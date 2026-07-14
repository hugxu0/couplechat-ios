import Foundation
import XCTest
@testable import CoupleChat

final class AppDeepLinkRouterTests: XCTestCase {
    func testRecognizesSupportedBarkDestinations() {
        XCTAssertEqual(AppDeepLink.parse(URL(string: "couplechat://chat/couple")!), .coupleChat)
        XCTAssertEqual(AppDeepLink.parse(URL(string: "couplechat://chat/ai")!), .dajuChat)
        XCTAssertEqual(AppDeepLink.parse(URL(string: "couplechat://plans/reminders")!), .reminders)
    }

    func testRejectsUnknownOrForeignLinks() {
        XCTAssertNil(AppDeepLink.parse(URL(string: "https://chat/couple")!))
        XCTAssertNil(AppDeepLink.parse(URL(string: "couplechat://settings/notifications")!))
    }
}
