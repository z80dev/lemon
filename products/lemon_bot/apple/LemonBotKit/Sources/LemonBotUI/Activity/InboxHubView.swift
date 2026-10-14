import SwiftUI
import LemonBotKit

struct InboxHubView: View {
    let store: LemonBotStore
    @State private var notifications: [BotNotification] = []
    @State private var cursor: String?
    @State private var unreadOnly = false
    @State private var action = HubAction()
    var body: some View {
        List {
            HubError(action: action)
            Toggle("Unread only", isOn: $unreadOnly).onChange(of: unreadOnly) { Task { await load() } }
            Text("Opening a notification only navigates to its exact authorized task, entry, approval, machine or routine. It never approves a decision. Read state is independent of pending gates.")
            ForEach(notifications.filter { $0.dismissedAtMs == nil }) { notification in
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(notification.readAtMs == nil ? "● " : "")\(notification.title)").font(.headline)
                    Text(notification.body).textSelection(.enabled)
                    Text("\(notification.kind) · \(hubDate(notification.createdAtMs))").font(.caption)
                    if let requestID = notification.requestId { Text("Request \(requestID)").font(.caption).textSelection(.enabled); Button("Copy diagnostic request ID") { hubCopy(requestID) } }
                    Button("Open exact target") { Task { await action.perform {
                        guard let url = URL(string: notification.deepLink) else { throw RoutineFormError.invalid("Invalid notification deep link; reload current notification.") }
                        try await store.navigate(url)
                        let _: BotNotification = try await store.mutate("PATCH", "/notifications/\(hubID(notification.id))", body: ["revision": .number(Double(notification.revision)), "read": .bool(true)])
                        try await refresh()
                    } } }
                    Button(notification.readAtMs == nil ? "Mark read" : "Mark unread") { Task { await action.perform {
                        let _: BotNotification = try await store.mutate("PATCH", "/notifications/\(hubID(notification.id))", body: ["revision": .number(Double(notification.revision)), "read": .bool(notification.readAtMs == nil)]); try await refresh()
                    } } }.disabled(action.busy || action.uncertain || store.connectionState != "online")
                    if notification.kind == "error" { Button("Clear this error notice only") { Task { await action.perform {
                        let _: BotNotification = try await store.mutate("PATCH", "/notifications/\(hubID(notification.id))", body: ["revision": .number(Double(notification.revision)), "dismissed": .bool(true)]); try await refresh()
                    } } }.disabled(action.busy || action.uncertain || store.connectionState != "online") }
                }
            }
            if cursor != nil { Button("More notifications") { Task { await load(more: true) } } }
            Section("Delivery diagnostics") {
                Text("Realtime: \(store.connectionState)")
                if let capabilities = store.capabilities { Text("APNs \(capabilities.apns ? "configured" : "not configured") · Web Push \(capabilities.webPush ? "configured" : "not configured")") }
                Text("OS permission and registered-device delivery settings are separate from this durable inbox. Use notification settings for permission recovery.")
                NavigationLink("Notification settings") { SettingsHubView(store: store) }
            }
        }.navigationTitle("Inbox").toolbar {
            Button("Refresh") { Task { await load() } }
            Button("Read through loaded notices") { Task { await action.perform {
                guard let through = notifications.map(\.createdAtMs).max() else { return }
                let _: HubOK = try await store.mutate("POST", "/notifications/read-all", body: ["throughAtMs": .number(through)]); try await refresh()
            } } }.disabled(notifications.isEmpty || action.busy || action.uncertain || store.connectionState != "online")
        }.task { await load() }
    }
    private func refresh(more: Bool = false) async throws {
        var query: [String: String] = [:]; if unreadOnly { query["unread"] = "true" }; if more, let cursor { query["cursor"] = cursor }
        let page: HubPage<BotNotification> = try await store.read("/notifications", query: query); notifications = hubMerged(notifications, page.items, append: more, id: \.id); cursor = page.nextCursor
    }
    private func load(more: Bool = false) async { await action.perform(readOnly: true) { try await refresh(more: more) } }
}
