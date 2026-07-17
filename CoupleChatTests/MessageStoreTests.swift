import SocketIO
import XCTest
@testable import CoupleChat

private final class DisconnectedSocketProvider: SocketProvider {
    var socket: SocketIOClient? { nil }
    var isConnected: Bool { false }
    var sessionUsername: String? { "xu" }
    var currentSession: Session? { Session(token: "token", username: "xu", name: "小旭") }
}

@MainActor
final class MessageStoreReadStateTests: XCTestCase {
    func testMarkReadOptimisticallyClearsLocalUnreadStateWhileDisconnected() {
        let provider = DisconnectedSocketProvider()
        let store = MessageStore()
        store.socketProvider = provider

        store.markRead(.couple, through: 1_725_000_000_000)

        XCTAssertEqual(store.readState(for: .couple)["xu"], 1_725_000_000_000)
        XCTAssertEqual(store.pendingReadTimestamp(for: .couple), 1_725_000_000_000)
    }
}

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

    func testSendAckRequiresCurrentServerMessageContract() {
        let validMessage: [String: Any] = [
            "id": "server-id",
            "sender": "xu",
            "type": "text",
            "text": "hello",
            "channel": "couple",
            "ts": 100,
        ]
        guard let message = MessageStore.parseSendAckMessage(
            ["message": validMessage],
            expectedChannel: .couple)
        else {
            return XCTFail("Expected a valid acknowledgement message")
        }
        XCTAssertEqual(message.id, "server-id")

        var missingChannel = validMessage
        missingChannel.removeValue(forKey: "channel")
        var unknownChannel = validMessage
        unknownChannel["channel"] = "private-future"
        var wrongChannel = validMessage
        wrongChannel["channel"] = "ai"

        let invalidPayloads: [[String: Any]] = [
            ["ok": true, "id": "server-id"],
            ["message": NSNull()],
            ["message": missingChannel],
            ["message": unknownChannel],
            ["message": wrongChannel],
        ]
        for payload in invalidPayloads {
            XCTAssertNil(MessageStore.parseSendAckMessage(payload, expectedChannel: .couple))
        }
    }
}

@MainActor
final class MessageStoreSearchMergeTests: XCTestCase {

    func testMergeSearchDeduplicatesById() {
        let a = makeMessage(id: "m1", ts: 100)
        let b = makeMessage(id: "m1", ts: 200)  // same id, different ts
        let c = makeMessage(id: "m2", ts: 150)

        let result = ChatMessageWindowing.mergeSearchResults([a], [b, c])
        XCTAssertEqual(result.count, 2)
        // Should keep the first occurrence (ts=100 for m1)
        XCTAssertTrue(result.contains(where: { $0.id == "m1" && $0.ts == 100 }))
        XCTAssertTrue(result.contains(where: { $0.id == "m2" }))
    }

    func testMergeSearchSortsDescending() {
        let a = makeMessage(id: "a", ts: 100)
        let b = makeMessage(id: "b", ts: 300)
        let c = makeMessage(id: "c", ts: 200)

        let result = ChatMessageWindowing.mergeSearchResults([c, a], [b])
        XCTAssertEqual(result.map(\.id), ["b", "c", "a"])
    }

    func testMergeSearchEmptyInputs() {
        XCTAssertTrue(ChatMessageWindowing.mergeSearchResults([], []).isEmpty)
        let one = [makeMessage(id: "x", ts: 1)]
        XCTAssertEqual(ChatMessageWindowing.mergeSearchResults(one, []).count, 1)
        XCTAssertEqual(ChatMessageWindowing.mergeSearchResults([], one).count, 1)
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
        let result = ChatMessageWindowing.mergedWindow([], with: current, around: "c1")
        XCTAssertEqual(result, current)
    }

    func testMergedWindowDeduplicatesAndSorts() {
        let w1 = makeMessage(id: "w1", ts: 50)
        let w2 = makeMessage(id: "w2", ts: 150)
        let c1 = makeMessage(id: "c1", ts: 100)
        let c2 = makeMessage(id: "w2", ts: 150)  // duplicate of w2

        let result = ChatMessageWindowing.mergedWindow([w1, w2], with: [c1, c2], around: "c1")
        // Should have 3 unique messages, sorted ascending
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.map(\.id), ["w1", "c1", "w2"])
    }

    func testMergedWindowAroundTarget() {
        let messages = (0..<20).map { makeMessage(id: "m\($0)", ts: Double($0 * 100)) }
        let result = ChatMessageWindowing.mergedWindow(messages, with: [], around: "m10")
        // Should center around m10 with ±window
        XCTAssertTrue(result.contains(where: { $0.id == "m10" }))
    }

    func testMergedWindowTargetNotFoundReturnsTail() {
        let messages = (0..<100).map { makeMessage(id: "m\($0)", ts: Double($0 * 100)) }
        let result = ChatMessageWindowing.mergedWindow(messages, with: [], around: "nonexistent")
        XCTAssertEqual(result.count, 90)  // suffix(90)
    }

    func testMergedWindowDoesNotBridgeHistoricalContextToLatestMessages() {
        let historical = (0..<65).map {
            makeMessage(id: "h\($0)", ts: Double(1_000 + $0))
        }
        let latest = (0..<50).map {
            makeMessage(id: "n\($0)", ts: Double(100_000 + $0))
        }

        let result = ChatMessageWindowing.mergedWindow(
            historical,
            with: latest,
            around: "h36")

        XCTAssertEqual(result.map(\.id), historical.map(\.id))
        XCTAssertFalse(result.contains(where: { $0.id.hasPrefix("n") }))
        XCTAssertEqual(result.last?.ts, historical.last?.ts)
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

        let range = ChatMessageWindowing.dayRange(for: date)
        let diffMs = range.end - range.start
        // Should be exactly 86400000 ms (24 hours)
        XCTAssertEqual(diffMs, 86_400_000, accuracy: 1)
    }

    func testDayRangeStartIsMidnight() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let date = cal.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 14, minute: 30))!

        let range = ChatMessageWindowing.dayRange(for: date)
        let startDate = Date(timeIntervalSince1970: range.start / 1000)
        let components = cal.dateComponents([.hour, .minute], from: startDate)
        XCTAssertEqual(components.hour, 0)
        XCTAssertEqual(components.minute, 0)
    }
}

@MainActor
final class MessageStoreMediaPlaceholderTests: XCTestCase {

    func testPlaceholderText() {
        XCTAssertEqual(PendingMessageFactory.placeholderText(for: "video"), "[视频]")
        XCTAssertEqual(PendingMessageFactory.placeholderText(for: "voice"), "[语音]")
        XCTAssertEqual(PendingMessageFactory.placeholderText(for: "file"), "[文件]")
        XCTAssertEqual(PendingMessageFactory.placeholderText(for: "image"), "[图片]")
        XCTAssertEqual(PendingMessageFactory.placeholderText(for: "sticker"), "[图片]")
    }

    func testMediaFileExtensionPreservesQuickTimeContainer() {
        XCTAssertEqual(MediaUploadService.fileExtension(for: "video/quicktime"), "mov")
        XCTAssertEqual(MediaUploadService.fileExtension(for: "video/mp4"), "mp4")
        XCTAssertEqual(MediaUploadService.fileExtension(for: "image/png"), "png")
        XCTAssertEqual(MediaUploadService.fileExtension(for: "image/gif"), "gif")
    }
}

@MainActor
final class MessageStoreLatestWindowTests: XCTestCase {
    func testLatestWindowDropsHistoricalSliceAndPreservesPendingOutbound() {
        let historical = makeMessage(id: "old", ts: 10)
        let latest = [makeMessage(id: "new-1", ts: 100), makeMessage(id: "new-2", ts: 200)]
        var pending = makeMessage(id: "tmp-1", ts: 300)
        pending.pending = true

        let result = ChatMessageWindowing.latestWindow(latest, preservingOutboundFrom: [historical, pending])

        XCTAssertEqual(result.map(\.id), ["new-1", "new-2", "tmp-1"])
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
final class MessageStoreFailedOutboxTests: XCTestCase {
    private var databaseURL: URL?
    private var temporaryURLs: [URL] = []

    override func setUp() {
        super.setUp()
        let username = "failed-outbox-\(UUID().uuidString)"
        XCTAssertTrue(ChatLocalDatabase.shared.open(username: username))
        databaseURL = ChatLocalDatabase.shared.currentDatabaseURL
    }

    override func tearDown() {
        ChatLocalDatabase.shared.close()
        for url in temporaryURLs { try? FileManager.default.removeItem(at: url) }
        if let databaseURL {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal")
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm")
        }
        super.tearDown()
    }

    func testDiscardFailedTextClearsOutboxAndTimeline() async {
        let item = makeItem(clientId: "tmp-failed-text", type: "text")
        let store = makeStore(containing: item)

        await store.discardFailedMessage(clientId: item.clientId)

        XCTAssertNil(ChatLocalDatabase.shared.pendingOutbound(clientId: item.clientId))
        XCTAssertFalse(store.messages(for: .couple).contains { $0.clientId == item.clientId })
    }

    func testOfflineSendImmediatelyBecomesFailed() async {
        let provider = DisconnectedSocketProvider()
        let store = MessageStore()
        store.socketProvider = provider

        await store.sendText(
            "offline", session: Session(token: "token", username: "xu", name: "小旭"))

        let message = store.messages(for: .couple).last
        XCTAssertNotNil(message)
        XCTAssertFalse(message?.pending == true)
        XCTAssertTrue(message?.failed == true)
        XCTAssertEqual(
            message.flatMap { ChatLocalDatabase.shared.pendingOutbound(clientId: $0.clientId ?? $0.id)?.attempts },
            1)
    }

    func testDiscardFailedMediaClearsOutboxTimelineAndFile() async throws {
        let file = try makeTemporaryFile(extension: "jpg")
        let item = makeItem(clientId: "tmp-failed-image", type: "image", localFilePath: file.path)
        let store = makeStore(containing: item)

        await store.discardFailedMessage(clientId: item.clientId)

        XCTAssertNil(ChatLocalDatabase.shared.pendingOutbound(clientId: item.clientId))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(store.messages(for: .couple).isEmpty)
    }

    func testDiscardFailedLivePhotoClearsBothFiles() async throws {
        let photo = try makeTemporaryFile(extension: "jpg")
        let video = try makeTemporaryFile(extension: "mov")
        let attachments = [
            PendingOutboundAttachment(
                assetId: "asset", role: "photo", order: 0, localFilePath: photo.path, mimeType: "image/jpeg"),
            PendingOutboundAttachment(
                assetId: "asset", role: "pairedVideo", order: 0, localFilePath: video.path, mimeType: "video/quicktime"),
        ]
        let item = makeItem(clientId: "tmp-live-photo", type: "image", attachments: attachments)
        let store = makeStore(containing: item)

        await store.discardFailedMessage(clientId: item.clientId)

        XCTAssertFalse(FileManager.default.fileExists(atPath: photo.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: video.path))
    }

    func testRetryMissingFileKeepsFailedState() async {
        let item = makeItem(
            clientId: "tmp-missing-image", type: "image",
            localFilePath: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path)
        let store = makeStore(containing: item)

        let result = await store.retryFailedMessage(
            clientId: item.clientId, session: Session(token: "token", username: "xu", name: "小旭"))

        XCTAssertEqual(result, .missingLocalFile)
        XCTAssertTrue(store.messages(for: .couple).first?.failed == true)
        XCTAssertFalse(store.messages(for: .couple).first?.pending == true)
        XCTAssertEqual(ChatLocalDatabase.shared.pendingOutbound(clientId: item.clientId)?.attempts, 1)
    }

    func testRetryChecksEverySingleMediaTypeForMissingFile() async {
        let store = MessageStore()
        let session = Session(token: "token", username: "xu", name: "小旭")

        for type in ["image", "video", "voice", "file"] {
            let item = makeItem(
                clientId: "tmp-missing-\(type)", type: type,
                localFilePath: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString).path)
            XCTAssertTrue(ChatLocalDatabase.shared.upsertPendingOutbound(item))
            store.updateMessages(.couple) { $0.append(item.optimisticMessage(session: session)) }

            let result = await store.retryFailedMessage(clientId: item.clientId, session: session)

            XCTAssertEqual(result, .missingLocalFile, "type=\(type)")
            XCTAssertTrue(store.messages(for: .couple).first { $0.clientId == item.clientId }?.failed == true)
        }
    }

    func testDiscardSameClientIdTwiceIsSafe() async {
        let item = makeItem(clientId: "tmp-idempotent-delete", type: "text")
        let store = makeStore(containing: item)

        await store.discardFailedMessage(clientId: item.clientId)
        await store.discardFailedMessage(clientId: item.clientId)

        XCTAssertNil(ChatLocalDatabase.shared.pendingOutbound(clientId: item.clientId))
        XCTAssertTrue(store.messages(for: .couple).isEmpty)
    }

    private func makeStore(containing item: PendingOutboundMessage) -> MessageStore {
        XCTAssertTrue(ChatLocalDatabase.shared.upsertPendingOutbound(item))
        let store = MessageStore()
        store.updateMessages(.couple) {
            $0 = [item.optimisticMessage(session: Session(token: "token", username: "xu", name: "小旭"))]
        }
        return store
    }

    private func makeItem(
        clientId: String,
        type: String,
        localFilePath: String? = nil,
        attachments: [PendingOutboundAttachment] = []
    ) -> PendingOutboundMessage {
        PendingOutboundMessage(
            clientId: clientId, channel: "couple", type: type,
            text: type == "text" ? "failed" : "[媒体]",
            replyTo: nil, replyPreview: nil, localFilePath: localFilePath,
            mimeType: localFilePath == nil ? nil : "image/jpeg",
            uploadId: nil, uploadURL: nil, createdAt: 1_710_000_000_000,
            attempts: 1, lastError: "offline", attachments: attachments)
    }

    private func makeTemporaryFile(extension ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try Data("test".utf8).write(to: url)
        temporaryURLs.append(url)
        return url
    }
}

@MainActor
final class ChatTimelineMediaPreviewStateTests: XCTestCase {
    func testPendingAndFailedMediaCannotOpenPager() {
        let session = Session(token: "token", username: "xu", name: "小旭")
        var message = ChatMessage(
            optimisticMedia: "image", text: "[图片]", localURL: "file:///tmp/pending.jpg",
            me: session, clientId: "tmp-preview", channel: "couple")
        XCTAssertFalse(ChatNativeMessageCell.canOpenMediaPreview(message))

        message.pending = false
        message.failed = true
        XCTAssertFalse(ChatNativeMessageCell.canOpenMediaPreview(message))

        message.failed = false
        XCTAssertTrue(ChatNativeMessageCell.canOpenMediaPreview(message))
    }
}
