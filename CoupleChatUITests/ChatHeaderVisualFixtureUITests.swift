import XCTest

final class ChatHeaderVisualFixtureUITests: XCTestCase {
    func testHeaderFixtureMatrix() {
        let fixtures = [
            ("bright-light-online", "bright", "light", "online"),
            ("dark-dark-online", "dark", "dark", "online"),
            ("custom-light-connecting", "custom", "light", "connecting"),
            ("custom-dark-failed", "custom", "dark", "failed"),
            ("bright-light-ai-composing", "bright", "light", "aiComposing"),
        ]

        for fixture in fixtures {
            let app = XCUIApplication()
            app.launchArguments = [
                "--chat-header-fixture",
                "--fixture-wallpaper", fixture.1,
                "--fixture-appearance", fixture.2,
                "--fixture-status", fixture.3,
                "-AppleLanguages", "(zh-Hans)",
                "-AppleLocale", "zh_CN",
            ]
            app.launch()
            let fixtureRoot = app.descendants(matching: .any)["chat-header-visual-fixture"]
            XCTAssertTrue(fixtureRoot.waitForExistence(timeout: 5))

            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = fixture.0
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }

    func testNativeHeaderSpikeMatrix() {
        let fixtures = [
            ("native-bright-light-online", "bright", "light", "online"),
            ("native-dark-dark-online", "dark", "dark", "online"),
            ("native-custom-light-connecting", "custom", "light", "connecting"),
            ("native-custom-dark-failed", "custom", "dark", "failed"),
            ("native-bright-light-ai-composing", "bright", "light", "aiComposing"),
        ]

        for fixture in fixtures {
            let app = XCUIApplication()
            app.launchArguments = [
                "--chat-header-native-spike",
                "--fixture-wallpaper", fixture.1,
                "--fixture-appearance", fixture.2,
                "--fixture-status", fixture.3,
            ]
            app.launch()
            let fixtureRoot = app.descendants(matching: .any)["chat-native-header-spike"]
            XCTAssertTrue(fixtureRoot.waitForExistence(timeout: 5))

            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = fixture.0
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }
}
