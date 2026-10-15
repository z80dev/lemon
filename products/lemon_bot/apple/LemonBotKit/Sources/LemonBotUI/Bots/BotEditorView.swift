import SwiftUI
import LemonBotKit
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct BotEditorView: View {
    let store: LemonBotStore
    let bot: Bot?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var title: String
    @State private var job: String
    @State private var instructions: String
    @State private var machineID: ID
    @State private var shape: String
    @State private var color: String
    @State private var avatarID: ID?
    @State private var voiceID: String
    @State private var speed: Double
    @State private var voiceLanguage: String
    @State private var language: String
    @State private var consent = false
    @State private var notify: Bool
    @State private var references: [ID]
    @State private var avatarPicker = false
    @State private var referencePicker = false
    @State private var selectedImage: Image?
    @State private var imageScale = 1.0
    @State private var imageX = 0.0
    @State private var imageY = 0.0
    @State private var generatedPrompt = ""
    @State private var currentRevision: Int
    @State private var action = UIActionState()
    init(store: LemonBotStore, bot: Bot? = nil) {
        self.store = store; self.bot = bot
        _name = State(initialValue: bot?.name ?? "")
        _title = State(initialValue: bot?.title ?? "")
        _job = State(initialValue: bot?.job ?? "")
        _instructions = State(initialValue: bot?.instructions ?? "")
        _machineID = State(initialValue: bot?.machineId ?? "")
        _shape = State(initialValue: bot?.avatar.shape ?? "round")
        _color = State(initialValue: bot?.avatar.color ?? "yellow")
        _avatarID = State(initialValue: bot?.avatar.attachmentId)
        _voiceID = State(initialValue: bot?.voice.voiceId ?? "default")
        _speed = State(initialValue: bot?.voice.speed ?? 1)
        _voiceLanguage = State(initialValue: bot?.voice.language ?? "")
        _language = State(initialValue: bot?.language ?? "")
        _notify = State(initialValue: bot?.sidebar.notificationsEnabled ?? true)
        _references = State(initialValue: bot?.referenceAttachmentIds ?? [])
        _currentRevision = State(initialValue: bot?.revision ?? 1)
    }
    var body: some View {
        NavigationStack {
            Form {
                SwiftUI.Section("Identity") {
                    TextField("Name", text: $name)
                    TextField("Title / label", text: $title)
                    if bot == nil {
                        Menu("Suggested focused roles") {
                            Button("Finance") { name = "Finance"; title = "Expense analyst"; job = "Reconcile weekly expenses against source records and prepare reviewed drafts."; instructions = "Cite sources, separate facts from inference, ask before financial or outward changes." }
                            Button("Engineering") { name = "Engineering"; title = "Investigation teammate"; job = "Investigate bugs with reproducible steps, logs and evidence."; instructions = "Do not modify production or contact customers without explicit approval." }
                            Button("Chief of staff") { name = "Chief of staff"; title = "Office teammate"; job = "Prepare source-linked status summaries and useful reviewed follow-ups."; instructions = "Keep private information scoped; prepare drafts before outward communication." }
                        }
                        NavigationLink("Review a workspace or third-party template instead") { TemplateHubView(store: store) }
                        Picker("Machine", selection: $machineID) { Text("Choose an online machine").tag(""); ForEach(store.machines.filter { $0.status == "online" }) { machine in Text(machine.name).tag(machine.id) } }
                        if !store.machines.contains(where: { $0.status == "online" }) {
                            Text("No machine is online. Start one of your machines, then come back.").font(LBFont.meta).foregroundStyle(LB.warning)
                        }
                        Toggle("I trust this host and accept shared files, browser logins and CLI credentials", isOn: $consent)
                        Text("Bots on one OS user are not isolated. Use separate hosts/users for hard isolation.").font(LBFont.meta)
                    }
                }
                SwiftUI.Section("Avatar") {
                    Picker("Character shape", selection: $shape) { Text("Round").tag("round"); Text("Square").tag("square"); Text("Star").tag("star") }
                    Picker("Character color", selection: $color) { ForEach(["yellow", "blue", "green", "purple", "orange", "red"], id: \.self) { value in Text(value.capitalized).tag(value) } }
                    Button("Use character avatar") { avatarID = nil; selectedImage = nil }
                    Button("Choose image and crop") { avatarPicker = true }
                    if let selectedImage {
                        croppedImage(selectedImage)
                        Slider(value: $imageScale, in: 1...4) { Text("Crop zoom") }
                        Slider(value: $imageX, in: -128...128) { Text("Crop horizontal position") }
                        Slider(value: $imageY, in: -128...128) { Text("Crop vertical position") }
                        Button("Upload cropped avatar") { Task { await cropAndUpload(selectedImage) } }.disabled(action.busy || store.connectionState != "online")
                    }
                    if let avatarID { AttachmentView(store: store, attachmentID: avatarID) }
                    TextField("Image generation prompt", text: $generatedPrompt)
                    Button("Generate with configured image provider") { Task { await generate() } }.disabled(action.busy || bot == nil || generatedPrompt.isEmpty || store.connectionState != "online")
                    Text("Generation returns an unattached real image. Crop or explicitly save it as the Bot avatar; missing provider prerequisite is shown exactly.").font(LBFont.meta)
                }
                if bot == nil {
                    SwiftUI.Section("Focused Job") {
                        TextField("Job", text: $job, axis: .vertical).lineLimit(3...10)
                        TextField("Standing instructions and boundaries", text: $instructions, axis: .vertical).lineLimit(4...12)
                    }
                }
                SwiftUI.Section("Voice and language") {
                    ProviderVoicePicker(store: store, voiceID: $voiceID, language: $voiceLanguage)
                    Slider(value: $speed, in: 0.5...2, step: 0.1) { Text("Speed") }
                    Text("Speed: \(speed, specifier: "%.1f")×")
                    TextField("Voice language (optional, e.g. en-US)", text: $voiceLanguage)
                    TextField("Reply language (blank for automatic)", text: $language)
                    Text("Voice and language changes are saved to this Bot's history. You can undo them under Preferences history.").font(LBFont.meta)
                }
                if bot != nil {
                    SwiftUI.Section("Reference files") {
                        ForEach(references, id: \.self) { id in HStack { AttachmentView(store: store, attachmentID: id); Button("Remove reference") { references.removeAll { $0 == id } } } }
                        Button("Choose reference files") { referencePicker = true }
                    }
                    SwiftUI.Section("Your notification preference") { Toggle("Notifications for this Bot", isOn: $notify) }
                }
                ActionErrorView(message: action.error)
                if let receipt = action.receipt { Text(receipt).font(LBFont.meta) }
                Button(bot == nil ? "Create Bot" : "Save changes") { Task { await save() } }.disabled(action.busy || name.isEmpty || store.connectionState != "online" || (bot == nil && (machineID.isEmpty || !consent)))
                if store.connectionState != "online" { Text("Reconnect to save changes.").font(LBFont.meta).foregroundStyle(LB.muted) }
                else if name.isEmpty { Text("Add a name to save.").font(LBFont.meta).foregroundStyle(LB.muted) }
                else if bot == nil && (machineID.isEmpty || !consent) { Text("Choose an online machine and accept its shared files and logins to create this Bot.").font(LBFont.meta).foregroundStyle(LB.muted) }
            }.formStyle(.grouped).navigationTitle(bot == nil ? "New Bot" : "Edit \(bot!.name)")
                .toolbar { Button("Cancel") { dismiss() } }
                .fileImporter(isPresented: $avatarPicker, allowedContentTypes: [.image]) { result in
                    switch result { case .success(let url): loadImage(url); case .failure(let error): action.error = String(describing: error) }
                }
                .fileImporter(isPresented: $referencePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                    switch result { case .success(let urls): Task { await uploadReferences(urls) }; case .failure(let error): action.error = String(describing: error) }
                }
        }.frame(minWidth: 340, minHeight: 560)
    }
    private func croppedImage(_ image: Image) -> some View { image.resizable().scaledToFill().scaleEffect(imageScale).offset(x: imageX, y: imageY).frame(width: 256, height: 256).clipped().accessibilityLabel("Reviewed avatar crop") }
    private func loadImage(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        guard let native = NSImage(contentsOf: url) else { action.error = "Image decoding failed; choose a supported image."; return }
        selectedImage = Image(nsImage: native)
        #else
        guard let native = UIImage(contentsOfFile: url.path) else { action.error = "Image decoding failed; choose a supported image."; return }
        selectedImage = Image(uiImage: native)
        #endif
        imageScale = 1; imageX = 0; imageY = 0
    }
    private func cropAndUpload(_ image: Image) async {
        await action.perform {
            let renderer = ImageRenderer(content: croppedImage(image)); renderer.scale = 2
            guard let cg = renderer.cgImage else { throw BotEditError.message("Avatar crop rendering failed.") }
            #if os(macOS)
            guard let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { throw BotEditError.message("PNG encoding failed.") }
            #else
            guard let data = UIImage(cgImage: cg).pngData() else { throw BotEditError.message("PNG encoding failed.") }
            #endif
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
            try data.write(to: url, options: .atomic)
            defer { try? FileManager.default.removeItem(at: url) }
            var metadata: JSONObject = ["purpose": .string("avatar")]
            if let bot { metadata["botId"] = .string(bot.id) }
            let attachment = try await store.upload(fileURL: url, mime: "image/png", metadata: metadata)
            avatarID = attachment.id; selectedImage = nil
        }
    }
    private func generate() async {
        await action.perform {
            guard let bot else { return }
            let image: Attachment = try await store.mutate("POST", resourcePath("bots", bot.id, "/avatar/generate"), body: ["prompt": .string(generatedPrompt)])
            let url = try await store.download(attachmentID: image.id)
            avatarID = image.id
            loadImage(url)
        }
    }
    private func uploadReferences(_ urls: [URL]) async {
        await action.perform {
            guard let bot else { return }
            for url in urls {
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let attachment = try await store.upload(fileURL: url, mime: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream", metadata: ["botId": .string(bot.id), "purpose": .string("reference")])
                references.append(attachment.id)
            }
        }
    }
    private func save() async {
        await action.perform {
            let avatar: JSONObject = ["kind": .string(avatarID == nil ? "character" : "image"), "shape": .string(shape), "color": .string(color), "attachmentId": avatarID.map(JSONValue.string) ?? .null]
            let voice: JSONObject = ["voiceId": .string(voiceID), "speed": .number(speed), "language": voiceLanguage.isEmpty ? .null : .string(voiceLanguage)]
            var body: JSONObject = ["name": .string(name), "title": .string(title), "avatar": .object(avatar)]
            let result: Bot
            if let bot {
                body["revision"] = .number(Double(currentRevision)); body["referenceAttachmentIds"] = strings(references)
                result = try await store.mutate("PATCH", resourcePath("bots", bot.id), body: body)
                currentRevision = result.revision
                if bot.voice.voiceId != voiceID || bot.voice.speed != speed || (bot.voice.language ?? "") != voiceLanguage {
                    let change: PreferenceChange = try await store.mutate("POST", resourcePath("bots", bot.id, "/preference-changes"), body: ["revision": .number(Double(currentRevision)), "changes": .object(["voice": .object(voice)]), "reason": .string("Manual voice settings edit")])
                    currentRevision = change.resultingBotRevision
                }
                if (bot.language ?? "") != language {
                    let change: PreferenceChange = try await store.mutate("POST", resourcePath("bots", bot.id, "/preference-changes"), body: ["revision": .number(Double(currentRevision)), "changes": .object(["language": language.isEmpty ? .null : .string(language)]), "reason": .string("Manual reply language edit")])
                    currentRevision = change.resultingBotRevision
                }
                let _: Bot = try await store.mutate("PATCH", resourcePath("bots", bot.id, "/sidebar"), body: ["revision": .number(Double(currentRevision)), "notificationsEnabled": .bool(notify)])
            } else {
                body["machineId"] = .string(machineID); body["job"] = .string(job); body["instructions"] = .string(instructions); body["voice"] = .object(voice); body["language"] = language.isEmpty ? .null : .string(language)
                result = try await store.mutate("POST", "/bots", body: body)
            }
            try await store.refresh()
            store.selectedConversationID = result.mainConversationId
            dismiss()
        }
    }
}
private enum BotEditError: LocalizedError { case message(String); var errorDescription: String? { if case .message(let value) = self { return value }; return nil } }
