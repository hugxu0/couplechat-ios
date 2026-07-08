import Foundation
import UIKit

/// 共享状态服务：管理两人共享的状态（纪念日、头像等）
@MainActor
final class SharedStateService: ObservableObject {
    @Published var sharedState: [String: Any] = [:]
    
    var socketService: SocketService?
    var session: Session?
    
    private var database: ChatLocalDatabase?
    
    // MARK: - 初始化
    
    func loadFromDatabase() {
        database = ChatLocalDatabase.shared
        sharedState = database?.loadSharedState() ?? [:]
    }
    
    // MARK: - 共享状态读写
    
    func setShared(_ key: String, value: [String: Any]) {
        // 乐观更新本地
        sharedState[key] = ["key": key, "value": value]
        
        if let valueData = try? JSONSerialization.data(withJSONObject: value),
           let valueJson = String(data: valueData, encoding: .utf8) {
            database?.saveSharedState(
                key: key, 
                valueJson: valueJson, 
                updatedBy: session?.username ?? "", 
                updatedAt: Date().timeIntervalSince1970 * 1000
            )
        }
        
        guard let socket = socketService, socket.isConnected else { return }
        socket.emit("shared:set", ["key": key, "value": value])
    }
    
    /// 读某个 shared key 的 value
    func sharedValue(_ key: String) -> [String: Any]? {
        guard let entry = sharedState[key] as? [String: Any] else { return nil }
        return entry["value"] as? [String: Any]
    }
    
    func handleSharedInit(_ state: [String: Any]) {
        sharedState = state
        for (key, val) in state {
            if let dict = val as? [String: Any],
               let value = dict["value"],
               let valueData = try? JSONSerialization.data(withJSONObject: value),
               let valueJson = String(data: valueData, encoding: .utf8) {
                let updatedBy = dict["updatedBy"] as? String ?? ""
                let updatedAt = (dict["updatedAt"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000
                database?.saveSharedState(key: key, valueJson: valueJson, updatedBy: updatedBy, updatedAt: updatedAt)
            }
        }
    }
    
    func handleSharedUpdate(_ update: [String: Any]) {
        guard let key = update["key"] as? String else { return }
        sharedState[key] = update
        
        if let value = update["value"],
           let valueData = try? JSONSerialization.data(withJSONObject: value),
           let valueJson = String(data: valueData, encoding: .utf8) {
            let updatedBy = update["updatedBy"] as? String ?? ""
            let updatedAt = (update["updatedAt"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000
            database?.saveSharedState(key: key, valueJson: valueJson, updatedBy: updatedBy, updatedAt: updatedAt)
        }
    }
    
    // MARK: - 纪念日
    
    var coupleDates: CoupleDates {
        let v = sharedValue("dates")
        return CoupleDates(
            together: v?["together"] as? String,
            lastMeet: v?["lastMeet"] as? String,
            lastFight: v?["lastFight"] as? String)
    }
    
    func saveCoupleDates(_ dates: CoupleDates) {
        var value: [String: Any] = [:]
        if let t = dates.together { value["together"] = t }
        if let m = dates.lastMeet { value["lastMeet"] = m }
        if let f = dates.lastFight { value["lastFight"] = f }
        setShared("dates", value: value)
    }
    
    /// 自由添加的纪念日列表
    var anniversaries: [AnniversaryEntry] {
        if let raw = sharedValue("anniversaries")?["items"] as? [[String: Any]] {
            return raw.compactMap { AnniversaryEntry(dict: $0) }
        }
        
        // 旧版本兼容
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
    
    func saveAnniversaries(_ items: [AnniversaryEntry]) {
        setShared("anniversaries", value: ["items": items.map { $0.asDict }])
    }
    
    // MARK: - 头像
    
    /// 某个用户的头像地址
    func avatarURL(for username: String?) -> URL? {
        guard let username, !username.isEmpty,
              let value = sharedValue("avatar_\(username)"),
              let raw = value["url"] as? String else { return nil }
        return ServerConfig.resolveMediaURL(raw)
    }
    
    func setAvatarURL(_ url: String, for username: String) {
        setShared("avatar_\(username)", value: ["url": url])
    }
    
    // MARK: - 清理
    
    func clearAll() {
        sharedState = [:]
    }
}
