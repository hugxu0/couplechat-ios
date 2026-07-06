import Foundation
import Security

// 登录会话存钥匙串（比 UserDefaults 安全，卸载重装也可选择保留）。

enum Keychain {
    private static let service = "com.hugxu0.couplechat.session"
    private static let account = "current"
    private static let defaultsKey = "com.hugxu0.couplechat.session.backup"

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func saveSession(_ session: Session) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)

        let query = Self.query
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let updateStatus = SecItemUpdate(query as CFDictionary, [
            kSecValueData as String: data,
        ] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            SecItemAdd(attrs as CFDictionary, nil)
        }
    }

    static func loadSession() -> Session? {
        if let session = loadFromKeychain(query: Self.query) {
            return session
        }

        // 迁移旧版本：旧 query 没有 account，升级后读到就重存成新格式。
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let session = loadFromKeychain(query: legacyQuery) {
            saveSession(session)
            return session
        }

        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let session = try? JSONDecoder().decode(Session.self, from: data) {
            saveSession(session)
            return session
        }

        return nil
    }

    private static func loadFromKeychain(query baseQuery: [String: Any]) -> Session? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    static func clearSession() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        SecItemDelete(Self.query as CFDictionary)

        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(legacyQuery as CFDictionary)
    }
}
