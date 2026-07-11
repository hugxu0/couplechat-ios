import Foundation
import XCTest
@testable import CoupleChat

final class ChatPersistenceTests: XCTestCase {
    private let persistence = ChatPersistence.shared
    private var databaseURLs: [URL] = []

    override func tearDown() async throws {
        await persistence.close()
        for url in databaseURLs {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
        }
        databaseURLs = []
    }

    func testConcurrentWritesAccountSwitchAndClearAreSerialized() async {
        let first = "persistence-a-\(UUID().uuidString)"
        let second = "persistence-b-\(UUID().uuidString)"
        let openedFirst = await persistence.open(username: first)
        XCTAssertTrue(openedFirst)
        if let url = await persistence.currentDatabaseURL() { databaseURLs.append(url) }

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask { [persistence] in
                    await persistence.insertMessage(Self.message(index: index))
                }
            }
        }

        let firstCount = await persistence.messageCount(channel: "couple")
        let latestCount = await persistence.fetchLatestMessages(channel: "couple", limit: 50).count
        XCTAssertEqual(firstCount, 40)
        XCTAssertEqual(latestCount, 40)

        let openedSecond = await persistence.open(username: second)
        XCTAssertTrue(openedSecond)
        if let url = await persistence.currentDatabaseURL() { databaseURLs.append(url) }
        let secondCount = await persistence.messageCount(channel: "couple")
        XCTAssertEqual(secondCount, 0)

        let reopenedFirst = await persistence.open(username: first)
        let restoredCount = await persistence.messageCount(channel: "couple")
        XCTAssertTrue(reopenedFirst)
        XCTAssertEqual(restoredCount, 40)
        await persistence.deleteMessages(channel: nil)
        await persistence.deleteMessages(channel: nil)
        let clearedCount = await persistence.messageCount(channel: "couple")
        XCTAssertEqual(clearedCount, 0)
    }

    private static func message(index: Int) -> ChatMessage {
        ChatMessage(dict: [
            "id": "persistence-\(index)",
            "sender": index.isMultiple(of: 2) ? "xu" : "si",
            "senderName": index.isMultiple(of: 2) ? "小旭" : "小偲",
            "kind": "user",
            "type": "text",
            "text": "message-\(index)",
            "channel": "couple",
            "ts": Double(index),
        ])!
    }
}
