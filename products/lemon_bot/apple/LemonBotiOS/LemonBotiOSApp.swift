import SwiftUI
import UIKit
import AVFoundation
import LemonBotKit
import LemonBotUI
import UniformTypeIdentifiers

@MainActor
@main
struct LemonBotiOSApp: App {
    @UIApplicationDelegateAdaptor(LemonBotAppDelegate.self) private var delegate
    @State private var store = LemonBotStore()
    var body: some Scene {
        WindowGroup { NativeLemonBotView(store: store, delegate: delegate) }
    }
}

private struct NativeSheet: Identifiable {
    let id = UUID()
    let action: String
    var capture: SharedCapture?
    var conversationID: ID?
    var accountID: String?
}

struct NativeLemonBotView: View {
    let store: LemonBotStore
    let delegate: LemonBotAppDelegate
    @State private var voice: NativeVoiceSession
    @State private var dictation = AppleSpeechCapture()
    @Environment(\.scenePhase) private var scenePhase
    @State private var sheet: NativeSheet?
    @State private var fileSelection: SharedCapture?
    @State private var filePicker = false
    @State private var stagedCount = 0
    @State private var localError: String?
    @State private var handlingNativeRequest = false

    init(store: LemonBotStore, delegate: LemonBotAppDelegate) {
        self.store = store
        self.delegate = delegate
        _voice = State(initialValue: NativeVoiceSession(store: store))
    }

    var body: some View {
        LemonBotRootView(store: store)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 4) {
                    if voice.active {
                        HStack {
                            Label(voice.capture.recording ? "Voice · Microphone on" : "Voice session active · microphone off", systemImage: voice.capture.recording ? "mic.fill" : "waveform")
                                .font(.caption).foregroundStyle(voice.capture.recording ? Color.red : Color.primary)
                            Spacer()
                            Button("Return") { sheet = NativeSheet(action: "voice") }
                            Button("Hang up") { Task { await voice.end() } }.disabled(voice.busy)
                        }
                    }
                    HStack {
                        Button { sheet = NativeSheet(action: "shares") } label: {
                            Label(stagedCount > 0 ? "Selected shares (\(stagedCount))" : "Selected shares", systemImage: "square.and.arrow.down")
                        }
                        Spacer()
                        Button { sheet = NativeSheet(action: "permissions") } label: { Label("iOS access", systemImage: "hand.raised") }
                    }.font(.caption)
                    if let error = localError ?? delegate.error ?? voice.error {
                        HStack(alignment: .top) {
                            Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                            Spacer()
                            Button("Details") { sheet = NativeSheet(action: "permissions") }.font(.caption)
                        }
                    }
                }
                .padding(8)
                .background(.bar)
            }
            .sheet(item: $sheet, onDismiss: { reloadShares() }) { request in
                switch request.action {
                case "camera":
                    if let capture = request.capture { ExplicitCameraPicker(capture: capture, completion: mediaFinished).ignoresSafeArea() }
                case "photos":
                    if let capture = request.capture { SelectedPhotoPicker(capture: capture, completion: mediaFinished).ignoresSafeArea() }
                case "dictation":
                    if let conversationID = request.conversationID {
                        DictationReviewView(capture: dictation, store: store, conversationID: conversationID, accountID: request.accountID)
                    }
                case "voice": NativeVoiceView(voice: voice, store: store)
                case "shares": ShareImportView(store: store)
                default: permissions
                }
            }
            .fileImporter(isPresented: $filePicker, allowedContentTypes: [.item], allowsMultipleSelection: true, onCompletion: filesFinished)
            .onOpenURL { url in
                if url.scheme == "lemonbot", url.host == "auth", url.path == "/complete" { return }
                if url.scheme == "lemonbot", url.host == "share", url.path.isEmpty, url.query == nil, url.fragment == nil {
                    reloadShares()
                    sheet = NativeSheet(action: "shares")
                } else { Task { await delegate.open(url) } }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("LemonBot.platformComposerRequest"))) { event in
                guard let action = event.userInfo?["action"] as? String, let conversationID = event.userInfo?["conversationID"] as? String else { return }
                Task { await handle(action: action, conversationID: conversationID) }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("LemonBot.visibleConversationChanged"))) { event in
                delegate.visibleConversationID = event.userInfo?["conversationID"] as? String
                Task { await delegate.publishPresence() }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("LemonBot.platformNotificationsRequest"))) { _ in Task { await delegate.requestPermission() } }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("LemonBot.platformSettingsRequest"))) { _ in openSettings() }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { event in
                guard let raw = event.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let interruption = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                if interruption == .ended { voice.foreground = scenePhase == .active; return }
                dictation.cancel(clearText: false)
                voice.background()
                localError = "Audio was interrupted. Microphone capture stopped; choose Record explicitly to resume when the app is active."
            }
            .onChange(of: scenePhase) { _, phase in
                delegate.foreground = phase == .active
                if phase == .active {
                    voice.foreground = true
                    reloadShares()
                    Task { await delegate.inspectPermission(); await voice.reconcile(); await delegate.publishPresence() }
                } else {
                    dictation.cancel(clearText: false)
                    voice.background()
                    Task { await delegate.publishPresence() }
                }
            }
            .onChange(of: store.voiceSession) { _, _ in voice.observeSessionState() }
            .onChange(of: store.connectionState) { _, state in
                if state == "online" {
                    Task {
                        await delegate.publishPresence()
                        if let url = delegate.pendingNavigationURL { await delegate.open(url) }
                    }
                }
            }
            .task(id: store.account?.id) {
                delegate.store = store
                delegate.registered = false
                delegate.visibleConversationID = nil
                dictation.cancel()
                voice.background()
                reloadShares()
                guard store.account != nil else { await voice.restore(); return }
                do {
                    if store.deviceID == nil { try await store.registerDevice(platform: "ios", name: UIDevice.current.name) }
                    await delegate.register()
                    await voice.restore()
                    voice.foreground = scenePhase == .active
                    await delegate.inspectPermission()
                    if let url = delegate.pendingNavigationURL { await delegate.open(url) }
                } catch { localError = error.localizedDescription }
            }
            .task {
                delegate.store = store
                reloadShares()
                while !Task.isCancelled {
                    await delegate.publishPresence()
                    try? await Task.sleep(for: .seconds(25))
                }
            }
            .task {
                while !Task.isCancelled {
                    await voice.speakReplies()
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
    }

    private var permissions: some View {
        NavigationStack {
            Form {
                Section("Notifications") {
                    Text("OS permission: \(delegate.permission)")
                    Text(delegate.registered ? "Actual APNs device token registered with this backend account." : "No confirmed APNs registration for this account.")
                    Text("Backend APNs configured: \(store.capabilities?.apns == true ? "Yes" : "No")")
                    Button("Request notification permission") { Task { await delegate.requestPermission() } }
                    Button("Register current APNs token") { Task { await delegate.register() } }.disabled(store.account == nil)
                    Text("APNs delivery requires the operator's key ID, team ID, private .p8 key and allowlisted bundle topic. Backend registration errors below report the actual missing prerequisite.").font(.caption)
                }
                Section("Explicit photo, camera and voice access") {
                    Text("Photos uses Apple's selected-item picker; Lemon Bot does not request unrestricted library access or save camera images to Photos. Camera permission is requested only after Camera. Microphone and Apple Speech permissions are requested only after Record. No ambient, lock-screen or background microphone capture.")
                    Text("Camera: \(cameraPermission)")
                    Text("Microphone: \(microphonePermission)")
                    Button("Open iOS Settings", action: openSettings)
                }
                if let error = localError { Section("Native input error") { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
                if let error = delegate.error { Section("Push or navigation error") { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
                if let error = voice.error { Section("Voice error") { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
                if delegate.pendingNavigationURL != nil {
                    Button("Retry selected link with ACL fetch") { Task { if let url = delegate.pendingNavigationURL { await delegate.open(url) } } }
                }
            }
            .navigationTitle("iOS permissions")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sheet = nil } } }
        }
    }

    private var cameraPermission: String {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return "Allowed"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not requested"
        @unknown default: return "Unknown"
        }
    }
    private var microphonePermission: String {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return "Allowed"
        case .denied: return "Denied"
        case .undetermined: return "Not requested"
        @unknown default: return "Unknown"
        }
    }

    @MainActor private func handle(action: String, conversationID: ID) async {
        guard scenePhase == .active, store.account != nil else { localError = "Sign in and keep Lemon Bot in the foreground before selecting native input."; return }
        if action == "stagedFiles" { publishStagedFiles(conversationID: conversationID); return }
        guard sheet == nil, !filePicker, !handlingNativeRequest else { return }
        handlingNativeRequest = true
        defer { handlingNativeRequest = false }
        localError = nil
        do {
            switch action {
            case "dictation":
                guard !voice.active else { throw CaptureError.message("A voice session owns the microphone. Use Record in that session or hang up before starting separate dictation.") }
                dictation.cancel()
                dictation.cuesEnabled = store.localSettings?.micCuesEnabled ?? true
                sheet = NativeSheet(action: "dictation", conversationID: conversationID, accountID: store.account?.id)
            case "voice":
                await voice.start(conversationID: conversationID)
                sheet = NativeSheet(action: "voice")
            case "shares":
                sheet = NativeSheet(action: "shares")
            case "camera", "photos", "files":
                guard let account = store.account, let workspace = store.workspace, let user = store.user else { throw CaptureError.message("Sign in before selecting files.") }
                if action == "camera" {
                    guard UIImagePickerController.isSourceTypeAvailable(.camera) else { throw CaptureError.message("This device has no available camera. Choose Photos or Files instead.") }
                    let granted = await AVCaptureDevice.requestAccess(for: .video)
                    guard granted else { throw CaptureError.message("Camera permission is denied or restricted. Enable Camera for Lemon Bot in iOS Settings, or choose an existing photo.") }
                    guard scenePhase == .active, store.account?.id == account.id else { return }
                }
                var capture = try ShareInbox.begin()
                capture.accountID = account.id
                capture.workspaceID = workspace.id
                capture.userID = user.id
                capture.conversationID = conversationID
                if action == "files" { fileSelection = capture; filePicker = true }
                else { sheet = NativeSheet(action: action, capture: capture) }
            default: throw CaptureError.message("Unknown native composer request: \(action)")
            }
        } catch { localError = error.localizedDescription }
    }

    @MainActor private func mediaFinished(_ result: Result<SharedCapture, Error>) {
        let cancelled = sheet?.capture
        sheet = nil
        switch result {
        case .success(let capture):
            if capture.files.isEmpty, capture.text.isEmpty { try? ShareInbox.discard(capture) }
            else { sheet = NativeSheet(action: "shares") }
        case .failure(let error):
            localError = error.localizedDescription
            if let cancelled, (try? ShareInbox.captures().contains(where: { $0.id == cancelled.id })) != true { try? ShareInbox.discard(cancelled) }
            sheet = NativeSheet(action: "shares")
        }
        reloadShares()
    }

    @MainActor private func filesFinished(_ result: Result<[URL], Error>) {
        guard var capture = fileSelection else { return }
        fileSelection = nil
        do {
            let urls = try result.get()
            guard urls.count <= 6 else { throw CaptureError.message("Select no more than six files for one message.") }
            for url in urls {
                capture.files.append(try ShareInbox.copy(url, into: capture))
                try ShareInbox.save(capture)
            }
            if capture.files.isEmpty { try ShareInbox.discard(capture) }
            else { sheet = NativeSheet(action: "shares") }
        } catch {
            if (error as NSError).code == NSUserCancelledError, capture.files.isEmpty { try? ShareInbox.discard(capture) }
            else {
                capture.error = error.localizedDescription
                localError = error.localizedDescription
                do { try ShareInbox.save(capture) } catch { localError = error.localizedDescription }
                sheet = NativeSheet(action: "shares")
            }
        }
        reloadShares()
    }

    private func reloadShares() {
        do {
            let captures = try ShareInbox.captures()
            stagedCount = captures.count
            if let accountID = store.account?.id {
                var names: [ID: [String]] = [:]
                for capture in captures where capture.accountID == accountID {
                    guard let conversationID = capture.conversationID else { continue }
                    for file in capture.files where file.attachmentID == nil {
                        names[conversationID, default: []].append(file.filename)
                    }
                }
                if let current = store.selectedConversationID, names[current] == nil { names[current] = [] }
                for (conversationID, filenames) in names {
                    NotificationCenter.default.post(name: Notification.Name("LemonBot.platformStagedFilesChanged"), object: nil, userInfo: ["conversationID": conversationID, "filenames": filenames])
                }
            }
        }
        catch { localError = error.localizedDescription }
    }
    private func publishStagedFiles(conversationID: ID) {
        do {
            var filenames: [String] = []
            for capture in try ShareInbox.captures() where capture.accountID == store.account?.id && capture.conversationID == conversationID {
                for file in capture.files where file.attachmentID == nil { filenames.append(file.filename) }
            }
            NotificationCenter.default.post(name: Notification.Name("LemonBot.platformStagedFilesChanged"), object: nil, userInfo: ["conversationID": conversationID, "filenames": filenames])
        } catch { localError = error.localizedDescription }
    }

    private func openSettings() { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
}

private struct DictationReviewView: View {
    @Bindable var capture: AppleSpeechCapture
    let store: LemonBotStore
    let conversationID: ID
    let accountID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Review before attaching") {
                    Text("Conversation: \(store.conversations.first(where: { $0.id == conversationID })?.name ?? conversationID)")
                    Text("Record explicitly, then stop, review and edit. Adding this text to the composer never sends it.").font(.caption)
                    if capture.preparing { ProgressView("Requesting Apple Speech and microphone access…") }
                    if capture.recording {
                        Label("Microphone on", systemImage: "mic.fill").foregroundStyle(.red)
                        Button("Stop and review") { capture.stop() }
                    } else {
                        Button("Record dictation") { Task { await capture.start(language: store.user?.preferences.voice.language) } }.disabled(capture.preparing)
                    }
                    if !capture.processing.isEmpty { Text(capture.processing).font(.caption) }
                    TextEditor(text: $capture.text).frame(minHeight: 160)
                    Button("Add reviewed text to unsent composer") {
                        guard store.account?.id == accountID else { error = "Account changed. Return to the original account before attaching this dictation."; return }
                        let current = store.draft(for: conversationID)
                        guard store.setLocalDraft(conversationID: conversationID, text: current.text + (current.text.isEmpty ? "" : "\n") + capture.text, attachmentIDs: current.attachmentIDs, replyTo: current.replyToEntryID) else {
                            error = store.errorMessage ?? "The reviewed dictation could not be saved to this local draft."
                            return
                        }
                        capture.cancel()
                        dismiss()
                    }.disabled(capture.text.isEmpty || capture.recording || capture.preparing)
                }
                if let failure = error ?? capture.error {
                    Section("Speech error") {
                        Text(failure).foregroundStyle(.red).textSelection(.enabled)
                        Button("Open iOS Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                    }
                }
            }
            .navigationTitle("Dictation")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { capture.cancel(); dismiss() } } }
            .interactiveDismissDisabled(capture.recording || capture.preparing)
            .onDisappear { capture.cancel() }
        }
    }
}
