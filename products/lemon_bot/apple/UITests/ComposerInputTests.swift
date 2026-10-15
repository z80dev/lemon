import XCTest
import SwiftUI
import UIKit
@testable import LemonBotUI

@MainActor
final class ComposerInputTests: XCTestCase {
    func testLayoutDoesNotOverwritePendingNativeKeystrokes() {
        var draft = "Key"
        let input = IOSComposerInput(text: Binding(get: { draft }, set: { draft = $0 }), focused: .constant(true), maximumLines: 8)
        let coordinator = input.makeCoordinator()
        let view = UITextView()
        view.text = "Keyb"

        // SwiftUI can lay out the previous draft before UIKit reports the just-inserted character.
        coordinator.updateText(draft, in: view)
        XCTAssertEqual(view.text, "Keyb")
        coordinator.textViewDidChange(view)
        XCTAssertEqual(draft, "Keyb")

        // An external edit or successful-send clear must still update the native editor.
        draft = "Dictated text\nSecond line"
        coordinator.updateText(draft, in: view)
        XCTAssertEqual(view.text, draft)
        draft = ""
        coordinator.updateText(draft, in: view)
        XCTAssertEqual(view.text, "")
    }
}
