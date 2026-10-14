import SwiftUI
import AVFoundation
import UserNotifications
import UniformTypeIdentifiers
import LemonBotKit

struct AccountSettingsView: View {
    let store: LemonBotStore
    @State private var control = AdminControl()
    @State private var user: User?
    @State private var name = ""
    @State private var email = ""
    @State private var avatar = ""
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var reauthPassword = ""
    @State private var reauthToken = ""
    @State private var sessions: [AuthSession] = []
    @State private var devices: [Device] = []
    @State private var importingAvatar = false
    var body: some View {
        Form {
            AdminStatus(control: control, store: store)
            Section("Your account") {
                TextField("Display name", text: $name)
                TextField("Email", text: $email)
                TextField("Avatar attachment ID (empty clears)", text: $avatar)
                Button("Upload an avatar image") { importingAvatar = true }.disabled(control.busy || store.connectionState != "online")
                AdminAction(title: "Save account", store: store, control: control) {
                    guard let user else { return }
                    self.user = try await store.mutate("PATCH", "/me", body: ["revision": .number(Double(user.revision)), "displayName": .string(name), "email": .string(email), "avatarAttachmentId": avatar.isEmpty ? .null : .string(avatar)], as: User.self)
                    try await store.refresh()
                }.disabled(user == nil)
            }
            Section("Password") {
                SecureField("Current password", text: $currentPassword)
                SecureField("New password (12–1024 UTF-8 bytes)", text: $newPassword)
                AdminAction(title: "Change password and revoke other sessions", store: store, control: control) {
                    _ = try await store.mutate("PUT", "/me/password", body: ["currentPassword": .string(currentPassword), "newPassword": .string(newPassword)], as: Empty.self)
                    currentPassword = ""; newPassword = ""; try await loadSessions()
                }
            }
            Section("Saved accounts on this device") {
                ForEach(store.accounts, id: \.id) { account in
                    Button("\(account.displayName) · \(account.email) · \(account.baseURL.host ?? "")") {
                        Task { await control.perform { try await store.restoreAccount(account) } }
                    }.disabled(control.busy)
                }
                AdminAction(title: "Sign out of current account", store: store, control: control) { try await store.signOut() }
            }
            Section("Product sessions") {
                ForEach(sessions) { session in
                    VStack(alignment: .leading) {
                        Text(session.current ? "Current session" : session.id)
                        Text("Last seen \(adminDate(Double(session.lastSeenAtMs))) · expires \(adminDate(Double(session.expiresAtMs)))").font(.caption)
                        AdminAction(title: "Revoke session", store: store, control: control, destructive: true) {
                            _ = try await store.mutate("DELETE", "/auth/sessions/\(adminPath(session.id))", body: [:], as: Deleted.self)
                            if session.current { try await store.signOut() } else { try await loadSessions() }
                        }
                    }
                }
            }
            Section("Registered devices") {
                ForEach(devices) { device in
                    DeviceSettingsRow(store: store, device: device, refresh: loadDevices)
                }
            }
            Section("Account-wide deletion") {
                Text("Deletion revokes product access and removes the previewed personal resources across all devices. Transfer final workspace ownership first. Host files, browser sessions, destination credentials, external provider authorizations/subscriptions and retained operator backups are separate. Mailbox retirement is only complete when the provider acknowledges it; unknown cleanup is not success.")
                SecureField("Password for one-use reauthentication", text: $reauthPassword)
                AdminAction(title: "Reauthenticate", store: store, control: control) {
                    let result = try await store.mutate("POST", "/auth/reauth", body: ["password": .string(reauthPassword)], as: ReauthResult.self)
                    reauthPassword = ""; reauthToken = result.reauthToken
                }
                OIDCVerificationView(store: store, purpose: "reauth", reauthToken: $reauthToken)
                if !reauthToken.isEmpty {
                    AdminPreviewDelete(store: store, path: "/me", additional: ["reauthToken": .string(reauthToken)]) {
                        reauthToken = ""; try await store.signOut()
                    }
                }
            }
            Button("Refresh account, sessions and devices") { Task { await control.perform { try await load() } } }
        }.navigationTitle("Account").task { await control.perform { try await load() } }
            .fileImporter(isPresented: $importingAvatar, allowedContentTypes: [.image]) { result in
                Task { await control.perform {
                    guard store.connectionState == "online" else { throw ClientError.offline }
                    let url = try result.get()
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                    let attachment = try await store.upload(fileURL: url, mime: mime, metadata: ["purpose": .string("avatar")])
                    avatar = attachment.id
                    control.notice = "Avatar uploaded. Save account to apply this image."
                } }
            }
            .onDisappear { currentPassword = ""; newPassword = ""; reauthPassword = ""; reauthToken = "" }
    }
    private func loadSessions() async throws { sessions = try await adminReadAll(store, "/auth/sessions", as: AuthSession.self) }
    private func loadDevices() async throws { devices = try await adminReadAll(store, "/devices", as: Device.self) }
    private func load() async throws {
        let value = try await store.read("/me", as: User.self)
        user = value; name = value.displayName; email = value.email; avatar = value.avatarAttachmentId ?? ""
        try await loadSessions(); try await loadDevices()
    }
}

struct DeviceSettingsRow: View {
    let store: LemonBotStore
    let device: Device
    let refresh: () async throws -> Void
    @State private var control = AdminControl()
    @State private var name = ""
    @State private var enabled = false
    var body: some View {
        VStack(alignment: .leading) {
            Text("\(device.platform) · \(device.appVersion) · last seen \(adminDate(Double(device.lastSeenAtMs)))").font(.caption)
            TextField("Device name", text: $name)
            Toggle("Push enabled", isOn: $enabled)
            AdminAction(title: "Save device", store: store, control: control) {
                _ = try await store.mutate("PATCH", "/devices/\(adminPath(device.id))", body: ["revision": .number(Double(device.revision)), "name": .string(name), "pushEnabled": .bool(enabled)], as: Device.self)
                try await refresh()
            }
            AdminAction(title: "Remove registered device", store: store, control: control, destructive: true) {
                _ = try await store.mutate("DELETE", "/devices/\(adminPath(device.id))", body: [:], as: Deleted.self); try await refresh()
            }
            if let error = control.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }.onAppear { name = device.name; enabled = device.pushEnabled }
    }
}

struct PreferencesSettingsView: View {
    let store: LemonBotStore
    @State private var control = AdminControl()
    @State private var user: User?
    @State private var appearance = "system"
    @State private var language = ""
    @State private var timezone = "UTC"
    @State private var colors = true
    @State private var beside = true
    @State private var celebrations = true
    @State private var enabled = true
    @State private var sound = true
    @State private var previews = true
    @State private var completed = true
    @State private var needsInput = true
    @State private var voice = "default"
    @State private var speed = 1.0
    @State private var voiceLanguage = ""
    @State private var permission = "Checking permission…"
    @State private var player: AVAudioPlayer?
    @State private var synthesizer = AVSpeechSynthesizer()
    @State private var deviceVoice = ""
    var body: some View {
        Form {
            AdminStatus(control: control, store: store)
            Section("Appearance and locale") {
                AdminChoice(label: "Appearance", value: $appearance, options: ["system", "light", "dark"])
                TextField("Language (empty uses default)", text: $language)
                TextField("IANA timezone", text: $timezone)
                Toggle("Bot colors", isOn: $colors)
                Toggle("Threads beside chat", isOn: $beside)
                Toggle("Verified milestone celebrations", isOn: $celebrations)
            }
            Section("Notifications") {
                Toggle("Enabled", isOn: $enabled); Toggle("Sound", isOn: $sound)
                Toggle("Content previews", isOn: $previews); Toggle("Completed work", isOn: $completed); Toggle("Needs input", isOn: $needsInput)
                Text(permission)
                Button("Request notification permission") {
                    Task { await control.perform {
                        #if os(iOS)
                        NotificationCenter.default.post(name: .init("LemonBot.platformNotificationsRequest"), object: nil)
                        #else
                        _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
                        NSApplication.shared.registerForRemoteNotifications()
                        #endif
                        await loadPermission()
                    } }
                }
                Button("Refresh OS permission status") { Task { await loadPermission() } }
                Text("APNs: \(store.capabilities?.apns == true ? "configured" : "not configured"); in-app inbox remains available.")
                Button("Open OS notification settings") {
                    #if os(iOS)
                    NotificationCenter.default.post(name: .init("LemonBot.platformSettingsRequest"), object: nil)
                    #else
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
                    #endif
                }
                ForEach(store.bots) { bot in
                    Toggle("Notify for \(bot.name)", isOn: Binding(get: { bot.sidebar.notificationsEnabled }, set: { value in
                        Task { await control.perform {
                            _ = try await store.mutate("PATCH", "/bots/\(adminPath(bot.id))/sidebar", body: ["revision": .number(Double(bot.revision)), "notificationsEnabled": .bool(value)], as: Bot.self); try await store.refresh()
                        } }
                    })).disabled(control.busy || store.connectionState != "online")
                }
            }
            Section("Voice") {
                TextField("Voice ID", text: $voice)
                Slider(value: $speed, in: 0.5...2, step: 0.1)
                Text("Speed: \(speed, specifier: "%.1f")×")
                TextField("Voice language (empty uses default)", text: $voiceLanguage)
                Text("Backend transcription: \(store.capabilities?.stt == true ? "configured" : "unconfigured") · backend speech: \(store.capabilities?.tts == true ? "configured" : "unconfigured")")
                Text("Dictation is explicitly started and stays unsent for review. Microphone input and on-device speech are controlled by this device, not a remote Bot host.")
                AdminAction(title: "Preview configured backend voice", store: store, control: control) {
                    let result = try await store.mutate("POST", "/audio/speech", body: ["text": .string("Hello, I’m your Lemon Bot teammate. Ready when you are."), "voice": voiceBody], as: SpeechResult.self)
                    let url = try await store.download(attachmentID: result.attachment.id)
                    player = try AVAudioPlayer(contentsOf: url); player?.play()
                }
                Picker("On-device sample voice (separate from backend voice ID)", selection: $deviceVoice) {
                    Text("System default").tag("")
                    ForEach(AVSpeechSynthesisVoice.speechVoices(), id: \.identifier) { Text("\($0.name) · \($0.language)").tag($0.identifier) }
                }
                Button("Preview on-device speech — not backend audio") {
                    synthesizer.stopSpeaking(at: .immediate)
                    let sample = AVSpeechUtterance(string: "Hello, I’m your Lemon Bot teammate. Ready when you are.")
                    sample.voice = deviceVoice.isEmpty ? AVSpeechSynthesisVoice(language: voiceLanguage.isEmpty ? nil : voiceLanguage) : AVSpeechSynthesisVoice(identifier: deviceVoice)
                    sample.rate = AVSpeechUtteranceDefaultSpeechRate * Float(speed)
                    synthesizer.speak(sample)
                }
                Button("Stop sample") { player?.stop(); synthesizer.stopSpeaking(at: .immediate) }
                #if os(macOS)
                Button("Select actual microphone input device") {
                    NotificationCenter.default.post(name: .init("LemonBot.platformAudioSettingsRequest"), object: nil)
                }
                #endif
                Button("Open microphone privacy settings") {
                    #if os(iOS)
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    #else
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
                    #endif
                }
            }
            AdminAction(title: "Save preferences and notifications", store: store, control: control) {
                guard let user else { return }
                self.user = try await store.mutate("PATCH", "/me", body: ["revision": .number(Double(user.revision)), "preferences": .object(["appearance": .string(appearance), "language": language.isEmpty ? .null : .string(language), "timezone": .string(timezone), "botColors": .bool(colors), "threadsBesideChat": .bool(beside), "celebrationsEnabled": .bool(celebrations), "voice": voiceBody]), "notifications": .object(["enabled": .bool(enabled), "sound": .bool(sound), "previews": .bool(previews), "completed": .bool(completed), "needsInput": .bool(needsInput)])], as: User.self)
                try await store.refresh()
            }.disabled(user == nil)
        }.navigationTitle("Preferences").task {
            await loadPermission()
            await control.perform {
                let value = try await store.read("/me", as: User.self); user = value
                appearance = value.preferences.appearance; language = value.preferences.language ?? ""; timezone = value.preferences.timezone
                colors = value.preferences.botColors; beside = value.preferences.threadsBesideChat; celebrations = value.preferences.celebrationsEnabled
                voice = value.preferences.voice.voiceId; speed = value.preferences.voice.speed; voiceLanguage = value.preferences.voice.language ?? ""
                enabled = value.notifications.enabled; sound = value.notifications.sound; previews = value.notifications.previews; completed = value.notifications.completed; needsInput = value.notifications.needsInput
            }
        }.onDisappear { player?.stop(); synthesizer.stopSpeaking(at: .immediate) }
    }
    private var voiceBody: JSONValue { .object(["voiceId": .string(voice), "speed": .number(speed), "language": voiceLanguage.isEmpty ? .null : .string(voiceLanguage)]) }
    private func loadPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let label: String
        switch settings.authorizationStatus {
        case .notDetermined: label = "not requested"
        case .denied: label = "denied — recover in OS settings"
        case .authorized: label = "authorized"
        case .provisional: label = "provisional"
        #if os(iOS)
        case .ephemeral: label = "ephemeral"
        #endif
        @unknown default: label = "unknown"
        }
        permission = "OS authorization: \(label). OS permission is separate from product preferences and push-provider configuration."
    }
}

struct LocalSettingsView: View {
    let store: LemonBotStore
    @State private var summon = ""
    @State private var ptt = ""
    @State private var cues = true
    @State private var companion = false
    @State private var selectedBot = ""
    @State private var motion = "system"
    @State private var error: String?
    var body: some View {
        Form {
            Section("This device and account only") {
                #if os(macOS)
                TextField("Summon shortcut (empty disables)", text: $summon)
                TextField("Hold-to-talk shortcut (empty disables)", text: $ptt)
                Toggle("One selected-Bot compact companion", isOn: $companion)
                #endif
                AdminBotPicker(store: store, value: $selectedBot)
                Toggle("Microphone on/off cues", isOn: $cues)
                AdminChoice(label: "Reduced motion", value: $motion, options: ["system", "on", "off"])
                Text("No ambient listening, background clipboard capture or screen capture. Push-to-talk releases into an unsent reviewable draft; Escape discards.")
                Button("Save local settings") {
                    do {
                        guard var settings = store.localSettings else { throw CocoaError(.fileNoSuchFile) }
                        settings.summonShortcut = summon.isEmpty ? nil : summon; settings.pushToTalkShortcut = ptt.isEmpty ? nil : ptt
                        settings.micCuesEnabled = cues; settings.compactCompanionEnabled = companion; settings.selectedBotId = selectedBot.isEmpty ? nil : selectedBot; settings.reducedMotion = motion
                        try store.saveLocalSettings(settings); error = nil
                    } catch { self.error = error.localizedDescription }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
        }.navigationTitle("Local settings").onAppear {
            if let value = store.localSettings { summon = value.summonShortcut ?? ""; ptt = value.pushToTalkShortcut ?? ""; cues = value.micCuesEnabled; companion = value.compactCompanionEnabled; selectedBot = value.selectedBotId ?? ""; motion = value.reducedMotion }
        }
    }
}

struct AboutSettingsView: View {
    let store: LemonBotStore
    @State private var control = AdminControl()
    @State private var setup: SetupStatus?
    @State private var hosts: [AdminHostVersion] = []
    var body: some View {
        Form {
            AdminStatus(control: control, store: store)
            Section("Product and service") {
                Text("Lemon Bot · \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown client version")")
                Text("Platform: \(ProcessInfo.processInfo.operatingSystemVersionString)")
                if let setup { Text("Backend \(setup.version) · API \(setup.apiVersion)") }
                Text("Service connection: \(store.connectionState)")
                Text("Controller: \(store.capabilities?.controlConnected == true ? "connected" : "unavailable")")
                if let versions = store.capabilities?.minClientVersions {
                    Text("Minimum supported clients: macOS \(versions.macos) · iOS \(versions.ios) · web \(versions.web)")
                }
                Text("Update the native application separately from the backend and destination worker. The operator installs the configured package and restarts its service; updating a client never resets host files or a Bot image.")
                Text("Self-hosted usage, no Lemon subscription or trial. External provider billing and cancellation remain with that provider.")
                ForEach(hosts) { version in Text("\(version.name): Lemon \(version.host.lemonVersion) · \(version.host.os) \(version.host.osVersion)") }
            }
            Section("Copy diagnostics — never includes credentials or transcript") {
                Text("Account: \(store.user?.id ?? "none")\nWorkspace: \(store.workspace?.id ?? "none")\nConversation: \(store.selectedConversationID ?? "none")\nTime: \(Date().formatted())\nRead attempts: \(control.attempts)\nLast attempt: \(control.lastAttempt?.formatted() ?? "none")\nService: \(store.connectionState)\nLast error: \(store.errorMessage ?? control.error ?? "none")").textSelection(.enabled)
            }
            Button("Refresh service diagnostics") { Task { await control.perform { try await load() } } }
        }.navigationTitle("About").task { await control.perform { try await load() } }
    }
    private func load() async throws {
        setup = try await store.read("/setup", as: SetupStatus.self)
        hosts = []
        for machine in store.machines where machine.status == "online" {
            let host = try await store.read("/machines/\(adminPath(machine.id))/host", as: HostInfo.self)
            hosts.append(AdminHostVersion(id: machine.id, name: machine.name, host: host))
        }
    }
}

private struct AdminHostVersion: Identifiable {
    let id: String
    let name: String
    let host: HostInfo
}

#if os(iOS)
import UIKit
#else
import AppKit
#endif
