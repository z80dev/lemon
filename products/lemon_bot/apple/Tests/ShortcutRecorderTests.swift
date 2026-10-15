import AppKit
import XCTest

@MainActor
final class ShortcutRecorderTests: XCTestCase {
    func testRecordingCaptureCancelClearAndFocusLoss() throws {
        _ = NSApplication.shared
        let button = MacShortcutRecorder.RecorderButton()
        button.label = "Quick composer shortcut"
        button.value = "control+option+space"
        var changes: [String] = []
        var recording: [Bool] = []
        button.changed = { changes.append($0) }
        button.recordingChanged = { recording.append($0) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = button
        defer { window.contentView = nil; window.close() }
        func press(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
            XCTAssertTrue(button.performKeyEquivalent(with: event))
        }
        button.performClick(nil)
        XCTAssertEqual(button.title, "Type shortcut…")
        try capture(button, name: "recording")
        try press(0) // Bare keys cannot become global shortcuts.
        XCTAssertTrue(changes.isEmpty)
        try press(49, [.control, .option])
        XCTAssertEqual(button.title, "⌃⌥Space")
        try capture(button, name: "assigned")
        XCTAssertEqual(changes, ["control+option+space"])
        XCTAssertEqual(recording, [true, false])
        button.performClick(nil)
        try press(53)
        XCTAssertEqual(changes.count, 1)
        button.performClick(nil)
        try press(51)
        XCTAssertEqual(changes.last, "")
        XCTAssertEqual(button.title, "Record Shortcut")
        button.performClick(nil)
        _ = window.makeFirstResponder(nil)
        XCTAssertEqual(recording, [true, false, true, false, true, false, true, false])
    }

    private func capture(_ button: NSButton, name: String) throws {
        button.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
        button.cacheDisplay(in: button.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/lemonbot3-shortcut-\(name).png"))
    }

    func testNativeDisplayKeepsCanonicalModifierOrderAndKeyNames() {
        XCTAssertEqual(MacShortcutRecorder.display("command+shift+option+control+a"), "⌃⌥⇧⌘A")
        XCTAssertEqual(MacShortcutRecorder.display("command+return"), "⌘↩")
        XCTAssertEqual(MacShortcutRecorder.display("control+tab"), "⌃⇥")
        XCTAssertEqual(MacShortcutRecorder.display("option+escape"), "⌥⎋")
        XCTAssertEqual(MacShortcutRecorder.display("command+shift+f8"), "⇧⌘F8")
    }

    func testEveryRecordableKeyParsesAndModifiersAreRequired() throws {
        for (key, code) in MacGlobalHotkeys.keys {
            XCTAssertEqual(try MacGlobalHotkeys.parse("control+option+" + key).0, code)
        }
        XCTAssertThrowsError(try MacGlobalHotkeys.parse("shift+a"))
        XCTAssertThrowsError(try MacGlobalHotkeys.parse("command+command+a"))
    }
}
