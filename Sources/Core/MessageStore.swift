import Foundation
import SocketIO
import UIKit

/// 消息 CRUD、发送、搜索、历史同步，从 ChatStore 拆出。
/// 通过 SocketProvider 访问 socket，不直接依赖 ChatStore。
@MainActor
final class MessageStore: ObservableObject {
    struct HistorySyncResult: Equatable {
        let localCount: Int
        let remoteTotal: Int?
        let downloaded: Int
        let completed: Bool
        let error: String?
    }

    private struct HistoryPage {
        let messages: [ChatMessage]
        let total: Int?
        let error: String?
    }

    enum UploadPurpose: String {
        case message
        case avatar
        case sticker
    }

    @Published private(set) var messagesByChannel: [String: [ChatMessage]] = [:]
    @Published private(set) var readStates: [String: [String: Double]] = [:]
    @Published var aiTyping = false
    @Published var aiReplying = false
    @Published private var loadingOlderChannels = Set<String>()
    @Published private var loadingNewerChannels = Set<String>()

    /// 消息解析计数：帮助追踪静默丢弃的消息
    private static var parseFailureCount: Int = 0
    private static var parseSuccessCount: Int = 0

    private var restoringCache = false
    private var lastLoadOlderAt: [String: Date] = [:]
    private var lastLoadNewerAt: [String: Date] = [:]
    private let storeStartedAtMs = Date().timeIntervalSince1970 * 1000

    /// outbox 始终串行发送，保证消息顺序并避免同一 clientId 并发重放。
    private var flushingOutbox = false
    private var outboxFlushRequested = false
    private let httpClient: any HTTPClient

    private static let mediaTypes = ["image", "video"]
    private static let managedAttachmentTypes = ["image", "video", "file"]

    weak var socketProvider: SocketProvider?

    init(httpClient: any HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    var messages: [ChatMessage] { messages(for: .couple) }

    // MARK: - 消息解析

    static func parseMessage(_ dict: [String: Any], context: String = "") -> ChatMessage? {
        if let msg = ChatMessage(dict: dict) {
            parseSuccessCount += 1
            return msg
        }
        parseFailureCount += 1
        let id = dict["id"] as? String ?? "?"
        let sender = dict["sender"] as? String ?? "?"
        let channel = dict["channel"] as? String ?? "?"
        let keys = dict.keys.joined(separator: ",")
        print("[MessageStore] ⚠️ 消息解析失败 #\(parseFailureCount) | id=\(id) sender=\(sender) channel=\(channel) context=\(context) keys=[\(keys)]")
        return nil
    }

    static func parseMessages(_ list: [[String: Any]], context: String = "") -> [ChatMessage] {
        let before = parseFailureCount
        let result = list.compactMap { parseMessage($0, context: context) }
        let failed = parseFailureCount - before
        if failed > 0 {
            print("[MessageStore] ⚠️ 批量解析完成: \(result.count)/\(list.count) 成功, \(failed) 失败 | context=\(context)")
        }
        return result
    }

    // MARK: - 消息读写

    func messages(for channel: ChatChannel) -> [ChatMessage] {
        messagesByChannel[channel.rawValue] ?? []
    }

    func updateMessages(_ channel: ChatChannel, _ transform: (inout [ChatMessage]) -> Void) {
        var next = messagesByChannel
        var list = next[channel.rawValue] ?? []
        transform(&list)
        next[channel.rawValue] = list
        messagesByChannel = next
    }

    func upsert(_ msg: ChatMessage, in channel: ChatChannel) {
        ChatLocalDatabase.shared.insertMessage(msg)
        if !msg.pending, !msg.failed, let clientId = msg.clientId {
            completePendingOutbound(clientId: clientId)
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

    func upsertBatch(_ msgs: [ChatMessage], in channel: ChatChannel) {
        guard !msgs.isEmpty else { return }
        for msg in msgs {
            ChatLocalDatabase.shared.insertMessage(msg)
            if !msg.pending, !msg.failed, let clientId = msg.clientId {
                completePendingOutbound(clientId: clientId)
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

    func restoreLocalCache(for session: Session) {
        restoringCache = true
        migrateLegacyCacheIfNeeded(for: session)
        messagesByChannel[ChatChannel.couple.rawValue] = ChatLocalDatabase.shared.fetchLatestMessages(channel: ChatChannel.couple.rawValue, limit: 50)
        messagesByChannel[ChatChannel.ai.rawValue] = ChatLocalDatabase.shared.fetchLatestMessages(channel: ChatChannel.ai.rawValue, limit: 50)
        readStates = [
            ChatChannel.couple.rawValue: ChatLocalDatabase.shared.loadReadReceipts(channel: ChatChannel.couple.rawValue),
            ChatChannel.ai.rawValue: ChatLocalDatabase.shared.loadReadReceipts(channel: ChatChannel.ai.rawValue),
        ]
        // 正式消息和待发消息分表存储；重启后把 outbox 重新投影成聊天气泡。
        for item in ChatLocalDatabase.shared.loadPendingOutbounds() {
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

    private func migrateLegacyCacheIfNeeded(for session: Session) {
        let existing = ChatLocalDatabase.shared.fetchLatestMessages(channel: ChatChannel.couple.rawValue, limit: 1)
        guard existing.isEmpty,
              let snapshot = LegacyCacheMigration.load(for: session.username) else { return }
        for (_, list) in snapshot.messagesByChannel {
            for msg in list where !msg.pending && !msg.failed {
                ChatLocalDatabase.shared.insertMessage(msg)
            }
        }
        for (channel, state) in snapshot.readStates {
            for (user, ts) in state {
                ChatLocalDatabase.shared.saveReadReceipt(channel: channel, username: user, ts: ts, updatedAt: snapshot.savedAt)
            }
        }
        LegacyCacheMigration.clear(for: session.username)
    }

    // MARK: - 搜索跳转

    @discardableResult
    func ensureMessageLoaded(_ target: ChatMessage, channel: ChatChannel) -> Bool {
        if messages(for: channel).contains(where: { $0.id == target.id }) { return true }
        let window = ChatLocalDatabase.shared.fetchMessagesAround(
            channel: channel.rawValue, centerTimestamp: target.ts, beforeLimit: 36, afterLimit: 28)
        if !window.isEmpty {
            updateMessages(channel) { list in
                list = Self.mergedWindow(window, with: list, around: target.id)
            }
        }
        if !messages(for: channel).contains(where: { $0.id == target.id }) {
            upsert(target, in: channel)
        }
        return messages(for: channel).contains(where: { $0.id == target.id })
    }

    @discardableResult
    func ensureDateLoaded(_ date: Date, channel: ChatChannel) async -> ChatMessage? {
        let range = Self.dayRange(for: date)
        var dayMessages = ChatLocalDatabase.shared.fetchMessages(
            channel: channel.rawValue, fromInclusive: range.start, toExclusive: range.end, limit: 80)
        if dayMessages.isEmpty {
            let incoming = await fetchRemoteMessages(
                MessageFetchRequest(channel: channel, after: range.start, before: range.end, limit: 80),
                context: "ensureDate:\(channel.rawValue)")
            guard !incoming.isEmpty else { return nil }
            upsertBatch(incoming, in: channel)
            dayMessages = incoming
        }
        guard let target = dayMessages.first else { return nil }
        let context = ChatLocalDatabase.shared.fetchMessagesAround(
            channel: channel.rawValue, centerTimestamp: target.ts, beforeLimit: 20, afterLimit: 44)
        if !context.isEmpty { dayMessages = context }
        updateMessages(channel) { list in
            list = Self.mergedWindow(dayMessages, with: list, around: target.id)
        }
        return target
    }

    private func fetchRemoteMessages(_ request: MessageFetchRequest, context: String) async -> [ChatMessage] {
        guard let socket = socketProvider?.socket, socketProvider?.isConnected == true else { return [] }
        let payload = SocketPayloadEncoder.encode(request)
        return await withCheckedContinuation { continuation in
            socket.emitWithAck(SocketEvent.messagesFetch.rawValue, payload).timingOut(after: 9) { data in
                guard let dict = data.first as? [String: Any],
                      let list = dict["list"] as? [[String: Any]] else {
                    continuation.resume(returning: [])
                    return
                }
                continuation.resume(returning: Self.parseMessages(list, context: context))
            }
        }
    }

    func ensureLocalMessages(_ channel: ChatChannel) {
        let current = messages(for: channel)
        // 登录恢复阶段已把最近消息放进内存。聊天转场时不应再同步访问 SQLite，
        // 否则大量历史记录会让 push / interactive-pop 手势出现卡顿。
        guard current.isEmpty else { return }
        let local = ChatLocalDatabase.shared.fetchLatestMessages(channel: channel.rawValue, limit: 50)
        guard !local.isEmpty else { return }
        let pendingOrFailed = current.filter { $0.pending || $0.failed }
        let knownIds = Set(local.map(\.id))
        updateMessages(channel) { list in
            list = local + pendingOrFailed.filter { !knownIds.contains($0.id) }
        }
    }

    // MARK: - 历史同步

    func syncHistory(_ channel: ChatChannel, roundsLeft: Int = 5) {
        guard let s = socketProvider?.socket, roundsLeft > 0 else { return }
        let local = messages(for: channel)
        let lastTs = local.last(where: { !$0.pending && !$0.failed })?.ts ?? 0
        let limit = 100
        let request = MessageFetchRequest(channel: channel, since: lastTs > 0 ? lastTs : nil, limit: limit)
        s.emitWithAck(SocketEvent.messagesFetch.rawValue, SocketPayloadEncoder.encode(request)).timingOut(after: 9) { [weak self] data in
            guard let dict = data.first as? [String: Any],
                  let list = dict["list"] as? [[String: Any]] else { return }
            let incoming = Self.parseMessages(list, context: "syncHistory:\(channel.rawValue)")
            Task { @MainActor in
                guard let self else { return }
                self.upsertBatch(incoming, in: channel)
                if channel == .couple { self.markRead(.couple) }
                if lastTs > 0, incoming.count >= limit {
                    self.syncHistory(channel, roundsLeft: roundsLeft - 1)
                }
            }
        }
    }

    func isLoadingOlder(_ channel: ChatChannel) -> Bool {
        loadingOlderChannels.contains(channel.rawValue)
    }

    func isLoadingNewer(_ channel: ChatChannel) -> Bool {
        loadingNewerChannels.contains(channel.rawValue)
    }

    func loadOlderAsync(_ channel: ChatChannel = .couple) async {
        guard let first = messages(for: channel).first else { return }
        guard !loadingOlderChannels.contains(channel.rawValue) else { return }
        if let last = lastLoadOlderAt[channel.rawValue], Date().timeIntervalSince(last) < 0.45 { return }
        lastLoadOlderAt[channel.rawValue] = Date()
        loadingOlderChannels.insert(channel.rawValue)
        let limit = 22
        let firstTs = first.ts

        let localOlder = await Task.detached(priority: .utility) {
            ChatLocalDatabase.shared.fetchMessages(channel: channel.rawValue, beforeTimestamp: firstTs, limit: limit)
        }.value
        if !localOlder.isEmpty {
            updateMessages(channel) { current in
                let known = Set(current.map(\.id))
                current.insert(contentsOf: localOlder.filter { !known.contains($0.id) }, at: 0)
            }
            loadingOlderChannels.remove(channel.rawValue)
            return
        }
        guard let s = socketProvider?.socket, socketProvider?.isConnected == true else {
            loadingOlderChannels.remove(channel.rawValue)
            return
        }
        let older: [ChatMessage] = await withCheckedContinuation { continuation in
            s.emitWithAck(
                SocketEvent.messagesFetch.rawValue,
                SocketPayloadEncoder.encode(MessageFetchRequest(channel: channel, before: firstTs, limit: limit)))
                .timingOut(after: 9) { data in
                    guard let dict = data.first as? [String: Any],
                          let list = dict["list"] as? [[String: Any]] else {
                        continuation.resume(returning: [])
                        return
                    }
                    continuation.resume(returning: Self.parseMessages(list, context: "loadOlder:\(channel.rawValue)"))
                }
        }
        defer { loadingOlderChannels.remove(channel.rawValue) }
        guard !older.isEmpty else { return }
        await Task.detached(priority: .utility) {
            for msg in older { ChatLocalDatabase.shared.insertMessage(msg) }
        }.value
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

        let localNewer = await Task.detached(priority: .utility) {
            ChatLocalDatabase.shared.fetchMessages(
                channel: channel.rawValue, fromInclusive: lastTs + 0.001,
                toExclusive: Double.greatestFiniteMagnitude, limit: limit)
        }.value
        if !localNewer.isEmpty {
            updateMessages(channel) { current in
                let known = Set(current.map(\.id))
                current.append(contentsOf: localNewer.filter { !known.contains($0.id) })
            }
            loadingNewerChannels.remove(channel.rawValue)
            return
        }
        guard let s = socketProvider?.socket, socketProvider?.isConnected == true else {
            loadingNewerChannels.remove(channel.rawValue)
            return
        }
        let newer: [ChatMessage] = await withCheckedContinuation { continuation in
            s.emitWithAck(
                SocketEvent.messagesFetch.rawValue,
                SocketPayloadEncoder.encode(MessageFetchRequest(channel: channel, since: lastTs, limit: limit)))
                .timingOut(after: 9) { data in
                    guard let dict = data.first as? [String: Any],
                          let list = dict["list"] as? [[String: Any]] else {
                        continuation.resume(returning: [])
                        return
                    }
                    continuation.resume(returning: Self.parseMessages(list, context: "loadNewer:\(channel.rawValue)"))
                }
        }
        defer { loadingNewerChannels.remove(channel.rawValue) }
        guard !newer.isEmpty else { return }
        await Task.detached(priority: .utility) {
            for msg in newer { ChatLocalDatabase.shared.insertMessage(msg) }
        }.value
        updateMessages(channel) { current in
            let known = Set(current.map(\.id))
            current.append(contentsOf: newer.filter { !known.contains($0.id) })
        }
    }

    // MARK: - 发送

    func sendText(_ text: String, channel: ChatChannel = .couple,
                  replyTo: String? = nil, replyPreview: String? = nil,
                  session: Session) {
        let clientId = "tmp-" + UUID().uuidString
        let optimistic = ChatMessage(optimisticText: text, me: session, clientId: clientId,
                                     channel: channel.rawValue, replyTo: replyTo, replyPreview: replyPreview)
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
            lastError: nil)
        guard ChatLocalDatabase.shared.upsertPendingOutbound(item) else {
            markPendingFailed(clientId: clientId, channel: channel, error: "本地保存失败")
            return
        }
        flushOutbox(session: session)
    }

    func sendMedia(data: Data, mimeType: String, preferredType: String, localPreviewURL: URL?,
                   channel: ChatChannel = .couple, displayText: String? = nil, session: Session) {
        let clientId = "tmp-" + UUID().uuidString
        let outgoingText = displayText ?? Self.mediaPlaceholderText(for: preferredType)
        let createdAt = Date().timeIntervalSince1970 * 1000
        let durableURL = persistOutboundMedia(
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
        guard ChatLocalDatabase.shared.upsertPendingOutbound(item) else {
            try? FileManager.default.removeItem(at: durableURL)
            markPendingFailed(clientId: clientId, channel: channel, error: "本地保存失败")
            return
        }
        flushOutbox(session: session)
    }

    func sendSticker(url: String, channel: ChatChannel = .couple, session: Session) {
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
        guard ChatLocalDatabase.shared.upsertPendingOutbound(item) else {
            markPendingFailed(clientId: clientId, channel: channel, error: "本地保存失败")
            return
        }
        flushOutbox(session: session)
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

    func resend(_ message: ChatMessage, session: Session) {
        guard message.failed else { return }
        let channel = ChatChannel(rawValue: message.channel) ?? .couple
        if var pending = ChatLocalDatabase.shared.pendingOutbound(clientId: message.id) {
            pending.lastError = nil
            pending.attempts = 0
            _ = ChatLocalDatabase.shared.upsertPendingOutbound(pending)
            markPendingSending(clientId: message.id, channel: channel)
            flushOutbox(session: session)
        } else if message.type == "text" {
            updateMessages(channel) { $0.removeAll { $0.id == message.id } }
            sendText(message.text, channel: channel, session: session)
        }
    }

    func hasPendingMedia(_ message: ChatMessage) -> Bool {
        ChatLocalDatabase.shared.pendingOutbound(clientId: message.id)?.isMedia == true
    }

    // MARK: - 已读

    func markRead(_ channel: ChatChannel = .couple) {
        guard let s = socketProvider?.socket, socketProvider?.isConnected == true,
              let lastTs = messages(for: channel).last(where: { !$0.pending })?.ts else { return }
        s.emit(SocketEvent.read.rawValue, SocketPayloadEncoder.encode(ReadReceiptRequest(channel: channel, ts: lastTs)))
    }

    func partnerHasRead(_ msg: ChatMessage, username: String?) -> Bool {
        guard msg.channel == ChatChannel.couple.rawValue, let me = username else { return false }
        let partnerTs = readState(for: .couple).first(where: { $0.key != me })?.value ?? 0
        if partnerTs <= 0, msg.sender == me, !msg.pending, !msg.failed, msg.ts < storeStartedAtMs - 60_000 {
            return true
        }
        return msg.ts <= partnerTs
    }

    func readState(for channel: ChatChannel) -> [String: Double] {
        readStates[channel.rawValue] ?? [:]
    }

    func setReadState(_ channel: ChatChannel, state: [String: Double]) {
        var next = readStates
        next[channel.rawValue] = state
        readStates = next
        for (user, ts) in state {
            ChatLocalDatabase.shared.saveReadReceipt(channel: channel.rawValue, username: user, ts: ts, updatedAt: Date().timeIntervalSince1970 * 1000)
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
        updateMessages(channel) { list in
            guard let i = list.firstIndex(where: { $0.id == message.id }) else { return }
            var m = list[i]
            m.recalledText = m.text
            m.kind = "system"
            m.type = "text"
            m.url = nil
            m.text = "你撤回了一条消息"
            list[i] = m
            ChatLocalDatabase.shared.insertMessage(m)
        }
        s.emitWithAck(
            SocketEvent.messageRecall.rawValue,
            SocketPayloadEncoder.encode(MessageRecallRequest(id: message.id))).timingOut(after: 9) { _ in }
    }

    func applyRecall(id: String, byName: String?, channel: ChatChannel?, myUsername: String?) {
        let channels = channel.map { [$0] } ?? ChatChannel.allCases
        for c in channels {
            updateMessages(c) { list in
                guard let i = list.firstIndex(where: { $0.id == id }) else { return }
                var m = list[i]
                let mine = m.sender == myUsername
                if m.recalledText == nil { m.recalledText = m.text }
                m.kind = "system"
                m.type = "text"
                m.url = nil
                m.text = mine ? "你撤回了一条消息" : "\(byName ?? "对方")撤回了一条消息"
                list[i] = m
                ChatLocalDatabase.shared.insertMessage(m)
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
                ChatLocalDatabase.shared.insertMessage(m)
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
        let local = ChatLocalDatabase.shared.searchMessages(query: q, channel: channel.rawValue)
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
                    continuation.resume(returning: Self.mergeSearchResults(remote, local))
                }
        }
    }

    func mediaMessages(for channel: ChatChannel, includeFiles: Bool = false, limit: Int? = nil) -> [ChatMessage] {
        let types = includeFiles ? Self.managedAttachmentTypes : Self.mediaTypes
        return ChatLocalDatabase.shared.mediaMessages(channel: channel.rawValue, types: types, limit: limit)
    }

    func mediaItemCount(for channel: ChatChannel, includeFiles: Bool = false) -> Int {
        let types = includeFiles ? Self.managedAttachmentTypes : Self.mediaTypes
        return ChatLocalDatabase.shared.mediaCount(channel: channel.rawValue, types: types)
    }

    // MARK: - 全量同步

    @discardableResult
    func syncAllHistory(
        _ channel: ChatChannel,
        onProgress: @escaping (_ localCount: Int, _ remoteTotal: Int?) -> Void
    ) async -> HistorySyncResult {
        guard let s = socketProvider?.socket, socketProvider?.isConnected == true else {
            return HistorySyncResult(
                localCount: ChatLocalDatabase.shared.messageCount(channel: channel.rawValue),
                remoteTotal: nil, downloaded: 0, completed: false, error: "当前未连接服务器")
        }
        // 以数据库最早记录作为断点，而不是内存中最近 50 条；重启后会从上次位置继续。
        var oldest = ChatLocalDatabase.shared.oldestMessageTimestamp(channel: channel.rawValue)
        var localCount = ChatLocalDatabase.shared.messageCount(channel: channel.rawValue)
        var remoteTotal: Int?
        var downloaded = 0
        var completed = false
        var lastError: String?
        let pageLimit = 300
        onProgress(localCount, nil)
        while !Task.isCancelled {
            let page: HistoryPage = await withCheckedContinuation { cont in
                let request = MessageFetchRequest(channel: channel, before: oldest, limit: pageLimit)
                s.emitWithAck(SocketEvent.messagesFetch.rawValue, SocketPayloadEncoder.encode(request)).timingOut(after: 15) { data in
                    guard let dict = data.first as? [String: Any],
                           let list = dict["list"] as? [[String: Any]] else {
                        let message = (data.first as? [String: Any])?["error"] as? String ?? "服务器响应超时"
                        cont.resume(returning: HistoryPage(messages: [], total: nil, error: message))
                        return
                    }
                    let total = (dict["total"] as? NSNumber)?.intValue ?? dict["total"] as? Int
                    cont.resume(returning: HistoryPage(
                        messages: Self.parseMessages(list, context: "syncAll:\(channel.rawValue)"),
                        total: total,
                        error: nil))
                }
            }
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
            guard ChatLocalDatabase.shared.insertMessages(batch) == batch.count else {
                lastError = "写入本地数据库失败"
                break
            }
            downloaded += batch.count
            localCount = ChatLocalDatabase.shared.messageCount(channel: channel.rawValue)
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
        let latest = ChatLocalDatabase.shared.fetchLatestMessages(channel: channel.rawValue, limit: 50)
        if !latest.isEmpty { updateMessages(channel) { $0 = latest } }
        localCount = ChatLocalDatabase.shared.messageCount(channel: channel.rawValue)
        if let remoteTotal, localCount >= remoteTotal { completed = true }
        return HistorySyncResult(
            localCount: localCount, remoteTotal: remoteTotal, downloaded: downloaded,
            completed: completed && lastError == nil, error: lastError)
    }

    func clearLocalHistory() {
        ChatLocalDatabase.shared.deleteMessages()
        messagesByChannel = [:]
    }

    // MARK: - 私有辅助

    /// 连接建立后按创建时间串行重放。服务端以 clientId 幂等，ACK 丢失也不会生成重复消息。
    func flushOutbox(session: Session) {
        guard socketProvider?.isConnected == true,
              socketProvider?.socket != nil else { return }
        if flushingOutbox {
            outboxFlushRequested = true
            return
        }
        flushingOutbox = true
        outboxFlushRequested = false
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.flushingOutbox = false
                if self.outboxFlushRequested {
                    self.outboxFlushRequested = false
                    self.flushOutbox(session: session)
                }
            }
            for item in ChatLocalDatabase.shared.loadPendingOutbounds() {
                guard self.socketProvider?.isConnected == true else { break }
                let channel = ChatChannel(rawValue: item.channel) ?? .couple
                self.markPendingSending(clientId: item.clientId, channel: channel)
                let sent = await self.transmitPendingOutbound(item, session: session)
                if !sent, self.socketProvider?.isConnected != true { break }
            }
        }
    }

    private func transmitPendingOutbound(_ original: PendingOutboundMessage, session: Session) async -> Bool {
        guard let socket = socketProvider?.socket, socketProvider?.isConnected == true else { return false }
        var item = original
        let channel = ChatChannel(rawValue: item.channel) ?? .couple

        if item.isMedia, item.uploadId == nil {
            guard let path = item.localFilePath,
                  let mimeType = item.mimeType,
                  FileManager.default.fileExists(atPath: path) else {
                recordPendingFailure(item, channel: channel, message: "本地媒体文件不可用")
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
                _ = ChatLocalDatabase.shared.upsertPendingOutbound(item)

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
                recordPendingFailure(item, channel: channel, message: error.localizedDescription)
                return false
            }
        }

        let request = MessageSendRequest(
            channel: channel,
            type: item.type,
            text: item.text,
            url: item.uploadURL,
            uploadId: item.uploadId,
            replyTo: item.replyTo,
            replyPreview: item.replyPreview,
            clientId: item.clientId)
        let ack: [Any] = await withCheckedContinuation { continuation in
            socket.emitWithAck(SocketEvent.messageSend.rawValue, SocketPayloadEncoder.encode(request))
                .timingOut(after: 15) { continuation.resume(returning: $0) }
        }
        let succeeded = handleSendAck(ack, clientId: item.clientId, channel: channel)
        if succeeded {
            completePendingOutbound(clientId: item.clientId)
        } else {
            let error = (ack.first as? [String: Any])?["error"] as? String ?? "发送确认超时"
            recordPendingFailure(item, channel: channel, message: error)
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
        print("[MessageStore] ⚠️ 待发消息失败 clientId=\(clientId): \(error)")
    }

    private func recordPendingFailure(_ original: PendingOutboundMessage, channel: ChatChannel, message: String) {
        var item = ChatLocalDatabase.shared.pendingOutbound(clientId: original.clientId) ?? original
        item.attempts += 1
        item.lastError = message
        _ = ChatLocalDatabase.shared.upsertPendingOutbound(item)
        markPendingFailed(clientId: item.clientId, channel: channel, error: message)
    }

    private func completePendingOutbound(clientId: String) {
        if let item = ChatLocalDatabase.shared.pendingOutbound(clientId: clientId),
           let path = item.localFilePath {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
        }
        ChatLocalDatabase.shared.deletePendingOutbound(clientId: clientId)
    }

    private func persistOutboundMedia(data: Data, mimeType: String, clientId: String, username: String) -> URL? {
        guard data.count <= 50 * 1024 * 1024,
              let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let safeUsername = username
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let directory = applicationSupport
            .appendingPathComponent("ChatOutboxMedia", isDirectory: true)
            .appendingPathComponent(safeUsername, isDirectory: true)
        let ext: String
        if mimeType.contains("png") { ext = "png" }
        else if mimeType.contains("gif") { ext = "gif" }
        else if mimeType.contains("webp") { ext = "webp" }
        else if mimeType.contains("video") { ext = "mp4" }
        else if mimeType.contains("audio") { ext = "m4a" }
        else if mimeType.contains("pdf") { ext = "pdf" }
        else { ext = "jpg" }
        let url = directory.appendingPathComponent(clientId).appendingPathExtension(ext)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = url
            try? mutableURL.setResourceValues(values)
            return url
        } catch {
            return nil
        }
    }

    @discardableResult
    private func handleSendAck(_ data: [Any], clientId: String, channel: ChatChannel) -> Bool {
        let succeeded = (data.first as? [String: Any])?["ok"] as? Bool == true
        let acknowledgedMessage: ChatMessage? = {
            guard let dict = data.first as? [String: Any],
                  let message = dict["message"] as? [String: Any] else { return nil }
            return Self.parseMessage(message, context: "message:send ack")
        }()
        updateMessages(channel) { list in
            guard let i = list.firstIndex(where: { $0.id == clientId }) else { return }
            if let dict = data.first as? [String: Any],
               dict["ok"] as? Bool == true, let realId = dict["id"] as? String {
                if let acknowledgedMessage {
                    list[i] = acknowledgedMessage
                    ChatLocalDatabase.shared.insertMessage(acknowledgedMessage)
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
                ChatLocalDatabase.shared.insertMessage(list[i])
            } else {
                list[i].pending = false
                list[i].failed = true
            }
        }
        return succeeded
    }

    func uploadMedia(
        data: Data,
        mimeType: String,
        purpose: UploadPurpose = .message,
        session: Session
    ) async throws -> UploadResult {
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: Self.uploadURL(purpose: purpose))
        req.httpMethod = "POST"
        req.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.multipartBody(data: data, mimeType: mimeType, boundary: boundary)
        let (responseData, response) = try await httpClient.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: responseData))?["error"]
            throw NSError(domain: "upload", code: 1, userInfo: [NSLocalizedDescriptionKey: msg ?? "上传失败"])
        }
        return try JSONDecoder().decode(UploadResult.self, from: responseData)
    }

    private func uploadMedia(
        fileURL: URL,
        mimeType: String,
        purpose: UploadPurpose,
        session: Session
    ) async throws -> UploadResult {
        let boundary = "Boundary-\(UUID().uuidString)"
        let multipartURL = try Self.makeMultipartFile(mediaURL: fileURL, mimeType: mimeType, boundary: boundary)
        defer { try? FileManager.default.removeItem(at: multipartURL) }
        var req = URLRequest(url: Self.uploadURL(purpose: purpose))
        req.httpMethod = "POST"
        req.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (responseData, response) = try await httpClient.upload(for: req, fromFile: multipartURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: responseData))?["error"]
            throw NSError(domain: "upload", code: 1, userInfo: [NSLocalizedDescriptionKey: msg ?? "上传失败"])
        }
        return try JSONDecoder().decode(UploadResult.self, from: responseData)
    }

    struct UploadResult: Decodable {
        let id: String
        let url: String
        let type: String
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
        var body = Data()
        let filename: String
        if mimeType.contains("video") { filename = "media.mp4" }
        else if mimeType.contains("audio") { filename = "media.m4a" }
        else { filename = "media.jpg" }
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n")
        return body
    }

    private static func uploadURL(purpose: UploadPurpose) -> URL {
        let base = ServerConfig.baseURL.appendingPathComponent("api/upload")
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "purpose", value: purpose.rawValue)]
        return components?.url ?? base
    }

    /// 在临时文件中拼 multipart，按块复制媒体内容，避免大视频在内存中再复制一份。
    private static func makeMultipartFile(mediaURL: URL, mimeType: String, boundary: String) throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("multipart-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            throw NSError(domain: "upload", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法创建上传临时文件"])
        }
        let input = try FileHandle(forReadingFrom: mediaURL)
        let output = try FileHandle(forWritingTo: outputURL)
        do {
            let filename = mediaURL.lastPathComponent
            let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n"
            try output.write(contentsOf: Data(header.utf8))
            while let chunk = try input.read(upToCount: 512 * 1024), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            try input.close()
            try output.close()
            return outputURL
        } catch {
            try? input.close()
            try? output.close()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    nonisolated static func mergeSearchResults(_ first: [ChatMessage], _ second: [ChatMessage]) -> [ChatMessage] {
        var seen = Set<String>()
        return (first + second)
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.ts > $1.ts }
    }

    nonisolated static func mergedWindow(_ window: [ChatMessage], with current: [ChatMessage], around targetId: String) -> [ChatMessage] {
        guard !window.isEmpty else { return current }
        var seen = Set<String>()
        let merged = (window + current)
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.ts < $1.ts }
        guard let targetIndex = merged.firstIndex(where: { $0.id == targetId }) else {
            return Array(merged.suffix(90))
        }
        let lower = max(0, targetIndex - 36)
        let upper = min(merged.count, targetIndex + 42)
        return Array(merged[lower..<upper])
    }

    nonisolated static func dayRange(for date: Date) -> (start: Double, end: Double) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let start = cal.startOfDay(for: date)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return (start.timeIntervalSince1970 * 1000, end.timeIntervalSince1970 * 1000)
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(contentsOf: string.utf8)
    }
}
