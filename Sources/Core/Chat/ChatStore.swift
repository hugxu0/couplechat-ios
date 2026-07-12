import Combine
import Foundation
import SocketIO
import SwiftUI

/// 实时连接的显示状态。`connecting` / `reconnecting` 是正常过渡，不能被当作断联错误展示。
enum RealtimeConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case failed

    var isTransient: Bool {
        self == .connecting || self == .reconnecting
    }

    var isUnavailable: Bool {
        self == .disconnected || self == .failed
    }
}

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
    lazy var historySync = HistorySyncCoordinator(
        isLoggedIn: { [weak self] in self?.loggedIn == true },
        historyWorker: { [weak self] channel, onProgress in
            guard let self else {
                return HistorySyncCoordinator.HistoryResult(
                    remoteTotal: nil, downloaded: 0, error: "同步服务不可用")
            }
            let result = await self.syncAllHistory(channel, onProgress: onProgress)
            return HistorySyncCoordinator.HistoryResult(
                remoteTotal: result.remoteTotal,
                downloaded: result.downloaded,
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

    @Published private(set) var connected = false
    @Published private(set) var connectionState: RealtimeConnectionState = .disconnected
    @Published var partnerOnline = false
    @Published private(set) var presenceKnown = false
    @Published private(set) var aiActivityByChannel: [String: AIActivity] = [:]
    @Published private(set) var localInteractionPresentation: InteractionPresentation?
    @Published var lastConnectionError: String?
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

    private var manager: SocketManager?
    private(set) var socket: SocketIOClient?
    /// Socket.IO 自己会在意外断开后重连；这个标志只负责避免前台恢复等调用重复发起握手。
    private var connectionAttemptInFlight = false
    private var connectionAttemptToken = UUID()
    private var reconnectAttempt = 0
    /// 健康检查失败时的受控重连。手动 disconnect 不会触发 Socket.IO 自动重连，
    /// 因而必须在 disconnect 回调中明确重新握手。
    private let httpClient: any HTTPClient
    private let persistence: any ChatPersistenceProtocol
    private var childStateCancellables = Set<AnyCancellable>()
    private var localAIActivityTokens: [String: UUID] = [:]
    var isConnected: Bool { connected }
    var sessionUsername: String? { auth.session?.username }
    var currentSession: Session? { auth.session }

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
        auth.socketProvider = self
        messageStore.socketProvider = self
        shared.socketProvider = self

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
            .sink { [weak self] _ in self?.objectWillChange.send() }
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
        auth.restoreCachedPartner()
        connect()
        do {
            let snapshot = try await snapshotTask.value
            await messageStore.applyBootstrap(snapshot, session: session)
            shared.applySharedInit(snapshot.sharedState)
            auth.activate(session, accounts: snapshot.accounts, persist: false)
        } catch BootstrapError.unauthorized {
            auth.logout()
        } catch {
            // 已登录用户离线启动时仍可查看有界本地缓存；连接恢复后前台刷新会补最新快照。
            lastConnectionError = error.localizedDescription
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
        auth.restoreCachedPartner()
        connect()
        do {
            let snapshot = try await snapshotTask.value
            await messageStore.applyBootstrap(snapshot, session: session)
            shared.applySharedInit(snapshot.sharedState)
            auth.activate(session, accounts: snapshot.accounts, persist: false)
        } catch BootstrapError.unauthorized {
            logout()
            throw BootstrapError.unauthorized
        } catch {
            lastConnectionError = error.localizedDescription
        }
    }

    private func openLocalDatabase(username: String) async -> Bool {
        await persistence.open(username: username)
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
            auth.activate(session, accounts: snapshot.accounts, persist: false)
            lastConnectionError = nil
            return true
        } catch BootstrapError.unauthorized {
            logout()
            return false
        } catch {
            lastConnectionError = error.localizedDescription
            return false
        }
    }

    func logout() {
        historySync.cancelForLogout()
        socket?.disconnect()
        manager = nil
        socket = nil
        connected = false
        connectionAttemptInFlight = false
        connectionState = .disconnected
        partnerOnline = false
        presenceKnown = false
        aiActivityByChannel.removeAll()
        messageStore.aiTyping = false
        messageStore.aiReplying = false
        connectionAttemptToken = UUID()
        reconnectAttempt = 0
        lastConnectionError = nil
        auth.logout()
    }

    // MARK: - Socket 连接

    private func connect() {
        guard let session = auth.session else { return }
        let createdSocket = socket == nil
        if createdSocket {
            auth.resolvePartner()
            let m = SocketManager(socketURL: Self.baseURL, config: [
                .compress,
                .reconnects(true),
                .reconnectWaitMax(5),
            ])
            manager = m
            let s = m.defaultSocket
            socket = s
            bindEvents(s)
        }

        guard !connected, !connectionAttemptInFlight, let s = socket else { return }
        connectionAttemptInFlight = true
        connectionState = createdSocket ? .connecting : .reconnecting
        let attemptToken = UUID()
        connectionAttemptToken = attemptToken
        // 认证只随 Socket.IO auth payload 发送，不放入 URL 查询参数，避免 token 落入代理访问日志。
        s.connect(withPayload: ["token": session.token])
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, self.connectionAttemptToken == attemptToken, !self.connected,
                  self.auth.session != nil else { return }
            self.connectionAttemptInFlight = false
            self.socket?.disconnect()
            self.manager = nil
            self.socket = nil
            self.connectionState = .reconnecting
            self.reconnectAttempt += 1
            let delay = min(5.0, pow(1.7, Double(self.reconnectAttempt)) * 0.35)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self.connectionAttemptInFlight = false
            self.connect()
        }
    }

    private func bindEvents(_ s: SocketIOClient) {
        s.on(clientEvent: .connect) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.socket === s else { return }
                self.connected = true
                self.connectionAttemptInFlight = false
                self.connectionState = .connected
                self.reconnectAttempt = 0
                self.connectionAttemptToken = UUID()
                self.lastConnectionError = nil
                self.reportAway(false)
                if let session = self.auth.session {
                    self.messageStore.flushOutbox(session: session)
                }
            }
        }
        s.on(clientEvent: .disconnect) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.socket === s else { return }
                self.connected = false
                guard self.auth.loggedIn else {
                    self.connectionAttemptInFlight = false
                    self.connectionState = .disconnected
                    return
                }
                // 意外断开交由 Socket.IO 的重连策略处理；不在这里再手动 connect。
                self.connectionAttemptInFlight = true
                self.connectionState = .reconnecting
            }
        }
        s.on(clientEvent: .error) { [weak self] data, _ in
            Task { @MainActor in
                guard let self, self.socket === s else { return }
                self.handleSocketError(data)
            }
        }
        s.on(SocketEvent.connectError.rawValue) { [weak self] data, _ in
            Task { @MainActor in
                guard let self, self.socket === s else { return }
                self.handleSocketError(data)
            }
        }

        // 消息事件 -> MessageStore
        s.on(SocketEvent.messageNew.rawValue) { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let msg = MessageStore.parseMessage(dict, context: "message:new") else { return }
            Task { @MainActor in
                guard let self else { return }
                let channel = ChatChannel(rawValue: msg.channel) ?? .couple
                self.messageStore.upsert(msg, in: channel)
                if msg.sender == "ai" {
                    self.aiActivityByChannel.removeValue(forKey: channel.rawValue)
                }
                if channel == .couple { self.messageStore.markRead(.couple) }
                if channel == .ai {
                    self.messageStore.aiTyping = false
                    self.messageStore.aiReplying = false
                }
            }
        }
        s.on(SocketEvent.readUpdate.rawValue) { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let user = dict["user"] as? String,
                  let ts = (dict["ts"] as? NSNumber)?.doubleValue else { return }
            let channel = ChatChannel(rawValue: dict["channel"] as? String ?? "couple") ?? .couple
            Task { @MainActor in self?.messageStore.setReadState(channel, user: user, ts: ts) }
        }
        s.on(SocketEvent.messageRecalled.rawValue) { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let id = dict["id"] as? String else { return }
            let byName = dict["byName"] as? String
            let recalledText = dict["recalledText"] as? String
            let channel = ChatChannel(rawValue: dict["channel"] as? String ?? "")
            Task { @MainActor in self?.messageStore.applyRecall(id: id, byName: byName, channel: channel, myUsername: self?.auth.session?.username, recalledText: recalledText) }
        }
        s.on(SocketEvent.messageUpdate.rawValue) { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let id = dict["id"] as? String else { return }
            let metaDict = dict["meta"] as? [String: Any]
            Task { @MainActor in self?.messageStore.applyMessageUpdate(id: id, meta: metaDict) }
        }
        s.on(SocketEvent.aiTyping.rawValue) { [weak self] data, _ in
            let typing = (data.first as? Bool) ?? true
            Task { @MainActor in self?.messageStore.aiTyping = typing }
        }
        s.on(SocketEvent.aiReplying.rawValue) { [weak self] data, _ in
            let replying = (data.first as? Bool) ?? true
            Task { @MainActor in self?.messageStore.aiReplying = replying }
        }
        s.on(SocketEvent.aiActivity.rawValue) { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let rawChannel = dict["channel"] as? String,
                  let channel = ChatChannel(rawValue: rawChannel),
                  let phase = dict["phase"] as? String else { return }
            let activity = AIActivity(
                channel: channel,
                requestMessageId: dict["requestMessageId"] as? String,
                requesterUsername: dict["requesterUsername"] as? String,
                phase: phase)
            Task { @MainActor in
                guard let self else { return }
                guard self.socket === s else { return }
                if activity.isVisible {
                    self.aiActivityByChannel[channel.rawValue] = activity
                } else {
                    self.aiActivityByChannel.removeValue(forKey: channel.rawValue)
                }
            }
        }

        // 在线状态 -> ConnectionStore
        s.on(SocketEvent.presence.rawValue) { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let online = dict["online"] as? [String] else { return }
            Task { @MainActor in
                guard let self, let me = self.auth.session else { return }
                self.partnerOnline = online.contains { $0 != me.username }
                self.presenceKnown = true
            }
        }

        // 共享状态事件 -> SharedStore
        s.on(SocketEvent.sharedUpdate.rawValue) { [weak self] data, _ in
            guard let update = data.first as? [String: Any] else { return }
            Task { @MainActor in self?.shared.applySharedUpdate(update) }
        }
        s.on(SocketEvent.personalItemChanged.rawValue) { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let itemDict = dict["item"] as? [String: Any],
                  let action = dict["action"] as? String else { return }
            if dict["source"] as? String == "ai" {
                NotificationCenter.default.post(
                    name: PersonalItemsRepository.changedNotification,
                    object: nil,
                    userInfo: ["action": action, "item": itemDict])
                return
            }
            let scope = itemDict["scope"] as? String ?? "personal"
            guard scope == "shared" else { return }
            Task { @MainActor in
                guard let self else { return }
                let itemOwner = itemDict["owner"] as? String ?? ""
                if itemOwner != self.auth.session?.username {
                    NotificationCenter.default.post(
                        name: SharedStore.personalItemChangedNotification,
                        object: nil,
                        userInfo: ["action": action, "item": itemDict])
                }
            }
        }
    }

    private func handleSocketError(_ data: [Any]) {
        let message = data.compactMap { item -> String? in
            if let text = item as? String { return text }
            if let error = item as? Error { return error.localizedDescription }
            if let dict = item as? [String: Any] { return dict.values.map { "\($0)" }.joined(separator: " ") }
            return "\(item)"
        }.joined(separator: " ")
        connected = false
        if message.lowercased().contains("unauthorized") {
            connectionAttemptInFlight = false
            connectionState = .failed
            lastConnectionError = "登录已过期，请重新登录"
            auth.verifySessionOrLogout()
        } else {
            // 网络瞬断期间保持“重连中”，不要把正常恢复过程渲染为红色断联。
            connectionAttemptInFlight = true
            connectionState = .reconnecting
            lastConnectionError = nil
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

    func uploadSticker(_ image: UIImage) async -> String? {
        guard let session = auth.session else { return nil }
        return await messageStore.uploadSticker(image, session: session)
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

    func markRead(_ channel: ChatChannel = .couple) { messageStore.markRead(channel) }

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

    func reportAway(_ away: Bool) { socket?.emit(SocketEvent.away.rawValue, away) }

    func recoverOnForeground() {
        guard auth.session != nil else { return }
        reportAway(false)
        // 退后台会中断 socket，但 connectionAttemptInFlight 可能仍卡在 true，
        // 直接 connect() 会被守卫挡掉，于是只能干等 Socket.IO 慢慢重连、长时间
        // 显示“正在重连”。回前台若未真正连上，就强制丢弃陈旧 socket 重新握手。
        if !connected { forceReconnect() }
        Task {
            _ = await refreshBootstrap()
            _ = await verifyRealtimeHealth()
            if connected, let session = auth.session {
                messageStore.flushOutbox(session: session)
            }
        }
    }

    /// 丢弃可能已失效的 socket 与在途标志，立即重新发起握手。
    private func forceReconnect() {
        connectionAttemptToken = UUID()
        connectionAttemptInFlight = false
        reconnectAttempt = 0
        socket?.disconnect()
        manager = nil
        socket = nil
        connect()
    }

    func refreshHomeData() async -> HomeRefreshResult {
        reportAway(false)
        if !connected { connect() }
        async let refreshed = refreshBootstrap()
        async let realtime = verifyRealtimeHealth()
        let result = await (refreshed, realtime)
        return HomeRefreshResult(dataUpdated: result.0, realtimeConnected: result.1)
    }

    private func verifyRealtimeHealth() async -> Bool {
        if !connected { connect() }
        let deadline = Date().addingTimeInterval(2.2)
        while !connected, Date() < deadline {
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        guard connected, let socket else { return false }
        let result: [Any] = await withCheckedContinuation { continuation in
            socket.emitWithAck(SocketEvent.health.rawValue).timingOut(after: 1.5) {
                continuation.resume(returning: $0)
            }
        }
        let healthy = (result.first as? [String: Any])?["ok"] as? Bool == true
        if !healthy {
            connected = false
            connectionAttemptInFlight = false
            connectionState = .reconnecting
            manager = nil
            self.socket = nil
            connect()
        }
        return healthy
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

// SocketProvider conformance
extension ChatStore: SocketProvider {}
