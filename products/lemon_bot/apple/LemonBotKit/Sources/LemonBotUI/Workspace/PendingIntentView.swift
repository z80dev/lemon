import SwiftUI
import LemonBotKit

struct PendingIntentView: View {
    let store: LemonBotStore
    init(store: LemonBotStore) { self.store = store }
    @State private var action = UIActionState()
    @State private var messages: [String: String] = [:]
    var body: some View {
        List {
            SwiftUI.Section {
                Text("These actions may not have finished. Check their status before trying again. Reconnecting never sends them again.")
                ActionErrorView(message: action.error)
            }
            ForEach(store.pendingIntents) { intent in
                VStack(alignment: .leading, spacing: 8) {
                    Text("Action not confirmed").font(LBFont.rowTitle)
                    Text("Started \(timestamp(intent.startedAtMs).formatted())").font(.caption)
                    DisclosureGroup("Details") {
                        Text("\(intent.method) \(intent.path)").textSelection(.enabled)
                        Text("Reference: \(intent.clientNonce)").textSelection(.enabled)
                        if let run = intent.runID { Text("Run: \(run)").textSelection(.enabled) }
                        ForEach(intent.resourceIDs, id: \.self) { id in Text("Resource: \(id)").textSelection(.enabled) }
                        Button("Copy") { copyText("\(intent.method) \(intent.path)\n\(intent.clientNonce)\n\(intent.resourceIDs.joined(separator: ", "))") }
                    }
                    if store.connectionState != "online" { Text("Reconnect to check this action.").font(LBFont.meta).foregroundStyle(LB.muted) }
                    Button("Check status") { Task { await action.perform {
                        let confirmed = try await store.reconcileMutation(intent.clientNonce)
                        messages[intent.clientNonce] = confirmed ? "The result is confirmed. Nothing was sent again." : "The result still isn't confirmed. Check the item or service before trying again."
                    } } }.disabled(action.inFlight || store.connectionState != "online")
                    if let message = messages[intent.clientNonce] { Text(message).font(LBFont.meta).foregroundStyle(LB.warning) }
                }.padding(.vertical, 6)
            }
            if store.pendingIntents.isEmpty { Text("No unconfirmed actions.") }
        }.navigationTitle("Unconfirmed actions")
    }
}
