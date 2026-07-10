import Foundation

/// 登录/登出/会话管理，从 ChatStore 拆出。
@MainActor
final class AuthStore: ObservableObject {
    @Published var session: Session?
    @Published private(set) var recoveredLocalCache = false
    @Published var partner: Account? {
        didSet {
            if let partner, let data = try? JSONEncoder().encode(partner) {
                UserDefaults.standard.set(data, forKey: "cached_partner_\(session?.username ?? "")")
            }
        }
    }

    var loggedIn: Bool { session != nil }

    private var verifyingSession = false
    private let httpClient: any HTTPClient
    weak var socketProvider: SocketProvider?

    init(httpClient: any HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    // MARK: - 启动

    func bootstrap() {
        guard session == nil, let saved = Keychain.loadSession() else { return }
        session = saved
        _ = ChatLocalDatabase.shared.openRecoveringIfNeeded(username: saved.username)
        recoveredLocalCache = ChatLocalDatabase.shared.lastOpenRecoveredCache
    }

    // MARK: - 登录

    func login(username: String, password: String) async throws {
        var req = URLRequest(url: ServerConfig.baseURL.appendingPathComponent("api/login"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["username": username, "password": password])
        let (data, resp) = try await httpClient.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw NSError(domain: "login", code: 1, userInfo: [NSLocalizedDescriptionKey: msg ?? "登录失败"])
        }
        let s = try JSONDecoder().decode(Session.self, from: data)
        Keychain.saveSession(s)
        session = s
        _ = ChatLocalDatabase.shared.openRecoveringIfNeeded(username: s.username)
        recoveredLocalCache = ChatLocalDatabase.shared.lastOpenRecoveredCache
    }

    // MARK: - 登出

    func logout() {
        Keychain.clearSession()
        session = nil
        partner = nil
        recoveredLocalCache = false
        ChatLocalDatabase.shared.close()
    }

    // MARK: - 账号

    func fetchAccounts() async -> [Account] {
        let req = URLRequest(url: ServerConfig.baseURL.appendingPathComponent("api/accounts"))
        guard let (data, _) = try? await httpClient.data(for: req) else {
            print("[AuthStore] ⚠️ fetchAccounts 网络请求失败")
            return []
        }
        guard let accounts = try? JSONDecoder().decode([Account].self, from: data) else {
            print("[AuthStore] ⚠️ fetchAccounts 解码失败")
            return []
        }
        return accounts
    }

    func resolvePartner() {
        Task {
            let accounts = await fetchAccounts()
            if let me = session?.username {
                partner = accounts.first { $0.username != me }
            }
        }
    }

    // MARK: - Token 核实

    func verifySessionOrLogout() {
        guard !verifyingSession, let token = session?.token else { return }
        verifyingSession = true
        Task {
            defer { verifyingSession = false }
            var req = URLRequest(url: ServerConfig.baseURL.appendingPathComponent("api/me"))
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard let (_, resp) = try? await httpClient.data(for: req),
                  let http = resp as? HTTPURLResponse else { return }
            if http.statusCode == 401 {
                logout()
            }
        }
    }

    // MARK: - 对方备注

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

    // MARK: - 恢复本地缓存

    func restoreCachedPartner() {
        guard let username = session?.username,
              let data = UserDefaults.standard.data(forKey: "cached_partner_\(username)"),
              let p = try? JSONDecoder().decode(Account.self, from: data) else { return }
        partner = p
    }
}
