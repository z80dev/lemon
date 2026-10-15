import SwiftUI
import LemonBotKit

struct SearchPaletteView: View {
    let store: LemonBotStore
    init(store: LemonBotStore) { self.store = store }
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            SearchHubView(store: store)
                .toolbar { Button("Close") { dismiss() } }
        }.frame(minWidth: 340, minHeight: 500)
    }
}
struct InboxView: View {
    let store: LemonBotStore
    init(store: LemonBotStore) { self.store = store }
    @State private var unread = false
    @State private var action = UIActionState()
    var body: some View {
        List {
            SwiftUI.Section {
                Toggle("Unread only", isOn: $unread)
                Text("Notices don't approve anything. Open the item to see what's needed.").font(LBFont.meta)
                Button("Mark all notices read") { Task { await action.perform {
                    let through = store.notifications.map(\.createdAtMs).max() ?? 0
                    let _: Empty = try await store.mutate("POST", "/notifications/read-all", body: ["throughAtMs": .number(Double(through))])
                    try await store.refresh()
                } } }.disabled(action.busy || store.connectionState != "online")
                ActionErrorView(message: action.error)
            }
            if store.notifications.filter({ $0.dismissedAtMs == nil && (!unread || $0.readAtMs == nil) }).isEmpty {
                ContentUnavailableView(unread ? "No unread notices" : "No notices", systemImage: "bell", description: Text("Approvals and results from your Bots appear here."))
            }
            ForEach(store.notifications.filter { $0.dismissedAtMs == nil && (!unread || $0.readAtMs == nil) }.sorted { $0.createdAtMs > $1.createdAtMs }) { notice in
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text(notice.title).fontWeight(notice.readAtMs == nil ? .bold : .regular); Spacer(); StatusBadge(text: notice.kind) }
                    Text(notice.body)
                    Text(timestamp(Double(notice.createdAtMs)), style: .date).font(.caption)
                    HStack {
                        Button("Open item") { Task { await action.perform {
                            guard let url = URL(string: notice.deepLink) else { return }
                            try await store.navigate(url)
                            try await store.acknowledgeNotification(notice.id)
                        } } }
                        Button(notice.readAtMs == nil ? "Mark read" : "Mark unread") { Task { await update(notice, read: notice.readAtMs == nil, dismiss: false) } }
                        if ["result", "error", "machine"].contains(notice.kind) { Button("Dismiss notice") { Task { await update(notice, read: true, dismiss: true) } } }
                    }.buttonStyle(.borderless).disabled(action.busy || store.connectionState != "online")
                    if let id = notice.requestId { Button("Copy request ID") { copyText(id) }.font(.caption) }
                }.padding(.vertical, 4)
            }
            SwiftUI.Section("Notifications") {
                Text("Connection: \(store.isOnline ? "Online" : "Offline")")
                Text("Push notifications: \(store.capabilities?.apns == true ? "Set up on this server" : "Not set up on this server")")
                Text("Notices stay in the inbox even when push alerts are off.").font(LBFont.meta)
                NavigationLink("Notification settings") { SettingsHubView(store: store) }
            }
        }.navigationTitle("Inbox")
    }
    private func update(_ notice: BotNotification, read: Bool, dismiss: Bool) async {
        await action.perform {
            var body: JSONObject = ["revision": .number(Double(notice.revision)), "read": .bool(read)]
            if dismiss { body["dismissed"] = .bool(true) }
            let updated: BotNotification = try await store.mutate("PATCH", resourcePath("notifications", notice.id), body: body)
            if let index = store.notifications.firstIndex(where: { $0.id == updated.id }) { store.notifications[index] = updated }
        }
    }
}
