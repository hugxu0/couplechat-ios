import Foundation
import XCTest
@testable import CoupleChat

@MainActor
final class SharedStorePendingWriteTests: XCTestCase {
    func testOfflineStatusWriteSurvivesStoreRecreation() {
        let suiteName = "SharedStorePendingWriteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let session = Session(token: "token", username: "xu", name: "小旭")

        let first = SharedStore(defaults: defaults)
        first.activate(username: session.username)
        first.setShared("chat_statuses", value: ["xu": "想你"], session: session)

        let restored = SharedStore(defaults: defaults)
        restored.activate(username: session.username)

        XCTAssertEqual(restored.sharedValue("chat_statuses")?["xu"] as? String, "想你")
    }
}
