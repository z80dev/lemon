import UIKit
import UserNotifications
import Observation
import LemonBotKit

@MainActor @Observable
final class LemonBotAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var store: LemonBotStore?
    var permission = "Not requested"
    var error: String?
    var registered = false
    var foreground = true
    var visibleConversationID: ID?
    var pendingNavigationURL: URL?
    private var token: String?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func inspectPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized: permission = "Allowed"
        case .provisional: permission = "Quiet delivery"
        case .ephemeral: permission = "Temporary permission"
        case .denied: permission = "Denied — enable Notifications for Lemon Bot in iOS Settings"
        case .notDetermined: permission = "Not requested"
        @unknown default: permission = "Unknown OS authorization status"
        }
        if [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) { UIApplication.shared.registerForRemoteNotifications() }
    }

    func requestPermission() async {
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            await inspectPermission()
            if !allowed { error = "Notifications are denied. Enable Notifications for Lemon Bot in iOS Settings. In-app inbox decisions remain available." }
        } catch { self.error = error.localizedDescription }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await register() }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        registered = false
        self.error = error.localizedDescription
    }

    func register() async {
        guard let store, store.account != nil, let token else { return }
        do {
            guard let topic = Bundle.main.bundleIdentifier else { throw CaptureError.message("The signed application has no bundle identifier for its APNs topic.") }
            let configured = Bundle.main.object(forInfoDictionaryKey: "LemonBotAPNSEnvironment") as? String
            let environment: String
            switch configured {
            case "development": environment = "sandbox"
            case "production": environment = "production"
            default: throw CaptureError.message("Set APS_ENVIRONMENT to development or production in the app's signing build configuration. Info.plist and the signed aps-environment entitlement must use the same setting.")
            }
            try await store.registerDevice(platform: "ios", name: UIDevice.current.name, push: [
                "kind": .string("apns"), "token": .string(token), "environment": .string(environment), "topic": .string(topic)
            ])
            registered = true
            error = nil
        } catch { registered = false; self.error = error.localizedDescription }
    }

    func publishPresence() async {
        guard let store, store.deviceID != nil, store.connectionState == "online" else { return }
        do {
            try await store.setPresence(foreground: foreground, conversationID: foreground ? visibleConversationID : nil)
        } catch { self.error = error.localizedDescription }
    }

    func open(_ url: URL) async {
        guard let store else { pendingNavigationURL = url; return }
        do { try await store.navigate(url); pendingNavigationURL = nil }
        catch { pendingNavigationURL = url; self.error = error.localizedDescription }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let workspaceID = notification.request.content.userInfo["workspaceId"] as? String
        let conversationID = notification.request.content.userInfo["conversationId"] as? String
        let botID = (notification.request.content.userInfo["target"] as? [String: Any])?["botId"] as? String
        Task { @MainActor [weak self] in
            guard let self, let store = self.store, store.account != nil,
                  workspaceID == store.workspace?.id,
                  let preferences = store.user?.notifications, preferences.enabled else {
                completionHandler([]); return
            }
            if let botID, let bot = store.bots.first(where: { $0.id == botID }),
               bot.sidebar.hidden || !bot.sidebar.notificationsEnabled {
                completionHandler([]); return
            }
            let sameRoom = conversationID.map { $0 == self.visibleConversationID } ?? false
            if self.foreground && sameRoom { completionHandler([]); return }
            completionHandler(preferences.sound ? [.banner, .list, .sound] : [.banner, .list])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let payload = response.notification.request.content.userInfo
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let value = payload["deepLink"] as? String, let url = URL(string: value), url.scheme == "lemonbot" {
            Task { @MainActor [weak self] in await self?.open(url) }
        }
        completionHandler()
    }
}
