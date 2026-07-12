import Foundation
import SocketIO
import UIKit

enum OutboxRetryResult: Equatable {
    case started
    case missingLocalFile
    case notFound
}

/// 消息 CRUD、发送、搜索、历史同步，从 ChatStore 拆出。
/// 通过 SocketProvider 访问 socket，不直接依赖 ChatStore。
@MainActor
final class MessageStore: ObservableObject {
    static let recallFailedNotification = Notification.Name("MessageStoreRecallFailed")
    static let messageDeletedNotification = Notification.Name("MessageStoreMessageDeleted")
    struct HistorySyncResult: Equatable {
        let localCount: Int
        let remoteTotal: Int?
        let downloaded: Int
        let completed: Bool
        let error: String?
    }

    private struct LocalCacheSnapshot {
        let messagesByChannel: [String: [ChatMessage]]
        let readStates: [String: [String: Double]]
        let pending: [PendingOutboundMessage]
    }

    typealias UploadPurpose = MediaUploadPurpose
    typealias UploadResult = MediaUploadResult

    let timelineStore: ChatTimelineStore
    var messagesByChannel: [String: [ChatMessage]] {
        get { timelineStore.messagesByChannel }
        set { timelineStore.messagesByChannel = newValue }
    }
    var readStates: [String: [String: Double]] {
        get { timelineStore.readStates }
        set { timelineStore.readStates = newValue }
    }
    @Published var aiTyping = false
    @Published var aiReplying = false
    private var loadingOlderChannels: Set<String> {
        get { timelineStore.loadingOlderChannels }
        set { timelineStore.loadingOlderChannels = newValue }
    }
    private var loadingNewerChannels: Set<String> {
        get { timelineStore.loadingNewerChannels }
        set { timelineStore.loadingNewerChannels = newValue }
    }
    private var latestPersistedMessageIDs: [String: String] {
        get { timelineStore.latestPersistedMessageIDs }
        set { timelineStore.latestPersistedMessageIDs = newValue }
    }

    // MARK: - 消息解析兼容入口

    nonisolated static func parseMessage(
        _ dictionary: [String: Any],
        context: String = ""
    ) -> ChatMessage? {
        ChatMessageMapper.parse(dictionary, context: context)
    }

    nonisolated static func parseMessages(
        _ rows: [[String: Any]],
        context: String = ""
    ) -> [ChatMessage] {
        ChatMessageMapper.parse(rows, context: context)
    }

    private var restoringCache = false
    private var lastLoadOlderAt: [String: Date] = [:]
    private var lastLoadNewerAt: [String: Date] = [:]
    private let httpClient: any HTTPClient
    private let persistence: any ChatPersistenceProtocol
    private let remoteDataSource: ChatRemoteDataSource
    private let mediaUploadService: MediaUploadService
    private let outboxProcessor: OutboxProcessor
    private var pendingReadReceipts: [String: Double] = [:]
    private var lastEmittedReadReceipts: [String: Double] = [:]
    private var readReceiptFlushTask: Task<Void, Never>?

    private static let mediaTypes = ["image", "video"]
    private static let managedAttachmentTypes = ["image", "video", "file"]

    weak var socketProvider: SocketProvider?

    init(
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        persistence: any ChatPersistenceProtocol = ChatPersistence.shared,
        timelineStore: ChatTimelineStore? = nil
    ) {
        self.httpClient = httpClient
        self.persistence = persistence
        self.timelineStore = timelineStore ?? ChatTimelineStore()
        remoteDataSource = ChatRemoteDataSource(httpClient: httpClient)
        mediaUploadService = MediaUploadService(httpClient: httpClient)
        outboxProcessor = OutboxProcessor(persistence: persistence)
    }

    var messages: [ChatMessage] { messages(for: .couple) }

    // MARK: - 消息读写

    func messages(for channel: ChatChannel) -> [ChatMessage] {
        timelineStore.messages(for: channel)
    }

    func updateMessages(_ channel: ChatChannel, _ transform: (inout [ChatMessage]) -> Void) {
        timelineStore.updateMessages(channel, transform)
    }

    func upsert(_ msg: ChatMessage, in channel: ChatChannel) {
        if !msg.pending, !msg.failed,
           messages(for: channel).last.map({ $0.ts <= msg.ts }) != false {
            latestPersistedMessageIDs[channel.rawValue] = msg.id
        }
        Task {
            await persistence.insertMessage(msg)
            if !msg.pending, !msg.failed, let clientId = msg.clientId {
                await completePendingOutbound(clientId: clientId)
            }
        }
        updateMessages(channel) { list in
            if let i = list.firstIndex(where: { $0.id == msg.id || (msg.clientId != nil && $0.id == msg.clientId) }) {
                list[i] = msg
                return
            }
            if let last = list.last, last.ts > msg.ts,
               let i = list.lastIndex(where: { $0.ts <= msg.ts }) {
                list.insert(msg, at: i + 1)
            } else {
                list.append(msg)
            }
        }
    }

    func upsertBatch(_ msgs: [ChatMessage], in channel: ChatChannel) async {
        guard !msgs.isEmpty else { return }
        let persisted = await persistence.insertMessages(msgs)
        guard persisted == msgs.count else {
            print("[MessageStore] ⚠️ 批量消息写入失败 channel=\(channel.rawValue)")
            return
        }
        for msg in msgs {
            if !msg.pending, !msg.failed, let clientId = msg.clientId {
                await completePendingOutbound(clientId: clientId)
            }
        }
        updateMessages(channel) { list in
            for msg in msgs {
                if let i = list.firstIndex(where: { $0.id == msg.id || (msg.clientId != nil && $0.id == msg.clientId) }) {
                    list[i] = msg
                    continue
                }
                if let last = list.last, last.ts > msg.ts,
                   let i = list.lastIndex(where: { $0.ts <= msg.ts }) {
                    list.insert(msg, at: i + 1)
                } else {
                    list.append(msg)
                }
            }
        }
    }

    // MARK: - 本地缓存

    func restoreLocalCache(for session: Session) async {
        restoringCache = true
        let snapshot = LocalCacheSnapshot(
            messagesByChannel: [
                ChatChannel.couple.rawValue: await persistence.fetchLatestMessages(
                    channel: ChatChannel.couple.rawValue, limit: 50),
                ChatChannel.ai.rawValue: await persistence.fetchLatestMessages(
                    channel: ChatChannel.ai.rawValue, limit: 50),
            ],
            readStates: [
                ChatChannel.couple.rawValue: await persistence.loadReadReceipts(
                    channel: ChatChannel.couple.rawValue),
                ChatChannel.ai.rawValue: await persistence.loadReadReceipts(
                    channel: ChatChannel.ai.rawValue),
            ],
            pending: await outboxProcessor.allPending())
        messagesByChannel = snapshot.messagesByChannel
        readStates = snapshot.readStates
        latestPersistedMessageIDs = snapshot.messagesByChannel.compactMapValues { $0.last?.id }
        // 正式消息和待发消息分表存储；重启后把 outbox 重新投影成聊天气泡。
        for item in snapshot.pending {
            let channel = ChatChannel(rawValue: item.channel) ?? .couple
            let optimistic = item.optimisticMessage(session: session)
            updateMessages(channel) { list in
                guard !list.contains(where: { $0.id == item.clientId || $0.clientId == item.clientId }) else { return }
                list.append(optimistic)
                list.sort { $0.ts < $1.ts }
            }
        }
        restoringCache = false
    }

    func applyBootstrap(_ snapshot: AppBootstrapSnapshot, session: Session) async {
        let remote = snapshot.messagesByChannel
        let receipts = snapshot.readStates
        for messages in remote.values {
            _ = await persistence.insertMessages(messages)
        }
        let now = Date().timeIntervalSince1970 * 1000
        for (channel, state) in receipts {
            for (username, ts) in state {
                await persistence.saveReadReceipt(
                    channel: channel, username: username, ts: ts, updatedAt: now)
            }
        }

        var next = remote
        for item in await outboxProcessor.allPending() {
            let channel = ChatChannel(rawValue: item.channel) ?? .couple
            var list = next[channel.rawValue] ?? []
            if !list.contains(where: { $0.id == item.clientId || $0.clientId == item.clientId }) {
                list.append(item.optimisticMessage(session: session))
                list.sort { $0.ts < $1.ts }
            }
            next[channel.rawValue] = list
        }
        messagesByChannel = next
        readStates = receipts
        latestPersistedMessageIDs = remote.compactMapValues { $0.last?.id }
    }

    // MARK: - 搜索跳转

    @discardableResult
    func ensureMessageLoaded(_ target: ChatMessage, channel: ChatChannel) async -> Bool {
        if messages(for: channel).contains(where: { $0.id == target.id }) { return true }
        let window = await persistence.fetchMessagesAround(
            channel: channel.rawValue, centerTimestamp: target.ts, beforeLimit: 36, afterLimit: 28)
        if !window.isEmpty {
            updateMessages(channel) { list in
                list = ChatMessageWindowing.mergedWindow(window, with: list, around: target.id)
            }
        }
        if !messages(for: channel).contains(where: { $0.id == target.id }) {
            upsert(target, in: channel)
        }
        return messages(for: channel).contains(where: { $0.id == target.id })
    }

    @discardableResult
    func ensureDateLoaded(_ date: Date, channel: ChatChannel) async -> ChatMessage? {
        let range = ChatMessageWindowing.dayRange(for: date)
        var dayMessages = await persistence.fetchMessages(
            channel: channel.rawValue, fromInclusive: range.start, toExclusive: range.end, limit: 80)
        if dayMessages.isEmpty {
            let incoming = await fetchRemoteMessages(
                MessagePageRequest(channel: channel, after: range.start, before: range.end, limit: 80),
                context: "ensureDate:\(channel.rawValue)")
            guard !incoming.isEmpty else { return nil }
            await upsertBatch(incoming, in: channel)
            dayMessages = incoming
        }
        guard let target = dayMessages.first else { return nil }
        let context = await persistence.fetchMessagesAround(
            channel: channel.rawValue, centerTimestamp: target.ts, beforeLimit: 20, afterLimit: 44)
        if !context.isEmpty { dayMessages = context }
        updateMessages(channel) { list in
            list = ChatMessageWindowing.mergedWindow(dayMessages, with: list, around: target.id)
        }
        return target
    }

    private func fetchRemoteMessages(_ request: MessagePageRequest, context: String) async -> [ChatMessage] {
        guard let session = socketProvider?.currentSession else { return [] }
        return await remoteDataSource.fetchMessages(request, session: session, context: context)
    }

    func ensureLocalMessages(_ channel: ChatChannel) async {
        let current = messages(for: channel)
        // 登录恢复阶段已把最近消息放进内存。聊天转场时不应再同步访问 SQLite，
        // 否则大量历史记录会让 push / interactive-pop 手势出现卡顿。
        guard current.isEmpty else { return }
        let local = await persistence.fetchLatestMessages(channel: channel.rawValue, limit: 50)
        guard !local.isEmpty else { return }
        let pendingOrFailed = current.filter { $0.pending || $0.failed }
        let knownIds = Set(local.map(\.id))
        updateMessages(channel) { list in
            list = local + pendingOrFailed.filter { !knownIds.contains($0.id) }
        }
    }

    /// 搜索跳转会把内存中的消息裁成目标附近的一小段。用户明确选择“回到最新”时，
    /// 必须重新加载最新窗口，不能只修改滚动状态，否则下一次刷新仍会回到历史窗口。
    func restoreLatestMessages(_ channel: ChatChannel) async {
        var latest = await persistence.fetchLatestMessages(channel: channel.rawValue, limit: 50)
        if latest.isEmpty {
            latest = await fetchRemoteMessages(
                MessagePageRequest(channel: channel, limit: 50),
                context: "restoreLatest:\(channel.rawValue)")
            if !latest.isEmpty { _ = await persistence.insertMessages(latest) }
        }
        guard !latest.isEmpty else { return }
        updateMessages(channel) { current in
            current = ChatMessageWindowing.latestWindow(latest, preservingOutboundFrom: current)
        }
        if let lastConfirmed = latest
            .filter({ !$0.pending && !$0.failed })
            .max(by: { $0.ts < $1.ts }) {
            latestPersistedMessageIDs[channel.rawValue] = lastConfirmed.id
        }
    }

    func isLoadingOlder(_ channel: ChatChannel) -> Bool {
        loadingOlderChannels.contains(channel.rawValue)
    }

    func isLoadingNewer(_ channel: ChatChannel) -> Bool {
        loadingNewerChannels.contains(channel.rawValue)
    }

    func isShowingLatestWindow(_ channel: ChatChannel) -> Bool {
        let list = messages(for: channel)
        guard let latestID = latestPersistedMessageIDs[channel.rawValue] else { return true }
        guard let last = list.last else { return true }
        if last.id == latestID { return true }
        // 自己刚发出的消息是本地乐观插入（pending/failed），排在最新已确认消息之后。
        // 这类尾部消息仍属于“最新窗口”，否则每次发送都会被误判为浏览历史，
        // 导致列表不跟到底、新消息落到输入栏后面（见搜索/分页跳转逻辑）。
        guard let anchorIndex = list.firstIndex(where: { $0.id == latestID }) else { return false }
        let tail = list[list.index(after: anchorIndex)...]
        return tail.allSatisfy { $0.pending || $0.failed }
    }

    func loadOlderAsync(_ channel: ChatChannel = .couple) async {
        guard let first = messages(for: channel).first else { return }
        guard !loadingOlderChannels.contains(channel.rawValue) else { return }
        if let last = lastLoadOlderAt[channel.rawValue], Date().timeIntervalSince(last) < 0.45 { return }
        lastLoadOlderAt[channel.rawValue] = Date()
        loadingOlderChannels.insert(channel.rawValue)
        let limit = 22
        let firstTs = first.ts

        let localOlder = await persistence.fetchMessages(
            channel: channel.rawValue, beforeTimestamp: firstTs, limit: limit)
        if !localOlder.isEmpty {
            updateMessages(channel) { current in
                let known = Set(current.map(\.id))
                current.insert(contentsOf: localOlder.filter { !known.contains($0.id) }, at: 0)
            }
            loadingOlderChannels.remove(channel.rawValue)
            return
        }
        let older = await fetchRemoteMessages(
            MessagePageRequest(channel: channel, before: firstTs, limit: limit),
            context: "loadOlder:\(channel.rawValue)")
        defer { loadingOlderChannels.remove(channel.rawValue) }
        guard !older.isEmpty else { return }
        _ = await persistence.insertMessages(older)
        updateMessages(channel) { current in
            let known = Set(current.map(\.id))
            current.insert(contentsOf: older.filter { !known.contains($0.id) }, at: 0)
        }
    }

    func loadNewerAsync(_ channel: ChatChannel = .couple) async {
        guard let last = messages(for: channel).last else { return }
        guard !loadingNewerChannels.contains(channel.rawValue) else { return }
        if let lastLoad = lastLoadNewerAt[channel.rawValue], Date().timeIntervalSince(lastLoad) < 0.45 { return }
        lastLoadNewerAt[channel.rawValue] = Date()
        loadingNewerChannels.insert(channel.rawValue)
        let limit = 24
        let lastTs = last.ts

        let localNewer = await persistence.fetchMessages(
            channel: channel.rawValue, fromInclusive: lastTs + 0.001,
            toExclusive: Double.greatestFiniteMagnitude, limit: limit)
        if !localNewer.isEmpty {
            updateMessages(channel) { current in
                let known = Set(current.map(\.id))
                current.append(contentsOf: localNewer.filter { !known.contains($0.id) })
            }
            loadingNewerChannels.remove(channel.rawValue)
            return
        }
        let newer = await fetchRemoteMessages(
            MessagePageRequest(channel: channel, since: lastTs, limit: limit),
            context: "loadNewer:\(channel.rawValue)")
        defer { loadingNewerChannels.remove(channel.rawValue) }
        guard !newer.isEmpty else { return }
        _ = await persistence.insertMessages(newer)
        updateMessages(channel) { current in
            let known = Set(current.map(\.id))
            current.append(contentsOf: newer.filter { !known.contains($0.id) })
        }
    }

    // MARK: - 发送

    func sendText(_ text: String, channel: ChatChannel = .couple,
                  replyTo: String? = nil, replyPreview: String? = nil,
                  meta: ChatMessageMeta? = nil, session: Session) async {
        let clientId = "tmp-" + UUID().uuidString
        let optimistic = ChatMessage(optimisticText: text, me: session, clientId: clientId,
                                     channel: channel.rawValue, replyTo: replyTo, replyPreview: replyPreview,
                                     meta: meta)
        updateMessages(channel) { $0.append(optimistic) }
        let item = PendingOutboundMessage(
            clientId: clientId,
            channel: channel.rawValue,
            type: "text",
            text: text,
            replyTo: replyTo,
            replyPreview: replyPreview,
            localFilePath: nil,
            mimeType: nil,
            uploadId: nil,
            uploadURL: nil,
            createdAt: optimistic.ts,
            attempts: 0,
            lastError: nil,
            metaJSON: meta.flatMap { value in
                (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }
            })
        guard await outboxProcessor.save(item) else {
            markPendingFailed(clientId: clientId, channel: channel, error: "本地保存失败")
            return
        }
        await schedulePendingOutbound(item, channel: channel, session: session)
    }

    func sendInteraction(
        id: String,
        kind: InteractionEffectKind,
        text: String,
        channel: ChatChannel = .couple,
        session: Session
    ) async {
        let interaction = ChatInteractionMeta(id: id, kind: kind.rawValue, text: text)
        await sendText(
            text, channel: channel, meta: ChatMessageMeta(interaction: interaction), session: session)
    }

    func sendMedia(data: Data, mimeType: String, preferredType: String, localPreviewURL: URL?,
                   channel: ChatChannel = .couple, displayText: String? = nil, session: Session) async {
        let clientId = "tmp-" + UUID().uuidString
        let outgoingText = displayText ?? Self.mediaPlaceholderText(for: preferredType)
        let createdAt = Date().timeIntervalSince1970 * 1000
        let durableURL = await outboxProcessor.persistMedia(
            data: data, mimeType: mimeType, clientId: clientId, username: session.username)
        var optimistic = ChatMessage(
            optimisticMedia: preferredType,
            text: outgoingText,
            localURL: durableURL?.absoluteString ?? localPreviewURL?.absoluteString,
            me: session,
            clientId: clientId,
            channel: channel.rawValue)
        optimistic.ts = createdAt
        updateMessages(channel) { $0.append(optimistic) }
        guard let durableURL else {
            markPendingFailed(clientId: clientId, channel: channel, error: "媒体保存失败")
            return
        }
        let item = PendingOutboundMessage(
            clientId: clientId,
            channel: channel.rawValue,
            type: preferredType,
            text: outgoingText,
            replyTo: nil,
            replyPreview: nil,
            localFilePath: durableURL.path,
            mimeType: mimeType,
            uploadId: nil,
            uploadURL: nil,
            createdAt: createdAt,
            attempts: 0,
            lastError: nil)
        guard await outboxProcessor.save(item) else {
            try? FileManager.default.removeItem(at: durableURL)
            markPendingFailed(clientId: clientId, channel: channel, error: "本地保存失败")
            return
        }
        await schedulePendingOutbound(item, channel: channel, session: session)
    }

    func sendSticker(url: String, channel: ChatChannel = .couple, session: Session) async {
        let clientId = "tmp-" + UUID().uuidString
        let optimistic = ChatMessage(
            optimisticMedia: "sticker", text: "[表情]", localURL: url,
            me: session, clientId: clientId, channel: channel.rawValue)
        updateMessages(channel) { $0.append(optimistic) }
        let item = PendingOutboundMessage(
            clientId: clientId,
            channel: channel.rawValue,
            type: "sticker",
            text: "[表情]",
            replyTo: nil,
            replyPreview: nil,
            localFilePath: nil,
            mimeType: nil,
            uploadId: nil,
            uploadURL: url,
            createdAt: optimistic.ts,
            attempts: 0,
            lastError: nil)
        guard await outboxProcessor.save(item) else {
            markPendingFailed(clientId: clientId, channel: channel, error: "本地保存失败")
            return
        }
        await schedulePendingOutbound(item, channel: channel, session: session)
    }

    func uploadSticker(_ image: UIImage, session: Session) async -> String? {
        guard let data = image.jpegData(compressionQuality: 0.9),
              let uploaded = try? await uploadMedia(
                data: data, mimeType: "image/jpeg", purpose: .sticker, session: session) else { return nil }
        if let url = ServerConfig.resolveMediaURL(uploaded.url) {
            ImageCache.shared.store(data: data, image: image, for: url)
        }
        return uploaded.url
    }

    func retryFailedMessage(clientId: String, session: Session) async -> OutboxRetryResult {
        guard var pending = await outboxProcessor.pending(clientId: clientId) else {
            return .notFound
        }
        guard await outboxProcessor.canRetry(pending) else {
            return .missingLocalFile
        }

        pending.lastError = nil
        pending.attempts = 0
        guard await outboxProcessor.save(pending) else { return .notFound }
        let channel = ChatChannel(rawValue: pending.channel) ?? .couple
        await schedulePendingOutbound(pending, channel: channel, session: session)
        return .started
    }

    func discardFailedMessage(clientId: String) async {
        guard let pending = await outboxProcessor.discard(clientId: clientId) else {
            removeOptimisticMessage(clientId: clientId)
            return
        }
        removeOptimisticMessage(clientId: clientId, channel: ChatChannel(rawValue: pending.channel))
    }

    private func removeOptimisticMessage(clientId: String, channel: ChatChannel? = nil) {
        let channels = channel.map { [$0] } ?? ChatChannel.allCases
        for channel in channels {
            updateMessages(channel) { list in
                list.removeAll { ($0.clientId ?? $0.id) == clientId || $0.id == clientId }
            }
        }
    }

    func hasPendingMedia(_ message: ChatMessage) async -> Bool {
        (await outboxProcessor.pending(clientId: message.id))?.isMedia == true
    }

    // MARK: - 已读

    func markRead(_ channel: ChatChannel, through timestamp: Double) {
        guard timestamp > 0 else { return }
        let key = channel.rawValue
        pendingReadReceipts[key] = max(pendingReadReceipts[key] ?? 0, timestamp)
        scheduleReadReceiptFlush()
    }

    /// 断线期间仍保留各频道最高已展示时间；连接成功后调用本方法重新发送。
    func flushPendingReadReceipts() {
        readReceiptFlushTask?.cancel()
        readReceiptFlushTask = nil
        lastEmittedReadReceipts.removeAll()
        emitPendingReadReceipts()
    }

    func resetPendingReadReceipts() {
        readReceiptFlushTask?.cancel()
        readReceiptFlushTask = nil
        pendingReadReceipts.removeAll()
        lastEmittedReadReceipts.removeAll()
    }

    func pendingReadTimestamp(for channel: ChatChannel) -> Double? {
        pendingReadReceipts[channel.rawValue]
    }

    private func scheduleReadReceiptFlush() {
        guard socketProvider?.isConnected == true else { return }
        readReceiptFlushTask?.cancel()
        readReceiptFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self else { return }
            self.readReceiptFlushTask = nil
            self.emitPendingReadReceipts()
        }
    }

    private func emitPendingReadReceipts() {
        guard let socket = socketProvider?.socket,
              socketProvider?.isConnected == true else { return }
        for (rawChannel, timestamp) in pendingReadReceipts {
            guard timestamp > (lastEmittedReadReceipts[rawChannel] ?? 0),
                  let channel = ChatChannel(rawValue: rawChannel) else { continue }
            socket.emit(
                SocketEvent.read.rawValue,
                SocketPayloadEncoder.encode(ReadReceiptRequest(channel: channel, ts: timestamp)))
            lastEmittedReadReceipts[rawChannel] = timestamp
        }
    }

    func partnerHasRead(_ msg: ChatMessage, username: String?) -> Bool {
        guard msg.channel == ChatChannel.couple.rawValue, let me = username else { return false }
        let partnerTs = readState(for: .couple).first(where: { $0.key != me })?.value ?? 0
        return msg.ts <= partnerTs
    }

    func readState(for channel: ChatChannel) -> [String: Double] {
        readStates[channel.rawValue] ?? [:]
    }

    func setReadState(_ channel: ChatChannel, state: [String: Double]) {
        var next = readStates
        next[channel.rawValue] = state
        readStates = next
        if let username = socketProvider?.sessionUsername,
           let confirmed = state[username],
           let pending = pendingReadReceipts[channel.rawValue],
           confirmed >= pending {
            pendingReadReceipts.removeValue(forKey: channel.rawValue)
            lastEmittedReadReceipts.removeValue(forKey: channel.rawValue)
        }
        for (user, ts) in state {
            Task {
                await persistence.saveReadReceipt(
                    channel: channel.rawValue,
                    username: user,
                    ts: ts,
                    updatedAt: Date().timeIntervalSince1970 * 1000)
            }
        }
    }

    func setReadState(_ channel: ChatChannel, user: String, ts: Double) {
        var state = readState(for: channel)
        if ts > (state[user] ?? 0) { state[user] = ts }
        setReadState(channel, state: state)
    }

    // MARK: - 撤回

    func recallMessage(_ message: ChatMessage, channel: ChatChannel) {
        guard let s = socketProvider?.socket, socketProvider?.isConnected == true else { return }
        s.emitWithAck(
            SocketEvent.messageRecall.rawValue,
            SocketPayloadEncoder.encode(MessageRecallRequest(id: message.id))).timingOut(after: 9) { [weak self] response in
                let ok = (response.first as? [String: Any])?["ok"] as? Bool == true
                guard !ok else { return }
                Task { @MainActor in
                    guard self != nil else { return }
                    NotificationCenter.default.post(name: Self.recallFailedNotification, object: nil)
                }
            }
    }

    func applyRecall(id: String, channel: ChatChannel?) {
        let channels = channel.map { [$0] } ?? ChatChannel.allCases
        var repairedReplies: [ChatMessage] = []
        var mediaURLs: Set<URL> = []
        for c in channels {
            updateMessages(c) { list in
                for message in list where message.id == id {
                    if let url = message.mediaURL { mediaURLs.insert(url) }
                    for attachment in message.attachments ?? [] {
                        if let url = attachment.mediaURL { mediaURLs.insert(url) }
                    }
                }
                list.removeAll { $0.id == id }
                for index in list.indices where list[index].replyTo == id {
                    list[index].replyTo = nil
                    list[index].replyPreview = nil
                    repairedReplies.append(list[index])
                }
            }
            if latestPersistedMessageIDs[c.rawValue] == id {
                latestPersistedMessageIDs[c.rawValue] = messages(for: c).last(where: {
                    !$0.pending && !$0.failed
                })?.id
            }
        }
        MediaFavoriteStore.shared.remove(messageId: id)
        for url in mediaURLs { ImageCache.shared.removeMedia(for: url) }
        NotificationCenter.default.post(
            name: Self.messageDeletedNotification,
            object: nil,
            userInfo: ["messageId": id])
        let repliesToPersist = repairedReplies
        Task {
            await persistence.deleteMessage(id: id)
            if !repliesToPersist.isEmpty {
                _ = await persistence.insertMessages(repliesToPersist)
            }
        }
    }

    // MARK: - Meta 更新（确认卡）

    func applyMessageUpdate(id: String, meta: [String: Any]?) {
        for c in ChatChannel.allCases {
            updateMessages(c) { list in
                guard let i = list.firstIndex(where: { $0.id == id }) else { return }
                var m = list[i]
                m.meta = meta.flatMap { ChatMessageMeta(dict: $0) }
                list[i] = m
                Task { await persistence.insertMessage(m) }
            }
        }
    }

    func confirmAction(messageId: String, decision: String) {
        socketProvider?.socket?.emit(
            SocketEvent.actionConfirm.rawValue,
            SocketPayloadEncoder.encode(ActionConfirmRequest(messageId: messageId, decision: decision)))
    }

    // MARK: - 搜索

    func searchMessages(_ query: String, channel: ChatChannel) async -> [ChatMessage] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let local = await persistence.searchMessages(query: q, channel: channel.rawValue)
        guard let s = socketProvider?.socket, socketProvider?.isConnected == true else { return local }
        return await withCheckedContinuation { continuation in
            s.emitWithAck(
                SocketEvent.messagesSearch.rawValue,
                SocketPayloadEncoder.encode(MessageSearchRequest(channel: channel, query: q, limit: 50)))
                .timingOut(after: 9) { data in
                    guard let dict = data.first as? [String: Any],
                          let list = dict["list"] as? [[String: Any]] else {
                        continuation.resume(returning: local)
                        return
                    }
                    let remote = Self.parseMessages(list, context: "search:\(channel.rawValue)")
                    continuation.resume(returning: ChatMessageWindowing.mergeSearchResults(remote, local))
                }
        }
    }

    func mediaMessages(
        for channel: ChatChannel,
        includeFiles: Bool = false,
        limit: Int? = nil
    ) async -> [ChatMessage] {
        let types = includeFiles ? Self.managedAttachmentTypes : Self.mediaTypes
        return await persistence.mediaMessages(channel: channel.rawValue, types: types, limit: limit)
    }

    func mediaItemCount(for channel: ChatChannel, includeFiles: Bool = false) async -> Int {
        let types = includeFiles ? Self.managedAttachmentTypes : Self.mediaTypes
        return await persistence.mediaCount(channel: channel.rawValue, types: types)
    }

    // MARK: - 全量同步

    @discardableResult
    func syncAllHistory(
        _ channel: ChatChannel,
        onProgress: @escaping (_ localCount: Int, _ remoteTotal: Int?) -> Void
    ) async -> HistorySyncResult {
        guard let session = socketProvider?.currentSession else {
            return HistorySyncResult(
                localCount: await persistence.messageCount(channel: channel.rawValue),
                remoteTotal: nil, downloaded: 0, completed: false, error: "当前未登录")
        }
        // 以数据库最早记录作为断点，而不是内存中最近 50 条；重启后会从上次位置继续。
        var oldest = await persistence.oldestMessageTimestamp(channel: channel.rawValue)
        var localCount = await persistence.messageCount(channel: channel.rawValue)
        var remoteTotal: Int?
        var downloaded = 0
        var completed = false
        var lastError: String?
        let pageLimit = 300
        onProgress(localCount, nil)
        while !Task.isCancelled {
            let page = await fetchHistoryPageREST(
                channel: channel, before: oldest, limit: pageLimit, session: session)
            if let total = page.total { remoteTotal = total }
            onProgress(localCount, remoteTotal)
            if let error = page.error {
                lastError = error
                break
            }
            let batch = page.messages
            if batch.isEmpty {
                completed = true
                break
            }
            let persisted = await persistence.insertMessages(batch)
            guard persisted == batch.count else {
                lastError = "写入本地数据库失败"
                break
            }
            downloaded += batch.count
            localCount = await persistence.messageCount(channel: channel.rawValue)
            onProgress(localCount, remoteTotal)
            let batchOldest = batch.map(\.ts).min()
            if batch.count < pageLimit {
                completed = true
                break
            }
            if let batchOldest, let prev = oldest, batchOldest >= prev {
                lastError = "同步游标未继续前进"
                break
            }
            oldest = batchOldest
        }
        if Task.isCancelled { lastError = "同步已暂停" }
        let latest = await persistence.fetchLatestMessages(channel: channel.rawValue, limit: 50)
        if !latest.isEmpty { updateMessages(channel) { $0 = latest } }
        latestPersistedMessageIDs[channel.rawValue] = latest.last?.id
        localCount = await persistence.messageCount(channel: channel.rawValue)
        if let remoteTotal, localCount >= remoteTotal { completed = true }
        return HistorySyncResult(
            localCount: localCount, remoteTotal: remoteTotal, downloaded: downloaded,
            completed: completed && lastError == nil, error: lastError)
    }

    private func fetchHistoryPageREST(
        channel: ChatChannel, before: Double?, limit: Int, session: Session
    ) async -> ChatHistoryPage {
        await remoteDataSource.fetchHistoryPage(
            channel: channel,
            before: before,
            limit: limit,
            session: session)
    }

    func clearLocalHistory() async {
        await persistence.deleteMessages(channel: nil)
        messagesByChannel = [:]
        latestPersistedMessageIDs = [:]
    }

    // MARK: - 私有辅助

    private func schedulePendingOutbound(
        _ item: PendingOutboundMessage,
        channel: ChatChannel,
        session: Session
    ) async {
        guard socketProvider?.isConnected == true, socketProvider?.socket != nil else {
            await recordPendingFailure(item, channel: channel, message: "当前离线")
            return
        }
        markPendingSending(clientId: item.clientId, channel: channel)
        flushOutbox(session: session)
    }

    /// 连接建立后按创建时间串行重放。服务端以 clientId 幂等，ACK 丢失也不会生成重复消息。
    func flushOutbox(session: Session) {
        guard socketProvider?.isConnected == true,
              socketProvider?.socket != nil else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.outboxProcessor.replay(
                isConnected: { [weak self] in self?.socketProvider?.isConnected == true },
                send: { [weak self] item in
                    guard let self else { return false }
                    let channel = ChatChannel(rawValue: item.channel) ?? .couple
                    self.markPendingSending(clientId: item.clientId, channel: channel)
                    return await self.transmitPendingOutbound(item, session: session)
                })
        }
    }

    private func transmitPendingOutbound(_ original: PendingOutboundMessage, session: Session) async -> Bool {
        guard let socket = socketProvider?.socket, socketProvider?.isConnected == true else { return false }
        var item = original
        let channel = ChatChannel(rawValue: item.channel) ?? .couple

        if !item.attachments.isEmpty {
            for index in item.attachments.indices where item.attachments[index].uploadId == nil {
                let attachment = item.attachments[index]
                guard FileManager.default.fileExists(atPath: attachment.localFilePath) else {
                    await recordPendingFailure(item, channel: channel, message: "相册资源不可用")
                    return false
                }
                do {
                    let uploaded = try await uploadMedia(
                        fileURL: URL(fileURLWithPath: attachment.localFilePath),
                        mimeType: attachment.mimeType, purpose: .message, session: session)
                    item.attachments[index].uploadId = uploaded.id
                    item.attachments[index].uploadURL = uploaded.url
                    item.lastError = nil
                    _ = await outboxProcessor.save(item)
                    updateMessages(channel) { list in
                        guard let messageIndex = list.firstIndex(where: { $0.id == item.clientId }),
                              let attachmentIndex = list[messageIndex].attachments?.firstIndex(where: {
                                  $0.assetId == attachment.assetId && $0.role == attachment.role
                              }) else { return }
                        list[messageIndex].attachments?[attachmentIndex] = ChatAttachment(
                            id: uploaded.id, assetId: attachment.assetId, role: attachment.role,
                            order: attachment.order, url: uploaded.url, mimeType: attachment.mimeType)
                        if attachment.role == "photo", attachment.order == 0 {
                            list[messageIndex].url = uploaded.url
                        }
                    }
                } catch {
                    await recordPendingFailure(item, channel: channel, message: error.localizedDescription)
                    return false
                }
            }
        } else if item.isMedia, item.uploadId == nil {
            guard let path = item.localFilePath,
                  let mimeType = item.mimeType,
                  FileManager.default.fileExists(atPath: path) else {
                await recordPendingFailure(item, channel: channel, message: "本地媒体文件不可用")
                return false
            }
            let localURL = URL(fileURLWithPath: path)
            do {
                let uploaded = try await uploadMedia(
                    fileURL: localURL, mimeType: mimeType, purpose: .message, session: session)
                item.type = item.type == "file" ? "file" : (uploaded.type.isEmpty ? item.type : uploaded.type)
                item.uploadId = uploaded.id
                item.uploadURL = uploaded.url
                item.lastError = nil
                _ = await outboxProcessor.save(item)

                if item.type == "image",
                   let data = try? Data(contentsOf: localURL),
                   let remoteURL = ServerConfig.resolveMediaURL(uploaded.url) {
                    ImageCache.shared.store(data: data, for: remoteURL)
                }
                updateMessages(channel) { list in
                    guard let index = list.firstIndex(where: { $0.id == item.clientId }) else { return }
                    list[index].type = item.type
                    list[index].url = item.uploadURL
                }
            } catch {
                await recordPendingFailure(item, channel: channel, message: error.localizedDescription)
                return false
            }
        }

        let interactionMeta: ChatInteractionMeta? = item.metaJSON.flatMap { raw in
            guard let data = raw.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let interaction = dict["interaction"] as? [String: Any] else { return nil }
            return ChatInteractionMeta(dict: interaction)
        }
        let attachmentRequests: [MessageAttachmentRequest]? = item.attachments.isEmpty ? nil : item.attachments.compactMap {
            guard let uploadId = $0.uploadId else { return nil }
            return MessageAttachmentRequest(assetId: $0.assetId, role: $0.role, uploadId: uploadId, order: $0.order)
        }
        let request = MessageSendRequest(
            channel: channel,
            type: item.type,
            text: item.text,
            url: item.uploadURL,
            uploadId: item.uploadId,
            replyTo: item.replyTo,
            replyPreview: item.replyPreview,
            clientId: item.clientId,
            meta: interactionMeta.map { MessageSendMeta(interaction: $0) },
            attachments: attachmentRequests)
        let ack: [Any] = await withCheckedContinuation { continuation in
            socket.emitWithAck(SocketEvent.messageSend.rawValue, SocketPayloadEncoder.encode(request))
                .timingOut(after: 15) { continuation.resume(returning: $0) }
        }
        let succeeded = await handleSendAck(ack, clientId: item.clientId, channel: channel)
        if succeeded {
            await completePendingOutbound(clientId: item.clientId)
        } else {
            let code = (ack.first as? [String: Any])?["error"] as? String
            let message = ServerErrorCode.message(for: code, fallback: "发送确认超时")
            await recordPendingFailure(item, channel: channel, message: message)
        }
        return succeeded
    }

    private func markPendingSending(clientId: String, channel: ChatChannel) {
        updateMessages(channel) { list in
            guard let index = list.firstIndex(where: { $0.id == clientId }) else { return }
            list[index].pending = true
            list[index].failed = false
        }
    }

    private func markPendingFailed(clientId: String, channel: ChatChannel, error: String) {
        updateMessages(channel) { list in
            guard let index = list.firstIndex(where: { $0.id == clientId }) else { return }
            list[index].pending = false
            list[index].failed = true
        }
        if channel == .ai {
            aiTyping = false
            aiReplying = false
        }
        print("[MessageStore] ⚠️ 待发消息失败 clientId=\(clientId): \(error)")
    }

    private func recordPendingFailure(
        _ original: PendingOutboundMessage,
        channel: ChatChannel,
        message: String
    ) async {
        var item = await outboxProcessor.pending(clientId: original.clientId) ?? original
        item.attempts += 1
        item.lastError = message
        _ = await outboxProcessor.save(item)
        markPendingFailed(clientId: item.clientId, channel: channel, error: message)
    }

    private func completePendingOutbound(clientId: String) async {
        await outboxProcessor.complete(clientId: clientId)
    }

    @discardableResult
    private func handleSendAck(_ data: [Any], clientId: String, channel: ChatChannel) async -> Bool {
        let succeeded = (data.first as? [String: Any])?["ok"] as? Bool == true
        let acknowledgedMessage: ChatMessage? = {
            guard let dict = data.first as? [String: Any],
                  let message = dict["message"] as? [String: Any] else { return nil }
            return Self.parseMessage(message, context: "message:send ack")
        }()
        var messageToPersist: ChatMessage?
        updateMessages(channel) { list in
            guard let i = list.firstIndex(where: { $0.id == clientId }) else { return }
            if let dict = data.first as? [String: Any],
               dict["ok"] as? Bool == true, let realId = dict["id"] as? String {
                if let acknowledgedMessage {
                    list[i] = acknowledgedMessage
                    messageToPersist = acknowledgedMessage
                    return
                }
                var old = list[i]
                old.pending = false
                old.clientId = clientId
                var payload: [String: Any] = [
                    "id": realId, "sender": old.sender, "senderName": old.senderName,
                    "kind": old.kind, "type": old.type, "text": old.text,
                    "url": old.url as Any, "channel": old.channel, "ts": old.ts, "clientId": clientId,
                ]
                if let replyTo = old.replyTo {
                    payload["replyTo"] = replyTo
                    payload["replyPreview"] = old.replyPreview ?? ""
                    payload["reply"] = ["id": replyTo, "preview": old.replyPreview ?? ""]
                }
                list[i] = ChatMessage(dict: payload) ?? old
                messageToPersist = list[i]
            } else {
                list[i].pending = false
                list[i].failed = true
            }
        }
        if let messageToPersist { await persistence.insertMessage(messageToPersist) }
        return succeeded
    }

    func uploadMedia(
        data: Data,
        mimeType: String,
        purpose: UploadPurpose = .message,
        session: Session
    ) async throws -> UploadResult {
        try await mediaUploadService.upload(
            data: data, mimeType: mimeType, purpose: purpose, session: session)
    }

    private func uploadMedia(
        fileURL: URL,
        mimeType: String,
        purpose: UploadPurpose,
        session: Session
    ) async throws -> UploadResult {
        try await mediaUploadService.upload(
            fileURL: fileURL, mimeType: mimeType, purpose: purpose, session: session)
    }

    static func mediaPlaceholderText(for type: String) -> String {
        switch type {
        case "video": return "[视频]"
        case "voice": return "[语音]"
        case "file": return "[文件]"
        default: return "[图片]"
        }
    }

    static func multipartBody(data: Data, mimeType: String, boundary: String) -> Data {
        MediaUploadService.multipartBody(data: data, mimeType: mimeType, boundary: boundary)
    }

    static func fileExtension(for mimeType: String) -> String {
        MediaUploadService.fileExtension(for: mimeType)
    }

    nonisolated static func mergeSearchResults(
        _ first: [ChatMessage],
        _ second: [ChatMessage]
    ) -> [ChatMessage] {
        ChatMessageWindowing.mergeSearchResults(first, second)
    }

    nonisolated static func mergedWindow(
        _ window: [ChatMessage],
        with current: [ChatMessage],
        around targetId: String
    ) -> [ChatMessage] {
        ChatMessageWindowing.mergedWindow(window, with: current, around: targetId)
    }

    nonisolated static func latestWindow(
        _ latest: [ChatMessage],
        preservingOutboundFrom current: [ChatMessage]
    ) -> [ChatMessage] {
        ChatMessageWindowing.latestWindow(latest, preservingOutboundFrom: current)
    }

    nonisolated static func dayRange(for date: Date) -> (start: Double, end: Double) {
        ChatMessageWindowing.dayRange(for: date)
    }
}

extension MessageStore: ChatRepositoryProtocol, OutboxProcessing {}

private extension Data {
    mutating func append(_ string: String) {
        append(contentsOf: string.utf8)
    }
}
