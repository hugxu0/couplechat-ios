import Foundation

/// 共享状态（纪念日/头像/贴条）+ REST 调用（每日内容/提醒/Bark），从 ChatStore 拆出。
@MainActor
final class SharedStore: ObservableObject {
    @Published var sharedState: [String: Any] = [:]

    static let personalItemChangedNotification = Notification.Name("personalItemChanged")

    private let httpClient: any HTTPClient

    init(httpClient: any HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    weak var socketProvider: SocketProvider?

    // MARK: - 共享状态读写

    func setShared(_ key: String, value: [String: Any], session: Session?) {
        sharedState[key] = ["key": key, "value": value]
        if let valueData = try? JSONSerialization.data(withJSONObject: value),
           let valueJson = String(data: valueData, encoding: .utf8) {
            ChatLocalDatabase.shared.saveSharedState(
                key: key, valueJson: valueJson,
                updatedBy: session?.username ?? "",
                updatedAt: Date().timeIntervalSince1970 * 1000)
        }
        guard let s = socketProvider?.socket, socketProvider?.isConnected == true else { return }
        s.emit(SocketEvent.sharedSet.rawValue, ["key": key, "value": value])
    }

    func sharedValue(_ key: String) -> [String: Any]? {
        guard let entry = sharedState[key] as? [String: Any] else { return nil }
        return entry["value"] as? [String: Any]
    }

    // MARK: - 纪念日

    var coupleDates: CoupleDates {
        let v = sharedValue("dates")
        return CoupleDates(
            together: v?["together"] as? String,
            lastMeet: v?["lastMeet"] as? String,
            lastFight: v?["lastFight"] as? String)
    }

    func saveCoupleDates(_ dates: CoupleDates, session: Session?) {
        var value: [String: Any] = [:]
        if let t = dates.together { value["together"] = t }
        if let m = dates.lastMeet { value["lastMeet"] = m }
        if let f = dates.lastFight { value["lastFight"] = f }
        setShared("dates", value: value, session: session)
    }

    var anniversaries: [AnniversaryEntry] {
        if let raw = sharedValue("anniversaries")?["items"] as? [[String: Any]] {
            return raw.compactMap { AnniversaryEntry(dict: $0) }
        }
        var legacy: [AnniversaryEntry] = []
        let dates = coupleDates
        if let m = dates.lastMeet {
            legacy.append(AnniversaryEntry(id: "legacy-meet", title: "距离上次见面", date: m, direction: .up, icon: "figure.2.arms.open"))
        }
        if let f = dates.lastFight {
            legacy.append(AnniversaryEntry(id: "legacy-fight", title: "距离上次吵架", date: f, direction: .up, icon: "cloud.sun"))
        }
        return legacy
    }

    func saveAnniversaries(_ items: [AnniversaryEntry], session: Session?) {
        setShared("anniversaries", value: ["items": items.map { $0.asDict }], session: session)
    }

    // MARK: - 头像

    func avatarURL(for username: String?) -> URL? {
        guard let username, !username.isEmpty,
              let value = sharedValue("avatar_\(username)"),
              let raw = value["url"] as? String else { return nil }
        return ServerConfig.resolveMediaURL(raw)
    }

    func setAvatar(_ url: String, for username: String, session: Session?) {
        setShared("avatar_\(username)", value: ["url": url], session: session)
    }

    // MARK: - 从 Socket 事件更新

    func applySharedInit(_ state: [String: Any]) {
        sharedState = state
        for (key, val) in state {
            if let dict = val as? [String: Any],
               let value = dict["value"],
               let valueData = try? JSONSerialization.data(withJSONObject: value),
               let valueJson = String(data: valueData, encoding: .utf8) {
                let updatedBy = dict["updatedBy"] as? String ?? ""
                let updatedAt = (dict["updatedAt"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000
                ChatLocalDatabase.shared.saveSharedState(key: key, valueJson: valueJson, updatedBy: updatedBy, updatedAt: updatedAt)
            }
        }
    }

    func applySharedUpdate(_ update: [String: Any]) {
        guard let key = update["key"] as? String else { return }
        sharedState[key] = update
        if let value = update["value"],
           let valueData = try? JSONSerialization.data(withJSONObject: value),
           let valueJson = String(data: valueData, encoding: .utf8) {
            let updatedBy = update["updatedBy"] as? String ?? ""
            let updatedAt = (update["updatedAt"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000
            ChatLocalDatabase.shared.saveSharedState(key: key, valueJson: valueJson, updatedBy: updatedBy, updatedAt: updatedAt)
        }
    }

    func restoreCachedSharedState() {
        sharedState = ChatLocalDatabase.shared.loadSharedState()
    }

    // MARK: - REST（每日内容 / 提醒 / Bark）

    private func authorizedRequest(_ path: String, method: String = "GET", token: String) -> URLRequest? {
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

    func fetchDaily(token: String) async -> DailyContent? {
        guard let req = authorizedRequest("api/daily", token: token) else {
            print("[SharedStore] ⚠️ fetchDaily: 未登录")
            return nil
        }
        guard let (data, resp) = try? await httpClient.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else {
            print("[SharedStore] ⚠️ fetchDaily: 请求失败")
            return nil
        }
        return try? JSONDecoder().decode(DailyContent.self, from: data)
    }

    func regenerateRecommendation(token: String) async -> Recommendation? {
        guard let req = authorizedRequest("api/daily/recommend", method: "POST", token: token) else { return nil }
        guard let (data, resp) = try? await httpClient.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        struct Wrapper: Decodable { let recommend: Recommendation? }
        return (try? JSONDecoder().decode(Wrapper.self, from: data))?.recommend
    }

    func fetchPersonalItems(kind: PersonalItemKind? = nil, scope: String = "personal", token: String) async -> [PersonalItem] {
        var components: [String] = []
        if let kind { components.append("kind=\(kind.rawValue)") }
        components.append("scope=\(scope)")
        let path = "api/me/items?\(components.joined(separator: "&"))"
        guard let req = authorizedRequest(path, token: token) else { return [] }
        guard let (data, resp) = try? await httpClient.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return (try? JSONDecoder().decode(PersonalItemsResponse.self, from: data))?.items ?? []
    }

    func createPersonalItem(kind: PersonalItemKind, scope: String = "personal", title: String, bodyMarkdown: String, dueAt: Int?, token: String) async -> PersonalItem? {
        var body: [String: Any] = ["kind": kind.rawValue, "scope": scope, "title": title, "bodyMarkdown": bodyMarkdown]
        if let dueAt { body["dueAt"] = dueAt }
        return await sendPersonalItemRequest(path: "api/me/items", method: "POST", body: body, token: token)
    }

    func updatePersonalItem(_ item: PersonalItem, title: String? = nil, bodyMarkdown: String? = nil, dueAt: Int? = nil, clearsDueAt: Bool = false, isDone: Bool? = nil, token: String) async -> PersonalItem? {
        var body: [String: Any] = [:]
        if let title { body["title"] = title }
        if let bodyMarkdown { body["bodyMarkdown"] = bodyMarkdown }
        if clearsDueAt { body["dueAt"] = NSNull() }
        else if let dueAt { body["dueAt"] = dueAt }
        if let isDone { body["isDone"] = isDone }
        return await sendPersonalItemRequest(path: "api/me/items/\(item.id)", method: "PATCH", body: body, token: token)
    }

    func deletePersonalItem(_ item: PersonalItem, token: String) async -> Bool {
        guard let req = authorizedRequest("api/me/items/\(item.id)", method: "DELETE", token: token) else { return false }
        guard let (_, resp) = try? await httpClient.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    func saveBarkKey(_ barkKey: String?, token: String) async -> Bool {
        guard var req = authorizedRequest("api/me/push/bark", method: "POST", token: token) else { return false }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["barkKey": barkKey ?? NSNull()]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, resp) = try? await httpClient.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else {
            print("[SharedStore] ⚠️ saveBarkKey: 请求失败")
            return false
        }
        return true
    }

    private func sendPersonalItemRequest(path: String, method: String, body: [String: Any], token: String) async -> PersonalItem? {
        guard var req = authorizedRequest(path, method: method, token: token) else { return nil }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await httpClient.data(for: req),
              let code = (resp as? HTTPURLResponse)?.statusCode,
              (200..<300).contains(code) else { return nil }
        return (try? JSONDecoder().decode(PersonalItemResponse.self, from: data))?.item
    }

    // MARK: - 统计 / 存储

    func localStats(for channel: ChatChannel = .couple) -> ChatStore.LocalStatsBuckets {
        // 委托给 ChatStore 的静态方法（不依赖实例状态）
        return ChatStore.computeLocalStats(for: channel)
    }

    func storageBreakdown() -> ChatStore.StorageBreakdown {
        ChatStore.StorageBreakdown(
            imageCacheBytes: ImageCache.shared.diskUsageBytes(),
            databaseBytes: ChatLocalDatabase.shared.databaseSizeBytes(),
            cachedImageFiles: ImageCache.shared.cachedFileCount(),
            coupleMessages: ChatLocalDatabase.shared.messageCount(channel: ChatChannel.couple.rawValue),
            aiMessages: ChatLocalDatabase.shared.messageCount(channel: ChatChannel.ai.rawValue))
    }

    // MARK: - 私有辅助

    private struct PersonalItemsResponse: Decodable {
        let items: [PersonalItem]
    }

    private struct PersonalItemResponse: Decodable {
        let item: PersonalItem
    }
}
