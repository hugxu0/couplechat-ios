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
}
