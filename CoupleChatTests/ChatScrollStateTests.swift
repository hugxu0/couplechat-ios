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
        XCTAssertEqual(
            ChatScrollReducer.reduce(state: &state, event: .receivedMessage(isMine: true)),
            [.scrollToLatest(animated: true)])
    }

    func testLoadedOlderPreservesAnchor() {
        var state = ChatScrollState(isLoadingOlder: true)
        XCTAssertEqual(
            ChatScrollReducer.reduce(state: &state, event: .loadedOlder),
            [.preserveAnchor])
        XCTAssertFalse(state.isLoadingOlder)
    }
}
