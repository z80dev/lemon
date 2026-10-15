import SwiftUI
import AVFoundation
import Observation
import LemonBotKit
import LemonBotUI
import UIKit

@MainActor @Observable
final class NativeVoiceSession: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    let capture = AppleSpeechCapture()
    var session: VoiceSession?
    var error: String?
    var busy = false
    var ambiguousSend = false
    var foreground = true
    var nativeVoiceID = ""
    var preferAppleSpeech = false
    private let store: LemonBotStore
    private let speaker = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var spoken: [ID: Int] = [:]
    private var restoredAccountID: String?
    private var speaking = false
    private var minimumSpeechSeq = Int.max

    init(store: LemonBotStore) {
        self.store = store
        super.init()
        speaker.delegate = self
    }
    var active: Bool { session?.state == "active" }
    private var persistenceKey: String? { store.account.map { "LemonBot.voiceSession.\($0.id)" } }

    func restore() async {
        guard let accountID = store.account?.id else {
            capture.cancel()
            speaker.stopSpeaking(at: .immediate)
            audioPlayer?.stop()
            session = nil
            restoredAccountID = nil
            error = nil
            return
        }
        guard restoredAccountID != accountID else { return }
        capture.cancel()
        speaker.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        session = nil
        spoken = [:]
        restoredAccountID = accountID
        minimumSpeechSeq = Int.max
        guard let key = persistenceKey, let id = UserDefaults.standard.string(forKey: key) else { return }
        do {
            let existing: VoiceSession = try await store.read("/voice/sessions/\(pathID(id))")
            guard store.account?.id == accountID else { return }
            session = existing
            try await resetSpeechBaseline(conversationID: existing.conversationId)
            if existing.state == "active" {
                error = "This session is still active. Microphone capture was not restarted. Return to the session or explicitly end it."
            }
        } catch { self.error = error.localizedDescription }
    }

    func start(conversationID: ID) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        guard !active else { error = "A voice session is already active. Return to it or explicitly end it before starting another."; return }
        guard store.connectionState == "online" else { error = "Reconnect before starting voice. Voice actions are never queued offline."; return }
        let draft = store.draft(for: conversationID)
        guard draft.text.isEmpty, draft.attachmentIDs.isEmpty, draft.fileURLs.isEmpty else { error = "Voice starts from an empty composer. Keep or send the current draft first."; return }
        guard let deviceID = store.deviceID, let user = store.user else { error = "Sign in and register this iOS device before starting voice."; return }
        let conversation: Conversation
        do {
            conversation = try await store.read("/conversations/\(pathID(conversationID))")
            try await resetSpeechBaseline(conversationID: conversationID)
        }
        catch { self.error = error.localizedDescription; return }
        guard conversation.ownerUserId == user.id, ["dm", "task"].contains(conversation.kind) else {
            error = "Voice is available only in your own direct chat or task, not groups, channels or another user's conversation."
            return
        }
        do {
            let voice = user.preferences.voice
            let created: VoiceSession = try await store.mutate("POST", "/voice/sessions", body: [
                "conversationId": .string(conversationID), "deviceId": .string(deviceID),
                "clientNonce": .string(UUID().uuidString),
                "settings": .object(["voiceId": .string(voice.voiceId), "speed": .number(voice.speed), "language": voice.language.map(JSONValue.string) ?? .null])
            ])
            session = created
            capture.cancel()
            ambiguousSend = false
            spoken = [:]
            if let key = persistenceKey { UserDefaults.standard.set(created.id, forKey: key) }
        } catch {
            self.error = error.localizedDescription
            if let backend = error as? BackendError, backend.failure.code == "conflict",
               let id = backend.failure.details?["voiceSessionId"]?.stringValue {
                do {
                    let existing: VoiceSession = try await store.read("/voice/sessions/\(pathID(id))")
                    session = existing
                    try await resetSpeechBaseline(conversationID: existing.conversationId)
                    if let key = persistenceKey { UserDefaults.standard.set(existing.id, forKey: key) }
                } catch { self.error = (self.error ?? "") + "\n" + error.localizedDescription }
            }
        }
    }

    func sendReviewedUtterance() async {
        guard let session, session.state == "active", session.deviceId == store.deviceID, !session.muted, foreground, !busy, !ambiguousSend else { return }
        guard store.connectionState == "online" else { error = "Reconnect before sending speech. The reviewed text is retained, never replayed."; return }
        let text = capture.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !capture.recording, !capture.preparing else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let receipt = try await store.send(conversationID: session.conversationId, text: text, attachmentIDs: [], voiceSessionID: session.id)
            guard self.session?.id == session.id, store.user?.id == session.userId else { return }
            if receipt.status == "outcome_unknown" {
                ambiguousSend = true
                error = "Voice message outcome is unknown. The text is retained. Inspect this conversation before another send; this utterance will not be replayed."
            } else if receipt.delivery.contains(where: { $0.effectiveMode == "rejected" }) {
                capture.cancel()
                error = "Message saved; the Bot did not admit this work.\n" + receipt.runs.compactMap { $0.status == "failed" ? $0.error?.message : nil }.joined(separator: "\n")
            } else { capture.cancel() }
        } catch {
            guard self.session?.id == session.id, store.user?.id == session.userId else { return }
            // A transport error can occur after acceptance. Do not manufacture a retry intent.
            ambiguousSend = true
            self.error = error.localizedDescription + "\nThe reviewed utterance is retained; it will not be automatically resent. Inspect the conversation before continuing."
        }
    }

    func reconcile() async {
        guard let id = session?.id else { return }
        do {
            let current: VoiceSession = try await store.read("/voice/sessions/\(pathID(id))")
            session = current
            if current.state != "active" || current.muted {
                capture.cancel(clearText: false)
                speaker.stopSpeaking(at: .immediate)
                audioPlayer?.stop()
                releasePlaybackSession()
            }
        }
        catch { self.error = error.localizedDescription }
    }

    func update(_ changes: JSONObject) async {
        guard let session, !busy else { return }
        guard store.connectionState == "online" else { error = "Voice controls require a live connection; no offline action is queued."; return }
        busy = true
        defer { busy = false }
        do {
            let current: VoiceSession = try await store.read("/voice/sessions/\(pathID(session.id))")
            var body = changes
            body["revision"] = .number(Double(current.revision))
            body["clientNonce"] = .string(UUID().uuidString)
            self.session = try await store.mutate("PATCH", "/voice/sessions/\(pathID(session.id))", body: body)
            if self.session?.muted == true { capture.cancel(clearText: false); speaker.stopSpeaking(at: .immediate) }
            if self.session?.muted == true { audioPlayer?.stop() }
        } catch { self.error = error.localizedDescription }
    }

    func end() async {
        capture.cancel(clearText: false)
        speaker.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        guard let session, !busy else { return }
        guard store.connectionState == "online" else { error = "Microphone stopped locally. Reconnect to end the server session; no end action has been queued."; return }
        busy = true
        defer { busy = false }
        do {
            self.session = try await store.mutate("POST", "/voice/sessions/\(pathID(session.id))/end", body: ["clientNonce": .string(UUID().uuidString)])
            if let key = persistenceKey { UserDefaults.standard.removeObject(forKey: key) }
        } catch { self.error = error.localizedDescription }
    }

    func background() {
        foreground = false
        capture.cancel(clearText: false)
        speaker.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        releasePlaybackSession()
    }

    func observeSessionState() {
        guard let latest = store.voiceSession, let session,
              latest.id == session.id, latest.revision >= session.revision else { return }
        self.session = latest
        if latest.state != "active" || latest.muted {
            capture.cancel(clearText: false)
            speaker.stopSpeaking(at: .immediate)
            audioPlayer?.stop()
            releasePlaybackSession()
        }
    }

    func speakReplies() async {
        observeSessionState()
        guard !speaking, !speaker.isSpeaking, audioPlayer?.isPlaying != true,
              foreground, let session, session.state == "active", session.deviceId == store.deviceID, !session.muted,
              !capture.recording, !capture.preparing else { return }
        for entry in store.entries[session.conversationId] ?? [] {
            guard entry.kind == "message", entry.role == "assistant",
                  entry.seq > minimumSpeechSeq, let text = entry.text else { continue }
            let offset = spoken[entry.id] ?? 0
            guard text.count > offset else { continue }
            let remaining = String(text.dropFirst(offset).prefix(4096))
            let speakable: String
            if entry.streaming {
                guard let boundary = remaining.lastIndex(where: { ".!?\n".contains($0) }) else { continue }
                speakable = String(remaining[...boundary])
            } else { speakable = remaining }
            // A failed/unknown provider request is not automatically replayed.
            spoken[entry.id] = offset + speakable.count
            speaking = true
            defer { speaking = false }
            do {
                if store.capabilities?.tts == true, !preferAppleSpeech {
                    guard store.connectionState == "online" else { throw ClientError.offline }
                    let result: SpeechResult = try await store.mutate("POST", "/audio/speech", body: [
                        "text": .string(speakable), "voice": .object([
                            "voiceId": .string(session.settings.voiceId), "speed": .number(session.settings.speed),
                            "language": session.settings.language.map(JSONValue.string) ?? .null
                        ]), "conversationId": .string(session.conversationId),
                        "voiceSessionId": .string(session.id), "clientNonce": .string(UUID().uuidString)
                    ])
                    let file = try await store.download(attachmentID: result.attachment.id)
                    guard foreground, self.session?.id == session.id, self.session?.state == "active",
                          self.session?.muted == false, !capture.recording else { return }
                    let player = try AVAudioPlayer(contentsOf: file)
                    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                    try AVAudioSession.sharedInstance().setActive(true)
                    audioPlayer = player
                    player.delegate = self
                    guard player.play() else { throw CaptureError.message("The provider's audio could not be played on this device.") }
                } else {
                    let utterance = AVSpeechUtterance(string: speakable)
                    utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(session.settings.speed)))
                    utterance.voice = nativeVoiceID.isEmpty ? AVSpeechSynthesisVoice(language: session.settings.language) : AVSpeechSynthesisVoice(identifier: nativeVoiceID)
                    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                    try AVAudioSession.sharedInstance().setActive(true)
                    speaker.speak(utterance)
                }
            } catch { self.error = error.localizedDescription }
            return
        }
    }

    func recordTurn() async {
        guard active, session?.deviceId == store.deviceID, session?.muted != true, foreground, !ambiguousSend else { return }
        speaker.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        capture.cuesEnabled = store.localSettings?.micCuesEnabled ?? true
        await capture.start(language: session?.settings.language)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.releasePlaybackSession() }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.releasePlaybackSession() }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            if !flag { self?.error = "Voice audio playback did not finish successfully." }
            self?.releasePlaybackSession()
        }
    }
    private func releasePlaybackSession() {
        guard !capture.recording, !capture.preparing else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func resetSpeechBaseline(conversationID: ID) async throws {
        minimumSpeechSeq = Int.max
        let page: Page<TranscriptEntry> = try await store.read("/conversations/\(pathID(conversationID))/entries", query: ["limit": "1"])
        minimumSpeechSeq = page.items.last?.seq ?? 0
        spoken = [:]
    }

    private func pathID(_ id: ID) -> String { id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) ?? "" }
}

struct NativeVoiceView: View {
    @Bindable var voice: NativeVoiceSession
    let store: LemonBotStore
    @Environment(\.dismiss) private var dismiss
    @State private var language = ""
    @State private var voiceID = "default"
    @State private var speed = 1.0
    private static let localVoices = AVSpeechSynthesisVoice.speechVoices()

    var body: some View {
        NavigationStack {
            Form {
                if let session = voice.session {
                    Section("Voice session · \(session.state)") {
                        Text("Conversation: \(store.conversations.first(where: { $0.id == session.conversationId })?.name ?? session.conversationId)")
                        Text(store.capabilities?.tts == true && !voice.preferAppleSpeech ? "Configured backend speech, played with the iOS audio session." : "Apple on-device speech fallback. Spoken locally; not a persisted voice memo.").font(.caption)
                        if session.deviceId != store.deviceID { Text("This call belongs to another device. End it explicitly before starting a call on this iPhone or iPad.").foregroundStyle(.orange) }
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let duration = session.state == "active" ? max(0, context.date.timeIntervalSince1970 - Double(session.startedAtMs) / 1000) : Double(session.durationMs) / 1000
                            Text("Duration: \(Int(duration)) seconds")
                        }
                        Button("Return to conversation") { Task { do { try await store.openConversation(session.conversationId); dismiss() } catch { voice.error = error.localizedDescription } } }
                        Button("Refresh session state") { Task { await voice.reconcile() } }
                        if voice.active {
                            Button(session.muted ? "Unmute" : "Mute") { Task { await voice.update(["muted": .bool(!session.muted)]) } }
                            Button("Hang up", role: .destructive) { Task { await voice.end() } }
                        } else {
                            HStack {
                                Button("Good call") { Task { await voice.update(["feedback": .string("good")]) } }
                                Button("Bad call") { Task { await voice.update(["feedback": .string("bad")]) } }
                            }
                            Text("Work already sent continues in chat after the call ends.")
                        }
                    }
                    if voice.active {
                        Section("Explicit microphone · reviewed utterance") {
                            Text("Record only when you choose Record. Stop, review and edit before sending to this voice session. Capture stops when the app leaves the foreground.").font(.caption)
                            if voice.capture.preparing { ProgressView("Requesting microphone and speech access…") }
                            if voice.capture.recording {
                                Label("Microphone on", systemImage: "mic.fill").foregroundStyle(.red)
                                Button("Stop and review") { voice.capture.stop() }
                            } else {
                                Button("Record a turn") { Task { await voice.recordTurn() } }.disabled(session.muted || voice.ambiguousSend || voice.busy || session.deviceId != store.deviceID)
                            }
                            if !voice.capture.processing.isEmpty { Text(voice.capture.processing).font(.caption) }
                            TextEditor(text: Binding(get: { voice.capture.text }, set: { voice.capture.text = $0 })).frame(minHeight: 100)
                            Button("Send reviewed utterance") { Task { await voice.sendReviewedUtterance() } }
                                .disabled(voice.capture.recording || voice.capture.preparing || voice.capture.text.isEmpty || session.muted || voice.busy || voice.ambiguousSend || store.connectionState != "online" || session.deviceId != store.deviceID)
                            Button("Discard reviewed utterance") { voice.capture.cancel(); voice.ambiguousSend = false }
                        }
                        Section("Voice settings") {
                            Toggle("Use Apple spoken voice instead of backend", isOn: $voice.preferAppleSpeech)
                            ProviderVoicePicker(store: store, voiceID: $voiceID, language: $language)
                            TextField("Language (optional, e.g. en-US)", text: $language).textInputAutocapitalization(.never)
                            Slider(value: $speed, in: 0.5...2, step: 0.1)
                            Text("Speed: \(speed, specifier: "%.1f")×")
                            Picker("Local spoken voice", selection: $voice.nativeVoiceID) {
                                Text("Language default").tag("")
                                ForEach(Self.localVoices, id: \.identifier) { voice in Text("\(voice.name) · \(voice.language)").tag(voice.identifier) }
                            }
                            Button("Apply session settings") {
                                Task { await voice.update(["settings": .object(["voiceId": .string(voiceID), "speed": .number(speed), "language": language.isEmpty ? .null : .string(language)])]) }
                            }.disabled(voice.busy || store.connectionState != "online")
                        }
                    }
                    Section("Conversation transcript") {
                        ForEach(store.entries[session.conversationId] ?? []) { entry in
                            if let text = entry.text { VStack(alignment: .leading) { Text(entry.actor.displayName).font(.caption); Text(text).textSelection(.enabled) } }
                        }
                    }
                }
                if voice.busy { ProgressView("Updating voice session…") }
                if let error = voice.error { Section("Voice error") { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
                if let error = voice.capture.error {
                    Section("Speech error") {
                        Text(error).foregroundStyle(.red)
                        Button("Open iOS Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                    }
                }
            }
            .navigationTitle("Voice")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Keep call visible in chat") { dismiss() } } }
            .onAppear {
                language = voice.session?.settings.language ?? ""
                voiceID = voice.session?.settings.voiceId ?? "default"
                speed = voice.session?.settings.speed ?? 1
            }
        }
    }
}
