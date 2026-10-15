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
            AdminStatus(control: control, store: store, refresh: { await control.perform { try await load() } })
            Section("Your email addresses") {
                ForEach(accounts) { account in
                    NavigationLink("\(account.address) · \(account.state)") { MailboxMessagesView(store: store, account: account) }
                    Text("\(account.provider) · \(account.immutableAddress ? "immutable address" : "provider-defined lifecycle")")
                    MailboxIndexingStatus(account: account)
                }
                Text("Email never wakes a Bot on its own. Only routines you set up for specific senders can. Search uses your provider's index, so new mail may take a while to appear. Every outgoing email is a draft until you tap Send.")
            }
            Section("Choose an email provider") {
                Picker("Provider", selection: $providerID) {
                    Text("Choose provider").tag("")
                    ForEach(providers, id: \.id) { Text("\($0.label) · \($0.domain)").tag($0.id) }
                }.disabled(proposal != nil)
                if let provider {
                    ProviderPrerequisites(label: provider.label, kind: provider.kind, configured: provider.configured, prerequisites: provider.prerequisites, capabilities: provider.capabilities)
                    Text("Address lifecycle: \(provider.immutableAddresses ? "immutable" : "provider-defined") · actual provisioning \(provider.supportsProvisioning ? "supported" : "unavailable") · unsubscribe \(provider.supportsUnsubscribe ? "supported" : "unavailable")")
                }
                TextField("Address name (before @)", text: $localPart).disabled(proposal != nil)
                Text("Use up to 64 lowercase letters, numbers, dots, hyphens or underscores. Start and end with a letter or number. Your provider checks availability and reserved names.")
                AdminBotPicker(store: store, value: $botID, ownedOnly: true).disabled(proposal != nil)
                AdminAction(title: "Check availability", store: store, control: control) {
                    availability = try await store.mutate("POST", "/email/address/check", body: ["providerId": .string(providerID), "localPart": .string(localPart)], as: EmailAddressAvailability.self)
                    checkedProvider = providerID; checkedPart = localPart
                }.disabled(provider?.configured != true || provider?.supportsProvisioning != true || localPart.isEmpty || proposal != nil)
                if let availability, checkedProvider == providerID, checkedPart == localPart {
                    Text("\(availability.address) · \(availability.available ? "available at check time" : "unavailable") · \(availability.immutable ? "immutable" : "provider-defined lifecycle")")
                    if let reason = availability.reason { Text(reason).textSelection(.enabled) }
                }
                AdminAction(title: "Request this address", store: store, control: control) {
                    let target = EmailClaimIntent(providerID: providerID, localPart: localPart, botID: botID)
                    proposal = try await store.mutate("POST", "/email/address/approval", body: ["providerId": .string(target.providerID), "localPart": .string(target.localPart), "botId": .string(target.botID)], as: Approval.self)
                    intent = target
                }.disabled(!exactAvailable || botID.isEmpty || proposal != nil)
                Text("Requesting asks for approval. It doesn't create or claim the address yet.").font(LBFont.meta)
            }
            if let proposal, let intent {
                Section("Review address request") {
                    Text(proposal.title).font(.headline); Text(proposal.description)
                    Text("\(intent.localPart)@\(providers.first(where: { $0.id == intent.providerID })?.domain ?? "selected provider")")
                    Text("Provider: \(providers.first(where: { $0.id == intent.providerID })?.label ?? "Email provider") · Bot: \(store.bots.first(where: { $0.id == intent.botID })?.name ?? "Selected Bot")")
                    DisclosureGroup("Details") {
                        let details = "Provider: \(intent.providerID)\nBot: \(intent.botID)\nTarget: \(proposal.target)"
                        Text(details).textSelection(.enabled)
                        Button("Copy") { copyText(details) }
                    }
                    Text("\(humanizedStatus(proposal.gate.state)) · \(proposal.scope.label) · \(proposal.scope.machineLabel)")
                    ForEach(proposal.scope.consequences, id: \.self) { Text($0) }
                    Text("Expires \(adminDate(Double(proposal.gate.expiresAtMs)))")
                    if proposal.gate.state == "pending" {
                        ForEach(["approve_once", "deny"], id: \.self) { decision in
                            AdminAction(title: decision == "approve_once" ? "Approve once" : "Deny", store: store, control: control) {
                                self.proposal = try await store.mutate("POST", "/approvals/\(adminPath(proposal.id))/resolve", body: ["revision": .number(Double(proposal.revision)), "decision": .string(decision)], as: Approval.self)
                            }.disabled(proposal.gate.targetUserId != store.user?.id || Double(proposal.gate.expiresAtMs) <= Date().timeIntervalSince1970 * 1000)
                        }
                    }
                    AdminAction(title: "Claim approved address", store: store, control: control) {
                        _ = try await store.mutate("POST", "/email/address/claim", body: ["providerId": .string(intent.providerID), "localPart": .string(intent.localPart), "approvalId": .string(proposal.id)], as: EmailAccount.self)
                        self.proposal = nil; self.intent = nil; availability = nil; try await load()
                    }.disabled(proposal.gate.state != "approved" || proposal.gate.targetUserId != store.user?.id || Double(proposal.gate.expiresAtMs) <= Date().timeIntervalSince1970 * 1000)
                    Button("Refresh request") { Task { await control.perform {
                        self.proposal = try await store.read("/approvals/\(adminPath(proposal.id))", as: Approval.self); try await load()
                    } } }
                    if proposal.gate.state == "denied" || proposal.gate.state == "expired" || proposal.gate.state == "cancelled" {
                        Text("This address wasn't approved. Check availability again to start a new request.")
                        Button("Start a new address request") { self.proposal = nil; self.intent = nil; availability = nil }
                    }
                }
            }
            Button("Refresh email status") { Task { await control.perform { try await load() } } }
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
            AdminStatus(control: control, store: store, refresh: { await control.perform { try await load() } })
            Section("Actual provider mailbox search") {
                Text(account.address).textSelection(.enabled)
                Text("\(account.state) · \(account.immutableAddress ? "immutable address" : "provider-defined address lifecycle")")
                MailboxIndexingStatus(account: account)
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
            AdminStatus(control: control, store: store, refresh: { await control.perform { try await load() } })
            Section("X on this server") {
                if let provider {
                    ProviderPrerequisites(label: provider.label, kind: provider.kind, configured: provider.configured, prerequisites: provider.prerequisites, capabilities: provider.capabilities)
                    Text("Public Bot handle: \(provider.publicHandle)")
                    Text("Account permissions: \(provider.oauthScopes.joined(separator: ", "))")
                    Text("Allowed media: \(provider.allowedMedia.joined(separator: ", ")) · disallowed countries: \(provider.deniedCountries.joined(separator: ", "))")
                } else {
                    Text("X isn't set up on this server yet. Ask whoever runs your Lemon Bot server to finish X setup.")
                }
                Text("Reading public posts doesn't connect your private account. When you mention this server's public Bot from your linked account, your chosen Bot can start work within your workspace's limits. Results stay private. Connecting here doesn't give other tools access to your account.")
            }
            Section("Connect your X account") {
                AdminBotPicker(store: store, value: $botID, ownedOnly: true)
                Toggle("I've reviewed the account permissions, public mentions and selected Bot", isOn: $consent)
                AdminAction(title: "Connect X account", store: store, control: control) {
                    result = try await store.mutate("POST", "/x/connections", body: ["mainBotId": .string(botID), "redirectUri": .string("lemonbot://auth/complete")], as: XConnectResult.self)
                    consent = false
                }.disabled(!consent || botID.isEmpty || provider?.configured != true)
                if let result {
                    Text("\(result.connection.state) · selected Bot \(result.connection.mainBotId)")
                    if let url = URL(string: result.authorizationUrl), url.scheme == "https" { Button("Continue on X") { openURL(url) } }
                    Button("Check connection") { Task { await control.perform { try await load() } } }
                }
            }
            Section("Own connected accounts and main Bots") {
                ForEach(connections) { connection in XConnectionSettingsRow(store: store, connection: connection, refresh: load) }
            }
            Button("Refresh X status") { Task { await control.perform { try await load() } } }
        }.navigationTitle("X").task { await control.perform { try await load() } }
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
            if let username = connection.username, let externalID = connection.externalAccountId {
                Text("@\(username) · \(connection.state) · verified external account \(externalID)")
                if connection.state != "connected" { Text("Last verified identity only; this is not an active authorization grant.").font(.caption).foregroundStyle(LB.muted) }
            } else {
                Text("Account not yet verified · \(connection.state)")
            }
            if let error = connection.lastError { Text(error).foregroundStyle(LB.danger).textSelection(.enabled) }
            AdminBotPicker(store: store, value: $botID, ownedOnly: true)
            Toggle("Enable my mention integration", isOn: $enabled)
            AdminAction(title: "Save exact main Bot and enable state", store: store, control: control) {
                _ = try await store.mutate("PATCH", "/x/connections/\(adminPath(connection.id))", body: ["revision": .number(Double(connection.revision)), "mainBotId": .string(botID), "enabled": .bool(enabled)], as: XConnection.self); try await refresh()
            }.disabled(botID.isEmpty)
            AdminAction(title: "Disconnect X account", store: store, control: control, destructive: true) {
                _ = try await store.mutate("DELETE", "/x/connections/\(adminPath(connection.id))", body: adminRevision(connection.revision), as: Deleted.self); try await refresh()
            }
            if let error = control.error { Text(error).foregroundStyle(LB.danger).textSelection(.enabled) }
        }.onAppear { botID = connection.mainBotId; enabled = connection.enabled }
    }
}

private struct MailboxIndexingStatus: View {
    let account: EmailAccount
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if (account.indexingDelayed ?? nil) == true {
                Label("Provider reports delayed indexing; recent mail may not appear yet.", systemImage: "clock.badge.exclamationmark").foregroundStyle(LB.warning)
            } else if (account.indexingDelayed ?? nil) == nil {
                Text("Provider indexing status has not been measured.").foregroundStyle(LB.muted)
            }
            if let measured = account.indexingMeasuredAtMs ?? nil {
                Text("Index observation: \(adminDate(measured)) · \(Date(timeIntervalSince1970: measured / 1000).formatted(.relative(presentation: .named)))").foregroundStyle(LB.muted)
            }
        }.font(.caption)
    }
}
