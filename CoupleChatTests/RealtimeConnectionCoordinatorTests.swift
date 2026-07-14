import XCTest
@testable import CoupleChat

@MainActor
final class RealtimeConnectionCoordinatorTests: XCTestCase {
    func testReconnectBackoffStartsQuicklyAndCapsAtThreeSeconds() {
        XCTAssertEqual(RealtimeConnectionCoordinator.retryDelay(for: 1), 0.35)
        XCTAssertEqual(RealtimeConnectionCoordinator.retryDelay(for: 2), 0.7)
        XCTAssertEqual(RealtimeConnectionCoordinator.retryDelay(for: 3), 1.4)
        XCTAssertEqual(RealtimeConnectionCoordinator.retryDelay(for: 4), 2.4)
        XCTAssertEqual(RealtimeConnectionCoordinator.retryDelay(for: 20), 3)
    }
}
