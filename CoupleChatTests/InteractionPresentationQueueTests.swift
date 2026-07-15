import XCTest
@testable import CoupleChat

@MainActor
final class InteractionPresentationQueueTests: XCTestCase {
    func testPresentationQueueKeepsOrderAndDeduplicatesIDs() {
        let store = ChatStore()
        let first = presentation(id: "first", kind: .miss)
        let second = presentation(id: "second", kind: .flower)

        store.queueInteractionPresentation(first)
        store.queueInteractionPresentation(first)
        store.queueInteractionPresentation(second)

        XCTAssertEqual(store.takeNextInteractionPresentation()?.id, "first")
        XCTAssertEqual(store.takeNextInteractionPresentation()?.id, "second")
        XCTAssertNil(store.takeNextInteractionPresentation())
    }

    private func presentation(id: String, kind: InteractionEffectKind) -> InteractionPresentation {
        InteractionPresentation(
            payload: InteractionPayload(id: id, kind: kind, text: "test"),
            senderName: "TA",
            duration: 1)
    }
}
