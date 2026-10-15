import AppKit
import LemonBotKit
import LemonBotUI
import SwiftUI
import UserNotifications

@MainActor
@main
struct LemonBotMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    @State private var store: LemonBotStore
    @State private var platform: MacPlatformController

    init() {
        let store = LemonBotStore()
        _store = State(initialValue: store)
        _platform = State(initialValue: MacPlatformController(store: store))
    }

    var body: some Scene {
        workspaceScene
        settingsScene
        menuBarScene
    }

    private var workspaceScene: some Scene {
        Window("Lemon Bot", id: "workspace") {
            workspaceContent
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 820)
        .commands { workspaceCommands }
    }

    private var settingsScene: some Scene {
        Settings { LemonBotSettingsView(store: store) { MacSettingsView(controller: platform) } }
    }

    private var menuBarScene: some Scene {
        MenuBarExtra("Lemon Bot", systemImage: "leaf") {
            MacMenuBarView(controller: platform)
        }
    }

    private var workspaceCommands: some Commands {
        CommandGroup(after: .newItem) {
            Button("Summon mini composer") { platform.summon() }
            Divider()
            Button("Dictate into current chat") { if let id = store.selectedConversationID { platform.beginDictation(conversationID: id) } }
                .disabled(store.selectedConversationID == nil)
            Button("Start voice chat") { if let id = store.selectedConversationID { Task { await platform.startCall(conversationID: id) } } }
                .disabled(store.selectedConversationID == nil || !platform.online)
            Button("Return to active voice chat") { platform.showVoicePanel() }
                .disabled(store.voiceSession?.state != "active")
        }
    }

    private var workspaceContent: some View {
        workspaceComposerEvents
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in Task { await platform.publishPresence() } }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task {
                    if store.account != nil, store.connectionState != "online", store.connectionState != "reconnect_required" {
                        do { try await store.refresh() } catch { platform.errorMessage = error.localizedDescription }
                    }
                    await platform.publishPresence()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in Task { await platform.publishPresence() } }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in Task { await platform.publishPresence() } }
    }

    private var workspaceComposerEvents: some View {
        workspaceAccountEvents
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("LemonBot.platformComposerRequest")), perform: handleComposerRequest)
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("LemonBot.visibleConversationChanged")), perform: handleVisibleConversationChanged)
            .onChange(of: store.bots) { _, _ in platform.updateCompanion() }
    }

    private var workspaceAccountEvents: some View {
        workspaceLayout
            .task { delegate.platform = platform; platform.start() }
            .onChange(of: store.account?.id) { _, _ in Task { await platform.accountChanged() } }
            .onChange(of: store.selectedConversationID) { _, _ in Task { await platform.publishPresence() } }
            .onChange(of: store.notifications) { _, _ in platform.notificationsChanged() }
            .onChange(of: store.entries) { _, _ in platform.entriesChanged() }
            .onChange(of: store.voiceSession) { _, session in updateVoiceCapture(session) }
            .onOpenURL { url in Task { await platform.route(url) } }
    }

    private var workspaceLayout: some View {
        LemonBotRootView(store: store)
            .frame(minWidth: 880, minHeight: 600)
            .background(MacWindowIdentity())
            .background(MacAudioSettingsRequestHandler())
            .overlay(alignment: .top) { workspaceError }
    }

    /// Platform errors float as a compact dismissible pill instead of a window-wide bar.
    @ViewBuilder private var workspaceError: some View {
        if let error = platform.errorMessage {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                Text(error).font(.system(size: 13)).textSelection(.enabled).lineLimit(3)
                Button { platform.errorMessage = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Dismiss error")
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .frame(maxWidth: 520)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .padding(.top, 60)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func updateVoiceCapture(_ session: VoiceSession?) {
        if session?.state != "active" || session?.muted == true {
            platform.cancelCapture()
            platform.stopPlayback()
        }
        platform.voiceSettings = session?.settings
    }

    private func handleComposerRequest(_ notification: Foundation.Notification) {
        guard let id = notification.userInfo?["conversationID"] as? String,
              let action = notification.userInfo?["action"] as? String else { return }
        switch action {
        case "dictation": platform.beginDictation(conversationID: id)
        case "voice": Task { await platform.startCall(conversationID: id) }
        case "files": platform.chooseFiles(conversationID: id)
        default: break
        }
    }

    private func handleVisibleConversationChanged(_ notification: Foundation.Notification) {
        platform.mainViewedConversationID = notification.userInfo?["conversationID"] as? String
        Task { await platform.publishPresence() }
    }
}

private struct MacMenuBarView: View {
    @Bindable var controller: MacPlatformController
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(controller.store.account?.displayName ?? "Not signed in")
        if let bot = controller.selectedBot {
            Text("\(bot.name) · \(bot.activity.replacingOccurrences(of: "_", with: " "))")
            Text(controller.store.machines.first { $0.id == bot.machineId }?.name ?? "Unknown machine")
        }
        Button("Open Lemon Bot") { openWindow(id: "workspace"); NSApp.activate(ignoringOtherApps: true) }
        Button("Summon mini composer") { controller.summon() }.disabled(controller.selectedBot == nil)
        Button("Return to voice chat") { controller.showVoicePanel() }.disabled(controller.store.voiceSession?.state != "active")
        SettingsLink { Text("Settings…") }
        Divider()
        if controller.store.accounts.count > 1 {
            Menu("Switch account") {
                ForEach(controller.store.accounts, id: \.id) { account in
                    Button("\(account.displayName) — \(account.baseURL.host ?? "")") {
                        Task { do { try await controller.store.restoreAccount(account) } catch { controller.errorMessage = error.localizedDescription } }
                    }.disabled(account.id == controller.store.account?.id)
                }
            }
        }
        Button("Sign out") {
            Task {
                controller.cancelCapture()
                controller.stopPlayback()
                do { try await controller.store.signOut() } catch { controller.errorMessage = error.localizedDescription }
            }
        }.disabled(controller.store.account == nil)
        Button("Quit Lemon Bot") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var pendingURLs: [URL] = []
    weak var platform: MacPlatformController? {
        didSet {
            guard let platform else { return }
            let urls = pendingURLs
            pendingURLs.removeAll()
            for url in urls { Task { await platform.route(url) } }
        }
    }

    func applicationDidFinishLaunching(_ notification: Foundation.Notification) {
        UNUserNotificationCenter.current().delegate = self
        NSApp.setActivationPolicy(.regular)
        NSUpdateDynamicServices()
    }
    func applicationWillTerminate(_ notification: Foundation.Notification) { platform?.cancelCapture(); platform?.stopPlayback() }
    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await platform?.registerPush(deviceToken) }
    }
    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        platform?.errorMessage = error.localizedDescription
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let platform { Task { await platform.route(url) } }
            else { pendingURLs.append(url) }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in
            guard let platform = self.platform, let workspace = notification.request.content.userInfo["workspaceId"] as? String,
                  platform.store.workspace?.id == workspace else { completionHandler([]); return }
            let info = notification.request.content.userInfo
            let room = info["conversationId"] as? String
            if let room, platform.viewedConversationID == room { completionHandler([]); return }
            let target = info["target"] as? [String: Any]
            if let botID = (info["botId"] as? String) ?? (target?["botId"] as? String),
               let bot = platform.store.bots.first(where: { $0.id == botID }), bot.sidebar.hidden || !bot.sidebar.notificationsEnabled {
                completionHandler([]); return
            }
            guard platform.store.user?.notifications.enabled == true else { completionHandler([]); return }
            completionHandler(platform.store.user?.notifications.sound == true ? [.banner, .list, .sound] : [.banner, .list])
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            defer { completionHandler() }
            guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
                  let raw = response.notification.request.content.userInfo["deepLink"] as? String,
                  let url = URL(string: raw) else { return }
            if let platform = self.platform { await platform.route(url) }
            else { self.pendingURLs.append(url) }
        }
    }
}

private struct MacAudioSettingsRequestHandler: View {
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .init("LemonBot.platformAudioSettingsRequest"))) { _ in
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}
