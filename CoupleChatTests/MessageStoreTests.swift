import XCTest
@testable import CoupleChat

@MainActor
final class MessageStoreParseTests: XCTestCase {

    // MARK: - parseMessage

    func testParseMessageValid() {
        let dict: [String: Any] = [
            "id": "msg_001", "sender": "xu", "senderName": "小旭",
            "kind": "user", "type": "text", "text": "hello",
            "channel": "couple", "ts": 1710000000000,
        ]
        let msg = MessageStore.parseMessage(dict, context: "test")
        XCTAssertNotNil(msg)
        XCTAssertEqual(msg?.id, "msg_001")
    }

    func testParseMessageMissingId() {
        let dict: [String: Any] = ["sender": "xu", "type": "text"]
        XCTAssertNil(MessageStore.parseMessage(dict))
    }

    func testParseMessageEmptyDict() {
        XCTAssertNil(MessageStore.parseMessage([:]))
    }

    func testParseMessageWithMeta() {
        let dict: [String: Any] = [
            "id": "msg_meta", "sender": "xu", "senderName": "小旭",
            "kind": "user", "type": "text", "text": "hi",
            "channel": "couple", "ts": 1710000000000,
            "meta": ["confirm": ["status": "pending", "items": [[
                "action": ["type": "add_reminder"], "label": "test"
            ]], "requesterName": "小旭", "requesterUsername": "xu"]],
        ]
        let msg = MessageStore.parseMessage(dict)
        XCTAssertNotNil(msg)
        XCTAssertNotNil(msg?.meta?.confirm)
        XCTAssertEqual(msg?.meta?.confirm?.status, "pending")
    }

    func testParseMessageWithReply() {
        let dict: [String: Any] = [
            "id": "msg_reply", "sender": "si", "senderName": "小偲",
            "kind": "user", "type": "text", "text": "reply",
            "channel": "couple", "ts": 1710000000000,
            "replyTo": "msg_001", "replyPreview": "hello",
        ]
        let msg = MessageStore.parseMessage(dict)
        XCTAssertNotNil(msg)
        XCTAssertEqual(msg?.replyTo, "msg_001")
        XCTAssertEqual(msg?.replyPreview, "hello")
    }

    // MARK: - parseMessages (batch)

    func testParseMessagesBatch() {
        let list: [[String: Any]] = [
            ["id": "a", "sender": "xu", "type": "text", "text": "1", "channel": "couple", "ts": 1],
            ["id": "b", "sender": "si", "type": "text", "text": "2", "channel": "couple", "ts": 2],
            ["sender": "xu"],  // missing id -> skipped
        ]
        let result = MessageStore.parseMessages(list, context: "batch")
        XCTAssertEqual(result.count, 2)
    }

    func testParseMessagesEmpty() {
        let result = MessageStore.parseMessages([], context: "empty")
        XCTAssertTrue(result.isEmpty)
    }
}

@MainActor
final class MessageStoreSearchMergeTests: XCTestCase {

    func testMergeSearchDeduplicatesById() {
        let a = makeMessage(id: "m1", ts: 100)
        let b = makeMessage(id: "m1", ts: 200)  // same id, different ts
        let c = makeMessage(id: "m2", ts: 150)

        let result = MessageStore.mergeSearchResults([a], [b, c])
        XCTAssertEqual(result.count, 2)
        // Should keep the first occurrence (ts=100 for m1)
        XCTAssertTrue(result.contains(where: { $0.id == "m1" && $0.ts == 100 }))
        XCTAssertTrue(result.contains(where: { $0.id == "m2" }))
    }

    func testMergeSearchSortsDescending() {
        let a = makeMessage(id: "a", ts: 100)
        let b = makeMessage(id: "b", ts: 300)
        let c = makeMessage(id: "c", ts: 200)

        let result = MessageStore.mergeSearchResults([c, a], [b])
        XCTAssertEqual(result.map(\.id), ["b", "c", "a"])
    }

    func testMergeSearchEmptyInputs() {
        XCTAssertTrue(MessageStore.mergeSearchResults([], []).isEmpty)
        let one = [makeMessage(id: "x", ts: 1)]
        XCTAssertEqual(MessageStore.mergeSearchResults(one, []).count, 1)
        XCTAssertEqual(MessageStore.mergeSearchResults([], one).count, 1)
    }

    // MARK: - Helpers

    private func makeMessage(id: String, ts: Double) -> ChatMessage {
        let dict: [String: Any] = [
            "id": id, "sender": "xu", "senderName": "小旭",
            "kind": "user", "type": "text", "text": id,
            "channel": "couple", "ts": ts,
        ]
        return ChatMessage(dict: dict)!
    }
}

@MainActor
final class MessageStoreMergedWindowTests: XCTestCase {

    func testMergedWindowEmptyWindowReturnsCurrent() {
        let current = [makeMessage(id: "c1", ts: 100)]
        let result = MessageStore.mergedWindow([], with: current, around: "c1")
        XCTAssertEqual(result, current)
    }

    func testMergedWindowDeduplicatesAndSorts() {
        let w1 = makeMessage(id: "w1", ts: 50)
        let w2 = makeMessage(id: "w2", ts: 150)
        let c1 = makeMessage(id: "c1", ts: 100)
        let c2 = makeMessage(id: "w2", ts: 150)  // duplicate of w2

        let result = MessageStore.mergedWindow([w1, w2], with: [c1, c2], around: "c1")
        // Should have 3 unique messages, sorted ascending
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.map(\.id), ["w1", "c1", "w2"])
    }

    func testMergedWindowAroundTarget() {
        let messages = (0..<20).map { makeMessage(id: "m\($0)", ts: Double($0 * 100)) }
        let result = MessageStore.mergedWindow(messages, with: [], around: "m10")
        // Should center around m10 with ±window
        XCTAssertTrue(result.contains(where: { $0.id == "m10" }))
    }

    func testMergedWindowTargetNotFoundReturnsTail() {
        let messages = (0..<100).map { makeMessage(id: "m\($0)", ts: Double($0 * 100)) }
        let result = MessageStore.mergedWindow(messages, with: [], around: "nonexistent")
        XCTAssertEqual(result.count, 90)  // suffix(90)
    }

    private func makeMessage(id: String, ts: Double) -> ChatMessage {
        ChatMessage(dict: [
            "id": id, "sender": "xu", "senderName": "小旭",
            "kind": "user", "type": "text", "text": id,
            "channel": "couple", "ts": ts,
        ])!
    }
}

@MainActor
final class MessageStoreDayRangeTests: XCTestCase {

    func testDayRangeSpansFullDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let date = cal.date(from: DateComponents(year: 2026, month: 7, day: 10))!

        let range = MessageStore.dayRange(for: date)
        let diffMs = range.end - range.start
        // Should be exactly 86400000 ms (24 hours)
        XCTAssertEqual(diffMs, 86_400_000, accuracy: 1)
    }

    func testDayRangeStartIsMidnight() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let date = cal.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 14, minute: 30))!

        let range = MessageStore.dayRange(for: date)
        let startDate = Date(timeIntervalSince1970: range.start / 1000)
        let components = cal.dateComponents([.hour, .minute], from: startDate)
        XCTAssertEqual(components.hour, 0)
        XCTAssertEqual(components.minute, 0)
    }
}

@MainActor
final class MessageStoreMediaPlaceholderTests: XCTestCase {

    func testPlaceholderText() {
        XCTAssertEqual(MessageStore.mediaPlaceholderText(for: "video"), "[视频]")
        XCTAssertEqual(MessageStore.mediaPlaceholderText(for: "voice"), "[语音]")
        XCTAssertEqual(MessageStore.mediaPlaceholderText(for: "file"), "[文件]")
        XCTAssertEqual(MessageStore.mediaPlaceholderText(for: "image"), "[图片]")
        XCTAssertEqual(MessageStore.mediaPlaceholderText(for: "sticker"), "[图片]")
    }
}
