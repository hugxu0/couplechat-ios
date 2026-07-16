import Foundation
import SQLite3
import XCTest
@testable import CoupleChat

private actor HistoryPageHTTPClient: HTTPClient {
    let body: Data

    init(body: Data) {
        self.body = body
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

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

    @MainActor
    func testConstraintFailureRollsBackBatchAndDoesNotAdvanceHistoryCursor() async throws {
        let username = "persistence-failure-\(UUID().uuidString)"
        let opened = await persistence.open(username: username)
        XCTAssertTrue(opened)
        let currentDatabaseURL = await persistence.currentDatabaseURL()
        let databaseURL = try XCTUnwrap(currentDatabaseURL)
        databaseURLs.append(databaseURL)

        var triggerDB: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(databaseURL.path, &triggerDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil),
            SQLITE_OK)
        defer { _ = sqlite3_close(triggerDB) }
        var triggerError: UnsafeMutablePointer<Int8>?
        let triggerResult = sqlite3_exec(triggerDB, """
        CREATE TRIGGER fail_selected_message
        BEFORE INSERT ON messages
        WHEN NEW.id = 'forced-constraint-failure'
        BEGIN
          SELECT RAISE(ABORT, 'forced constraint failure');
        END;
        """, nil, nil, &triggerError)
        let triggerErrorText = triggerError.map { String(cString: $0) }
        sqlite3_free(triggerError)
        XCTAssertEqual(triggerResult, SQLITE_OK, triggerErrorText ?? "failed to create test trigger")

        let rows: [[String: Any]] = (0..<300).map { index in
            [
                "id": index == 1 ? "forced-constraint-failure" : "history-\(index)",
                "sender": index.isMultiple(of: 2) ? "xu" : "si",
                "senderName": index.isMultiple(of: 2) ? "小旭" : "小偲",
                "kind": "user",
                "type": "text",
                "text": "message-\(index)",
                "channel": "couple",
                "ts": Double(100 + index),
            ]
        }
        let body = try JSONSerialization.data(withJSONObject: ["list": rows, "total": 1_000])
        let remote = ChatRemoteDataSource(httpClient: HistoryPageHTTPClient(body: body))
        let service = MessageHistorySyncService(persistence: persistence, remoteDataSource: remote)

        let cursorKey = "history.sync.v2.cursor.\(username).couple"
        let countKey = "history.sync.v2.local-count.\(username).couple"
        UserDefaults.standard.set(500.0, forKey: cursorKey)
        UserDefaults.standard.set(0, forKey: countKey)
        defer {
            UserDefaults.standard.removeObject(forKey: cursorKey)
            UserDefaults.standard.removeObject(forKey: countKey)
        }

        let result = await service.sync(
            channel: .couple,
            session: Session(token: "test-token", username: username, name: "Test"),
            onProgress: { _, _ in })

        XCTAssertEqual(result.error, "写入本地数据库失败")
        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.downloaded, 0)
        let persistedCount = await persistence.messageCount(channel: "couple")
        XCTAssertEqual(persistedCount, 0)
        XCTAssertEqual(UserDefaults.standard.object(forKey: cursorKey) as? Double, 500.0)
    }

    func testRecallDeleteIsChannelScopedAndRepairsRepliesInSameTransaction() async throws {
        let username = "persistence-recall-\(UUID().uuidString)"
        let opened = await persistence.open(username: username)
        XCTAssertTrue(opened)
        let currentDatabaseURL = await persistence.currentDatabaseURL()
        databaseURLs.append(try XCTUnwrap(currentDatabaseURL))

        let original = ChatMessage(dict: [
            "id": "original", "sender": "xu", "senderName": "小旭",
            "kind": "user", "type": "text", "text": "original",
            "channel": "couple", "ts": 100,
        ])!
        let reply = ChatMessage(dict: [
            "id": "reply", "sender": "si", "senderName": "小偲",
            "kind": "user", "type": "text", "text": "reply",
            "channel": "couple", "ts": 200,
            "replyTo": "original", "replyPreview": "original",
        ])!
        let inserted = await persistence.insertMessages([original, reply])
        XCTAssertEqual(inserted, 2)

        let wrongChannelDelete = await persistence.deleteMessage(id: original.id, channel: "ai")
        XCTAssertTrue(wrongChannelDelete)
        let countAfterWrongChannel = await persistence.messageCount(channel: "couple")
        XCTAssertEqual(countAfterWrongChannel, 2)

        let deleted = await persistence.deleteMessage(id: original.id, channel: "couple")
        XCTAssertTrue(deleted)
        let remaining = await persistence.fetchLatestMessages(channel: "couple", limit: 10)
        XCTAssertEqual(remaining.map(\.id), ["reply"])
        XCTAssertNil(remaining.first?.replyTo)
        XCTAssertNil(remaining.first?.replyPreview)
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
