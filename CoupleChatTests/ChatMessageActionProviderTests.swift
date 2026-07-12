import XCTest
@testable import CoupleChat

final class ChatMessageActionProviderTests: XCTestCase {
    func testFailedMessageOnlyOffersRetryAndDiscard() {
        var message = makeMessage(type: "image", sender: "xu", ts: 1_000)
        message.failed = true
        XCTAssertEqual(
            ChatMessageActionProvider.actions(for: message, currentUsername: "xu", nowMilliseconds: 2_000),
            [.retry, .discard])
    }

    func testRecentOwnTextCanCopyReplyAndRecall() {
        let message = makeMessage(type: "text", sender: "xu", ts: 100_000)
        XCTAssertEqual(
            ChatMessageActionProvider.actions(for: message, currentUsername: "xu", nowMilliseconds: 110_000),
            [.copy, .reply, .recall])
    }

    func testPendingAndOtherUsersOldMessagesCannotRecall() {
        var pending = makeMessage(type: "text", sender: "xu", ts: 1_000)
        pending.pending = true
        XCTAssertTrue(ChatMessageActionProvider.actions(for: pending, currentUsername: "xu").isEmpty)

        let other = makeMessage(type: "image", sender: "si", ts: 1_000)
        XCTAssertEqual(
            ChatMessageActionProvider.actions(for: other, currentUsername: "xu", nowMilliseconds: 500_000),
            [.reply])
    }

    private func makeMessage(type: String, sender: String, ts: Double) -> ChatMessage {
        ChatMessage(dict: [
            "id": "message-\(type)-\(sender)", "sender": sender, "senderName": sender,
            "kind": "user", "type": type, "text": "hello", "channel": "couple", "ts": ts,
        ])!
    }
}
