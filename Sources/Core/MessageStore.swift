import Foundation
import SocketIO
import UIKit

/// 消息 CRUD、发送、搜索、历史同步，从 ChatStore 拆出。
/// 通过 SocketProvider 访问 socket，不直接依赖 ChatStore。
@MainActor
final class MessageStore: ObservableObject {
    @Published private(set) var messagesByChannel: [String: [ChatMessage]] = [:]
    @Published private(set) var readStates: [String: [String: Double]] = [:]
    @Published var aiTyping = false
    @Published var aiReplying = false
    @Published private var loadingOlderChannels = Set<String>()
    @Published private var loadingNewerChannels = Set<String>()

    /// 消息解析计数：帮助追踪静默丢弃的消息
    private static var parseFailureCount: Int = 0
    private static var parseSuccessCount: Int = 0

    private var restoringCache = false
    private var lastLoadOlderAt: [String: Date] = [:]
    private var lastLoadNewerAt: [String: Date] = [:]
    private let storeStartedAtMs = Date().timeIntervalSince1970 * 1000

    /// 媒体发送失败后保留原始 Data，支持一键重传
    private var pendingMediaData: [String: (data: Data, mimeType: String, preferredType: String, channel: ChatChannel)] = [:]

    private static let mediaTypes = ["image", "video"]
    private static let managedAttachmentTypes = ["image", "video", "file"]

    weak var socketProvider: SocketProvider?

    var messages: [ChatMessage] { messages(for: .couple) }

    // MARK: - 消息解析

    static func parseMessage(_ dict: [String: Any], context: String = "") -> ChatMessage? {
        if let msg = ChatMessage(dict: dict) {
            parseSuccessCount += 1
            return msg
        }
        parseFailureCount += 1
        let id = dict["id"] as? String ?? "?"
        let sender = dict["sender"] as? String ?? "?"
        let channel = dict["channel"] as? String ?? "?"
        let keys = dict.keys.joined(separator: ",")
        print("[MessageStore] ⚠️ 消息解析失败 #\(parseFailureCount) | id=\(id) sender=\(sender) channel=\(channel) context=\(context) keys=[\(keys)]")
        return nil
    }

    static func parseMessages(_ list: [[String: Any]], context: String = "") -> [ChatMessage] {
        let before = parseFailureCount
        let result = list.compactMap { parseMessage($0, context: context) }
        let failed = parseFailureCount - before
        if failed > 0 {
            print("[MessageStore] ⚠️ 批量解析完成: \(result.count)/\(list.count) 成功, \(failed) 失败 | context=\(context)")
        }
        return result
    }

    // MARK: - 消息读写

    func messages(for channel: ChatChannel) -> [ChatMessage] {
        messagesByChannel[channel.rawValue] ?? []
    }

    func updateMessages(_ channel: ChatChannel, _ transform: (inout [ChatMessage]) -> Void) {
        var next = messagesByChannel
        var list = next[channel.rawValue] ?? []
        transform(&list)
        next[channel.rawValue] = list
        messagesByChannel = next
    }

    func upsert(_ msg: ChatMessage, in channel: ChatChannel) {
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

    func upsertBatch(_ msgs: [ChatMessage], in channel: ChatChannel) {
        guard !msgs.isEmpty else { return }
        for msg in msgs { ChatLocalDatabase.shared.insertMessage(msg) }
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
        restoringCache = true
        migrateLegacyCacheIfNeeded(for: session)
        messagesByChannel[ChatChannel.couple.rawValue] = ChatLocalDatabase.shared.fetchLatestMessages(channel: ChatChannel.couple.rawValue, limit: 50)
        messagesByChannel[ChatChannel.ai.rawValue] = ChatLocalDatabase.shared.fetchLatestMessages(channel: ChatChannel.ai.rawValue, limit: 50)
        readStates = [
            ChatChannel.couple.rawValue: ChatLocalDatabase.shared.loadReadReceipts(channel: ChatChannel.couple.rawValue),
            ChatChannel.ai.rawValue: ChatLocalDatabase.shared.loadReadReceipts(channel: ChatChannel.ai.rawValue),
        ]
        restoringCache = false
    }

    private func migrateLegacyCacheIfNeeded(for session: Session) {
        let existing = ChatLocalDatabase.shared.fetchLatestMessages(channel: ChatChannel.couple.rawValue, limit: 1)
        guard existing.isEmpty,
              let snapshot = ChatLocalCache.load(for: session.username) else { return }
        for (_, list) in snapshot.messagesByChannel {
            for msg in list where !msg.pending && !msg.failed {
                ChatLocalDatabase.shared.insertMessage(msg)
            }
        }
        for (channel, state) in snapshot.readStates {
            for (user, ts) in state {
                ChatLocalDatabase.shared.saveReadReceipt(channel: channel, username: user, ts: ts, updatedAt: snapshot.savedAt)
            }
        }
        ChatLocalCache.clear(for: session.username)
    }

    // MARK: - 搜索跳转

    @discardableResult
    func ensureMessageLoaded(_ target: ChatMessage, channel: ChatChannel) -> Bool {
        if messages(for: channel).contains(where: { $0.id == target.id }) { return true }
        let window = ChatLocalDatabase.shared.fetchMessagesAround(
            channel: channel.rawValue, centerTimestamp: target.ts, beforeLimit: 36, afterLimit: 28)
        if !window.isEmpty {
            updateMessages(channel) { list in
                list = Self.mergedWindow(window, with: list, around: target.id)
            }
        }
        if !messages(for: channel).contains(where: { $0.id == target.id }) {
            upsert(target, in: channel)
        }
        return messages(for: channel).contains(where: { $0.id == target.id })
    }

    @discardableResult
    func ensureDateLoaded(_ date: Date, channel: ChatChannel) -> ChatMessage? {
        let range = Self.dayRange(for: date)
        var dayMessages = ChatLocalDatabase.shared.fetchMessages(
            channel: channel.rawValue, fromInclusive: range.start, toExclusive: range.end, limit: 80)
        if dayMessages.isEmpty, let s = socketProvider?.socket, socketProvider?.isConnected == true {
            s.emitWithAck("messages:fetch", [
                "channel": channel.rawValue, "after": range.start, "before": range.end, "limit": 80,
            ]).timingOut(after: 9) { data in
                guard let dict = data.first as? [String: Any],
                      let list = dict["list"] as? [[String: Any]] else { return }
                let incoming = Self.parseMessages(list, context: "ensureDate:\(channel.rawValue)")
                Task { @MainActor in incoming.forEach { ChatLocalDatabase.shared.insertMessage($0) } }
            }
        }
        guard let target = dayMessages.first else { return nil }
        let context = ChatLocalDatabase.shared.fetchMessagesAround(
            channel: channel.rawValue, centerTimestamp: target.ts, beforeLimit: 20, afterLimit: 44)
        if !context.isEmpty { dayMessages = context }
        updateMessages(channel) { list in
            list = Self.mergedWindow(dayMessages, with: list, around: target.id)
        }
        return target
    }

    func ensureLocalMessages(_ channel: ChatChannel) {
        let local = ChatLocalDatabase.shared.fetchLatestMessages(channel: channel.rawValue, limit: 50)
        guard !local.isEmpty else { return }
        let current = messages(for: channel)
        guard current.isEmpty || current.last?.id != local.last?.id else { return }
        let pendingOrFailed = current.filter { $0.pending || $0.failed }
        let knownIds = Set(local.map(\.id))
        updateMessages(channel) { list in
            list = local + pendingOrFailed.filter { !knownIds.contains($0.id) }
        }
    }

    // MARK: - 历史同步

    func syncHistory(_ channel: ChatChannel, roundsLeft: Int = 5) {
        guard let s = socketProvider?.socket, roundsLeft > 0 else { return }
        let local = messages(for: channel)
        let lastTs = local.last(where: { !$0.pending && !$0.failed })?.ts ?? 0
        let limit = 100
        var payload: [String: Any] = ["channel": channel.rawValue, "limit": limit]
        if lastTs > 0 { payload["since"] = lastTs }
        s.emitWithAck("messages:fetch", payload).timingOut(after: 9) { [weak self] data in
            guard let dict = data.first as? [String: Any],
                  let list = dict["list"] as? [[String: Any]] else { return }
            let incoming = Self.parseMessages(list, context: "syncHistory:\(channel.rawValue)")
            Task { @MainActor in
                guard let self else { return }
                self.upsertBatch(incoming, in: channel)
                if channel == .couple { self.markRead(.couple) }
                if lastTs > 0, incoming.count >= limit {
                    self.syncHistory(channel, roundsLeft: roundsLeft - 1)
                }
            }
        }
    }

    func isLoadingOlder(_ channel: ChatChannel) -> Bool {
        loadingOlderChannels.contains(channel.rawValue)
    }

    func isLoadingNewer(_ channel: ChatChannel) -> Bool {
        loadingNewerChannels.contains(channel.rawValue)
    }

    func loadOlderAsync(_ channel: ChatChannel = .couple) async {
        guard let first = messages(for: channel).first else { return }
        guard !loadingOlderChannels.contains(channel.rawValue) else { return }
        if let last = lastLoadOlderAt[channel.rawValue], Date().timeIntervalSince(last) < 0.45 { return }
        lastLoadOlderAt[channel.rawValue] = Date()
        loadingOlderChannels.insert(channel.rawValue)
        let limit = 22
        let firstTs = first.ts

        let localOlder = await Task.detached(priority: .utility) {
            ChatLocalDatabase.shared.fetchMessages(channel: channel.rawValue, beforeTimestamp: firstTs, limit: limit)
        }.value
        if !localOlder.isEmpty {
            updateMessages(channel) { current in
                let known = Set(current.map(\.id))
                current.insert(contentsOf: localOlder.filter { !known.contains($0.id) }, at: 0)
            }
            loadingOlderChannels.remove(channel.rawValue)
            return
        }
        guard let s = socketProvider?.socket, socketProvider?.isConnected == true else {
            loadingOlderChannels.remove(channel.rawValue)
            return
        }
        let older: [ChatMessage] = await withCheckedContinuation { continuation in
            s.emitWithAck("messages:fetch", ["channel": channel.rawValue, "before": firstTs, "limit": limit])
                .timingOut(after: 9) { data in
                    guard let dict = data.first as? [String: Any],
                          let list = dict["list"] as? [[String: Any]] else {
                        continuation.resume(returning: [])
                        return
                    }
                    continuation.resume(returning: Self.parseMessages(list, context: "loadOlder:\(channel.rawValue)"))
                }
        }
        defer { loadingOlderChannels.remove(channel.rawValue) }
        guard !older.isEmpty else { return }
        await Task.detached(priority: .utility) {
            for msg in older { ChatLocalDatabase.shared.insertMessage(msg) }
        }.value
        updateMessages(channel) { current in
            let known = Set(current.map(\.id))
            current.insert(contentsOf: older.filter { !known.contains($0.id) }, at: 0)
        }
    }

    func loadNewerAsync(_ channel: ChatChannel = .couple) async {
        guard let last = messages(for: channel).last else { return }
        guard !loadingNewerChannels.contains(channel.rawValue) else { return }
        if let lastLoad = lastLoadNewerAt[channel.rawValue], Date().timeIntervalSince(lastLoad) < 0.45 { return }
        lastLoadNewerAt[channel.rawValue] = Date()
        loadingNewerChannels.insert(channel.rawValue)
        let limit = 24
        let lastTs = last.ts

        let localNewer = await Task.detached(priority: .utility) {
            ChatLocalDatabase.shared.fetchMessages(
                channel: channel.rawValue, fromInclusive: lastTs + 0.001,
                toExclusive: Double.greatestFiniteMagnitude, limit: limit)
        }.value
        if !localNewer.isEmpty {
            updateMessages(channel) { current in
                let known = Set(current.map(\.id))
                current.append(contentsOf: localNewer.filter { !known.contains($0.id) })
            }
            loadingNewerChannels.remove(channel.rawValue)
            return
        }
        guard let s = socketProvider?.socket, socketProvider?.isConnected == true else {
            loadingNewerChannels.remove(channel.rawValue)
            return
        }
        let newer: [ChatMessage] = await withCheckedContinuation { continuation in
            s.emitWithAck("messages:fetch", ["channel": channel.rawValue, "after": lastTs, "limit": limit])
                .timingOut(after: 9) { data in
                    guard let dict = data.first as? [String: Any],
                          let list = dict["list"] as? [[String: Any]] else {
                        continuation.resume(returning: [])
                        return
                    }
                    continuation.resume(returning: Self.parseMessages(list, context: "loadNewer:\(channel.rawValue)"))
                }
        }
        defer { loadingNewerChannels.remove(channel.rawValue) }
        guard !newer.isEmpty else { return }
        await Task.detached(priority: .utility) {
            for msg in newer { ChatLocalDatabase.shared.insertMessage(msg) }
        }.value
        updateMessages(channel) { current in
            let known = Set(current.map(\.id))
            current.append(contentsOf: newer.filter { !known.contains($0.id) })
        }
    }

    // MARK: - 发送

    func sendText(_ text: String, channel: ChatChannel = .couple,
                  replyTo: String? = nil, replyPreview: String? = nil,
                  session: Session) {
        guard let s = socketProvider?.socket else { return }
        let clientId = "tmp-" + UUID().uuidString
        let optimistic = ChatMessage(optimisticText: text, me: session, clientId: clientId,
                                     channel: channel.rawValue, replyTo: replyTo, replyPreview: replyPreview)
        updateMessages(channel) { $0.append(optimistic) }

        guard socketProvider?.isConnected == true else {
            updateMessages(channel) { list in
                guard let i = list.firstIndex(where: { $0.id == clientId }) else { return }
                list[i].pending = false
                list[i].failed = true
            }
            return
        }

        var payload: [String: Any] = [
            "type": "text", "text": text, "channel": channel.rawValue, "clientId": clientId,
        ]
        if let replyTo {
            payload["replyTo"] = replyTo
            payload["replyPreview"] = replyPreview ?? ""
            payload["reply"] = ["id": replyTo, "preview": replyPreview ?? ""]
        }
        s.emitWithAck("message:send", payload).timingOut(after: 15) { [weak self] data in
            Task { @MainActor in
                self?.handleSendAck(data, clientId: clientId, channel: channel)
            }
        }
    }

    func sendMedia(data: Data, mimeType: String, preferredType: String, localPreviewURL: URL?,
                   channel: ChatChannel = .couple, displayText: String? = nil, session: Session) {
        guard let s = socketProvider?.socket else { return }
        let clientId = "tmp-" + UUID().uuidString
        let outgoingText = displayText ?? Self.mediaPlaceholderText(for: preferredType)
        let optimistic = ChatMessage(
            optimisticMedia: preferredType, text: outgoingText, localURL: localPreviewURL?.absoluteString,
            me: session, clientId: clientId, channel: channel.rawValue)
        updateMessages(channel) { $0.append(optimistic) }
        pendingMediaData[clientId] = (data: data, mimeType: mimeType, preferredType: preferredType, channel: channel)

        guard socketProvider?.isConnected == true else {
            updateMessages(channel) { list in
                guard let i = list.firstIndex(where: { $0.id == clientId }) else { return }
                list[i].pending = false
                list[i].failed = true
            }
            return
        }

        Task {
            do {
                let uploaded = try await uploadMedia(data: data, mimeType: mimeType, session: session)
                pendingMediaData.removeValue(forKey: clientId)
                let type = preferredType == "file" ? "file" : (uploaded.type.isEmpty ? preferredType : uploaded.type)
                updateMessages(channel) { list in
                    guard let i = list.firstIndex(where: { $0.id == clientId }) else { return }
                    list[i].type = type
                    list[i].url = uploaded.url
                }
                let payload: [String: Any] = [
                    "type": type, "text": displayText ?? Self.mediaPlaceholderText(for: type),
                    "url": uploaded.url, "channel": channel.rawValue, "clientId": clientId,
                ]
                s.emitWithAck("message:send", payload).timingOut(after: 15) { [weak self] data in
                    Task { @MainActor in self?.handleSendAck(data, clientId: clientId, channel: channel) }
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

    func sendSticker(url: String, channel: ChatChannel = .couple, session: Session) {
        guard let s = socketProvider?.socket else { return }
        let clientId = "tmp-" + UUID().uuidString
        let optimistic = ChatMessage(
            optimisticMedia: "sticker", text: "[表情]", localURL: url,
            me: session, clientId: clientId, channel: channel.rawValue)
        updateMessages(channel) { $0.append(optimistic) }

        guard socketProvider?.isConnected == true else {
            updateMessages(channel) { list in
                guard let i = list.firstIndex(where: { $0.id == clientId }) else { return }
                list[i].pending = false
                list[i].failed = true
            }
            return
        }

        let payload: [String: Any] = [
            "type": "sticker", "text": "[表情]", "url": url,
            "channel": channel.rawValue, "clientId": clientId,
        ]
        s.emitWithAck("message:send", payload).timingOut(after: 15) { [weak self] data in
            Task { @MainActor in self?.handleSendAck(data, clientId: clientId, channel: channel) }
        }
    }

    func uploadSticker(_ image: UIImage, session: Session) async -> String? {
        guard let data = image.jpegData(compressionQuality: 0.9),
              let uploaded = try? await uploadMedia(data: data, mimeType: "image/jpeg", session: session) else { return nil }
        if let url = ServerConfig.resolveMediaURL(uploaded.url) {
            ImageCache.shared.store(data: data, image: image, for: url)
        }
        return uploaded.url
    }

    func resend(_ message: ChatMessage, session: Session) {
        guard message.failed else { return }
        let channel = ChatChannel(rawValue: message.channel) ?? .couple
        if message.type == "text" {
            updateMessages(channel) { $0.removeAll { $0.id == message.id } }
            sendText(message.text, channel: channel, session: session)
        } else if let cached = pendingMediaData[message.id] {
            updateMessages(channel) { $0.removeAll { $0.id == message.id } }
            pendingMediaData.removeValue(forKey: message.id)
            sendMedia(data: cached.data, mimeType: cached.mimeType, preferredType: cached.preferredType,
                      localPreviewURL: nil, channel: cached.channel, session: session)
        }
    }

    func hasPendingMedia(_ message: ChatMessage) -> Bool {
        pendingMediaData[message.id] != nil
    }

    // MARK: - 已读

    func markRead(_ channel: ChatChannel = .couple) {
        guard let s = socketProvider?.socket, socketProvider?.isConnected == true,
              let lastTs = messages(for: channel).last(where: { !$0.pending })?.ts else { return }
        s.emit("read", ["channel": channel.rawValue, "ts": lastTs])
    }

    func partnerHasRead(_ msg: ChatMessage, username: String?) -> Bool {
        guard msg.channel == ChatChannel.couple.rawValue, let me = username else { return false }
        let partnerTs = readState(for: .couple).first(where: { $0.key != me })?.value ?? 0
        if partnerTs <= 0, msg.sender == me, !msg.pending, !msg.failed, msg.ts < storeStartedAtMs - 60_000 {
            return true
        }
        return msg.ts <= partnerTs
    }

    func readState(for channel: ChatChannel) -> [String: Double] {
        readStates[channel.rawValue] ?? [:]
    }

    func setReadState(_ channel: ChatChannel, state: [String: Double]) {
        var next = readStates
        next[channel.rawValue] = state
        readStates = next
        for (user, ts) in state {
            ChatLocalDatabase.shared.saveReadReceipt(channel: channel.rawValue, username: user, ts: ts, updatedAt: Date().timeIntervalSince1970 * 1000)
        }
    }

    func setReadState(_ channel: ChatChannel, user: String, ts: Double) {
        var state = readState(for: channel)
        if ts > (state[user] ?? 0) { state[user] = ts }
        setReadState(channel, state: state)
    }

    // MARK: - 撤回

    func recallMessage(_ message: ChatMessage, channel: ChatChannel) {
        guard let s = socketProvider?.socket, socketProvider?.isConnected == true else { return }
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

    func applyRecall(id: String, byName: String?, channel: ChatChannel?, myUsername: String?) {
        let channels = channel.map { [$0] } ?? ChatChannel.allCases
        for c in channels {
            updateMessages(c) { list in
                guard let i = list.firstIndex(where: { $0.id == id }) else { return }
                var m = list[i]
                let mine = m.sender == myUsername
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

    // MARK: - Meta 更新（确认卡）

    func applyMessageUpdate(id: String, meta: [String: Any]?) {
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

    func confirmAction(messageId: String, decision: String) {
        socketProvider?.socket?.emit("action:confirm", ["messageId": messageId, "decision": decision])
    }

    // MARK: - 搜索

    func searchMessages(_ query: String, channel: ChatChannel) async -> [ChatMessage] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let local = ChatLocalDatabase.shared.searchMessages(query: q, channel: channel.rawValue)
        guard let s = socketProvider?.socket, socketProvider?.isConnected == true else { return local }
        return await withCheckedContinuation { continuation in
            s.emitWithAck("messages:search", ["channel": channel.rawValue, "query": q, "limit": 50])
                .timingOut(after: 9) { data in
                    guard let dict = data.first as? [String: Any],
                          let list = dict["list"] as? [[String: Any]] else {
                        continuation.resume(returning: local)
                        return
                    }
                    let remote = Self.parseMessages(list, context: "search:\(channel.rawValue)")
                    continuation.resume(returning: Self.mergeSearchResults(remote, local))
                }
        }
    }

    func mediaMessages(for channel: ChatChannel, includeFiles: Bool = false, limit: Int? = nil) -> [ChatMessage] {
        let types = includeFiles ? Self.managedAttachmentTypes : Self.mediaTypes
        return ChatLocalDatabase.shared.mediaMessages(channel: channel.rawValue, types: types, limit: limit)
    }

    func mediaItemCount(for channel: ChatChannel, includeFiles: Bool = false) -> Int {
        let types = includeFiles ? Self.managedAttachmentTypes : Self.mediaTypes
        return ChatLocalDatabase.shared.mediaCount(channel: channel.rawValue, types: types)
    }

    // MARK: - 全量同步

    @discardableResult
    func syncAllHistory(_ channel: ChatChannel, onProgress: @escaping (Int) -> Void) async -> Int {
        guard let s = socketProvider?.socket, socketProvider?.isConnected == true else { return 0 }
        var oldest = messages(for: channel).first?.ts
        var total = 0
        let pageLimit = 200
        while !Task.isCancelled {
            let batch: [ChatMessage] = await withCheckedContinuation { cont in
                var payload: [String: Any] = ["channel": channel.rawValue, "limit": pageLimit]
                if let oldest { payload["before"] = oldest }
                s.emitWithAck("messages:fetch", payload).timingOut(after: 15) { data in
                    guard let dict = data.first as? [String: Any],
                          let list = dict["list"] as? [[String: Any]] else {
                        cont.resume(returning: [])
                        return
                    }
                    cont.resume(returning: Self.parseMessages(list, context: "syncAll:\(channel.rawValue)"))
                }
            }
            if batch.isEmpty { break }
            for m in batch { ChatLocalDatabase.shared.insertMessage(m) }
            total += batch.count
            onProgress(total)
            let batchOldest = batch.map(\.ts).min()
            if batch.count < pageLimit { break }
            if let batchOldest, let prev = oldest, batchOldest >= prev { break }
            oldest = batchOldest
        }
        let latest = ChatLocalDatabase.shared.fetchLatestMessages(channel: channel.rawValue, limit: 50)
        if !latest.isEmpty { updateMessages(channel) { $0 = latest } }
        return total
    }

    // MARK: - 私有辅助

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
                    "url": old.url as Any, "channel": old.channel, "ts": old.ts, "clientId": clientId,
                ]
                if let replyTo = old.replyTo {
                    payload["replyTo"] = replyTo
                    payload["replyPreview"] = old.replyPreview ?? ""
                    payload["reply"] = ["id": replyTo, "preview": old.replyPreview ?? ""]
                }
                list[i] = ChatMessage(dict: payload) ?? old
                ChatLocalDatabase.shared.insertMessage(list[i])
            } else {
                list[i].pending = false
                list[i].failed = true
            }
        }
    }

    func uploadMedia(data: Data, mimeType: String, session: Session) async throws -> UploadResult {
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: ServerConfig.baseURL.appendingPathComponent("api/upload"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.multipartBody(data: data, mimeType: mimeType, boundary: boundary)
        let (responseData, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: responseData))?["error"]
            throw NSError(domain: "upload", code: 1, userInfo: [NSLocalizedDescriptionKey: msg ?? "上传失败"])
        }
        return try JSONDecoder().decode(UploadResult.self, from: responseData)
    }

    struct UploadResult: Decodable {
        let url: String
        let type: String
    }

    static func mediaPlaceholderText(for type: String) -> String {
        switch type {
        case "video": return "[视频]"
        case "voice": return "[语音]"
        case "file": return "[文件]"
        default: return "[图片]"
        }
    }

    static func multipartBody(data: Data, mimeType: String, boundary: String) -> Data {
        var body = Data()
        let filename: String
        if mimeType.contains("video") { filename = "media.mp4" }
        else if mimeType.contains("audio") { filename = "media.m4a" }
        else { filename = "media.jpg" }
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n")
        return body
    }

    nonisolated static func mergeSearchResults(_ first: [ChatMessage], _ second: [ChatMessage]) -> [ChatMessage] {
        var seen = Set<String>()
        return (first + second)
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.ts > $1.ts }
    }

    nonisolated static func mergedWindow(_ window: [ChatMessage], with current: [ChatMessage], around targetId: String) -> [ChatMessage] {
        guard !window.isEmpty else { return current }
        var seen = Set<String>()
        let merged = (window + current)
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.ts < $1.ts }
        guard let targetIndex = merged.firstIndex(where: { $0.id == targetId }) else {
            return Array(merged.suffix(90))
        }
        let lower = max(0, targetIndex - 36)
        let upper = min(merged.count, targetIndex + 42)
        return Array(merged[lower..<upper])
    }

    nonisolated static func dayRange(for date: Date) -> (start: Double, end: Double) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let start = cal.startOfDay(for: date)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return (start.timeIntervalSince1970 * 1000, end.timeIntervalSince1970 * 1000)
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(contentsOf: string.utf8)
    }
}
