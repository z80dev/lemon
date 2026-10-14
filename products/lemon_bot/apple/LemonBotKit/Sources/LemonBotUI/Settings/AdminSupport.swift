import SwiftUI
import Observation
import LemonBotKit

@MainActor @Observable final class AdminControl {
    var busy = false
    var error: String?
    var notice: String?
    var attempts = 0
    var lastAttempt: Date?

    func perform(_ operation: () async throws -> Void) async {
        guard !busy else { return }
        busy = true; error = nil; notice = nil; attempts += 1; lastAttempt = Date()
        defer { busy = false }
        do { try await operation() } catch { self.error = error.localizedDescription }
    }
}

func adminPath(_ id: String) -> String {
    id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
}
func adminStrings(_ text: String) -> [String] {
    text.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
}
func adminArray(_ values: [String]) -> JSONValue { .array(values.map(JSONValue.string)) }
func adminRevision(_ revision: Int) -> JSONObject { ["revision": .number(Double(revision))] }
func adminDate(_ milliseconds: Double) -> String {
    Date(timeIntervalSince1970: milliseconds / 1000).formatted(date: .abbreviated, time: .shortened)
}

@MainActor func adminReadAll<T: Codable & Hashable>(_ store: LemonBotStore, _ path: String, query: [String: String] = [:], as: T.Type) async throws -> [T] {
    var query = query
    var items: [T] = []
    repeat {
        let page = try await store.read(path, query: query, as: Page<T>.self)
        items.append(contentsOf: page.items)
        guard let cursor = page.nextCursor else { return items }
        query["cursor"] = cursor
    } while true
}

struct AdminStatus: View {
    let control: AdminControl
    let store: LemonBotStore
    var body: some View {
        Section {
            if control.busy { ProgressView("Contacting backend…") }
            if store.connectionState != "online" {
                Label("\(store.connectionState). Changes require an online connection and are never queued.", systemImage: "wifi.exclamationmark")
            }
            if let error = control.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                Text("If the outcome is unknown, refresh the named resource before making another request. No request is automatically replayed.").font(.caption)
            }
            if let notice = control.notice { Text(notice).textSelection(.enabled) }
        }
    }
}

struct AdminAction: View {
    let title: String
    let store: LemonBotStore
    let control: AdminControl
    var destructive = false
    let action: () async throws -> Void
    @State private var confirming = false
    var body: some View {
        Button(title, role: destructive ? .destructive : nil) {
            if destructive { confirming = true } else { submit() }
        }.disabled(control.busy || store.connectionState != "online")
            .confirmationDialog(title, isPresented: $confirming, titleVisibility: .visible) {
                Button(title, role: .destructive) { submit() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Confirm this explicitly scoped action. Completed external effects are not rolled back.")
            }
    }
    private func submit() {
        Task { await control.perform {
            guard store.connectionState == "online" else { throw ClientError.offline }
            try await action()
        } }
    }
}

struct AdminChoice: View {
    let label: String
    @Binding var value: String
    let options: [String]
    var body: some View {
        Picker(label, selection: $value) {
            ForEach(options, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")).tag($0) }
        }
    }
}

struct AdminBotPicker: View {
    let store: LemonBotStore
    @Binding var value: String
    var ownedOnly = false
    var body: some View {
        Picker("Bot", selection: $value) {
            Text("Choose a Bot").tag("")
            ForEach(store.bots.filter { !ownedOnly || $0.ownerUserId == store.user?.id }) { bot in
                Text(bot.name).tag(bot.id)
            }
        }
    }
}

struct AdminMachineSelection: View {
    let store: LemonBotStore
    @Binding var ids: Set<String>
    var body: some View {
        ForEach(store.machines) { machine in
            Toggle("\(machine.name) · \(machine.status)", isOn: Binding(get: { ids.contains(machine.id) }, set: { if $0 { ids.insert(machine.id) } else { ids.remove(machine.id) } }))
        }
    }
}

struct AdminPreviewDelete: View {
    let store: LemonBotStore
    let path: String
    var action = "delete"
    var additional: JSONObject = [:]
    var completed: () async throws -> Void = {}
    @State private var control = AdminControl()
    @State private var preview: Confirmation?
    @State private var typedName = ""
    var body: some View {
        Section("Destructive review") {
            AdminStatus(control: control, store: store)
            AdminAction(title: "Preview \(action)", store: store, control: control) {
                preview = nil; typedName = ""
                preview = try await store.mutate("POST", path + "/preview", body: ["action": .string(action)], as: Confirmation.self)
            }
            if let preview {
                ForEach(Array(preview.effects.enumerated()), id: \.offset) { Text($0.element) }
                ForEach(Array(preview.affected.enumerated()), id: \.offset) { _, effect in
                    VStack(alignment: .leading) {
                        Text("\(effect.operation) · \(effect.resourceType) · \(effect.id)").font(.headline)
                        if let machine = effect.machineId { Text("Machine: \(machine)") }
                        Text(effect.explanation)
                    }
                }
                Text("Expires: \(adminDate(Double(preview.expiresAtMs)))")
                TextField("Type exactly: \(preview.confirmName)", text: $typedName)
                AdminAction(title: "Confirm \(action)", store: store, control: control, destructive: true) {
                    var body = additional
                    body["revision"] = .number(Double(preview.revision))
                    body["confirmationToken"] = .string(preview.confirmationToken)
                    body["confirmName"] = .string(typedName)
                    _ = try await store.mutate("DELETE", path, body: body, as: Deleted.self)
                    self.preview = nil; typedName = ""
                    try await completed()
                }.disabled(typedName != preview.confirmName || Double(preview.expiresAtMs) <= Date().timeIntervalSince1970 * 1000)
            }
        }
    }
}

public struct SettingsHubView: View {
    private let store: LemonBotStore
    public init(store: LemonBotStore) { self.store = store }
    public var body: some View {
        List {
            Section("Personal") {
                NavigationLink("Account, password and sessions") { AccountSettingsView(store: store) }
                NavigationLink("Appearance, notifications and voice") { PreferencesSettingsView(store: store) }
                NavigationLink("Local companion and accessibility") { LocalSettingsView(store: store) }
            }
            Section("Workspace and access") {
                NavigationLink("Workspace, members and invitations") { WorkspaceSettingsView(store: store) }
                NavigationLink("Policies, action review and consents") { PolicySettingsView(store: store) }
                NavigationLink("Identity, OIDC and SCIM") { IdentitySettingsView(store: store) }
                NavigationLink("Directory groups and governance") { DirectorySettingsView(store: store) }
            }
            Section("Operations") {
                NavigationLink("Network enforcement and egress") { NetworkSettingsView(store: store) }
                NavigationLink("Reviewed setup manifests") { SetupSettingsView(store: store) }
                NavigationLink("Usage and spend limits") { UsageSettingsView(store: store) }
                NavigationLink("Exports and participant consent") { ExportSettingsView(store: store) }
                NavigationLink("Provider catalog and exact setup prerequisites") { ProviderCatalogView(store: store) }
                NavigationLink("About and diagnostics") { AboutSettingsView(store: store) }
            }
        }.navigationTitle("Settings")
    }
}
