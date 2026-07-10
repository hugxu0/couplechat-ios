import XCTest
@testable import CoupleChat

final class ChatMessageTests: XCTestCase {

    func testInitFromDict() {
        let dict: [String: Any] = [
            "id": "msg_001",
            "sender": "xu",
            "senderName": "小旭",
            "kind": "user",
            "type": "text",
            "text": "hello",
            "channel": "couple",
            "ts": 1710000000000,
        ]
        let msg = ChatMessage(dict: dict)
        XCTAssertNotNil(msg)
        XCTAssertEqual(msg?.id, "msg_001")
        XCTAssertEqual(msg?.sender, "xu")
        XCTAssertEqual(msg?.text, "hello")
        XCTAssertEqual(msg?.ts, 1710000000000)
    }

    func testInitFromDictMissingId() {
        let dict: [String: Any] = [
            "sender": "xu",
            "type": "text",
            "text": "hello",
        ]
        XCTAssertNil(ChatMessage(dict: dict))
    }

    func testOptimisticText() {
        let session = Session(token: "tok", username: "xu", name: "小旭")
        let msg = ChatMessage(
            optimisticText: "测试消息",
            me: session,
            clientId: "tmp-001",
            channel: "couple"
        )
        XCTAssertEqual(msg.id, "tmp-001")
        XCTAssertEqual(msg.sender, "xu")
        XCTAssertEqual(msg.type, "text")
        XCTAssertTrue(msg.pending)
        XCTAssertFalse(msg.failed)
    }

    func testOptimisticMedia() {
        let session = Session(token: "tok", username: "si", name: "小偲")
        let msg = ChatMessage(
            optimisticMedia: "image",
            text: "[图片]",
            localURL: "file:///tmp/test.jpg",
            me: session,
            clientId: "tmp-002",
            channel: "ai"
        )
        XCTAssertEqual(msg.type, "image")
        XCTAssertEqual(msg.url, "file:///tmp/test.jpg")
        XCTAssertEqual(msg.channel, "ai")
        XCTAssertTrue(msg.pending)
    }

    func testPendingOutboundRestoresSameClientIdAndFailureState() {
        let session = Session(token: "tok", username: "xu", name: "小旭")
        let pending = PendingOutboundMessage(
            clientId: "tmp-durable-001",
            channel: "couple",
            type: "text",
            text: "断网消息",
            replyTo: nil,
            replyPreview: nil,
            localFilePath: nil,
            mimeType: nil,
            uploadId: nil,
            uploadURL: nil,
            createdAt: 1_710_000_000_000,
            attempts: 1,
            lastError: "timeout")

        let restored = pending.optimisticMessage(session: session)
        XCTAssertEqual(restored.id, "tmp-durable-001")
        XCTAssertEqual(restored.ts, 1_710_000_000_000)
        XCTAssertFalse(restored.pending)
        XCTAssertTrue(restored.failed)
    }

    func testPendingStickerRestoresStickerBubble() {
        let session = Session(token: "tok", username: "xu", name: "小旭")
        let pending = PendingOutboundMessage(
            clientId: "tmp-sticker-001",
            channel: "couple",
            type: "sticker",
            text: "[表情]",
            replyTo: nil,
            replyPreview: nil,
            localFilePath: nil,
            mimeType: nil,
            uploadId: nil,
            uploadURL: "https://example.com/sticker.jpg",
            createdAt: 1_710_000_000_000,
            attempts: 0,
            lastError: nil)

        let restored = pending.optimisticMessage(session: session)
        XCTAssertEqual(restored.type, "sticker")
        XCTAssertEqual(restored.url, "https://example.com/sticker.jpg")
        XCTAssertTrue(restored.pending)
    }

    func testTimeFormatting() {
        let dict: [String: Any] = [
            "id": "msg_time",
            "sender": "xu",
            "senderName": "小旭",
            "kind": "user",
            "type": "text",
            "text": "hi",
            "channel": "couple",
            "ts": 1710000000000,
        ]
        let msg = ChatMessage(dict: dict)!
        let timeStr = msg.timeString
        // Should be formatted as HH:mm
        XCTAssertTrue(timeStr.contains(":"))
        XCTAssertEqual(timeStr.count, 5)
    }

    func testMediaURL() {
        let dict: [String: Any] = [
            "id": "msg_url",
            "sender": "xu",
            "senderName": "小旭",
            "kind": "user",
            "type": "image",
            "text": "",
            "url": "/uploads/test.jpg",
            "channel": "couple",
            "ts": 1710000000000,
        ]
        let msg = ChatMessage(dict: dict)!
        let url = msg.mediaURL
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.contains("hoo66.top") ?? false)
    }
}
