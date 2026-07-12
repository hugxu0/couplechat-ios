import Foundation
import UIKit

/// 登录/登出/会话管理，从 ChatStore 拆出。
@MainActor
final class AuthStore: ObservableObject {
    @Published var session: Session?
    @Published private(set) var accounts: [Account] = []
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
    private let persistence: any ChatPersistenceProtocol
    weak var socketProvider: SocketProvider?

    init(
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        persistence: any ChatPersistenceProtocol = ChatPersistence.shared
    ) {
        self.httpClient = httpClient
        self.persistence = persistence
    }

    // MARK: - 启动

    func savedSession() -> Session? {
        // Keychain 可能跨卸载保留，而 UserDefaults 会随 App 删除。
        // 全新安装必须清掉残留会话，保证从账号选择与密码登录开始。
        let installMarker = "clean_install_generation_v2"
        guard UserDefaults.standard.bool(forKey: installMarker) else {
            let upgradedSession = Keychain.migrateLegacyDefaultsSessionIfPresent()
            if upgradedSession == nil { Keychain.clearSession() }
            UserDefaults.standard.set(true, forKey: installMarker)
            guard upgradedSession?.deviceId?.isEmpty == false else {
                Keychain.clearSession()
                return nil
            }
            return upgradedSession
        }
        guard let session = Keychain.loadSession() else { return nil }
        // V2 token 必须绑定 installation/session；旧 90 天账号 token 无法可靠撤销。
        guard session.deviceId?.isEmpty == false else {
            Keychain.clearSession()
            return nil
        }
        return session
    }

    // MARK: - 登录

    func authenticate(username: String, password: String) async throws -> Session {
        var req = URLRequest(url: ServerConfig.baseURL.appendingPathComponent("api/v2/login"))
        req.timeoutInterval = 15
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(
            LoginRequest(username: username, password: password, device: currentDevice()))
        let (data, resp) = try await httpClient.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let code = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            let message = ServerErrorCode.message(for: code, fallback: "登录失败")
            throw NSError(domain: "login", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return try JSONDecoder().decode(Session.self, from: data)
    }

    func register(username: String, displayName: String, password: String) async throws -> Session {
        var request = URLRequest(url: ServerConfig.baseURL.appendingPathComponent("api/v2/register"))
        request.timeoutInterval = 15
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RegisterRequest(
            username: username,
            displayName: displayName,
            password: password,
            device: currentDevice()))
        let (data, response) = try await httpClient.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 201 else {
            let code = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            let message = ServerErrorCode.message(for: code, fallback: "注册失败，请稍后重试")
            throw NSError(domain: "register", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return try JSONDecoder().decode(Session.self, from: data)
    }

    private func currentDevice() -> LoginDevice {
        let bundle = Bundle.main
        return LoginDevice(
            installationId: Keychain.installationID(),
            platform: UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios",
            deviceName: UIDevice.current.name,
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            locale: Locale.current.identifier,
            timezone: TimeZone.current.identifier)
    }

    func activate(_ newSession: Session, accounts: [Account], persist: Bool) {
        if persist { Keychain.saveSession(newSession) }
        session = newSession
        self.accounts = accounts
        partner = accounts.first { $0.username != newSession.username }
    }

    // MARK: - 登出

    func logout() {
        Keychain.clearSession()
        session = nil
        partner = nil
        accounts = []
        Task { await persistence.close() }
    }

    func revokeCurrentDevice(_ current: Session) async {
        guard let deviceId = current.deviceId,
              let encoded = deviceId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return }
        var request = URLRequest(
            url: ServerConfig.baseURL.appendingPathComponent("api/v2/me/devices/\(encoded)"))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 8
        request.setValue("Bearer \(current.token)", forHTTPHeaderField: "Authorization")
        _ = try? await httpClient.data(for: request)
    }

    // MARK: - 账号

    func fetchAccounts() async -> [Account] {
        var req = URLRequest(url: ServerConfig.baseURL.appendingPathComponent("api/accounts"))
        if let token = session?.token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, _) = try? await httpClient.data(for: req) else {
            print("[AuthStore] ⚠️ fetchAccounts 网络请求失败")
            return []
        }
        guard let accounts = try? JSONDecoder().decode([Account].self, from: data) else {
            print("[AuthStore] ⚠️ fetchAccounts 解码失败")
            return []
        }
        self.accounts = accounts
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

    func account(for username: String?) -> Account? {
        guard let username else { return nil }
        if partner?.username == username { return partner }
        return accounts.first { $0.username == username }
    }

    // MARK: - 恢复本地缓存

    func restoreCachedPartner() {
        guard let username = session?.username,
              let data = UserDefaults.standard.data(forKey: "cached_partner_\(username)"),
              let p = try? JSONDecoder().decode(Account.self, from: data) else { return }
        partner = p
    }
}

private struct LoginRequest: Encodable {
    let username: String
    let password: String
    let device: LoginDevice
}

private struct RegisterRequest: Encodable {
    let username: String
    let displayName: String
    let password: String
    let device: LoginDevice
}

private struct LoginDevice: Encodable {
    let installationId: String
    let platform: String
    let deviceName: String
    let appVersion: String
    let buildNumber: String
    let locale: String
    let timezone: String
}
