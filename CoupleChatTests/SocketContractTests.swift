import XCTest
@testable import CoupleChat

final class SocketContractTests: XCTestCase {

    func testMessageFetchRequestEncodesIncrementalCursor() {
        let payload = SocketPayloadEncoder.encode(
            MessageFetchRequest(channel: .couple, since: 1_710_000_000_000, limit: 80))

        XCTAssertEqual(payload["channel"] as? String, "couple")
        XCTAssertEqual((payload["since"] as? NSNumber)?.doubleValue, 1_710_000_000_000)
        XCTAssertEqual((payload["limit"] as? NSNumber)?.intValue, 80)
        XCTAssertNil(payload["after"])
        XCTAssertNil(payload["before"])
    }

    func testMessageFetchRequestEncodesDateRange() {
        let payload = SocketPayloadEncoder.encode(
            MessageFetchRequest(channel: .ai, after: 100, before: 200, limit: 80))

        XCTAssertEqual(payload["channel"] as? String, "ai")
        XCTAssertEqual((payload["after"] as? NSNumber)?.doubleValue, 100)
        XCTAssertEqual((payload["before"] as? NSNumber)?.doubleValue, 200)
    }

    func testMediaSendRequestEncodesUploadReference() {
        let payload = SocketPayloadEncoder.encode(
            MessageSendRequest(
                channel: .couple,
                type: "image",
                text: "[图片]",
                url: "https://example.com/uploads/up_12345678.jpg",
                uploadId: "up_12345678",
                clientId: "tmp-123"))

        XCTAssertEqual(payload["uploadId"] as? String, "up_12345678")
        XCTAssertEqual(payload["url"] as? String, "https://example.com/uploads/up_12345678.jpg")
    }

    func testCriticalSocketEventNamesStayStable() {
        XCTAssertEqual(SocketEvent.messagesFetch.rawValue, "messages:fetch")
        XCTAssertEqual(SocketEvent.messageSend.rawValue, "message:send")
        XCTAssertEqual(SocketEvent.sharedSet.rawValue, "shared:set")
    }
}
