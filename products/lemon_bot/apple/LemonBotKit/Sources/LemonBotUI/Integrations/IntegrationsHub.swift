import SwiftUI
import LemonBotKit

public struct IntegrationsHubView: View {
    private let store: LemonBotStore
    public init(store: LemonBotStore) { self.store = store }
    public var body: some View {
        List {
            Section("Explicit account authority") {
                NavigationLink("Connect apps — per-Bot MCP accounts and tools") { ConnectorSettingsView(store: store) }
                NavigationLink("Channels — install, verified principals and event capabilities") { ChannelSettingsView(store: store) }
                NavigationLink("Email — approved address and actual mailbox search") { EmailSettingsView(store: store) }
                NavigationLink("X — connect, public mentions and main Bot") { XSettingsView(store: store) }
            }
            Section("Operator configuration") {
                NavigationLink("Provider catalog and exact prerequisites") { ProviderCatalogView(store: store) }
            }
            Text("Connecting your account is not a tool approval or permission to send. Channels are separate from MCP posting tools; provider installation and external administrator approval are independent states.")
        }.navigationTitle("Integrations")
    }
}

struct ProviderCatalogView: View {
    let store: LemonBotStore
    @State private var control = AdminControl()
    @State private var providers: [IntegrationProvider] = []
    @State private var sources: [ExternalSource] = []
    var body: some View {
        Form {
            AdminStatus(control: control, store: store)
            Section("Eligible registered providers") {
                ForEach(providers, id: \.id) { provider in
                    ProviderPrerequisites(label: provider.label, kind: provider.kind, configured: provider.configured, prerequisites: provider.prerequisites, capabilities: provider.capabilities)
                }
                Text("Configured means validated operator configuration and credential references, not an authenticated account, installed app, applied host policy or successful external operation.")
            }
            Section("Actual supported new-event sources") {
                ForEach(sources, id: \.source) { source in
                    Text("\(source.source) · \(source.configured ? "configured" : "unconfigured")")
                    ForEach(source.events, id: \.self) { Text($0).font(.caption) }
                }
                Text("Only new verified, registered events can wake explicitly configured routines. No old-event backfill; payloads never choose arbitrary user or machine authority. Routine editors select source-specific validated filters.")
            }
            Button("Refresh catalog") { Task { await control.perform { try await load() } } }
        }.navigationTitle("Provider catalog").task { await control.perform { try await load() } }
    }
    private func load() async throws {
        providers = try await store.read("/integration-providers", as: [IntegrationProvider].self)
        sources = try await store.read("/event-sources", as: [ExternalSource].self)
    }
}

struct ProviderPrerequisites: View {
    let label: String
    let kind: String
    let configured: Bool
    let prerequisites: [String]
    let capabilities: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("\(label) · \(kind) · \(configured ? "configured" : "requires setup")", systemImage: configured ? "checkmark.circle" : "exclamationmark.triangle").font(.headline)
            ForEach(prerequisites, id: \.self) { Text($0).textSelection(.enabled) }
            if !capabilities.isEmpty { Text("Capabilities: \(capabilities.joined(separator: ", "))").font(.caption) }
        }
    }
}
