import XCTest
import UIKit

final class ComposerKeyboardTests: XCTestCase {
    override func tearDown() { XCUIDevice.shared.orientation = .portrait; super.tearDown() }

    func testPortraitComposerSendsWithoutDismissingKeyboard() { exerciseComposer(orientation: .portrait) }
    func testLandscapeComposerSendsWithoutDismissingKeyboard() { exerciseComposer(orientation: .landscapeLeft) }

    private func exerciseComposer(orientation: UIDeviceOrientation) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = ["-LBFixtures"]
        app.launch()
        let draft = app.descendants(matching: .any).matching(identifier: "Unsent message draft").firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout: 15))
        draft.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        draft.typeText("K")
        XCTAssertTrue(app.buttons["Send"].waitForExistence(timeout: 5), "The first character changes Voice chat into Send")
        draft.typeText("eyboard-up short message")
        XCTAssertEqual(draft.value as? String, "Keyboard-up short message")
        assertComposerAboveKeyboard(app, draft: draft)
        XCTAssertTrue(app.staticTexts["Preview only. Opening this card authorizes no calendar change."].isHittable,
                      "Opening the keyboard must keep the latest transcript content visible")
        capture("short")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts["Keyboard-up short message"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Sending must not resign the composer")

        // Both soft Return and hardware Shift+Return are newlines on iOS; neither submits.
        draft.typeText("First line for Lisbon")
        let returnKey = app.keyboards.buttons["Return"]
        XCTAssertTrue(returnKey.exists, "The multiline composer must not advertise a Send return key")
        returnKey.tap()
        draft.typeText("Second line with hotel options. Compare flights and keep conference follow-ups flagged. Include a day trip to Sintra and leave time for dinner. Nothing should be booked without review.")
        let value = draft.value as? String ?? ""
        XCTAssertTrue(value.contains("First line for Lisbon\nSecond line"), value)
        assertComposerAboveKeyboard(app, draft: draft)
        capture("multiline")
        app.buttons["Send"].tap()
        let posted = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Second line with hotel options")).firstMatch
        XCTAssertTrue(posted.waitForExistence(timeout: 5))
        XCTAssertTrue(posted.isHittable, "The transcript must follow the sent message above the composer")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertFalse(app.staticTexts["This fixture workspace is read-only."].exists)
        capture("sent")
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let startY = (app.navigationBars.firstMatch.frame.maxY + draft.frame.minY) / 2
        let start = origin.withOffset(CGVector(dx: app.frame.midX, dy: startY))
        let end = origin.withOffset(CGVector(dx: app.frame.midX, dy: app.frame.maxY - 10))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "Transcript dragging should dismiss the keyboard interactively")
        capture("dismissed")
        if orientation == .landscapeLeft {
            app.buttons["Add attachment, reference or delivery option"].tap()
            let details = app.buttons["Last send details"]
            XCTAssertTrue(details.waitForExistence(timeout: 5))
            details.tap()
            XCTAssertTrue(app.staticTexts["Last send details"].waitForExistence(timeout: 5))
            app.buttons["Close"].tap()
            draft.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        }
    }

    private func assertComposerAboveKeyboard(_ app: XCUIApplication, draft: XCUIElement) {
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        let send = app.buttons["Send"]
        XCTAssertTrue(send.isHittable)
        for label in ["Send", "Dictate", "Add attachment, reference or delivery option"] {
            // iOS also exposes a keyboard Dictate button with identifier "dictation".
            let button = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", label, "dictation")).firstMatch
            XCTAssertGreaterThanOrEqual(button.frame.width, 44, "\(label) touch width")
            XCTAssertGreaterThanOrEqual(button.frame.height, 44, "\(label) touch height")
        }
        XCTAssertLessThanOrEqual(send.frame.maxY, keyboard.frame.minY)
        XCTAssertLessThanOrEqual(draft.frame.maxY, keyboard.frame.minY)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
