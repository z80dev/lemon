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
                Text("Reading or dismissing a notice never approves a request. Open the exact action to inspect current authorization and expiry.").font(.caption)
                Button("Mark all displayed notices read") { Task { await action.perform {
                    let through = store.notifications.map(\.createdAtMs).max() ?? 0
                    let _: Empty = try await store.mutate("POST", "/notifications/read-all", body: ["throughAtMs": .number(Double(through))])
                    try await store.refresh()
                } } }.disabled(action.busy || store.connectionState != "online")
                ActionErrorView(message: action.error)
            }
            ForEach(store.notifications.filter { $0.dismissedAtMs == nil && (!unread || $0.readAtMs == nil) }.sorted { $0.createdAtMs > $1.createdAtMs }) { notice in
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text(notice.title).fontWeight(notice.readAtMs == nil ? .bold : .regular); Spacer(); StatusBadge(text: notice.kind) }
                    Text(notice.body)
                    Text(timestamp(Double(notice.createdAtMs)), style: .date).font(.caption)
                    HStack {
                        Button("Open exact target") { Task { await action.perform {
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
            SwiftUI.Section("Delivery diagnostics") {
                Text("Realtime: \(store.connectionState)")
                Text("Backend APNs configured: \(store.capabilities?.apns == true ? "yes" : "no")")
                Text("OS permission and per-device settings are independent of backend push configuration. Pending requests remain visible even without push.").font(.caption)
                NavigationLink("Notification settings / permission recovery") { SettingsHubView(store: store) }
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
