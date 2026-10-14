import SwiftUI
import LemonBotKit

struct AccountCleanupSettingsView: View {
    let store: LemonBotStore
    @State private var operations: [AccountTeardown] = []
    @State private var cursor: String?
    @State private var userID = ""
    @State private var state = "all"
    @State private var control = AdminControl()

    var body: some View {
        List {
            if store.member?.role == "owner" {
                Section("Read-only operational recovery") {
                    Text("Account sessions revoke immediately. Product cleanup and provider cleanup are separate observed outcomes. This view never deletes an account, resends a provider revocation, restores login or exposes private deleted content.")
                    TextField("Deleted user ID (optional)", text: $userID)
                    AdminChoice(label: "Observed state", value: $state, options: ["all", "pending", "running", "completed", "failed", "outcome_unknown"])
                    Button("Read matching cleanup operations") { Task { await load() } }.disabled(control.busy)
                }
                ForEach(operations) { operation in
                    NavigationLink {
                        AccountCleanupDetailView(store: store, operationID: operation.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("User \(operation.userId)").font(.headline)
                            Text("\(operation.state) · product \(operation.productCleanup.state)")
                            Text("Operation \(operation.id) · request \(operation.requestId)").font(.caption)
                            Text("Updated \(adminDate(operation.updatedAtMs))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if cursor != nil { Button("Older cleanup operations") { Task { await load(more: true) } }.disabled(control.busy) }
                if control.busy { ProgressView("Reading durable cleanup observations…") }
                if let error = control.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            } else {
                Text("Only the enabled workspace Owner can inspect bounded account-cleanup metadata. This is not access to another person's private history.")
            }
        }
        .navigationTitle("Account cleanup")
        .task(id: store.account?.id) { await load() }
        .onChange(of: userID) { _, _ in cursor = nil }
        .onChange(of: state) { _, _ in cursor = nil }
    }

    private func load(more: Bool = false) async {
        guard store.member?.role == "owner" else { operations = []; cursor = nil; return }
        let accountID = store.account?.id
        let requestedUser = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedState = state
        await control.perform {
            var query: [String: String] = [:]
            if !requestedUser.isEmpty { query["userId"] = requestedUser }
            if requestedState != "all" { query["state"] = requestedState }
            if more, let cursor { query["cursor"] = cursor }
            let page: Page<AccountTeardown> = try await store.read("/account-teardowns", query: query)
            guard store.account?.id == accountID, store.member?.role == "owner" else { return }
            operations = more ? hubMerged(operations, page.items, append: true, id: \.id) : page.items
            cursor = page.nextCursor
        }
    }
}

private struct AccountCleanupDetailView: View {
    let store: LemonBotStore
    let operationID: ID
    @State private var operation: AccountTeardown?
    @State private var control = AdminControl()

    var body: some View {
        Form {
            if store.member?.role == "owner" {
                if let operation {
                    Section("Durable account operation") {
                        LabeledContent("Operation", value: operation.id)
                        LabeledContent("User", value: operation.userId)
                        LabeledContent("Workspace", value: operation.workspaceId)
                        LabeledContent("Overall observed state", value: operation.state)
                        Text("Request ID: \(operation.requestId)").textSelection(.enabled)
                        Text("Started: \(operation.startedAtMs.map(adminDate) ?? "not observed")")
                        Text("Completed: \(operation.completedAtMs.map(adminDate) ?? "not observed")")
                        Button("Copy safe operation diagnostics") {
                            copyText("operation=\(operation.id) user=\(operation.userId) request=\(operation.requestId) state=\(operation.state)")
                        }
                    }
                    Section("Product cleanup") {
                        CleanupObservationView(result: operation.productCleanup)
                        Text("Product-owned data removal is independent of provider availability. A missing private row does not prove an external grant was revoked.").font(.caption)
                    }
                    Section("Actual provider targets") {
                        ForEach(Array(operation.providerCleanup.enumerated()), id: \.offset) { _, provider in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(provider.kind) · provider \(provider.providerId)").font(.headline)
                                Text("Observed: \(provider.state) · \(adminDate(provider.updatedAtMs))")
                                if let error = provider.errorCode { Text("Bounded error: \(error)").foregroundStyle(.orange) }
                                if let receipt = provider.receiptId { Text("Original receipt: \(receipt)").font(.caption).textSelection(.enabled) }
                            }
                        }
                        Text("Pending, failed or unknown provider cleanup is not completed. Refresh only reads the original receipt/status; it never re-dispatches deletion or revocation. Host files, backups and independently held external copies can remain.").font(.caption)
                    }
                }
                Button("Refresh read-only observations") { Task { await load() } }.disabled(control.busy)
                if control.busy { ProgressView("Reading actual cleanup observations…") }
                if let error = control.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            } else { Text("Workspace Owner authority is required.") }
        }.navigationTitle("Cleanup observation").task(id: operationID) { await load() }
    }

    private func load() async {
        guard store.member?.role == "owner" else { operation = nil; return }
        let accountID = store.account?.id
        await control.perform {
            let result: AccountTeardown = try await store.read("/account-teardowns/\(adminPath(operationID))")
            guard store.account?.id == accountID, store.member?.role == "owner" else { return }
            operation = result
        }
    }
}

private struct CleanupObservationView: View {
    let result: AccountCleanupResult
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Observed: \(result.state)").font(.headline)
            Text("Updated: \(adminDate(result.updatedAtMs))")
            if let error = result.errorCode { Text("Bounded error: \(error)").foregroundStyle(.orange) }
        }
    }
}
