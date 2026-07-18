import Combine
import Foundation
import SocketIO
import SwiftUI

struct AIActivity: Equatable {
    let channel: ChatChannel
    let requestMessageId: String?
    let requesterUsername: String?
    let phase: String

    var isVisible: Bool { phase == "accepted" || phase == "generating" }
}

/// 协调层：持有 socket，分发事件给子 store，对外暴露统一接口。
/// 子 store：AuthStore（登录）、MessageStore（消息）、SharedStore（共享状态）。
@MainActor
final class ChatStore: ObservableObject {
    static let baseURL = ServerConfig.baseURL

    nonisolated static func validatedSyncChannel(_ rawChannel: String?) -> ChatChannel? {
        rawChannel.flatMap(ChatChannel.init(rawValue:))
    }

    nonisolated static func validatedSyncMessageChannels(
        _ events: [SyncV2Event]
    ) -> [ChatChannel]? {
        var channels: [ChatChannel] = []
        for event in events where event.entityType == "message" {
            guard let channel = validatedSyncChannel(event.payload.channel) else {
                return nil
            }
            channels.append(channel)
        }
        return channels
    }

    // MARK: - 子 store

    let auth: AuthStore
    let messageStore: MessageStore
    let shared: SharedStore
    let localData: LocalDataRepository
    let personalItems: PersonalItemsRepository
    let memoryControl: AIMemoryRepository
    let syncV2: SyncV2Repository
    lazy var historySync = HistorySyncCoordinator(
        isLoggedIn: { [weak self] in self?.loggedIn == true },
        historyWorker: { [weak self] channel, onProgress in
            guard let self else {
                return HistorySyncCoordinator.HistoryResult(
                    localCount: 0, remoteTotal: nil, downloaded: 0,
                    completed: false, error: "同步服务不可用")
            }
            let result = await self.syncAllHistory(channel, onProgress: onProgress)
            return HistorySyncCoordinator.HistoryResult(
                localCount: result.localCount,
                remoteTotal: result.remoteTotal,
                downloaded: result.downloaded,
                completed: result.completed,
                error: result.error)
        },
        imageWorker: { [weak self] onProgress in
            guard let self else {
                return HistorySyncCoordinator.ImageResult(total: 0, completed: 0, failed: 0)
            }
            let result = await self.localData.cacheAllImages(onProgress: onProgress)
            return HistorySyncCoordinator.ImageResult(
                total: result.total,
                completed: result.completed,
                failed: result.failed)
        })

    // MARK: - 对外聚合状态

    var connected: Bool { realtime.isConnected }
    var connectionState: RealtimeConnectionState { realtime.state }
    var lastConnectionError: String? { realtime.lastError }
    @Published var partnerOnline = false
    @Published private(set) var presenceKnown = false
    @Published private(set) var aiActivityByChannel: [String: AIActivity] = [:]
    @Published private(set) var interactionPresentationQueue: [InteractionPresentation] = []
    @Published private(set) var visibleChatChannel: ChatChannel?
    @Published private(set) var localCacheAvailable = true

    // 便捷访问
    var session: Session? { auth.session }
    var loggedIn: Bool { auth.loggedIn }
    var partner: Account? { auth.partner }

    lazy var realtime = RealtimeConnectionCoordinator(
        sessionProvider: { [weak self] in self?.auth.session },
        onSocketCreated: { [weak self] socket in self?.eventRouter.bind(socket) },
        onConnected: { [weak self] in
            guard let self, let session = self.auth.session else { return }
            let generation = self.auth.sessionGeneration
            self.messageStore.flushPendingReadReceipts()
            self.messageStore.flushOutbox(session: session)
            self.shared.flushPendingWrites()
            self.startPersistentSyncLoop()
            Task {
                // 前台重连时补 bootstrap + Sync，避免仅 tombstone 的 SyncV2 漏掉新消息。
                guard self.auth.sessionGeneration == generation else { return }
                _ = await self.refreshBootstrap()
                guard self.auth.sessionGeneration == generation else { return }
                await self.recoverSyncV2()
            }
        },
        onUnauthorized: { [weak self] in self?.auth.verifySessionOrLogout() })
    private lazy var eventRouter = RealtimeEventRouter(
        auth: auth,
        messageStore: messageStore,
        shared: shared,
        setAIActivity: { [weak self] channel, activity in
            self?.setAIActivity(activity, for: channel)
        },
        setPartnerOnline: { [weak self] online in self?.partnerOnline = online },
        setPresenceKnown: { [weak self] known in self?.presenceKnown = known },
        onIncomingInteraction: { [weak self] message in
            self?.receiveIncomingInteraction(message)
        })
    private let httpClient: any HTTPClient
    private let persistence: any ChatPersistenceProtocol
    private var childStateCancellables = Set<AnyCancellable>()
    private var localAIActivityTokens: [String: UUID] = [:]
    private var wasBackgrounded = false
    private var syncingV2 = false
    private var persistentSyncTask: Task<Void, Never>?
    private var deferredIncomingInteractions: [String: InteractionPresentation] = [:]
    private var knownInteractionPresentationIDs = Set<String>()
    private var lastInteractionSentAt = Date.distantPast

    // MARK: - 统计/存储

    // MARK: - 初始化

    init(
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        persistence: any ChatPersistenceProtocol = ChatPersistence.shared
    ) {
        self.httpClient = httpClient
        self.persistence = persistence
        auth = AuthStore(httpClient: httpClient, persistence: persistence)
        messageStore = MessageStore(httpClient: httpClient, persistence: persistence)
        shared = SharedStore(httpClient: httpClient, persistence: persistence)
        localData = LocalDataRepository(persistence: persistence)
        personalItems = PersonalItemsRepository(httpClient: httpClient)
        memoryControl = AIMemoryRepository(httpClient: httpClient)
        syncV2 = SyncV2Repository(httpClient: httpClient)
        auth.socketProvider = realtime
        messageStore.socketProvider = realtime
        shared.socketProvider = realtime

        StickerStore.shared.configureSync { [weak self] value in
            guard let self, let session = self.auth.session else { return }
            self.shared.setShared(
                StickerStore.sharedKey(for: session.username),
                value: value,
                session: session)
        }

        realtime.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &childStateCancellables)

        // ChatStore 暴露的是 MessageStore 的计算属性；子 ObservableObject 不会自动把
        // objectWillChange 传给父对象。只转发 AI 状态，避免 SwiftUI 顶栏/大橘入口永远
        // 看见旧值，同时不让普通消息更新产生重复的整页刷新。
        Publishers.CombineLatest(messageStore.$aiTyping, messageStore.$aiReplying)
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &childStateCancellables)

        // 首页读取的是 ChatStore 暴露的 sharedValue；SharedStore 是独立的
        // ObservableObject，必须显式转发，否则状态已写入但首页不会立即重绘。
        shared.$sharedState
            .dropFirst()
            .sink { [weak self] state in
                guard let self else { return }
                guard let username = self.auth.session?.username else {
                    self.objectWillChange.send()
                    return
                }
                let key = StickerStore.sharedKey(for: username)
                guard let entry = state[key] as? [String: Any],
                      let library = entry["value"] as? [String: Any] else {
                    self.objectWillChange.send()
                    return
                }
                StickerStore.shared.applySyncedLibrary(library)
                self.objectWillChange.send()
            }
            .store(in: &childStateCancellables)
    }

    // MARK: - 启动

    func bootstrap() async {
        guard let session = auth.savedSession() else { return }
        shared.activate(username: session.username)
        let snapshotTask = Task { try await fetchBootstrap(session: session) }
        localCacheAvailable = await openLocalDatabase(username: session.username)
        if localCacheAvailable {
            await messageStore.restoreLocalCache(for: session)
            await shared.restoreCachedSharedState()
        }
        auth.activate(session, accounts: [], persist: false)
        StickerStore.shared.activate(username: session.username)
        MediaFavoriteStore.shared.activate(username: session.username)
        auth.restoreCachedPartner()
        realtime.connect()
        do {
            let snapshot = try await snapshotTask.value
            await messageStore.applyBootstrap(snapshot, session: session)
            shared.applySharedInit(snapshot.sharedState)
            completeStickerInitialSync(for: session)
            auth.activate(session, accounts: snapshot.accounts, persist: false)
            await recoverSyncV2()
        } catch BootstrapError.unauthorized {
            StickerStore.shared.deactivate()
            await auth.logout()
        } catch {
            // 已登录用户离线启动时仍可查看有界本地缓存；连接恢复后前台刷新会补最新快照。
            realtime.setLastError(error.localizedDescription)
        }
    }

    // MARK: - 登录/登出

    func login(username: String, password: String) async throws {
        let session = try await auth.authenticate(username: username, password: password)
        shared.activate(username: session.username)
        let snapshotTask = Task { try await fetchBootstrap(session: session) }
        localCacheAvailable = await openLocalDatabase(username: session.username)
        if localCacheAvailable {
            await messageStore.restoreLocalCache(for: session)
            await shared.restoreCachedSharedState()
        }
        auth.activate(session, accounts: [], persist: true)
        StickerStore.shared.activate(username: session.username)
        MediaFavoriteStore.shared.activate(username: session.username)
        auth.restoreCachedPartner()
        realtime.connect()
        do {
            let snapshot = try await snapshotTask.value
            await messageStore.applyBootstrap(snapshot, session: session)
            shared.applySharedInit(snapshot.sharedState)
            completeStickerInitialSync(for: session)
            auth.activate(session, accounts: snapshot.accounts, persist: false)
            await recoverSyncV2()
        } catch BootstrapError.unauthorized {
            logout()
            throw BootstrapError.unauthorized
        } catch {
            realtime.setLastError(error.localizedDescription)
        }
    }

    private func openLocalDatabase(username: String) async -> Bool {
        await persistence.open(username: username)
    }

    private func completeStickerInitialSync(for session: Session) {
        StickerStore.shared.completeInitialSync(
            personalLibrary: shared.sharedValue(
                StickerStore.sharedKey(for: session.username)))
    }

    private func fetchBootstrap(session: Session) async throws -> AppBootstrapSnapshot {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("api/bootstrap"))
        request.timeoutInterval = 15
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await httpClient.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BootstrapError.invalidResponse }
        if http.statusCode == 401 { throw BootstrapError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            let detail = ServerErrorCode.message(for: code, fallback: "初始化失败（\(http.statusCode)）")
            throw BootstrapError.server(detail)
        }
        return try AppBootstrapSnapshot.decode(data)
    }

    @discardableResult
    private func refreshBootstrap() async -> Bool {
        guard let session = auth.session else { return false }
        do {
            let snapshot = try await fetchBootstrap(session: session)
            await messageStore.applyBootstrap(snapshot, session: session)
            shared.applySharedInit(snapshot.sharedState)
            completeStickerInitialSync(for: session)
            auth.activate(session, accounts: snapshot.accounts, persist: false)
            realtime.setLastError(nil)
            return true
        } catch BootstrapError.unauthorized {
            logout()
            return false
        } catch {
            realtime.setLastError(error.localizedDescription)
            return false
        }
    }

    func logout() {
        let sessionToRevoke = auth.session
        let generation = auth.sessionGeneration
        stopPersistentSyncLoop()
        historySync.cancelForLogout()
        realtime.disconnect()
        partnerOnline = false
        presenceKnown = false
        resetTransientAIState()
        resetInteractionState()
        messageStore.resetPendingReadReceipts()
        messageStore.clearAllChannels()
        realtime.setLastError(nil)
        StickerStore.shared.deactivate()
        MediaFavoriteStore.shared.deactivate()
        shared.deactivate()
        Task {
            await auth.logout()
            // 若期间已登录新账号，不再 revoke 旧设备之外的操作。
            guard let sessionToRevoke else { return }
            await auth.revokeCurrentDevice(sessionToRevoke)
            _ = generation
        }
    }

    // MARK: - 便捷方法（桥接到子 store）

    func messages(for channel: ChatChannel) -> [ChatMessage] { messageStore.messages(for: channel) }

    func setShared(_ key: String, value: [String: Any]) {
        shared.setShared(key, value: value, session: auth.session)
    }

    func sharedValue(_ key: String) -> [String: Any]? { shared.sharedValue(key) }

    var coupleDates: CoupleDates { shared.coupleDates }
    func saveCoupleDates(_ dates: CoupleDates) { shared.saveCoupleDates(dates, session: auth.session) }
    var anniversaries: [AnniversaryEntry] { shared.anniversaries }
    func saveAnniversaries(_ items: [AnniversaryEntry]) { shared.saveAnniversaries(items, session: auth.session) }

    func avatarURL(for username: String?) -> URL? {
        if let sharedURL = shared.avatarURL(for: username) { return sharedURL }
        return AccountPresentation.mediaURL(auth.account(for: username)?.avatar)
    }

    func avatarText(for username: String?) -> String {
        let fallbackUsername = username ?? ""
        return AccountPresentation.avatarText(auth.account(for: username)?.avatar, for: fallbackUsername)
    }

    func partnerAlias(for username: String?) -> String? { auth.partnerAlias(for: username) }
    func setPartnerAlias(_ alias: String?, for username: String?) { auth.setPartnerAlias(alias, for: username) }
    func partnerDisplayName(fallback: String = "对方") -> String { auth.partnerDisplayName(fallback: fallback) }

    func sendText(_ text: String, channel: ChatChannel = .couple, replyTo: String? = nil, replyPreview: String? = nil) {
        guard let session = auth.session else { return }
        if channel == .ai || text.contains("@大橘") {
            beginLocalAIActivity(channel: channel, requesterUsername: session.username)
        }
        if channel == .ai { messageStore.aiReplying = true }
        Task {
            await messageStore.sendText(
                text,
                channel: channel,
                replyTo: replyTo,
                replyPreview: replyPreview,
                session: session)
        }
    }

    private func beginLocalAIActivity(channel: ChatChannel, requesterUsername: String) {
        let token = UUID()
        localAIActivityTokens[channel.rawValue] = token
        aiActivityByChannel[channel.rawValue] = AIActivity(
            channel: channel,
            requestMessageId: nil,
            requesterUsername: requesterUsername,
            phase: "accepted")
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let self, self.localAIActivityTokens[channel.rawValue] == token else { return }
            self.localAIActivityTokens.removeValue(forKey: channel.rawValue)
            if self.aiActivityByChannel[channel.rawValue]?.requestMessageId == nil {
                self.aiActivityByChannel.removeValue(forKey: channel.rawValue)
            }
        }
    }

    func sendMedia(data: Data, mimeType: String, preferredType: String, localPreviewURL: URL?, channel: ChatChannel = .couple, displayText: String? = nil) {
        guard let session = auth.session else { return }
        if channel == .ai, preferredType == "image" { messageStore.aiReplying = true }
        Task {
            await messageStore.sendMedia(
                data: data,
                mimeType: mimeType,
                preferredType: preferredType,
                localPreviewURL: localPreviewURL,
                channel: channel,
                displayText: displayText,
                session: session)
        }
    }

    func sendMediaFile(
        fileURL: URL,
        mimeType: String,
        preferredType: String,
        localPreviewURL: URL?,
        channel: ChatChannel = .couple,
        displayText: String? = nil
    ) {
        guard let session = auth.session else { return }
        if channel == .ai, preferredType == "image" { messageStore.aiReplying = true }
        Task {
            await messageStore.sendMediaFile(
                fileURL: fileURL,
                mimeType: mimeType,
                preferredType: preferredType,
                localPreviewURL: localPreviewURL,
                channel: channel,
                displayText: displayText,
                session: session)
        }
    }

    func sendSticker(url: String, channel: ChatChannel = .couple) {
        guard let session = auth.session else { return }
        Task { await messageStore.sendSticker(url: url, channel: channel, session: session) }
    }

    func uploadSticker(data: Data, mimeType: String) async -> String? {
        guard let session = auth.session else { return nil }
        return await messageStore.uploadSticker(data: data, mimeType: mimeType, session: session)
    }

    func uploadAvatar(_ image: UIImage) async -> Bool {
        await uploadAvatar(image, for: auth.session?.username)
    }

    @discardableResult
    func sendInteraction(kind: InteractionEffectKind, text: String, channel: ChatChannel = .couple) -> Bool {
        guard let session = auth.session else { return false }
        let now = Date()
        if kind != .note, now.timeIntervalSince(lastInteractionSentAt) < 0.75 {
            return false
        }
        if kind != .note { lastInteractionSentAt = now }
        let id = UUID().uuidString
        Task {
            await messageStore.sendInteraction(
                id: id, kind: kind, text: text, channel: channel, session: session)
        }
        if kind == .note {
            shared.setShared("screen_note", value: [
                "id": id,
                "from": session.username,
                "fromName": session.name,
                "text": text,
                "ts": Date().timeIntervalSince1970 * 1_000,
                "dismissed": false,
            ], session: session)
        } else {
            queueInteractionPresentation(InteractionPresentation(
                payload: InteractionPayload(id: id, kind: kind, text: text),
                senderName: "已送达",
                duration: 1.15))
        }
        return true
    }

    func setChatVisible(_ channel: ChatChannel, visible: Bool) {
        if visible {
            visibleChatChannel = channel
            if let deferred = deferredIncomingInteractions.removeValue(forKey: channel.rawValue) {
                queueInteractionPresentation(deferred)
                return
            }
            guard let username = session?.username else { return }
            let readAt = messageStore.readState(for: channel)[username] ?? 0
            if let message = messageStore.messages(for: channel).reversed().first(where: {
                $0.sender != username
                    && $0.ts > readAt
                    && $0.interactionPayload?.kind != .note
                    && $0.interactionPayload != nil
            }) {
                receiveIncomingInteraction(message)
            }
        } else if visibleChatChannel == channel {
            visibleChatChannel = nil
        }
    }

    func takeNextInteractionPresentation() -> InteractionPresentation? {
        guard !interactionPresentationQueue.isEmpty else { return nil }
        return interactionPresentationQueue.removeFirst()
    }

    private func receiveIncomingInteraction(_ message: ChatMessage) {
        guard let username = session?.username,
              message.channel == ChatChannel.couple.rawValue,
              message.sender != username,
              let payload = message.interactionPayload,
              payload.kind != .note else { return }
        let presentation = InteractionPresentation(
            payload: payload,
            senderName: message.senderName.isEmpty ? "TA" : message.senderName,
            duration: 2.1)
        guard !knownInteractionPresentationIDs.contains(presentation.id) else { return }
        if visibleChatChannel == .couple {
            queueInteractionPresentation(presentation)
        } else {
            // 离开聊天页时只保留最后一个，下一次进入直接展示。
            deferredIncomingInteractions[ChatChannel.couple.rawValue] = presentation
        }
    }

    func queueInteractionPresentation(_ presentation: InteractionPresentation) {
        guard knownInteractionPresentationIDs.insert(presentation.id).inserted else { return }
        if interactionPresentationQueue.count >= 6 {
            interactionPresentationQueue.removeFirst()
        }
        interactionPresentationQueue.append(presentation)
    }

    private func resetInteractionState() {
        interactionPresentationQueue.removeAll()
        deferredIncomingInteractions.removeAll()
        knownInteractionPresentationIDs.removeAll()
        visibleChatChannel = nil
        lastInteractionSentAt = .distantPast
    }

    func dismissScreenNote(id: String) {
        guard let session = auth.session,
              shared.sharedValue("screen_note")?["id"] as? String == id else { return }
        shared.setShared("screen_note", value: [
            "id": id,
            "dismissed": true,
            "dismissedBy": session.username,
            "dismissedAt": Date().timeIntervalSince1970 * 1_000,
        ], session: session)
    }

    func aiActivity(for channel: ChatChannel) -> AIActivity? {
        aiActivityByChannel[channel.rawValue]
    }

    func setAIActivity(_ activity: AIActivity?, for channel: String) {
        if let activity {
            aiActivityByChannel[channel] = activity
        } else {
            aiActivityByChannel.removeValue(forKey: channel)
        }
    }

    func resetTransientAIState() {
        localAIActivityTokens.removeAll()
        aiActivityByChannel.removeAll()
        messageStore.aiTyping = false
        messageStore.aiReplying = false
    }

    func isAIComposing(in channel: ChatChannel) -> Bool {
        let hasActivity = aiActivity(for: channel)?.isVisible == true
        guard channel == .ai else { return hasActivity }
        return hasActivity || messageStore.aiTyping || messageStore.aiReplying
    }

    func uploadDajuAvatar(_ image: UIImage) async -> Bool {
        await uploadAvatar(image, for: "ai")
    }

    private func uploadAvatar(_ image: UIImage, for target: String?) async -> Bool {
        guard let session = auth.session,
              let target,
              let data = image.jpegData(compressionQuality: 0.85) else { return false }
        guard let uploaded = try? await messageStore.uploadMedia(
            data: data, mimeType: "image/jpeg", purpose: .avatar, session: session) else { return false }
        if let url = ServerConfig.resolveMediaURL(uploaded.url) {
            ImageCache.shared.store(data: data, image: image, for: url)
        }
        shared.setAvatar(uploaded.url, for: target, session: session)
        return true
    }

    func retryFailedMessage(_ message: ChatMessage) async -> OutboxRetryResult {
        guard let session = auth.session else { return .notFound }
        return await messageStore.retryFailedMessage(
            clientId: message.clientId ?? message.id, session: session)
    }

    func discardFailedMessage(_ message: ChatMessage) async {
        await messageStore.discardFailedMessage(clientId: message.clientId ?? message.id)
    }

    func markRead(_ channel: ChatChannel, through timestamp: Double) {
        messageStore.markRead(channel, through: timestamp)
    }

    func partnerHasRead(_ msg: ChatMessage) -> Bool {
        messageStore.partnerHasRead(msg, username: auth.session?.username)
    }

    func recallMessage(_ message: ChatMessage, channel: ChatChannel) { messageStore.recallMessage(message, channel: channel) }

    func confirmAction(messageId: String, decision: String) { messageStore.confirmAction(messageId: messageId, decision: decision) }

    func searchMessages(
        _ query: String,
        channel: ChatChannel,
        cursor: MessageSearchCursor? = nil
    ) async -> MessageSearchPage {
        await messageStore.searchMessages(query, channel: channel, cursor: cursor)
    }

    func ensureMessageLoaded(_ target: ChatMessage, channel: ChatChannel) async -> Bool {
        await messageStore.ensureMessageLoaded(target, channel: channel)
    }

    func loadReferencedMessage(id: String, channel: ChatChannel) async -> ChatMessage? {
        await messageStore.loadReferencedMessage(id: id, channel: channel)
    }

    func ensureDateLoaded(_ date: Date, channel: ChatChannel) async -> ChatMessage? {
        await messageStore.ensureDateLoaded(date, channel: channel)
    }

    func ensureLocalMessages(_ channel: ChatChannel) async {
        await messageStore.ensureLocalMessages(channel)
    }
    func restoreLatestMessages(_ channel: ChatChannel) async {
        await messageStore.restoreLatestMessages(channel)
    }

    func isLoadingOlder(_ channel: ChatChannel) -> Bool { messageStore.isLoadingOlder(channel) }
    func isLoadingNewer(_ channel: ChatChannel) -> Bool { messageStore.isLoadingNewer(channel) }
    func isShowingLatestWindow(_ channel: ChatChannel) -> Bool {
        messageStore.isShowingLatestWindow(channel)
    }
    func loadOlderAsync(_ channel: ChatChannel = .couple) async { await messageStore.loadOlderAsync(channel) }
    func loadNewerAsync(_ channel: ChatChannel = .couple) async { await messageStore.loadNewerAsync(channel) }

    func mediaMessages(
        for channel: ChatChannel,
        includeFiles: Bool = false,
        limit: Int? = nil
    ) async -> [ChatMessage] {
        await messageStore.mediaMessages(for: channel, includeFiles: includeFiles, limit: limit)
    }

    func mediaItemCount(for channel: ChatChannel, includeFiles: Bool = false) async -> Int {
        await messageStore.mediaItemCount(for: channel, includeFiles: includeFiles)
    }

    func reportAway(_ away: Bool) {
        if away {
            wasBackgrounded = true
            // 输入/生成状态只靠实时事件维持；App 挂起后可能错过结束事件，
            // 因此不能把它跨后台保留成持久状态。
            resetTransientAIState()
        }
        realtime.reportAway(away)
        if away { stopPersistentSyncLoop() } else { startPersistentSyncLoop() }
    }

    func recoverOnForeground() {
        // 即使系统没有及时送达 background，回前台也先丢弃旧的瞬时状态。
        // 最新回复会由 bootstrap/sync 补回，不能继续展示离线前的“正在输入”。
        resetTransientAIState()
        guard auth.session != nil else { return }
        let needsFreshSocket = wasBackgrounded
        wasBackgrounded = false
        reportAway(false)
        // iOS 暂停网络后，客户端仍可能暂时显示 connected，但底层连接已经失效。
        // 真正进过后台就立即重建；仅从系统弹窗的 inactive 返回则保留健康连接。
        if needsFreshSocket || !connected { realtime.forceReconnect() }
        Task {
            _ = await refreshBootstrap()
            await recoverSyncV2()
            _ = await verifyRealtimeHealth()
            if connected, let session = auth.session {
                messageStore.flushOutbox(session: session)
            }
        }
    }

    private func verifyRealtimeHealth() async -> Bool {
        await realtime.verifyHealth()
    }

    private func recoverSyncV2() async {
        guard !syncingV2, let session = auth.session else { return }
        let generation = auth.sessionGeneration
        syncingV2 = true
        defer { syncingV2 = false }
        let defaults = UserDefaults.standard
        let legacyKey = "sync.v2.cursor.\(session.username).\(Keychain.installationID())"
        let metaKey = "sync.v2.cursor.\(Keychain.installationID())"
        // 优先账号库 app_meta；兼容旧 UserDefaults 游标并迁移一次。
        var cursor = Int64((await persistence.metaValue(forKey: metaKey)).flatMap(Int64.init) ?? 0)
        if cursor == 0, let legacy = defaults.object(forKey: legacyKey) as? Int {
            cursor = Int64(legacy)
            if cursor > 0 {
                _ = await persistence.setMetaValue(String(cursor), forKey: metaKey)
            }
        }
        var changedEntityTypes = Set<String>()
        do {
            var hasMore = true
            while hasMore {
                guard auth.sessionGeneration == generation, auth.session?.username == session.username else { return }
                let page = try await syncV2.fetch(after: cursor, token: session.token)
                guard Self.validatedSyncMessageChannels(page.events) != nil else {
                    throw SyncV2Error.invalidPayload
                }
                for event in page.events where event.entityType == "message" && event.operation == "delete" {
                    guard let channel = Self.validatedSyncChannel(event.payload.channel) else {
                        throw SyncV2Error.invalidPayload
                    }
                    guard await messageStore.applyRecallPersisted(
                        id: event.payload.id ?? event.entityId,
                        channel: channel
                    ) else {
                        throw SyncV2Error.localPersistence
                    }
                }
                changedEntityTypes.formUnion(page.events.map(\.entityType))
                cursor = max(cursor, page.nextCursor)
                // 按页推进：与本页 delete 落库同代次后写入，减少崩溃窗口。
                _ = await persistence.setMetaValue(String(cursor), forKey: metaKey)
                defaults.set(Int(cursor), forKey: legacyKey)
                hasMore = page.hasMore
            }
            guard auth.sessionGeneration == generation, auth.session?.username == session.username else { return }
            await syncV2.acknowledge(cursor, token: session.token)
            if !changedEntityTypes.isEmpty {
                NotificationCenter.default.post(
                    name: .persistentSyncChanged,
                    object: nil,
                    userInfo: ["entityTypes": Array(changedEntityTypes)])
            }
        } catch SyncV2Error.unauthorized {
            auth.verifySessionOrLogout()
        } catch {
            // Socket/前台恢复会再次尝试；cursor 只在一页完整应用后推进。
        }
    }

    private func startPersistentSyncLoop() {
        guard persistentSyncTask == nil, auth.session != nil else { return }
        persistentSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                await self.recoverSyncV2()
            }
        }
    }

    private func stopPersistentSyncLoop() {
        persistentSyncTask?.cancel()
        persistentSyncTask = nil
    }

    @discardableResult
    func syncAllHistory(
        _ channel: ChatChannel,
        onProgress: @escaping (_ localCount: Int, _ remoteTotal: Int?) -> Void
    ) async -> MessageStore.HistorySyncResult {
        await messageStore.syncAllHistory(channel, onProgress: onProgress)
    }

    func clearLocalHistory() async {
        await messageStore.clearLocalHistory()
        Task { _ = await refreshBootstrap() }
    }
}
