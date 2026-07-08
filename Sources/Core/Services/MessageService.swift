import Foundation

/// 消息服务：处理消息的增删改查、发送、撤回、已读状态
@MainActor
final class MessageService: ObservableObject {
    @Published private(set) var messagesByChannel: [String: [ChatMessage]] = [:]
    @Published private(set) var readStates: [String: [String: Double]] = [:]
    @Published private(set) var reachedOldestLocal: Set<String> = []
    
    private var loadingOlderChannels = Set<String>()
    private var lastLoadOlderAt: [String: Date] = [:]
    
    var socketService: SocketService?
    var session: Session? { 
        didSet { 
            if let username = session?.username {
                database = ChatLocalDatabase.shared
                _ = database?.open(username: username)
            }
        }
    }
    
    private var database: ChatLocalDatabase?
    
    // MARK: - 消息获取
    
    func messages(for channel: ChatChannel) -> [ChatMessage] {
        messagesByChannel[channel.rawValue] ?? []
    }
    
    func clearReachedOldestLocal() {
        reachedOldestLocal.removeAll()
    }
    
    func updateMessages(_ channel: ChatChannel, _ transform: (inout [ChatMessage]) -> Void) {
        var next = messagesByChannel
        var list = next[channel.rawValue] ?? []
        transform(&list)
        next[channel.rawValue] = list
        messagesByChannel = next
    }
    
    // MARK: - 消息插入/更新
    
    func upsert(_ msg: ChatMessage, in channel: ChatChannel) {
        database?.insertMessage(msg)
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
    
    func upsertBatch(_ msgs: [ChatMessage], in channel: ChatChannel) {
        guard !msgs.isEmpty else { return }
        for msg in msgs { database?.insertMessage(msg) }
        updateMessages(channel) { list in
            for msg in msgs {
                if let i = list.firstIndex(where: { $0.id == msg.id || (msg.clientId != nil && $0.id == msg.clientId) }) {
                    list[i] = msg
                    continue
                }
                if let last = list.last, last.ts > msg.ts,
                   let i = list.lastIndex(where: { $0.ts <= msg.ts }) {
                    list.insert(msg, at: i + 1)
                } else {
                    list.append(msg)
                }
            }
        }
    }
    
    // MARK: - 本地缓存
    
    func restoreLocalCache(for session: Session) {
        guard let db = database else { return }
        
        messagesByChannel[ChatChannel.couple.rawValue] = db.fetchLatestMessages(channel: ChatChannel.couple.rawValue, limit: 50)
        messagesByChannel[ChatChannel.ai.rawValue] = db.fetchLatestMessages(channel: ChatChannel.ai.rawValue, limit: 50)
        
        readStates = [
            ChatChannel.couple.rawValue: db.loadReadReceipts(channel: ChatChannel.couple.rawValue),
            ChatChannel.ai.rawValue: db.loadReadReceipts(channel: ChatChannel.ai.rawValue)
        ]
    }
    
    func ensureLocalMessages(_ channel: ChatChannel) {
        guard let db = database else { return }
        
        let local = db.fetchLatestMessages(channel: channel.rawValue, limit: 50)
        guard !local.isEmpty else { return }
        
        let current = messages(for: channel)
        guard current.isEmpty || current.last?.id != local.last?.id else { return }
        
        let pendingOrFailed = current.filter { $0.pending || $0.failed }
        let knownIds = Set(local.map(\.id))
        updateMessages(channel) { list in
            list = local + pendingOrFailed.filter { !knownIds.contains($0.id) }
        }
    }
    
    // MARK: - 加载历史消息
    
    func isLoadingOlder(_ channel: ChatChannel) -> Bool {
        loadingOlderChannels.contains(channel.rawValue)
    }
    
    func loadOlder(_ channel: ChatChannel = .couple) {
        Task { await loadOlderAsync(channel) }
    }
    
    func loadOlderAsync(_ channel: ChatChannel = .couple) async {
        guard let first = messages(for: channel).first else { return }
        guard !loadingOlderChannels.contains(channel.rawValue) else { return }
        
        if let last = lastLoadOlderAt[channel.rawValue],
           Date().timeIntervalSince(last) < 0.45 {
            return
        }
        
        lastLoadOlderAt[channel.rawValue] = Date()
        loadingOlderChannels.insert(channel.rawValue)
        
        let limit = 22
        let firstTs = first.ts
        
        // SQLite 读取放到后台
        let localOlder = await Task.detached(priority: .utility) {
            self.database?.fetchMessages(channel: channel.rawValue, beforeTimestamp: firstTs, limit: limit) ?? []
        }.value
        
        if !localOlder.isEmpty {
            reachedOldestLocal.remove(channel.rawValue)
            updateMessages(channel) { current in
                let known = Set(current.map(\.id))
                current.insert(contentsOf: localOlder.filter { !known.contains($0.id) }, at: 0)
            }
            loadingOlderChannels.remove(channel.rawValue)
            return
        }
        
        // 本地库没有更早消息时访问网络
        guard let socket = socketService, socket.isConnected else {
            reachedOldestLocal.insert(channel.rawValue)
            loadingOlderChannels.remove(channel.rawValue)
            return
        }
        
        reachedOldestLocal.remove(channel.rawValue)
        
        let older: [ChatMessage] = await withCheckedContinuation { continuation in
            socket.emitWithAck("messages:fetch", timeout: 9, ["channel": channel.rawValue, "before": firstTs, "limit": limit]) { data in
                guard let dict = data.first as? [String: Any],
                      let list = dict["list"] as? [[String: Any]] else {
                    continuation.resume(returning: [])
                    return
                }
                continuation.resume(returning: list.compactMap { ChatMessage(dict: $0) })
            }
        }
        
        defer { loadingOlderChannels.remove(channel.rawValue) }
        guard !older.isEmpty else { return }
        
        await Task.detached(priority: .utility) {
            for msg in older {
                self.database?.insertMessage(msg)
            }
        }.value
        
        updateMessages(channel) { current in
            let known = Set(current.map(\.id))
            current.insert(contentsOf: older.filter { !known.contains($0.id) }, at: 0)
        }
    }
    
    // MARK: - 发送消息
    
    func sendText(_ text: String, channel: ChatChannel = .couple,
                  replyTo: String? = nil, replyPreview: String? = nil) {
        guard let session, let socket = socketService else { return }
        
        let clientId = "tmp-" + UUID().uuidString
        let optimistic = ChatMessage(optimisticText: text, me: session, clientId: clientId,
                                     channel: channel.rawValue, replyTo: replyTo, replyPreview: replyPreview)
        updateMessages(channel) { $0.append(optimistic) }
        
        guard socket.isConnected else {
            updateMessages(channel) { list in
                guard let i = list.firstIndex(where: { $0.id == clientId }) else { return }
                list[i].pending = false
                list[i].failed = true
            }
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
            payload["reply"] = ["id": replyTo, "preview": replyPreview ?? ""]
        }
        
        socket.emitWithAck("message:send", timeout: 15, payload) { [weak self] data in
            Task { @MainActor in
                self?.handleSendAck(data, clientId: clientId, channel: channel)
            }
        }
    }
    
    func sendMedia(url: String, type: String, channel: ChatChannel = .couple, 
                   displayText: String? = nil) {
        guard let session, let socket = socketService else { return }
        
        let clientId = "tmp-" + UUID().uuidString
        let outgoingText = displayText ?? Self.mediaPlaceholderText(for: type)
        let optimistic = ChatMessage(
            optimisticMedia: type,
            text: outgoingText,
            localURL: nil,
            me: session,
            clientId: clientId,
            channel: channel.rawValue)
        updateMessages(channel) { $0.append(optimistic) }
        
        guard socket.isConnected else {
            updateMessages(channel) { list in
                guard let i = list.firstIndex(where: { $0.id == clientId }) else { return }
                list[i].pending = false
                list[i].failed = true
            }
            return
        }
        
        let payload: [String: Any] = [
            "type": type,
            "text": outgoingText,
            "url": url,
            "channel": channel.rawValue,
            "clientId": clientId,
        ]
        
        socket.emitWithAck("message:send", timeout: 15, payload) { [weak self] data in
            Task { @MainActor in
                self?.handleSendAck(data, clientId: clientId, channel: channel)
            }
        }
    }
    
    func sendSticker(url: String, channel: ChatChannel = .couple) {
        guard let session, let socket = socketService else { return }
        
        let clientId = "tmp-" + UUID().uuidString
        let optimistic = ChatMessage(
            optimisticMedia: "sticker",
            text: "[表情]",
            localURL: url,
            me: session,
            clientId: clientId,
            channel: channel.rawValue)
        updateMessages(channel) { $0.append(optimistic) }
        
        guard socket.isConnected else {
            updateMessages(channel) { list in
                guard let i = list.firstIndex(where: { $0.id == clientId }) else { return }
                list[i].pending = false
                list[i].failed = true
            }
            return
        }
        
        let payload: [String: Any] = [
            "type": "sticker",
            "text": "[表情]",
            "url": url,
            "channel": channel.rawValue,
            "clientId": clientId,
        ]
        
        socket.emitWithAck("message:send", timeout: 15, payload) { [weak self] data in
            Task { @MainActor in
                self?.handleSendAck(data, clientId: clientId, channel: channel)
            }
        }
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
                self.database?.insertMessage(list[i])
            } else {
                list[i].pending = false
                list[i].failed = true
            }
        }
    }
    
    private static func mediaPlaceholderText(for type: String) -> String {
        switch type {
        case "video": return "[视频]"
        case "voice": return "[语音]"
        case "file": return "[文件]"
        default: return "[图片]"
        }
    }
    
    // MARK: - 撤回消息
    
    func recallMessage(_ message: ChatMessage, channel: ChatChannel) {
        guard let socket = socketService, socket.isConnected else { return }
        
        // 乐观本地更新
        updateMessages(channel) { list in
            guard let i = list.firstIndex(where: { $0.id == message.id }) else { return }
            var m = list[i]
            m.recalledText = m.text
            m.kind = "system"
            m.type = "text"
            m.url = nil
            m.text = "你撤回了一条消息"
            list[i] = m
            self.database?.insertMessage(m)
        }
        
        socket.emitWithAck("message:recall", timeout: 9, ["id": message.id]) { _ in }
    }
    
    func resend(_ message: ChatMessage) {
        guard message.failed, message.type == "text" else { return }
        let channel = ChatChannel(rawValue: message.channel) ?? .couple
        updateMessages(channel) { $0.removeAll { $0.id == message.id } }
        sendText(message.text, channel: channel)
    }
    
    func applyRecall(id: String, byName: String?, channel: ChatChannel?) {
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
                self.database?.insertMessage(m)
            }
        }
    }
    
    // MARK: - 已读状态
    
    func markRead(_ channel: ChatChannel = .couple) {
        guard let socket = socketService, socket.isConnected,
              let lastTs = messages(for: channel).last(where: { !$0.pending })?.ts else { return }
        socket.emit("read", ["channel": channel.rawValue, "ts": lastTs])
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
    
    func setReadState(_ channel: ChatChannel, state: [String: Double]) {
        var next = readStates
        next[channel.rawValue] = state
        readStates = next
        
        for (user, ts) in state {
            database?.saveReadReceipt(channel: channel.rawValue, username: user, ts: ts, updatedAt: Date().timeIntervalSince1970 * 1000)
        }
    }
    
    func setReadState(_ channel: ChatChannel, user: String, ts: Double) {
        var state = readState(for: channel)
        if ts > (state[user] ?? 0) { state[user] = ts }
        setReadState(channel, state: state)
    }
    
    // MARK: - 搜索
    
    func searchMessages(_ query: String, channel: ChatChannel) async -> [ChatMessage] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        
        let local = database?.searchMessages(query: q, channel: channel.rawValue) ?? []
        guard let socket = socketService, socket.isConnected else { return local }
        
        return await withCheckedContinuation { continuation in
            socket.emitWithAck("messages:search", timeout: 9, [
                "channel": channel.rawValue,
                "query": q,
                "limit": 50,
            ]) { data in
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
    
    func mediaMessages(for channel: ChatChannel, includeFiles: Bool = false, limit: Int? = nil) -> [ChatMessage] {
        let types = includeFiles ? ["image", "video", "file"] : ["image", "video"]
        return database?.mediaMessages(channel: channel.rawValue, types: types, limit: limit) ?? []
    }
    
    func mediaItemCount(for channel: ChatChannel, includeFiles: Bool = false) -> Int {
        let types = includeFiles ? ["image", "video", "file"] : ["image", "video"]
        return database?.mediaCount(channel: channel.rawValue, types: types) ?? 0
    }
    
    private nonisolated static func mergeSearchResults(_ first: [ChatMessage], _ second: [ChatMessage]) -> [ChatMessage] {
        var seen = Set<String>()
        return (first + second)
            .filter { message in
                guard !seen.contains(message.id) else { return false }
                seen.insert(message.id)
                return true
            }
            .sorted { $0.ts > $1.ts }
    }
    
    // MARK: - 清理
    
    func clearAll() {
        messagesByChannel = [:]
        readStates = [:]
        reachedOldestLocal = []
    }
}
