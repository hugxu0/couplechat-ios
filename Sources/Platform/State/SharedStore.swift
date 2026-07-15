import Foundation
import UIKit

/// 共享状态（纪念日/头像/贴条）+ REST 调用（提醒/Bark），从 ChatStore 拆出。
@MainActor
final class SharedStore: ObservableObject {
    @Published var sharedState: [String: Any] = [:]

    static let personalItemChangedNotification = Notification.Name("personalItemChanged")

    private let httpClient: any HTTPClient
    private let persistence: any ChatPersistenceProtocol
    private let defaults: UserDefaults
    private var activeUsername: String?
    private var pendingWrites: [String: [String: Any]] = [:]
    private var pendingWriteTokens: [String: UUID] = [:]

    init(
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        persistence: any ChatPersistenceProtocol = ChatPersistence.shared,
        defaults: UserDefaults = .standard
    ) {
        self.httpClient = httpClient
        self.persistence = persistence
        self.defaults = defaults
    }

    weak var socketProvider: SocketProvider?

    // MARK: - 共享状态读写

    func activate(username: String) {
        guard activeUsername != username else { return }
        activeUsername = username
        pendingWriteTokens.removeAll()
        pendingWrites = loadPendingWrites(username: username)
        overlayPendingWrites()
    }

    func deactivate() {
        activeUsername = nil
        pendingWrites.removeAll()
        pendingWriteTokens.removeAll()
    }

    func setShared(_ key: String, value: [String: Any], session: Session?) {
        guard let session else { return }
        if activeUsername != session.username { activate(username: session.username) }
        sharedState[key] = ["key": key, "value": value]
        pendingWrites[key] = value
        persistPendingWrites()
        if let valueJson = jsonObjectString(value) {
            Task {
                await persistence.saveSharedState(
                    key: key, valueJson: valueJson,
                    updatedBy: session.username,
                    updatedAt: Date().timeIntervalSince1970 * 1000)
            }
        }
        emitPendingWrite(key: key)
    }

    /// 断线期间的最后一次本地意图会持久化；重连后逐项带 ACK 重发。
    func flushPendingWrites() {
        for key in pendingWrites.keys.sorted() {
            emitPendingWrite(key: key)
        }
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
        overlayPendingWrites()
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
            if let pending = pendingWrites[key] {
                let updatedBy = update["updatedBy"] as? String
                if updatedBy == activeUsername, Self.jsonObjectsEqual(pending, value) {
                    pendingWrites.removeValue(forKey: key)
                    pendingWriteTokens.removeValue(forKey: key)
                    persistPendingWrites()
                } else {
                    // 本地还有更新未被服务端确认时，不能让较早的广播覆盖界面。
                    return
                }
            }
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
        overlayPendingWrites()
    }

    // MARK: - REST（提醒 / Bark）

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
        guard var req = authorizedRequest(
            "api/v2/me/devices/current/push/bark", method: "PUT", token: token) else { return false }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let info = Bundle.main.infoDictionary ?? [:]
        let body: [String: Any] = [
            "installationId": Keychain.installationID(),
            "platform": UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios",
            "deviceName": UIDevice.current.name,
            "appVersion": info["CFBundleShortVersionString"] as? String ?? "",
            "buildNumber": info["CFBundleVersion"] as? String ?? "",
            "locale": Locale.current.identifier,
            "timezone": TimeZone.current.identifier,
            "barkKey": barkKey ?? NSNull(),
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, resp) = try? await httpClient.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else {
            print("[SharedStore] ⚠️ saveBarkKey: 请求失败")
            return false
        }
        return true
    }

    func testBark(token: String) async -> Bool {
        guard let req = authorizedRequest(
            "api/v2/me/devices/current/push/bark/test", method: "POST", token: token),
              let (_, resp) = try? await httpClient.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: - 私有辅助

    private func emitPendingWrite(key: String) {
        guard let value = pendingWrites[key],
              let socket = socketProvider?.socket,
              socketProvider?.isConnected == true else { return }
        let token = UUID()
        pendingWriteTokens[key] = token
        socket.emitWithAck(SocketEvent.sharedSet.rawValue, ["key": key, "value": value])
            .timingOut(after: 9) { [weak self] response in
                Task { @MainActor in
                    guard let self,
                          self.pendingWriteTokens[key] == token,
                          let ack = response.first as? [String: Any],
                          ack["ok"] as? Bool == true else { return }
                    self.pendingWriteTokens.removeValue(forKey: key)
                    self.pendingWrites.removeValue(forKey: key)
                    self.persistPendingWrites()
                    if let update = ack["update"] as? [String: Any] {
                        self.applySharedUpdate(update)
                    }
                }
            }
    }

    private func overlayPendingWrites() {
        guard let username = activeUsername else { return }
        var next = sharedState
        for (key, value) in pendingWrites {
            next[key] = [
                "key": key,
                "value": value,
                "updatedBy": username,
                "updatedAt": Date().timeIntervalSince1970 * 1_000,
            ]
        }
        sharedState = next
    }

    private func pendingStorageKey(username: String) -> String {
        let safe = username.lowercased().map {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_"
        }
        return "shared.pending.\(String(safe))"
    }

    private func loadPendingWrites(username: String) -> [String: [String: Any]] {
        guard let data = defaults.data(forKey: pendingStorageKey(username: username)),
              let decoded = try? JSONSerialization.jsonObject(with: data),
              let object = decoded as? [String: Any] else {
            return [:]
        }
        return object.reduce(into: [:]) { result, item in
            if let value = item.value as? [String: Any] { result[item.key] = value }
        }
    }

    private func persistPendingWrites() {
        guard let username = activeUsername else { return }
        let key = pendingStorageKey(username: username)
        guard !pendingWrites.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        guard JSONSerialization.isValidJSONObject(pendingWrites),
              let data = try? JSONSerialization.data(withJSONObject: pendingWrites) else { return }
        defaults.set(data, forKey: key)
    }

    private static func jsonObjectsEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        guard JSONSerialization.isValidJSONObject(lhs), JSONSerialization.isValidJSONObject(rhs),
              let left = try? JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys]),
              let right = try? JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys]) else {
            return false
        }
        return left == right
    }

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
