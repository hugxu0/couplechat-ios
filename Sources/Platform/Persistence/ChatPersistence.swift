import Foundation

protocol ChatPersistenceProtocol: Actor {
    func open(username: String) -> Bool
    func close()
    func currentDatabaseURL() -> URL?
    func databaseSizeBytes() -> Int64
    func messageCount(channel: String) -> Int
    func mediaURLs(channel: String, types: [String]) -> [String]
    @discardableResult
    func insertMessage(_ message: ChatMessage) -> Bool
    func insertMessages(_ messages: [ChatMessage]) -> Int
    func oldestMessageTimestamp(channel: String) -> Double?
    @discardableResult
    func deleteMessages(channel: String?) -> Bool
    @discardableResult
    func deleteMessage(id: String, channel: String) -> Bool
    func fetchMessage(id: String, channel: String) -> ChatMessage?
    func fetchMessages(channel: String, beforeTimestamp: Double, beforeId: String?, limit: Int) -> [ChatMessage]
    func fetchMessages(channel: String, fromTimestamp: Double, toTimestamp: Double) -> [ChatMessage]
    func fetchMessagesAround(
        channel: String,
        centerTimestamp: Double,
        beforeLimit: Int,
        afterLimit: Int
    ) -> [ChatMessage]
    func fetchMessages(
        channel: String,
        fromInclusive: Double,
        toExclusive: Double,
        limit: Int?
    ) -> [ChatMessage]
    func mediaMessages(channel: String, types: [String], limit: Int?) -> [ChatMessage]
    func mediaCount(channel: String, types: [String]) -> Int
    func dayCounts(channel: String) -> [(date: String, sender: String, count: Int)]
    func monthCounts(channel: String) -> [(date: String, sender: String, count: Int)]
    func upsertPendingOutbound(_ item: PendingOutboundMessage) -> Bool
    func pendingOutbound(clientId: String) -> PendingOutboundMessage?
    func loadPendingOutbounds() -> [PendingOutboundMessage]
    @discardableResult
    func deletePendingOutbound(clientId: String) -> Bool
    func fetchLatestMessages(channel: String, limit: Int) -> [ChatMessage]
    func searchMessages(query: String, channel: String) -> [ChatMessage]
    @discardableResult
    func saveReadReceipt(channel: String, username: String, ts: Double, updatedAt: Double) -> Bool
    func loadReadReceipts(channel: String) -> [String: Double]
    @discardableResult
    func saveSharedState(key: String, valueJson: String, updatedBy: String, updatedAt: Double) -> Bool
    func loadSharedState() -> [String: Any]
    func metaValue(forKey key: String) -> String?
    @discardableResult
    func setMetaValue(_ value: String, forKey key: String) -> Bool
}

/// The only production owner of the SQLite connection. UI-facing stores await this
/// actor instead of running database work on the main actor.
actor ChatPersistence: ChatPersistenceProtocol {
    static let shared = ChatPersistence()

    private let database = ChatLocalDatabase.shared

    func open(username: String) -> Bool { database.open(username: username) }
    func close() { database.close() }
    func currentDatabaseURL() -> URL? { database.currentDatabaseURL }
    func databaseSizeBytes() -> Int64 { database.databaseSizeBytes() }
    func messageCount(channel: String) -> Int { database.messageCount(channel: channel) }
    func mediaURLs(channel: String, types: [String]) -> [String] {
        database.mediaURLs(channel: channel, types: types)
    }
    @discardableResult
    func insertMessage(_ message: ChatMessage) -> Bool { database.insertMessage(message) }
    func insertMessages(_ messages: [ChatMessage]) -> Int { database.insertMessages(messages) }
    func oldestMessageTimestamp(channel: String) -> Double? {
        database.oldestMessageTimestamp(channel: channel)
    }
    @discardableResult
    func deleteMessages(channel: String? = nil) -> Bool { database.deleteMessages(channel: channel) }
    @discardableResult
    func deleteMessage(id: String, channel: String) -> Bool {
        database.deleteMessage(id: id, channel: channel)
    }
    func fetchMessage(id: String, channel: String) -> ChatMessage? {
        database.fetchMessage(id: id, channel: channel)
    }
    func fetchMessages(channel: String, beforeTimestamp: Double, beforeId: String?, limit: Int) -> [ChatMessage] {
        database.fetchMessages(channel: channel, beforeTimestamp: beforeTimestamp, beforeId: beforeId, limit: limit)
    }
    func fetchMessages(channel: String, fromTimestamp: Double, toTimestamp: Double) -> [ChatMessage] {
        database.fetchMessages(channel: channel, fromTimestamp: fromTimestamp, toTimestamp: toTimestamp)
    }
    func fetchMessagesAround(
        channel: String,
        centerTimestamp: Double,
        beforeLimit: Int,
        afterLimit: Int
    ) -> [ChatMessage] {
        database.fetchMessagesAround(
            channel: channel,
            centerTimestamp: centerTimestamp,
            beforeLimit: beforeLimit,
            afterLimit: afterLimit)
    }
    func fetchMessages(
        channel: String,
        fromInclusive: Double,
        toExclusive: Double,
        limit: Int? = nil
    ) -> [ChatMessage] {
        database.fetchMessages(
            channel: channel,
            fromInclusive: fromInclusive,
            toExclusive: toExclusive,
            limit: limit)
    }
    func mediaMessages(channel: String, types: [String], limit: Int? = nil) -> [ChatMessage] {
        database.mediaMessages(channel: channel, types: types, limit: limit)
    }
    func mediaCount(channel: String, types: [String]) -> Int {
        database.mediaCount(channel: channel, types: types)
    }
    func dayCounts(channel: String) -> [(date: String, sender: String, count: Int)] {
        database.dayCounts(channel: channel)
    }
    func monthCounts(channel: String) -> [(date: String, sender: String, count: Int)] {
        database.monthCounts(channel: channel)
    }
    func upsertPendingOutbound(_ item: PendingOutboundMessage) -> Bool {
        database.upsertPendingOutbound(item)
    }
    func pendingOutbound(clientId: String) -> PendingOutboundMessage? {
        database.pendingOutbound(clientId: clientId)
    }
    func loadPendingOutbounds() -> [PendingOutboundMessage] { database.loadPendingOutbounds() }
    @discardableResult
    func deletePendingOutbound(clientId: String) -> Bool {
        database.deletePendingOutbound(clientId: clientId)
    }
    func fetchLatestMessages(channel: String, limit: Int) -> [ChatMessage] {
        database.fetchLatestMessages(channel: channel, limit: limit)
    }
    func searchMessages(query: String, channel: String) -> [ChatMessage] {
        database.searchMessages(query: query, channel: channel)
    }
    @discardableResult
    func saveReadReceipt(channel: String, username: String, ts: Double, updatedAt: Double) -> Bool {
        database.saveReadReceipt(channel: channel, username: username, ts: ts, updatedAt: updatedAt)
    }
    func loadReadReceipts(channel: String) -> [String: Double] {
        database.loadReadReceipts(channel: channel)
    }
    @discardableResult
    func saveSharedState(key: String, valueJson: String, updatedBy: String, updatedAt: Double) -> Bool {
        database.saveSharedState(key: key, valueJson: valueJson, updatedBy: updatedBy, updatedAt: updatedAt)
    }
    func loadSharedState() -> [String: Any] { database.loadSharedState() }
    func metaValue(forKey key: String) -> String? { database.metaValue(forKey: key) }
    @discardableResult
    func setMetaValue(_ value: String, forKey key: String) -> Bool {
        database.setMetaValue(value, forKey: key)
    }
}
