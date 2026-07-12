import XCTest
@testable import CoupleChat

final class ChatTimelineBuilderTests: XCTestCase {
    func testBuilderAddsTimeSeparatorsAndGroupsConsecutiveSender() {
        let first = message(id: "a", sender: "xu", ts: 1_000)
        let second = message(id: "b", sender: "xu", ts: 2_000)
        let third = message(id: "c", sender: "si", ts: 600_000)

        let result = ChatTimelineBuilder.build(messages: [first, second, third])

        XCTAssertEqual(result.items.map(\.id), ["time-a", "a", "b", "time-c", "c"])
        XCTAssertEqual(result.groupedMessageIds, ["b"])
    }

    func testBuilderProjectsSystemAndActivityMessages() {
        let system = message(id: "system", sender: "xu", ts: 1_000, kind: "system")
        let activity = message(id: "__ai_activity__ai", sender: "ai", ts: 2_000)

        let result = ChatTimelineBuilder.build(messages: [system], activity: activity)

        XCTAssertEqual(result.items.last, .message(id: activity.id))
        XCTAssertEqual(result.messagesById[activity.id], activity)
        XCTAssertEqual(result.items[1], .system(id: "system-system", text: system.text))
    }

    func testBuilderSeparatesMessagesAcrossMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let beforeMidnight = message(id: "before", sender: "xu", ts: 86_390_000)
        let afterMidnight = message(id: "after", sender: "xu", ts: 86_410_000)

        let result = ChatTimelineBuilder.build(
            messages: [beforeMidnight, afterMidnight],
            calendar: calendar)

        XCTAssertEqual(result.items.map(\.id), ["time-before", "before", "time-after", "after"])
        XCTAssertFalse(result.groupedMessageIds.contains("after"))
    }

    func testBuilderUsesLastProjectionForDuplicateStableID() {
        var pending = message(id: "stable", sender: "xu", ts: 1_000)
        pending.pending = true
        let formal = message(id: "stable", sender: "xu", ts: 2_000)

        let result = ChatTimelineBuilder.build(messages: [pending, formal])

        XCTAssertEqual(result.messagesById["stable"]?.ts, formal.ts)
    }

    private func message(
        id: String,
        sender: String,
        ts: Double,
        kind: String = "user"
    ) -> ChatMessage {
        ChatMessage(dict: [
            "id": id, "sender": sender, "senderName": sender,
            "kind": kind, "type": "text", "text": id,
            "channel": "couple", "ts": ts,
        ])!
    }
}
