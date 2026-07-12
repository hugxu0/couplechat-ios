import XCTest
@testable import CoupleChat

final class ServerErrorCodeTests: XCTestCase {
    func testKnownCodesMapToActionableMessages() {
        XCTAssertEqual(
            ServerErrorCode.message(for: "upload_not_found", fallback: "fallback"),
            "上传记录已失效，请重新选择文件发送")
        XCTAssertEqual(
            ServerErrorCode.message(for: "unauthorized", fallback: "fallback"),
            "登录已过期，请重新登录")
    }

    func testUnknownCodesUseFallback() {
        XCTAssertEqual(ServerErrorCode.message(for: "future_code", fallback: "请重试"), "请重试")
    }
}
