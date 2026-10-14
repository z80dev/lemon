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
        Window("Lemon Bot", id: "workspace") {
            LemonBotRootView(store: store)
                .frame(minWidth: 920, minHeight: 620)
                .background(MacWindowIdentity())
                .toolbar {
                    ToolbarItemGroup {
                        if let conversationID = store.selectedConversationID {
                            Button { platform.beginDictation(conversationID: conversationID) } label: { Label("Dictate", systemImage: "mic") }
                            Button { Task { await platform.startCall(conversationID: conversationID) } } label: { Label("Voice chat", systemImage: "waveform") }
                                .disabled(!platform.online)
                        }
                        Button { platform.summon() } label: { Label("Mini composer", systemImage: "square.and.pencil") }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if let error = platform.errorMessage {
                        HStack {
                            Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                            Spacer()
                            Button("Dismiss") { platform.errorMessage = nil }
                        }.padding(8).background(.regularMaterial)
                    }
                }
                .task { delegate.platform = platform; platform.start() }
                .onChange(of: store.account?.id) { _, _ in Task { await platform.accountChanged() } }
                .onChange(of: store.selectedConversationID) { _, _ in Task { await platform.publishPresence() } }
                .onChange(of: store.notifications) { _, _ in platform.notificationsChanged() }
                .onChange(of: store.entries) { _, _ in platform.entriesChanged() }
                .onChange(of: store.voiceSession) { _, session in
                    if session?.state != "active" || session?.muted == true { platform.cancelCapture(); platform.stopPlayback() }
                    platform.voiceSettings = session?.settings
                }
                .onOpenURL { url in Task { await platform.route(url) } }
                .onReceive(NotificationCenter.default.publisher(for: .init("LemonBot.platformComposerRequest"))) { notification in
                    guard let id = notification.userInfo?["conversationID"] as? String,
                          let action = notification.userInfo?["action"] as? String else { return }
                    switch action {
                    case "dictation": platform.beginDictation(conversationID: id)
                    case "voice": Task { await platform.startCall(conversationID: id) }
                    case "files": platform.chooseFiles(conversationID: id)
                    default: break
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .init("LemonBot.visibleConversationChanged"))) { notification in
                    platform.mainViewedConversationID = notification.userInfo?["conversationID"] as? String
                    Task { await platform.publishPresence() }
                }
                .onChange(of: store.bots) { _, _ in platform.updateCompanion() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in Task { await platform.publishPresence() } }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await platform.publishPresence() } }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in Task { await platform.publishPresence() } }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in Task { await platform.publishPresence() } }
        }.commands {
            CommandGroup(after: .newItem) {
                Button("Summon mini composer") { platform.summon() }
                Button("Return to active voice chat") { platform.showVoicePanel() }.disabled(store.voiceSession?.state != "active")
            }
        }
        Settings { MacSettingsView(controller: platform) }
        MenuBarExtra("Lemon Bot", systemImage: "leaf") {
            MacMenuBarView(controller: platform)
        }
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
        SettingsLink { Text("macOS settings…") }
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
