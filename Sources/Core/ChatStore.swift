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
    @Published var partner: Account? {
        didSet {
            if let partner = partner,
               let data = try? JSONEncoder().encode(partner) {
                UserDefaults.standard.set(data, forKey: "cached_partner_\(session?.username ?? "")")
            }
        }
    }
    @Published private(set) var readStates: [String: [String: Double]] = [:]
    @Published var aiTyping = false
    @Published var sharedState: [String: Any] = [:]
    @Published var lastConnectionError: String?

    // 通知提醒页：收到共享提醒/备忘变更时刷新
    static let personalItemChangedNotification = Notification.Name("personalItemChanged")

    /// 兼容旧 UI：默认仍然表示 couple 频道。
    var messages: [ChatMessage] { messages(for: .couple) }
    var readState: [String: Double] { readState(for: .couple) }
    var loggedIn: Bool { session != nil }

    private var manager: SocketManager?
    private var socket: SocketIOClient?
    private var restoringCache = false
    private var backfillingChannels = Set<String>()

    private struct UploadResponse: Decodable {
        let url: String
        let type: String
    }

    private struct PersonalItemsResponse: Decodable {
        let items: [PersonalItem]
    }

    private struct PersonalItemResponse: Decodable {
        let item: PersonalItem
    }

    // MARK: 启动：钥匙串里有会话就直接连
    func bootstrap() {
        guard session == nil, let saved = Keychain.loadSession() else { return }
        session = saved
        _ = ChatLocalDatabase.shared.open(username: saved.username)
        restoreLocalCache(for: saved)
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
        _ = ChatLocalDatabase.shared.open(username: s.username)
        restoreLocalCache(for: s)
        connect()
    }

    func logout() {
        let username = session?.username
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
        ChatLocalDatabase.shared.close()
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
        // token 同时走 connectParams(query) 和 auth payload：
        // query 参数在每次自动重连时都会带上，避免重连握手丢 token 被服务端判 unauthorized。
        let m = SocketManager(socketURL: Self.baseURL, config: [
            .compress,
            .reconnects(true),
            .reconnectWaitMax(5),
            .connectParams(["token": session.token]),
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

        s.on("message:update") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let id = dict["id"] as? String else { return }
            let metaDict = dict["meta"] as? [String: Any]
            Task { @MainActor in self?.applyMessageUpdate(id: id, meta: metaDict) }
        }

        s.on("ai:typing") { [weak self] data, _ in
            let typing = (data.first as? Bool) ?? true
            Task { @MainActor in self?.aiTyping = typing }
        }

        s.on("shared:init") { [weak self] data, _ in
            guard let state = data.first as? [String: Any] else { return }
            Task { @MainActor in
                self?.sharedState = state
                for (key, val) in state {
                    if let dict = val as? [String: Any],
                       let value = dict["value"],
                       let valueData = try? JSONSerialization.data(withJSONObject: value),
                       let valueJson = String(data: valueData, encoding: .utf8) {
                        let updatedBy = dict["updatedBy"] as? String ?? ""
                        let updatedAt = (dict["updatedAt"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000
                        ChatLocalDatabase.shared.saveSharedState(key: key, valueJson: valueJson, updatedBy: updatedBy, updatedAt: updatedAt)
                    }
                }
            }
        }

        s.on("shared:update") { [weak self] data, _ in
            guard let update = data.first as? [String: Any],
                  let key = update["key"] as? String else { return }
            Task { @MainActor in
                self?.sharedState[key] = update
                if let value = update["value"],
                   let valueData = try? JSONSerialization.data(withJSONObject: value),
                   let valueJson = String(data: valueData, encoding: .utf8) {
                    let updatedBy = update["updatedBy"] as? String ?? ""
                    let updatedAt = (update["updatedAt"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000
                    ChatLocalDatabase.shared.saveSharedState(key: key, valueJson: valueJson, updatedBy: updatedBy, updatedAt: updatedAt)
                }
            }
        }

        s.on("personalItem:changed") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let itemDict = dict["item"] as? [String: Any],
                  let action = dict["action"] as? String else { return }

            // shared items only — personal items don't need real-time sync
            let scope = itemDict["scope"] as? String ?? "personal"
            guard scope == "shared" else { return }

            Task { @MainActor in
                guard let self else { return }
                // 不是自己操作的才通知刷新
                let itemOwner = itemDict["owner"] as? String ?? ""
                if itemOwner != self.session?.username {
                    NotificationCenter.default.post(
                        name: Self.personalItemChangedNotification,
                        object: nil,
                        userInfo: ["action": action, "item": itemDict]
                    )
                }
            }
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
        // Socket 层 unauthorized 不直接登出：可能只是重连握手异常。
        // 先用 REST 验证 token 是否真失效，确认失效才清 session。
        if message.lowercased().contains("unauthorized") {
            verifySessionOrLogout()
        }
    }

    /// 用 REST /api/me 核实 token；仅在服务端明确返回 401 时登出。
    /// 网络错误或服务端 5xx 都不登出，保留 session 等待下次重连。
    private var verifyingSession = false
    private func verifySessionOrLogout() {
        guard !verifyingSession, let token = session?.token else { return }
        verifyingSession = true
        Task {
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
        ChatLocalDatabase.shared.insertMessage(msg)
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
        for msg in incoming {
            ChatLocalDatabase.shared.insertMessage(msg)
        }
        updateMessages(channel) { list in
            list = incoming
        }
    }

    // MARK: 本地缓存
    private func restoreLocalCache(for session: Session) {
        restoringCache = true
        messagesByChannel[ChatChannel.couple.rawValue] = ChatLocalDatabase.shared.fetchLatestMessages(channel: ChatChannel.couple.rawValue, limit: 50)
        messagesByChannel[ChatChannel.ai.rawValue] = ChatLocalDatabase.shared.fetchLatestMessages(channel: ChatChannel.ai.rawValue, limit: 50)
        
        readStates = [
            ChatChannel.couple.rawValue: ChatLocalDatabase.shared.loadReadReceipts(channel: ChatChannel.couple.rawValue),
            ChatChannel.ai.rawValue: ChatLocalDatabase.shared.loadReadReceipts(channel: ChatChannel.ai.rawValue)
        ]
        
        sharedState = ChatLocalDatabase.shared.loadSharedState()
        
        if let data = UserDefaults.standard.data(forKey: "cached_partner_\(session.username)"),
           let p = try? JSONDecoder().decode(Account.self, from: data) {
            partner = p
        }
        
        restoringCache = false
    }

    // MARK: 历史 / 补漏
    private func syncHistory(_ channel: ChatChannel) {
        guard let s = socket else { return }
        let local = messages(for: channel)
        let lastTs = local.last(where: { !$0.pending && !$0.failed })?.ts ?? 0
        var payload: [String: Any] = ["channel": channel.rawValue, "limit": 100]
        if lastTs > 0 { payload["since"] = lastTs }
        s.emitWithAck("messages:fetch", payload).timingOut(after: 9) { [weak self] data in
            guard let dict = data.first as? [String: Any],
                  let list = dict["list"] as? [[String: Any]] else { return }
            let incoming = list.compactMap { ChatMessage(dict: $0) }
            Task { @MainActor in
                guard let self else { return }
                incoming.forEach { self.upsert($0, in: channel) }
                if channel == .couple { self.markRead(.couple) }
            }
        }
    }

    func loadOlder(_ channel: ChatChannel = .couple) {
        guard let first = messages(for: channel).first else { return }
        let limit = 50
        
        // 1. First try to load from local SQLite
        let localOlder = ChatLocalDatabase.shared.fetchMessages(channel: channel.rawValue, beforeTimestamp: first.ts, limit: limit)
        if !localOlder.isEmpty {
            updateMessages(channel) { current in
                let known = Set(current.map(\.id))
                current.insert(contentsOf: localOlder.filter { !known.contains($0.id) }, at: 0)
            }
            if localOlder.count >= limit {
                return // Loaded a full page locally, no need to query network
            }
        }
        
        // 2. If local database has no more or not enough older messages, fetch from server
        guard let s = socket, connected else { return }
        s.emitWithAck("messages:fetch", ["channel": channel.rawValue, "before": first.ts, "limit": limit])
            .timingOut(after: 9) { [weak self] data in
                guard let dict = data.first as? [String: Any],
                      let list = dict["list"] as? [[String: Any]] else { return }
                let older = list.compactMap { ChatMessage(dict: $0) }
                Task { @MainActor in
                    guard let self, !older.isEmpty else { return }
                    for msg in older {
                        ChatLocalDatabase.shared.insertMessage(msg)
                    }
                    self.updateMessages(channel) { current in
                        let known = Set(current.map(\.id))
                        current.insert(contentsOf: older.filter { !known.contains($0.id) }, at: 0)
                    }
                }
            }
    }

    // MARK: 发送（乐观上屏）
    func sendText(_ text: String, channel: ChatChannel = .couple,
                  replyTo: String? = nil, replyPreview: String? = nil) {
        guard let session, let s = socket else { return }
        let clientId = "tmp-" + UUID().uuidString
        let optimistic = ChatMessage(optimisticText: text, me: session, clientId: clientId,
                                     channel: channel.rawValue, replyTo: replyTo, replyPreview: replyPreview)
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

        var payload: [String: Any] = [
            "type": "text",
            "text": text,
            "channel": channel.rawValue,
            "clientId": clientId,
        ]
        if let replyTo {
            payload["replyTo"] = replyTo
            payload["replyPreview"] = replyPreview ?? ""
            payload["reply"] = [
                "id": replyTo,
                "preview": replyPreview ?? "",
            ]
        }
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
                        var payload: [String: Any] = [
                            "id": realId, "sender": old.sender, "senderName": old.senderName,
                            "kind": old.kind, "type": old.type, "text": old.text,
                            "channel": old.channel, "ts": old.ts,
                        ]
                        if let replyTo = old.replyTo {
                            payload["replyTo"] = replyTo
                            payload["replyPreview"] = old.replyPreview ?? ""
                            payload["reply"] = ["id": replyTo, "preview": old.replyPreview ?? ""]
                        }
                        list[i] = ChatMessage(dict: payload) ?? old
                    } else {
                        list[i].pending = false
                        list[i].failed = true
                    }
                }
                _ = didFindPending
            }
        }
    }

    func sendMedia(data: Data, mimeType: String, preferredType: String, localPreviewURL: URL?, channel: ChatChannel = .couple) {
        guard let session, let s = socket else { return }
        let clientId = "tmp-" + UUID().uuidString
        let optimistic = ChatMessage(
            optimisticMedia: preferredType,
            text: Self.mediaPlaceholderText(for: preferredType),
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
                    "text": Self.mediaPlaceholderText(for: type),
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

    private static func mediaPlaceholderText(for type: String) -> String {
        switch type {
        case "video": return "[视频]"
        case "voice": return "[语音]"
        default: return "[图片]"
        }
    }

    private func multipartBody(data: Data, mimeType: String, boundary: String) -> Data {
        var body = Data()
        let filename: String
        if mimeType.contains("video") {
            filename = "media.mp4"
        } else if mimeType.contains("audio") {
            filename = "media.m4a"
        } else {
            filename = "media.jpg"
        }
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
                var payload: [String: Any] = [
                    "id": realId, "sender": old.sender, "senderName": old.senderName,
                    "kind": old.kind, "type": old.type, "text": old.text,
                    "url": old.url as Any, "channel": old.channel, "ts": old.ts,
                    "clientId": clientId,
                ]
                if let replyTo = old.replyTo {
                    payload["replyTo"] = replyTo
                    payload["replyPreview"] = old.replyPreview ?? ""
                    payload["reply"] = ["id": replyTo, "preview": old.replyPreview ?? ""]
                }
                list[i] = ChatMessage(dict: payload) ?? old
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
        for (user, ts) in state {
            ChatLocalDatabase.shared.saveReadReceipt(channel: channel.rawValue, username: user, ts: ts, updatedAt: Date().timeIntervalSince1970 * 1000)
        }
    }

    private func setReadState(_ channel: ChatChannel, user: String, ts: Double) {
        var state = readState(for: channel)
        if ts > (state[user] ?? 0) { state[user] = ts }
        setReadState(channel, state: state)
    }

    func recallMessage(_ message: ChatMessage, channel: ChatChannel) {
        guard let s = socket, connected else { return }
        // 乐观本地更新：保留原文供重新编辑
        updateMessages(channel) { list in
            guard let i = list.firstIndex(where: { $0.id == message.id }) else { return }
            var m = list[i]
            m.recalledText = m.text
            m.kind = "system"
            m.type = "text"
            m.url = nil
            m.text = "你撤回了一条消息"
            list[i] = m
            ChatLocalDatabase.shared.insertMessage(m)
        }
        s.emitWithAck("message:recall", ["id": message.id]).timingOut(after: 9) { _ in }
    }

    private func applyRecall(id: String, byName: String?, channel: ChatChannel?) {
        let channels = channel.map { [$0] } ?? ChatChannel.allCases
        for c in channels {
            updateMessages(c) { list in
                guard let i = list.firstIndex(where: { $0.id == id }) else { return }
                var m = list[i]
                let mine = m.sender == session?.username
                if m.recalledText == nil { m.recalledText = m.text }
                m.kind = "system"
                m.type = "text"
                m.url = nil
                m.text = mine ? "你撤回了一条消息" : "\(byName ?? "对方")撤回了一条消息"
                list[i] = m
                ChatLocalDatabase.shared.insertMessage(m)
            }
        }
    }

    // 确认卡：服务端确认/取消后把新 meta 推回来，更新对应消息
    private func applyMessageUpdate(id: String, meta: [String: Any]?) {
        for c in ChatChannel.allCases {
            updateMessages(c) { list in
                guard let i = list.firstIndex(where: { $0.id == id }) else { return }
                var m = list[i]
                m.meta = meta.flatMap { ChatMessageMeta(dict: $0) }
                list[i] = m
                ChatLocalDatabase.shared.insertMessage(m)
            }
        }
    }

    // 用户在确认卡上点「确认」/「取消」，emit 给服务端
    func confirmAction(messageId: String, decision: String) {
        socket?.emit("action:confirm", ["messageId": messageId, "decision": decision])
    }

    func reportAway(_ away: Bool) {
        socket?.emit("away", away)
    }

    // MARK: 搜索聊天记录（服务端 messages:search）
    func searchMessages(_ query: String, channel: ChatChannel) async -> [ChatMessage] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let local = ChatLocalDatabase.shared.searchMessages(query: q, channel: channel.rawValue)
        guard let s = socket, connected else { return local }

        return await withCheckedContinuation { continuation in
            s.emitWithAck("messages:search", [
                "channel": channel.rawValue,
                "query": q,
                "limit": 50,
            ]).timingOut(after: 9) { data in
                guard let dict = data.first as? [String: Any],
                      let list = dict["list"] as? [[String: Any]] else {
                    continuation.resume(returning: local)
                    return
                }
                let remote = list.compactMap { ChatMessage(dict: $0) }
                continuation.resume(returning: Self.mergeSearchResults(remote, local))
            }
        }
    }

    nonisolated private static func mergeSearchResults(_ first: [ChatMessage], _ second: [ChatMessage]) -> [ChatMessage] {
        var seen = Set<String>()
        return (first + second)
            .filter { message in
                guard !seen.contains(message.id) else { return false }
                seen.insert(message.id)
                return true
            }
            .sorted { $0.ts > $1.ts }
    }

    // MARK: shared 键值（纪念日等两人共享状态）
    func setShared(_ key: String, value: [String: Any]) {
        // 乐观更新本地，服务端广播 shared:update 后自然对齐
        sharedState[key] = ["key": key, "value": value]
        if let valueData = try? JSONSerialization.data(withJSONObject: value),
           let valueJson = String(data: valueData, encoding: .utf8) {
            ChatLocalDatabase.shared.saveSharedState(key: key, valueJson: valueJson, updatedBy: session?.username ?? "", updatedAt: Date().timeIntervalSince1970 * 1000)
        }
        guard let s = socket, connected else {
            lastConnectionError = "Socket 未连接"
            return
        }
        s.emit("shared:set", ["key": key, "value": value])
    }

    /// 读某个 shared key 的 value（兼容 shared:init 和 shared:update 两种包装）
    func sharedValue(_ key: String) -> [String: Any]? {
        guard let entry = sharedState[key] as? [String: Any] else { return nil }
        return entry["value"] as? [String: Any]
    }

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

    /// 自由添加的纪念日列表；旧版本仅有 lastMeet/lastFight 时，回退合成两张卡片展示，
    /// 一旦用户编辑/新增/删除过任意一条，才真正落到 "anniversaries" 上成为唯一数据源。
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

    func saveAnniversaries(_ items: [AnniversaryEntry]) {
        setShared("anniversaries", value: ["items": items.map { $0.asDict }])
    }

    // MARK: 聊天时光统计（本地缓存聚合，无需服务端）

    struct LocalStatsBuckets {
        let days: [DayStat]
        let months: [MonthStat]
    }

    private static let statsDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f
    }()

    private static let statsMonthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f
    }()

    private static var shanghaiCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal
    }()

    private static let weekdayLabels = ["日", "一", "二", "三", "四", "五", "六"]

    /// 从本地已缓存的完整聊天记录聚合出逐日/逐月的双方消息数，取代原先的服务端 /api/stats。
    func localStats(for channel: ChatChannel = .couple) -> LocalStatsBuckets {
        let cal = Self.shanghaiCalendar
        let now = Date()
        let today = cal.startOfDay(for: now)

        let userMessages = messages(for: channel).filter { $0.kind == "user" && $0.sender != "ai" }

        // 至少铺满最近 10 天 / 12 个月（没聊天记录的日子留空心柱），
        // 真实聊天记录更久才继续往前翻页。
        let minRecentDays = 10
        let minRecentMonths = 12

        var dayCounts: [String: [String: Int]] = [:]
        var earliestDay = cal.date(byAdding: .day, value: -(minRecentDays - 1), to: today) ?? today
        var monthCounts: [String: [String: Int]] = [:]
        let thisMonthStartInit = cal.date(from: cal.dateComponents([.year, .month], from: today)) ?? today
        var earliestMonth = cal.date(byAdding: .month, value: -(minRecentMonths - 1), to: thisMonthStartInit) ?? thisMonthStartInit

        for message in userMessages {
            let date = message.date
            let dayStart = cal.startOfDay(for: date)
            let dayKey = Self.statsDayFormatter.string(from: date)
            dayCounts[dayKey, default: [:]][message.sender, default: 0] += 1
            if dayStart < earliestDay { earliestDay = dayStart }

            let monthKey = Self.statsMonthFormatter.string(from: date)
            monthCounts[monthKey, default: [:]][message.sender, default: 0] += 1
            if let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: date)),
               monthStart < earliestMonth {
                earliestMonth = monthStart
            }
        }

        var days: [DayStat] = []
        var cursor = earliestDay
        while cursor <= today {
            let key = Self.statsDayFormatter.string(from: cursor)
            let weekday = cal.isDate(cursor, inSameDayAs: today) ? "今" : Self.weekdayLabels[cal.component(.weekday, from: cursor) - 1]
            days.append(DayStat(date: key, weekday: weekday, counts: dayCounts[key] ?? [:]))
            guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        var months: [MonthStat] = []
        var monthCursor = cal.date(from: cal.dateComponents([.year, .month], from: earliestMonth)) ?? earliestMonth
        let thisMonthStart = cal.date(from: cal.dateComponents([.year, .month], from: today)) ?? today
        while monthCursor <= thisMonthStart {
            let key = Self.statsMonthFormatter.string(from: monthCursor)
            months.append(MonthStat(month: key, counts: monthCounts[key] ?? [:]))
            guard let next = cal.date(byAdding: .month, value: 1, to: monthCursor) else { break }
            monthCursor = next
        }

        return LocalStatsBuckets(days: days, months: months)
    }

    // MARK: REST（统计 / 每日内容 / Bark）
    private func authorizedRequest(_ path: String, method: String = "GET") -> URLRequest? {
        guard let token = session?.token else { return nil }
        let url: URL
        if let relative = URL(string: path, relativeTo: Self.baseURL) {
            url = relative.absoluteURL
        } else {
            url = Self.baseURL.appendingPathComponent(path)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    func fetchStats() async -> StatsResponse? {
        guard let req = authorizedRequest("api/stats"),
              let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(StatsResponse.self, from: data)
    }

    func fetchDaily() async -> DailyContent? {
        guard let req = authorizedRequest("api/daily"),
              let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(DailyContent.self, from: data)
    }

    func regenerateRecommendation() async -> Recommendation? {
        guard let req = authorizedRequest("api/daily/recommend", method: "POST"),
              let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        struct Wrapper: Decodable { let recommend: Recommendation? }
        return (try? JSONDecoder().decode(Wrapper.self, from: data))?.recommend
    }

    func fetchPersonalItems(kind: PersonalItemKind? = nil, scope: String = "personal") async -> [PersonalItem] {
        var components: [String] = []
        if let kind { components.append("kind=\(kind.rawValue)") }
        components.append("scope=\(scope)")
        let path = "api/me/items?\(components.joined(separator: "&"))"
        guard let req = authorizedRequest(path),
              let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return (try? JSONDecoder().decode(PersonalItemsResponse.self, from: data))?.items ?? []
    }

    func createPersonalItem(kind: PersonalItemKind, scope: String = "personal", title: String, bodyMarkdown: String, dueAt: Int?) async -> PersonalItem? {
        var body: [String: Any] = [
            "kind": kind.rawValue,
            "scope": scope,
            "title": title,
            "bodyMarkdown": bodyMarkdown,
        ]
        if let dueAt { body["dueAt"] = dueAt }
        return await sendPersonalItemRequest(path: "api/me/items", method: "POST", body: body)
    }

    func updatePersonalItem(_ item: PersonalItem, title: String? = nil, bodyMarkdown: String? = nil, dueAt: Int? = nil, clearsDueAt: Bool = false, isDone: Bool? = nil) async -> PersonalItem? {
        var body: [String: Any] = [:]
        if let title { body["title"] = title }
        if let bodyMarkdown { body["bodyMarkdown"] = bodyMarkdown }
        if clearsDueAt {
            body["dueAt"] = NSNull()
        } else if let dueAt {
            body["dueAt"] = dueAt
        }
        if let isDone { body["isDone"] = isDone }
        return await sendPersonalItemRequest(path: "api/me/items/\(item.id)", method: "PATCH", body: body)
    }

    func deletePersonalItem(_ item: PersonalItem) async -> Bool {
        guard let req = authorizedRequest("api/me/items/\(item.id)", method: "DELETE"),
              let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    private func sendPersonalItemRequest(path: String, method: String, body: [String: Any]) async -> PersonalItem? {
        guard var req = authorizedRequest(path, method: method) else { return nil }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let code = (resp as? HTTPURLResponse)?.statusCode,
              (200..<300).contains(code) else { return nil }
        return (try? JSONDecoder().decode(PersonalItemResponse.self, from: data))?.item
    }

    /// 保存/清空 Bark 推送 key（barkKey 为 nil 表示关闭离线通知）
    func saveBarkKey(_ barkKey: String?) async -> Bool {
        guard var req = authorizedRequest("api/me/push/bark", method: "POST") else { return false }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["barkKey": barkKey ?? NSNull()]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return true
    }

    func recoverOnForeground() {
        guard let s = socket else { return }
        reportAway(false)
        guard connected else {
            s.connect(withPayload: ["token": session?.token ?? ""])
            return
        }
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
