import SwiftUI
import LemonBotKit

private struct EmailClaimIntent { let providerID: String; let localPart: String; let botID: String }
struct EmailSettingsView: View {
    let store: LemonBotStore
    @State private var control = AdminControl()
    @State private var providers: [EmailProviderInfo] = []
    @State private var accounts: [EmailAccount] = []
    @State private var providerID = ""
    @State private var localPart = ""
    @State private var botID = ""
    @State private var availability: EmailAddressAvailability?
    @State private var checkedProvider = ""
    @State private var checkedPart = ""
    @State private var proposal: Approval?
    @State private var intent: EmailClaimIntent?
    private var provider: EmailProviderInfo? { providers.first { $0.id == providerID } }
    private var exactAvailable: Bool { availability?.available == true && checkedProvider == providerID && checkedPart == localPart }
    var body: some View {
        Form {
            AdminStatus(control: control, store: store)
            Section("Actual account-owned mailboxes") {
                ForEach(accounts) { account in
                    NavigationLink("\(account.address) · \(account.state)") { MailboxMessagesView(store: store, account: account) }
                    Text("\(account.provider) · \(account.immutableAddress ? "immutable address" : "provider-defined lifecycle")")
                }
                Text("One claimed account-owned address. Email alone never wakes a Bot: explicitly matching authenticated/scanned sender/domain routines do. Mail read/search uses the provider's real index; this is not a guaranteed product inbox/new-mail notification service. All outbound mail, replies and routines require an editable draft and explicit Send.")
            }
            Section("Choose registered provisioning provider") {
                Picker("Provider", selection: $providerID) {
                    Text("Choose provider").tag("")
                    ForEach(providers, id: \.id) { Text("\($0.label) · \($0.domain)").tag($0.id) }
                }.disabled(proposal != nil)
                if let provider {
                    ProviderPrerequisites(label: provider.label, kind: provider.kind, configured: provider.configured, prerequisites: provider.prerequisites, capabilities: provider.capabilities)
                    Text("Address lifecycle: \(provider.immutableAddresses ? "immutable" : "provider-defined") · actual provisioning \(provider.supportsProvisioning ? "supported" : "unavailable") · unsubscribe \(provider.supportsUnsubscribe ? "supported" : "unavailable")")
                }
                TextField("Exact local part", text: $localPart).disabled(proposal != nil)
                Text("Up to 64 lowercase letters/digits/dot/hyphen/underscore, starts and ends with letter/digit. Reserved names, uniqueness and throttling are validated by the actual provider.")
                AdminBotPicker(store: store, value: $botID, ownedOnly: true).disabled(proposal != nil)
                AdminAction(title: "Check exact address availability", store: store, control: control) {
                    availability = try await store.mutate("POST", "/email/address/check", body: ["providerId": .string(providerID), "localPart": .string(localPart)], as: EmailAddressAvailability.self)
                    checkedProvider = providerID; checkedPart = localPart
                }.disabled(provider?.configured != true || provider?.supportsProvisioning != true || localPart.isEmpty || proposal != nil)
                if let availability, checkedProvider == providerID, checkedPart == localPart {
                    Text("\(availability.address) · \(availability.available ? "available at check time" : "unavailable") · \(availability.immutable ? "immutable" : "provider-defined lifecycle")")
                    if let reason = availability.reason { Text(reason).textSelection(.enabled) }
                }
                AdminAction(title: "Create exact permissions proposal (does not claim)", store: store, control: control) {
                    let target = EmailClaimIntent(providerID: providerID, localPart: localPart, botID: botID)
                    proposal = try await store.mutate("POST", "/email/address/approval", body: ["providerId": .string(target.providerID), "localPart": .string(target.localPart), "botId": .string(target.botID)], as: Approval.self)
                    intent = target
                }.disabled(!exactAvailable || botID.isEmpty || proposal != nil)
            }
            if let proposal, let intent {
                Section("Review exact proposed claim") {
                    Text(proposal.title).font(.headline); Text(proposal.description)
                    Text("Target: \(proposal.target) · provider \(intent.providerID) · local part \(intent.localPart) · Bot \(intent.botID)")
                    Text("\(proposal.category) · \(proposal.gate.state) · scope \(proposal.scope.label) · machine \(proposal.scope.machineLabel)")
                    ForEach(proposal.scope.consequences, id: \.self) { Text($0) }
                    Text("Expires \(adminDate(Double(proposal.gate.expiresAtMs)))")
                    if proposal.gate.state == "pending" {
                        ForEach(["approve_once", "deny"], id: \.self) { decision in
                            AdminAction(title: decision == "approve_once" ? "Approve exact claim once" : "Deny claim", store: store, control: control) {
                                self.proposal = try await store.mutate("POST", "/approvals/\(adminPath(proposal.id))/resolve", body: ["revision": .number(Double(proposal.revision)), "decision": .string(decision)], as: Approval.self)
                            }.disabled(proposal.gate.targetUserId != store.user?.id || Double(proposal.gate.expiresAtMs) <= Date().timeIntervalSince1970 * 1000)
                        }
                    }
                    AdminAction(title: "Claim only the approved exact address", store: store, control: control) {
                        _ = try await store.mutate("POST", "/email/address/claim", body: ["providerId": .string(intent.providerID), "localPart": .string(intent.localPart), "approvalId": .string(proposal.id)], as: EmailAccount.self)
                        self.proposal = nil; self.intent = nil; availability = nil; try await load()
                    }.disabled(proposal.gate.state != "approved" || proposal.gate.targetUserId != store.user?.id || Double(proposal.gate.expiresAtMs) <= Date().timeIntervalSince1970 * 1000)
                    Button("Refresh proposal / reconcile without claiming") { Task { await control.perform {
                        self.proposal = try await store.read("/approvals/\(adminPath(proposal.id))", as: Approval.self); try await load()
                    } } }
                    if proposal.gate.state == "denied" || proposal.gate.state == "expired" || proposal.gate.state == "cancelled" {
                        Text("No claim was authorized. A new explicit request needs another availability check and proposal.")
                        Button("Start a new address request") { self.proposal = nil; self.intent = nil; availability = nil }
                    }
                }
            }
            Button("Refresh mailbox/provider status (never reclaims)") { Task { await control.perform { try await load() } } }
        }.navigationTitle("Email").task { await control.perform { try await load() } }
    }
    private func load() async throws { providers = try await store.read("/email/providers", as: [EmailProviderInfo].self); accounts = try await adminReadAll(store, "/email/accounts", as: EmailAccount.self) }
}

struct MailboxMessagesView: View {
    let store: LemonBotStore
    let account: EmailAccount
    @State private var control = AdminControl()
    @State private var messages: [EmailMessage] = []
    @State private var query = ""
    @State private var sender = ""
    var body: some View {
        Form {
            AdminStatus(control: control, store: store)
            Section("Actual provider mailbox search") {
                Text(account.address).textSelection(.enabled)
                Text("\(account.state) · \(account.immutableAddress ? "immutable address" : "provider-defined address lifecycle")")
                TextField("Provider search query", text: $query); TextField("Sender", text: $sender)
                Button("Search real mailbox index") { Task { await control.perform { try await load() } } }
                Text("Provider indexing may be delayed. No automatic new-mail notification or implicit routine wake is promised. Spam/virus/failed scans retain metadata without unsafe body or attachments.")
            }
            Section("Messages") {
                ForEach(messages) { message in
                    NavigationLink("\(message.subject) · \(message.from)") { EmailMessageDetailView(store: store, messageID: message.id) }
                    Text("\(adminDate(Double(message.receivedAtMs))) · authentication \(message.authentication) · scan \(message.scan)").font(.caption)
                }
            }
        }.navigationTitle("Mailbox").task { await control.perform { try await load() } }
    }
    private func load() async throws {
        var filters: [String: String] = [:]
        if !query.isEmpty { filters["query"] = query }; if !sender.isEmpty { filters["sender"] = sender }
        messages = try await adminReadAll(store, "/email/accounts/\(adminPath(account.id))/messages", query: filters, as: EmailMessage.self)
    }
}
struct EmailMessageDetailView: View {
    let store: LemonBotStore
    let messageID: String
    @Environment(\.openURL) private var openURL
    @State private var control = AdminControl()
    @State private var message: EmailMessage?
    var body: some View {
        Form {
            AdminStatus(control: control, store: store)
            if let message {
                Section("Source and safety") {
                    Text(message.subject).font(.headline); Text("From: \(message.from)"); Text("To: \(message.to.joined(separator: ", "))")
                    Text("Received \(adminDate(Double(message.receivedAtMs))) · authentication \(message.authentication) · scan \(message.scan)")
                    Text("External mail is untrusted content, never permission to send, approve or run tools.")
                }
                Section("Body") {
                    if message.scan == "passed", let text = message.text { Text(text).textSelection(.enabled) }
                    else { Text("Body not available for this scan/provider state.") }
                }
                Section("Checked attachments") {
                    ForEach(message.skippedAttachmentNames, id: \.self) { Text("Skipped: \($0)") }
                    if message.scan == "passed" {
                        ForEach(message.attachmentIds, id: \.self) { id in
                            Button("Download authorized attachment \(id)") { Task { await control.perform { let url = try await store.download(attachmentID: id); openURL(url) } } }
                        }
                    }
                }
            }
        }.navigationTitle("Email message").task { await control.perform { message = try await store.read("/email/messages/\(adminPath(messageID))", as: EmailMessage.self) } }
    }
}

struct XSettingsView: View {
    let store: LemonBotStore
    @Environment(\.openURL) private var openURL
    @State private var control = AdminControl()
    @State private var provider: XProviderInfo?
    @State private var connections: [XConnection] = []
    @State private var botID = ""
    @State private var result: XConnectResult?
    @State private var consent = false
    var body: some View {
        Form {
            AdminStatus(control: control, store: store)
            Section("Registered X provider — no implicit account linking") {
                if let provider {
                    ProviderPrerequisites(label: provider.label, kind: provider.kind, configured: provider.configured, prerequisites: provider.prerequisites, capabilities: provider.capabilities)
                    Text("Actual public Bot handle: \(provider.publicHandle)")
                    Text("OAuth scopes: \(provider.oauthScopes.joined(separator: ", "))")
                    Text("Allowed media: \(provider.allowedMedia.joined(separator: ", ")) · disallowed countries: \(provider.deniedCountries.joined(separator: ", "))")
                } else {
                    Text("No eligible registered X provider. Operator must configure xProvider OAuth/API/public handle/signature gateway and native redirect allowlist in the private provider configuration. No account or public confirmation is fabricated.")
                }
                Text("Public source reading does not need private account access. Protected tools require their own explicit MCP account scopes. Only your own explicit mention of the registered public handle wakes your selected private main Bot, under actual region/media/moderation/spend rules. Short public acceptance is sent only after a real accepted receipt; results remain private.")
            }
            Section("Connect your X account") {
                AdminBotPicker(store: store, value: $botID, ownedOnly: true)
                Toggle("I reviewed actual OAuth scopes, public mention behavior and private Bot destination", isOn: $consent)
                AdminAction(title: "Start explicit X OAuth connection", store: store, control: control) {
                    result = try await store.mutate("POST", "/x/connections", body: ["mainBotId": .string(botID), "redirectUri": .string("lemonbot://auth/complete")], as: XConnectResult.self)
                    consent = false
                }.disabled(!consent || botID.isEmpty || provider?.configured != true)
                if let result {
                    Text("\(result.connection.state) · selected Bot \(result.connection.mainBotId)")
                    if let url = URL(string: result.authorizationUrl), url.scheme == "https" { Button("Open / reopen X authorization") { openURL(url) } }
                    Button("Check actual OAuth result") { Task { await control.perform { try await load() } } }
                }
            }
            Section("Own connected accounts and main Bots") {
                ForEach(connections) { connection in XConnectionSettingsRow(store: store, connection: connection, refresh: load) }
            }
            Button("Refresh actual account/provider status") { Task { await control.perform { try await load() } } }
        }.navigationTitle("X integration").task { await control.perform { try await load() } }
    }
    private func load() async throws { provider = try await store.read("/x/provider", as: Optional<XProviderInfo>.self); connections = try await adminReadAll(store, "/x/connections", as: XConnection.self) }
}
struct XConnectionSettingsRow: View {
    let store: LemonBotStore
    let connection: XConnection
    let refresh: () async throws -> Void
    @State private var control = AdminControl()
    @State private var botID = ""
    @State private var enabled = false
    var body: some View {
        VStack(alignment: .leading) {
            Text("@\(connection.username) · \(connection.state) · external account \(connection.externalAccountId)")
            if let error = connection.lastError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            AdminBotPicker(store: store, value: $botID, ownedOnly: true)
            Toggle("Enable my mention integration", isOn: $enabled)
            AdminAction(title: "Save exact main Bot and enable state", store: store, control: control) {
                _ = try await store.mutate("PATCH", "/x/connections/\(adminPath(connection.id))", body: ["revision": .number(Double(connection.revision)), "mainBotId": .string(botID), "enabled": .bool(enabled)], as: XConnection.self); try await refresh()
            }.disabled(botID.isEmpty)
            AdminAction(title: "Disconnect X account", store: store, control: control, destructive: true) {
                _ = try await store.mutate("DELETE", "/x/connections/\(adminPath(connection.id))", body: adminRevision(connection.revision), as: Deleted.self); try await refresh()
            }
            if let error = control.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }.onAppear { botID = connection.mainBotId; enabled = connection.enabled }
    }
}
