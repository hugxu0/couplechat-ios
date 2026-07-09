import XCTest
@testable import CoupleChat

final class ServerConfigTests: XCTestCase {

    func testBaseURLFromBundle() {
        let url = ServerConfig.baseURL
        XCTAssertNotNil(url)
        // 应该能正确解析
        XCTAssertFalse(url.absoluteString.isEmpty)
    }

    func testResolveAbsoluteURL() {
        let result = ServerConfig.resolveMediaURL("https://example.com/image.jpg")
        XCTAssertEqual(result?.absoluteString, "https://example.com/image.jpg")
    }

    func testResolveRelativeURL() {
        let result = ServerConfig.resolveMediaURL("/uploads/test.png")
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.absoluteString.contains("hoo66.top") ?? false)
        XCTAssertTrue(result?.absoluteString.contains("/uploads/test.png") ?? false)
    }

    func testResolveNilURL() {
        XCTAssertNil(ServerConfig.resolveMediaURL(nil))
        XCTAssertNil(ServerConfig.resolveMediaURL(""))
    }

    func testResolveFileURL() {
        let result = ServerConfig.resolveMediaURL("file:///tmp/photo.jpg")
        XCTAssertEqual(result?.absoluteString, "file:///tmp/photo.jpg")
    }
}
