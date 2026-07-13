import XCTest
@testable import CoupleChat

final class ChatMessageCollectionTests: XCTestCase {
    func testUpsertInsertsMessageOlderThanEntireWindowAtBeginning() {
        var messages = [message("middle", ts: 20), message("latest", ts: 30)]

        ChatMessageCollection.upsert(message("oldest", ts: 10), into: &messages)

        XCTAssertEqual(messages.map(\.id), ["oldest", "middle", "latest"])
    }

    func testUpsertReplacesOptimisticMessageUsingClientId() {
        var optimistic = message("tmp-1", ts: 10)
        optimistic.clientId = "tmp-1"
        optimistic.pending = true
        var acknowledged = message("server-1", ts: 11)
        acknowledged.clientId = "tmp-1"
        var messages = [optimistic]

        ChatMessageCollection.upsert(acknowledged, into: &messages)

        XCTAssertEqual(messages.map(\.id), ["server-1"])
        XCTAssertFalse(messages[0].pending)
    }

    func testReplacePendingRemovesSocketAndAckDuplicate() {
        var pending = message("tmp-1", ts: 10)
        pending.clientId = "tmp-1"
        pending.pending = true
        var socketMessage = message("server-1", ts: 11)
        socketMessage.clientId = "tmp-1"
        var acknowledged = socketMessage
        acknowledged.text = "ack"
        var messages = [pending, socketMessage]

        ChatMessageCollection.replacePending(
            clientId: "tmp-1",
            with: acknowledged,
            in: &messages)

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].id, "server-1")
        XCTAssertEqual(messages[0].text, "ack")
    }

    func testPendingFactoryUsesOneIdentityAndTimestamp() {
        let session = Session(token: "token", username: "xu", name: "小旭")

        let draft = PendingMessageFactory.text(
            "hello",
            channel: .couple,
            replyTo: nil,
            replyPreview: nil,
            meta: nil,
            session: session,
            clientId: "tmp-fixed")

        XCTAssertEqual(draft.message.id, draft.outbound.clientId)
        XCTAssertEqual(draft.message.ts, draft.outbound.createdAt)
        XCTAssertEqual(draft.outbound.clientId, "tmp-fixed")
    }

    func testSendRequestRejectsPartiallyUploadedAttachmentGroup() {
        let item = PendingOutboundMessage(
            clientId: "tmp-live",
            channel: "couple",
            type: "image",
            text: "[图片]",
            replyTo: nil,
            replyPreview: nil,
            localFilePath: nil,
            mimeType: nil,
            uploadId: nil,
            uploadURL: nil,
            createdAt: 1,
            attempts: 0,
            lastError: nil,
            attachments: [
                PendingOutboundAttachment(
                    assetId: "asset",
                    role: "photo",
                    order: 0,
                    localFilePath: "/tmp/photo.jpg",
                    mimeType: "image/jpeg",
                    uploadId: "upload-photo"),
                PendingOutboundAttachment(
                    assetId: "asset",
                    role: "pairedVideo",
                    order: 0,
                    localFilePath: "/tmp/video.mov",
                    mimeType: "video/quicktime"),
            ])

        XCTAssertNil(item.sendRequest(channel: .couple))
    }

    func testStickerSendRequestUsesRemoteURLWithoutUploadReference() {
        let item = PendingOutboundMessage(
            clientId: "tmp-sticker",
            channel: "couple",
            type: "sticker",
            text: "[表情]",
            replyTo: nil,
            replyPreview: nil,
            localFilePath: nil,
            mimeType: nil,
            uploadId: nil,
            uploadURL: "/uploads/cat.gif",
            createdAt: 1,
            attempts: 0,
            lastError: nil)

        let request = item.sendRequest(channel: .couple)
        XCTAssertNotNil(request)
        let resolvedURL = request.flatMap { $0.url }.flatMap { URL(string: $0) }
        XCTAssertEqual(resolvedURL?.path, "/uploads/cat.gif")
        XCTAssertTrue(resolvedURL?.scheme == "https" || resolvedURL?.scheme == "http")
        XCTAssertNil(request?.uploadId)
    }

    private func message(_ id: String, ts: Double) -> ChatMessage {
        ChatMessage(dict: [
            "id": id,
            "sender": "xu",
            "senderName": "小旭",
            "kind": "user",
            "type": "text",
            "text": id,
            "channel": "couple",
            "ts": ts,
        ])!
    }
}
