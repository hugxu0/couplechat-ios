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

    static let personalItemChangedNotification = SharedStore.personalItemChangedNotification

    private var manager: SocketManager?
    private(set) var socket: SocketIOClient?
    /// Socket.IO 自己会在意外断开后重连；这个标志只负责避免前台恢复等调用重复发起握手。
    private var connectionAttemptInFlight = false
    private var connectionAttemptToken = UUID()
    private var reconnectAttempt = 0
    /// 健康检查失败时的受控重连。手动 disconnect 不会触发 Socket.IO 自动重连，
    /// 因而必须在 disconnect 回调中明确重新握手。
    private let httpClient: any HTTPClient
    var isConnected: Bool { connected }
    var sessionUsername: String? { auth.session?.username }
    var currentSession: Session? { auth.session }

    // MARK: - 统计/存储

    struct LocalStatsBuckets {
        let days: [DayStat]
        let months: [MonthStat]
    }

    struct StorageBreakdown {
        var imageCacheBytes: Int64
        var databaseBytes: Int64
        var cachedImageFiles: Int
        var coupleMessages: Int
        var aiMessages: Int
        var totalBytes: Int64 { imageCacheBytes + databaseBytes }
    }

    struct MediaCacheResult: Equatable {
        let total: Int
        let completed: Int
        let failed: Int
        var succeeded: Int { completed - failed }
    }

    private static let statsDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f
    }()

    private static let statsMonthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f
    }()

    private static var shanghaiCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal
    }()

    private static let weekdayLabels = ["日", "一", "二", "三", "四", "五", "六"]

    static func computeLocalStats(for channel: ChatChannel = .couple) -> LocalStatsBuckets {
        let cal = shanghaiCalendar
        let now = Date()
        let today = cal.startOfDay(for: now)
        let recentDayCount = 30

        var dayCounts: [String: [String: Int]] = [:]
        let earliestDay = cal.date(byAdding: .day, value: -(recentDayCount - 1), to: today) ?? today
        var monthCounts: [String: [String: Int]] = [:]
        let thisMonthStartInit = cal.date(from: cal.dateComponents([.year, .month], from: today)) ?? today
        var earliestMonth = thisMonthStartInit

        for row in ChatLocalDatabase.shared.dayCounts(channel: channel.rawValue) {
            guard let date = statsDayFormatter.date(from: row.date),
                  cal.startOfDay(for: date) >= earliestDay else { continue }
            var counts = dayCounts[row.date] ?? [:]
            counts[row.sender] = row.count
            dayCounts[row.date] = counts
        }

        for row in ChatLocalDatabase.shared.monthCounts(channel: channel.rawValue) {
            var counts = monthCounts[row.date] ?? [:]
            counts[row.sender] = row.count
            monthCounts[row.date] = counts
            if let date = statsMonthFormatter.date(from: row.date),
               let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: date)),
               monthStart < earliestMonth {
                earliestMonth = monthStart
            }
        }

        var days: [DayStat] = []
        var cursor = earliestDay
        while cursor <= today {
            let key = statsDayFormatter.string(from: cursor)
            let weekday = cal.isDate(cursor, inSameDayAs: today) ? "今" : weekdayLabels[cal.component(.weekday, from: cursor) - 1]
            days.append(DayStat(date: key, weekday: weekday, counts: dayCounts[key] ?? [:]))
            guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        var months: [MonthStat] = []
        var monthCursor = cal.date(from: cal.dateComponents([.year, .month], from: earliestMonth)) ?? earliestMonth
        let thisMonthStart = cal.date(from: cal.dateComponents([.year, .month], from: today)) ?? today
        while monthCursor <= thisMonthStart {
            let key = statsMonthFormatter.string(from: monthCursor)
            months.append(MonthStat(month: key, counts: monthCounts[key] ?? [:]))
            guard let next = cal.date(byAdding: .month, value: 1, to: monthCursor) else { break }
            monthCursor = next
        }

        return LocalStatsBuckets(days: days, months: months)
    }

    // MARK: - 初始化

    init(httpClient: any HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
        auth = AuthStore(httpClient: httpClient)
        messageStore = MessageStore(httpClient: httpClient)
        shared = SharedStore(httpClient: httpClient)
        auth.socketProvider = self
        messageStore.socketProvider = self
        shared.socketProvider = self
    }

    // MARK: - 启动

    func bootstrap() async {
        guard let session = auth.savedSession() else { return }
        let snapshotTask = Task { try await fetchBootstrap(session: session) }
        localCacheAvailable = await openLocalDatabase(username: session.username)
        if localCacheAvailable {
            await messageStore.restoreLocalCache(for: session)
            shared.restoreCachedSharedState()
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
            shared.restoreCachedSharedState()
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
        await Task.detached(priority: .utility) {
            ChatLocalDatabase.shared.open(username: username)
        }.value
    }

    private func fetchBootstrap(session: Session) async throws -> AppBootstrapSnapshot {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("api/bootstrap"))
        request.timeoutInterval = 15
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await httpClient.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BootstrapError.invalidResponse }
        if http.statusCode == 401 { throw BootstrapError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw BootstrapError.server(detail ?? "初始化失败（\(http.statusCode)）")
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
        socket?.disconnect()
        manager = nil
        socket = nil
        connected = false
        connectionAttemptInFlight = false
        connectionState = .disconnected
        partnerOnline = false
        presenceKnown = false
        aiActivityByChannel.removeAll()
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
        messageStore.sendText(text, channel: channel, replyTo: replyTo, replyPreview: replyPreview, session: session)
    }

    func sendMedia(data: Data, mimeType: String, preferredType: String, localPreviewURL: URL?, channel: ChatChannel = .couple, displayText: String? = nil) {
        guard let session = auth.session else { return }
        messageStore.sendMedia(data: data, mimeType: mimeType, preferredType: preferredType, localPreviewURL: localPreviewURL, channel: channel, displayText: displayText, session: session)
    }

    func sendSticker(url: String, channel: ChatChannel = .couple) {
        guard let session = auth.session else { return }
        messageStore.sendSticker(url: url, channel: channel, session: session)
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
        messageStore.sendInteraction(id: id, kind: kind, text: text, channel: channel, session: session)
        localInteractionPresentation = InteractionPresentation(
            payload: InteractionPayload(id: id, kind: kind, text: text),
            senderName: "已送达",
            duration: kind == .note ? 2.1 : 1.15)
    }

    func sendAlbum(resources: [OutboundMediaResource], displayText: String?, channel: ChatChannel = .couple) {
        guard let session = auth.session else { return }
        messageStore.sendAlbum(resources: resources, displayText: displayText, channel: channel, session: session)
    }

    func aiActivity(for channel: ChatChannel) -> AIActivity? {
        aiActivityByChannel[channel.rawValue]
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

    func resend(_ message: ChatMessage) {
        guard let session = auth.session else { return }
        messageStore.resend(message, session: session)
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

    func ensureMessageLoaded(_ target: ChatMessage, channel: ChatChannel) -> Bool {
        messageStore.ensureMessageLoaded(target, channel: channel)
    }

    func ensureDateLoaded(_ date: Date, channel: ChatChannel) async -> ChatMessage? {
        await messageStore.ensureDateLoaded(date, channel: channel)
    }

    func ensureLocalMessages(_ channel: ChatChannel) { messageStore.ensureLocalMessages(channel) }

    func isLoadingOlder(_ channel: ChatChannel) -> Bool { messageStore.isLoadingOlder(channel) }
    func isLoadingNewer(_ channel: ChatChannel) -> Bool { messageStore.isLoadingNewer(channel) }
    func loadOlderAsync(_ channel: ChatChannel = .couple) async { await messageStore.loadOlderAsync(channel) }
    func loadNewerAsync(_ channel: ChatChannel = .couple) async { await messageStore.loadNewerAsync(channel) }

    func mediaMessages(for channel: ChatChannel, includeFiles: Bool = false, limit: Int? = nil) -> [ChatMessage] {
        messageStore.mediaMessages(for: channel, includeFiles: includeFiles, limit: limit)
    }

    func mediaItemCount(for channel: ChatChannel, includeFiles: Bool = false) -> Int {
        messageStore.mediaItemCount(for: channel, includeFiles: includeFiles)
    }

    func reportAway(_ away: Bool) { socket?.emit(SocketEvent.away.rawValue, away) }

    func recoverOnForeground() {
        guard auth.session != nil else { return }
        reportAway(false)
        if !connected { connect() }
        Task {
            _ = await refreshBootstrap()
            _ = await verifyRealtimeHealth()
            if connected, let session = auth.session {
                messageStore.flushOutbox(session: session)
            }
        }
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

    // REST 桥接
    func fetchAccounts() async -> [Account] { await auth.fetchAccounts() }
    func fetchDaily() async -> DailyContent? {
        guard let token = auth.session?.token else { return nil }
        return await shared.fetchDaily(token: token)
    }
    func regenerateRecommendation() async -> Recommendation? {
        guard let token = auth.session?.token else { return nil }
        return await shared.regenerateRecommendation(token: token)
    }
    func fetchPersonalItems(kind: PersonalItemKind? = nil, scope: String = "personal") async -> [PersonalItem] {
        guard let token = auth.session?.token else { return [] }
        return await shared.fetchPersonalItems(kind: kind, scope: scope, token: token)
    }
    func createPersonalItem(kind: PersonalItemKind, scope: String = "personal", title: String, bodyMarkdown: String, dueAt: Int?) async -> PersonalItem? {
        guard let token = auth.session?.token else { return nil }
        return await shared.createPersonalItem(kind: kind, scope: scope, title: title, bodyMarkdown: bodyMarkdown, dueAt: dueAt, token: token)
    }
    func updatePersonalItem(_ item: PersonalItem, title: String? = nil, bodyMarkdown: String? = nil, dueAt: Int? = nil, clearsDueAt: Bool = false, isDone: Bool? = nil) async -> PersonalItem? {
        guard let token = auth.session?.token else { return nil }
        return await shared.updatePersonalItem(item, title: title, bodyMarkdown: bodyMarkdown, dueAt: dueAt, clearsDueAt: clearsDueAt, isDone: isDone, token: token)
    }
    func deletePersonalItem(_ item: PersonalItem) async -> Bool {
        guard let token = auth.session?.token else { return false }
        return await shared.deletePersonalItem(item, token: token)
    }
    func saveBarkKey(_ barkKey: String?) async -> Bool {
        guard let token = auth.session?.token else { return false }
        return await shared.saveBarkKey(barkKey, token: token)
    }

    func localStats(for channel: ChatChannel = .couple) -> LocalStatsBuckets {
        Self.computeLocalStats(for: channel)
    }

    func storageBreakdown() -> StorageBreakdown {
        shared.storageBreakdown()
    }

    func clearImageCache() { ImageCache.shared.clearAll() }

    @discardableResult
    func syncAllHistory(
        _ channel: ChatChannel,
        onProgress: @escaping (_ localCount: Int, _ remoteTotal: Int?) -> Void
    ) async -> MessageStore.HistorySyncResult {
        await messageStore.syncAllHistory(channel, onProgress: onProgress)
    }

    func cacheAllImages(
        _ channels: [ChatChannel] = ChatChannel.allCases,
        onProgress: @escaping (_ completed: Int, _ total: Int, _ failed: Int) -> Void
    ) async -> MediaCacheResult {
        let raws = channels.flatMap {
            ChatLocalDatabase.shared.mediaURLs(channel: $0.rawValue, types: ["image", "sticker"])
        }
        let urls = Array(Set(raws.compactMap { ServerConfig.resolveMediaURL($0) }))
        let total = urls.count
        onProgress(0, total, 0)
        var done = 0
        var failed = 0
        for url in urls {
            if Task.isCancelled { break }
            if !ImageCache.shared.isCached(url), await ImageCache.shared.image(for: url) == nil {
                failed += 1
            }
            done += 1
            onProgress(done, total, failed)
        }
        return MediaCacheResult(total: total, completed: done, failed: failed)
    }

    func clearLocalHistory() {
        messageStore.clearLocalHistory()
        Task { _ = await refreshBootstrap() }
    }
}

// SocketProvider conformance
extension ChatStore: SocketProvider {}
