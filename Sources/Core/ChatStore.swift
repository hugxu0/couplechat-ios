import Foundation
import SocketIO
import SwiftUI

/// 数据中枢：协调各个服务，提供统一的 API 给 UI 层
@MainActor
final class ChatStore: ObservableObject {
    // MARK: - 服务实例
    
    let authService = AuthService()
    let socketService = SocketService()
    let messageService = MessageService()
    let mediaService = MediaService()
    let sharedStateService = SharedStateService()
    
    // MARK: - 转发属性（保持向后兼容）
    
    @Published var partnerOnline = false
    @Published var partner: Account? {
        didSet {
            if let partner,
               let data = try? JSONEncoder().encode(partner) {
                UserDefaults.standard.set(data, forKey: "cached_partner_\(authService.session?.username ?? "")")
            }
        }
    }
    @Published var aiTyping = false
    @Published var aiReplying = false
    
    // 转发 session
    var session: Session? { authService.session }
    var loggedIn: Bool { authService.loggedIn }
    var connected: Bool { socketService.isConnected }
    var lastConnectionError: String? { socketService.lastConnectionError }
    
    // 转发消息相关
    var messagesByChannel: [String: [ChatMessage]] { messageService.messagesByChannel }
    var readStates: [String: [String: Double]] { messageService.readStates }
    var reachedOldestLocal: Set<String> { messageService.reachedOldestLocal }
    
    // 转发共享状态
    var sharedState: [String: Any] { sharedStateService.sharedState }
    
    // 兼容旧 UI
    var messages: [ChatMessage] { messageService.messages(for: .couple) }
    var readState: [String: Double] { messageService.readStates[ChatChannel.couple.rawValue] ?? [:] }
    
    static let personalItemChangedNotification = Notification.Name("personalItemChanged")
    
    // MARK: - 初始化
    
    init() {
        setupServiceDependencies()
        setupSocketEventHandlers()
    }
    
    private func setupServiceDependencies() {
        // 设置服务间的依赖关系
        messageService.socketService = socketService
        sharedStateService.socketService = socketService
        mediaService.session = authService.session
        sharedStateService.session = authService.session
        messageService.session = authService.session
    }
    
    private func setupSocketEventHandlers() {
        // Socket 连接事件
        socketService.onConnect = { [weak self] in
            Task { @MainActor in
                self?.handleConnect()
            }
        }
        
        socketService.onDisconnect = { [weak self] in
            Task { @MainActor in
                self?.handleDisconnect()
            }
        }
        
        // 消息事件
        socketService.onNewMessage = { [weak self] dict in
            Task { @MainActor in
                self?.handleNewMessage(dict)
            }
        }
        
        socketService.onPresence = { [weak self] online in
            Task { @MainActor in
                self?.handlePresence(online)
            }
        }
        
        socketService.onReadInit = { [weak self] dict in
            Task { @MainActor in
                self?.handleReadInit(dict)
            }
        }
        
        socketService.onReadUpdate = { [weak self] dict in
            Task { @MainActor in
                self?.handleReadUpdate(dict)
            }
        }
        
        socketService.onMessageRecalled = { [weak self] dict in
            Task { @MainActor in
                self?.handleMessageRecalled(dict)
            }
        }
        
        socketService.onMessageUpdate = { [weak self] dict in
            Task { @MainActor in
                self?.handleMessageUpdate(dict)
            }
        }
        
        // AI 事件
        socketService.onAiTyping = { [weak self] typing in
            Task { @MainActor in
                self?.aiTyping = typing
            }
        }
        
        socketService.onAiReplying = { [weak self] replying in
            Task { @MainActor in
                self?.aiReplying = replying
            }
        }
        
        // 共享状态事件
        socketService.onSharedInit = { [weak self] state in
            Task { @MainActor in
                self?.sharedStateService.handleSharedInit(state)
            }
        }
        
        socketService.onSharedUpdate = { [weak self] update in
            Task { @MainActor in
                self?.sharedStateService.handleSharedUpdate(update)
            }
        }
        
        socketService.onPersonalItemChanged = { [weak self] dict in
            Task { @MainActor in
                self?.handlePersonalItemChanged(dict)
            }
        }
    }
    
    // MARK: - 启动
    
    func bootstrap() {
        guard authService.session == nil else { return }
        
        if let saved = authService.bootstrap() {
            let _ = ChatLocalDatabase.shared.open(username: saved.username)
            messageService.session = saved
            messageService.restoreLocalCache(for: saved)
            sharedStateService.loadFromDatabase()
            
            // 恢复缓存的 partner
            if let data = UserDefaults.standard.data(forKey: "cached_partner_\(saved.username)"),
               let p = try? JSONDecoder().decode(Account.self, from: data) {
                partner = p
            }
            
            connect()
        }
    }
    
    // MARK: - 登录
    
    func login(username: String, password: String) async throws {
        let s = try await authService.login(username: username, password: password)
        let _ = ChatLocalDatabase.shared.open(username: s.username)
        messageService.session = s
        messageService.restoreLocalCache(for: s)
        sharedStateService.loadFromDatabase()
        connect()
    }
    
    // MARK: - 登出
    
    func logout() {
        authService.logout()
        socketService.disconnect()
        socketService.lastConnectionError = nil
        messageService.clearAll()
        sharedStateService.clearAll()
        partnerOnline = false
        aiTyping = false
        aiReplying = false
        ChatLocalDatabase.shared.close()
    }
    
    // MARK: - Socket 连接
    
    private func connect() {
        guard let session = authService.session else { return }
        resolvePartner()
        socketService.connect(token: session.token)
    }
    
    private func handleConnect() {
        messageService.clearReachedOldestLocal()
        reportAway(false)
        syncHistory(.couple)
        syncHistory(.ai)
    }
    
    private func handleDisconnect() {
        // 连接断开时的处理
    }
    
    // MARK: - 消息事件处理
    
    private func handleNewMessage(_ dict: [String: Any]) {
        guard let msg = ChatMessage(dict: dict) else { return }
        let channel = ChatChannel(rawValue: msg.channel) ?? .couple
        messageService.upsert(msg, in: channel)
        
        if channel == .couple {
            messageService.markRead(.couple)
        }
        
        if channel == .ai {
            aiTyping = false
            aiReplying = false
        }
    }
    
    private func handlePresence(_ online: [String]) {
        guard let me = authService.session?.username else { return }
        partnerOnline = online.contains { $0 != me }
    }
    
    private func handleReadInit(_ dict: [String: Any]) {
        // 新后端：{ channel, state }；旧后端：直接是 username -> ts
        if let state = dict["state"] as? [String: Any] {
            let channel = ChatChannel(rawValue: dict["channel"] as? String ?? "couple") ?? .couple
            messageService.setReadState(channel, state: state.compactMapValues { ($0 as? NSNumber)?.doubleValue })
        } else {
            messageService.setReadState(.couple, state: dict.compactMapValues { ($0 as? NSNumber)?.doubleValue })
        }
    }
    
    private func handleReadUpdate(_ dict: [String: Any]) {
        guard let user = dict["user"] as? String,
              let ts = (dict["ts"] as? NSNumber)?.doubleValue else { return }
        let channel = ChatChannel(rawValue: dict["channel"] as? String ?? "couple") ?? .couple
        messageService.setReadState(channel, user: user, ts: ts)
    }
    
    private func handleMessageRecalled(_ dict: [String: Any]) {
        guard let id = dict["id"] as? String else { return }
        let byName = dict["byName"] as? String
        let channel = ChatChannel(rawValue: dict["channel"] as? String ?? "")
        messageService.applyRecall(id: id, byName: byName, channel: channel)
    }
    
    private func handleMessageUpdate(_ dict: [String: Any]) {
        guard let id = dict["id"] as? String else { return }
        let metaDict = dict["meta"] as? [String: Any]
        applyMessageUpdate(id: id, meta: metaDict)
    }
    
    private func handlePersonalItemChanged(_ dict: [String: Any]) {
        guard let itemDict = dict["item"] as? [String: Any],
              let action = dict["action"] as? String else { return }
        
        // shared items only
        let scope = itemDict["scope"] as? String ?? "personal"
        guard scope == "shared" else { return }
        
        // 不是自己操作的才通知刷新
        let itemOwner = itemDict["owner"] as? String ?? ""
        if itemOwner != authService.session?.username {
            NotificationCenter.default.post(
                name: Self.personalItemChangedNotification,
                object: nil,
                userInfo: ["action": action, "item": itemDict]
            )
        }
    }
    
    // MARK: - 消息 API（转发到 MessageService）
    
    func messages(for channel: ChatChannel) -> [ChatMessage] {
        messageService.messages(for: channel)
    }
    
    func sendText(_ text: String, channel: ChatChannel = .couple,
                  replyTo: String? = nil, replyPreview: String? = nil) {
        messageService.sendText(text, channel: channel, replyTo: replyTo, replyPreview: replyPreview)
    }
    
    func sendMedia(data: Data, mimeType: String, preferredType: String, 
                   localPreviewURL: URL?, channel: ChatChannel = .couple, 
                   displayText: String? = nil) {
        Task {
            do {
                // 先上传媒体
                let uploaded = try await mediaService.uploadMedia(data: data, mimeType: mimeType)
                let type = preferredType == "file" ? "file" : (uploaded.type.isEmpty ? preferredType : uploaded.type)
                
                // 然后发送消息
                messageService.sendMedia(
                    url: uploaded.url,
                    type: type,
                    channel: channel,
                    displayText: displayText
                )
            } catch {
                // 上传失败，创建一个失败的消息
                guard let session = authService.session else { return }
                let clientId = "tmp-" + UUID().uuidString
                let outgoingText = displayText ?? mediaPlaceholderText(for: preferredType)
                let optimistic = ChatMessage(
                    optimisticMedia: preferredType,
                    text: outgoingText,
                    localURL: localPreviewURL?.absoluteString,
                    me: session,
                    clientId: clientId,
                    channel: channel.rawValue)
                messageService.updateMessages(channel) { $0.append(optimistic) }
                messageService.updateMessages(channel) { list in
                    guard let i = list.firstIndex(where: { $0.id == clientId }) else { return }
                    list[i].pending = false
                    list[i].failed = true
                }
            }
        }
    }
    
    private func mediaPlaceholderText(for type: String) -> String {
        switch type {
        case "video": return "[视频]"
        case "voice": return "[语音]"
        case "file": return "[文件]"
        default: return "[图片]"
        }
    }
    
    func sendSticker(url: String, channel: ChatChannel = .couple) {
        messageService.sendSticker(url: url, channel: channel)
    }
    
    func recallMessage(_ message: ChatMessage, channel: ChatChannel) {
        messageService.recallMessage(message, channel: channel)
    }
    
    func resend(_ message: ChatMessage) {
        messageService.resend(message)
    }
    
    func markRead(_ channel: ChatChannel = .couple) {
        messageService.markRead(channel)
    }
    
    func partnerHasRead(_ msg: ChatMessage) -> Bool {
        messageService.partnerHasRead(msg)
    }
    
    func searchMessages(_ query: String, channel: ChatChannel) async -> [ChatMessage] {
        await messageService.searchMessages(query, channel: channel)
    }
    
    func mediaMessages(for channel: ChatChannel, includeFiles: Bool = false, limit: Int? = nil) -> [ChatMessage] {
        messageService.mediaMessages(for: channel, includeFiles: includeFiles, limit: limit)
    }
    
    func mediaItemCount(for channel: ChatChannel, includeFiles: Bool = false) -> Int {
        messageService.mediaItemCount(for: channel, includeFiles: includeFiles)
    }
    
    // MARK: - 加载历史
    
    func isLoadingOlder(_ channel: ChatChannel) -> Bool {
        messageService.isLoadingOlder(channel)
    }
    
    func loadOlder(_ channel: ChatChannel = .couple) {
        messageService.loadOlder(channel)
    }
    
    func loadOlderAsync(_ channel: ChatChannel = .couple) async {
        await messageService.loadOlderAsync(channel)
    }
    
    func ensureLocalMessages(_ channel: ChatChannel) {
        messageService.ensureLocalMessages(channel)
    }
    
    // MARK: - 媒体上传（转发到 MediaService）
    
    func uploadSticker(_ image: UIImage) async -> String? {
        await mediaService.uploadSticker(image)
    }
    
    func uploadAvatar(_ image: UIImage) async -> Bool {
        let success = await mediaService.uploadAvatar(image)
        
        // 获取上传后的 URL 并保存到共享状态
        if success, let username = authService.session?.username {
            // 这里需要获取上传后的 URL，但 MediaService.uploadAvatar 只返回 Bool
            // 暂时简化处理
        }
        
        return success
    }
    
    // MARK: - 共享状态（转发到 SharedStateService）
    
    func setShared(_ key: String, value: [String: Any]) {
        sharedStateService.setShared(key, value: value)
    }
    
    func sharedValue(_ key: String) -> [String: Any]? {
        sharedStateService.sharedValue(key)
    }
    
    var coupleDates: CoupleDates {
        sharedStateService.coupleDates
    }
    
    func saveCoupleDates(_ dates: CoupleDates) {
        sharedStateService.saveCoupleDates(dates)
    }
    
    var anniversaries: [AnniversaryEntry] {
        sharedStateService.anniversaries
    }
    
    func saveAnniversaries(_ items: [AnniversaryEntry]) {
        sharedStateService.saveAnniversaries(items)
    }
    
    func avatarURL(for username: String?) -> URL? {
        sharedStateService.avatarURL(for: username)
    }
    
    // MARK: - 备注管理
    
    func partnerAlias(for username: String?) -> String? {
        guard let username, !username.isEmpty else { return nil }
        let value = UserDefaults.standard.string(forKey: "partner_alias_\(username)")
        return (value?.isEmpty == false) ? value : nil
    }
    
    func setPartnerAlias(_ alias: String?, for username: String?) {
        guard let username, !username.isEmpty else { return }
        let key = "partner_alias_\(username)"
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(String(trimmed.prefix(12)), forKey: key)
        }
        
        objectWillChange.send()
    }
    
    func partnerDisplayName(fallback: String = "对方") -> String {
        if let alias = partnerAlias(for: partner?.username) { return alias }
        return partner?.name ?? fallback
    }
    
    // MARK: - 前后台切换
    
    func reportAway(_ away: Bool) {
        socketService.emit("away", away)
    }
    
    func recoverOnForeground() {
        reportAway(false)
        
        guard connected else {
            socketService.reconnect(token: authService.session?.token ?? "")
            return
        }
        
        socketService.emitWithAck("health", timeout: 2.5) { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                if data.first is [String: Any] {
                    self.syncHistory(.couple)
                    self.syncHistory(.ai)
                } else {
                    self.socketService.reconnect(token: self.authService.session?.token ?? "")
                }
            }
        }
    }
    
    // MARK: - 历史同步
    
    private func syncHistory(_ channel: ChatChannel, roundsLeft: Int = 5) {
        guard roundsLeft > 0 else { return }
        
        let local = messageService.messages(for: channel)
        let lastTs = local.last(where: { !$0.pending && !$0.failed })?.ts ?? 0
        let limit = 100
        
        var payload: [String: Any] = ["channel": channel.rawValue, "limit": limit]
        if lastTs > 0 { payload["since"] = lastTs }
        
        socketService.emitWithAck("messages:fetch", timeout: 9, payload) { [weak self] data in
            guard let dict = data.first as? [String: Any],
                  let list = dict["list"] as? [[String: Any]] else { return }
            
            let incoming = list.compactMap { ChatMessage(dict: $0) }
            
            Task { @MainActor in
                guard let self else { return }
                self.messageService.upsertBatch(incoming, in: channel)
                
                if channel == .couple {
                    self.messageService.markRead(.couple)
                }
                
                // 离线太久时缺口可能超过一页，继续增量拉直到补齐
                if lastTs > 0, incoming.count >= limit {
                    self.syncHistory(channel, roundsLeft: roundsLeft - 1)
                }
            }
        }
    }
    
    // MARK: - 辅助方法
    
    private func resolvePartner() {
        Task {
            let accounts = await fetchAccounts()
            if let me = authService.session?.username {
                partner = accounts.first { $0.username != me }
            }
        }
    }
    
    func fetchAccounts() async -> [Account] {
        guard let baseURL = URL(string: "https://hoo66.top/api/accounts"),
              let token = authService.session?.token else { return [] }
        
        var req = URLRequest(url: baseURL)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return [] }
        return (try? JSONDecoder().decode([Account].self, from: data)) ?? []
    }
    
    private func applyMessageUpdate(id: String, meta: [String: Any]?) {
        for c in ChatChannel.allCases {
            messageService.updateMessages(c) { list in
                guard let i = list.firstIndex(where: { $0.id == id }) else { return }
                var m = list[i]
                m.meta = meta.flatMap { ChatMessageMeta(dict: $0) }
                list[i] = m
                // 保存到数据库
                ChatLocalDatabase.shared.insertMessage(m)
            }
        }
    }
    
    // MARK: - 确认卡
    
    func confirmAction(messageId: String, decision: String) {
        socketService.emit("action:confirm", ["messageId": messageId, "decision": decision])
    }
    
    // MARK: - 统计
    
    struct LocalStatsBuckets {
        let days: [DayStat]
        let months: [MonthStat]
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
    
    /// 从本地已缓存的完整聊天记录聚合出逐日/逐月的双方消息数
    func localStats(for channel: ChatChannel = .couple) -> LocalStatsBuckets {
        let cal = Self.shanghaiCalendar
        let now = Date()
        let today = cal.startOfDay(for: now)
        
        let minRecentDays = 10
        let minRecentMonths = 12
        
        var dayCounts: [String: [String: Int]] = [:]
        var earliestDay = cal.date(byAdding: .day, value: -(minRecentDays - 1), to: today) ?? today
        var monthCounts: [String: [String: Int]] = [:]
        let thisMonthStartInit = cal.date(from: cal.dateComponents([.year, .month], from: today)) ?? today
        var earliestMonth = cal.date(byAdding: .month, value: -(minRecentMonths - 1), to: thisMonthStartInit) ?? thisMonthStartInit
        
        for row in ChatLocalDatabase.shared.dayCounts(channel: channel.rawValue) {
            var counts = dayCounts[row.date] ?? [:]
            counts[row.sender] = row.count
            dayCounts[row.date] = counts
            if let date = Self.statsDayFormatter.date(from: row.date) {
                let dayStart = cal.startOfDay(for: date)
                if dayStart < earliestDay { earliestDay = dayStart }
            }
        }
        
        for row in ChatLocalDatabase.shared.monthCounts(channel: channel.rawValue) {
            var counts = monthCounts[row.date] ?? [:]
            counts[row.sender] = row.count
            monthCounts[row.date] = counts
            if let date = Self.statsMonthFormatter.date(from: row.date),
               let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: date)),
               monthStart < earliestMonth {
                earliestMonth = monthStart
            }
        }
        
        var days: [DayStat] = []
        var cursor = earliestDay
        while cursor <= today {
            let key = Self.statsDayFormatter.string(from: cursor)
            let weekday = cal.isDate(cursor, inSameDayAs: today) ? "今" : Self.weekdayLabels[cal.component(.weekday, from: cursor) - 1]
            days.append(DayStat(date: key, weekday: weekday, counts: dayCounts[key] ?? [:]))
            guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        
        var months: [MonthStat] = []
        var monthCursor = cal.date(from: cal.dateComponents([.year, .month], from: earliestMonth)) ?? earliestMonth
        let thisMonthStart = cal.date(from: cal.dateComponents([.year, .month], from: today)) ?? today
        while monthCursor <= thisMonthStart {
            let key = Self.statsMonthFormatter.string(from: monthCursor)
            months.append(MonthStat(month: key, counts: monthCounts[key] ?? [:]))
            guard let next = cal.date(byAdding: .month, value: 1, to: monthCursor) else { break }
            monthCursor = next
        }
        
        return LocalStatsBuckets(days: days, months: months)
    }
    
    // MARK: - REST API
    
    func fetchStats() async -> StatsResponse? {
        guard let req = authorizedRequest("api/stats"),
              let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(StatsResponse.self, from: data)
    }
    
    func fetchDaily() async -> DailyContent? {
        guard let req = authorizedRequest("api/daily"),
              let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(DailyContent.self, from: data)
    }
    
    func regenerateRecommendation() async -> Recommendation? {
        guard let req = authorizedRequest("api/daily/recommend", method: "POST"),
              let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        struct Wrapper: Decodable { let recommend: Recommendation? }
        return (try? JSONDecoder().decode(Wrapper.self, from: data))?.recommend
    }
    
    func fetchPersonalItems(kind: PersonalItemKind? = nil, scope: String = "personal") async -> [PersonalItem] {
        var components: [String] = []
        if let kind { components.append("kind=\(kind.rawValue)") }
        components.append("scope=\(scope)")
        let path = "api/me/items?\(components.joined(separator: "&"))"
        guard let req = authorizedRequest(path),
              let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        struct Response: Decodable { let items: [PersonalItem] }
        return (try? JSONDecoder().decode(Response.self, from: data))?.items ?? []
    }
    
    func createPersonalItem(kind: PersonalItemKind, scope: String = "personal", title: String, bodyMarkdown: String, dueAt: Int?) async -> PersonalItem? {
        var body: [String: Any] = [
            "kind": kind.rawValue,
            "scope": scope,
            "title": title,
            "bodyMarkdown": bodyMarkdown,
        ]
        if let dueAt { body["dueAt"] = dueAt }
        return await sendPersonalItemRequest(path: "api/me/items", method: "POST", body: body)
    }
    
    func updatePersonalItem(_ item: PersonalItem, title: String? = nil, bodyMarkdown: String? = nil, dueAt: Int? = nil, clearsDueAt: Bool = false, isDone: Bool? = nil) async -> PersonalItem? {
        var body: [String: Any] = [:]
        if let title { body["title"] = title }
        if let bodyMarkdown { body["bodyMarkdown"] = bodyMarkdown }
        if clearsDueAt {
            body["dueAt"] = NSNull()
        } else if let dueAt {
            body["dueAt"] = dueAt
        }
        if let isDone { body["isDone"] = isDone }
        return await sendPersonalItemRequest(path: "api/me/items/\(item.id)", method: "PATCH", body: body)
    }
    
    func deletePersonalItem(_ item: PersonalItem) async -> Bool {
        guard let req = authorizedRequest("api/me/items/\(item.id)", method: "DELETE"),
              let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
    
    private func sendPersonalItemRequest(path: String, method: String, body: [String: Any]) async -> PersonalItem? {
        guard var req = authorizedRequest(path, method: method) else { return nil }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let code = (resp as? HTTPURLResponse)?.statusCode,
              (200..<300).contains(code) else { return nil }
        struct Response: Decodable { let item: PersonalItem }
        return (try? JSONDecoder().decode(Response.self, from: data))?.item
    }
    
    func saveBarkKey(_ barkKey: String?) async -> Bool {
        guard var req = authorizedRequest("api/me/push/bark", method: "POST") else { return false }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["barkKey": barkKey ?? NSNull()]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return true
    }
    
    private func authorizedRequest(_ path: String, method: String = "GET") -> URLRequest? {
        guard let token = authService.session?.token else { return nil }
        let url: URL
        if let relative = URL(string: path, relativeTo: ServerConfig.baseURL) {
            url = relative.absoluteURL
        } else {
            url = ServerConfig.baseURL.appendingPathComponent(path)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }
    
    func refreshHomeData() async -> Bool {
        reportAway(false)
        
        guard connected else {
            socketService.reconnect(token: authService.session?.token ?? "")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        
        guard connected else { return false }
        
        return await withCheckedContinuation { continuation in
            socketService.emitWithAck("health", timeout: 2.5) { [weak self] data in
                Task { @MainActor in
                    guard let self else {
                        continuation.resume(returning: false)
                        return
                    }
                    
                    let ok = data.first is [String: Any]
                    if ok {
                        self.syncHistory(.couple)
                        self.syncHistory(.ai)
                    } else {
                        self.socketService.reconnect(token: self.authService.session?.token ?? "")
                    }
                    
                    continuation.resume(returning: ok)
                }
            }
        }
    }
    
    // MARK: - 存储管理
    
    struct StorageBreakdown {
        var imageCacheBytes: Int64
        var databaseBytes: Int64
        var coupleMessages: Int
        var aiMessages: Int
        var totalBytes: Int64 { imageCacheBytes + databaseBytes }
    }
    
    func storageBreakdown() -> StorageBreakdown {
        StorageBreakdown(
            imageCacheBytes: ImageCache.shared.diskUsageBytes(),
            databaseBytes: ChatLocalDatabase.shared.databaseSizeBytes(),
            coupleMessages: ChatLocalDatabase.shared.messageCount(channel: ChatChannel.couple.rawValue),
            aiMessages: ChatLocalDatabase.shared.messageCount(channel: ChatChannel.ai.rawValue)
        )
    }
    
    func clearImageCache() {
        ImageCache.shared.clearAll()
    }
    
    @discardableResult
    func syncAllHistory(_ channel: ChatChannel, onProgress: @escaping (Int) -> Void) async -> Int {
        guard connected else { return 0 }
        
        var oldest = messageService.messages(for: channel).first?.ts
        var total = 0
        let pageLimit = 200
        
        while !Task.isCancelled {
            let batch: [ChatMessage] = await withCheckedContinuation { cont in
                var payload: [String: Any] = ["channel": channel.rawValue, "limit": pageLimit]
                if let oldest { payload["before"] = oldest }
                
                socketService.emitWithAck("messages:fetch", timeout: 15, payload) { data in
                    guard let dict = data.first as? [String: Any],
                          let list = dict["list"] as? [[String: Any]] else {
                        cont.resume(returning: [])
                        return
                    }
                    cont.resume(returning: list.compactMap { ChatMessage(dict: $0) })
                }
            }
            
            if batch.isEmpty { break }
            
            messageService.upsertBatch(batch, in: channel)
            total += batch.count
            onProgress(total)
            
            let batchOldest = batch.map(\.ts).min()
            if batch.count < pageLimit { break }
            if let batchOldest, let prev = oldest, batchOldest >= prev { break }
            oldest = batchOldest
        }
        
        // 刷新内存里的最新窗口
        let latest = ChatLocalDatabase.shared.fetchLatestMessages(channel: channel.rawValue, limit: 50)
        if !latest.isEmpty {
            messageService.updateMessages(channel) { $0 = latest }
        }
        
        return total
    }
    
    func cacheAllImages(_ channel: ChatChannel, onProgress: @escaping (Int, Int) -> Void) async {
        let raws = ChatLocalDatabase.shared.mediaURLs(channel: channel.rawValue, types: ["image", "sticker"])
        let urls = raws.compactMap { ServerConfig.resolveMediaURL($0) }
        let total = urls.count
        onProgress(0, total)
        
        var done = 0
        for url in urls {
            if Task.isCancelled { break }
            if !ImageCache.shared.isCached(url) {
                _ = await ImageCache.shared.image(for: url)
            }
            done += 1
            onProgress(done, total)
        }
    }
    
    // MARK: - 搜索/日历跳转辅助
    
    @discardableResult
    func ensureMessageLoaded(_ target: ChatMessage, channel: ChatChannel) -> Bool {
        if messages(for: channel).contains(where: { $0.id == target.id }) { return true }
        
        let window = ChatLocalDatabase.shared.fetchMessagesAround(
            channel: channel.rawValue,
            centerTimestamp: target.ts,
            beforeLimit: 36,
            afterLimit: 28)
        if !window.isEmpty {
            messageService.updateMessages(channel) { list in
                list = Self.mergedWindow(window, with: list, around: target.id)
            }
        }
        if !messages(for: channel).contains(where: { $0.id == target.id }) {
            messageService.upsert(target, in: channel)
        }
        return messages(for: channel).contains(where: { $0.id == target.id })
    }
    
    @discardableResult
    func ensureDateLoaded(_ date: Date, channel: ChatChannel) -> ChatMessage? {
        let range = Self.dayRange(for: date)
        var dayMessages = ChatLocalDatabase.shared.fetchMessages(
            channel: channel.rawValue,
            fromInclusive: range.start,
            toExclusive: range.end,
            limit: 80)
        
        if dayMessages.isEmpty, let socket = socketService, connected {
            socket.emitWithAck("messages:fetch", timeout: 9, [
                "channel": channel.rawValue,
                "after": range.start,
                "before": range.end,
                "limit": 80,
            ]) { data in
                guard let dict = data.first as? [String: Any],
                      let list = dict["list"] as? [[String: Any]] else { return }
                let incoming = list.compactMap { ChatMessage(dict: $0) }
                Task { @MainActor in
                    incoming.forEach { ChatLocalDatabase.shared.insertMessage($0) }
                }
            }
        }
        
        if dayMessages.isEmpty {
            return nil
        }
        
        guard let target = dayMessages.first else { return nil }
        let context = ChatLocalDatabase.shared.fetchMessagesAround(
            channel: channel.rawValue,
            centerTimestamp: target.ts,
            beforeLimit: 20,
            afterLimit: 44)
        if !context.isEmpty {
            dayMessages = context
        }
        messageService.updateMessages(channel) { list in
            list = Self.mergedWindow(dayMessages, with: list, around: target.id)
        }
        return target
    }
    
    private nonisolated static func mergedWindow(_ window: [ChatMessage], with current: [ChatMessage], around targetId: String) -> [ChatMessage] {
        guard !window.isEmpty else { return current }
        var seen = Set<String>()
        let merged = (window + current)
            .filter { message in
                guard !seen.contains(message.id) else { return false }
                seen.insert(message.id)
                return true
            }
            .sorted { $0.ts < $1.ts }
        
        guard let targetIndex = merged.firstIndex(where: { $0.id == targetId }) else {
            return Array(merged.suffix(90))
        }
        let lower = max(0, targetIndex - 36)
        let upper = min(merged.count, targetIndex + 42)
        return Array(merged[lower..<upper])
    }
    
    private nonisolated static func dayRange(for date: Date) -> (start: Double, end: Double) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let start = cal.startOfDay(for: date)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return (start.timeIntervalSince1970 * 1000, end.timeIntervalSince1970 * 1000)
    }
}
