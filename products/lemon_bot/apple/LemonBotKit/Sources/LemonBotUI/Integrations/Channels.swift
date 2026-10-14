import SwiftUI
import LemonBotKit

struct ChannelSettingsView: View {
    let store: LemonBotStore
    @Environment(\.openURL) private var openURL
    @State private var control = AdminControl()
    @State private var providers: [ChannelProviderInfo] = []
    @State private var channels: [ChannelBinding] = []
    @State private var links: [ChannelPrincipalLink] = []
    @State private var bot = ""
    @State private var providerID = ""
    @State private var label = ""
    @State private var setup: ChannelSetupFlow?
    @State private var adapter = "slack"
    @State private var accountID = ""
    @State private var target = ""
    @State private var enabled = false
    private var provider: ChannelProviderInfo? { providers.first { $0.id == providerID } }
    var body: some View {
        Form {
            AdminStatus(control: control, store: store)
            Section("Channel bindings — not MCP posting accounts") {
                ForEach(channels) { channel in NavigationLink("\(channel.adapter) · \(channel.target) · \(channel.state) · \(channel.enabled ? "enabled" : "disabled")") { ChannelDetailSettingsView(store: store, binding: channel) } }
                Text("Mapped external actors use their enabled product identity and budget. An unlinked person is refused, never silently charged to the Bot owner. Thread participation and listener triggers are separate from ordinary plugin posting consent.")
            }
            Section("Install or authorize a registered provider") {
                AdminBotPicker(store: store, value: $bot)
                Picker("Registered provider", selection: $providerID) {
                    Text("Choose provider").tag("")
                    ForEach(providers, id: \.id) { Text("\($0.label) · \($0.adapter)").tag($0.id) }
                }
                if let provider {
                    ProviderPrerequisites(label: provider.label, kind: provider.kind, configured: provider.configured, prerequisites: provider.prerequisites, capabilities: provider.capabilities)
                    Text("Per-Bot app install: \(provider.supportsBotAppInstall ? "supported" : "not supported")")
                }
                TextField("Account label", text: $label)
                AdminAction(title: "Start provider install / authorization", store: store, control: control) {
                    guard let provider else { throw AdminFormError("Choose a registered provider.") }
                    setup = try await store.mutate("POST", "/channels/setup", body: ["botId": .string(bot), "adapter": .string(provider.adapter), "providerId": .string(provider.id), "accountLabel": .string(label), "redirectUri": .string("lemonbot://auth/complete")], as: ChannelSetupFlow.self)
                }.disabled(bot.isEmpty || provider?.configured != true)
                if let setup {
                    Text("Install: \(setup.state) · Bot \(setup.botId)")
                    if let error = setup.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    if let string = setup.authorizationUrl, let url = URL(string: string), url.scheme == "https" { Button("Open / reopen provider installation") { openURL(url) } }
                    Button("Check actual install status") { Task { await control.perform {
                        self.setup = try await store.read("/channels/setup/\(adminPath(setup.id))", as: ChannelSetupFlow.self)
                        channels = try await adminReadAll(store, "/channels", as: ChannelBinding.self)
                    } } }
                    Text("Awaiting admin is not installed. Welcome/invite/removal use the provider's actual permissions. A denied or failed install never becomes connected merely because this screen closes.")
                }
            }
            Section("Existing operator-configured adapter binding") {
                Text("Use an actual installed adapter account and target; adding a binding never fabricates an external install.")
                AdminChoice(label: "Adapter", value: $adapter, options: ["email", "slack", "telegram", "discord", "whatsapp"])
                TextField("Existing adapter account ID", text: $accountID); TextField("Exact channel / mailbox target", text: $target)
                Toggle("Enable binding", isOn: $enabled)
                AdminAction(title: "Add configured adapter binding", store: store, control: control) {
                    _ = try await store.mutate("POST", "/channels", body: ["botId": .string(bot), "adapter": .string(adapter), "accountId": .string(accountID), "target": .string(target), "enabled": .bool(enabled)], as: ChannelBinding.self); try await load()
                }.disabled(bot.isEmpty || accountID.isEmpty || target.isEmpty)
            }
            Section("Own verified external principal links") {
                ForEach(links) { link in
                    Text("\(link.channelBindingId) · verified external \(link.externalUserId) → product \(link.userId) · \(link.verified ? "verified" : "not verified")")
                    AdminAction(title: "Remove this principal link", store: store, control: control, destructive: true) {
                        _ = try await store.mutate("DELETE", "/channels/principal-links/\(adminPath(link.id))", body: adminRevision(link.revision), as: Deleted.self); try await load()
                    }
                }
                Text("Open a binding to initiate a one-use proof through your actual authenticated external account. No arbitrary user-ID mapping is accepted.")
            }
            Button("Refresh channels, links and providers") { Task { await control.perform { try await load() } } }
        }.navigationTitle("Channels").task { await control.perform { try await load() } }
    }
    private func load() async throws {
        providers = try await store.read("/channels/providers", as: [ChannelProviderInfo].self)
        channels = try await adminReadAll(store, "/channels", as: ChannelBinding.self)
        links = try await adminReadAll(store, "/channels/principal-links", as: ChannelPrincipalLink.self)
    }
}

struct ChannelDetailSettingsView: View {
    let store: LemonBotStore
    let binding: ChannelBinding
    @State private var control = AdminControl()
    @State private var current: ChannelBinding?
    @State private var target = ""
    @State private var enabled = false
    @State private var linkFlow: ChannelLinkFlow?
    @State private var identityConfirmed = false
    private var value: ChannelBinding { current ?? binding }
    var body: some View {
        Form {
            AdminStatus(control: control, store: store)
            Section("Adapter capability and state") {
                Text("\(value.adapter) · account \(value.accountId) · Bot \(value.botId) · \(value.state)")
                Text("Inbound \(value.capabilities.inbound ? "supported" : "unavailable") · outbound \(value.capabilities.outbound ? "supported" : "unavailable")")
                ForEach(value.capabilities.events, id: \.self) { Text($0) }
                if let error = value.lastError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                TextField("Exact target", text: $target); Toggle("Enabled", isOn: $enabled)
                AdminAction(title: "Save binding", store: store, control: control) {
                    current = try await store.mutate("PATCH", "/channels/\(adminPath(binding.id))", body: ["revision": .number(Double(value.revision)), "target": .string(target), "enabled": .bool(enabled)], as: ChannelBinding.self)
                }
                AdminAction(title: "Remove / uninstall binding through provider", store: store, control: control, destructive: true) {
                    _ = try await store.mutate("DELETE", "/channels/\(adminPath(binding.id))", body: adminRevision(value.revision), as: Deleted.self); control.notice = "Binding removed after backend response. Product Bot/history are independent; any provider-admin cleanup error must be resolved at the provider."
                }
            }
            Section("Prove your external account — no arbitrary mapping") {
                Text("A one-use code is bound to your product account and this owned Bot binding. Follow instructions in your actual authenticated external account, then inspect the verified identity before linking. Expires after ten minutes; never paste this authority in a public thread.")
                AdminAction(title: "Issue own private linking instructions", store: store, control: control) {
                    linkFlow = try await store.mutate("POST", "/channels/principal-links/start", body: ["channelBindingId": .string(binding.id)], as: ChannelLinkFlow.self); identityConfirmed = false
                }
                if let flow = linkFlow {
                    Text("\(flow.state) · expires \(adminDate(Double(flow.expiresAtMs)))")
                    Text(flow.instructions).textSelection(.enabled)
                    if let code = flow.linkCode { Text(code).textSelection(.enabled) }
                    Button("Check verified external identity") { Task { await control.perform {
                        linkFlow = try await store.read("/channels/principal-links/flows/\(adminPath(flow.id))", as: ChannelLinkFlow.self); identityConfirmed = false
                    } } }
                    if flow.state == "verified", let externalID = flow.externalUserId, let verification = flow.verificationCode {
                        Text("Verified account: \(flow.externalDisplayName ?? externalID) · \(externalID)").font(.headline)
                        Toggle("This is my external identity; link it to my product account", isOn: $identityConfirmed)
                        AdminAction(title: "Confirm exact verified principal link", store: store, control: control) {
                            _ = try await store.mutate("POST", "/channels/principal-links", body: ["channelBindingId": .string(binding.id), "externalUserId": .string(externalID), "verificationCode": .string(verification)], as: ChannelPrincipalLink.self)
                            linkFlow = try await store.read("/channels/principal-links/flows/\(adminPath(flow.id))", as: ChannelLinkFlow.self); identityConfirmed = false
                        }.disabled(!identityConfirmed || Double(flow.expiresAtMs) <= Date().timeIntervalSince1970 * 1000)
                    }
                }
            }
        }.navigationTitle("Channel binding").onAppear { target = binding.target; enabled = binding.enabled }.onDisappear { linkFlow = nil }
    }
}
