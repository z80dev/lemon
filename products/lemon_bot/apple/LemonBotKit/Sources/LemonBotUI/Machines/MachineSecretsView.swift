import SwiftUI
import LemonBotKit

struct MachineSecretsView: View {
    let store: LemonBotStore
    let machineID: ID
    @State private var secrets: [Secret] = []
    @State private var cursor: String?
    @State private var name = ""
    @State private var description = ""
    @State private var value = ""
    @State private var scope = "machine"
    @State private var botID = ""
    @State private var deleting: Secret?
    @State private var action = HubAction()
    var body: some View {
        Form {
            HubError(action: action)
            Text("Values are write-only and stored encrypted on this destination host. Bot scope is not OS isolation: privileged users and co-resident host processes retain full host access. Values never become chat drafts.")
            Section("Names only") {
                ForEach(secrets) { secret in
                    VStack(alignment: .leading) {
                        Text(secret.name).font(.headline)
                        Text("•••••••• · \(secret.scope) · \(secret.botId ?? machineID)")
                        Text(secret.description)
                        HStack {
                            Button("Replace") { name = secret.name; description = secret.description; scope = secret.scope; botID = secret.botId ?? ""; value = "" }
                            Button("Delete", role: .destructive) { deleting = secret }
                        }
                    }
                }
                if cursor != nil { Button("More names") { Task { await load(more: true) } } }
            }
            Section("Add / replace") {
                TextField("NAME", text: $name)
                TextField("Description", text: $description)
                Picker("Scope", selection: $scope) { Text("Shared machine").tag("machine"); Text("Bot").tag("bot") }
                if scope == "bot" {
                    Picker("Bot on this host", selection: $botID) { Text("Select Bot").tag(""); ForEach(store.bots.filter { $0.machineId == machineID }) { Text($0.name).tag($0.id) } }
                }
                SecureField("New value (never readable)", text: $value)
                Button("Save securely on destination") { Task { await action.perform {
                    defer { value = "" }
                    var body: JSONObject = ["description": .string(description), "value": .string(value), "scope": .string(scope)]
                    if scope == "bot" { body["botId"] = .string(botID) }
                    let _: Secret = try await store.mutate("PUT", "/machines/\(hubID(machineID))/secrets/\(hubID(name))", body: body)
                    try await refresh()
                } } }.disabled(name.isEmpty || value.isEmpty || (scope == "bot" && botID.isEmpty) || action.busy || action.uncertain || store.connectionState != "online")
                Button("Clear secret input") { value = "" }
            }
        }.navigationTitle("Host secrets").toolbar { Button("Refresh names") { Task { await load() } } }
            .task { await load() }.onDisappear { value = "" }
            .confirmationDialog("Delete named secret \(deleting?.name ?? "")? Existing history remains; future destination resolution will fail.", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Delete named secret", role: .destructive) { guard let secret = deleting else { return }; Task { await action.perform {
                    let _: HubDeleted = try await store.mutate("DELETE", "/machines/\(hubID(machineID))/secrets/\(hubID(secret.name))", body: [:]); deleting = nil; try await refresh()
                } } }.disabled(action.busy || action.uncertain || store.connectionState != "online")
            }
    }
    private func refresh(more: Bool = false) async throws {
        let page: HubPage<Secret> = try await store.read("/machines/\(hubID(machineID))/secrets", query: more ? ["cursor": cursor ?? ""] : [:]); secrets = hubMerged(secrets, page.items, append: more, id: \.id); cursor = page.nextCursor
    }
    private func load(more: Bool = false) async { await action.perform(readOnly: true) { try await refresh(more: more) } }
}
