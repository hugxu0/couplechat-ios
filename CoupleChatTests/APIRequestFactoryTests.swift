import XCTest
@testable import CoupleChat

final class APIRequestFactoryTests: XCTestCase {
    func testAuthorizedRequestUsesSharedBaseAndHeaders() {
        let request = APIRequestFactory.authorized(
            path: "api/v2/me/devices",
            method: "DELETE",
            token: "token",
            timeout: 9)

        XCTAssertEqual(request?.url?.path, "/api/v2/me/devices")
        XCTAssertEqual(request?.httpMethod, "DELETE")
        XCTAssertEqual(request?.timeoutInterval, 9)
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer token")
    }

    func testErrorCodeDecodesServerEnvelope() throws {
        let data = try JSONEncoder().encode(["error": "version_conflict"])
        XCTAssertEqual(APIRequestFactory.errorCode(from: data), "version_conflict")
    }
}
