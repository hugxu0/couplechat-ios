import XCTest
@testable import CoupleChat

@MainActor
final class ReadReceiptCoordinatorTests: XCTestCase {
    func testOfflineReadsMergeToHighestTimestampAndFlushOnce() {
        let coordinator = ReadReceiptCoordinator()
        coordinator.mark(.couple, through: 10, isConnected: false) { _, _ in false }
        coordinator.mark(.couple, through: 8, isConnected: false) { _, _ in false }
        coordinator.mark(.couple, through: 20, isConnected: false) { _, _ in false }
        var emitted: [(ChatChannel, Double)] = []

        coordinator.flush(isConnected: true) { channel, timestamp in
            emitted.append((channel, timestamp))
            return true
        }

        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(emitted.first?.0, .couple)
        XCTAssertEqual(emitted.first?.1, 20)
    }

    func testConfirmedTimestampClearsPendingReceipt() {
        let coordinator = ReadReceiptCoordinator()
        coordinator.mark(.ai, through: 30, isConnected: false) { _, _ in false }

        coordinator.confirm(.ai, through: 29)
        XCTAssertEqual(coordinator.pendingTimestamp(for: .ai), 30)

        coordinator.confirm(.ai, through: 30)
        XCTAssertNil(coordinator.pendingTimestamp(for: .ai))
    }
}
