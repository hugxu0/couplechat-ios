import Foundation

/// 共享状态（纪念日/头像/贴条）+ REST 调用（每日内容/提醒/Bark），从 ChatStore 拆出。
@MainActor
final class SharedStore: ObservableObject {
    @Published var sharedState: [String: Any] = [:]

    static let personalItemChangedNotification = Notification.Name("personalItemChanged")

    private let httpClient: any HTTPClient
    private let persistence: any ChatPersistenceProtocol

    init(
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        persistence: any ChatPersistenceProtocol = ChatPersistence.shared
    ) {
        self.httpClient = httpClient
        self.persistence = persistence
    }

    weak var socketProvider: SocketProvider?

    // MARK: - 共享状态读写

    func setShared(_ key: String, value: [String: Any], session: Session?) {
        sharedState[key] = ["key": key, "value": value]
        if let valueJson = jsonObjectString(value) {
            Task {
                await persistence.saveSharedState(
                    key: key, valueJson: valueJson,
                    updatedBy: session?.username ?? "",
                    updatedAt: Date().timeIntervalSince1970 * 1000)
            }
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
        guard let username, !username.isEmpty else { return nil }
        if let value = sharedValue("avatar_\(username)"),
           let raw = value["url"] as? String {
            return ServerConfig.resolveMediaURL(raw)
        }
        // 旧网页后端把两人的头像合并在 avatars 对象中。
        if let raw = sharedValue("avatars")?[username] as? String {
            return ServerConfig.resolveMediaURL(raw)
        }
        return nil
    }

    func setAvatar(_ url: String, for username: String, session: Session?) {
        setShared("avatar_\(username)", value: ["url": url], session: session)
    }

    // MARK: - 从 Socket 事件更新

    func applySharedInit(_ state: [String: Any]) {
        var sanitizedState: [String: Any] = [:]
        var persisted: [(String, String, String, Double)] = []
        for (key, val) in state {
            if let dict = val as? [String: Any],
               let value = dict["value"],
               let valueJson = jsonObjectString(value) {
                sanitizedState[key] = dict
                let updatedBy = dict["updatedBy"] as? String ?? ""
                let updatedAt = (dict["updatedAt"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000
                persisted.append((key, valueJson, updatedBy, updatedAt))
            } else {
                // 旧数据可能含有顶层字符串、数组或 null。共享状态契约只接受对象；
                // 非法值可能使 NSJSONSerialization 抛出 Objective-C 异常，不能影响登录。
                print("[SharedStore] 忽略格式不合法的共享状态: \(key)")
            }
        }
        sharedState = sanitizedState
        Task {
            for row in persisted {
                await persistence.saveSharedState(
                    key: row.0, valueJson: row.1, updatedBy: row.2, updatedAt: row.3)
            }
        }
    }

    func applySharedUpdate(_ update: [String: Any]) {
        guard let key = update["key"] as? String else { return }
        if let value = update["value"],
           let valueJson = jsonObjectString(value) {
            sharedState[key] = update
            let updatedBy = update["updatedBy"] as? String ?? ""
            let updatedAt = (update["updatedAt"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000
            Task {
                await persistence.saveSharedState(
                    key: key, valueJson: valueJson, updatedBy: updatedBy, updatedAt: updatedAt)
            }
        } else {
            print("[SharedStore] 忽略格式不合法的共享状态更新: \(key)")
        }
    }

    func restoreCachedSharedState() async {
        sharedState = await persistence.loadSharedState()
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

    // MARK: - 私有辅助

    /// `try?` 不能捕获 Foundation 的 Objective-C NSException。先验证顶层 JSON
    /// 对象，确保历史异常值不会在登录阶段造成 abort。
    private func jsonObjectString(_ value: Any) -> String? {
        guard value is [String: Any],
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

}
