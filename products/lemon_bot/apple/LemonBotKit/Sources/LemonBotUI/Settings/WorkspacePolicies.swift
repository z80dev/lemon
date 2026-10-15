import SwiftUI
import LemonBotKit

let adminCategories = ["shell", "files", "external_message", "calendar", "publish", "purchase", "permissions", "connector", "handoff"]

struct WorkspaceSettingsView: View {
    let store: LemonBotStore
    @State private var control = AdminControl()
    @State private var workspace: Workspace?
    @State private var name = ""
    @State private var timezone = "UTC"
    @State private var enabled = true
    var body: some View {
        Form {
            AdminStatus(control: control, store: store, refresh: { await control.perform { try await load() } })
            Section("Workspace") {
                TextField("Name", text: $name); TextField("IANA timezone", text: $timezone)
                Toggle("Workspace enabled", isOn: $enabled)
                AdminAction(title: "Save workspace", store: store, control: control) {
                    guard let workspace else { return }
                    self.workspace = try await store.mutate("PATCH", "/workspace", body: ["revision": .number(Double(workspace.revision)), "name": .string(name), "timezone": .string(timezone), "enabled": .bool(enabled)], as: Workspace.self)
                    try await store.refresh()
                }.disabled(store.member?.role != "owner" || workspace == nil)
            }
            Button("Refresh") { Task { await control.perform { try await load() } } }
        }.navigationTitle("Workspace").task { await control.perform { try await load() } }
    }
    private func load() async throws {
        let value = try await store.read("/workspace", as: Workspace.self); workspace = value; name = value.name; timezone = value.timezone; enabled = value.enabled
    }
}


struct PolicySettingsView: View {
    let store: LemonBotStore
    @State private var control = AdminControl()
    @State private var policies: Policies?
    @State private var effective: EffectivePolicy?
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
            AdminStatus(control: control, store: store, refresh: { await control.perform { try await load() } })
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

