import Foundation
import SocketIO
import SwiftUI

// 数据中枢：登录、Socket.IO 连接、多频道消息、已读、断线恢复。
// 新后端契约见 server/docs/API.md；客户端只关心 couple / ai 两个逻辑频道。

@MainActor
final class ChatStore: ObservableObject {
    static let baseURL = URL(string: "https://hoo66.top")!

    // MARK: 对外状态
    @Published var session: Session?
    @Published var connected = false
    @Published private(set) var messagesByChannel: [String: [ChatMessage]] = [:]
    @Published var partnerOnline = false
    @Published var partner: Account?
    @Published private(set) var readStates: [String: [String: Double]] = [:]
    @Published var aiTyping = false
    @Published var sharedState: [String: Any] = [:]
    @Published var lastConnectionError: String?

    /// 兼容旧 UI：默认仍然表示 couple 频道。
    var messages: [ChatMessage] { messages(for: .couple) }
    var readState: [String: Double] { readState(for: .couple) }
    var loggedIn: Bool { session != nil }

    private var manager: SocketManager?
    private var socket: SocketIOClient?

    private struct UploadResponse: Decodable {
        let url: String
        let type: String
    }

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
        messagesByChannel = [:]
        readStates = [:]
        sharedState = [:]
        socket?.disconnect()
        manager = nil
        socket = nil
        connected = false
        partnerOnline = false
        aiTyping = false
        lastConnectionError = nil
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
        s.connect(withPayload: ["token": session.token])
    }

    private func bindEvents(_ s: SocketIOClient) {
        s.on(clientEvent: .connect) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.connected = true
                self.lastConnectionError = nil
                self.reportAway(false)
                self.syncHistory(.couple)
                self.syncHistory(.ai)
            }
        }
        s.on(clientEvent: .disconnect) { [weak self] _, _ in
            Task { @MainActor in self?.connected = false }
        }
        s.on(clientEvent: .error) { [weak self] data, _ in
            Task { @MainActor in self?.handleSocketError(data) }
        }

        s.on("connect_error") { [weak self] data, _ in
            Task { @MainActor in self?.handleSocketError(data) }
        }

        s.on("message:new") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let msg = ChatMessage(dict: dict) else { return }
            Task { @MainActor in
                guard let self else { return }
                let channel = ChatChannel(rawValue: msg.channel) ?? .couple
                self.upsert(msg, in: channel)
                if channel == .couple { self.markRead(.couple) }
                if channel == .ai { self.aiTyping = false }
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
            Task { @MainActor in self?.handleReadInit(dict) }
        }

        s.on("read:update") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let user = dict["user"] as? String,
                  let ts = (dict["ts"] as? NSNumber)?.doubleValue else { return }
            let channel = ChatChannel(rawValue: dict["channel"] as? String ?? "couple") ?? .couple
            Task { @MainActor in self?.setReadState(channel, user: user, ts: ts) }
        }

        s.on("message:recalled") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let id = dict["id"] as? String else { return }
            let byName = dict["byName"] as? String
            let channel = ChatChannel(rawValue: dict["channel"] as? String ?? "")
            Task { @MainActor in self?.applyRecall(id: id, byName: byName, channel: channel) }
        }

        s.on("ai:typing") { [weak self] data, _ in
            let typing = (data.first as? Bool) ?? true
            Task { @MainActor in self?.aiTyping = typing }
        }

        s.on("shared:init") { [weak self] data, _ in
            guard let state = data.first as? [String: Any] else { return }
            Task { @MainActor in self?.sharedState = state }
        }

        s.on("shared:update") { [weak self] data, _ in
            guard let update = data.first as? [String: Any],
                  let key = update["key"] as? String else { return }
            Task { @MainActor in self?.sharedState[key] = update }
        }
    }

    private func handleSocketError(_ data: [Any]) {
        let message = data.compactMap { item -> String? in
            if let text = item as? String { return text }
            if let error = item as? Error { return error.localizedDescription }
            if let dict = item as? [String: Any] { return dict.values.map { "\($0)" }.joined(separator: " ") }
            return "\(item)"
        }.joined(separator: " ")

        lastConnectionError = message.isEmpty ? "连接失败" : message
        connected = false
        if message.lowercased().contains("unauthorized") {
            logout()
        }
    }

    private func handleReadInit(_ dict: [String: Any]) {
        // 新后端：{ channel, state }；旧后端：直接是 username -> ts。
        if let state = dict["state"] as? [String: Any] {
            let channel = ChatChannel(rawValue: dict["channel"] as? String ?? "couple") ?? .couple
            setReadState(channel, state: state.compactMapValues { ($0 as? NSNumber)?.doubleValue })
        } else {
            setReadState(.couple, state: dict.compactMapValues { ($0 as? NSNumber)?.doubleValue })
        }
    }

    // MARK: 消息读写
    func messages(for channel: ChatChannel) -> [ChatMessage] {
        messagesByChannel[channel.rawValue] ?? []
    }

    private func updateMessages(_ channel: ChatChannel, _ transform: (inout [ChatMessage]) -> Void) {
        var next = messagesByChannel
        var list = next[channel.rawValue] ?? []
        transform(&list)
        next[channel.rawValue] = list
        messagesByChannel = next
    }

    private func upsert(_ msg: ChatMessage, in channel: ChatChannel) {
        updateMessages(channel) { list in
            if let i = list.firstIndex(where: { $0.id == msg.id || (msg.clientId != nil && $0.id == msg.clientId) }) {
                list[i] = msg
                return
            }
            if let last = list.last, last.ts > msg.ts,
               let i = list.lastIndex(where: { $0.ts <= msg.ts }) {
                list.insert(msg, at: i + 1)
            } else {
                list.append(msg)
            }
        }
    }

    private func replaceMessages(_ incoming: [ChatMessage], in channel: ChatChannel) {
        updateMessages(channel) { list in
            list = incoming
        }
    }

    // MARK: 历史 / 补漏
    private func syncHistory(_ channel: ChatChannel) {
        guard let s = socket else { return }
        let local = messages(for: channel)
        let lastTs = local.last(where: { !$0.pending && !$0.failed })?.ts ?? 0
        var payload: [String: Any] = ["channel": channel.rawValue, "limit": lastTs > 0 ? 300 : 80]
        if lastTs > 0 { payload["since"] = lastTs }
        s.emitWithAck("messages:fetch", payload).timingOut(after: 9) { [weak self] data in
            guard let dict = data.first as? [String: Any],
                  let list = dict["list"] as? [[String: Any]] else { return }
            let incoming = list.compactMap { ChatMessage(dict: $0) }
            Task { @MainActor in
                guard let self else { return }
                if lastTs > 0 {
                    incoming.forEach { self.upsert($0, in: channel) }
                } else {
                    self.replaceMessages(incoming, in: channel)
                }
                if channel == .couple { self.markRead(.couple) }
            }
        }
    }

    func loadOlder(_ channel: ChatChannel = .couple) {
        guard let s = socket, connected, let first = messages(for: channel).first else { return }
        s.emitWithAck("messages:fetch", ["channel": channel.rawValue, "before": first.ts, "limit": 50])
            .timingOut(after: 9) { [weak self] data in
                guard let dict = data.first as? [String: Any],
                      let list = dict["list"] as? [[String: Any]] else { return }
                let older = list.compactMap { ChatMessage(dict: $0) }
                Task { @MainActor in
                    guard let self, !older.isEmpty else { return }
                    self.updateMessages(channel) { current in
                        let known = Set(current.map(\.id))
                        current.insert(contentsOf: older.filter { !known.contains($0.id) }, at: 0)
                    }
                }
            }
    }

    // MARK: 发送（乐观上屏）
    func sendText(_ text: String, channel: ChatChannel = .couple) {
        guard let session, let s = socket else { return }
        let clientId = "tmp-" + UUID().uuidString
        let optimistic = ChatMessage(optimisticText: text, me: session, clientId: clientId, channel: channel.rawValue)
        updateMessages(channel) { $0.append(optimistic) }

        guard connected else {
            updateMessages(channel) { list in
                guard let i = list.firstIndex(where: { $0.id == clientId }) else { return }
                list[i].pending = false
                list[i].failed = true
            }
            lastConnectionError = "Socket 未连接"
            return
        }

        let payload: [String: Any] = [
            "type": "text",
            "text": text,
            "channel": channel.rawValue,
            "clientId": clientId,
        ]
        s.emitWithAck("message:send", payload).timingOut(after: 15) { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                var didFindPending = false
                self.updateMessages(channel) { list in
                    guard let i = list.firstIndex(where: { $0.id == clientId }) else { return }
                    didFindPending = true
                    if let dict = data.first as? [String: Any],
                       dict["ok"] as? Bool == true, let realId = dict["id"] as? String {
                        let old = list[i]
                        list[i] = ChatMessage(dict: [
                            "id": realId, "sender": old.sender, "senderName": old.senderName,
                            "kind": old.kind, "type": old.type, "text": old.text,
                            "channel": old.channel, "ts": old.ts,
                        ]) ?? old
                    } else {
                        list[i].pending = false
                        list[i].failed = true
                    }
                }
                _ = didFindPending // 广播先到时占位已被 upsert 替换，ack 无需再处理。
            }
        }
    }

    func sendMedia(data: Data, mimeType: String, preferredType: String, localPreviewURL: URL?, channel: ChatChannel = .couple) {
        guard let session, let s = socket else { return }
        let clientId = "tmp-" + UUID().uuidString
        let optimistic = ChatMessage(
            optimisticMedia: preferredType,
            text: preferredType == "video" ? "[视频]" : "[图片]",
            localURL: localPreviewURL?.absoluteString,
            me: session,
            clientId: clientId,
            channel: channel.rawValue)
        updateMessages(channel) { $0.append(optimistic) }

        guard connected else {
            updateMessages(channel) { list in
                guard let i = list.firstIndex(where: { $0.id == clientId }) else { return }
                list[i].pending = false
                list[i].failed = true
            }
            lastConnectionError = "Socket 未连接"
            return
        }

        Task {
            do {
                let uploaded = try await uploadMedia(data: data, mimeType: mimeType)
                let type = uploaded.type.isEmpty ? preferredType : uploaded.type
                updateMessages(channel) { list in
                    guard let i = list.firstIndex(where: { $0.id == clientId }) else { return }
                    list[i].type = type
                    list[i].url = uploaded.url
                }
                let payload: [String: Any] = [
                    "type": type,
                    "text": type == "video" ? "[视频]" : "[图片]",
                    "url": uploaded.url,
                    "channel": channel.rawValue,
                    "clientId": clientId,
                ]
                s.emitWithAck("message:send", payload).timingOut(after: 15) { [weak self] data in
                    Task { @MainActor in
                        guard let self else { return }
                        self.handleSendAck(data, clientId: clientId, channel: channel)
                    }
                }
            } catch {
                updateMessages(channel) { list in
                    guard let i = list.firstIndex(where: { $0.id == clientId }) else { return }
                    list[i].pending = false
                    list[i].failed = true
                }
            }
        }
    }

    private func uploadMedia(data: Data, mimeType: String) async throws -> UploadResponse {
        guard let token = session?.token else {
            throw NSError(domain: "upload", code: 401, userInfo: [NSLocalizedDescriptionKey: "未登录"])
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("api/upload"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = multipartBody(data: data, mimeType: mimeType, boundary: boundary)

        let (responseData, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: responseData))?["error"]
            throw NSError(domain: "upload", code: 1, userInfo: [NSLocalizedDescriptionKey: msg ?? "上传失败"])
        }
        return try JSONDecoder().decode(UploadResponse.self, from: responseData)
    }

    private func multipartBody(data: Data, mimeType: String, boundary: String) -> Data {
        var body = Data()
        let filename = "media.\(mimeType.contains("video") ? "mp4" : "jpg")"
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n")
        return body
    }

    private func handleSendAck(_ data: [Any], clientId: String, channel: ChatChannel) {
        updateMessages(channel) { list in
            guard let i = list.firstIndex(where: { $0.id == clientId }) else { return }
            if let dict = data.first as? [String: Any],
               dict["ok"] as? Bool == true, let realId = dict["id"] as? String {
                var old = list[i]
                old.pending = false
                old.clientId = clientId
                list[i] = ChatMessage(dict: [
                    "id": realId, "sender": old.sender, "senderName": old.senderName,
                    "kind": old.kind, "type": old.type, "text": old.text,
                    "url": old.url as Any, "channel": old.channel, "ts": old.ts,
                    "clientId": clientId,
                ]) ?? old
            } else {
                list[i].pending = false
                list[i].failed = true
            }
        }
    }

    func resend(_ message: ChatMessage) {
        guard message.failed, message.type == "text" else { return }
        let channel = ChatChannel(rawValue: message.channel) ?? .couple
        updateMessages(channel) { $0.removeAll { $0.id == message.id } }
        sendText(message.text, channel: channel)
    }

    // MARK: 已读 / 前后台
    func markRead(_ channel: ChatChannel = .couple) {
        guard let s = socket, connected,
              let lastTs = messages(for: channel).last(where: { !$0.pending })?.ts else { return }
        s.emit("read", ["channel": channel.rawValue, "ts": lastTs])
    }

    func partnerHasRead(_ msg: ChatMessage) -> Bool {
        guard msg.channel == ChatChannel.couple.rawValue,
              let me = session?.username else { return false }
        let partnerTs = readState(for: .couple).first(where: { $0.key != me })?.value ?? 0
        return msg.ts <= partnerTs
    }

    private func readState(for channel: ChatChannel) -> [String: Double] {
        readStates[channel.rawValue] ?? [:]
    }

    private func setReadState(_ channel: ChatChannel, state: [String: Double]) {
        var next = readStates
        next[channel.rawValue] = state
        readStates = next
    }

    private func setReadState(_ channel: ChatChannel, user: String, ts: Double) {
        var state = readState(for: channel)
        if ts > (state[user] ?? 0) { state[user] = ts }
        setReadState(channel, state: state)
    }

    private func applyRecall(id: String, byName: String?, channel: ChatChannel?) {
        let channels = channel.map { [$0] } ?? ChatChannel.allCases
        for c in channels {
            updateMessages(c) { list in
                guard let i = list.firstIndex(where: { $0.id == id }) else { return }
                var m = list[i]
                let mine = m.sender == session?.username
                m.kind = "system"
                m.type = "text"
                m.url = nil
                m.text = mine ? "你撤回了一条消息" : "\(byName ?? "对方")撤回了一条消息"
                list[i] = m
            }
        }
    }

    func reportAway(_ away: Bool) {
        socket?.emit("away", away)
    }

    func recoverOnForeground() {
        guard let s = socket else { return }
        reportAway(false)
        guard connected else { s.connect(); return }
        s.emitWithAck("health").timingOut(after: 2.5) { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                if data.first is [String: Any] {
                    self.syncHistory(.couple)
                    self.syncHistory(.ai)
                } else {
                    self.socket?.disconnect()
                    self.socket?.connect(withPayload: ["token": self.session?.token ?? ""])
                }
            }
        }
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(contentsOf: string.utf8)
    }
}
