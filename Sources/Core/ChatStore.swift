import Foundation
import SocketIO
import SwiftUI

/// 协调层：持有 socket，分发事件给子 store，对外暴露统一接口。
/// 子 store：AuthStore（登录）、MessageStore（消息）、SharedStore（共享状态）。
@MainActor
final class ChatStore: ObservableObject {
    static let baseURL = ServerConfig.baseURL

    // MARK: - 子 store

    let auth = AuthStore()
    let messages = MessageStore()
    let shared = SharedStore()

    // MARK: - 对外聚合状态

    @Published var connected = false
    @Published var partnerOnline = false
    @Published var lastConnectionError: String?

    // 便捷访问（保持向后兼容，减少子 store 的改动量）
    var session: Session? { auth.session }
    var loggedIn: Bool { auth.loggedIn }
    var partner: Account? { auth.partner }
    var messagesByChannel: [String: [ChatMessage]] { messages.messagesByChannel }
    var readStates: [String: [String: Double]] { messages.readStates }
    var sharedState: [String: Any] { shared.sharedState }
    var aiTyping: Bool { messages.aiTyping }
    var aiReplying: Bool { messages.aiReplying }

    static let personalItemChangedNotification = SharedStore.personalItemChangedNotification

    private var manager: SocketManager?
    private(set) var socket: SocketIOClient?
    var isConnected: Bool { connected }
    var sessionUsername: String? { auth.session?.username }

    // MARK: - 统计/存储（保留为静态方法供 SharedStore 调用）

    struct LocalStatsBuckets {
        let days: [DayStat]
        let months: [MonthStat]
    }

    struct StorageBreakdown {
        var imageCacheBytes: Int64
        var databaseBytes: Int64
        var coupleMessages: Int
        var aiMessages: Int
        var totalBytes: Int64 { imageCacheBytes + databaseBytes }
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

    init() {
        auth.socketProvider = self
        messages.socketProvider = self
        shared.socketProvider = self
    }

    // MARK: - 启动

    func bootstrap() {
        auth.bootstrap()
        guard let session = auth.session else { return }
        messages.restoreLocalCache(for: session)
        shared.restoreCachedSharedState()
        auth.restoreCachedPartner()
        connect()
    }

    // MARK: - 登录/登出

    func login(username: String, password: String) async throws {
        try await auth.login(username: username, password: password)
        guard let session = auth.session else { return }
        messages.restoreLocalCache(for: session)
        shared.restoreCachedSharedState()
        auth.resolvePartner()
        connect()
    }

    func logout() {
        socket?.disconnect()
        manager = nil
        socket = nil
        connected = false
        partnerOnline = false
        lastConnectionError = nil
        auth.logout()
        // 子 store 不需要手动清——auth.session = nil 后，UI 自然走登录页
    }

    // MARK: - Socket 连接

    private func connect() {
        guard let session = auth.session else { return }
        auth.resolvePartner()
        let m = SocketManager(socketURL: Self.baseURL, config: [
            .compress,
            .reconnects(true),
            .reconnectWaitMax(5),
            .connectParams(["token": session.token]),
        ])
        manager = m
        let s = m.defaultSocket
        socket = s
        bindEvents(s)
        s.connect(withPayload: ["token": session.token])
    }

    private func bindEvents(_ s: SocketIOClient) {
        s.on(clientEvent: .connect) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.connected = true
                self.lastConnectionError = nil
                self.reportAway(false)
                self.messages.syncHistory(.couple)
                self.messages.syncHistory(.ai)
            }
        }
        s.on(clientEvent: .disconnect) { [weak self] _, _ in
            Task { @MainActor in self?.connected = false }
        }
        s.on(clientEvent: .error) { [weak self] data, _ in
            Task { @MainActor in self?.handleSocketError(data) }
        }
        s.on("connect_error") { [weak self] data, _ in
            Task { @MainActor in self?.handleSocketError(data) }
        }

        // 消息事件 → MessageStore
        s.on("message:new") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let msg = MessageStore.parseMessage(dict, context: "message:new") else { return }
            Task { @MainActor in
                guard let self else { return }
                let channel = ChatChannel(rawValue: msg.channel) ?? .couple
                self.messages.upsert(msg, in: channel)
                if channel == .couple { self.messages.markRead(.couple) }
                if channel == .ai {
                    self.messages.aiTyping = false
                    self.messages.aiReplying = false
                }
            }
        }
        s.on("read:init") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any] else { return }
            Task { @MainActor in self?.handleReadInit(dict) }
        }
        s.on("read:update") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let user = dict["user"] as? String,
                  let ts = (dict["ts"] as? NSNumber)?.doubleValue else { return }
            let channel = ChatChannel(rawValue: dict["channel"] as? String ?? "couple") ?? .couple
            Task { @MainActor in self?.messages.setReadState(channel, user: user, ts: ts) }
        }
        s.on("message:recalled") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let id = dict["id"] as? String else { return }
            let byName = dict["byName"] as? String
            let channel = ChatChannel(rawValue: dict["channel"] as? String ?? "")
            Task { @MainActor in self?.messages.applyRecall(id: id, byName: byName, channel: channel, myUsername: self?.auth.session?.username) }
        }
        s.on("message:update") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let id = dict["id"] as? String else { return }
            let metaDict = dict["meta"] as? [String: Any]
            Task { @MainActor in self?.messages.applyMessageUpdate(id: id, meta: metaDict) }
        }
        s.on("ai:typing") { [weak self] data, _ in
            let typing = (data.first as? Bool) ?? true
            Task { @MainActor in self?.messages.aiTyping = typing }
        }
        s.on("ai:replying") { [weak self] data, _ in
            let replying = (data.first as? Bool) ?? true
            Task { @MainActor in self?.messages.aiReplying = replying }
        }

        // 在线状态 → ConnectionStore
        s.on("presence") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let online = dict["online"] as? [String] else { return }
            Task { @MainActor in
                guard let self, let me = self.auth.session else { return }
                self.partnerOnline = online.contains { $0 != me.username }
            }
        }

        // 共享状态事件 → SharedStore
        s.on("shared:init") { [weak self] data, _ in
            guard let state = data.first as? [String: Any] else { return }
            Task { @MainActor in self?.shared.applySharedInit(state) }
        }
        s.on("shared:update") { [weak self] data, _ in
            guard let update = data.first as? [String: Any] else { return }
            Task { @MainActor in self?.shared.applySharedUpdate(update) }
        }
        s.on("personalItem:changed") { [weak self] data, _ in
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
        lastConnectionError = message.isEmpty ? "连接失败" : message
        connected = false
        if message.lowercased().contains("unauthorized") {
            auth.verifySessionOrLogout()
        }
    }

    private func handleReadInit(_ dict: [String: Any]) {
        if let state = dict["state"] as? [String: Any] {
            let channel = ChatChannel(rawValue: dict["channel"] as? String ?? "couple") ?? .couple
            messages.setReadState(channel, state: state.compactMapValues { ($0 as? NSNumber)?.doubleValue })
        } else {
            messages.setReadState(.couple, state: dict.compactMapValues { ($0 as? NSNumber)?.doubleValue })
        }
    }

    // MARK: - 便捷方法（桥接到子 store，保持向后兼容）

    func messages(for channel: ChatChannel) -> [ChatMessage] { messages.messages(for: channel) }

    func setShared(_ key: String, value: [String: Any]) {
        shared.setShared(key, value: value, session: auth.session)
    }

    func sharedValue(_ key: String) -> [String: Any]? { shared.sharedValue(key) }

    var coupleDates: CoupleDates { shared.coupleDates }
    func saveCoupleDates(_ dates: CoupleDates) { shared.saveCoupleDates(dates, session: auth.session) }
    var anniversaries: [AnniversaryEntry] { shared.anniversaries }
    func saveAnniversaries(_ items: [AnniversaryEntry]) { shared.saveAnniversaries(items, session: auth.session) }

    func avatarURL(for username: String?) -> URL? { shared.avatarURL(for: username) }

    func partnerAlias(for username: String?) -> String? { auth.partnerAlias(for: username) }
    func setPartnerAlias(_ alias: String?, for username: String?) { auth.setPartnerAlias(alias, for: username) }
    func partnerDisplayName(fallback: String = "对方") -> String { auth.partnerDisplayName(fallback: fallback) }

    func sendText(_ text: String, channel: ChatChannel = .couple, replyTo: String? = nil, replyPreview: String? = nil) {
        guard let session = auth.session else { return }
        messages.sendText(text, channel: channel, replyTo: replyTo, replyPreview: replyPreview, session: session)
    }

    func sendMedia(data: Data, mimeType: String, preferredType: String, localPreviewURL: URL?, channel: ChatChannel = .couple, displayText: String? = nil) {
        guard let session = auth.session else { return }
        messages.sendMedia(data: data, mimeType: mimeType, preferredType: preferredType, localPreviewURL: localPreviewURL, channel: channel, displayText: displayText, session: session)
    }

    func sendSticker(url: String, channel: ChatChannel = .couple) {
        guard let session = auth.session else { return }
        messages.sendSticker(url: url, channel: channel, session: session)
    }

    func uploadSticker(_ image: UIImage) async -> String? {
        guard let session = auth.session else { return nil }
        return await messages.uploadSticker(image, session: session)
    }

    func uploadAvatar(_ image: UIImage) async -> Bool {
        guard let session = auth.session,
              let data = image.jpegData(compressionQuality: 0.85) else { return false }
        guard let uploaded = try? await messages.uploadMedia(data: data, mimeType: "image/jpeg", session: session) else { return false }
        if let url = ServerConfig.resolveMediaURL(uploaded.url) {
            ImageCache.shared.store(data: data, image: image, for: url)
        }
        shared.setAvatar(uploaded.url, for: session.username, session: session)
        return true
    }

    func resend(_ message: ChatMessage) {
        guard let session = auth.session else { return }
        messages.resend(message, session: session)
    }

    func markRead(_ channel: ChatChannel = .couple) { messages.markRead(channel) }

    func partnerHasRead(_ msg: ChatMessage) -> Bool {
        messages.partnerHasRead(msg, username: auth.session?.username)
    }

    func recallMessage(_ message: ChatMessage, channel: ChatChannel) { messages.recallMessage(message, channel: channel) }

    func confirmAction(messageId: String, decision: String) { messages.confirmAction(messageId: messageId, decision: decision) }

    func searchMessages(_ query: String, channel: ChatChannel) async -> [ChatMessage] {
        await messages.searchMessages(query, channel: channel)
    }

    func ensureMessageLoaded(_ target: ChatMessage, channel: ChatChannel) -> Bool {
        messages.ensureMessageLoaded(target, channel: channel)
    }

    func ensureDateLoaded(_ date: Date, channel: ChatChannel) -> ChatMessage? {
        messages.ensureDateLoaded(date, channel: channel)
    }

    func ensureLocalMessages(_ channel: ChatChannel) { messages.ensureLocalMessages(channel) }

    func isLoadingOlder(_ channel: ChatChannel) -> Bool { messages.isLoadingOlder(channel) }
    func isLoadingNewer(_ channel: ChatChannel) -> Bool { messages.isLoadingNewer(channel) }
    func loadOlderAsync(_ channel: ChatChannel = .couple) async { await messages.loadOlderAsync(channel) }
    func loadNewerAsync(_ channel: ChatChannel = .couple) async { await messages.loadNewerAsync(channel) }

    func mediaMessages(for channel: ChatChannel, includeFiles: Bool = false, limit: Int? = nil) -> [ChatMessage] {
        messages.mediaMessages(for: channel, includeFiles: includeFiles, limit: limit)
    }

    func mediaItemCount(for channel: ChatChannel, includeFiles: Bool = false) -> Int {
        messages.mediaItemCount(for: channel, includeFiles: includeFiles)
    }

    func reportAway(_ away: Bool) { socket?.emit("away", away) }

    func recoverOnForeground() {
        guard let s = socket else { return }
        reportAway(false)
        guard connected else {
            s.connect(withPayload: ["token": auth.session?.token ?? ""])
            return
        }
        s.emitWithAck("health").timingOut(after: 2.5) { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                if data.first is [String: Any] {
                    self.messages.syncHistory(.couple)
                    self.messages.syncHistory(.ai)
                } else {
                    self.socket?.disconnect()
                    self.socket?.connect(withPayload: ["token": self.auth.session?.token ?? ""])
                }
            }
        }
    }

    func refreshHomeData() async -> Bool {
        reportAway(false)
        guard let s = socket else { return false }
        if !connected {
            s.connect(withPayload: ["token": auth.session?.token ?? ""])
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard connected else { return false }
        return await withCheckedContinuation { continuation in
            s.emitWithAck("health").timingOut(after: 2.5) { [weak self] data in
                Task { @MainActor in
                    guard let self else {
                        continuation.resume(returning: false)
                        return
                    }
                    let ok = data.first is [String: Any]
                    if ok {
                        self.messages.syncHistory(.couple)
                        self.messages.syncHistory(.ai)
                    } else {
                        self.socket?.disconnect()
                        self.socket?.connect(withPayload: ["token": self.auth.session?.token ?? ""])
                    }
                    continuation.resume(returning: ok)
                }
            }
        }
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
    func syncAllHistory(_ channel: ChatChannel, onProgress: @escaping (Int) -> Void) async -> Int {
        await messages.syncAllHistory(channel, onProgress: onProgress)
    }

    func cacheAllImages(_ channel: ChatChannel, onProgress: @escaping (Int, Int) -> Void) async {
        let raws = ChatLocalDatabase.shared.mediaURLs(channel: channel.rawValue, types: ["image", "sticker"])
        let urls = raws.compactMap { ServerConfig.resolveMediaURL($0) }
        let total = urls.count
        onProgress(0, total)
        var done = 0
        for url in urls {
            if Task.isCancelled { break }
            if !ImageCache.shared.isCached(url) { _ = await ImageCache.shared.image(for: url) }
            done += 1
            onProgress(done, total)
        }
    }
}

// SocketProvider conformance
extension ChatStore: SocketProvider {}
