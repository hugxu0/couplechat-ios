import XCTest
@testable import CoupleChat

final class SocketContractTests: XCTestCase {

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
        XCTAssertEqual(SocketEvent.messageSend.rawValue, "message:send")
        XCTAssertEqual(SocketEvent.sharedSet.rawValue, "shared:set")
    }
}
