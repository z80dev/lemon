import AppKit
import LemonBotKit
import LemonBotUI
import SwiftUI

struct MacMiniComposer: View {
    @Bindable var controller: MacPlatformController
    let conversationID: ID
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacTargetLabel(controller: controller, conversationID: conversationID)
            Text("Only the text and files you explicitly choose are shared. Nothing is sent until Send.")
                .font(.caption).foregroundStyle(.secondary)
            ComposerView(store: controller.store, conversationID: conversationID, compact: true)
            HStack {
                Button("Choose files…") { controller.chooseFiles(conversationID: conversationID) }
                Button("Dictate…") { controller.beginDictation(conversationID: conversationID) }
                Button("Open conversation") {
                    Task { do { try await controller.store.openConversation(conversationID) } catch { controller.errorMessage = error.localizedDescription } }
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first { $0.identifier?.rawValue == "lemonbot.main" }?.makeKeyAndOrderFront(nil)
                }
            }
            if let error = controller.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }.padding().frame(minWidth: 440, minHeight: 280)
    }
}

struct MacTargetLabel: View {
    let controller: MacPlatformController
    let conversationID: ID?
    var body: some View {
        let room = controller.store.conversations.first { $0.id == conversationID }
        let bot = controller.store.bots.first { room?.botIds.contains($0.id) == true }
        let machine = controller.store.machines.first { $0.id == bot?.machineId }
        VStack(alignment: .leading, spacing: 4) {
            Text(bot?.name ?? room?.name ?? "Choose a conversation").font(.headline)
            Text("\(controller.store.account?.displayName ?? "Not signed in") · \(controller.store.workspace?.name ?? "") · \(machine?.name ?? "Unknown machine")")
                .font(.caption).foregroundStyle(.secondary)
            if let room { Text(room.name).font(.caption) }
        }
    }
}

struct MacCompanionView: View {
    @Bindable var controller: MacPlatformController
    let botID: ID
    var body: some View {
        if let bot = controller.store.bots.first(where: { $0.id == botID }) {
            VStack(alignment: .leading, spacing: 10) {
                MacTargetLabel(controller: controller, conversationID: bot.mainConversationId)
                Label(bot.activity.replacingOccurrences(of: "_", with: " ").capitalized, systemImage: bot.activity == "offline" ? "wifi.slash" : "circle.fill")
                Text("Status comes from your Bot’s latest backend state.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Compose") { controller.summon() }
                    Button("Overview") {
                        Task {
                            guard let workspace = controller.store.workspace else { return }
                            var components = URLComponents()
                            components.scheme = "lemonbot"
                            components.host = "workspace"
                            components.path = "/\(workspace.id)/bot/\(bot.id)"
                            if let url = components.url { await controller.route(url) }
                        }
                    }
                }
            }.padding().frame(minWidth: 290, minHeight: 150)
        } else { Text("The selected Bot is no longer available.").padding() }
    }
}

struct MacVoiceView: View {
    @Bindable var controller: MacPlatformController
    var body: some View {
        @Bindable var speech = controller.speech
        let session = controller.store.voiceSession
        let active = session?.state == "active"
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            MacTargetLabel(controller: controller, conversationID: controller.captureConversationID ?? session?.conversationId)
            Label(speech.state == .recording ? "Microphone on — explicitly capturing your voice" : "Microphone off", systemImage: speech.state == .recording ? "mic.fill" : "mic.slash")
                .foregroundStyle(speech.state == .recording ? Color.red : Color.secondary)
                .accessibilityLabel(speech.state == .recording ? "Microphone on" : "Microphone off")
            if active, let session {
                Text("Active voice chat · \(session.muted ? "Muted" : "Ready") · \(session.durationMs / 1000) seconds")
                HStack {
                    Button(session.muted ? "Unmute" : "Mute") { Task { await controller.updateCall(muted: !session.muted) } }
                    Button("Return to chat") {
                        Task { do { try await controller.store.openConversation(session.conversationId) } catch { controller.errorMessage = error.localizedDescription } }
                        NSApp.windows.first { $0.identifier?.rawValue == "lemonbot.main" }?.makeKeyAndOrderFront(nil)
                    }
                    Button("End voice chat", role: .destructive) { Task { await controller.endCall() } }
                }.disabled(!controller.online || controller.busy)
                DisclosureGroup("Voice transcript") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(controller.store.entries[session.conversationId] ?? []) { entry in
                                if let text = entry.text, entry.kind == "message" {
                                    Text("\(entry.actor.displayName): \(text)").textSelection(.enabled)
                                }
                            }
                        }
                    }.frame(maxHeight: 130)
                }
                HStack {
                    Button("Good call") { Task { await controller.updateCall(feedback: "good") } }
                    Button("Bad call") { Task { await controller.updateCall(feedback: "bad") } }
                }.disabled(!controller.online || controller.busy)
                if var settings = controller.voiceSettings {
                    HStack {
                        Text("Speech speed")
                        Slider(value: Binding(get: { controller.voiceSettings?.speed ?? settings.speed }, set: { value in
                            settings.speed = value
                            controller.voiceSettings = settings
                        }), in: 0.5...2)
                        Text(String(format: "%.1f×", controller.voiceSettings?.speed ?? settings.speed))
                    }
                    TextField("Voice identifier", text: Binding(get: { controller.voiceSettings?.voiceId ?? "" }, set: { value in
                        settings.voiceId = value; controller.voiceSettings = settings
                    }))
                    TextField("Language (BCP-47; blank for automatic)", text: Binding(get: { controller.voiceSettings?.language ?? "" }, set: { value in
                        settings.language = value.isEmpty ? nil : value; controller.voiceSettings = settings
                    }))
                    Button("Apply voice settings") { Task { await controller.updateCall(settings: controller.voiceSettings) } }
                        .disabled(!controller.online || controller.busy)
                }
            }
            if speech.state == .requestingPermission || speech.state == .transcribing {
                ProgressView(speech.state == .requestingPermission ? "Waiting for microphone/Speech permission…" : "Finishing transcription…")
            }
            if speech.state == .recording {
                Button("Stop and review") { speech.release() }
            } else if speech.state == .idle {
                Button("Record utterance…") {
                    if let id = controller.captureConversationID ?? session?.conversationId { controller.beginDictation(conversationID: id) }
                }.disabled(active && (session?.muted == true))
                Text("Record explicitly, then Stop and review. The configured push-to-talk shortcut captures only while held. Escape discards.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if speech.state == .review {
                Text("Review and edit — nothing has been sent.").font(.headline)
                TextEditor(text: $speech.transcript).frame(minHeight: 110)
                if speech.needsBackendTranscription {
                    Button("Transcribe recorded audio with backend") { Task { await controller.transcribeRecording() } }
                        .disabled(!controller.online || controller.busy)
                    Text("This explicitly uploads this recording to your backend’s configured transcription provider.").font(.caption)
                }
                HStack {
                    Button("Keep as unsent draft") { controller.keepReviewedDraft() }
                        .disabled(speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.uncertainVoiceSend)
                    if active && controller.reviewForCall {
                        Button("Send reviewed utterance") { Task { await controller.sendReviewedVoice() } }
                            .disabled(!controller.online || controller.busy || session?.muted == true || speech.transcript.isEmpty || controller.uncertainVoiceSend)
                    }
                    Button("Discard", role: .cancel) { controller.cancelCapture() }
                }
            }
            if let text = controller.speechStatus { Text(text).font(.caption).textSelection(.enabled) }
            if let error = speech.errorMessage { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if let error = controller.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if controller.busy { ProgressView() }
            Button("Stop playback") { controller.stopPlayback() }
            }.padding()
        }.frame(minWidth: 500, minHeight: 360)
            .onExitCommand { controller.cancelCapture() }
    }
}

struct MacSettingsView: View {
    @Bindable var controller: MacPlatformController
    @State private var value = ClientLocalSettings(micCuesEnabled: true, compactCompanionEnabled: false, reducedMotion: "system")
    @State private var summon = ""
    @State private var ptt = ""
    var body: some View {
        Form {
            Section("Selected Bot and companion") {
                Picker("Bot", selection: $value.selectedBotId) {
                    Text("None").tag(String?.none)
                    ForEach(controller.store.bots) { bot in Text(bot.name).tag(Optional(bot.id)) }
                }
                Toggle("Show one compact selected-Bot companion", isOn: $value.compactCompanionEnabled)
            }
            Section("Explicit keyboard controls") {
                TextField("Global summon", text: $summon)
                TextField("Hold push-to-talk", text: $ptt)
                Text("Examples: control+option+space or command+shift+f8. Blank disables. Carbon registers only these combinations; no keyboard history is captured.").font(.caption)
                Toggle("Microphone on/off sounds", isOn: $value.micCuesEnabled)
                Picker("Reduced motion", selection: $value.reducedMotion) {
                    Text("Follow system").tag("system"); Text("On").tag("on"); Text("Off").tag("off")
                }
                Button("Save device-local settings") {
                    value.summonShortcut = summon.trimmingCharacters(in: .whitespaces).isEmpty ? nil : summon.trimmingCharacters(in: .whitespaces)
                    value.pushToTalkShortcut = ptt.trimmingCharacters(in: .whitespaces).isEmpty ? nil : ptt.trimmingCharacters(in: .whitespaces)
                    controller.saveSettings(value)
                }.disabled(controller.store.account == nil)
            }
            Section("Voice and notifications") {
                Picker("Microphone input", selection: Binding(get: { controller.speech.preferredInputUID }, set: { controller.speech.preferredInputUID = $0 })) {
                    Text("System default").tag(String?.none)
                    ForEach(controller.speech.inputDevices) { input in
                        Text(input.name).tag(Optional(input.id))
                    }
                }
                .disabled(controller.speech.state != .idle)
                Button("Refresh microphone inputs") { controller.speech.refreshInputDevices() }
                Button("Play real backend Bot voice sample") { if let id = value.selectedBotId { Task { await controller.previewVoice(botID: id) } } }
                    .disabled(value.selectedBotId == nil || !controller.online || controller.busy)
                Text("The fixed sample does not create a chat or run. Backend provider failures display their actual prerequisites; persisted voice memos are played from their authorized audio attachments in chat.").font(.caption)
                Button("Enable macOS notifications…") { Task { await controller.requestNotifications() } }
                if let status = controller.speechStatus { Text(status).font(.caption) }
            }
            Section("Privacy") {
                Text("No ambient listening, clipboard history, screen capture, or desktop streaming. To share selected content from another app, explicitly choose Services → Send selection to Lemon Bot; review it in the mini-composer. Choose files only through the file picker. Hotkeys and companion are disabled by default and stored for this device/account.")
                    .font(.caption)
            }
            if let error = controller.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }.formStyle(.grouped).frame(width: 590, height: 680)
            .onAppear { load(); controller.speech.refreshInputDevices() }
            .onChange(of: controller.settings) { _, _ in load() }
    }
    private func load() { value = controller.settings; summon = value.summonShortcut ?? ""; ptt = value.pushToTalkShortcut ?? "" }
}

struct MacWindowIdentity: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { let view = NSView(); DispatchQueue.main.async { view.window?.identifier = NSUserInterfaceItemIdentifier("lemonbot.main") }; return view }
    func updateNSView(_ nsView: NSView, context: Context) { nsView.window?.identifier = NSUserInterfaceItemIdentifier("lemonbot.main") }
}
