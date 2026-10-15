import AppKit
import SwiftUI

/// Receives keys only while this explicitly activated control is first responder.
struct MacShortcutRecorder: NSViewRepresentable {
    let label: String
    @Binding var shortcut: String
    let recordingChanged: (Bool) -> Void

    func makeNSView(context: Context) -> RecorderButton { RecorderButton() }
    func updateNSView(_ button: RecorderButton, context: Context) {
        button.label = label
        button.value = shortcut
        button.changed = { shortcut = $0 }
        button.recordingChanged = recordingChanged
        button.refreshTitle()
    }
    static func dismantleNSView(_ button: RecorderButton, coordinator: ()) { button.finish() }

    static func display(_ shortcut: String) -> String {
        let parts = shortcut.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last else { return "" }
        let modifiers = [("control", "⌃"), ("option", "⌥"), ("shift", "⇧"), ("command", "⌘")]
        let symbols = modifiers.filter { parts.dropLast().contains($0.0) }.map(\.1).joined()
        let names = ["space": "Space", "return": "↩", "tab": "⇥", "escape": "⎋"]
        return symbols + (names[key] ?? key.uppercased())
    }

    final class RecorderButton: NSButton {
        var label = ""
        var value = ""
        var changed: ((String) -> Void)?
        var recordingChanged: ((Bool) -> Void)?
        private var recording = false
        override var acceptsFirstResponder: Bool { true }

        init() {
            super.init(frame: .zero)
            bezelStyle = .rounded
            target = self
            action = #selector(start)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func refreshTitle() {
            title = recording ? "Type shortcut…" : (value.isEmpty ? "Record Shortcut" : MacShortcutRecorder.display(value))
            setAccessibilityLabel(label)
            setAccessibilityValue(recording ? "Recording shortcut" : (value.isEmpty ? "Off" : value))
            setAccessibilityHelp("Press to record. Escape cancels; Delete clears.")
        }
        @objc private func start() {
            guard window?.makeFirstResponder(self) == true else { return }
            recording = true
            recordingChanged?(true)
            refreshTitle()
        }
        func finish() {
            guard recording else { return }
            recording = false
            recordingChanged?(false)
            refreshTitle()
        }
        override func resignFirstResponder() -> Bool { finish(); return super.resignFirstResponder() }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard recording else { return super.performKeyEquivalent(with: event) }
            keyDown(with: event)
            return true
        }
        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            if event.keyCode == 53 { finish(); return }
            if event.keyCode == 51 || event.keyCode == 117 { changed?(""); value = ""; finish(); return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard let key = MacGlobalHotkeys.keys.first(where: { $0.value == UInt32(event.keyCode) })?.key else {
                NSSound.beep(); return
            }
            let modifiers: [(NSEvent.ModifierFlags, String)] = [(.control, "control"), (.option, "option"), (.shift, "shift"), (.command, "command")]
            let candidate = (modifiers.compactMap { flags.contains($0.0) ? $0.1 : nil } + [key]).joined(separator: "+")
            do {
                _ = try MacGlobalHotkeys.parse(candidate)
                value = candidate
                changed?(candidate)
                finish()
            } catch {
                title = "Use Command, Control or Option"
                setAccessibilityValue("Use Command, Control or Option with a supported key")
                NSSound.beep()
            }
        }
    }
}
