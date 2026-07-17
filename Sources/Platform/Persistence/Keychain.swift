import Foundation
import Security

// 登录会话存钥匙串（比 UserDefaults 安全，卸载重装也可选择保留）。

enum Keychain {
    private static let service = "com.hugxu0.couplechat.session"
    private static let account = "current"
    private static let installationService = "com.hugxu0.couplechat.installation"
    private static let barkService = "com.hugxu0.couplechat.bark"

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    @discardableResult
    static func saveSession(_ session: Session) -> Bool {
        guard let data = try? JSONEncoder().encode(session) else {
            print("[Keychain] ⚠️ Session 编码失败，无法保存")
            return false
        }
        return save(data, query: Self.query, label: "Session")
    }

    static func loadSession() -> Session? {
        loadFromKeychain(query: Self.query)
    }

    private static func loadFromKeychain(query baseQuery: [String: Any]) -> Session? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                print("[Keychain] ⚠️ 读取失败 status=\(status)")
            }
            return nil
        }
        guard let data = result as? Data else {
            print("[Keychain] ⚠️ 读取结果非 Data 类型")
            return nil
        }
        guard let session = try? JSONDecoder().decode(Session.self, from: data) else {
            print("[Keychain] ⚠️ Session 解码失败，数据可能损坏")
            return nil
        }
        return session
    }

    static func clearSession() {
        // service 级删除确保登出和首次安装不会保留任何会话条目。
        let serviceQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(serviceQuery as CFDictionary)
    }

    // MARK: - Bark secret

    @discardableResult
    static func saveBarkKey(_ key: String, for username: String) -> Bool {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !value.isEmpty else { return false }
        return save(
            Data(value.utf8),
            query: passwordQuery(service: barkService, account: username),
            label: "Bark key")
    }

    static func loadBarkKey(for username: String) -> String? {
        guard !username.isEmpty,
              let data = loadData(
                query: passwordQuery(service: barkService, account: username),
                label: "Bark key"),
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    static func deleteBarkKey(for username: String) {
        guard !username.isEmpty else { return }
        SecItemDelete(passwordQuery(service: barkService, account: username) as CFDictionary)
    }

    static func installationID() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: installationService,
            kSecAttrAccount as String: "current",
        ]
        var readQuery = query
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        if SecItemCopyMatching(readQuery as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let value = String(data: data, encoding: .utf8),
           !value.isEmpty {
            return value
        }

        let value = "ios_\(UUID().uuidString.lowercased())"
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(attributes as CFDictionary, nil) != errSecSuccess {
            // Keychain 极少数情况下暂不可写；本次进程仍使用稳定的 UserDefaults 兜底。
            let fallbackKey = "com.hugxu0.couplechat.installation.fallback"
            if let fallback = UserDefaults.standard.string(forKey: fallbackKey) { return fallback }
            UserDefaults.standard.set(value, forKey: fallbackKey)
        }
        return value
    }

    private static func passwordQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func save(_ data: Data, query: [String: Any], label: String) -> Bool {
        let updateStatus = SecItemUpdate(query as CFDictionary, [
            kSecValueData as String: data,
        ] as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else {
            print("[Keychain] ⚠️ \(label) 更新失败 status=\(updateStatus)")
            return false
        }

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            print("[Keychain] ⚠️ \(label) 写入失败 status=\(addStatus)")
            return false
        }
        return true
    }

    private static func loadData(query baseQuery: [String: Any], label: String) -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                print("[Keychain] ⚠️ \(label) 读取失败 status=\(status)")
            }
            return nil
        }
        guard let data = result as? Data else {
            print("[Keychain] ⚠️ \(label) 读取结果非 Data 类型")
            return nil
        }
        return data
    }
}
