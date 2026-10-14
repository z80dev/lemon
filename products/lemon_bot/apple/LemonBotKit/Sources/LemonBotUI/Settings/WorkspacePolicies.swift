import SwiftUI
import LemonBotKit

let adminCategories = ["shell", "files", "external_message", "calendar", "publish", "purchase", "permissions", "connector", "handoff"]

struct WorkspaceSettingsView: View {
    let store: LemonBotStore
    @State private var control = AdminControl()
    @State private var workspace: Workspace?
    @State private var members: [Member] = []
    @State private var invites: [MemberInvite] = []
    @State private var name = ""
    @State private var timezone = "UTC"
    @State private var enabled = true
    @State private var owner = ""
    @State private var transferConfirmed = false
    @State private var inviteEmail = ""
    @State private var inviteRole = "member"
    @State private var inviteDays = 7
    @State private var issued: InviteIssued?
    var body: some View {
        Form {
            AdminStatus(control: control, store: store)
            Section("Workspace") {
                TextField("Name", text: $name); TextField("IANA timezone", text: $timezone)
                Toggle("Workspace enabled", isOn: $enabled)
                AdminAction(title: "Save workspace", store: store, control: control) {
                    guard let workspace else { return }
                    self.workspace = try await store.mutate("PATCH", "/workspace", body: ["revision": .number(Double(workspace.revision)), "name": .string(name), "timezone": .string(timezone), "enabled": .bool(enabled)], as: Workspace.self)
                    try await store.refresh()
                }.disabled(store.member?.role != "owner" || workspace == nil)
                Picker("Transfer ownership to enabled member", selection: $owner) {
                    Text("Choose member").tag("")
                    ForEach(members.filter { $0.enabled }) { Text("\($0.displayName) · \($0.email)").tag($0.userId) }
                }
                Toggle("I understand my owner role will be transferred", isOn: $transferConfirmed)
                AdminAction(title: "Transfer ownership", store: store, control: control) {
                    guard let workspace else { return }
                    self.workspace = try await store.mutate("PATCH", "/workspace", body: ["revision": .number(Double(workspace.revision)), "ownerUserId": .string(owner)], as: Workspace.self)
                    transferConfirmed = false; try await store.refresh(); try await load()
                }.disabled(!transferConfirmed || owner.isEmpty || owner == workspace?.ownerUserId || store.member?.role != "owner")
            }
            Section("Members — identities, not private conversations") {
                ForEach(members) { member in
                    NavigationLink("\(member.displayName) · \(member.role) · \(member.enabled ? "enabled" : "disabled")") { MemberSettingsView(store: store, member: member) }
                }
                Text("Disabling or removing access revokes product sessions/devices and future work. It does not terminate a host or erase external provider sessions.")
            }
            if store.member?.role == "owner" || store.member?.role == "admin" {
                Section("Invite") {
                    TextField("Email", text: $inviteEmail)
                    AdminChoice(label: "Role", value: $inviteRole, options: ["member", "admin"])
                    Stepper("Expires after \(inviteDays) days", value: $inviteDays, in: 1...30)
                    AdminAction(title: "Issue invitation", store: store, control: control) {
                        issued = try await store.mutate("POST", "/invites", body: ["email": .string(inviteEmail), "role": .string(inviteRole), "expiresInMs": .number(Double(inviteDays) * 86_400_000)], as: InviteIssued.self)
                        invites = try await adminReadAll(store, "/invites", as: MemberInvite.self)
                    }
                    if let issued { Text(issued.inviteUrl).textSelection(.enabled); Text("This one-use invitation is shown only at issuance. Treat it as access authority.").font(.caption) }
                    ForEach(invites) { invite in
                        Text("\(invite.email) · \(invite.role) · \(invite.status) · \(adminDate(Double(invite.expiresAtMs)))")
                        AdminAction(title: "Revoke invitation", store: store, control: control, destructive: true) {
                            _ = try await store.mutate("DELETE", "/invites/\(adminPath(invite.id))", body: [:], as: Deleted.self)
                            invites = try await adminReadAll(store, "/invites", as: MemberInvite.self)
                        }.disabled(invite.status != "pending")
                    }
                }
            }
            Section("Published Team directory") {
                ForEach(store.bots.filter { $0.visibility == "team" && $0.published }) { bot in
                    Text("\(bot.name) · owner \(bot.ownerUserId) · \(bot.required ? "required" : "optional") · machine \(bot.machineId)")
                }
                Text("Directory membership does not grant management or access to another person's private DM or notes.")
            }
            Button("Refresh") { Task { await control.perform { try await load() } } }
        }.navigationTitle("Workspace").task { await control.perform { try await load() } }
    }
    private func load() async throws {
        let value = try await store.read("/workspace", as: Workspace.self); workspace = value; name = value.name; timezone = value.timezone; enabled = value.enabled
        members = try await adminReadAll(store, "/members", as: Member.self)
        if store.member?.role == "admin" || store.member?.role == "owner" { invites = try await adminReadAll(store, "/invites", as: MemberInvite.self) }
    }
}

struct MemberSettingsView: View {
    let store: LemonBotStore
    let member: Member
    @State private var control = AdminControl()
    @State private var current: Member?
    @State private var role = "member"
    @State private var enabled = true
    var body: some View {
        Form {
            AdminStatus(control: control, store: store)
            Text(member.email).textSelection(.enabled)
            if member.role == "owner" {
                Text("Owner role: use workspace ownership transfer, not a membership role change.")
            } else {
                AdminChoice(label: "Role", value: $role, options: ["member", "admin"])
            }
            Toggle("Enabled", isOn: $enabled)
            AdminAction(title: "Save membership", store: store, control: control) {
                let value = current ?? member
                var body: JSONObject = ["revision": .number(Double(value.revision)), "enabled": .bool(enabled)]
                if value.role != "owner" { body["role"] = .string(role) }
                current = try await store.mutate("PATCH", "/members/\(adminPath(member.id))", body: body, as: Member.self)
            }.disabled(store.member?.role != "owner" && store.member?.role != "admin")
            AdminPreviewDelete(store: store, path: "/members/\(adminPath(member.id))") { try await store.refresh() }
        }.navigationTitle(member.displayName).onAppear { role = member.role; enabled = member.enabled }
    }
}

struct PolicySettingsView: View {
    let store: LemonBotStore
    @State private var control = AdminControl()
    @State private var policies: Policies?
    @State private var effective: EffectivePolicy?
    @State private var consents: [ConnectorConsent] = []
    @State private var approvals: [Approval] = []
    @State private var publicTemplates = false
    @State private var origins = ""
    @State private var unrestrictedOrigins = false
    @State private var ceiling = "ask"
    @State private var recording = true
    @State private var retention = 90
    @State private var bot = ""
    @State private var category = "shell"
    @State private var mode = "ask_first"
    @State private var description = ""
    @State private var required = false
    @State private var machine = ""
    var body: some View {
        Form {
            AdminStatus(control: control, store: store)
            Section("Effective policy — actual composition") {
                AdminBotPicker(store: store, value: $bot)
                Button("Inspect effective policy") { Task { await control.perform { effective = try await store.read("/policies/effective", query: bot.isEmpty ? [:] : ["botId": bot], as: EffectivePolicy.self) } } }
                if let effective {
                    Text("Product access: \(effective.productAccess ? "allowed" : "denied") · local \(effective.localExecutionCeiling) · sudo \(effective.allowSudo ? "allowed" : "denied") · egress \(effective.allowEgress ? "allowed" : "denied")")
                    ForEach(effective.explanations, id: \.self) { Text($0) }
                    ForEach(effective.rules) { Text("\($0.category): \($0.mode) · \($0.required ? "locked required" : "personal/group") · \($0.description)") }
                }
            }
            Section("Workspace hard ceiling") {
                Toggle("Public templates", isOn: $publicTemplates)
                Toggle("No MCP origin restriction", isOn: $unrestrictedOrigins)
                TextField("Allowed MCP origins (one per line)", text: $origins, axis: .vertical)
                AdminChoice(label: "Local execution ceiling", value: $ceiling, options: ["deny", "ask", "allow"])
                Toggle("Action recording", isOn: $recording)
                Stepper("Audit retention \(retention) days", value: $retention, in: 1...3650)
                AdminAction(title: "Save workspace policies", store: store, control: control) {
                    guard let policies else { return }
                    _ = try await store.mutate("PATCH", "/policies", body: ["revision": .number(Double(policies.revision)), "publicTemplates": .bool(publicTemplates), "allowedMcpOrigins": unrestrictedOrigins ? .null : adminArray(adminStrings(origins)), "localExecutionCeiling": .string(ceiling), "actionRecording": .bool(recording), "auditRetentionDays": .number(Double(retention))], as: Policies.self)
                    try await load()
                }.disabled(policies == nil || (store.member?.role != "admin" && store.member?.role != "owner"))
            }
            Section("Category rules") {
                ForEach(policies?.rules ?? []) { rule in NavigationLink("\(rule.category) · \(rule.mode) · \(rule.required ? "Required" : "Personal")") { PolicyRuleView(store: store, rule: rule) } }
                AdminChoice(label: "Category", value: $category, options: adminCategories)
                AdminChoice(label: "Mode", value: $mode, options: ["ask_first", "auto_review", "allow"])
                TextField("Narrow rule description", text: $description)
                TextField("Bot ID (empty = any)", text: $bot)
                TextField("Machine ID (empty = any)", text: $machine)
                Toggle("Required locked rule (admin only)", isOn: $required).disabled(store.member?.role == "member")
                Text("A future rule never authorizes a retained expired request. Outward drafts still require explicit Send, and personal connector accounts still require consent.")
                AdminAction(title: "Create rule", store: store, control: control) {
                    var body: JSONObject = ["category": .string(category), "mode": .string(mode), "description": .string(description), "required": .bool(required)]
                    if !bot.isEmpty { body["botId"] = .string(bot) }; if !machine.isEmpty { body["machineId"] = .string(machine) }
                    _ = try await store.mutate("POST", "/policies/rules", body: body, as: PolicyRule.self); try await load()
                }
            }
            Section("Own connector grants") {
                ForEach(consents) { consent in ConnectorConsentRow(store: store, consent: consent, refresh: load) }
            }
            Section("Attention queue") {
                ForEach(approvals) { approval in
                    Text("\(approval.title) · \(approval.gate.state) · \(approval.scope.machineLabel)")
                    Text(approval.description)
                    Button("Open exact request") { Task { await control.perform { try await store.openConversation(approval.conversationId); store.selectedConversationID = approval.conversationId } } }
                }
            }
            Button("Refresh") { Task { await control.perform { try await load() } } }
        }.navigationTitle("Policies").task { await control.perform { try await load() } }
    }
    private func load() async throws {
        let value = try await store.read("/policies", as: Policies.self); policies = value
        publicTemplates = value.publicTemplates; unrestrictedOrigins = value.allowedMcpOrigins == nil; origins = (value.allowedMcpOrigins ?? []).joined(separator: "\n"); ceiling = value.localExecutionCeiling; recording = value.actionRecording; retention = value.auditRetentionDays
        effective = try await store.read("/policies/effective", as: EffectivePolicy.self)
        consents = try await adminReadAll(store, "/consents", as: ConnectorConsent.self)
        approvals = try await adminReadAll(store, "/approvals", query: ["state": "pending"], as: Approval.self)
    }
}

struct PolicyRuleView: View {
    let store: LemonBotStore
    let rule: PolicyRule
    @State private var current: PolicyRule?
    @State private var mode = "ask_first"
    @State private var description = ""
    @State private var control = AdminControl()
    var body: some View {
        Form {
            AdminStatus(control: control, store: store)
            Text("\(rule.category) · bot \(rule.botId ?? "any") · machine \(rule.machineId ?? "any")")
            Text(rule.required ? "Required policy; cannot be relaxed by personal choice." : "Personal rule")
            AdminChoice(label: "Mode", value: $mode, options: ["ask_first", "auto_review", "allow"])
            TextField("Description", text: $description)
            AdminAction(title: "Save rule", store: store, control: control) {
                current = try await store.mutate("PATCH", "/policies/rules/\(adminPath(rule.id))", body: ["revision": .number(Double((current ?? rule).revision)), "mode": .string(mode), "description": .string(description)], as: PolicyRule.self)
            }.disabled(rule.required && store.member?.role == "member")
            AdminAction(title: "Delete this rule", store: store, control: control, destructive: true) {
                _ = try await store.mutate("DELETE", "/policies/rules/\(adminPath(rule.id))", body: adminRevision((current ?? rule).revision), as: Deleted.self); control.notice = "Rule deleted; refresh policy inventory."
            }.disabled(rule.required && store.member?.role == "member")
        }.navigationTitle("Rule").onAppear { mode = rule.mode; description = rule.description }
    }
}

struct ConnectorConsentRow: View {
    let store: LemonBotStore
    let consent: ConnectorConsent
    let refresh: () async throws -> Void
    @State private var control = AdminControl()
    @State private var expiring = true
    @State private var days = 30
    var body: some View {
        VStack(alignment: .leading) {
            Text("Account owner \(consent.accountOwnerUserId) · connector \(consent.connectorId) · Bot \(consent.botId)")
            Text("\(consent.scope) · \(consent.gate.state) · expires \(adminDate(Double(consent.gate.expiresAtMs)))")
            if consent.gate.state == "pending" {
                Toggle("Expire remembered Bot grant", isOn: $expiring)
                if expiring { Stepper("Grant expires after \(days) days", value: $days, in: 1...365) }
                ForEach(["allow_once", "allow_bot", "decline"], id: \.self) { decision in
                    AdminAction(title: decision.replacingOccurrences(of: "_", with: " "), store: store, control: control) {
                        var body: JSONObject = ["revision": .number(Double(consent.revision)), "decision": .string(decision)]
                        if decision == "allow_bot" && expiring { body["expiresAtMs"] = .number((Date().addingTimeInterval(Double(days) * 86_400).timeIntervalSince1970 * 1000).rounded(.down)) }
                        _ = try await store.mutate("POST", "/consents/\(adminPath(consent.id))/resolve", body: body, as: ConnectorConsent.self); try await refresh()
                    }.disabled(consent.gate.targetUserId != store.user?.id || Double(consent.gate.expiresAtMs) <= Date().timeIntervalSince1970 * 1000)
                }
            }
            AdminAction(title: "Revoke grant for future use", store: store, control: control, destructive: true) {
                _ = try await store.mutate("DELETE", "/consents/\(adminPath(consent.id))", body: adminRevision(consent.revision), as: Deleted.self); try await refresh()
            }
            if let error = control.error { Text(error).foregroundStyle(.red) }
        }
    }
}
