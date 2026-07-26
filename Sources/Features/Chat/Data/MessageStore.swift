import Foundation
import SocketIO
import UIKit

private final class MessageAckContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[Any], Never>?

    init(_ continuation: CheckedContinuation<[Any], Never>) {
        self.continuation = continuation
    }

    func resume(returning value: [Any]) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
    }
}

private struct MessageSessionFence: Equatable {
    let token: String
    let username: String
    let generation: UInt64
    let persistenceScope: ChatPersistenceScope?
}

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
    typealias HistorySyncResult = MessageHistorySyncResult

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

    nonisolated static func parseSendAckMessage(
        _ payload: [String: Any],
        expectedChannel: ChatChannel
    ) -> ChatMessage? {
        guard let dictionary = payload["message"] as? [String: Any],
              let message = parseMessage(dictionary, context: "message:send ack"),
              message.channel == expectedChannel.rawValue else { return nil }
        return message
    }

    private var lastLoadOlderAt: [String: Date] = [:]
    private var lastLoadNewerAt: [String: Date] = [:]
    private let persistence: any ChatPersistenceProtocol
    private let remoteDataSource: ChatRemoteDataSource
    private let historySyncService: MessageHistorySyncService
    private let mediaUploadService: MediaUploadService
    private let outboxProcessor: OutboxProcessor
    private let readReceiptCoordinator = ReadReceiptCoordinator()
    private var activeSessionFence: MessageSessionFence?

    private static let mediaTypes = ["image", "video"]
    private static let managedAttachmentTypes = ["image", "video", "file"]
    private static let maxAutomaticSendAttempts = 3
    private static let sendAckTimeout: TimeInterval = 12
    private static let sendAckHardTimeout: TimeInterval = 13

    weak var socketProvider: SocketProvider?

    init(
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        persistence: any ChatPersistenceProtocol = ChatPersistence.shared,
        timelineStore: ChatTimelineStore? = nil
    ) {
        self.persistence = persistence
        self.timelineStore = timelineStore ?? ChatTimelineStore()
        let remoteDataSource = ChatRemoteDataSource(httpClient: httpClient)
        self.remoteDataSource = remoteDataSource
        historySyncService = MessageHistorySyncService(
            persistence: persistence,
            remoteDataSource: remoteDataSource)
        mediaUploadService = MediaUploadService(httpClient: httpClient)
        outboxProcessor = OutboxProcessor(persistence: persistence)
    }

    func activateSession(
        _ session: Session,
        generation: UInt64,
        persistenceScope: ChatPersistenceScope?
    ) {
        activeSessionFence = MessageSessionFence(
            token: session.token,
            username: session.username,
            generation: generation,
            persistenceScope: persistenceScope)
    }

    func deactivateSession() {
        activeSessionFence = nil
        readReceiptCoordinator.reset()
        confirmationRequestsInFlight.removeAll()
        optimisticRecalls.removeAll()
        recallDrafts.removeAll()
    }

    func latestConfirmedCursors() -> [String: MessageSearchCursor] {
        var cursors: [String: MessageSearchCursor] = [:]
        for channel in ChatChannel.allCases {
            guard let latest = messages(for: channel)
                .filter({ !$0.pending && !$0.failed })
                .max(by: { ChatMessageCollection.isOrderedBefore($0, $1) })
            else { continue }
            cursors[channel.rawValue] = MessageSearchCursor(ts: latest.ts, id: latest.id)
        }
        return cursors
    }

    private func sessionFence(for session: Session) -> MessageSessionFence? {
        guard let fence = activeSessionFence,
              fence.token == session.token,
              fence.username == session.username else { return nil }
        return fence
    }

    private func isCurrent(_ fence: MessageSessionFence) -> Bool {
        activeSessionFence == fence
    }

    private func currentPersistenceContext() -> (
        fence: MessageSessionFence,
        scope: ChatPersistenceScope
    )? {
        guard let fence = activeSessionFence,
              let scope = fence.persistenceScope else { return nil }
        return (fence, scope)
    }

    // MARK: - 消息读写

    func messages(for channel: ChatChannel) -> [ChatMessage] {
        timelineStore.messages(for: channel)
    }

    func updateMessages(_ channel: ChatChannel, _ transform: (inout [ChatMessage]) -> Void) {
        timelineStore.updateMessages(channel, transform)
    }

    func upsert(_ msg: ChatMessage, in channel: ChatChannel) {
        guard msg.channel == channel.rawValue else {
            print("[MessageStore] ⚠️ 拒绝路由到不匹配频道的消息 id=\(msg.id)")
            return
        }
        guard let fence = activeSessionFence else {
            print("[MessageStore] ⚠️ 会话未激活，丢弃实时消息 id=\(msg.id) channel=\(channel.rawValue)")
            return
        }
        let latestConfirmed = messages(for: channel)
            .filter { !$0.pending && !$0.failed }
            .max(by: { ChatMessageCollection.isOrderedBefore($0, $1) })
        let shouldUpdateLatest = !msg.pending && !msg.failed
            && latestConfirmed.map {
                $0.id == msg.id || ChatMessageCollection.isOrderedBefore($0, msg)
            } != false
        if let scope = fence.persistenceScope {
            Task {
                guard self.isCurrent(fence),
                      await persistence.insertMessage(msg, scope: scope),
                      self.isCurrent(fence) else {
                    print("[MessageStore] ⚠️ 消息写入本地数据库失败 id=\(msg.id)")
                    return
                }
                if shouldUpdateLatest {
                    latestPersistedMessageIDs[channel.rawValue] = msg.id
                }
                if !msg.pending, !msg.failed, let clientId = msg.clientId {
                    await completePendingOutbound(
                        clientId: clientId,
                        scope: scope,
                        fence: fence)
                }
            }
        } else {
            print("[MessageStore] ⚠️ 本地数据库不可用，仅在当前会话展示消息 id=\(msg.id)")
        }
        updateMessages(channel) { list in
            ChatMessageCollection.upsert(msg, into: &list)
        }
    }

    @discardableResult
    func upsertBatch(_ msgs: [ChatMessage], in channel: ChatChannel) async -> Bool {
        guard !msgs.isEmpty else { return true }
        guard msgs.allSatisfy({ $0.channel == channel.rawValue }) else {
            print("[MessageStore] ⚠️ 拒绝包含频道不匹配消息的批次 channel=\(channel.rawValue)")
            return false
        }
        guard let fence = activeSessionFence,
              let scope = fence.persistenceScope else { return false }
        let persisted = await persistence.insertMessages(msgs, scope: scope)
        guard persisted == msgs.count, isCurrent(fence) else {
            print("[MessageStore] ⚠️ 批量消息写入失败 channel=\(channel.rawValue)")
            return false
        }
        for msg in msgs {
            if !msg.pending, !msg.failed, let clientId = msg.clientId {
                await completePendingOutbound(
                    clientId: clientId,
                    scope: scope,
                    fence: fence)
            }
        }
        guard isCurrent(fence) else { return false }
        updateMessages(channel) { list in
            ChatMessageCollection.upsert(msgs, into: &list)
        }
        return true
    }

    // MARK: - 本地缓存

    func restoreLocalCache(for session: Session) async {
        guard let fence = sessionFence(for: session),
              let scope = fence.persistenceScope else { return }
        guard let couple = await persistence.fetchLatestMessages(
            channel: ChatChannel.couple.rawValue,
            limit: 50,
            scope: scope
        ), isCurrent(fence) else { return }
        guard let ai = await persistence.fetchLatestMessages(
            channel: ChatChannel.ai.rawValue,
            limit: 50,
            scope: scope
        ), isCurrent(fence) else { return }
        guard let coupleRead = await persistence.loadReadReceipts(
            channel: ChatChannel.couple.rawValue,
            scope: scope
        ), isCurrent(fence) else { return }
        guard let aiRead = await persistence.loadReadReceipts(
            channel: ChatChannel.ai.rawValue,
            scope: scope
        ), isCurrent(fence) else { return }
        let cachedMessages = [
            ChatChannel.couple.rawValue: couple,
            ChatChannel.ai.rawValue: ai,
        ]
        var restored = cachedMessages
        await reconcilePendingOutbounds(
            with: cachedMessages.values.flatMap { $0 },
            scope: scope,
            fence: fence)
        guard isCurrent(fence),
              let pending = await outboxProcessor.allPending(scope: scope),
              isCurrent(fence) else { return }
        for item in pending {
            guard let channel = ChatChannel(rawValue: item.channel) else {
                print("[MessageStore] ⚠️ 隔离未知频道待发消息 clientId=\(item.clientId)")
                continue
            }
            var list = restored[channel.rawValue] ?? []
            ChatMessageCollection.upsert(
                item.optimisticMessage(session: session, waitingToSend: true),
                into: &list)
            restored[channel.rawValue] = list
        }
        guard isCurrent(fence) else { return }
        messagesByChannel = restored
        readStates = [
            ChatChannel.couple.rawValue: coupleRead,
            ChatChannel.ai.rawValue: aiRead,
        ]
        latestPersistedMessageIDs = cachedMessages.compactMapValues { $0.last?.id }
    }

    func applyBootstrap(
        _ snapshot: AppBootstrapSnapshot,
        session: Session,
        recoveryCursors: [String: MessageSearchCursor] = [:]
    ) async {
        guard let fence = sessionFence(for: session) else { return }
        let scope = fence.persistenceScope
        let remote = snapshot.messagesByChannel
        let receipts = snapshot.readStates
        var persistedRemoteMessages: [ChatMessage] = []
        var remoteLatestPersistedIDs: [String: String] = [:]
        for channel in ChatChannel.allCases {
            let rawChannel = channel.rawValue
            let messages = remote[rawChannel] ?? []
            guard !messages.isEmpty else { continue }
            if let scope {
                let persisted = await persistence.insertMessages(messages, scope: scope)
                guard isCurrent(fence) else { return }
                guard persisted == messages.count else {
                    print("[MessageStore] ⚠️ bootstrap 消息写入失败 channel=\(rawChannel)")
                    continue
                }
                persistedRemoteMessages.append(contentsOf: messages)
                remoteLatestPersistedIDs[rawChannel] = messages.last?.id
            }
        }
        if let scope {
            let now = Date().timeIntervalSince1970 * 1000
            for (channel, state) in receipts {
                for (username, ts) in state {
                    _ = await persistence.saveReadReceipt(
                        channel: channel,
                        username: username,
                        ts: ts,
                        updatedAt: now,
                        scope: scope)
                    guard isCurrent(fence) else { return }
                }
            }
            await reconcilePendingOutbounds(
                with: persistedRemoteMessages,
                scope: scope,
                fence: fence)
            guard isCurrent(fence) else { return }
        }

        var next = messagesByChannel
        for channel in ChatChannel.allCases {
            var list = next[channel.rawValue] ?? []
            ChatMessageCollection.upsert(remote[channel.rawValue] ?? [], into: &list)
            next[channel.rawValue] = list
        }
        if let scope {
            guard let pending = await outboxProcessor.allPending(scope: scope),
                  isCurrent(fence) else { return }
            for item in pending {
                guard let channel = ChatChannel(rawValue: item.channel) else {
                    print("[MessageStore] ⚠️ 隔离未知频道待发消息 clientId=\(item.clientId)")
                    continue
                }
                var list = next[channel.rawValue] ?? []
                ChatMessageCollection.upsert(
                    item.optimisticMessage(session: session, waitingToSend: true),
                    into: &list)
                next[channel.rawValue] = list
            }
        }

        var mergedReadStates = readStates
        for (channel, state) in receipts {
            var merged = mergedReadStates[channel] ?? [:]
            for (username, ts) in state {
                merged[username] = max(merged[username] ?? 0, ts)
            }
            mergedReadStates[channel] = merged
        }
        var persistedLatestIDs = latestPersistedMessageIDs
        for channel in ChatChannel.allCases {
            let rawChannel = channel.rawValue
            let candidates = [
                persistedLatestIDs[rawChannel],
                remoteLatestPersistedIDs[rawChannel],
            ].compactMap { $0 }
            let list = next[rawChannel] ?? []
            persistedLatestIDs[rawChannel] = list
                .filter { candidates.contains($0.id) }
                .max(by: { ChatMessageCollection.isOrderedBefore($0, $1) })?
                .id
        }
        guard isCurrent(fence) else { return }
        messagesByChannel = next
        readStates = mergedReadStates
        latestPersistedMessageIDs = persistedLatestIDs

        await recoverBootstrapGaps(
            after: recoveryCursors,
            session: session,
            fence: fence)
    }

    private func recoverBootstrapGaps(
        after recoveryCursors: [String: MessageSearchCursor],
        session: Session,
        fence: MessageSessionFence
    ) async {
        guard let scope = fence.persistenceScope else { return }
        let pageLimit = 300
        for channel in ChatChannel.allCases {
            guard var cursor = recoveryCursors[channel.rawValue] else { continue }
            while !Task.isCancelled, isCurrent(fence) {
                let page = await remoteDataSource.fetchNewerPage(
                    channel: channel,
                    since: cursor.ts,
                    sinceId: cursor.id,
                    limit: pageLimit,
                    session: session)
                guard isCurrent(fence), page.error == nil else { break }
                guard !page.messages.isEmpty else { break }
                guard await persistence.insertMessages(
                    page.messages,
                    scope: scope
                ) == page.messages.count, isCurrent(fence) else {
                    print("[MessageStore] ⚠️ bootstrap 增量补洞写入失败 channel=\(channel.rawValue)")
                    break
                }
                for message in page.messages {
                    if let clientId = message.clientId {
                        await completePendingOutbound(
                            clientId: clientId,
                            scope: scope,
                            fence: fence)
                    }
                }
                guard isCurrent(fence),
                      let latest = page.messages.max(
                        by: { ChatMessageCollection.isOrderedBefore($0, $1) }),
                      latest.ts > cursor.ts || (latest.ts == cursor.ts && latest.id > cursor.id)
                else { break }
                updateMessages(channel) { current in
                    ChatMessageCollection.upsert(page.messages, into: &current)
                }
                latestPersistedMessageIDs[channel.rawValue] = latest.id
                cursor = MessageSearchCursor(ts: latest.ts, id: latest.id)
                if page.messages.count < pageLimit { break }
            }
        }
    }

    // MARK: - 搜索跳转

    @discardableResult
    func ensureMessageLoaded(_ target: ChatMessage, channel: ChatChannel) async -> Bool {
        guard let context = currentPersistenceContext(),
              var window = await persistence.fetchMessagesAround(
                channel: channel.rawValue,
                centerTimestamp: target.ts,
                beforeLimit: 40,
                afterLimit: 60,
                scope: context.scope
              ),
              isCurrent(context.fence) else { return false }
        // 即使命中消息已经在内存，也必须重建它附近的连续窗口。此前的直接返回
        // 会保留旧版搜索产生的「历史片段 + 最新片段」断层。
        if !window.contains(where: { $0.id == target.id }), socketProvider?.isConnected == true {
            let remote = await fetchRemoteMessages(
                MessagePageRequest(channel: channel, around: target.ts, limit: 100),
                context: "ensureMessageAround:\(channel.rawValue)")
            guard isCurrent(context.fence) else { return false }
            if !remote.isEmpty {
                let candidates = remote + [target]
                guard await persistence.insertMessages(
                    candidates,
                    scope: context.scope
                ) == candidates.count, isCurrent(context.fence) else {
                    print("[MessageStore] ⚠️ 搜索窗口写入本地数据库失败")
                    return false
                }
                guard let refreshed = await persistence.fetchMessagesAround(
                    channel: channel.rawValue,
                    centerTimestamp: target.ts,
                    beforeLimit: 40,
                    afterLimit: 60,
                    scope: context.scope
                ), isCurrent(context.fence) else { return false }
                window = refreshed
            }
        }
        if !window.contains(where: { $0.id == target.id }) {
            window.append(target)
            window.sort { $0.ts == $1.ts ? $0.id < $1.id : $0.ts < $1.ts }
        }
        updateMessages(channel) { list in
            list = ChatMessageWindowing.mergedWindow(window, with: list, around: target.id)
        }
        return messages(for: channel).contains(where: { $0.id == target.id })
    }

    func loadReferencedMessage(id: String, channel: ChatChannel) async -> ChatMessage? {
        if let loaded = messages(for: channel).first(where: { $0.id == id }) {
            return loaded
        }
        guard let context = currentPersistenceContext() else { return nil }
        let local = await persistence.fetchMessage(
            id: id,
            channel: channel.rawValue,
            scope: context.scope)
        guard isCurrent(context.fence) else { return nil }
        let target: ChatMessage?
        if let local {
            target = local
        } else if let session = socketProvider?.currentSession {
            target = await remoteDataSource.fetchMessage(id: id, channel: channel, session: session)
            guard isCurrent(context.fence) else { return nil }
        } else {
            target = nil
        }
        guard let target,
              await ensureMessageLoaded(target, channel: channel) else { return nil }
        return target
    }

    @discardableResult
    func ensureDateLoaded(_ date: Date, channel: ChatChannel) async -> ChatMessage? {
        guard let context = currentPersistenceContext() else { return nil }
        let range = ChatMessageWindowing.dayRange(for: date)
        guard var dayMessages = await persistence.fetchMessages(
            channel: channel.rawValue,
            fromInclusive: range.start,
            toExclusive: range.end,
            limit: 80,
            scope: context.scope
        ), isCurrent(context.fence) else { return nil }
        if dayMessages.isEmpty {
            let incoming = await fetchRemoteMessages(
                MessagePageRequest(channel: channel, after: range.start, before: range.end, limit: 80),
                context: "ensureDate:\(channel.rawValue)")
            guard !incoming.isEmpty else { return nil }
            guard await upsertBatch(incoming, in: channel) else { return nil }
            dayMessages = incoming
        }
        guard let target = dayMessages.first else { return nil }
        guard let nearby = await persistence.fetchMessagesAround(
            channel: channel.rawValue,
            centerTimestamp: target.ts,
            beforeLimit: 20,
            afterLimit: 44,
            scope: context.scope
        ), isCurrent(context.fence) else { return nil }
        if !nearby.isEmpty { dayMessages = nearby }
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
        guard let context = currentPersistenceContext(),
              let local = await persistence.fetchLatestMessages(
                channel: channel.rawValue,
                limit: 50,
                scope: context.scope
              ),
              isCurrent(context.fence) else { return }
        guard !local.isEmpty else { return }
        updateMessages(channel) { list in
            list = local
        }
    }

    /// 搜索跳转会把内存中的消息裁成目标附近的一小段。用户明确选择“回到最新”时，
    /// 必须重新加载最新窗口，不能只修改滚动状态，否则下一次刷新仍会回到历史窗口。
    func restoreLatestMessages(_ channel: ChatChannel) async {
        guard let context = currentPersistenceContext(),
              var latest = await persistence.fetchLatestMessages(
                channel: channel.rawValue,
                limit: 50,
                scope: context.scope
              ),
              isCurrent(context.fence) else { return }
        if latest.isEmpty, socketProvider?.isConnected == true {
            latest = await fetchRemoteMessages(
                MessagePageRequest(channel: channel, limit: 50),
                context: "restoreLatest:\(channel.rawValue)")
            guard isCurrent(context.fence) else { return }
            if !latest.isEmpty,
               await persistence.insertMessages(
                latest,
                scope: context.scope
               ) != latest.count {
                print("[MessageStore] ⚠️ 最新消息窗口写入本地数据库失败")
                return
            }
        }
        guard !latest.isEmpty else { return }
        let pendingOptimistic: [ChatMessage]
        if let session = socketProvider?.currentSession,
           let fence = sessionFence(for: session),
           let scope = fence.persistenceScope,
           let pending = await outboxProcessor.allPending(scope: scope),
           isCurrent(fence) {
            pendingOptimistic = pending
                .filter { $0.channel == channel.rawValue }
                .map { $0.optimisticMessage(session: session, waitingToSend: true) }
        } else {
            pendingOptimistic = []
        }
        updateMessages(channel) { current in
            current = ChatMessageWindowing.latestWindow(
                latest,
                preservingOutboundFrom: current + pendingOptimistic)
        }
        if let lastConfirmed = latest
            .filter({ !$0.pending && !$0.failed })
            .max(by: { ChatMessageCollection.isOrderedBefore($0, $1) }) {
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
        guard !list.isEmpty else { return true }
        // 只要当前窗口仍包含“发布前已知的最新持久消息”，随后追加的 pending、
        // ACK 或实时来信都属于同一个最新窗口。实时来信会先发布到 UI，再异步
        // 写 SQLite 并推进 latestID；若只允许尾部是 pending，这个短暂顺序会把
        // 已确认来信误判成历史窗口，导致它落到输入栏后面且不再自动恢复。
        return list.contains(where: { $0.id == latestID })
    }

    func loadOlderAsync(_ channel: ChatChannel = .couple) async {
        guard let first = messages(for: channel).first else { return }
        guard let context = currentPersistenceContext() else { return }
        guard !loadingOlderChannels.contains(channel.rawValue) else { return }
        if let last = lastLoadOlderAt[channel.rawValue], Date().timeIntervalSince(last) < 0.45 { return }
        lastLoadOlderAt[channel.rawValue] = Date()
        loadingOlderChannels.insert(channel.rawValue)
        defer { loadingOlderChannels.remove(channel.rawValue) }
        let limit = 22
        let firstTs = first.ts
        let firstId = first.id
        var attemptedCloudPage = false

        // 联网时云端页才是连续性的事实源。本地库可能因旧断点、系统中断或搜索
        // 按日期补取而存在孤立片段，直接取“本地下一条”会跨过整个缺口。
        if let session = socketProvider?.currentSession {
            attemptedCloudPage = true
            let page = await remoteDataSource.fetchHistoryPage(
                channel: channel,
                before: firstTs,
                beforeId: firstId,
                limit: limit,
                session: session)
            guard isCurrent(context.fence) else { return }
            if page.error == nil {
                guard !page.messages.isEmpty else { return }
                guard await persistence.insertMessages(
                    page.messages,
                    scope: context.scope
                ) == page.messages.count, isCurrent(context.fence) else {
                    print("[MessageStore] ⚠️ 较早消息页写入本地数据库失败")
                    return
                }
                updateMessages(channel) { current in
                    ChatMessageCollection.prependUnique(page.messages, to: &current)
                }
                return
            }
        }

        // 无网或云端请求失败时仍允许浏览已经保存到设备上的历史。
        guard let localOlder = await persistence.fetchMessages(
            channel: channel.rawValue,
            beforeTimestamp: firstTs,
            beforeId: firstId,
            limit: limit,
            scope: context.scope
        ), isCurrent(context.fence) else { return }
        if !localOlder.isEmpty {
            updateMessages(channel) { current in
                ChatMessageCollection.prependUnique(localOlder, to: &current)
            }
            return
        }
        guard !attemptedCloudPage else { return }
        let older = await fetchRemoteMessages(
            MessagePageRequest(channel: channel, before: firstTs, beforeId: firstId, limit: limit),
            context: "loadOlder:\(channel.rawValue)")
        guard isCurrent(context.fence) else { return }
        guard !older.isEmpty else { return }
        guard await persistence.insertMessages(
            older,
            scope: context.scope
        ) == older.count, isCurrent(context.fence) else {
            print("[MessageStore] ⚠️ 较早消息写入本地数据库失败")
            return
        }
        updateMessages(channel) { current in
            ChatMessageCollection.prependUnique(older, to: &current)
        }
    }

    func loadNewerAsync(_ channel: ChatChannel = .couple) async {
        guard let last = messages(for: channel).last else { return }
        guard let context = currentPersistenceContext() else { return }
        guard !loadingNewerChannels.contains(channel.rawValue) else { return }
        if let lastLoad = lastLoadNewerAt[channel.rawValue], Date().timeIntervalSince(lastLoad) < 0.45 { return }
        lastLoadNewerAt[channel.rawValue] = Date()
        loadingNewerChannels.insert(channel.rawValue)
        defer { loadingNewerChannels.remove(channel.rawValue) }
        let limit = 24
        let lastTs = last.ts
        let lastId = last.id

        // 搜索定位后的内存窗口可能与“本机安装后的近期缓存”之间隔着很长缺口。
        // 联网时必须先向云端请求紧邻当前尾部的下一页，不能让本地孤立片段把时间线
        // 直接跳到近期消息。
        if let session = socketProvider?.currentSession {
            let page = await remoteDataSource.fetchNewerPage(
                channel: channel,
                since: lastTs,
                sinceId: lastId,
                limit: limit,
                session: session)
            guard isCurrent(context.fence) else { return }
            if page.error == nil {
                guard !page.messages.isEmpty else { return }
                guard await persistence.insertMessages(
                    page.messages,
                    scope: context.scope
                ) == page.messages.count, isCurrent(context.fence) else {
                    print("[MessageStore] ⚠️ 较新消息页写入本地数据库失败")
                    return
                }
                updateMessages(channel) { current in
                    ChatMessageCollection.appendUnique(page.messages, to: &current)
                }
                return
            }
        }

        // 无网或云端请求失败时，仅浏览设备里已有的连续缓存。
        guard let localNewer = await persistence.fetchMessagesAfter(
            channel: channel.rawValue,
            afterTimestamp: lastTs,
            afterId: lastId,
            limit: limit,
            scope: context.scope
        ), isCurrent(context.fence) else { return }
        if !localNewer.isEmpty {
            updateMessages(channel) { current in
                ChatMessageCollection.appendUnique(localNewer, to: &current)
            }
            return
        }
    }

    // MARK: - 发送

    func sendText(_ text: String, channel: ChatChannel = .couple,
                  replyTo: String? = nil, replyPreview: String? = nil,
                  meta: ChatMessageMeta? = nil, session: Session) async {
        guard let fence = sessionFence(for: session),
              let scope = fence.persistenceScope else { return }
        let draft = PendingMessageFactory.text(
            text,
            channel: channel,
            replyTo: replyTo,
            replyPreview: replyPreview,
            meta: meta,
            session: session)
        guard await outboxProcessor.save(draft.outbound, scope: scope),
              isCurrent(fence) else { return }
        updateMessages(channel) { messages in
            ChatMessageCollection.upsert(draft.message, into: &messages)
        }
        await schedulePendingOutbound(draft.outbound, channel: channel, session: session)
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
                   channel: ChatChannel = .couple, displayText: String? = nil,
                   durationMs: Int? = nil, session: Session) async {
        guard let fence = sessionFence(for: session) else { return }
        let clientId = "tmp-" + UUID().uuidString
        let createdAt = Date().timeIntervalSince1970 * 1000
        let durableURL = await outboxProcessor.persistMedia(
            data: data, mimeType: mimeType, clientId: clientId, username: session.username)
        guard isCurrent(fence) else {
            if let durableURL { try? FileManager.default.removeItem(at: durableURL) }
            return
        }
        await finalizeMediaSend(
            durableURL: durableURL,
            preferredType: preferredType,
            mimeType: mimeType,
            localPreviewURL: localPreviewURL,
            channel: channel,
            displayText: displayText,
            durationMs: durationMs,
            session: session,
            clientId: clientId,
            createdAt: createdAt)
    }

    /// 大文件优先走文件复制，不把整包 Data 二次写入 outbox。
    func sendMediaFile(
        fileURL: URL,
        mimeType: String,
        preferredType: String,
        localPreviewURL: URL?,
        channel: ChatChannel = .couple,
        displayText: String? = nil,
        durationMs: Int? = nil,
        session: Session
    ) async {
        guard let fence = sessionFence(for: session) else { return }
        let clientId = "tmp-" + UUID().uuidString
        let createdAt = Date().timeIntervalSince1970 * 1000
        let durableURL = await outboxProcessor.persistMediaFile(
            source: fileURL, mimeType: mimeType, clientId: clientId, username: session.username)
        guard isCurrent(fence) else {
            if let durableURL { try? FileManager.default.removeItem(at: durableURL) }
            return
        }
        await finalizeMediaSend(
            durableURL: durableURL,
            preferredType: preferredType,
            mimeType: mimeType,
            localPreviewURL: localPreviewURL ?? fileURL,
            channel: channel,
            displayText: displayText,
            durationMs: durationMs,
            session: session,
            clientId: clientId,
            createdAt: createdAt)
    }

    private func finalizeMediaSend(
        durableURL: URL?,
        preferredType: String,
        mimeType: String,
        localPreviewURL: URL?,
        channel: ChatChannel,
        displayText: String?,
        durationMs: Int?,
        session: Session,
        clientId: String,
        createdAt: Double
    ) async {
        guard let fence = sessionFence(for: session),
              let scope = fence.persistenceScope else {
            if let durableURL {
                try? FileManager.default.removeItem(at: durableURL)
            }
            return
        }
        let draft = PendingMessageFactory.media(
            type: preferredType,
            text: displayText,
            mimeType: mimeType,
            durableURL: durableURL,
            previewURL: localPreviewURL,
            channel: channel,
            session: session,
            durationMs: durationMs,
            clientId: clientId,
            createdAt: createdAt)
        guard let durableURL else {
            print("[MessageStore] ⚠️ 媒体保存失败 clientId=\(clientId)")
            return
        }
        guard await outboxProcessor.save(draft.outbound, scope: scope) else {
            try? FileManager.default.removeItem(at: durableURL)
            return
        }
        guard isCurrent(fence) else { return }
        updateMessages(channel) { messages in
            ChatMessageCollection.upsert(draft.message, into: &messages)
        }
        await schedulePendingOutbound(draft.outbound, channel: channel, session: session)
    }

    func sendSticker(url: String, channel: ChatChannel = .couple, session: Session) async {
        guard let fence = sessionFence(for: session),
              let scope = fence.persistenceScope else { return }
        let draft = PendingMessageFactory.sticker(url: url, channel: channel, session: session)
        guard await outboxProcessor.save(draft.outbound, scope: scope),
              isCurrent(fence) else { return }
        updateMessages(channel) { messages in
            ChatMessageCollection.upsert(draft.message, into: &messages)
        }
        await schedulePendingOutbound(draft.outbound, channel: channel, session: session)
    }

    func uploadSticker(data: Data, mimeType: String, session: Session) async -> String? {
        guard mimeType.hasPrefix("image/") else { return nil }
        do {
            let uploaded = try await uploadMedia(
                data: data, mimeType: mimeType, purpose: .sticker, session: session)
            if let url = ServerConfig.resolveMediaURL(uploaded.url) {
                ImageCache.shared.store(data: data, for: url)
            }
            return uploaded.url
        } catch {
            print("[MessageStore] 表情上传失败: \(error.localizedDescription)")
            return nil
        }
    }

    func retryFailedMessage(clientId: String, session: Session) async -> OutboxRetryResult {
        guard let fence = sessionFence(for: session),
              let scope = fence.persistenceScope else { return .notFound }
        guard var pending = await outboxProcessor.pending(
            clientId: clientId,
            scope: scope
        ), isCurrent(fence) else {
            return .notFound
        }
        guard await outboxProcessor.canRetry(pending) else {
            return .missingLocalFile
        }

        pending.lastError = nil
        pending.attempts = 0
        pending.requiresManualRetry = false
        guard await outboxProcessor.update(pending, scope: scope),
              isCurrent(fence) else { return .notFound }
        guard let channel = ChatChannel(rawValue: pending.channel) else {
            print("[MessageStore] ⚠️ 拒绝重试未知频道待发消息 clientId=\(pending.clientId)")
            return .notFound
        }
        await schedulePendingOutbound(pending, channel: channel, session: session)
        return .started
    }

    func discardFailedMessage(clientId: String) async {
        guard let fence = activeSessionFence,
              let scope = fence.persistenceScope else { return }
        guard let pending = await outboxProcessor.discard(
            clientId: clientId,
            scope: scope
        ), isCurrent(fence) else {
            removeOptimisticMessage(clientId: clientId)
            return
        }
        removeOptimisticMessage(clientId: clientId, channel: ChatChannel(rawValue: pending.channel))
    }

    private func removeOptimisticMessage(clientId: String, channel: ChatChannel? = nil) {
        let channels = channel.map { [$0] } ?? ChatChannel.allCases
        for channel in channels {
            updateMessages(channel) { list in
                ChatMessageCollection.removePending(clientId: clientId, from: &list)
            }
        }
    }

    // MARK: - 已读

    func markRead(_ channel: ChatChannel, through timestamp: Double) {
        if let username = socketProvider?.sessionUsername,
           timestamp <= (readState(for: channel)[username] ?? 0),
           readReceiptCoordinator.pendingTimestamp(for: channel) == nil {
            return
        }
        readReceiptCoordinator.mark(
            channel,
            through: timestamp,
            isConnected: socketProvider?.isConnected == true,
            emit: { [weak self] channel, timestamp in
                self?.emitReadReceipt(channel: channel, timestamp: timestamp) == true
            })
        // 已展示即已读：先乐观更新当前设备状态，避免用户立即退出聊天时角标等待
        // WebSocket 回执后才消失。服务端事件仍会用权威时间戳重新确认。
        if let username = socketProvider?.sessionUsername,
           timestamp > (readState(for: channel)[username] ?? 0) {
            var state = readState(for: channel)
            state[username] = timestamp
            var next = readStates
            next[channel.rawValue] = state
            readStates = next
            if let fence = activeSessionFence,
               let scope = fence.persistenceScope {
                Task {
                    guard self.isCurrent(fence) else { return }
                    _ = await persistence.saveReadReceipt(
                        channel: channel.rawValue,
                        username: username,
                        ts: timestamp,
                        updatedAt: Date().timeIntervalSince1970 * 1000,
                        scope: scope)
                }
            }
        }
    }

    /// 断线期间仍保留各频道最高已展示时间；连接成功后调用本方法重新发送。
    func flushPendingReadReceipts() {
        readReceiptCoordinator.flush(
            isConnected: socketProvider?.isConnected == true,
            emit: { [weak self] channel, timestamp in
                self?.emitReadReceipt(channel: channel, timestamp: timestamp) == true
            })
    }

    func clearAllChannels() {
        timelineStore.reset()
        lastLoadOlderAt.removeAll()
        lastLoadNewerAt.removeAll()
        aiTyping = false
        aiReplying = false
    }

    func resetPendingReadReceipts() {
        readReceiptCoordinator.reset()
    }

    func pendingReadTimestamp(for channel: ChatChannel) -> Double? {
        readReceiptCoordinator.pendingTimestamp(for: channel)
    }

    private func emitReadReceipt(channel: ChatChannel, timestamp: Double) -> Bool {
        guard let socket = socketProvider?.socket,
              socketProvider?.isConnected == true,
              let fence = activeSessionFence,
              let username = socketProvider?.sessionUsername,
              socketProvider?.currentSession?.token == fence.token else { return false }
        socket.emitWithAck(
            SocketEvent.read.rawValue,
            SocketPayloadEncoder.encode(ReadReceiptRequest(channel: channel, ts: timestamp)))
            .timingOut(after: 3) { [weak self] response in
                Task { @MainActor in
                    guard let self,
                          self.isCurrent(fence),
                          self.socketProvider?.socket === socket,
                          self.socketProvider?.currentSession?.token == fence.token,
                          self.socketProvider?.sessionUsername == username else { return }
                    guard let ack = response.first as? [String: Any],
                          ack["ok"] as? Bool == true,
                          let effectiveTimestamp = (ack["ts"] as? NSNumber)?.doubleValue else {
                        self.readReceiptCoordinator.retry(
                            channel,
                            requestTimestamp: timestamp,
                            isConnected: self.socketProvider?.isConnected == true,
                            emit: { [weak self] channel, timestamp in
                                self?.emitReadReceipt(channel: channel, timestamp: timestamp) == true
                            })
                        return
                    }
                    self.readReceiptCoordinator.acknowledge(
                        channel,
                        requestTimestamp: timestamp)
                    self.setReadState(channel, user: username, ts: effectiveTimestamp)
                }
            }
        return true
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
           let confirmed = state[username] {
            readReceiptCoordinator.confirm(channel, through: confirmed)
        }
        for (user, ts) in state {
            if let fence = activeSessionFence,
               let scope = fence.persistenceScope {
                Task {
                    guard self.isCurrent(fence) else { return }
                    _ = await persistence.saveReadReceipt(
                        channel: channel.rawValue,
                        username: user,
                        ts: ts,
                        updatedAt: Date().timeIntervalSince1970 * 1000,
                        scope: scope)
                }
            }
        }
    }

    func setReadState(_ channel: ChatChannel, user: String, ts: Double) {
        var state = readState(for: channel)
        guard ts > (state[user] ?? 0) else {
            if user == socketProvider?.sessionUsername {
                readReceiptCoordinator.confirm(channel, through: ts)
            }
            return
        }
        state[user] = ts
        setReadState(channel, state: state)
    }

    // MARK: - 撤回

    struct RecallDraft {
        let text: String
    }

    private var recallDrafts: [String: RecallDraft] = [:]
    private var optimisticRecalls: [String: (message: ChatMessage, channel: ChatChannel)] = [:]

    func hasRecallDraft(messageId: String) -> Bool {
        recallDrafts[messageId] != nil
    }

    func takeRecallDraft(messageId: String) -> RecallDraft? {
        recallDrafts.removeValue(forKey: messageId)
    }

    func recallMessage(_ message: ChatMessage, channel: ChatChannel) {
        guard let s = socketProvider?.socket,
              socketProvider?.isConnected == true,
              let fence = activeSessionFence,
              fence.persistenceScope != nil else {
            // 离线时不能静默返回：长按菜单选了"撤回"却什么都不发生，用户无从判断。
            NotificationCenter.default.post(name: Self.recallFailedNotification, object: nil)
            return
        }
        guard optimisticRecalls[message.id] == nil else { return }
        let editable = message.type == "text"
            ? message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        if !editable.isEmpty { recallDrafts[message.id] = RecallDraft(text: message.text) }
        // 先只从当前时间线隐藏，数据库、引用和媒体缓存等不可逆清理由服务端成功事件完成。
        // 这样长按菜单关闭后立即看到结果，网络失败时还能完整恢复原消息。
        optimisticRecalls[message.id] = (message, channel)
        updateMessages(channel) { list in
            list.removeAll { $0.id == message.id }
        }
        s.emitWithAck(
            SocketEvent.messageRecall.rawValue,
            SocketPayloadEncoder.encode(MessageRecallRequest(id: message.id))).timingOut(after: 9) { [weak self] response in
                // 区分"服务端明确拒绝"和"根本没等到 ACK"：超时时服务端事务很可能已经
                // 成功，按失败处理会让消息复活并弹一次假的"撤回失败"，几秒后又被广播删掉。
                let acknowledgement = response.first as? [String: Any]
                let confirmed = acknowledgement?["ok"] as? Bool == true
                let rejected = acknowledgement != nil && !confirmed
                Task { @MainActor in
                    guard let self else { return }
                    guard self.isCurrent(fence), self.socketProvider?.socket === s else {
                        // 会话或连接已经换掉，结果无从判断。撤销乐观隐藏让界面回到已知状态，
                        // 同时解除重试封锁；若撤回其实已生效，广播或下次补拉会再删掉它。
                        self.restoreOptimisticRecall(id: message.id)
                        return
                    }
                    if confirmed {
                        if !(await self.applyRecall(id: message.id, channel: channel)) {
                            print("[MessageStore] ⚠️ 撤回已获服务器确认，等待本地持久化重试 id=\(message.id)")
                        }
                        return
                    }
                    guard rejected else {
                        print("[MessageStore] ⚠️ 撤回 ACK 超时，交给服务端广播或补拉收敛 id=\(message.id)")
                        return
                    }
                    self.recallDrafts.removeValue(forKey: message.id)
                    self.restoreOptimisticRecall(id: message.id)
                    NotificationCenter.default.post(name: Self.recallFailedNotification, object: nil)
                }
            }
    }

    /// 撤销乐观隐藏并解除重试封锁。
    private func restoreOptimisticRecall(id: String) {
        guard let snapshot = optimisticRecalls.removeValue(forKey: id) else { return }
        updateMessages(snapshot.channel) { list in
            ChatMessageCollection.upsert(snapshot.message, into: &list)
        }
    }

    @discardableResult
    func applyRecall(id: String, channel: ChatChannel) async -> Bool {
        await applyRecallPersisted(id: id, channel: channel)
    }

    func applyRecallPersisted(id: String, channel: ChatChannel) async -> Bool {
        guard let context = currentPersistenceContext() else { return false }
        let persistedMessage = await persistence.fetchMessage(
            id: id,
            channel: channel.rawValue,
            scope: context.scope)
        guard isCurrent(context.fence),
              await persistRecall(id: id, channel: channel, scope: context.scope),
              isCurrent(context.fence) else { return false }
        await applyRecallLocally(
            id: id,
            channel: channel,
            persistedMessage: persistedMessage,
            fence: context.fence)
        return isCurrent(context.fence)
    }

    private func applyRecallLocally(
        id: String,
        channel: ChatChannel,
        persistedMessage: ChatMessage?,
        fence: MessageSessionFence
    ) async {
        guard isCurrent(fence) else { return }
        optimisticRecalls.removeValue(forKey: id)
        var mediaURLs: Set<URL> = []
        if let url = persistedMessage?.mediaURL { mediaURLs.insert(url) }
        for attachment in persistedMessage?.attachments ?? [] {
            if let url = attachment.mediaURL { mediaURLs.insert(url) }
        }
        updateMessages(channel) { list in
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
            }
        }
        if latestPersistedMessageIDs[channel.rawValue] == id {
            latestPersistedMessageIDs[channel.rawValue] = messages(for: channel).last(where: {
                !$0.pending && !$0.failed
            })?.id
        }
        MediaFavoriteStore.shared.remove(messageId: id)
        NotificationCenter.default.post(
            name: Self.messageDeletedNotification,
            object: nil,
            userInfo: ["messageId": id])
        for url in mediaURLs {
            guard isCurrent(fence) else { return }
            await ImageCache.shared.removeMedia(for: url)
            guard isCurrent(fence) else { return }
            await MediaFileCache.shared.removeMedia(for: url)
        }
    }

    private func persistRecall(
        id: String,
        channel: ChatChannel,
        scope: ChatPersistenceScope
    ) async -> Bool {
        guard await persistence.deleteMessage(
            id: id,
            channel: channel.rawValue,
            scope: scope
        ) else {
            print("[MessageStore] ⚠️ 撤回消息未能从本地数据库删除 id=\(id)")
            return false
        }
        return true
    }

    // MARK: - Meta 更新（确认卡）

    private var confirmationRequestsInFlight = Set<String>()

    @discardableResult
    func applyMessageUpdate(id: String, meta: [String: Any]?) async -> Bool {
        guard let context = currentPersistenceContext() else { return false }
        for c in ChatChannel.allCases {
            guard var updated = messages(for: c).first(where: { $0.id == id }) else { continue }
            updated.meta = meta.flatMap { ChatMessageMeta(dict: $0) }
            guard await persistence.insertMessage(updated, scope: context.scope),
                  isCurrent(context.fence) else {
                print("[MessageStore] ⚠️ 消息更新未能写入本地数据库 id=\(id)")
                return false
            }
            updateMessages(c) { list in
                guard let index = list.firstIndex(where: { $0.id == id }) else { return }
                list[index].meta = updated.meta
            }
            return true
        }
        return true
    }

    func confirmAction(
        messageId: String,
        decision: String,
        completion: @escaping (Bool) -> Void
    ) {
        guard ["confirm", "cancel"].contains(decision),
              !confirmationRequestsInFlight.contains(messageId),
              let socket = socketProvider?.socket,
              socketProvider?.isConnected == true,
              let fence = activeSessionFence,
              fence.persistenceScope != nil,
              setConfirmationStatusInMemory(messageId: messageId, status: "processing") else {
            completion(false)
            return
        }

        confirmationRequestsInFlight.insert(messageId)
        socket.emitWithAck(
            SocketEvent.actionConfirm.rawValue,
            SocketPayloadEncoder.encode(ActionConfirmRequest(
                messageId: messageId,
                decision: decision)))
            .timingOut(after: 9) { [weak self] response in
                let acknowledgement = response.first as? [String: Any]
                let ok = acknowledgement?["ok"] as? Bool == true
                let finalMeta = acknowledgement?["meta"] as? [String: Any]
                Task { @MainActor in
                    guard let self else { return }
                    // 每次进前台都会 forceReconnect 换掉 socket 实例，所以这个守卫是常见路径。
                    // 必须先解除 in-flight 封锁并恢复卡片状态，否则卡片永远停在 processing、
                    // 重入又被封锁挡住，用户只能反复看到"操作未完成"。
                    guard self.isCurrent(fence), self.socketProvider?.socket === socket else {
                        self.confirmationRequestsInFlight.remove(messageId)
                        self.restoreProcessingConfirmation(messageId: messageId)
                        completion(false)
                        return
                    }
                    self.confirmationRequestsInFlight.remove(messageId)

                    if ok, let finalMeta {
                        completion(await self.applyMessageUpdate(id: messageId, meta: finalMeta))
                        return
                    }
                    if ok {
                        // 兼容尚未返回最终 meta 的旧服务版本；成功 ACK 仍是服务端事实。
                        let status = decision == "cancel" ? "cancelled" : "confirmed"
                        completion(await self.persistConfirmationStatus(messageId: messageId, status: status))
                        return
                    }

                    self.restoreProcessingConfirmation(messageId: messageId)
                    completion(false)
                }
            }
    }

    private func setConfirmationStatusInMemory(messageId: String, status: String) -> Bool {
        for channel in ChatChannel.allCases {
            guard var updated = messages(for: channel).first(where: { $0.id == messageId }),
                  var meta = updated.meta,
                  var confirm = meta.confirm,
                  confirm.status == "pending" else { continue }
            confirm.status = status
            meta.confirm = confirm
            updated.meta = meta
            updateMessages(channel) { list in
                guard let index = list.firstIndex(where: { $0.id == messageId }) else { return }
                list[index] = updated
            }
            return true
        }
        return false
    }

    private func restoreProcessingConfirmation(messageId: String) {
        for channel in ChatChannel.allCases {
            guard var updated = messages(for: channel).first(where: { $0.id == messageId }),
                  var meta = updated.meta,
                  var confirm = meta.confirm,
                  confirm.status == "processing" else { continue }
            confirm.status = "pending"
            meta.confirm = confirm
            updated.meta = meta
            updateMessages(channel) { list in
                guard let index = list.firstIndex(where: { $0.id == messageId }) else { return }
                list[index] = updated
            }
            return
        }
    }

    private func persistConfirmationStatus(messageId: String, status: String) async -> Bool {
        guard let context = currentPersistenceContext() else { return false }
        for channel in ChatChannel.allCases {
            guard var updated = messages(for: channel).first(where: { $0.id == messageId }),
                  var meta = updated.meta,
                  var confirm = meta.confirm else { continue }
            confirm.status = status
            meta.confirm = confirm
            updated.meta = meta
            guard await persistence.insertMessage(updated, scope: context.scope),
                  isCurrent(context.fence) else { return false }
            updateMessages(channel) { list in
                guard let index = list.firstIndex(where: { $0.id == messageId }) else { return }
                list[index] = updated
            }
            return true
        }
        return false
    }

    // MARK: - 搜索

    func searchMessages(
        _ query: String,
        channel: ChatChannel,
        cursor: MessageSearchCursor? = nil,
        limit: Int = 50
    ) async -> MessageSearchPage {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            return MessageSearchPage(messages: [], nextCursor: nil, hasMore: false)
        }
        guard let fence = activeSessionFence else {
            return MessageSearchPage(messages: [], nextCursor: nil, hasMore: false)
        }
        let local: [ChatMessage]
        if cursor == nil, let scope = fence.persistenceScope {
            local = await persistence.searchMessages(
                query: q,
                channel: channel.rawValue,
                scope: scope) ?? []
            guard isCurrent(fence) else {
                return MessageSearchPage(messages: [], nextCursor: nil, hasMore: false)
            }
        } else {
            local = []
        }
        guard let s = socketProvider?.socket, socketProvider?.isConnected == true else {
            return MessageSearchPage(messages: local, nextCursor: nil, hasMore: false)
        }
        let data: [Any] = await withCheckedContinuation { continuation in
            s.emitWithAck(
                SocketEvent.messagesSearch.rawValue,
                SocketPayloadEncoder.encode(MessageSearchRequest(
                    channel: channel,
                    query: q,
                    limit: limit,
                    cursor: cursor)))
                .timingOut(after: 9) { continuation.resume(returning: $0) }
        }
        guard isCurrent(fence),
              socketProvider?.socket === s,
              let dict = data.first as? [String: Any],
              dict["ok"] as? Bool == true,
              let list = dict["list"] as? [[String: Any]] else {
            return MessageSearchPage(messages: local, nextCursor: nil, hasMore: false)
        }
        let remote = Self.parseMessages(list, context: "search:\(channel.rawValue)")
            .filter { $0.channel == channel.rawValue }
        if !remote.isEmpty, let scope = fence.persistenceScope {
            let persisted = await persistence.insertMessages(remote, scope: scope)
            guard isCurrent(fence) else {
                return MessageSearchPage(messages: [], nextCursor: nil, hasMore: false)
            }
            if persisted != remote.count {
                print("[MessageStore] ⚠️ 搜索结果写入本地数据库不完整")
            }
        }
        let cursorDict = dict["nextCursor"] as? [String: Any]
        let nextTimestamp = (cursorDict?["ts"] as? NSNumber)?.doubleValue
        let nextID = cursorDict?["id"] as? String
        let nextCursor: MessageSearchCursor?
        if let nextTimestamp, let nextID {
            nextCursor = MessageSearchCursor(ts: nextTimestamp, id: nextID)
        } else {
            nextCursor = nil
        }
        let hasMore = dict["hasMore"] as? Bool == true && nextCursor != nil
        return MessageSearchPage(messages: remote, nextCursor: nextCursor, hasMore: hasMore)
    }

    func mediaMessages(
        for channel: ChatChannel,
        includeFiles: Bool = false,
        limit: Int? = nil
    ) async -> [ChatMessage] {
        guard let context = currentPersistenceContext() else { return [] }
        let types = includeFiles ? Self.managedAttachmentTypes : Self.mediaTypes
        guard let messages = await persistence.mediaMessages(
            channel: channel.rawValue,
            types: types,
            limit: limit,
            scope: context.scope
        ), isCurrent(context.fence) else { return [] }
        return messages
    }

    func mediaItemCount(for channel: ChatChannel, includeFiles: Bool = false) async -> Int {
        guard let context = currentPersistenceContext() else { return 0 }
        let types = includeFiles ? Self.managedAttachmentTypes : Self.mediaTypes
        guard let count = await persistence.mediaCount(
            channel: channel.rawValue,
            types: types,
            scope: context.scope
        ), isCurrent(context.fence) else { return 0 }
        return count
    }

    // MARK: - 全量同步

    @discardableResult
    func syncAllHistory(
        _ channel: ChatChannel,
        onProgress: @escaping (_ localCount: Int, _ remoteTotal: Int?) -> Void
    ) async -> HistorySyncResult {
        guard let session = socketProvider?.currentSession,
              let context = currentPersistenceContext(),
              sessionFence(for: session) == context.fence else {
            return HistorySyncResult(
                localCount: 0,
                remoteTotal: nil, downloaded: 0, completed: false, error: "当前未登录")
        }
        let result = await historySyncService.sync(
            channel: channel,
            session: session,
            scope: context.scope,
            onProgress: onProgress)
        guard isCurrent(context.fence) else {
            return HistorySyncResult(
                localCount: result.localCount,
                remoteTotal: result.remoteTotal,
                downloaded: result.downloaded,
                completed: false,
                error: "登录会话已切换")
        }
        guard let latest = await persistence.fetchLatestMessages(
            channel: channel.rawValue,
            limit: 50,
            scope: context.scope
        ), isCurrent(context.fence) else {
            return HistorySyncResult(
                localCount: result.localCount,
                remoteTotal: result.remoteTotal,
                downloaded: result.downloaded,
                completed: false,
                error: "登录会话已切换")
        }
        if !latest.isEmpty {
            updateMessages(channel) { messages in
                ChatMessageCollection.upsert(latest, into: &messages)
            }
        }
        latestPersistedMessageIDs[channel.rawValue] = latest.max {
            ChatMessageCollection.isOrderedBefore($0, $1)
        }?.id
        return result
    }

    func clearLocalHistory() async {
        guard let context = currentPersistenceContext(),
              await persistence.deleteMessages(channel: nil, scope: context.scope),
              isCurrent(context.fence) else {
            print("[MessageStore] ⚠️ 清理本地聊天记录失败")
            return
        }
        MessageHistorySyncService.resetCheckpoint(username: context.fence.username, channel: .couple)
        MessageHistorySyncService.resetCheckpoint(username: context.fence.username, channel: .ai)
        messagesByChannel = [:]
        latestPersistedMessageIDs = [:]
        guard isCurrent(context.fence) else { return }
        await ImageCache.shared.clearAllAsync()
        guard isCurrent(context.fence) else { return }
        await MediaFileCache.shared.clearAll()
    }

    // MARK: - 私有辅助

    private func schedulePendingOutbound(
        _ item: PendingOutboundMessage,
        channel: ChatChannel,
        session: Session
    ) async {
        markPendingWaiting(clientId: item.clientId, channel: channel)
        guard socketProvider?.isConnected == true, socketProvider?.socket != nil else {
            // 离线发送仍保留为待发状态；网络恢复、socket 重连后会由 outbox 自动重放。
            // 只有确定的服务端拒绝或连续多次确认超时才显示失败按钮。
            return
        }
        flushOutbox(session: session)
    }

    /// 连接建立后按创建时间串行重放。服务端以 clientId 幂等，ACK 丢失也不会生成重复消息。
    func flushOutbox(session: Session) {
        guard socketProvider?.isConnected == true,
              socketProvider?.socket != nil,
              let fence = sessionFence(for: session),
              let scope = fence.persistenceScope else { return }
        // 两条车道并行重放：文字/贴纸不等媒体上传，媒体内部仍串行。
        for lane in OutboxLane.allCases {
            Task { [weak self] in
                guard let self, self.isCurrent(fence) else { return }
                await self.outboxProcessor.replay(
                    scope: scope,
                    lane: lane,
                    isConnected: { [weak self] in
                        guard let self else { return false }
                        return self.isCurrent(fence)
                            && self.socketProvider?.currentSession?.token == fence.token
                            && self.socketProvider?.isConnected == true
                    },
                    send: { [weak self] item in
                        guard let self, self.isCurrent(fence) else { return false }
                        guard let channel = ChatChannel(rawValue: item.channel) else {
                            print("[MessageStore] ⚠️ 隔离未知频道待发消息 clientId=\(item.clientId)")
                            return false
                        }
                        self.markPendingSending(clientId: item.clientId, channel: channel)
                        return await self.transmitPendingOutbound(
                            item,
                            session: session,
                            scope: scope,
                            fence: fence)
                    })
            }
        }
    }

    private func transmitPendingOutbound(
        _ original: PendingOutboundMessage,
        session: Session,
        scope: ChatPersistenceScope,
        fence: MessageSessionFence
    ) async -> Bool {
        guard isCurrent(fence),
              socketProvider?.currentSession?.token == session.token,
              socketProvider?.isConnected == true else { return false }
        var item = original
        guard let channel = ChatChannel(rawValue: item.channel) else {
            print("[MessageStore] ⚠️ 拒绝发送未知频道待发消息 clientId=\(item.clientId)")
            return false
        }

        if !item.attachments.isEmpty {
            for index in item.attachments.indices where item.attachments[index].uploadId == nil {
                let attachment = item.attachments[index]
                guard FileManager.default.fileExists(atPath: attachment.localFilePath) else {
                    await recordPendingFailure(
                        item,
                        channel: channel,
                        scope: scope,
                        fence: fence,
                        message: "相册资源不可用")
                    return false
                }
                do {
                    let uploaded = try await uploadMedia(
                        fileURL: URL(fileURLWithPath: attachment.localFilePath),
                        mimeType: attachment.mimeType, purpose: .message, session: session,
                        progressClientId: item.clientId, progressChannel: channel)
                    guard isCurrent(fence) else { return false }
                    item.attachments[index].uploadId = uploaded.id
                    item.attachments[index].uploadURL = uploaded.url
                    item.lastError = nil
                    guard await outboxProcessor.update(item, scope: scope),
                          isCurrent(fence) else { return false }
                    if attachment.mimeType.hasPrefix("image/"),
                       let remoteURL = ServerConfig.resolveMediaURL(uploaded.url) {
                        cacheUploadedImage(
                            at: attachment.localFilePath,
                            remoteURL: remoteURL)
                    }
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
                    await recordUploadFailure(
                        error,
                        item: item,
                        channel: channel,
                        session: session,
                        scope: scope,
                        fence: fence)
                    return false
                }
            }
        } else if item.isMedia, item.uploadId == nil {
            guard let path = item.localFilePath,
                   let mimeType = item.mimeType,
                   FileManager.default.fileExists(atPath: path) else {
                await recordPendingFailure(
                    item,
                    channel: channel,
                    scope: scope,
                    fence: fence,
                    message: "本地媒体文件不可用")
                return false
            }
            let localURL = URL(fileURLWithPath: path)
            do {
                let uploaded = try await uploadMedia(
                    fileURL: localURL, mimeType: mimeType, purpose: .message, session: session,
                    progressClientId: item.clientId, progressChannel: channel)
                guard isCurrent(fence) else { return false }
                item.type = item.type == "file" ? "file" : (uploaded.type.isEmpty ? item.type : uploaded.type)
                item.uploadId = uploaded.id
                item.uploadURL = uploaded.url
                item.lastError = nil
                guard await outboxProcessor.update(item, scope: scope),
                      isCurrent(fence) else { return false }

                if item.type == "image",
                   let remoteURL = ServerConfig.resolveMediaURL(uploaded.url) {
                    cacheUploadedImage(at: localURL.path, remoteURL: remoteURL)
                }
                updateMessages(channel) { list in
                    guard let index = list.firstIndex(where: { $0.id == item.clientId }) else { return }
                    list[index].type = item.type
                    list[index].url = item.uploadURL
                }
            } catch {
                await recordUploadFailure(
                    error,
                    item: item,
                    channel: channel,
                    session: session,
                    scope: scope,
                    fence: fence)
                return false
            }
        }

        guard let request = item.sendRequest(channel: channel) else {
            await recordPendingFailure(
                item,
                channel: channel,
                scope: scope,
                fence: fence,
                message: "附件上传不完整")
            return false
        }
        guard socketProvider?.currentSession?.token == session.token,
              socketProvider?.isConnected == true,
              let socket = socketProvider?.socket else {
            markPendingWaiting(clientId: item.clientId, channel: channel)
            return false
        }
        let ack = await waitForSendAck(socket: socket, request: request)
        guard isCurrent(fence), socketProvider?.socket === socket else { return false }
        let succeeded = await handleSendAck(
            ack,
            clientId: item.clientId,
            channel: channel,
            scope: scope,
            fence: fence)
        if succeeded {
            await finalizeConfirmedOutbound(
                clientId: item.clientId,
                scope: scope,
                fence: fence)
        } else {
            let payload = ack.first as? [String: Any]
            if let code = payload?["error"] as? String {
                let message = ServerErrorCode.message(for: code, fallback: "发送失败")
                await recordPendingFailure(
                    item,
                    channel: channel,
                    scope: scope,
                    fence: fence,
                    message: message)
            } else if ack.isEmpty {
                if socketProvider?.socket === socket {
                    socketProvider?.recoverConnection()
                }
                await recordTransientPendingFailure(
                    item,
                    channel: channel,
                    session: session,
                    scope: scope,
                    fence: fence,
                    message: "发送确认超时")
            } else {
                await recordTransientPendingFailure(
                    item,
                    channel: channel,
                    session: session,
                    scope: scope,
                    fence: fence,
                    message: "发送结果未能保存")
            }
        }
        return succeeded
    }

    private func waitForSendAck(
        socket: SocketIOClient,
        request: MessageSendRequest
    ) async -> [Any] {
        await withCheckedContinuation { continuation in
            let gate = MessageAckContinuation(continuation)
            socket.emitWithAck(SocketEvent.messageSend.rawValue, SocketPayloadEncoder.encode(request))
                .timingOut(after: Self.sendAckTimeout) { gate.resume(returning: $0) }
            // Socket.IO 在网络路径原地失效时偶尔不会交付 timeout callback。
            // 独立兜底确保消息不会永远停在“三个点”。
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.sendAckHardTimeout) {
                gate.resume(returning: [])
            }
        }
    }

    private func markPendingSending(clientId: String, channel: ChatChannel) {
        updateMessages(channel) { list in
            guard let index = ChatMessageCollection.index(matchingClientId: clientId, in: list),
                  list[index].pending || list[index].failed || list[index].id.hasPrefix("tmp-")
            else { return }
            list[index].pending = true
            list[index].failed = false
            list[index].waitingToSend = false
        }
    }

    private func markPendingWaiting(clientId: String, channel: ChatChannel) {
        updateMessages(channel) { list in
            guard let index = ChatMessageCollection.index(matchingClientId: clientId, in: list),
                  !list[index].failed,
                  list[index].pending || list[index].id.hasPrefix("tmp-") else { return }
            list[index].pending = true
            list[index].waitingToSend = true
        }
    }

    func markPendingWaitingToSend() {
        for channel in ChatChannel.allCases {
            updateMessages(channel) { list in
                for index in list.indices where list[index].pending && !list[index].failed {
                    list[index].waitingToSend = true
                }
            }
        }
    }

    private func markPendingFailed(clientId: String, channel: ChatChannel, error: String) {
        updateMessages(channel) { list in
            guard let index = ChatMessageCollection.index(matchingClientId: clientId, in: list),
                  list[index].pending || list[index].failed || list[index].id.hasPrefix("tmp-")
            else { return }
            list[index].pending = false
            list[index].failed = true
            list[index].waitingToSend = false
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
        scope: ChatPersistenceScope,
        fence: MessageSessionFence,
        message: String
    ) async {
        guard isCurrent(fence),
              var item = await outboxProcessor.pending(
                clientId: original.clientId,
                scope: scope
              ),
              isCurrent(fence) else { return }
        item.attempts += 1
        item.lastError = message
        item.requiresManualRetry = true
        guard await outboxProcessor.update(item, scope: scope),
              isCurrent(fence) else { return }
        markPendingFailed(clientId: item.clientId, channel: channel, error: message)
    }

    private func recordTransientPendingFailure(
        _ original: PendingOutboundMessage,
        channel: ChatChannel,
        session: Session,
        scope: ChatPersistenceScope,
        fence: MessageSessionFence,
        message: String
    ) async {
        guard isCurrent(fence),
              var item = await outboxProcessor.pending(
                clientId: original.clientId,
                scope: scope
              ),
              isCurrent(fence) else { return }
        item.attempts += 1
        item.lastError = message
        item.requiresManualRetry = item.attempts >= Self.maxAutomaticSendAttempts
        guard await outboxProcessor.update(item, scope: scope),
              isCurrent(fence) else { return }

        guard !item.requiresManualRetry else {
            markPendingFailed(clientId: item.clientId, channel: channel, error: message)
            return
        }
        markPendingWaiting(clientId: item.clientId, channel: channel)
        let expectedToken = session.token
        let delay = TimeInterval(item.attempts) * 1.5
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self,
                  self.isCurrent(fence),
                  self.socketProvider?.currentSession?.token == expectedToken,
                  let currentSession = self.socketProvider?.currentSession else { return }
            guard self.socketProvider?.isConnected == true else {
                self.markPendingWaiting(clientId: item.clientId, channel: channel)
                return
            }
            self.flushOutbox(session: currentSession)
        }
    }

    private func recordUploadFailure(
        _ error: Error,
        item: PendingOutboundMessage,
        channel: ChatChannel,
        session: Session,
        scope: ChatPersistenceScope,
        fence: MessageSessionFence
    ) async {
        if Self.isRetryableUploadError(error) {
            await recordTransientPendingFailure(
                item,
                channel: channel,
                session: session,
                scope: scope,
                fence: fence,
                message: error.localizedDescription)
        } else {
            await recordPendingFailure(
                item,
                channel: channel,
                scope: scope,
                fence: fence,
                message: error.localizedDescription)
        }
    }

    private func cacheUploadedImage(at path: String, remoteURL: URL) {
        Task {
            let data = await Task.detached(priority: .utility) {
                try? Data(contentsOf: URL(fileURLWithPath: path))
            }.value
            if let data {
                ImageCache.shared.store(data: data, for: remoteURL)
            }
        }
    }

    private nonisolated static func isRetryableUploadError(_ error: Error) -> Bool {
        if let uploadError = error as? MediaUploadError {
            return uploadError.isRetryable
        }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .badURL, .unsupportedURL, .fileDoesNotExist, .noPermissionsToReadFile,
             .dataLengthExceedsMaximum, .userAuthenticationRequired, .cancelled:
            return false
        default:
            return true
        }
    }

    private func completePendingOutbound(
        clientId: String,
        scope: ChatPersistenceScope,
        fence: MessageSessionFence
    ) async {
        await finalizeConfirmedOutbound(
            clientId: clientId,
            scope: scope,
            fence: fence)
    }

    private func finalizeConfirmedOutbound(
        clientId: String,
        scope: ChatPersistenceScope,
        fence: MessageSessionFence
    ) async {
        guard isCurrent(fence),
              let item = await outboxProcessor.pending(
                clientId: clientId,
                scope: scope
              ),
              isCurrent(fence) else { return }
        await retainCompletedMediaCache(item)
        guard isCurrent(fence) else { return }
        await outboxProcessor.complete(clientId: clientId, scope: scope)
    }

    private func reconcilePendingOutbounds(
        with confirmedMessages: [ChatMessage],
        scope: ChatPersistenceScope,
        fence: MessageSessionFence
    ) async {
        let confirmedClientIDs = Set(confirmedMessages.compactMap { message -> String? in
            guard !message.pending, !message.failed else { return nil }
            return message.clientId
        })
        guard !confirmedClientIDs.isEmpty else { return }

        guard let pending = await outboxProcessor.allPending(scope: scope),
              isCurrent(fence) else { return }
        for item in pending where confirmedClientIDs.contains(item.clientId) {
            await finalizeConfirmedOutbound(
                clientId: item.clientId,
                scope: scope,
                fence: fence)
        }
    }

    private func retainCompletedMediaCache(_ item: PendingOutboundMessage) async {
        if !item.attachments.isEmpty {
            for attachment in item.attachments
            where attachment.mimeType.hasPrefix("image/") {
                guard let remoteURL = ServerConfig.resolveMediaURL(attachment.uploadURL) else { continue }
                let data = await Task.detached(priority: .utility) {
                    try? Data(contentsOf: URL(fileURLWithPath: attachment.localFilePath))
                }.value
                if let data {
                    ImageCache.shared.store(data: data, for: remoteURL)
                }
            }
            return
        }
        guard let path = item.localFilePath,
              let remoteURL = ServerConfig.resolveMediaURL(item.uploadURL) else { return }
        if item.type == "image" {
            let data = await Task.detached(priority: .utility) {
                try? Data(contentsOf: URL(fileURLWithPath: path))
            }.value
            if let data {
                ImageCache.shared.store(data: data, for: remoteURL)
            }
            return
        }
        let kind: DownloadedMediaKind
        switch item.type {
        case "voice": kind = .voice
        case "file": kind = .file
        default: return
        }
        await MediaFileCache.shared.importLocalFile(
            URL(fileURLWithPath: path),
            remoteURL: remoteURL,
            kind: kind,
            suggestedFilename: item.type == "file" ? item.text : nil)
    }

    @discardableResult
    private func handleSendAck(
        _ data: [Any],
        clientId: String,
        channel: ChatChannel,
        scope: ChatPersistenceScope,
        fence: MessageSessionFence
    ) async -> Bool {
        guard isCurrent(fence) else { return false }
        guard let payload = data.first as? [String: Any] else { return false }
        guard payload["ok"] as? Bool == true else { return false }
        guard let acknowledgedMessage = Self.parseSendAckMessage(
            payload,
            expectedChannel: channel
        ) else {
            print("[MessageStore] ⚠️ 发送确认消息频道或格式无效 clientId=\(clientId)")
            return false
        }
        // ACK 只有在完整消息落入 SQLite 后才可以替换 UI pending。否则本次
        // messages 发布会先把已确认消息放到旧 latest anchor 后面，时间线随即
        // 把它误判为历史窗口并显示“回到最新”。
        guard await persistence.insertMessage(
            acknowledgedMessage,
            scope: scope
        ), isCurrent(fence) else {
            print("[MessageStore] ⚠️ 发送确认未能持久化 clientId=\(clientId)")
            return false
        }

        var next = messages(for: channel)
        if ChatMessageCollection.index(matchingClientId: clientId, in: next) == nil {
            ChatMessageCollection.upsert(acknowledgedMessage, into: &next)
        } else {
            ChatMessageCollection.replacePending(
                clientId: clientId,
                with: acknowledgedMessage,
                in: &next)
        }
        if next.last(where: { !$0.pending && !$0.failed })?.id == acknowledgedMessage.id {
            // 必须先推进 anchor 再发布 messages，让同一轮 UI 刷新看到一致状态。
            latestPersistedMessageIDs[channel.rawValue] = acknowledgedMessage.id
        }
        updateMessages(channel) { $0 = next }
        return true
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
        session: Session,
        progressClientId: String? = nil,
        progressChannel: ChatChannel? = nil
    ) async throws -> UploadResult {
        var onProgress: (@Sendable (Double) -> Void)?
        if let progressClientId, let progressChannel {
            onProgress = { [weak self] fraction in
                Task { @MainActor [weak self] in
                    self?.updateUploadProgress(
                        clientId: progressClientId,
                        channel: progressChannel,
                        progress: fraction)
                }
            }
        }
        defer {
            if let progressClientId, let progressChannel {
                updateUploadProgress(clientId: progressClientId, channel: progressChannel, progress: nil)
            }
        }
        return try await mediaUploadService.upload(
            fileURL: fileURL, mimeType: mimeType, purpose: purpose, session: session,
            onProgress: onProgress)
    }

    /// 进度按 ≥5% 的步进写入气泡，避免每个网络分片都触发一次时间线刷新。
    private func updateUploadProgress(clientId: String, channel: ChatChannel, progress: Double?) {
        updateMessages(channel) { list in
            guard let index = ChatMessageCollection.index(matchingClientId: clientId, in: list),
                  list[index].pending else { return }
            if let progress, let current = list[index].uploadProgress,
               progress - current < 0.05, progress < 1 { return }
            list[index].uploadProgress = progress
        }
    }

}


private extension Data {
    mutating func append(_ string: String) {
        append(contentsOf: string.utf8)
    }
}
