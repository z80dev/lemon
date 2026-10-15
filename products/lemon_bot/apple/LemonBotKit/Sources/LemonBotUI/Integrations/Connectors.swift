import SwiftUI
import LemonBotKit

struct SecretBindingDraft: Identifiable {
    let id = UUID()
    var header = "Authorization"
    var secretName = ""
    var body: JSONValue { .object(["header": .string(header), "secretName": .string(secretName)]) }
}
struct SecretBindingEditor: View {
    let secrets: [Secret]
    @Binding var bindings: [SecretBindingDraft]
    var body: some View {
        ForEach($bindings) { $binding in
            TextField("Header name (not credential)", text: $binding.header)
            Picker("Destination-local secret name", selection: $binding.secretName) {
                Text("Choose existing secret").tag("")
                ForEach(secrets) { Text("\($0.name) · \($0.scope)").tag($0.name) }
            }
            Button("Remove header binding", role: .destructive) { bindings.removeAll { $0.id == binding.id } }
        }
        Button("Bind a header to an existing secret name") { bindings.append(SecretBindingDraft()) }
    }
}

struct ConnectorSettingsView: View {
    let store: LemonBotStore
    @State private var control = AdminControl()
    @State private var botID = ""
    @State private var connectors: [Connector] = []
    @State private var secrets: [Secret] = []
    @State private var providers: [IntegrationProvider] = []
    @State private var name = ""
    @State private var url = ""
    @State private var account = ""
    @State private var auth = "none"
    @State private var level = "read_only"
    @State private var bindings: [SecretBindingDraft] = []
    @State private var selectedLoadedBot = ""
    @State private var acceptedSharedHost = false
    @State private var setupResult: ConnectorSetupResult?
    private var bot: Bot? { store.bots.first { $0.id == botID } }
    var body: some View {
        Form {
            AdminStatus(control: control, store: store)
            Section("Assigned Bot and account inventory") {
                AdminBotPicker(store: store, value: $botID)
                Button("Load selected Bot connectors and destination secret names") { Task { await control.perform { try await loadBot() } } }.disabled(botID.isEmpty || control.busy)
                if let bot { Text("\(bot.name) · machine \(store.machines.first { $0.id == bot.machineId }?.name ?? bot.machineId)") }
                ForEach(connectors) { connector in
                    NavigationLink("\(connector.name) · \(connector.accountLabel) · \(connector.state)") { ConnectorDetailSettingsView(store: store, connector: connector) }
                    if let error = connector.lastError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
                Text("Added is not connected. Labeled accounts are separate and retain actual account-owner authority; tools discovered from a server remain subject to its permissions and account consent.")
            }
            Section("Real eligible provider prerequisites") {
                ForEach(providers.filter { $0.kind == "connector" }, id: \.id) { value in
                    ProviderPrerequisites(label: value.label, kind: value.kind, configured: value.configured, prerequisites: value.prerequisites, capabilities: value.capabilities)
                }
            }
            Section("Custom HTTPS MCP setup on the assigned machine") {
                TextField("Connection name", text: $name); TextField("HTTPS streamable MCP URL", text: $url); TextField("Account label", text: $account)
                AdminChoice(label: "Authentication", value: $auth, options: ["none", "secret_headers", "oauth"])
                AdminChoice(label: "Requested access", value: $level, options: ["off", "read_only", "read_interact"])
                if auth == "secret_headers" { SecretBindingEditor(secrets: secrets, bindings: $bindings) }
                if let bot { NavigationLink("Manage write-only named secrets on this host") { MachineDetailView(store: store, machineID: bot.machineId) } }
                Text("Only secret names are sent. Values stay encrypted on the destination, expanded as ${LEMON_SECRET:NAME}; missing references fail closed. Co-resident Bots share this OS user's files/browser/CLI identities. Separate OS users/machines are required for hard isolation.")
                Toggle("I reviewed the Bot, assigned host, account and requested access", isOn: $acceptedSharedHost)
                AdminAction(title: "Set up connector with effective host grants", store: store, control: control) {
                    guard let bot else { throw AdminFormError("Select a Bot first.") }
                    setupResult = try await store.mutate("POST", "/bots/\(adminPath(bot.id))/connectors/setup", body: ["machineId": .string(bot.machineId), "name": .string(name), "url": .string(url), "accountLabel": .string(account), "authKind": .string(auth), "secretBindings": .array(auth == "secret_headers" ? bindings.map(\.body) : []), "requestedLevel": .string(level)], as: ConnectorSetupResult.self)
                    acceptedSharedHost = false; try await loadBot()
                }.disabled(bot == nil || botID != selectedLoadedBot || !acceptedSharedHost || (auth == "secret_headers" && bindings.contains { $0.secretName.isEmpty }))
                if let result = setupResult {
                    Text("Acknowledged connector \(result.connector.name) · \(result.connector.state) · machine \(result.machineId)")
                    ForEach(result.grants) { Text("\($0.capabilityId): requested \($0.requestedLevel), effective \($0.effectiveLevel) · \($0.reasons.joined(separator: "; "))") }
                }
            }
        }.navigationTitle("Connect apps").task { await control.perform { providers = try await store.read("/integration-providers", as: [IntegrationProvider].self) } }
            .onChange(of: botID) { _, _ in
                connectors = []; secrets = []; selectedLoadedBot = ""; setupResult = nil; acceptedSharedHost = false; bindings = []
            }
    }
    private func loadBot() async throws {
        selectedLoadedBot = ""; bindings = []; secrets = []; connectors = []
        guard let bot else { throw AdminFormError("Select an accessible Bot.") }
        connectors = try await adminReadAll(store, "/bots/\(adminPath(bot.id))/connectors", as: Connector.self)
        secrets = try await adminReadAll(store, "/machines/\(adminPath(bot.machineId))/secrets", as: Secret.self)
        selectedLoadedBot = bot.id
    }
}

struct ConnectorToolDraft: Identifiable { var id: String { name }; let name: String; var enabled: Bool; var body: JSONValue { .object(["name": .string(name), "enabled": .bool(enabled)]) } }
struct ConnectorDetailSettingsView: View {
    let store: LemonBotStore
    let connector: Connector
    @Environment(\.openURL) private var openURL
    @State private var control = AdminControl()
    @State private var current: Connector?
    @State private var name = ""
    @State private var label = ""
    @State private var tools: [ConnectorToolDraft] = []
    @State private var authFlow: ConnectorAuth?
    @State private var secrets: [Secret] = []
    @State private var bindings: [SecretBindingDraft] = []
    @State private var replaceBindings = false
    private var value: Connector { current ?? connector }
    var body: some View {
        Form {
            AdminStatus(control: control, store: store)
            Section("Actual account and server") {
                Text("\(value.state) · owner \(value.ownerUserId)")
                Text(value.url).textSelection(.enabled)
                if let error = value.lastError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                TextField("Connection name", text: $name); TextField("Account label", text: $label)
                ForEach($tools) { $tool in Toggle(tool.name, isOn: $tool.enabled) }
                Toggle("Replace destination secret header bindings", isOn: $replaceBindings)
                if replaceBindings { Text("Existing secret header names: \(value.secretHeaderNames.joined(separator: ", ")). Values are never returned."); SecretBindingEditor(secrets: secrets, bindings: $bindings) }
                AdminAction(title: "Save account label and complete tool controls", store: store, control: control) {
                    var body: JSONObject = ["revision": .number(Double(value.revision)), "name": .string(name), "accountLabel": .string(label), "tools": .array(tools.map(\.body))]
                    if replaceBindings { body["secretBindings"] = .array(bindings.map(\.body)) }
                    current = try await store.mutate("PATCH", "/connectors/\(adminPath(value.id))", body: body, as: Connector.self)
                }
            }
            Section("Authorization — explicit external account") {
                AdminAction(title: "Authenticate / reconnect", store: store, control: control) {
                    authFlow = try await store.mutate("POST", "/connectors/\(adminPath(value.id))/auth", body: [:], as: ConnectorAuth.self)
                }
                if let flow = authFlow {
                    Text("\(flow.state) · expires \(adminDate(Double(flow.expiresAtMs)))")
                    if let url = URL(string: flow.authorizationUrl), url.scheme == "https" { Button("Open / reopen external authorization") { openURL(url) } }
                    Button("Check authorization status (no replay)") { Task { await control.perform {
                        authFlow = try await store.read("/connector-auth/\(adminPath(flow.id))", as: ConnectorAuth.self)
                        try await refreshConnector()
                    } } }
                }
                Text("Authorizing a server does not approve a risky tool action or another Bot's use of your account. Product policy and provider-admin denial remain distinct backend errors.")
            }
            AdminPreviewDelete(store: store, path: "/connectors/\(adminPath(value.id))", action: "disconnect", completed: {
                control.notice = "Disconnected. Retained history/artifacts and actual provider revocation outcome are disclosed by the preview; externally retained authorization may need provider cleanup."
            })
            Button("Refresh server state and discovered tools") { Task { await control.perform { try await refreshConnector() } } }
        }.navigationTitle(connector.name).task {
            name = connector.name; label = connector.accountLabel; tools = connector.tools.map { ConnectorToolDraft(name: $0.name, enabled: $0.enabled) }
            await control.perform {
                guard let bot = store.bots.first(where: { $0.id == connector.botId }) else { throw AdminFormError("The connector's Bot is unavailable.") }
                secrets = try await adminReadAll(store, "/machines/\(adminPath(bot.machineId))/secrets", as: Secret.self)
            }
        }
    }
    private func refreshConnector() async throws {
        let items = try await adminReadAll(store, "/bots/\(adminPath(connector.botId))/connectors", as: Connector.self)
        guard let result = items.first(where: { $0.id == connector.id }) else { throw AdminFormError("Connector no longer exists or is inaccessible.") }
        current = result; name = result.name; label = result.accountLabel; tools = result.tools.map { ConnectorToolDraft(name: $0.name, enabled: $0.enabled) }
    }
}
