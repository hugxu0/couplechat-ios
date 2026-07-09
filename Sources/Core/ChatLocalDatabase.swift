import Foundation
import SQLite3

final class ChatLocalDatabase {
    static let shared = ChatLocalDatabase()
    private var db: OpaquePointer?
    private(set) var currentDatabaseURL: URL?
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private init() {}

    func open(username: String) -> Bool {
        if db != nil { close() }
        let fileManager = FileManager.default
        let appSupportDirs = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let directoryURL = appSupportDirs[0].appendingPathComponent("ChatCache", isDirectory: true)

        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        } catch {
            return false
        }

        let safeUsername = username
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let dbURL = directoryURL.appendingPathComponent("\(safeUsername).sqlite")
        currentDatabaseURL = dbURL

        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            return false
        }

        createTables()
        return true
    }

    // MARK: - 存储空间统计（供缓存管理页）

    /// 本地数据库文件大小（含 -wal / -shm）
    func databaseSizeBytes() -> Int64 {
        guard let url = currentDatabaseURL else { return 0 }
        let fm = FileManager.default
        var total: Int64 = 0
        for path in [url.path, url.path + "-wal", url.path + "-shm"] {
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let size = (attrs[.size] as? NSNumber)?.int64Value {
                total += size
            }
        }
        return total
    }

    /// 某频道已缓存的消息条数
    func messageCount(channel: String) -> Int {
        let sql = "SELECT COUNT(*) FROM messages WHERE channel = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        sqlite3_bind_text(stmt, 1, channel, -1, SQLITE_TRANSIENT)
        var count = 0
        if sqlite3_step(stmt) == SQLITE_ROW {
            count = Int(sqlite3_column_int(stmt, 0))
        }
        sqlite3_finalize(stmt)
        return count
    }

    /// 某频道内指定类型消息的媒体地址列表（去重、去空），用于「缓存全部图片」
    func mediaURLs(channel: String, types: [String]) -> [String] {
        guard !types.isEmpty else { return [] }
        let placeholders = types.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT DISTINCT url FROM messages
        WHERE channel = ? AND url IS NOT NULL AND url <> '' AND type IN (\(placeholders));
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, channel, -1, SQLITE_TRANSIENT)
        for (i, type) in types.enumerated() {
            sqlite3_bind_text(stmt, Int32(2 + i), type, -1, SQLITE_TRANSIENT)
        }
        var urls: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let value = readText(stmt, index: 0) { urls.append(value) }
        }
        sqlite3_finalize(stmt)
        return urls
    }
    
    func close() {
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
    }
    
    private func createTables() {
        let messagesSQL = """
        CREATE TABLE IF NOT EXISTS messages (
            id TEXT PRIMARY KEY,
            channel TEXT NOT NULL,
            sender TEXT NOT NULL,
            senderName TEXT NOT NULL,
            kind TEXT NOT NULL,
            type TEXT NOT NULL,
            text TEXT NOT NULL,
            url TEXT,
            replyTo TEXT,
            replyPreview TEXT,
            ts REAL NOT NULL,
            clientId TEXT,
            metaJson TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_messages_channel_ts ON messages(channel, ts);
        CREATE INDEX IF NOT EXISTS idx_messages_channel_type_ts ON messages(channel, type, ts);
        """
        
        let readReceiptsSQL = """
        CREATE TABLE IF NOT EXISTS read_receipts (
            channel TEXT NOT NULL,
            username TEXT NOT NULL,
            ts REAL NOT NULL,
            updatedAt REAL NOT NULL,
            PRIMARY KEY (channel, username)
        );
        """
        
        let sharedStateSQL = """
        CREATE TABLE IF NOT EXISTS shared_state (
            key TEXT PRIMARY KEY,
            valueJson TEXT NOT NULL,
            updatedBy TEXT NOT NULL,
            updatedAt REAL NOT NULL
        );
        """
        
        execute(sql: messagesSQL)
        execute(sql: readReceiptsSQL)
        execute(sql: sharedStateSQL)
    }
    
    private func execute(sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }
    
    // MARK: - Message Operations
    
    func insertMessage(_ msg: ChatMessage) {
        // 乐观占位/发送失败的消息不落库：它们的 id 是临时的 tmp-xxx，
        // 重启后既发不出去也删不掉，只会在列表里留下幽灵消息。
        guard !msg.pending, !msg.failed, !msg.id.hasPrefix("tmp-") else { return }
        let sql = """
        INSERT OR REPLACE INTO messages 
        (id, channel, sender, senderName, kind, type, text, url, replyTo, replyPreview, ts, clientId, metaJson)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return
        }
        
        sqlite3_bind_text(stmt, 1, msg.id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, msg.channel, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, msg.sender, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, msg.senderName, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 5, msg.kind, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 6, msg.type, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 7, msg.text, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 8, msg.url, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 9, msg.replyTo, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 10, msg.replyPreview, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 11, msg.ts)
        sqlite3_bind_text(stmt, 12, msg.clientId, -1, SQLITE_TRANSIENT)
        
        var metaStr: String? = nil
        if let meta = msg.meta {
            if let data = try? JSONEncoder().encode(meta) {
                metaStr = String(data: data, encoding: .utf8)
            }
        }
        sqlite3_bind_text(stmt, 13, metaStr, -1, SQLITE_TRANSIENT)
        
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }
    
    func deleteMessage(id: String) {
        let sql = "DELETE FROM messages WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }
    
    func fetchMessages(channel: String, beforeTimestamp: Double, limit: Int) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        let sql = """
        SELECT id, channel, sender, senderName, kind, type, text, url, replyTo, replyPreview, ts, clientId, metaJson 
        FROM messages 
        WHERE channel = ? AND ts < ? 
        ORDER BY ts DESC 
        LIMIT ?;
        """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        
        sqlite3_bind_text(stmt, 1, channel, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, beforeTimestamp)
        sqlite3_bind_int(stmt, 3, Int32(limit))
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let msg = parseMessageRow(stmt) {
                messages.append(msg)
            }
        }
        
        sqlite3_finalize(stmt)
        return messages.reversed() // Return chronologically ordered
    }
    
    /// 拉取某个时间区间内的全部消息（含端点），按时间正序。
    /// 用于「搜索结果跳转」把命中消息与当前已加载窗口之间的空档补齐，保证能定位。
    func fetchMessages(channel: String, fromTimestamp: Double, toTimestamp: Double) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        let sql = """
        SELECT id, channel, sender, senderName, kind, type, text, url, replyTo, replyPreview, ts, clientId, metaJson
        FROM messages
        WHERE channel = ? AND ts >= ? AND ts <= ?
        ORDER BY ts ASC;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }

        sqlite3_bind_text(stmt, 1, channel, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, fromTimestamp)
        sqlite3_bind_double(stmt, 3, toTimestamp)

        while sqlite3_step(stmt) == SQLITE_ROW {
            if let msg = parseMessageRow(stmt) {
                messages.append(msg)
            }
        }

        sqlite3_finalize(stmt)
        return messages
    }

    /// 拉取目标消息附近的一小段上下文，避免跳到很久以前的消息时把中间全部历史塞进 SwiftUI 列表。
    func fetchMessagesAround(channel: String, centerTimestamp: Double, beforeLimit: Int, afterLimit: Int) -> [ChatMessage] {
        let before = fetchMessagesBeforeOrAt(channel: channel, timestamp: centerTimestamp, limit: beforeLimit)
        let after = fetchMessagesAfter(channel: channel, timestamp: centerTimestamp, limit: afterLimit)
        var seen = Set<String>()
        return (before + after)
            .filter { msg in
                guard !seen.contains(msg.id) else { return false }
                seen.insert(msg.id)
                return true
            }
            .sorted { $0.ts < $1.ts }
    }

    func fetchMessages(channel: String, fromInclusive: Double, toExclusive: Double, limit: Int? = nil) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        let limitClause = limit == nil ? "" : "LIMIT ?"
        let sql = """
        SELECT id, channel, sender, senderName, kind, type, text, url, replyTo, replyPreview, ts, clientId, metaJson
        FROM messages
        WHERE channel = ? AND ts >= ? AND ts < ?
        ORDER BY ts ASC
        \(limitClause);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }

        sqlite3_bind_text(stmt, 1, channel, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, fromInclusive)
        sqlite3_bind_double(stmt, 3, toExclusive)
        if let limit {
            sqlite3_bind_int(stmt, 4, Int32(limit))
        }

        while sqlite3_step(stmt) == SQLITE_ROW {
            if let msg = parseMessageRow(stmt) {
                messages.append(msg)
            }
        }

        sqlite3_finalize(stmt)
        return messages
    }

    func mediaMessages(channel: String, types: [String], limit: Int? = nil) -> [ChatMessage] {
        guard !types.isEmpty else { return [] }
        var messages: [ChatMessage] = []
        let placeholders = types.map { _ in "?" }.joined(separator: ",")
        let limitClause = limit == nil ? "" : "LIMIT ?"
        let sql = """
        SELECT id, channel, sender, senderName, kind, type, text, url, replyTo, replyPreview, ts, clientId, metaJson
        FROM messages
        WHERE channel = ? AND type IN (\(placeholders)) AND kind = 'user'
        ORDER BY ts DESC
        \(limitClause);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, channel, -1, SQLITE_TRANSIENT)
        for (i, type) in types.enumerated() {
            sqlite3_bind_text(stmt, Int32(2 + i), type, -1, SQLITE_TRANSIENT)
        }
        if let limit {
            sqlite3_bind_int(stmt, Int32(2 + types.count), Int32(limit))
        }

        while sqlite3_step(stmt) == SQLITE_ROW {
            if let msg = parseMessageRow(stmt) {
                messages.append(msg)
            }
        }

        sqlite3_finalize(stmt)
        return messages
    }

    func mediaCount(channel: String, types: [String]) -> Int {
        guard !types.isEmpty else { return 0 }
        let placeholders = types.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT COUNT(*) FROM messages
        WHERE channel = ? AND type IN (\(placeholders)) AND kind = 'user';
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        sqlite3_bind_text(stmt, 1, channel, -1, SQLITE_TRANSIENT)
        for (i, type) in types.enumerated() {
            sqlite3_bind_text(stmt, Int32(2 + i), type, -1, SQLITE_TRANSIENT)
        }
        var count = 0
        if sqlite3_step(stmt) == SQLITE_ROW {
            count = Int(sqlite3_column_int(stmt, 0))
        }
        sqlite3_finalize(stmt)
        return count
    }

    func dayCounts(channel: String) -> [(date: String, sender: String, count: Int)] {
        groupedCounts(channel: channel, format: "%Y-%m-%d")
    }

    func monthCounts(channel: String) -> [(date: String, sender: String, count: Int)] {
        groupedCounts(channel: channel, format: "%Y-%m")
    }

    func fetchLatestMessages(channel: String, limit: Int) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        let sql = """
        SELECT id, channel, sender, senderName, kind, type, text, url, replyTo, replyPreview, ts, clientId, metaJson 
        FROM messages 
        WHERE channel = ? 
        ORDER BY ts DESC 
        LIMIT ?;
        """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        
        sqlite3_bind_text(stmt, 1, channel, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let msg = parseMessageRow(stmt) {
                messages.append(msg)
            }
        }
        
        sqlite3_finalize(stmt)
        return messages.reversed() // Return chronologically ordered
    }

    private func fetchMessagesBeforeOrAt(channel: String, timestamp: Double, limit: Int) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        let sql = """
        SELECT id, channel, sender, senderName, kind, type, text, url, replyTo, replyPreview, ts, clientId, metaJson
        FROM messages
        WHERE channel = ? AND ts <= ?
        ORDER BY ts DESC
        LIMIT ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, channel, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, timestamp)
        sqlite3_bind_int(stmt, 3, Int32(limit))

        while sqlite3_step(stmt) == SQLITE_ROW {
            if let msg = parseMessageRow(stmt) {
                messages.append(msg)
            }
        }

        sqlite3_finalize(stmt)
        return messages.reversed()
    }

    private func fetchMessagesAfter(channel: String, timestamp: Double, limit: Int) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        let sql = """
        SELECT id, channel, sender, senderName, kind, type, text, url, replyTo, replyPreview, ts, clientId, metaJson
        FROM messages
        WHERE channel = ? AND ts > ?
        ORDER BY ts ASC
        LIMIT ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, channel, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, timestamp)
        sqlite3_bind_int(stmt, 3, Int32(limit))

        while sqlite3_step(stmt) == SQLITE_ROW {
            if let msg = parseMessageRow(stmt) {
                messages.append(msg)
            }
        }

        sqlite3_finalize(stmt)
        return messages
    }

    private func groupedCounts(channel: String, format: String) -> [(date: String, sender: String, count: Int)] {
        let sql = """
        SELECT strftime(?, ts / 1000, 'unixepoch', '+8 hours') AS bucket, sender, COUNT(*)
        FROM messages
        WHERE channel = ? AND kind = 'user' AND sender <> 'ai'
        GROUP BY bucket, sender
        ORDER BY bucket ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, format, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, channel, -1, SQLITE_TRANSIENT)

        var rows: [(date: String, sender: String, count: Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let bucket = readText(stmt, index: 0),
               let sender = readText(stmt, index: 1) {
                rows.append((date: bucket, sender: sender, count: Int(sqlite3_column_int(stmt, 2))))
            }
        }
        sqlite3_finalize(stmt)
        return rows
    }
    
    func searchMessages(query: String, channel: String) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        let sql = """
        SELECT id, channel, sender, senderName, kind, type, text, url, replyTo, replyPreview, ts, clientId, metaJson 
        FROM messages 
        WHERE channel = ? AND (text LIKE ? OR replyPreview LIKE ?)
        ORDER BY ts DESC 
        LIMIT 100;
        """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        
        let matchQuery = "%\(query)%"
        sqlite3_bind_text(stmt, 1, channel, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, matchQuery, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, matchQuery, -1, SQLITE_TRANSIENT)
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let msg = parseMessageRow(stmt) {
                messages.append(msg)
            }
        }
        
        sqlite3_finalize(stmt)
        return messages
    }
    
    // MARK: - Read Receipt Operations
    
    func saveReadReceipt(channel: String, username: String, ts: Double, updatedAt: Double) {
        let sql = """
        INSERT OR REPLACE INTO read_receipts (channel, username, ts, updatedAt)
        VALUES (?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        
        sqlite3_bind_text(stmt, 1, channel, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, username, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 3, ts)
        sqlite3_bind_double(stmt, 4, updatedAt)
        
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }
    
    func loadReadReceipts(channel: String) -> [String: Double] {
        var receipts: [String: Double] = [:]
        let sql = "SELECT username, ts FROM read_receipts WHERE channel = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        
        sqlite3_bind_text(stmt, 1, channel, -1, SQLITE_TRANSIENT)
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let username = readText(stmt, index: 0) {
                let ts = sqlite3_column_double(stmt, 1)
                receipts[username] = ts
            }
        }
        
        sqlite3_finalize(stmt)
        return receipts
    }
    
    // MARK: - Shared State Operations
    
    func saveSharedState(key: String, valueJson: String, updatedBy: String, updatedAt: Double) {
        let sql = """
        INSERT OR REPLACE INTO shared_state (key, valueJson, updatedBy, updatedAt)
        VALUES (?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, valueJson, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, updatedBy, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 4, updatedAt)
        
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }
    
    func loadSharedState() -> [String: Any] {
        var state: [String: Any] = [:]
        let sql = "SELECT key, valueJson, updatedBy, updatedAt FROM shared_state;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let key = readText(stmt, index: 0),
               let valueJson = readText(stmt, index: 1),
               let updatedBy = readText(stmt, index: 2) {
                let updatedAt = sqlite3_column_double(stmt, 3)
                
                if let data = valueJson.data(using: .utf8),
                   let jsonObject = try? JSONSerialization.jsonObject(with: data) {
                    state[key] = [
                        "key": key,
                        "value": jsonObject,
                        "updatedBy": updatedBy,
                        "updatedAt": updatedAt
                    ]
                }
            }
        }
        
        sqlite3_finalize(stmt)
        return state
    }
    
    // MARK: - Helper Methods
    
    private func bindText(_ stmt: OpaquePointer?, index: Int32, value: String?) {
        if let value = value {
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
    
    private func readText(_ stmt: OpaquePointer?, index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: UnsafeRawPointer(cString).assumingMemoryBound(to: CChar.self))
    }
    
    private func parseMessageRow(_ stmt: OpaquePointer?) -> ChatMessage? {
        guard let id = readText(stmt, index: 0),
              let channel = readText(stmt, index: 1),
              let sender = readText(stmt, index: 2),
              let senderName = readText(stmt, index: 3),
              let kind = readText(stmt, index: 4),
              let type = readText(stmt, index: 5),
              let text = readText(stmt, index: 6) else {
            return nil
        }
        
        let url = readText(stmt, index: 7)
        let replyTo = readText(stmt, index: 8)
        let replyPreview = readText(stmt, index: 9)
        let ts = sqlite3_column_double(stmt, 10)
        let clientId = readText(stmt, index: 11)
        let metaJson = readText(stmt, index: 12)
        
        var dict: [String: Any] = [
            "id": id,
            "channel": channel,
            "sender": sender,
            "senderName": senderName,
            "kind": kind,
            "type": type,
            "text": text,
            "ts": ts
        ]
        if let url = url { dict["url"] = url }
        if let replyTo = replyTo { dict["replyTo"] = replyTo }
        if let replyPreview = replyPreview { dict["replyPreview"] = replyPreview }
        if let clientId = clientId { dict["clientId"] = clientId }
        
        if let metaJson = metaJson,
           let data = metaJson.data(using: .utf8),
           let metaObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict["meta"] = metaObj
        }
        
        if let msg = ChatMessage(dict: dict) {
            return msg
        }
        let msgId = dict["id"] as? String ?? "?"
        print("[ChatLocalDatabase] ⚠️ 消息解析失败 | id=\(msgId) source=SQLite")
        return nil
    }
}
