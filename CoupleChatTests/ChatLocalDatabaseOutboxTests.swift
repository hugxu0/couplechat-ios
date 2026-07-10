import Foundation
import XCTest
@testable import CoupleChat

final class ChatLocalDatabaseOutboxTests: XCTestCase {
    private var databaseURL: URL?

    override func tearDown() {
        ChatLocalDatabase.shared.close()
        if let databaseURL {
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: databaseURL)
            try? fileManager.removeItem(atPath: databaseURL.path + "-wal")
            try? fileManager.removeItem(atPath: databaseURL.path + "-shm")
        }
        databaseURL = nil
        super.tearDown()
    }

    func testPendingOutboundRoundTripAndDelete() {
        let username = "outbox-test-\(UUID().uuidString)"
        XCTAssertTrue(ChatLocalDatabase.shared.open(username: username))
        databaseURL = ChatLocalDatabase.shared.currentDatabaseURL

        let item = PendingOutboundMessage(
            clientId: "tmp-outbox-1",
            channel: "couple",
            type: "image",
            text: "[图片]",
            replyTo: nil,
            replyPreview: nil,
            localFilePath: "/tmp/outbox.jpg",
            mimeType: "image/jpeg",
            uploadId: "up_12345678",
            uploadURL: "https://example.com/uploads/up_12345678.jpg",
            createdAt: 1_710_000_000_000,
            attempts: 2,
            lastError: "timeout")

        XCTAssertTrue(ChatLocalDatabase.shared.upsertPendingOutbound(item))
        XCTAssertEqual(ChatLocalDatabase.shared.pendingOutbound(clientId: item.clientId), item)
        XCTAssertEqual(ChatLocalDatabase.shared.loadPendingOutbounds(), [item])

        ChatLocalDatabase.shared.deletePendingOutbound(clientId: item.clientId)
        XCTAssertNil(ChatLocalDatabase.shared.pendingOutbound(clientId: item.clientId))
    }

    func testAlbumAttachmentOutboxRoundTrip() {
        let username = "album-outbox-test-\(UUID().uuidString)"
        XCTAssertTrue(ChatLocalDatabase.shared.open(username: username))
        databaseURL = ChatLocalDatabase.shared.currentDatabaseURL
        let attachment = PendingOutboundAttachment(
            assetId: "asset-1", role: "photo", order: 0,
            localFilePath: "/tmp/album.jpg", mimeType: "image/jpeg",
            uploadId: "up_12345678", uploadURL: "/media/up_12345678")
        let item = PendingOutboundMessage(
            clientId: "tmp-album", channel: "couple", type: "image", text: "[实况照片]",
            replyTo: nil, replyPreview: nil, localFilePath: nil, mimeType: nil,
            uploadId: nil, uploadURL: nil, createdAt: 1_710_000_000_000,
            attempts: 0, lastError: nil, attachments: [attachment])
        XCTAssertTrue(ChatLocalDatabase.shared.upsertPendingOutbound(item))
        XCTAssertEqual(ChatLocalDatabase.shared.pendingOutbound(clientId: item.clientId), item)
    }
}
