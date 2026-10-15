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
                Text("A timeout is not proof that an operation failed. These account-bound nonces survive restart, but contain no secret values, confirmation tokens or request bodies. A reconnect never resubmits them.")
                ActionErrorView(message: action.error)
            }
            ForEach(store.pendingIntents) { intent in
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(intent.method) \(intent.path)").font(.headline).textSelection(.enabled)
                    StatusBadge(text: intent.state)
                    Text("Started \(timestamp(intent.startedAtMs).formatted())").font(.caption)
                    Text("Nonce: \(intent.clientNonce)").font(.caption).textSelection(.enabled)
                    if let run = intent.runID { Text("Run: \(run)").font(.caption).textSelection(.enabled) }
                    ForEach(intent.resourceIDs, id: \.self) { id in Text("Exact resource: \(id)").font(.caption).textSelection(.enabled) }
                    Button("Read exact outcome · never replay") { Task { await action.perform {
                        let confirmed = try await store.reconcileMutation(intent.clientNonce)
                        messages[intent.clientNonce] = confirmed ? "An authoritative read confirmed the original outcome; its fence was released. Nothing was replayed." : "No authoritative proof is available yet. The original intent remains fenced. Inspect the exact target or provider; an unknown create without a returned ID cannot safely be repeated."
                    } } }.disabled(action.inFlight || store.connectionState != "online")
                    if let message = messages[intent.clientNonce] { Text(message).font(.caption).foregroundStyle(.orange) }
                    Button("Copy diagnostic IDs") { copyText("\(intent.method) \(intent.path)\nnonce \(intent.clientNonce)\nrun \(intent.runID ?? "not returned")\nresources \(intent.resourceIDs.joined(separator: ", "))") }.font(.caption)
                }.padding(.vertical, 6)
            }
            if store.pendingIntents.isEmpty { Text("No unresolved account-bound mutations.") }
        }.navigationTitle("Unconfirmed actions")
    }
}
