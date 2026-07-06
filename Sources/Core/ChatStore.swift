import Foundation
import SocketIO
import SwiftUI

// 数据中枢：登录、Socket.IO 连接、消息收发、断线恢复。
// 服务端就是网页版同一套（chat.huhuhu.top），原生 App 是它的第三个客户端。

@MainActor
final class ChatStore: ObservableObject {
    static let baseURL = URL(string: "https://chat.huhuhu.top")!

    // MARK: 对外状态
    @Published var session: Session?
    @Published var connected = false
    @Published var messages: [ChatMessage] = []      // couple 频道
    @Published var partnerOnline = false
    @Published var partner: Account?
    @Published var readState: [String: Double] = [:] // username -> 已读到的 ts

    var loggedIn: Bool { session != nil }

    private var manager: SocketManager?
    private var socket: SocketIOClient?

    // MARK: 启动：钥匙串里有会话就直接连
    func bootstrap() {
        guard session == nil, let saved = Keychain.loadSession() else { return }
        session = saved
        connect()
    }

    // MARK: 登录
    func login(username: String, password: String) async throws {
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
        connect()
    }

    func logout() {
        Keychain.clearSession()
        session = nil
        messages = []
        socket?.disconnect()
        manager = nil
        socket = nil
        connected = false
    }

    func fetchAccounts() async -> [Account] {
        guard let (data, _) = try? await URLSession.shared.data(
            from: Self.baseURL.appendingPathComponent("api/accounts")) else { return [] }
        return (try? JSONDecoder().decode([Account].self, from: data)) ?? []
    }

    /// 从账号表里找出「对方」
    private func resolvePartner() {
        Task {
            let accounts = await fetchAccounts()
            if let me = session?.username {
                partner = accounts.first { $0.username != me }
            }
        }
    }

    // MARK: Socket 连接
    private func connect() {
        guard let session else { return }
        resolvePartner()
        let m = SocketManager(socketURL: Self.baseURL, config: [
            .compress,
            .reconnects(true),
            .reconnectWaitMax(5),
        ])
        manager = m
        let s = m.defaultSocket
        socket = s
        bindEvents(s)
        // 服务端握手鉴权读 handshake.auth.token
        s.connect(withPayload: ["token": session.token])
    }

    private func bindEvents(_ s: SocketIOClient) {
        s.on(clientEvent: .connect) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.connected = true
                self.reportAway(false)
                self.syncHistory()
            }
        }
        s.on(clientEvent: .disconnect) { [weak self] _, _ in
            Task { @MainActor in self?.connected = false }
        }
        s.on(clientEvent: .error) { [weak self] data, _ in
            // 鉴权失败（token 过期/失效）→ 退回登录页
            if let msg = data.first as? String, msg.contains("unauthorized") {
                Task { @MainActor in self?.logout() }
            }
        }

        s.on("message:new") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let msg = ChatMessage(dict: dict) else { return }
            Task { @MainActor in
                guard let self else { return }
                guard msg.channel == "couple" else { return } // ai 频道下一阶段接
                self.upsert(msg)
                self.markRead()
            }
        }

        s.on("presence") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let online = dict["online"] as? [String] else { return }
            Task { @MainActor in
                guard let self, let me = self.session else { return }
                self.partnerOnline = online.contains { $0 != me.username }
            }
        }

        s.on("read:init") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any] else { return }
            Task { @MainActor in
                self?.readState = dict.compactMapValues { ($0 as? NSNumber)?.doubleValue }
            }
        }
        s.on("read:update") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let user = dict["user"] as? String,
                  let ts = (dict["ts"] as? NSNumber)?.doubleValue else { return }
            Task { @MainActor in
                guard let self else { return }
                if ts > (self.readState[user] ?? 0) { self.readState[user] = ts }
            }
        }

        s.on("message:recalled") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let id = dict["id"] as? String else { return }
            let byName = dict["byName"] as? String
            Task { @MainActor in
                guard let self else { return }
                if let i = self.messages.firstIndex(where: { $0.id == id }) {
                    var m = self.messages[i]
                    let mine = m.sender == self.session?.username
                    m.kind = "system"
                    m.type = "text"
                    m.url = nil
                    m.text = mine ? "你撤回了一条消息" : "\(byName ?? "对方")撤回了一条消息"
                    self.messages[i] = m
                }
            }
        }
    }

    // MARK: 历史 / 补漏
    /// 连接（含重连）后同步：本地为空整批拉，否则只拉最后一条之后的增量
    private func syncHistory() {
        guard let s = socket else { return }
        let lastTs = messages.last(where: { !$0.pending && !$0.failed })?.ts ?? 0
        var payload: [String: Any] = ["channel": "couple", "limit": lastTs > 0 ? 300 : 80]
        if lastTs > 0 { payload["since"] = lastTs }
        s.emitWithAck("messages:fetch", payload).timingOut(after: 9) { [weak self] data in
            guard let dict = data.first as? [String: Any],
                  let list = dict["list"] as? [[String: Any]] else { return }
            let incoming = list.compactMap { ChatMessage(dict: $0) }
            Task { @MainActor in
                guard let self else { return }
                if lastTs > 0 {
                    incoming.forEach { self.upsert($0) }
                } else {
                    self.messages = incoming
                }
                self.markRead()
            }
        }
    }

    /// 上滑加载更早记录
    func loadOlder() {
        guard let s = socket, connected, let first = messages.first else { return }
        s.emitWithAck("messages:fetch", ["channel": "couple", "before": first.ts, "limit": 50])
            .timingOut(after: 9) { [weak self] data in
                guard let dict = data.first as? [String: Any],
                      let list = dict["list"] as? [[String: Any]] else { return }
                let older = list.compactMap { ChatMessage(dict: $0) }
                Task { @MainActor in
                    guard let self, !older.isEmpty else { return }
                    let known = Set(self.messages.map(\.id))
                    self.messages.insert(contentsOf: older.filter { !known.contains($0.id) }, at: 0)
                }
            }
    }

    // MARK: 发送（乐观上屏）
    func sendText(_ text: String) {
        guard let session, let s = socket else { return }
        let clientId = "tmp-" + UUID().uuidString
        let optimistic = ChatMessage(optimisticText: text, me: session, clientId: clientId, channel: "couple")
        messages.append(optimistic)

        let payload: [String: Any] = ["type": "text", "text": text, "channel": "couple", "clientId": clientId]
        s.emitWithAck("message:send", payload).timingOut(after: 15) { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                guard let i = self.messages.firstIndex(where: { $0.id == clientId }) else { return }
                if let dict = data.first as? [String: Any],
                   dict["ok"] as? Bool == true, let realId = dict["id"] as? String {
                    var m = self.messages[i]
                    // 广播若已先到并按 clientId 替换过占位，这里就找不到了，天然幂等
                    m = ChatMessage(dict: [
                        "id": realId, "sender": m.sender, "senderName": m.senderName,
                        "kind": m.kind, "type": m.type, "text": m.text,
                        "channel": m.channel, "ts": m.ts,
                    ]) ?? m
                    self.messages[i] = m
                } else {
                    self.messages[i].pending = false
                    self.messages[i].failed = true
                }
            }
        }
    }

    /// 重发失败消息
    func resend(_ message: ChatMessage) {
        guard message.failed else { return }
        messages.removeAll { $0.id == message.id }
        sendText(message.text)
    }

    private func upsert(_ msg: ChatMessage) {
        // 先按真实 id 去重，再按乐观占位的临时 id 对号入座
        if let i = messages.firstIndex(where: { $0.id == msg.id || (msg.clientId != nil && $0.id == msg.clientId) }) {
            messages[i] = msg
            return
        }
        // 常见情况是追加到尾部；乱序时按 ts 插入
        if let last = messages.last, last.ts > msg.ts,
           let i = messages.lastIndex(where: { $0.ts <= msg.ts }) {
            messages.insert(msg, at: i + 1)
        } else {
            messages.append(msg)
        }
    }

    // MARK: 已读 / 前后台
    /// 把「我已读到最新」上报给服务端（对方气泡上的双勾就是靠这个）
    func markRead() {
        guard let s = socket, connected,
              let lastTs = messages.last(where: { !$0.pending })?.ts else { return }
        s.emit("read", ["ts": lastTs])
    }

    /// 我发的消息对方是否已读
    func partnerHasRead(_ msg: ChatMessage) -> Bool {
        guard let me = session?.username else { return false }
        let partnerTs = readState.first(where: { $0.key != me })?.value ?? 0
        return msg.ts <= partnerTs
    }

    /// 前后台切换上报：服务端据此决定「对方不在看 → 走系统推送」
    func reportAway(_ away: Bool) {
        socket?.emit("away", away)
    }

    /// 回前台：health 探测假连接，通了就增量补漏
    func recoverOnForeground() {
        guard let s = socket else { return }
        reportAway(false)
        guard connected else { s.connect(); return }
        s.emitWithAck("health").timingOut(after: 2.5) { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                if data.first is [String: Any] {
                    self.syncHistory() // 管道活着，补漏
                } else {
                    // iOS 冻结后的假连接：ack 超时，强制重连
                    self.socket?.disconnect()
                    self.socket?.connect(withPayload: ["token": self.session?.token ?? ""])
                }
            }
        }
    }
}
