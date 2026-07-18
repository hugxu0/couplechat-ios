import Foundation
import SQLite3

final class ChatLocalDatabase {
    static let shared = ChatLocalDatabase()
    private static let schemaVersion: Int32 = 7
    private var db: OpaquePointer?
    private(set) var currentDatabaseURL: URL?
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let databaseLock = NSRecursiveLock()

    private init() {}

    func open(username: String) -> Bool {
        databaseLock.lock()
        defer { databaseLock.unlock() }
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

        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(dbURL.path, &db, flags, nil) != SQLITE_OK {
            close()
            return false
        }

        sqlite3_busy_timeout(db, 5_000)
        guard execute(sql: "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;"),
              createTables() else {
            close()
            return false
        }
        return true
    }

    // MARK: - 存储空间统计（供缓存管理页）

    /// 本地数据库文件大小（含 -wal / -shm）
    func databaseSizeBytes() -> Int64 {
        databaseLock.lock()
        defer { databaseLock.unlock() }
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
        databaseLock.lock()
        defer { databaseLock.unlock() }
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
        databaseLock.lock()
        defer { databaseLock.unlock() }
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
        databaseLock.lock()
        defer { databaseLock.unlock() }
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
        currentDatabaseURL = nil
    }
    
    private func createTables() -> Bool {
        let currentVersion = schemaVersion()
        guard currentVersion <= Self.schemaVersion else {
            print("[ChatLocalDatabase] ⚠️ 本地数据库版本 \(currentVersion) 高于客户端支持的 \(Self.schemaVersion)")
            return false
        }
        guard execute(sql: "BEGIN IMMEDIATE TRANSACTION;") else { return false }
        var committed = false
        defer {
            if !committed { rollbackOrInvalidate(context: "schema migration") }
        }

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
            metaJson TEXT,
            recalledText TEXT,
            attachmentsJson TEXT
        );
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

        let outboxSQL = """
        CREATE TABLE IF NOT EXISTS pending_outbound_messages (
            clientId TEXT PRIMARY KEY,
            channel TEXT NOT NULL,
            type TEXT NOT NULL,
            text TEXT NOT NULL,
            replyTo TEXT,
            replyPreview TEXT,
            localFilePath TEXT,
            mimeType TEXT,
            uploadId TEXT,
            uploadURL TEXT,
            createdAt REAL NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,
            lastError TEXT
            ,metaJson TEXT
            ,attachmentsJson TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_pending_outbound_created
            ON pending_outbound_messages(createdAt);
        """

        let appMetaSQL = """
        CREATE TABLE IF NOT EXISTS app_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """
        
        guard execute(sql: messagesSQL),
              ensureMessageColumns(),
              execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_channel_ts ON messages(channel, ts);"),
              execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_channel_type_ts ON messages(channel, type, ts);"),
              execute(sql: readReceiptsSQL),
              execute(sql: sharedStateSQL),
              execute(sql: outboxSQL),
              ensureOutboxColumns(),
              execute(sql: appMetaSQL),
              migrateHardDeletedRecalls(from: currentVersion),
              execute(sql: "PRAGMA user_version = \(Self.schemaVersion);"),
              execute(sql: "COMMIT;") else { return false }
        committed = true
        return true
    }

    private func migrateHardDeletedRecalls(from version: Int32) -> Bool {
        guard version < 6 else { return true }
        return execute(sql: """
        UPDATE messages
           SET replyTo = NULL, replyPreview = NULL
         WHERE replyTo IN (
           SELECT id FROM messages
            WHERE recalledText IS NOT NULL
               OR (kind = 'system' AND type = 'text' AND text = '你撤回了一条消息')
         );
        DELETE FROM messages
         WHERE recalledText IS NOT NULL
            OR (kind = 'system' AND type = 'text' AND text = '你撤回了一条消息');
        """)
    }

    /// CREATE TABLE IF NOT EXISTS 不会给旧表补列。逐列检查使跨多个历史版本升级也安全。
    private func ensureMessageColumns() -> Bool {
        let definitions: [(String, String)] = [
            ("channel", "TEXT NOT NULL DEFAULT 'couple'"),
            ("sender", "TEXT NOT NULL DEFAULT ''"),
            ("senderName", "TEXT NOT NULL DEFAULT ''"),
            ("kind", "TEXT NOT NULL DEFAULT 'user'"),
            ("type", "TEXT NOT NULL DEFAULT 'text'"),
            ("text", "TEXT NOT NULL DEFAULT ''"),
            ("url", "TEXT"),
            ("replyTo", "TEXT"),
            ("replyPreview", "TEXT"),
            ("ts", "REAL NOT NULL DEFAULT 0"),
            ("clientId", "TEXT"),
            ("metaJson", "TEXT"),
            ("recalledText", "TEXT"),
            ("attachmentsJson", "TEXT"),
        ]
        let existing = tableColumns("messages")
        for (name, definition) in definitions where !existing.contains(name) {
            guard execute(sql: "ALTER TABLE messages ADD COLUMN \(name) \(definition);") else { return false }
        }
        return true
    }

    private func ensureOutboxColumns() -> Bool {
        let existing = tableColumns("pending_outbound_messages")
        for (name, definition) in [("metaJson", "TEXT"), ("attachmentsJson", "TEXT")]
        where !existing.contains(name) {
            guard execute(sql: "ALTER TABLE pending_outbound_messages ADD COLUMN \(name) \(definition);") else { return false }
        }
        return true
    }

    private func tableColumns(_ table: String) -> Set<String> {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var columns = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = readText(stmt, index: 1) { columns.insert(name) }
        }
        return columns
    }

    private func schemaVersion() -> Int32 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int(stmt, 0)
    }

    @discardableResult
    private func execute(sql: String) -> Bool {
        var errorMessage: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        defer { sqlite3_free(errorMessage) }
        guard result == SQLITE_OK else {
            let detail = errorMessage.map { String(cString: $0) } ?? "SQLite error \(result)"
            print("[ChatLocalDatabase] ⚠️ SQL 执行失败: \(detail)")
            return false
        }
        return true
    }
    
    // MARK: - Message Operations
    
    @discardableResult
    func insertMessage(_ msg: ChatMessage) -> Bool {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        return insertMessageLocked(msg)
    }

    private func insertMessageLocked(_ msg: ChatMessage) -> Bool {
        // 乐观占位/发送失败的消息不落库：它们的 id 是临时的 tmp-xxx，
        // 重启后既发不出去也删不掉，只会在列表里留下幽灵消息。
        guard !msg.pending, !msg.failed, !msg.id.hasPrefix("tmp-") else { return false }
        guard ChatChannel(rawValue: msg.channel) != nil else {
            print("[ChatLocalDatabase] ⚠️ 拒绝写入未知频道消息 id=\(msg.id)")
            return false
        }
        let sql = """
        INSERT OR REPLACE INTO messages 
        (id, channel, sender, senderName, kind, type, text, url, replyTo, replyPreview, ts, clientId, metaJson, recalledText, attachmentsJson)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        
        let metaString: String?
        let attachmentsString: String?
        do {
            if let meta = msg.meta {
                let data = try JSONEncoder().encode(meta)
                guard let value = String(data: data, encoding: .utf8) else { return false }
                metaString = value
            } else {
                metaString = nil
            }
            if let attachments = msg.attachments {
                let data = try JSONEncoder().encode(attachments)
                guard let value = String(data: data, encoding: .utf8) else { return false }
                attachmentsString = value
            } else {
                attachmentsString = nil
            }
        } catch {
            print("[ChatLocalDatabase] ⚠️ 消息附加数据编码失败 id=\(msg.id)")
            return false
        }

        return performPreparedWrite(
            sql: sql,
            operation: "upsert message",
            bindings: { stmt in
                [
                    sqlite3_bind_text(stmt, 1, msg.id, -1, self.SQLITE_TRANSIENT),
                    sqlite3_bind_text(stmt, 2, msg.channel, -1, self.SQLITE_TRANSIENT),
                    sqlite3_bind_text(stmt, 3, msg.sender, -1, self.SQLITE_TRANSIENT),
                    sqlite3_bind_text(stmt, 4, msg.senderName, -1, self.SQLITE_TRANSIENT),
                    sqlite3_bind_text(stmt, 5, msg.kind, -1, self.SQLITE_TRANSIENT),
                    sqlite3_bind_text(stmt, 6, msg.type, -1, self.SQLITE_TRANSIENT),
                    sqlite3_bind_text(stmt, 7, msg.text, -1, self.SQLITE_TRANSIENT),
                    self.bindTextResult(stmt, index: 8, value: msg.url),
                    self.bindTextResult(stmt, index: 9, value: msg.replyTo),
                    self.bindTextResult(stmt, index: 10, value: msg.replyPreview),
                    sqlite3_bind_double(stmt, 11, msg.ts),
                    self.bindTextResult(stmt, index: 12, value: msg.clientId),
                    self.bindTextResult(stmt, index: 13, value: metaString),
                    self.bindTextResult(stmt, index: 14, value: msg.recalledText),
                    self.bindTextResult(stmt, index: 15, value: attachmentsString),
                ]
            })
    }

    /// 全量同步按页事务写入，避免每条消息单独提交 WAL。
    @discardableResult
    func insertMessages(_ messages: [ChatMessage]) -> Int {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        guard !messages.isEmpty, execute(sql: "BEGIN IMMEDIATE TRANSACTION;") else { return 0 }
        var transactionOpen = true
        defer {
            if transactionOpen { rollbackOrInvalidate(context: "batch message write") }
        }

        for message in messages {
            guard insertMessageLocked(message) else { return 0 }
        }
        guard execute(sql: "COMMIT;") else { return 0 }
        transactionOpen = false
        return messages.count
    }

    func oldestMessageTimestamp(channel: String) -> Double? {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT MIN(ts) FROM messages WHERE channel = ?;", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, channel, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, 0)
    }

    @discardableResult
    func deleteMessages(channel: String? = nil) -> Bool {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        let deleted: Bool
        if let channel {
            guard ChatChannel(rawValue: channel) != nil else { return false }
            deleted = performPreparedWrite(
                sql: "DELETE FROM messages WHERE channel = ?;",
                operation: "delete messages by channel",
                bindings: { [sqlite3_bind_text($0, 1, channel, -1, self.SQLITE_TRANSIENT)] })
        } else {
            deleted = execute(sql: "DELETE FROM messages;")
        }
        guard deleted else { return false }
        return execute(sql: "PRAGMA wal_checkpoint(PASSIVE);")
    }
    
    @discardableResult
    func deleteMessage(id: String, channel: String) -> Bool {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        guard ChatChannel(rawValue: channel) != nil else { return false }
        guard execute(sql: "BEGIN IMMEDIATE TRANSACTION;") else { return false }
        var transactionOpen = true
        defer {
            if transactionOpen { rollbackOrInvalidate(context: "delete message id=\(id)") }
        }
        guard performPreparedWrite(
            sql: "UPDATE messages SET replyTo = NULL, replyPreview = NULL WHERE replyTo = ? AND channel = ?;",
            operation: "repair replies before deleting message",
            bindings: {
                [
                    sqlite3_bind_text($0, 1, id, -1, self.SQLITE_TRANSIENT),
                    sqlite3_bind_text($0, 2, channel, -1, self.SQLITE_TRANSIENT),
                ]
            }),
              performPreparedWrite(
                sql: "DELETE FROM messages WHERE id = ? AND channel = ?;",
                operation: "delete message",
                bindings: {
                    [
                        sqlite3_bind_text($0, 1, id, -1, self.SQLITE_TRANSIENT),
                        sqlite3_bind_text($0, 2, channel, -1, self.SQLITE_TRANSIENT),
                    ]
                }),
              execute(sql: "COMMIT;") else { return false }
        transactionOpen = false
        return true
    }

    func fetchMessage(id: String, channel: String) -> ChatMessage? {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        guard ChatChannel(rawValue: channel) != nil else { return nil }
        let sql = """
        SELECT id, channel, sender, senderName, kind, type, text, url, replyTo, replyPreview, ts, clientId, metaJson, recalledText, attachmentsJson
        FROM messages
        WHERE id = ? AND channel = ?
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, channel, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return parseMessageRow(stmt)
    }
    
    func fetchMessages(
        channel: String,
        beforeTimestamp: Double,
        beforeId: String? = nil,
        limit: Int
    ) -> [ChatMessage] {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        var messages: [ChatMessage] = []
        let useComposite = !(beforeId ?? "").isEmpty
        let sql = useComposite
            ? """
            SELECT id, channel, sender, senderName, kind, type, text, url, replyTo, replyPreview, ts, clientId, metaJson, recalledText, attachmentsJson
            FROM messages
            WHERE channel = ? AND (ts < ? OR (ts = ? AND id < ?))
            ORDER BY ts DESC, id DESC
            LIMIT ?;
            """
            : """
            SELECT id, channel, sender, senderName, kind, type, text, url, replyTo, replyPreview, ts, clientId, metaJson, recalledText, attachmentsJson
            FROM messages
            WHERE channel = ? AND ts < ?
            ORDER BY ts DESC, id DESC
            LIMIT ?;
            """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        
        sqlite3_bind_text(stmt, 1, channel, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, beforeTimestamp)
        if useComposite {
            sqlite3_bind_double(stmt, 3, beforeTimestamp)
            sqlite3_bind_text(stmt, 4, beforeId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 5, Int32(limit))
        } else {
            sqlite3_bind_int(stmt, 3, Int32(limit))
        }
        
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
        databaseLock.lock()
        defer { databaseLock.unlock() }
        var messages: [ChatMessage] = []
        let sql = """
        SELECT id, channel, sender, senderName, kind, type, text, url, replyTo, replyPreview, ts, clientId, metaJson, recalledText, attachmentsJson
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
        databaseLock.lock()
        defer { databaseLock.unlock() }
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
        databaseLock.lock()
        defer { databaseLock.unlock() }
        var messages: [ChatMessage] = []
        let limitClause = limit == nil ? "" : "LIMIT ?"
        let sql = """
        SELECT id, channel, sender, senderName, kind, type, text, url, replyTo, replyPreview, ts, clientId, metaJson, recalledText, attachmentsJson
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
        databaseLock.lock()
        defer { databaseLock.unlock() }
        guard !types.isEmpty else { return [] }
        var messages: [ChatMessage] = []
        let placeholders = types.map { _ in "?" }.joined(separator: ",")
        let limitClause = limit == nil ? "" : "LIMIT ?"
        let sql = """
        SELECT id, channel, sender, senderName, kind, type, text, url, replyTo, replyPreview, ts, clientId, metaJson, recalledText, attachmentsJson
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
        databaseLock.lock()
        defer { databaseLock.unlock() }
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
        databaseLock.lock()
        defer { databaseLock.unlock() }
        return groupedCounts(channel: channel, format: "%Y-%m-%d")
    }

    // MARK: - Durable Outbox

    @discardableResult
    func upsertPendingOutbound(_ item: PendingOutboundMessage) -> Bool {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        guard ChatChannel(rawValue: item.channel) != nil else {
            print("[ChatLocalDatabase] ⚠️ 拒绝写入未知频道待发消息 clientId=\(item.clientId)")
            return false
        }
        let attachmentsJSON: String
        do {
            let data = try JSONEncoder().encode(item.attachments)
            guard let value = String(data: data, encoding: .utf8) else { return false }
            attachmentsJSON = value
        } catch {
            print("[ChatLocalDatabase] ⚠️ 待发消息附件编码失败 clientId=\(item.clientId)")
            return false
        }
        let sql = """
        INSERT OR REPLACE INTO pending_outbound_messages
        (clientId, channel, type, text, replyTo, replyPreview, localFilePath, mimeType,
         uploadId, uploadURL, createdAt, attempts, lastError, metaJson, attachmentsJson)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        return performPreparedWrite(
            sql: sql,
            operation: "upsert pending outbound",
            bindings: { stmt in
                [
                    sqlite3_bind_text(stmt, 1, item.clientId, -1, self.SQLITE_TRANSIENT),
                    sqlite3_bind_text(stmt, 2, item.channel, -1, self.SQLITE_TRANSIENT),
                    sqlite3_bind_text(stmt, 3, item.type, -1, self.SQLITE_TRANSIENT),
                    sqlite3_bind_text(stmt, 4, item.text, -1, self.SQLITE_TRANSIENT),
                    self.bindTextResult(stmt, index: 5, value: item.replyTo),
                    self.bindTextResult(stmt, index: 6, value: item.replyPreview),
                    self.bindTextResult(stmt, index: 7, value: item.localFilePath),
                    self.bindTextResult(stmt, index: 8, value: item.mimeType),
                    self.bindTextResult(stmt, index: 9, value: item.uploadId),
                    self.bindTextResult(stmt, index: 10, value: item.uploadURL),
                    sqlite3_bind_double(stmt, 11, item.createdAt),
                    sqlite3_bind_int(stmt, 12, Int32(item.attempts)),
                    self.bindTextResult(stmt, index: 13, value: item.lastError),
                    self.bindTextResult(stmt, index: 14, value: item.metaJSON),
                    self.bindTextResult(stmt, index: 15, value: attachmentsJSON),
                ]
            })
    }

    func pendingOutbound(clientId: String) -> PendingOutboundMessage? {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        let sql = """
        SELECT clientId, channel, type, text, replyTo, replyPreview, localFilePath, mimeType,
               uploadId, uploadURL, createdAt, attempts, lastError, metaJson, attachmentsJson
        FROM pending_outbound_messages WHERE clientId = ? LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, clientId, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return parsePendingOutboundRow(stmt)
    }

    func loadPendingOutbounds() -> [PendingOutboundMessage] {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        let sql = """
        SELECT clientId, channel, type, text, replyTo, replyPreview, localFilePath, mimeType,
               uploadId, uploadURL, createdAt, attempts, lastError, metaJson, attachmentsJson
        FROM pending_outbound_messages ORDER BY createdAt ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var items: [PendingOutboundMessage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let item = parsePendingOutboundRow(stmt) { items.append(item) }
        }
        return items
    }

    @discardableResult
    func deletePendingOutbound(clientId: String) -> Bool {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        return performPreparedWrite(
            sql: "DELETE FROM pending_outbound_messages WHERE clientId = ?;",
            operation: "delete pending outbound",
            bindings: { [sqlite3_bind_text($0, 1, clientId, -1, self.SQLITE_TRANSIENT)] })
    }

    private func parsePendingOutboundRow(_ stmt: OpaquePointer?) -> PendingOutboundMessage? {
        guard let clientId = readText(stmt, index: 0),
              let channel = readText(stmt, index: 1),
              let type = readText(stmt, index: 2),
              let text = readText(stmt, index: 3) else { return nil }
        return PendingOutboundMessage(
            clientId: clientId,
            channel: channel,
            type: type,
            text: text,
            replyTo: readText(stmt, index: 4),
            replyPreview: readText(stmt, index: 5),
            localFilePath: readText(stmt, index: 6),
            mimeType: readText(stmt, index: 7),
            uploadId: readText(stmt, index: 8),
            uploadURL: readText(stmt, index: 9),
            createdAt: sqlite3_column_double(stmt, 10),
            attempts: Int(sqlite3_column_int(stmt, 11)),
            lastError: readText(stmt, index: 12),
            metaJSON: readText(stmt, index: 13),
            attachments: readText(stmt, index: 14).flatMap { raw in
                raw.data(using: .utf8).flatMap { try? JSONDecoder().decode([PendingOutboundAttachment].self, from: $0) }
            } ?? [])
    }

    func monthCounts(channel: String) -> [(date: String, sender: String, count: Int)] {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        return groupedCounts(channel: channel, format: "%Y-%m")
    }

    func fetchLatestMessages(channel: String, limit: Int) -> [ChatMessage] {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        var messages: [ChatMessage] = []
        let sql = """
        SELECT id, channel, sender, senderName, kind, type, text, url, replyTo, replyPreview, ts, clientId, metaJson, recalledText, attachmentsJson
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
        SELECT id, channel, sender, senderName, kind, type, text, url, replyTo, replyPreview, ts, clientId, metaJson, recalledText, attachmentsJson
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
        SELECT id, channel, sender, senderName, kind, type, text, url, replyTo, replyPreview, ts, clientId, metaJson, recalledText, attachmentsJson
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
    
    func metaValue(forKey key: String) -> String? {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        guard db != nil else { return nil }
        let sql = "SELECT value FROM app_meta WHERE key = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return readText(stmt, index: 0)
    }

    @discardableResult
    func setMetaValue(_ value: String, forKey key: String) -> Bool {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        guard db != nil else { return false }
        let sql = """
        INSERT INTO app_meta(key, value) VALUES(?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    func searchMessages(query: String, channel: String) -> [ChatMessage] {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        var messages: [ChatMessage] = []
        let sql = """
        SELECT id, channel, sender, senderName, kind, type, text, url, replyTo, replyPreview, ts, clientId, metaJson, recalledText, attachmentsJson
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
    
    @discardableResult
    func saveReadReceipt(channel: String, username: String, ts: Double, updatedAt: Double) -> Bool {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        guard ChatChannel(rawValue: channel) != nil else { return false }
        let sql = """
        INSERT OR REPLACE INTO read_receipts (channel, username, ts, updatedAt)
        VALUES (?, ?, ?, ?);
        """
        return performPreparedWrite(
            sql: sql,
            operation: "save read receipt",
            bindings: { stmt in
                [
                    sqlite3_bind_text(stmt, 1, channel, -1, self.SQLITE_TRANSIENT),
                    sqlite3_bind_text(stmt, 2, username, -1, self.SQLITE_TRANSIENT),
                    sqlite3_bind_double(stmt, 3, ts),
                    sqlite3_bind_double(stmt, 4, updatedAt),
                ]
            })
    }
    
    func loadReadReceipts(channel: String) -> [String: Double] {
        databaseLock.lock()
        defer { databaseLock.unlock() }
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
    
    @discardableResult
    func saveSharedState(key: String, valueJson: String, updatedBy: String, updatedAt: Double) -> Bool {
        databaseLock.lock()
        defer { databaseLock.unlock() }
        let sql = """
        INSERT OR REPLACE INTO shared_state (key, valueJson, updatedBy, updatedAt)
        VALUES (?, ?, ?, ?);
        """
        return performPreparedWrite(
            sql: sql,
            operation: "save shared state",
            bindings: { stmt in
                [
                    sqlite3_bind_text(stmt, 1, key, -1, self.SQLITE_TRANSIENT),
                    sqlite3_bind_text(stmt, 2, valueJson, -1, self.SQLITE_TRANSIENT),
                    sqlite3_bind_text(stmt, 3, updatedBy, -1, self.SQLITE_TRANSIENT),
                    sqlite3_bind_double(stmt, 4, updatedAt),
                ]
            })
    }
    
    func loadSharedState() -> [String: Any] {
        databaseLock.lock()
        defer { databaseLock.unlock() }
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

    private func logSQLiteFailure(operation: String, code: Int32) {
        let detail = db.map { String(cString: sqlite3_errmsg($0)) } ?? "database is closed"
        let extendedCode = db.map { sqlite3_extended_errcode($0) } ?? code
        print("[ChatLocalDatabase] ⚠️ \(operation) failed code=\(code) extended=\(extendedCode): \(detail)")
    }

    private func rollbackOrInvalidate(context: String) {
        let rolledBack = execute(sql: "ROLLBACK;")
        let returnedToAutocommit = db.map { sqlite3_get_autocommit($0) != 0 } ?? false
        guard rolledBack, returnedToAutocommit else {
            print("[ChatLocalDatabase] ⚠️ \(context) 回滚后连接状态不可信，关闭本地数据库")
            invalidateConnection()
            return
        }
    }

    private func invalidateConnection() {
        guard let handle = db else {
            currentDatabaseURL = nil
            return
        }
        let closeResult = sqlite3_close_v2(handle)
        if closeResult != SQLITE_OK {
            logSQLiteFailure(operation: "invalidate database connection", code: closeResult)
        }
        db = nil
        currentDatabaseURL = nil
    }

    private func bindTextResult(
        _ stmt: OpaquePointer?,
        index: Int32,
        value: String?
    ) -> Int32 {
        if let value {
            return sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        }
        return sqlite3_bind_null(stmt, index)
    }

    private func performPreparedWrite(
        sql: String,
        operation: String,
        bindings: (OpaquePointer?) -> [Int32]
    ) -> Bool {
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK, stmt != nil else {
            logSQLiteFailure(operation: "prepare \(operation)", code: prepareResult)
            if let stmt {
                let finalizeResult = sqlite3_finalize(stmt)
                if finalizeResult != SQLITE_OK {
                    logSQLiteFailure(operation: "finalize failed \(operation) preparation", code: finalizeResult)
                }
            }
            return false
        }

        if let bindFailure = bindings(stmt).first(where: { $0 != SQLITE_OK }) {
            logSQLiteFailure(operation: "bind \(operation)", code: bindFailure)
            let finalizeResult = sqlite3_finalize(stmt)
            if finalizeResult != SQLITE_OK {
                logSQLiteFailure(operation: "finalize \(operation) after bind failure", code: finalizeResult)
            }
            return false
        }

        let stepResult = sqlite3_step(stmt)
        if stepResult != SQLITE_DONE {
            logSQLiteFailure(operation: "step \(operation)", code: stepResult)
        }
        let finalizeResult = sqlite3_finalize(stmt)
        if finalizeResult != SQLITE_OK, finalizeResult != stepResult {
            logSQLiteFailure(operation: "finalize \(operation)", code: finalizeResult)
        }
        return stepResult == SQLITE_DONE && finalizeResult == SQLITE_OK
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
        let recalledText = readText(stmt, index: 13)
        let attachmentsJson = readText(stmt, index: 14)
        
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
        if let recalledText = recalledText { dict["recalledText"] = recalledText }
        if let attachmentsJson,
           let data = attachmentsJson.data(using: .utf8),
           let attachments = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            dict["attachments"] = attachments
        }
        
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
