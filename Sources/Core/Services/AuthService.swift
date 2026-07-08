import Foundation

/// 认证服务：处理登录、登出、会话管理
@MainActor
final class AuthService: ObservableObject {
    static let baseURL = ServerConfig.baseURL
    
    @Published var session: Session?
    
    var loggedIn: Bool { session != nil }
    
    // MARK: - 启动
    
    /// 从钥匙串恢复会话
    func bootstrap() -> Session? {
        guard session == nil else { return session }
        let saved = Keychain.loadSession()
        session = saved
        return saved
    }
    
    // MARK: - 登录
    
    func login(username: String, password: String) async throws -> Session {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("api/login"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["username": username, "password": password])
        
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw NSError(domain: "login", code: 1, userInfo: [NSLocalizedDescriptionKey: msg ?? "登录失败"])
        }
        
        let s = try JSONDecoder().decode(Session.self, from: data)
        Keychain.saveSession(s)
        session = s
        return s
    }
    
    // MARK: - 登出
    
    func logout() {
        Keychain.clearSession()
        session = nil
    }
    
    // MARK: - 会话验证
    
    /// 用 REST /api/me 核实 token；仅在服务端明确返回 401 时登出。
    /// 网络错误或服务端 5xx 都不登出，保留 session 等待下次重连。
    private var verifyingSession = false
    
    func verifySessionOrLogout() async {
        guard !verifyingSession, let token = session?.token else { return }
        verifyingSession = true
        defer { verifyingSession = false }
        
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("api/me"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return }
        
        if http.statusCode == 401 {
            logout()
        }
    }
}
