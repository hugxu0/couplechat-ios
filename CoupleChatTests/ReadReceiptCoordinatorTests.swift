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

    func testServerAcknowledgementClearsProcessedRequest() {
        let coordinator = ReadReceiptCoordinator()
        coordinator.mark(.couple, through: 100, isConnected: false) { _, _ in false }

        coordinator.acknowledge(.couple, requestTimestamp: 100)

        XCTAssertNil(coordinator.pendingTimestamp(for: .couple))
    }

    func testOlderAcknowledgementDoesNotClearNewerPendingRead() {
        let coordinator = ReadReceiptCoordinator()
        coordinator.mark(.couple, through: 100, isConnected: false) { _, _ in false }
        coordinator.mark(.couple, through: 200, isConnected: false) { _, _ in false }

        coordinator.acknowledge(.couple, requestTimestamp: 100)

        XCTAssertEqual(coordinator.pendingTimestamp(for: .couple), 200)
    }

    func testAckFailureMakesSameTimestampRetryable() async {
        let coordinator = ReadReceiptCoordinator()
        coordinator.mark(.couple, through: 100, isConnected: false) { _, _ in false }
        var emitted: [Double] = []
        let emit: ReadReceiptCoordinator.Emitter = { _, timestamp in
            emitted.append(timestamp)
            return true
        }
        coordinator.flush(isConnected: true, emit: emit)

        coordinator.retry(
            .couple,
            requestTimestamp: 100,
            isConnected: true,
            emit: emit)
        try? await Task.sleep(nanoseconds: 450_000_000)

        XCTAssertEqual(emitted, [100, 100])
    }
}
