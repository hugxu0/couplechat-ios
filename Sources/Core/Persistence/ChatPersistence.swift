import Foundation

protocol ChatPersistenceProtocol: Actor {
    func open(username: String) -> Bool
    func close()
    func currentDatabaseURL() -> URL?
    func databaseSizeBytes() -> Int64
    func messageCount(channel: String) -> Int
    func mediaURLs(channel: String, types: [String]) -> [String]
    func insertMessage(_ message: ChatMessage)
    func insertMessages(_ messages: [ChatMessage]) -> Int
    func oldestMessageTimestamp(channel: String) -> Double?
    func deleteMessages(channel: String?)
    func deleteMessage(id: String)
    func fetchMessages(channel: String, beforeTimestamp: Double, limit: Int) -> [ChatMessage]
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
    func deletePendingOutbound(clientId: String)
    func fetchLatestMessages(channel: String, limit: Int) -> [ChatMessage]
    func searchMessages(query: String, channel: String) -> [ChatMessage]
    func saveReadReceipt(channel: String, username: String, ts: Double, updatedAt: Double)
    func loadReadReceipts(channel: String) -> [String: Double]
    func saveSharedState(key: String, valueJson: String, updatedBy: String, updatedAt: Double)
    func loadSharedState() -> [String: Any]
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
    func insertMessage(_ message: ChatMessage) { database.insertMessage(message) }
    func insertMessages(_ messages: [ChatMessage]) -> Int { database.insertMessages(messages) }
    func oldestMessageTimestamp(channel: String) -> Double? {
        database.oldestMessageTimestamp(channel: channel)
    }
    func deleteMessages(channel: String? = nil) { database.deleteMessages(channel: channel) }
    func deleteMessage(id: String) { database.deleteMessage(id: id) }
    func fetchMessages(channel: String, beforeTimestamp: Double, limit: Int) -> [ChatMessage] {
        database.fetchMessages(channel: channel, beforeTimestamp: beforeTimestamp, limit: limit)
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
    func deletePendingOutbound(clientId: String) {
        database.deletePendingOutbound(clientId: clientId)
    }
    func fetchLatestMessages(channel: String, limit: Int) -> [ChatMessage] {
        database.fetchLatestMessages(channel: channel, limit: limit)
    }
    func searchMessages(query: String, channel: String) -> [ChatMessage] {
        database.searchMessages(query: query, channel: channel)
    }
    func saveReadReceipt(channel: String, username: String, ts: Double, updatedAt: Double) {
        database.saveReadReceipt(channel: channel, username: username, ts: ts, updatedAt: updatedAt)
    }
    func loadReadReceipts(channel: String) -> [String: Double] {
        database.loadReadReceipts(channel: channel)
    }
    func saveSharedState(key: String, valueJson: String, updatedBy: String, updatedAt: Double) {
        database.saveSharedState(key: key, valueJson: valueJson, updatedBy: updatedBy, updatedAt: updatedAt)
    }
    func loadSharedState() -> [String: Any] { database.loadSharedState() }
}
