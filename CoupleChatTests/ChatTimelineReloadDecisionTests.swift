import XCTest
@testable import CoupleChat

final class ChatTimelineReloadDecisionTests: XCTestCase {
    func testExplicitSendAlwaysForcesLatest() {
        let decision = decide(
            stickToLatest: true,
            pending: true,
            visible: true,
            nearBottom: false,
            lastChanged: false,
            countIncreased: false,
            showingAI: false
        )
        XCTAssertEqual(decision, .forceLatest)
    }

    func testPendingLoadAnchorTakesPriorityOverVisibleAnchor() {
        let decision = decide(
            pending: true,
            visible: true,
            nearBottom: false,
            lastChanged: true,
            countIncreased: true,
            showingAI: false
        )
        XCTAssertEqual(decision, .restorePendingAnchor)
    }

    func testReaderAwayFromBottomKeepsVisibleAnchor() {
        let decision = decide(
            pending: false,
            visible: true,
            nearBottom: false,
            lastChanged: true,
            countIncreased: true,
            showingAI: false
        )
        XCTAssertEqual(decision, .restoreVisibleAnchor)
    }

    func testInvalidPendingAnchorDoesNotFallThroughToDifferentVisibleAnchor() {
        let decision = decide(
            pendingExists: true,
            pending: false,
            visible: true,
            nearBottom: false,
            lastChanged: true,
            countIncreased: true,
            showingAI: false
        )
        XCTAssertEqual(decision, .preservePosition)
    }

    func testInvalidPendingAnchorStillFollowsNewContentWhenAtBottom() {
        let decision = decide(
            pendingExists: true,
            pending: false,
            visible: true,
            nearBottom: true,
            lastChanged: true,
            countIncreased: true,
            showingAI: false
        )
        XCTAssertEqual(decision, .followLatest)
    }

    func testReaderAtBottomFollowsNewMessage() {
        let decision = decide(
            pending: false,
            visible: true,
            nearBottom: true,
            lastChanged: true,
            countIncreased: true,
            showingAI: false
        )
        XCTAssertEqual(decision, .followLatest)
    }

    func testReplacingAIActivityAtBottomStillFollowsReply() {
        let decision = decide(
            pending: false,
            visible: false,
            nearBottom: true,
            lastChanged: true,
            countIncreased: false,
            showingAI: true
        )
        XCTAssertEqual(decision, .followLatest)
    }

    func testUnchangedTimelinePreservesPosition() {
        let decision = decide(
            pending: false,
            visible: false,
            nearBottom: true,
            lastChanged: false,
            countIncreased: false,
            showingAI: false
        )
        XCTAssertEqual(decision, .preservePosition)
    }

    private func decide(
        stickToLatest: Bool = false,
        pendingExists: Bool? = nil,
        pending: Bool,
        visible: Bool,
        nearBottom: Bool,
        lastChanged: Bool,
        countIncreased: Bool,
        showingAI: Bool
    ) -> ChatTimelineReloadDecision {
        ChatTimelineReloadDecision.decide(
            stickToLatest: stickToLatest,
            hasPendingAnchor: pendingExists ?? pending,
            hasValidPendingAnchor: pending,
            hasValidVisibleAnchor: visible,
            wasNearLatestBottom: nearBottom,
            lastMessageChanged: lastChanged,
            messageCountIncreased: countIncreased,
            wasShowingAIActivity: showingAI
        )
    }
}
