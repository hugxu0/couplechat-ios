import XCTest
@testable import CoupleChat

final class ChatScrollStateTests: XCTestCase {
    func testInitialContentPositionsOnlyOnce() {
        var state = ChatScrollState()
        XCTAssertEqual(
            ChatScrollReducer.reduce(state: &state, event: .initialContent),
            [.scrollToLatest(animated: false)])
        XCTAssertEqual(
            ChatScrollReducer.reduce(state: &state, event: .initialContent),
            [.preservePosition])
    }

    func testIncomingMessagePreservesReadingPositionAwayFromBottom() {
        var state = ChatScrollState(isNearBottom: false, isAtLatestWindow: false)
        XCTAssertEqual(
            ChatScrollReducer.reduce(state: &state, event: .receivedMessage(isMine: false)),
            [.showJumpToLatest(true)])
        XCTAssertTrue(state.hasNewMessagesBelow)
        XCTAssertEqual(
            ChatScrollReducer.reduce(state: &state, event: .receivedMessage(isMine: true)),
            [.scrollToLatest(animated: true)])
        XCTAssertFalse(state.hasNewMessagesBelow)
    }

    func testIncomingMessageAtBottomOfHistoricalWindowDoesNotJumpToLatest() {
        var state = ChatScrollState(isNearBottom: true, isAtLatestWindow: false)
        XCTAssertEqual(
            ChatScrollReducer.reduce(state: &state, event: .receivedMessage(isMine: false)),
            [.showJumpToLatest(true)])
        XCTAssertTrue(state.hasNewMessagesBelow)
    }

    func testIncomingMessageAtLatestBottomContinuesFollowingLatest() {
        var state = ChatScrollState(isNearBottom: true, isAtLatestWindow: true)
        XCTAssertEqual(
            ChatScrollReducer.reduce(state: &state, event: .receivedMessage(isMine: false)),
            [.scrollToLatest(animated: true)])
        XCTAssertFalse(state.hasNewMessagesBelow)
    }

    func testReachingLatestBottomClearsNewMessageStatus() {
        var state = ChatScrollState(
            isNearBottom: false,
            isAtLatestWindow: true,
            hasNewMessagesBelow: true)
        XCTAssertEqual(
            ChatScrollReducer.reduce(
                state: &state,
                event: .userScrolled(isNearBottom: true, isAtLatestWindow: true)),
            [.showJumpToLatest(false)])
        XCTAssertFalse(state.hasNewMessagesBelow)
    }

    func testLoadedOlderPreservesAnchor() {
        var state = ChatScrollState(isLoadingOlder: true)
        XCTAssertEqual(
            ChatScrollReducer.reduce(state: &state, event: .loadedOlder),
            [.preserveAnchor])
        XCTAssertFalse(state.isLoadingOlder)
    }
}
