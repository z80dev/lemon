import AppKit
import AVFoundation
import LemonBotKit
import LemonBotUI
import Observation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications


@MainActor
@Observable
final class MacPlatformController: NSObject {
    let store: LemonBotStore
    let speech = MacSpeechCapture()
    var settings = ClientLocalSettings(micCuesEnabled: true, compactCompanionEnabled: false, reducedMotion: "system")
    var errorMessage: String?
    var speechStatus: String?
    var busy = false
    var captureConversationID: ID?
    var voiceSettings: VoiceSettings?
    var reviewForCall = false
    var panelConversationID: ID?
    var mainViewedConversationID: ID?
    var uncertainVoiceSend = false
    private let hotkeys = MacGlobalHotkeys()
    private var composerPanel: NSPanel?
    private var companionPanel: NSPanel?
    private var voicePanel: NSPanel?
    private var player: AVAudioPlayer?
    private let synthesizer = AVSpeechSynthesizer()
    private var spokenEntryIDs: Set<ID> = []
    private var seenNotifications: Set<ID> = []
    private var notificationBaseline = false
    private var lifecycleTask: Task<Void, Never>?
    private var activeAccountID: String?
    private var accountGeneration = UUID()
    private var playbackTask: Task<Void, Never>?
    private var playbackGeneration = UUID()

    init(store: LemonBotStore) {
        self.store = store
        super.init()
        hotkeys.action = { [weak self] id, pressed in
            guard let self else { return }
            if id == 1, pressed { self.summon() }
            if id == 2 {
                if pressed {
                    guard let id = self.selectedBot?.mainConversationId else { return }
                    self.beginDictation(conversationID: id)
                } else { self.speech.release() }
            }
        }
    }

    var selectedBot: Bot? { store.bots.first { $0.id == settings.selectedBotId } }
    var online: Bool { store.account != nil && store.connectionState == "online" }
    var viewedConversationID: ID? {
        guard NSApp.isActive else { return nil }
        switch NSApp.keyWindow?.identifier?.rawValue {
        case "lemonbot.composer": return panelConversationID
        case "lemonbot.companion": return nil
        case "lemonbot.voice": return captureConversationID ?? store.voiceSession?.conversationId
        case "lemonbot.main": return mainViewedConversationID
        default: return nil
        }
    }

    func start() {
        guard lifecycleTask == nil else { return }
        NSApp.servicesProvider = self
        lifecycleTask = Task { [weak self] in
            guard let self else { return }
            if self.store.account == nil {
                do { try await self.store.restoreSavedAccount() }
                catch { if self.store.connectionIssue == nil { self.errorMessage = error.localizedDescription } }
            }
            await self.accountChanged()
            while !Task.isCancelled {
                await self.publishPresence()
                self.notificationsChanged()
                self.entriesChanged()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    func accountChanged() async {
        guard activeAccountID != store.account?.id else { return }
        activeAccountID = store.account?.id
        let generation = UUID()
        accountGeneration = generation
        speech.cancel()
        captureConversationID = nil
        mainViewedConversationID = nil
        reviewForCall = false
        uncertainVoiceSend = false
        stopPlayback()
        voicePanel?.orderOut(nil)
        composerPanel?.orderOut(nil)
        companionPanel?.orderOut(nil)
        seenNotifications.removeAll()
        notificationBaseline = false
        spokenEntryIDs.removeAll()
        do {
            settings = store.localSettings ?? ClientLocalSettings(micCuesEnabled: true, compactCompanionEnabled: false, reducedMotion: "system")
            try hotkeys.configure(summon: store.account == nil ? nil : settings.summonShortcut, pushToTalk: store.account == nil ? nil : settings.pushToTalkShortcut)
            if store.account != nil, store.connectionState != "reconnect_required" {
                try await store.registerDevice(platform: "macos", name: Host.current().localizedName ?? "Mac")
                guard generation == accountGeneration else { return }
                let permission = await UNUserNotificationCenter.current().notificationSettings()
                guard generation == accountGeneration else { return }
                if permission.authorizationStatus == .authorized, pushEnvironment != nil { NSApp.registerForRemoteNotifications() }
                updateCompanion()
                notificationsChanged()
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func saveSettings(_ value: ClientLocalSettings) {
        do {
            try hotkeys.configure(summon: value.summonShortcut, pushToTalk: value.pushToTalkShortcut)
            try store.saveLocalSettings(value)
            settings = value
            updateCompanion()
        } catch {
            try? hotkeys.configure(summon: settings.summonShortcut, pushToTalk: settings.pushToTalkShortcut)
            errorMessage = error.localizedDescription
        }
    }

    func summon() {
        guard store.account != nil else { errorMessage = "Sign in to Lemon Bot to use the quick composer."; NSApp.activate(ignoringOtherApps: true); return }
        guard let bot = selectedBot else { errorMessage = "Choose a Bot in Lemon Bot Settings first."; NSApp.activate(ignoringOtherApps: true); return }
        panelConversationID = bot.mainConversationId
        if composerPanel == nil {
            composerPanel = makePanel(title: "Lemon Bot — Quick composer", id: "lemonbot.composer", size: NSSize(width: 520, height: 340))
        }
        composerPanel?.contentView = NSHostingView(rootView: MacMiniComposer(controller: self, conversationID: bot.mainConversationId))
        composerPanel?.center()
        composerPanel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { do { try await store.openConversation(bot.mainConversationId) } catch { errorMessage = error.localizedDescription } }
    }

    func updateCompanion() {
        guard settings.compactCompanionEnabled, let bot = selectedBot, store.account != nil else {
            companionPanel?.orderOut(nil)
            return
        }
        if companionPanel == nil {
            companionPanel = makePanel(title: "Lemon Bot companion", id: "lemonbot.companion", size: NSSize(width: 330, height: 190))
        }
        companionPanel?.contentView = NSHostingView(rootView: MacCompanionView(controller: self, botID: bot.id))
        companionPanel?.orderFront(nil)
    }

    private func makePanel(title: String, id: String, size: NSSize) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = title
        panel.identifier = NSUserInterfaceItemIdentifier(id)
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        return panel
    }

    func beginDictation(conversationID: ID) {
        guard store.account != nil, speech.state == .idle else { return }
        if let session = store.voiceSession, session.state == "active", session.conversationId == conversationID, session.muted {
            errorMessage = "Unmute voice chat before recording a voice message."
            return
        }
        stopPlayback()
        captureConversationID = conversationID
        reviewForCall = store.voiceSession?.state == "active" && store.voiceSession?.conversationId == conversationID
        showVoicePanel()
        let language = reviewForCall ? store.voiceSession?.settings.language : store.user?.preferences.voice.language
        guard let ticket = speech.prepare(cues: settings.micCuesEnabled) else { return }
        Task { await speech.begin(language: language, ticket: ticket) }
    }

    func showVoicePanel() {
        if voicePanel == nil {
            voicePanel = makePanel(title: "Lemon Bot — Voice review", id: "lemonbot.voice", size: NSSize(width: 540, height: 510))
        }
        voicePanel?.contentView = NSHostingView(rootView: MacVoiceView(controller: self))
        voicePanel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func cancelCapture() { speech.cancel(); captureConversationID = nil }

    func startNewVoiceMessage() {
        guard uncertainVoiceSend, !busy else { return }
        speech.cancel()
        uncertainVoiceSend = false
        errorMessage = nil
        speechStatus = "Previous message wasn't confirmed. Check the conversation before sending a new message."
    }

    func keepReviewedDraft() {
        guard let id = captureConversationID, !speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let draft = store.draft(for: id)
        let text = draft.text.isEmpty ? speech.transcript : draft.text + "\n" + speech.transcript
        store.setLocalDraft(conversationID: id, text: text, attachmentIDs: draft.attachmentIDs, replyTo: draft.replyToEntryID)
        cancelCapture()
        if store.voiceSession?.state != "active" { voicePanel?.orderOut(nil) }
    }

    func transcribeRecording() async {
        guard online, !busy, let url = speech.recordingURL, let id = captureConversationID else { return }
        let generation = accountGeneration
        busy = true
        defer { busy = false }
        do {
            let attachment = try await store.upload(fileURL: url, mime: "audio/wav", metadata: ["purpose": .string("audio"), "conversationId": .string(id)])
            guard generation == accountGeneration, speech.recordingURL == url, captureConversationID == id else { return }
            var body: JSONObject = ["attachmentId": .string(attachment.id)]
            if let language = store.voiceSession?.settings.language ?? store.user?.preferences.voice.language { body["language"] = .string(language) }
            if reviewForCall, let session = store.voiceSession { body["voiceSessionId"] = .string(session.id) }
            let result: Transcription = try await store.mutate("POST", "/audio/transcriptions", body: body)
            guard generation == accountGeneration, speech.recordingURL == url, captureConversationID == id else { return }
            speech.acceptBackendTranscript(result.text)
        } catch { errorMessage = error.localizedDescription }
    }

    func startCall(conversationID: ID) async {
        guard online, !busy else { return }
        if store.voiceSession?.state == "active" { showVoicePanel(); return }
        guard store.draft(for: conversationID).text.isEmpty, store.draft(for: conversationID).attachmentIDs.isEmpty else {
            errorMessage = "Save or send this conversation’s draft before starting voice chat. Voice chat starts from an empty composer."
            return
        }
        guard let device = store.deviceID else { errorMessage = "This Mac isn't connected yet. Sign in again to start voice chat."; return }
        let generation = accountGeneration
        busy = true
        defer { busy = false }
        do {
            let session: VoiceSession = try await store.mutate("POST", "/voice/sessions", body: ["conversationId": .string(conversationID), "deviceId": .string(device)])
            guard generation == accountGeneration else { return }
            store.voiceSession = session
            voiceSettings = session.settings
            captureConversationID = conversationID
            reviewForCall = true
            spokenEntryIDs = Set((store.entries[conversationID] ?? []).map(\.id))
            uncertainVoiceSend = false
            showVoicePanel()
        } catch {
            guard generation == accountGeneration else { return }
            errorMessage = error.localizedDescription
            if let backend = error as? BackendError, backend.failure.code == "conflict",
               let existingID = backend.failure.details?["voiceSessionId"]?.stringValue {
                do {
                    let existing: VoiceSession = try await store.read("/voice/sessions/\(escaped(existingID))")
                    guard generation == accountGeneration else { return }
                    store.voiceSession = existing
                    voiceSettings = existing.settings
                    captureConversationID = existing.conversationId
                    reviewForCall = true
                    spokenEntryIDs = Set((store.entries[existing.conversationId] ?? []).map(\.id))
                    showVoicePanel()
                } catch { errorMessage = error.localizedDescription }
            }
        }
    }

    func sendReviewedVoice() async {
        guard online, !busy, !uncertainVoiceSend, let session = store.voiceSession, session.state == "active", !session.muted,
              captureConversationID == session.conversationId, speech.state == .review,
              !speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let generation = accountGeneration
        busy = true
        defer { busy = false }
        do {
            let receipt = try await store.send(conversationID: session.conversationId, text: speech.transcript, attachmentIDs: [], voiceSessionID: session.id)
            guard generation == accountGeneration else { return }
            if receipt.status == "outcome_unknown" {
                uncertainVoiceSend = true
                errorMessage = "We couldn't confirm this voice message was sent. Check the conversation before sending again."
            } else if receipt.delivery.contains(where: { $0.effectiveMode == "rejected" }) {
                speech.cancel()
                speechStatus = "Message saved, but the Bot hasn't picked it up yet."
                errorMessage = receipt.runs.compactMap { $0.status == "failed" ? $0.error?.message : nil }.joined(separator: "\n")
            } else {
                speech.cancel()
                speechStatus = receipt.status == "queued" ? "Queued; waiting for the Bot’s next turn." : "Sent; waiting for the Bot’s reply."
            }
        } catch {
            guard generation == accountGeneration else { return }
            // Only an authoritative pre-dispatch error can leave this explicit send available.
            uncertainVoiceSend = (error as? BackendError)?.failure.retrySafe != true
            errorMessage = error.localizedDescription
        }
    }

    func updateCall(muted: Bool? = nil, settings: VoiceSettings? = nil, feedback: String? = nil) async {
        guard online, !busy, let session = store.voiceSession, session.state == "active" else { return }
        busy = true
        defer { busy = false }
        speech.cancel()
        stopPlayback()
        do {
            var body: JSONObject = ["revision": .number(Double(session.revision))]
            if let muted { body["muted"] = .bool(muted) }
            if let settings { body["settings"] = try jsonObject(settings) }
            if let feedback { body["feedback"] = .string(feedback) }
            let updated: VoiceSession = try await store.mutate("PATCH", "/voice/sessions/\(escaped(session.id))", body: body)
            guard store.voiceSession?.id == session.id else { return }
            store.voiceSession = updated
            voiceSettings = updated.settings
        } catch { errorMessage = error.localizedDescription }
    }

    func endCall() async {
        guard online, !busy, let session = store.voiceSession else { return }
        cancelCapture()
        stopPlayback()
        busy = true
        defer { busy = false }
        do {
            let ended: VoiceSession = try await store.mutate("POST", "/voice/sessions/\(escaped(session.id))/end", body: [:])
            guard store.voiceSession?.id == session.id else { return }
            store.voiceSession = ended
            reviewForCall = false
            voicePanel?.orderOut(nil)
        } catch { errorMessage = error.localizedDescription }
    }

    func entriesChanged() {
        guard let session = store.voiceSession, session.state == "active", !session.muted else { stopPlayback(); return }
        guard speech.state != .recording, speech.state != .requestingPermission else { return }
        let replies = (store.entries[session.conversationId] ?? []).filter {
            $0.kind == "message" && $0.role == "assistant" && !$0.streaming && !spokenEntryIDs.contains($0.id)
        }.sorted { $0.seq < $1.seq }
        guard !replies.isEmpty else { return }
        replies.forEach { spokenEntryIDs.insert($0.id) }
        let previous = playbackTask
        let account = accountGeneration
        let playback = playbackGeneration
        playbackTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, account == self.accountGeneration, playback == self.playbackGeneration else { return }
            for entry in replies {
                guard !Task.isCancelled, playback == self.playbackGeneration, self.store.voiceSession?.id == session.id, self.store.voiceSession?.state == "active", self.store.voiceSession?.muted == false else { return }
                if let text = entry.text { await self.speakReply(text, session: session, playback: playback) }
            }
        }
    }

    private func speakReply(_ text: String, session: VoiceSession, playback: UUID) async {
        // Bound every real provider segment to the wire limit without losing long replies.
        var remaining = text[...]
        while !remaining.isEmpty, !Task.isCancelled, playback == playbackGeneration {
            let boundary = remaining.index(remaining.startIndex, offsetBy: min(4096, remaining.count))
            let segment = String(remaining[..<boundary])
            remaining = remaining[boundary...]
            do {
                let result: SpeechResult = try await store.mutate("POST", "/audio/speech", body: ["text": .string(segment), "voice": try jsonObject(session.settings), "conversationId": .string(session.conversationId), "voiceSessionId": .string(session.id)])
                guard !Task.isCancelled, playback == playbackGeneration else { return }
                let url = try await store.download(attachmentID: result.attachment.id)
                guard !Task.isCancelled, playback == playbackGeneration else { return }
                try await play(url, playback: playback)
                speechStatus = "Playing Bot voice."
            } catch {
                guard !Task.isCancelled, playback == playbackGeneration else { return }
                errorMessage = error.localizedDescription
                speechStatus = "Bot voice couldn't play. Reading it aloud on this Mac instead."
                let utterance = AVSpeechUtterance(string: segment)
                utterance.voice = session.settings.language.flatMap { AVSpeechSynthesisVoice(language: $0) }
                utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(session.settings.speed)
                synthesizer.speak(utterance)
                while synthesizer.isSpeaking, !Task.isCancelled, playback == playbackGeneration { try? await Task.sleep(for: .milliseconds(100)) }
            }
        }
    }

    func previewVoice(botID: ID) async {
        guard online, !busy else { return }
        stopPlayback()
        let playback = playbackGeneration
        let account = accountGeneration
        busy = true
        defer { busy = false }
        do {
            let result: SpeechResult = try await store.mutate("POST", "/bots/\(escaped(botID))/voice/preview", body: [:])
            guard playback == playbackGeneration, account == accountGeneration else { return }
            let url = try await store.download(attachmentID: result.attachment.id)
            guard playback == playbackGeneration, account == accountGeneration else { return }
            try await play(url, playback: playback)
            speechStatus = "Voice sample played. No message or task was created."
        } catch { errorMessage = error.localizedDescription }
    }

    private func play(_ url: URL, playback: UUID) async throws {
        player?.stop()
        let audio = try AVAudioPlayer(contentsOf: url)
        player = audio
        audio.prepareToPlay()
        guard audio.play() else { throw HotkeyError.invalid("The downloaded audio could not be played.") }
        while audio.isPlaying, !Task.isCancelled, playback == playbackGeneration { try await Task.sleep(for: .milliseconds(100)) }
        if Task.isCancelled || playback != playbackGeneration { audio.stop() }
    }

    func stopPlayback() {
        playbackGeneration = UUID()
        playbackTask?.cancel()
        playbackTask = nil
        player?.stop()
        player = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    func chooseFiles(conversationID: ID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        Task { await importFiles(panel.urls, conversationID: conversationID) }
    }

    func importFiles(_ urls: [URL], conversationID: ID) async {
        guard online, !busy else { return }
        let generation = accountGeneration
        let draft = store.draft(for: conversationID)
        guard draft.attachmentIDs.count + urls.count <= 6 else { errorMessage = "A message may contain at most six files."; return }
        busy = true
        defer { busy = false }
        for url in urls {
            guard generation == accountGeneration else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                let attachment = try await store.upload(fileURL: url, mime: mime, metadata: ["purpose": .string("message"), "conversationId": .string(conversationID)])
                guard generation == accountGeneration else { return }
                let current = store.draft(for: conversationID)
                store.setLocalDraft(conversationID: conversationID, text: current.text, attachmentIDs: current.attachmentIDs + [attachment.id], replyTo: current.replyToEntryID)
            } catch { errorMessage = error.localizedDescription; return }
        }
    }

    @objc func receiveSelection(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        // Invoked only by the user's macOS Services menu on explicit selected content.
        guard let bot = selectedBot, store.account != nil else { error.pointee = "Choose a signed-in Bot in Lemon Bot settings first."; return }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            let draft = store.draft(for: bot.mainConversationId)
            store.setLocalDraft(conversationID: bot.mainConversationId, text: draft.text.isEmpty ? text : draft.text + "\n" + text, attachmentIDs: draft.attachmentIDs, replyTo: draft.replyToEntryID)
        }
        if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            Task { await importFiles(files, conversationID: bot.mainConversationId) }
        }
        summon()
    }

    func route(_ url: URL) async {
        do { try await store.navigate(url); NSApp.activate(ignoringOtherApps: true) }
        catch { errorMessage = error.localizedDescription }
    }

    func publishPresence() async {
        guard online else { return }
        do { try await store.sendFrame(["type": .string("presence"), "foreground": .bool(NSApp.isActive), "conversationId": viewedConversationID.map(JSONValue.string) ?? .null]) }
        catch { errorMessage = error.localizedDescription }
    }

    private var pushEnvironment: String? {
        switch Bundle.main.object(forInfoDictionaryKey: "LemonBotAPNSEnvironment") as? String {
        case "development": return "sandbox"
        case "production": return "production"
        default: return nil // Local Debug builds have no APNs entitlement.
        }
    }

    func requestNotifications() async {
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            if allowed {
                if pushEnvironment != nil { NSApp.registerForRemoteNotifications() }
            } else { errorMessage = "Notifications are disabled in macOS. Enable Lemon Bot in System Settings → Notifications." }
        } catch { errorMessage = error.localizedDescription }
    }

    func registerPush(_ data: Data) async {
        guard store.account != nil, let environment = pushEnvironment else { return }
        let token = data.map { String(format: "%02x", $0) }.joined()
        do {
            try await store.registerDevice(platform: "macos", name: Host.current().localizedName ?? "Mac", push: ["kind": .string("apns"), "token": .string(token), "environment": .string(environment), "topic": .string(Bundle.main.bundleIdentifier ?? "org.lemonbot.mac")])
        } catch { errorMessage = error.localizedDescription }
    }

    func notificationsChanged() {
        guard store.account != nil else { return }
        if !notificationBaseline {
            seenNotifications = Set(store.notifications.map(\.id))
            notificationBaseline = true
            return
        }
        for notification in store.notifications where !seenNotifications.contains(notification.id) {
            seenNotifications.insert(notification.id)
            guard notification.readAtMs == nil, notification.dismissedAtMs == nil, let preferences = store.user?.notifications, preferences.enabled else { continue }
            if let botID = notification.botId, let bot = store.bots.first(where: { $0.id == botID }), bot.sidebar.hidden || !bot.sidebar.notificationsEnabled { continue }
            if notification.kind == "result", !preferences.completed { continue }
            if ["approval", "question", "human_step"].contains(notification.kind), !preferences.needsInput { continue }
            if let room = notification.conversationId, room == viewedConversationID { continue }
            let content = UNMutableNotificationContent()
            content.title = preferences.previews ? notification.title : "Lemon Bot"
            content.body = preferences.previews ? notification.body : "Your teammate has an update."
            if preferences.sound { content.sound = .default }
            content.userInfo = ["deepLink": notification.deepLink, "workspaceId": store.workspace?.id ?? "", "notificationId": notification.id, "conversationId": notification.conversationId ?? "", "botId": notification.botId ?? ""]
            // An approval keeps its own identifier; informational results coalesce per room.
            let key = notification.kind == "result" ? "result-\(notification.conversationId ?? notification.id)" : notification.id
            let request = UNNotificationRequest(identifier: "\(store.account?.id ?? "")-\(key)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { [weak self] error in
                if let error { Task { @MainActor in self?.errorMessage = error.localizedDescription } }
            }
        }
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
    private func escaped(_ id: String) -> String { id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id }
}

extension MacPlatformController: NSWindowDelegate {
    func windowWillClose(_ notification: Foundation.Notification) {
        if (notification.object as? NSWindow)?.identifier?.rawValue == "lemonbot.voice" { cancelCapture(); stopPlayback() }
        Task { await publishPresence() }
    }
    func windowDidBecomeKey(_ notification: Foundation.Notification) { Task { await publishPresence() } }
    func windowDidResignKey(_ notification: Foundation.Notification) { Task { await publishPresence() } }
}
