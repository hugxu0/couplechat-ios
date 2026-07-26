import Foundation

struct ChatPersistenceScope: Hashable, Sendable {
    let username: String
    fileprivate let id: UUID

    fileprivate init(username: String) {
        self.username = username
        id = UUID()
    }
}

/// 所有读写都必须带 scope。不带 scope 的重载曾经与每个方法成对存在，但没有任何
/// 调用方使用，而且它们不做 isActive 检查——退出或切换账号后的旧任务可以经由它们
/// 写进新账号的库。删掉这一半既减少一半接口面，也消掉那个隐患。
protocol ChatPersistenceProtocol: Actor {
    func openScoped(username: String) -> ChatPersistenceScope?
    func close(scope: ChatPersistenceScope)
    func isActive(scope: ChatPersistenceScope) -> Bool
    func databaseSizeBytes(scope: ChatPersistenceScope) -> Int64?
    func messageCount(channel: String, scope: ChatPersistenceScope) -> Int?
    func mediaURLs(
        channel: String,
        types: [String],
        scope: ChatPersistenceScope
    ) -> [String]?
    @discardableResult
    func insertMessage(_ message: ChatMessage, scope: ChatPersistenceScope) -> Bool
    func insertMessages(_ messages: [ChatMessage], scope: ChatPersistenceScope) -> Int?
    @discardableResult
    func deleteMessages(channel: String?, scope: ChatPersistenceScope) -> Bool
    @discardableResult
    func deleteMessage(id: String, channel: String, scope: ChatPersistenceScope) -> Bool
    func fetchMessage(id: String, channel: String, scope: ChatPersistenceScope) -> ChatMessage?
    func fetchMessages(
        channel: String,
        beforeTimestamp: Double,
        beforeId: String?,
        limit: Int,
        scope: ChatPersistenceScope
    ) -> [ChatMessage]?
    func fetchMessagesAfter(
        channel: String,
        afterTimestamp: Double,
        afterId: String,
        limit: Int,
        scope: ChatPersistenceScope
    ) -> [ChatMessage]?
    func fetchMessages(
        channel: String,
        fromTimestamp: Double,
        toTimestamp: Double,
        scope: ChatPersistenceScope
    ) -> [ChatMessage]?
    func fetchMessagesAround(
        channel: String,
        centerTimestamp: Double,
        beforeLimit: Int,
        afterLimit: Int,
        scope: ChatPersistenceScope
    ) -> [ChatMessage]?
    func fetchMessages(
        channel: String,
        fromInclusive: Double,
        toExclusive: Double,
        limit: Int?,
        scope: ChatPersistenceScope
    ) -> [ChatMessage]?
    func mediaMessages(
        channel: String,
        types: [String],
        limit: Int?,
        scope: ChatPersistenceScope
    ) -> [ChatMessage]?
    func mediaCount(channel: String, types: [String], scope: ChatPersistenceScope) -> Int?
    func dayCounts(
        channel: String,
        scope: ChatPersistenceScope
    ) -> [(date: String, sender: String, count: Int)]?
    func monthCounts(
        channel: String,
        scope: ChatPersistenceScope
    ) -> [(date: String, sender: String, count: Int)]?
    func upsertPendingOutbound(_ item: PendingOutboundMessage, scope: ChatPersistenceScope) -> Bool
    func updatePendingOutbound(_ item: PendingOutboundMessage, scope: ChatPersistenceScope) -> Bool
    func pendingOutbound(clientId: String, scope: ChatPersistenceScope) -> PendingOutboundMessage?
    func loadPendingOutbounds(scope: ChatPersistenceScope) -> [PendingOutboundMessage]?
    @discardableResult
    func deletePendingOutbound(clientId: String, scope: ChatPersistenceScope) -> Bool
    func fetchLatestMessages(
        channel: String,
        limit: Int,
        scope: ChatPersistenceScope
    ) -> [ChatMessage]?
    func searchMessages(
        query: String,
        channel: String,
        scope: ChatPersistenceScope
    ) -> [ChatMessage]?
    @discardableResult
    func saveReadReceipt(
        channel: String,
        username: String,
        ts: Double,
        updatedAt: Double,
        scope: ChatPersistenceScope
    ) -> Bool
    func loadReadReceipts(channel: String, scope: ChatPersistenceScope) -> [String: Double]?
    @discardableResult
    func saveSharedState(
        key: String,
        valueJson: String,
        updatedBy: String,
        updatedAt: Double,
        scope: ChatPersistenceScope
    ) -> Bool
    func loadSharedState(scope: ChatPersistenceScope) -> [String: Any]?
    func metaValue(forKey key: String, scope: ChatPersistenceScope) -> String?
    @discardableResult
    func setMetaValue(_ value: String, forKey key: String, scope: ChatPersistenceScope) -> Bool
}

/// The only production owner of the SQLite connection. UI-facing stores await this
/// actor instead of running database work on the main actor.
actor ChatPersistence: ChatPersistenceProtocol {
    static let shared = ChatPersistence()

    private let database = ChatLocalDatabase.shared
    private var activeScope: ChatPersistenceScope?

    func openScoped(username: String) -> ChatPersistenceScope? { openDatabase(username: username) }
    func close(scope: ChatPersistenceScope) {
        guard isActive(scope: scope) else { return }
        activeScope = nil
        database.close()
    }
    func isActive(scope: ChatPersistenceScope) -> Bool { activeScope == scope }
    func databaseSizeBytes(scope: ChatPersistenceScope) -> Int64? {
        guard isActive(scope: scope) else { return nil }
        return database.databaseSizeBytes()
    }
    func messageCount(channel: String, scope: ChatPersistenceScope) -> Int? {
        guard isActive(scope: scope) else { return nil }
        return database.messageCount(channel: channel)
    }
    func mediaURLs(
        channel: String,
        types: [String],
        scope: ChatPersistenceScope
    ) -> [String]? {
        guard isActive(scope: scope) else { return nil }
        return database.mediaURLs(channel: channel, types: types)
    }
    @discardableResult
    func insertMessage(_ message: ChatMessage, scope: ChatPersistenceScope) -> Bool {
        guard isActive(scope: scope) else { return false }
        return database.insertMessage(message)
    }
    func insertMessages(_ messages: [ChatMessage], scope: ChatPersistenceScope) -> Int? {
        guard isActive(scope: scope) else { return nil }
        return database.insertMessages(messages)
    }
    @discardableResult
    func deleteMessages(channel: String?, scope: ChatPersistenceScope) -> Bool {
        guard isActive(scope: scope) else { return false }
        return database.deleteMessages(channel: channel)
    }
    @discardableResult
    func deleteMessage(id: String, channel: String, scope: ChatPersistenceScope) -> Bool {
        guard isActive(scope: scope) else { return false }
        return database.deleteMessage(id: id, channel: channel)
    }
    func fetchMessage(id: String, channel: String, scope: ChatPersistenceScope) -> ChatMessage? {
        guard isActive(scope: scope) else { return nil }
        return database.fetchMessage(id: id, channel: channel)
    }
    func fetchMessages(
        channel: String,
        beforeTimestamp: Double,
        beforeId: String?,
        limit: Int,
        scope: ChatPersistenceScope
    ) -> [ChatMessage]? {
        guard isActive(scope: scope) else { return nil }
        return database.fetchMessages(
            channel: channel,
            beforeTimestamp: beforeTimestamp,
            beforeId: beforeId,
            limit: limit)
    }
    func fetchMessagesAfter(
        channel: String,
        afterTimestamp: Double,
        afterId: String,
        limit: Int,
        scope: ChatPersistenceScope
    ) -> [ChatMessage]? {
        guard isActive(scope: scope) else { return nil }
        return database.fetchMessagesAfter(
            channel: channel,
            afterTimestamp: afterTimestamp,
            afterId: afterId,
            limit: limit)
    }
    func fetchMessages(
        channel: String,
        fromTimestamp: Double,
        toTimestamp: Double,
        scope: ChatPersistenceScope
    ) -> [ChatMessage]? {
        guard isActive(scope: scope) else { return nil }
        return database.fetchMessages(
            channel: channel,
            fromTimestamp: fromTimestamp,
            toTimestamp: toTimestamp)
    }
    func fetchMessagesAround(
        channel: String,
        centerTimestamp: Double,
        beforeLimit: Int,
        afterLimit: Int,
        scope: ChatPersistenceScope
    ) -> [ChatMessage]? {
        guard isActive(scope: scope) else { return nil }
        return database.fetchMessagesAround(
            channel: channel,
            centerTimestamp: centerTimestamp,
            beforeLimit: beforeLimit,
            afterLimit: afterLimit)
    }
    func fetchMessages(
        channel: String,
        fromInclusive: Double,
        toExclusive: Double,
        limit: Int?,
        scope: ChatPersistenceScope
    ) -> [ChatMessage]? {
        guard isActive(scope: scope) else { return nil }
        return database.fetchMessages(
            channel: channel,
            fromInclusive: fromInclusive,
            toExclusive: toExclusive,
            limit: limit)
    }
    func mediaMessages(
        channel: String,
        types: [String],
        limit: Int?,
        scope: ChatPersistenceScope
    ) -> [ChatMessage]? {
        guard isActive(scope: scope) else { return nil }
        return database.mediaMessages(channel: channel, types: types, limit: limit)
    }
    func mediaCount(channel: String, types: [String], scope: ChatPersistenceScope) -> Int? {
        guard isActive(scope: scope) else { return nil }
        return database.mediaCount(channel: channel, types: types)
    }
    func dayCounts(
        channel: String,
        scope: ChatPersistenceScope
    ) -> [(date: String, sender: String, count: Int)]? {
        guard isActive(scope: scope) else { return nil }
        return database.dayCounts(channel: channel)
    }
    func monthCounts(
        channel: String,
        scope: ChatPersistenceScope
    ) -> [(date: String, sender: String, count: Int)]? {
        guard isActive(scope: scope) else { return nil }
        return database.monthCounts(channel: channel)
    }
    func upsertPendingOutbound(_ item: PendingOutboundMessage, scope: ChatPersistenceScope) -> Bool {
        guard isActive(scope: scope) else { return false }
        return database.upsertPendingOutbound(item)
    }
    func updatePendingOutbound(_ item: PendingOutboundMessage, scope: ChatPersistenceScope) -> Bool {
        guard isActive(scope: scope) else { return false }
        return database.updatePendingOutbound(item)
    }
    func pendingOutbound(clientId: String, scope: ChatPersistenceScope) -> PendingOutboundMessage? {
        guard isActive(scope: scope) else { return nil }
        return database.pendingOutbound(clientId: clientId)
    }
    func loadPendingOutbounds(scope: ChatPersistenceScope) -> [PendingOutboundMessage]? {
        guard isActive(scope: scope) else { return nil }
        return database.loadPendingOutbounds()
    }
    @discardableResult
    func deletePendingOutbound(clientId: String, scope: ChatPersistenceScope) -> Bool {
        guard isActive(scope: scope) else { return false }
        return database.deletePendingOutbound(clientId: clientId)
    }
    func fetchLatestMessages(
        channel: String,
        limit: Int,
        scope: ChatPersistenceScope
    ) -> [ChatMessage]? {
        guard isActive(scope: scope) else { return nil }
        return database.fetchLatestMessages(channel: channel, limit: limit)
    }
    func searchMessages(
        query: String,
        channel: String,
        scope: ChatPersistenceScope
    ) -> [ChatMessage]? {
        guard isActive(scope: scope) else { return nil }
        return database.searchMessages(query: query, channel: channel)
    }
    @discardableResult
    func saveReadReceipt(
        channel: String,
        username: String,
        ts: Double,
        updatedAt: Double,
        scope: ChatPersistenceScope
    ) -> Bool {
        guard isActive(scope: scope) else { return false }
        return database.saveReadReceipt(
            channel: channel,
            username: username,
            ts: ts,
            updatedAt: updatedAt)
    }
    func loadReadReceipts(
        channel: String,
        scope: ChatPersistenceScope
    ) -> [String: Double]? {
        guard isActive(scope: scope) else { return nil }
        return database.loadReadReceipts(channel: channel)
    }
    @discardableResult
    func saveSharedState(
        key: String,
        valueJson: String,
        updatedBy: String,
        updatedAt: Double,
        scope: ChatPersistenceScope
    ) -> Bool {
        guard isActive(scope: scope) else { return false }
        return database.saveSharedState(
            key: key,
            valueJson: valueJson,
            updatedBy: updatedBy,
            updatedAt: updatedAt)
    }
    func loadSharedState(scope: ChatPersistenceScope) -> [String: Any]? {
        guard isActive(scope: scope) else { return nil }
        return database.loadSharedState()
    }
    func metaValue(forKey key: String, scope: ChatPersistenceScope) -> String? {
        guard isActive(scope: scope) else { return nil }
        return database.metaValue(forKey: key)
    }
    @discardableResult
    func setMetaValue(
        _ value: String,
        forKey key: String,
        scope: ChatPersistenceScope
    ) -> Bool {
        guard isActive(scope: scope) else { return false }
        return database.setMetaValue(value, forKey: key)
    }

    private func openDatabase(username: String) -> ChatPersistenceScope? {
        let scope = ChatPersistenceScope(username: username)
        guard database.open(username: username) else {
            activeScope = nil
            return nil
        }
        activeScope = scope
        return scope
    }
}
