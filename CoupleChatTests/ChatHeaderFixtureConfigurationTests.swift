#if DEBUG
import XCTest
@testable import CoupleChat

final class ChatHeaderFixtureConfigurationTests: XCTestCase {
    func testFixtureRequiresExplicitLaunchFlag() {
        XCTAssertNil(ChatHeaderVisualFixtureConfiguration.fromProcessArguments([]))
    }

    func testFixtureParsesAllArguments() {
        let configuration = ChatHeaderVisualFixtureConfiguration.fromProcessArguments([
            "--chat-header-fixture",
            "--fixture-wallpaper", "custom",
            "--fixture-appearance", "dark",
            "--fixture-status", "failed",
        ])

        XCTAssertEqual(configuration?.wallpaper, .custom)
        XCTAssertEqual(configuration?.appearance, .dark)
        XCTAssertEqual(configuration?.connection, .failed)
    }

    func testFixtureUsesStableDefaults() {
        let configuration = ChatHeaderVisualFixtureConfiguration.fromProcessArguments([
            "--chat-header-fixture",
        ])

        XCTAssertEqual(configuration?.wallpaper, .bright)
        XCTAssertEqual(configuration?.appearance, .light)
        XCTAssertEqual(configuration?.connection, .online)
    }
}
#endif
