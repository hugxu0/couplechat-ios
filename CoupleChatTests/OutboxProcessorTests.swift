import XCTest
@testable import CoupleChat

@MainActor
final class OutboxProcessorReplayTests: XCTestCase {
    func testReplayProcessesPendingItemsInOrder() async {
        let persistence = InMemoryChatPersistence()
        await persistence.seed([
            makeItem(clientId: "first", createdAt: 1),
            makeItem(clientId: "second", createdAt: 2),
        ])
        let processor = OutboxProcessor(persistence: persistence)
        var sent: [String] = []

        await processor.replay(
            isConnected: { true },
            send: { item in
                sent.append(item.clientId)
                return true
            })

        XCTAssertEqual(sent, ["first", "second"])
    }

    func testConcurrentReplayRequestsRunAfterCurrentPass() async {
        let persistence = InMemoryChatPersistence()
        await persistence.seed([makeItem(clientId: "first", createdAt: 1)])
        let processor = OutboxProcessor(persistence: persistence)
        var sent: [String] = []
        var requestedSecondPass = false

        await processor.replay(
            isConnected: { true },
            send: { item in
                sent.append(item.clientId)
                if !requestedSecondPass {
                    requestedSecondPass = true
                    Task {
                        await processor.replay(isConnected: { true }, send: { _ in true })
                    }
                    await Task.yield()
                }
                return true
            })

        XCTAssertGreaterThanOrEqual(sent.count, 1)
        XCTAssertEqual(sent.first, "first")
    }

    private func makeItem(clientId: String, createdAt: Double) -> PendingOutboundMessage {
        PendingOutboundMessage(
            clientId: clientId,
            channel: "couple",
            type: "text",
            text: clientId,
            replyTo: nil,
            replyPreview: nil,
            localFilePath: nil,
            mimeType: nil,
            uploadId: nil,
            uploadURL: nil,
            createdAt: createdAt,
            attempts: 0,
            lastError: nil)
    }
}

private actor InMemoryChatPersistence: ChatPersistenceProtocol {
    private var pendingItems: [PendingOutboundMessage] = []

    func seed(_ items: [PendingOutboundMessage]) {
        pendingItems = items.sorted { $0.createdAt < $1.createdAt }
    }

    func open(username: String) -> Bool { true }
    func close() {}
    func currentDatabaseURL() -> URL? { nil }
    func databaseSizeBytes() -> Int64 { 0 }
    func messageCount(channel: String) -> Int { 0 }
    func mediaURLs(channel: String, types: [String]) -> [String] { [] }
    func insertMessage(_ message: ChatMessage) -> Bool { true }
    func insertMessages(_ messages: [ChatMessage]) -> Int { messages.count }
    func oldestMessageTimestamp(channel: String) -> Double? { nil }
    func deleteMessages(channel: String?) -> Bool { true }
    func deleteMessage(id: String, channel: String) -> Bool { true }
    func fetchMessages(channel: String, beforeTimestamp: Double, limit: Int) -> [ChatMessage] { [] }
    func fetchMessages(channel: String, fromTimestamp: Double, toTimestamp: Double) -> [ChatMessage] { [] }
    func fetchMessagesAround(channel: String, centerTimestamp: Double, beforeLimit: Int, afterLimit: Int) -> [ChatMessage] { [] }
    func fetchMessages(channel: String, fromInclusive: Double, toExclusive: Double, limit: Int?) -> [ChatMessage] { [] }
    func mediaMessages(channel: String, types: [String], limit: Int?) -> [ChatMessage] { [] }
    func mediaCount(channel: String, types: [String]) -> Int { 0 }
    func dayCounts(channel: String) -> [(date: String, sender: String, count: Int)] { [] }
    func monthCounts(channel: String) -> [(date: String, sender: String, count: Int)] { [] }
    func upsertPendingOutbound(_ item: PendingOutboundMessage) -> Bool {
        pendingItems.removeAll { $0.clientId == item.clientId }
        pendingItems.append(item)
        pendingItems.sort { $0.createdAt < $1.createdAt }
        return true
    }
    func pendingOutbound(clientId: String) -> PendingOutboundMessage? {
        pendingItems.first { $0.clientId == clientId }
    }
    func loadPendingOutbounds() -> [PendingOutboundMessage] { pendingItems }
    func deletePendingOutbound(clientId: String) -> Bool {
        pendingItems.removeAll { $0.clientId == clientId }
        return true
    }
    func fetchLatestMessages(channel: String, limit: Int) -> [ChatMessage] { [] }
    func searchMessages(query: String, channel: String) -> [ChatMessage] { [] }
    func saveReadReceipt(channel: String, username: String, ts: Double, updatedAt: Double) -> Bool { true }
    func loadReadReceipts(channel: String) -> [String: Double] { [:] }
    func saveSharedState(key: String, valueJson: String, updatedBy: String, updatedAt: Double) -> Bool { true }
    func loadSharedState() -> [String: Any] { [:] }
}
