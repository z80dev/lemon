import XCTest

final class ProviderVoicePickerTests: XCTestCase {
    func testProviderChoicesAreNamedAndSelectionIsExplicit() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-LBFixtures", "-LBRenderScene", "composer-polish"]
        app.launch()
        let voice = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Alloy")).firstMatch
        XCTAssertTrue(voice.waitForExistence(timeout: 15))
        voice.tap()
        let coral = app.buttons["Coral"]
        XCTAssertTrue(coral.waitForExistence(timeout: 5))
        coral.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Coral")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["OpenAI · Built-in voices"].exists)
        XCTAssertTrue(app.staticTexts["and 3 more"].exists || app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "and 3 more")).firstMatch.exists)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Provider voice selection"; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
