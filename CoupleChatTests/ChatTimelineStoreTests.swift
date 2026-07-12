import Combine
import XCTest
@testable import CoupleChat

@MainActor
final class ChatTimelineStoreTests: XCTestCase {
    func testUpdatingMessagesPublishesToDirectObservers() {
        let store = ChatTimelineStore()
        let published = expectation(description: "timeline update published")
        var cancellable: AnyCancellable?
        cancellable = store.$messagesByChannel
            .dropFirst()
            .sink { channels in
                XCTAssertEqual(channels[ChatChannel.couple.rawValue]?.last?.id, "timeline-message")
                published.fulfill()
            }

        store.updateMessages(.couple) { messages in
            messages.append(ChatMessage(dict: [
                "id": "timeline-message",
                "sender": "si",
                "senderName": "小偲",
                "kind": "user",
                "type": "text",
                "text": "hello",
                "channel": "couple",
                "ts": 1_710_000_000_000,
            ])!)
        }

        wait(for: [published], timeout: 1)
        withExtendedLifetime(cancellable) {}
    }
}
