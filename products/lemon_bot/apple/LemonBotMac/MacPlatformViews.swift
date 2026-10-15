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
            Text("Only the text and files you explicitly choose are shared. Nothing is sent until Send.").font(LBFont.meta).foregroundStyle(LB.muted)
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
            if let error = controller.errorMessage { Text(error).foregroundStyle(LB.danger).textSelection(.enabled) }
            if controller.selectedBot == nil { SettingsLink { Text("Open Settings") } }
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
            Text("\(controller.store.account?.displayName ?? "Not signed in") · \(controller.store.workspace?.name ?? "") · \(machine?.name ?? "Unknown machine")").font(LBFont.meta).foregroundStyle(LB.muted)
            if let room { Text(room.name).font(LBFont.meta) }
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
                Text("Status comes from your Bot’s latest backend state.").font(LBFont.meta).foregroundStyle(LB.muted)
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
        } else {
            VStack(spacing: 12) {
                Text("The selected Bot is no longer available.")
                SettingsLink { Text("Choose another Bot") }
            }.padding()
        }
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
                .foregroundStyle(speech.state == .recording ? LB.danger : LB.muted)
                .accessibilityLabel(speech.state == .recording ? "Microphone on" : "Microphone off")
            if active, let session {
                Text("Voice chat · \(session.muted ? "Muted" : "Ready") · \(compactDuration(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: Double(session.durationMs) / 1000)))")
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
                    Text("How was this call?")
                    Button("Good") { Task { await controller.updateCall(feedback: "good") } }
                    Button("Bad") { Task { await controller.updateCall(feedback: "bad") } }
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
                    ProviderVoicePicker(store: controller.store, voiceID: Binding(get: { controller.voiceSettings?.voiceId ?? settings.voiceId }, set: { value in
                        settings.voiceId = value; controller.voiceSettings = settings
                    }), language: Binding(get: { controller.voiceSettings?.language ?? "" }, set: { value in
                        settings.language = value.isEmpty ? nil : value; controller.voiceSettings = settings
                    }))
                    TextField("Language (optional, e.g. en-US)", text: Binding(get: { controller.voiceSettings?.language ?? "" }, set: { value in
                        settings.language = value.isEmpty ? nil : value; controller.voiceSettings = settings
                    }))
                    Button("Save voice") { Task { await controller.updateCall(settings: controller.voiceSettings) } }
                        .disabled(!controller.online || controller.busy)
                }
            }
            if speech.state == .requestingPermission || speech.state == .transcribing {
                ProgressView(speech.state == .requestingPermission ? "Waiting for microphone/Speech permission…" : "Finishing transcription…")
            }
            if speech.state == .recording {
                Button("Stop") { speech.release() }
            } else if speech.state == .idle {
                Button("Record") {
                    if let id = controller.captureConversationID ?? session?.conversationId { controller.beginDictation(conversationID: id) }
                }.disabled(active && (session?.muted == true))
                Text("Record, stop, then review. Hold your talk shortcut to record only while pressed. Escape discards.").font(LBFont.meta).foregroundStyle(LB.muted)
            }
            if speech.state == .review {
                Text("Review and edit — nothing has been sent.").font(.headline)
                TextEditor(text: $speech.transcript).frame(minHeight: 110)
                if speech.needsBackendTranscription {
                    Button("Turn speech into text") { Task { await controller.transcribeRecording() } }
                        .disabled(!controller.online || controller.busy)
                    Text("Uploads this recording to the speech-to-text provider set up on your server.").font(LBFont.meta)
                }
                HStack {
                    Button("Save as draft") { controller.keepReviewedDraft() }
                        .disabled(speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.uncertainVoiceSend)
                    if active && controller.reviewForCall {
                        Button("Send") { Task { await controller.sendReviewedVoice() } }
                            .disabled(!controller.online || controller.busy || session?.muted == true || speech.transcript.isEmpty || controller.uncertainVoiceSend)
                    }
                    Button("Discard", role: .cancel) { controller.cancelCapture() }
                }
            }
            if controller.uncertainVoiceSend {
                Text("We couldn't confirm the last voice message. Check the conversation before sending again.").font(LBFont.meta).foregroundStyle(LB.warning)
                Button("Start new voice message") { controller.startNewVoiceMessage() }.disabled(controller.busy)
            }
            if let text = controller.speechStatus { Text(text).font(LBFont.meta).textSelection(.enabled) }
            if let error = speech.errorMessage { Text(error).foregroundStyle(LB.warning).textSelection(.enabled) }
            if let error = controller.errorMessage { Text(error).foregroundStyle(LB.danger).textSelection(.enabled) }
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
                LabeledContent("Quick composer shortcut") {
                    MacShortcutRecorder(label: "Quick composer shortcut", shortcut: $summon, recordingChanged: controller.shortcutRecordingChanged)
                }
                LabeledContent("Hold to talk shortcut") {
                    MacShortcutRecorder(label: "Hold to talk shortcut", shortcut: $ptt, recordingChanged: controller.shortcutRecordingChanged)
                }
                Text("Click to record a key with Command, Control or Option. Escape cancels; Delete turns the shortcut off. Save to apply.").font(LBFont.meta)
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
                Button("Play voice sample") { if let id = value.selectedBotId { Task { await controller.previewVoice(botID: id) } } }
                    .disabled(value.selectedBotId == nil || !controller.online || controller.busy)
                Text("Playing a sample doesn't create a chat or task. If it can't play, the error says what's missing.").font(LBFont.meta)
                Button("Enable macOS notifications…") { Task { await controller.requestNotifications() } }
                if let status = controller.speechStatus { Text(status).font(LBFont.meta) }
            }
            Section("Privacy") {
                Text("No listening, clipboard history or screen capture happens in the background. To share text, right-click selected text → Services → Send to Lemon Bot, then review it in the quick composer. Choose files with the file picker. Shortcuts and the companion are off by default and saved for this device and account.").font(LBFont.meta)
            }
            if let error = controller.errorMessage { Text(error).foregroundStyle(LB.danger).textSelection(.enabled) }
        }.formStyle(.grouped)
            .onAppear { load(); controller.speech.refreshInputDevices() }
            .onChange(of: controller.settings) { _, _ in load() }
    }
    private func load() { value = controller.settings; summon = value.summonShortcut ?? ""; ptt = value.pushToTalkShortcut ?? "" }
}

struct MacWindowIdentity: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { let view = NSView(); DispatchQueue.main.async { view.window?.identifier = NSUserInterfaceItemIdentifier("lemonbot.main") }; return view }
    func updateNSView(_ nsView: NSView, context: Context) { nsView.window?.identifier = NSUserInterfaceItemIdentifier("lemonbot.main") }
}
