import XCTest
@testable import CoupleChat

@MainActor
final class HistorySyncCoordinatorTests: XCTestCase {
    func testHistorySyncPublishesProgressAndCompletionAcrossBothChannels() async {
        let coordinator = makeCoordinator { channel, progress in
            let total = channel == .couple ? 12 : 5
            progress(total, total)
            return .init(localCount: total, remoteTotal: total,
                         downloaded: channel == .couple ? 3 : 1, completed: true, error: nil)
        }

        coordinator.startHistorySync()
        await waitUntil { !coordinator.operation.isRunning }

        XCTAssertEqual(coordinator.remoteCounts[ChatChannel.couple.rawValue], 12)
        XCTAssertEqual(coordinator.remoteCounts[ChatChannel.ai.rawValue], 5)
        XCTAssertEqual(coordinator.outcome, .completed("同步完成，本次新增 4 条消息"))
    }

    func testRepeatedStartDoesNotCreateConcurrentHistoryWorkers() async {
        var calls = 0
        var continuation: CheckedContinuation<HistorySyncCoordinator.HistoryResult, Never>?
        let coordinator = makeCoordinator { _, _ in
            calls += 1
            return await withCheckedContinuation { continuation = $0 }
        }

        coordinator.startHistorySync()
        await waitUntil { continuation != nil }
        coordinator.startHistorySync()

        XCTAssertEqual(calls, 1)
        coordinator.pause()
        continuation?.resume(returning: .init(localCount: 0, remoteTotal: nil, downloaded: 0,
                                              completed: false, error: "同步已暂停"))
        await Task.yield()
    }

    func testIncompleteCountsNeverReportLatest() async {
        let coordinator = makeCoordinator { channel, progress in
            let local = channel == .couple ? 8 : 5
            let remote = channel == .couple ? 12 : 5
            progress(local, remote)
            return .init(localCount: local, remoteTotal: remote, downloaded: 0,
                         completed: local == remote, error: nil)
        }

        coordinator.startHistorySync()
        await waitUntil { !coordinator.operation.isRunning }

        guard case .failed(let message) = coordinator.outcome else {
            return XCTFail("本地条数未达到云端总数时不能显示已是最新")
        }
        XCTAssertTrue(message.contains("同步未完成"))
    }

    func testPauseInvalidatesLateWorkerUpdates() async {
        var progress: ((Int, Int?) -> Void)?
        var continuation: CheckedContinuation<HistorySyncCoordinator.HistoryResult, Never>?
        let coordinator = makeCoordinator { _, callback in
            progress = callback
            return await withCheckedContinuation { continuation = $0 }
        }

        coordinator.startHistorySync()
        await waitUntil { continuation != nil }
        coordinator.pause()
        progress?(999, 1_000)
        continuation?.resume(returning: .init(localCount: 999, remoteTotal: 1_000, downloaded: 999,
                                              completed: false, error: nil))
        await Task.yield()

        XCTAssertEqual(coordinator.operation, .idle)
        XCTAssertEqual(coordinator.outcome, .paused("同步已暂停，下次会从当前位置继续"))
        XCTAssertNil(coordinator.remoteCounts[ChatChannel.couple.rawValue])
    }

    func testLogoutCancelsTaskAndClearsPublishedState() async {
        var continuation: CheckedContinuation<HistorySyncCoordinator.HistoryResult, Never>?
        let coordinator = makeCoordinator { _, _ in
            await withCheckedContinuation { continuation = $0 }
        }

        coordinator.startHistorySync()
        await waitUntil { continuation != nil }
        coordinator.cancelForLogout()
        continuation?.resume(returning: .init(localCount: 10, remoteTotal: 10, downloaded: 10,
                                              completed: true, error: nil))
        await Task.yield()

        XCTAssertEqual(coordinator.operation, .idle)
        XCTAssertEqual(coordinator.outcome, .none)
        XCTAssertTrue(coordinator.remoteCounts.isEmpty)
    }

    private func makeCoordinator(
        historyWorker: @escaping HistorySyncCoordinator.HistoryWorker
    ) -> HistorySyncCoordinator {
        HistorySyncCoordinator(
            isLoggedIn: { true },
            historyWorker: historyWorker,
            imageWorker: { _ in .init(total: 0, completed: 0, failed: 0) })
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("等待异步状态超时", file: file, line: line)
    }
}
