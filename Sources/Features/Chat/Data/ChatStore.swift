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

struct HomeRefreshResult: Equatable {
    let dataUpdated: Bool
    let realtimeConnected: Bool
}

/// 协调层：持有 socket，分发事件给子 store，对外暴露统一接口。
/// 子 store：AuthStore（登录）、MessageStore（消息）、SharedStore（共享状态）。
@MainActor
final class ChatStore: ObservableObject {
    static let baseURL = ServerConfig.baseURL

    // MARK: - 子 store

    let auth: AuthStore
    let messageStore: MessageStore
    let shared: SharedStore
    let localData: LocalDataRepository
    let dailyContent: DailyContentRepository
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
    @Published private(set) var localInteractionPresentation: InteractionPresentation?
    @Published private(set) var localCacheAvailable = true

    // 便捷访问（保持向后兼容）
    var session: Session? { auth.session }
    var loggedIn: Bool { auth.loggedIn }
    var partner: Account? { auth.partner }
    var messagesByChannel: [String: [ChatMessage]] { messageStore.messagesByChannel }
    var readStates: [String: [String: Double]] { messageStore.readStates }
    var sharedState: [String: Any] { shared.sharedState }
    var aiTyping: Bool { messageStore.aiTyping }
    var aiReplying: Bool { messageStore.aiReplying }

    /// 向后兼容：store.messages 返回 couple 频道消息数组
    var messages: [ChatMessage] { messageStore.messages(for: .couple) }

    lazy var realtime = RealtimeConnectionCoordinator(
        sessionProvider: { [weak self] in self?.auth.session },
        onSocketCreated: { [weak self] socket in self?.eventRouter.bind(socket) },
        onConnected: { [weak self] in
            guard let self, let session = self.auth.session else { return }
            self.messageStore.flushPendingReadReceipts()
            self.messageStore.flushOutbox(session: session)
            self.startPersistentSyncLoop()
            Task { await self.recoverSyncV2() }
        },
        onUnauthorized: { [weak self] in self?.auth.verifySessionOrLogout() })
    private lazy var eventRouter = RealtimeEventRouter(
        auth: auth,
        messageStore: messageStore,
        shared: shared,
        setAIActivity: { [weak self] channel, activity in
            guard let self else { return }
            if let activity {
                self.aiActivityByChannel[channel] = activity
            } else {
                self.aiActivityByChannel.removeValue(forKey: channel)
            }
        },
        setPartnerOnline: { [weak self] online in self?.partnerOnline = online },
        setPresenceKnown: { [weak self] known in self?.presenceKnown = known })
    private let httpClient: any HTTPClient
    private let persistence: any ChatPersistenceProtocol
    private var childStateCancellables = Set<AnyCancellable>()
    private var localAIActivityTokens: [String: UUID] = [:]
    private var syncingV2 = false
    private var persistentSyncTask: Task<Void, Never>?

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
        dailyContent = DailyContentRepository(httpClient: httpClient)
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
            auth.logout()
        } catch {
            // 已登录用户离线启动时仍可查看有界本地缓存；连接恢复后前台刷新会补最新快照。
            realtime.setLastError(error.localizedDescription)
        }
    }

    // MARK: - 登录/登出

    func login(username: String, password: String) async throws {
        let session = try await auth.authenticate(username: username, password: password)
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
                StickerStore.sharedKey(for: session.username)),
            legacySharedLibrary: shared.sharedValue("stickers"))
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
        stopPersistentSyncLoop()
        historySync.cancelForLogout()
        realtime.disconnect()
        partnerOnline = false
        presenceKnown = false
        aiActivityByChannel.removeAll()
        messageStore.aiTyping = false
        messageStore.aiReplying = false
        messageStore.resetPendingReadReceipts()
        realtime.setLastError(nil)
        StickerStore.shared.deactivate()
        MediaFavoriteStore.shared.deactivate()
        auth.logout()
        if let sessionToRevoke {
            Task { await auth.revokeCurrentDevice(sessionToRevoke) }
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

    func sendInteraction(kind: InteractionEffectKind, text: String, channel: ChatChannel = .couple) {
        guard let session = auth.session else { return }
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
            localInteractionPresentation = InteractionPresentation(
                payload: InteractionPayload(id: id, kind: kind, text: text),
                senderName: "已送达",
                duration: 1.15)
        }
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

    func searchMessages(_ query: String, channel: ChatChannel) async -> [ChatMessage] {
        await messageStore.searchMessages(query, channel: channel)
    }

    func ensureMessageLoaded(_ target: ChatMessage, channel: ChatChannel) async -> Bool {
        await messageStore.ensureMessageLoaded(target, channel: channel)
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
        realtime.reportAway(away)
        if away { stopPersistentSyncLoop() } else { startPersistentSyncLoop() }
    }

    func recoverOnForeground() {
        guard auth.session != nil else { return }
        reportAway(false)
        // 退后台可能留下陈旧的在途握手；前台恢复时由连接协调器重建。
        if !connected { realtime.forceReconnect() }
        Task {
            _ = await refreshBootstrap()
            await recoverSyncV2()
            _ = await verifyRealtimeHealth()
            if connected, let session = auth.session {
                messageStore.flushOutbox(session: session)
            }
        }
    }

    func refreshHomeData() async -> HomeRefreshResult {
        reportAway(false)
        if !connected { realtime.connect() }
        async let refreshed = refreshBootstrap()
        async let realtime = verifyRealtimeHealth()
        let result = await (refreshed, realtime)
        return HomeRefreshResult(dataUpdated: result.0, realtimeConnected: result.1)
    }

    private func verifyRealtimeHealth() async -> Bool {
        await realtime.verifyHealth()
    }

    private func recoverSyncV2() async {
        guard !syncingV2, let session = auth.session else { return }
        syncingV2 = true
        defer { syncingV2 = false }
        let defaults = UserDefaults.standard
        let key = "sync.v2.cursor.\(session.username).\(Keychain.installationID())"
        var cursor = Int64(defaults.object(forKey: key) as? Int ?? 0)
        var changedEntityTypes = Set<String>()
        do {
            var hasMore = true
            while hasMore {
                let page = try await syncV2.fetch(after: cursor, token: session.token)
                for event in page.events where event.entityType == "message" && event.operation == "delete" {
                    let channel = event.payload.channel.flatMap(ChatChannel.init(rawValue:))
                    messageStore.applyRecall(id: event.payload.id ?? event.entityId, channel: channel)
                }
                changedEntityTypes.formUnion(page.events.map(\.entityType))
                cursor = max(cursor, page.nextCursor)
                defaults.set(Int(cursor), forKey: key)
                hasMore = page.hasMore
            }
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
