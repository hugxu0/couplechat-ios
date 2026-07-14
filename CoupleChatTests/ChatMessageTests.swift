import Combine
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

    func testVoiceMessageHydratesTranscriptFromMessagePayload() {
        let message = ChatMessage(dict: [
            "id": "voice_001",
            "sender": "si",
            "type": "voice",
            "text": "",
            "channel": "couple",
            "ts": 1_710_000_000_000,
            "transcript": [
                "messageId": "voice_001",
                "status": "completed",
                "text": "晚上一起吃饭",
                "language": "zh",
                "version": 3,
                "updatedAt": 1_710_000_000_100,
            ],
        ])

        XCTAssertEqual(message?.transcript?.status, .ready)
        XCTAssertEqual(message?.transcript?.text, "晚上一起吃饭")
        XCTAssertEqual(message?.transcript?.version, 3)
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

    func testMessageContentKindAndConversationPreview() {
        let image = makeMessage(type: "image", text: "")
        XCTAssertEqual(image.contentKind, .image)
        XCTAssertEqual(image.conversationalPreviewText, "[图片]")
        XCTAssertEqual(image.replyPreviewText, "小旭: [图片]")

        let sticker = makeMessage(type: "sticker", text: "")
        XCTAssertEqual(sticker.conversationalPreviewText, "[表情]")

        let text = makeMessage(type: "text", text: "晚安")
        XCTAssertEqual(text.conversationalPreviewText, "晚安")
        XCTAssertEqual(text.replyPreviewText, "小旭: 晚安")

        let unknown = makeMessage(type: "future-type", text: "兼容正文")
        XCTAssertEqual(unknown.contentKind, .unknown)
        XCTAssertEqual(unknown.conversationalPreviewText, "兼容正文")
    }

    private func makeMessage(type: String, text: String) -> ChatMessage {
        ChatMessage(dict: [
            "id": UUID().uuidString,
            "sender": "xu",
            "senderName": "小旭",
            "kind": "user",
            "type": type,
            "text": text,
            "channel": "couple",
            "ts": 1_710_000_000_000,
        ])!
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
        XCTAssertEqual(restored.clientId, "tmp-durable-001")
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
        XCTAssertFalse(restored.failed)
        XCTAssertEqual(restored.id, restored.clientId)
    }

    func testPendingOutboundProjectsPendingStateWithoutChangingClientId() {
        let session = Session(token: "tok", username: "si", name: "小偲")
        let pending = PendingOutboundMessage(
            clientId: "tmp-pending-text",
            channel: "couple",
            type: "text",
            text: "等待发送",
            replyTo: "msg-source",
            replyPreview: "原消息",
            localFilePath: nil,
            mimeType: nil,
            uploadId: nil,
            uploadURL: nil,
            createdAt: 1_710_000_000_001,
            attempts: 0,
            lastError: nil)

        let restored = pending.optimisticMessage(session: session)
        XCTAssertEqual(restored.id, pending.clientId)
        XCTAssertEqual(restored.clientId, pending.clientId)
        XCTAssertTrue(restored.pending)
        XCTAssertFalse(restored.failed)
        XCTAssertEqual(restored.replyTo, "msg-source")
    }

    func testFailedMediaOutboxProjectsFailedStateAndLocalPreview() {
        let session = Session(token: "tok", username: "xu", name: "小旭")
        let pending = PendingOutboundMessage(
            clientId: "tmp-failed-image",
            channel: "couple",
            type: "image",
            text: "[图片]",
            replyTo: nil,
            replyPreview: nil,
            localFilePath: "/tmp/failed-image.jpg",
            mimeType: "image/jpeg",
            uploadId: nil,
            uploadURL: nil,
            createdAt: 1_710_000_000_002,
            attempts: 2,
            lastError: "offline")

        let restored = pending.optimisticMessage(session: session)
        XCTAssertEqual(restored.id, pending.clientId)
        XCTAssertEqual(restored.clientId, pending.clientId)
        XCTAssertEqual(restored.url, "file:///tmp/failed-image.jpg")
        XCTAssertFalse(restored.pending)
        XCTAssertTrue(restored.failed)
    }

    func testPendingAlbumKeepsClientIdAndAllAttachmentPreviews() {
        let session = Session(token: "tok", username: "xu", name: "小旭")
        let attachments = [
            PendingOutboundAttachment(
                assetId: "asset-live", role: "photo", order: 0,
                localFilePath: "/tmp/live.jpg", mimeType: "image/jpeg",
                uploadId: nil, uploadURL: nil),
            PendingOutboundAttachment(
                assetId: "asset-live", role: "pairedVideo", order: 0,
                localFilePath: "/tmp/live.mov", mimeType: "video/quicktime",
                uploadId: nil, uploadURL: nil),
        ]
        let pending = PendingOutboundMessage(
            clientId: "tmp-live-photo",
            channel: "couple",
            type: "image",
            text: "[实况照片]",
            replyTo: nil,
            replyPreview: nil,
            localFilePath: nil,
            mimeType: nil,
            uploadId: nil,
            uploadURL: nil,
            createdAt: 1_710_000_000_003,
            attempts: 0,
            lastError: nil,
            attachments: attachments)

        let restored = pending.optimisticMessage(session: session)
        XCTAssertEqual(restored.id, pending.clientId)
        XCTAssertEqual(restored.clientId, pending.clientId)
        XCTAssertEqual(restored.attachments?.count, 2)
        XCTAssertEqual(restored.attachments?.map(\.role), ["photo", "pairedVideo"])
        XCTAssertTrue(restored.pending)
        XCTAssertFalse(restored.failed)
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

    func testLegacyAttachmentMetadataFallsBackToSingleStaticMedia() {
        let dict: [String: Any] = [
            "id": "msg_album",
            "sender": "xu",
            "senderName": "小旭",
            "kind": "user",
            "type": "image",
            "text": "周末",
            "url": "/media/up_photo",
            "channel": "couple",
            "ts": 1_710_000_000_000,
            "attachments": [
                ["id": "up_photo", "assetId": "asset1", "role": "photo", "order": 0,
                 "url": "/media/up_photo", "mimeType": "image/jpeg", "size": 100],
                ["id": "up_motion", "assetId": "asset1", "role": "pairedVideo", "order": 0,
                 "url": "/media/up_motion", "mimeType": "video/quicktime", "size": 200],
                ["id": "up_photo2", "assetId": "asset2", "role": "photo", "order": 1,
                 "url": "/media/up_photo2", "mimeType": "image/jpeg", "size": 120],
            ],
        ]
        let message = ChatMessage(dict: dict)
        XCTAssertEqual(message?.attachments?.count, 3)
        XCTAssertEqual(MediaBrowserItem.items(for: message!).count, 1)
    }

    func testMediaPlaceholdersNeverRenderAsImageCaptions() {
        let session = Session(token: "tok", username: "xu", name: "小旭")
        for (index, text) in ["[图片]", "[实况照片]", "[3张图片]"].enumerated() {
            let message = ChatMessage(
                optimisticMedia: "image",
                text: text,
                localURL: "file:///tmp/\(index).jpg",
                me: session,
                clientId: "tmp-placeholder-\(index)",
                channel: "couple")
            XCTAssertNil(ChatTimelineMetrics.mediaCaption(for: message))
        }
    }

    func testAIActivityVisibilityPhases() {
        XCTAssertTrue(AIActivity(channel: .ai, requestMessageId: nil, requesterUsername: nil, phase: "accepted").isVisible)
        XCTAssertTrue(AIActivity(channel: .couple, requestMessageId: nil, requesterUsername: nil, phase: "generating").isVisible)
        XCTAssertFalse(AIActivity(channel: .ai, requestMessageId: nil, requesterUsername: nil, phase: "finished").isVisible)
    }

    @MainActor
    func testChatStoreForwardsAIReplyStateToViews() {
        let store = ChatStore()
        var changeCount = 0
        let observation = store.objectWillChange.sink { changeCount += 1 }

        store.messageStore.aiReplying = true

        XCTAssertEqual(changeCount, 1)
        XCTAssertTrue(store.isAIComposing(in: .ai))
        XCTAssertFalse(store.isAIComposing(in: .couple))
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testChatStoreClearsTransientAIStateAcrossBackgroundRecovery() {
        let store = ChatStore()
        let generating = AIActivity(
            channel: .couple,
            requestMessageId: "msg-request",
            requesterUsername: "xu",
            phase: "generating")

        store.setAIActivity(generating, for: ChatChannel.couple.rawValue)
        store.messageStore.aiTyping = true
        store.messageStore.aiReplying = true
        XCTAssertTrue(store.isAIComposing(in: .couple))
        XCTAssertTrue(store.isAIComposing(in: .ai))

        store.reportAway(true)
        XCTAssertFalse(store.isAIComposing(in: .couple))
        XCTAssertFalse(store.isAIComposing(in: .ai))

        store.setAIActivity(generating, for: ChatChannel.couple.rawValue)
        store.messageStore.aiTyping = true
        store.recoverOnForeground()
        XCTAssertFalse(store.isAIComposing(in: .couple))
        XCTAssertFalse(store.isAIComposing(in: .ai))
    }

    func testInteractionMetaTakesPriorityOverLegacyText() {
        let dict: [String: Any] = [
            "id": "msg_fx",
            "sender": "si",
            "senderName": "小偲",
            "kind": "user",
            "type": "text",
            "text": "兼容正文",
            "channel": "couple",
            "ts": 1_710_000_000_000,
            "meta": ["interaction": ["id": "fx1", "kind": "flower", "text": "🌸 送你一朵花花"]],
        ]
        let payload = ChatMessage(dict: dict)?.interactionPayload
        XCTAssertEqual(payload?.id, "fx1")
        XCTAssertEqual(payload?.kind, .flower)
    }
}
