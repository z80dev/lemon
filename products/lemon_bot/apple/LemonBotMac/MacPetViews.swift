import AppKit
import LemonBotKit
import LemonBotUI
import SwiftUI

struct MacPetBubble: View {
    let text: String?
    var body: some View {
        if let text { PetBubbleView(text: text) }
    }
}

@MainActor
final class MacPetContentView: NSView {
    weak var controller: MacPetController?
    let spriteView = NSView()
    let bubble = NSHostingView(rootView: MacPetBubble(text: nil))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        spriteView.wantsLayer = true
        spriteView.layer?.magnificationFilter = .nearest
        spriteView.layer?.minificationFilter = .nearest
        spriteView.layer?.contentsGravity = .resize
        addSubview(spriteView)
        addSubview(bubble)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Lemon Bot desktop pet")
        setAccessibilityHelp("Open Lemon Bot. Drag to move; right-click for pet settings.")
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let controller else { return nil }
        return controller.hitsSprite(point) || controller.hitsBubble(point) ? self : nil
    }
    override func mouseDown(with event: NSEvent) { controller?.mouseDown() }
    override func mouseDragged(with event: NSEvent) { controller?.mouseDragged() }
    override func mouseUp(with event: NSEvent) { controller?.mouseUp() }
    override func rightMouseDown(with event: NSEvent) { controller?.contextMenu(event) }
    override func accessibilityPerformPress() -> Bool { controller?.activate(); return true }
}

struct MacPetSettingsSection: View {
    @Bindable var controller: MacPetController
    @State private var showingURL = false
    @State private var remoteURL = ""
    @State private var confirmingRemoval = false

    var body: some View {
        Section("Desktop pet") {
            Toggle("Show desktop pet", isOn: preference(\.enabled))
            Picker("Pet", selection: preference(\.petID)) {
                ForEach(controller.pets) { pet in
                    HStack(spacing: 8) {
                        if let frame = controller.thumbnails[pet.id] { Image(nsImage: frame).interpolation(.none) }
                        Text(pet.manifest.displayName)
                    }.tag(pet.id)
                }
            }
            Picker("Size", selection: preference(\.size)) {
                ForEach(MacPetPreferences.Size.allCases, id: \.self) { size in Text(size.label).tag(size) }
            }
            Toggle("Play sounds", isOn: preference(\.soundEnabled))
            HStack {
                Button("Import pet…") { controller.importPet() }
                Button("Import from URL…") { showingURL.toggle() }
                if controller.pets.contains(where: { $0.id == controller.preferences.petID && !$0.isBuiltIn }) {
                    Button("Remove", role: .destructive) { confirmingRemoval = true }
                }
                Spacer()
                Button("Reset position") { controller.resetPosition() }
            }
            .disabled(controller.importing)
            if showingURL {
                HStack {
                    TextField("https://example.com/pet.zip", text: $remoteURL)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Pet package HTTPS URL")
                        .onSubmit { importRemote() }
                    Button(controller.importing ? "Importing…" : "Import") { importRemote() }
                        .disabled(controller.importing || remoteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Text("Codex pets work too: import a pet folder or .zip. Pets are images only; nothing in a pet package runs.")
                .font(LBFont.meta).foregroundStyle(LB.muted)
            if let error = controller.errorMessage { Text(error).font(LBFont.meta).foregroundStyle(LB.danger).textSelection(.enabled) }
        }
        .onAppear { controller.settingsAppeared() }
        .confirmationDialog("Remove this imported pet?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove pet", role: .destructive) { controller.removeSelectedPet() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The built-in lemon will be selected. You can import this pet again later.")
        }
    }

    private func preference<Value>(_ path: WritableKeyPath<MacPetPreferences, Value>) -> Binding<Value> {
        Binding(get: { controller.preferences[keyPath: path] }, set: { value in controller.updatePreferences { $0[keyPath: path] = value } })
    }
    private func importRemote() {
        guard !controller.importing else { return }
        Task { await controller.importURL(remoteURL) }
    }
}
