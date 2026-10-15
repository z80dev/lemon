import SwiftUI
import LemonBotKit

struct NetworkRuleDraft: Identifiable {
    let id = UUID()
    var kind = "domain"
    var value = ""
    var ports = "443"
    var transport = "tcp"
    func body() throws -> JSONValue {
        let values = adminStrings(ports)
        var numbers: [JSONValue] = []
        for value in values {
            guard let port = Int(value), (1...65535).contains(port) else { throw AdminFormError("Ports must be integers from 1 to 65535.") }
            numbers.append(.number(Double(port)))
        }
        return .object(["kind": .string(kind), "value": .string(value), "ports": .array(numbers), "protocol": .string(transport)])
    }
}
struct AdminFormError: LocalizedError { let errorDescription: String?; init(_ message: String) { errorDescription = message } }
struct NetworkRuleEditor: View {
    @Binding var rules: [NetworkRuleDraft]
    var body: some View {
        ForEach($rules) { $rule in
            VStack(alignment: .leading) {
                AdminChoice(label: "Destination kind", value: $rule.kind, options: ["domain", "ip_cidr"])
                TextField("Exact domain, *.suffix, or canonical CIDR", text: $rule.value)
                TextField("Ports (empty = all)", text: $rule.ports)
                AdminChoice(label: "Transport", value: $rule.transport, options: ["tcp", "udp", "both"])
                Button("Remove destination", role: .destructive) { rules.removeAll { $0.id == rule.id } }
            }
        }
        Button("Add domain or IP rule") { rules.append(NetworkRuleDraft()) }
    }
}

struct NetworkSettingsView: View {
    let store: LemonBotStore
    @State private var control = AdminControl()
    @State private var policies: [NetworkPolicy] = []
    @State private var egress: [EgressRoute] = []
    @State private var mode = "defaults_plus_allowlist"
    @State private var rules: [NetworkRuleDraft] = []
    @State private var source = ""
    @State private var through = ""
    @State private var enabled = false
    var body: some View {
        Form {
            AdminStatus(control: control, store: store, refresh: { await control.perform { try await load() } })
            Section("Desired policies") {
                Text("Desired rules are not proof of host enforcement. Apply requires configured destination HostDriverConfig.networkApply, node.shell support and explicit authority. Bot admission is blocked until required policy is actually applied. MCP-origin blocks are distinct from website network restrictions.")
                ForEach(policies) { policy in NavigationLink("\(policy.scope) · \(policy.mode) · desired revision \(policy.revision)") { NetworkPolicySettingsView(store: store, policy: policy) } }
            }
            Section("Create network policy") {
                AdminChoice(label: "Mode", value: $mode, options: ["allow_all", "defaults_plus_allowlist", "allowlist_only"])
                NetworkRuleEditor(rules: $rules)
                AdminAction(title: "Save desired policy", store: store, control: control) {
                    let body: JSONObject = ["scope": .string("workspace"), "mode": .string(mode), "rules": .array(try rules.map { try $0.body() })]
                    _ = try await store.mutate("POST", "/network-policies", body: body, as: NetworkPolicy.self); try await load()
                }
            }
            Section("Explicit egress routing") {
                Text("Source and through-machine must both be authorized, with configured authenticated/encrypted proxy/tunnel host drivers. This changes new connections only. A central disable stops the route; remembered preference is not a new trust grant.")
                ForEach(egress) { route in EgressRouteSettingsRow(store: store, route: route, refresh: load) }
                Picker("Source machine", selection: $source) { Text("Choose").tag(""); ForEach(store.machines) { Text($0.name).tag($0.id) } }
                Picker("Through machine", selection: $through) { Text("Choose").tag(""); ForEach(store.machines) { Text($0.name).tag($0.id) } }
                Toggle("Explicitly enable this route", isOn: $enabled)
                AdminAction(title: "Create route", store: store, control: control) {
                    _ = try await store.mutate("POST", "/egress-routes", body: ["machineId": .string(source), "throughMachineId": .string(through), "enabled": .bool(enabled)], as: EgressRoute.self); try await load()
                }.disabled(source.isEmpty || through.isEmpty || source == through)
            }
            Button("Refresh desired/applied and route state") { Task { await control.perform { try await load() } } }
        }.navigationTitle("Network").task { await control.perform { try await load() } }
    }
    private func load() async throws { policies = try await adminReadAll(store, "/network-policies", as: NetworkPolicy.self); egress = try await adminReadAll(store, "/egress-routes", as: EgressRoute.self) }
}

struct NetworkPolicySettingsView: View {
    let store: LemonBotStore
    let policy: NetworkPolicy
    @State private var control = AdminControl()
    @State private var current: NetworkPolicy?
    @State private var mode = "allowlist_only"
    @State private var rules: [NetworkRuleDraft] = []
    @State private var machines: Set<String> = []
    @State private var applications: [PolicyApplication] = []
    var body: some View {
        Form {
            AdminStatus(control: control, store: store)
            Section("Desired configuration") {
                Text("\(policy.scope) · group \(policy.directoryGroupId ?? "none") · revision \((current ?? policy).revision)")
                AdminChoice(label: "Mode", value: $mode, options: ["allow_all", "defaults_plus_allowlist", "allowlist_only"])
                NetworkRuleEditor(rules: $rules)
                AdminAction(title: "Save new desired revision", store: store, control: control) {
                    current = try await store.mutate("PATCH", "/network-policies/\(adminPath(policy.id))", body: ["revision": .number(Double((current ?? policy).revision)), "mode": .string(mode), "rules": .array(try rules.map { try $0.body() })], as: NetworkPolicy.self)
                }
                AdminAction(title: "Delete desired policy", store: store, control: control, destructive: true) {
                    _ = try await store.mutate("DELETE", "/network-policies/\(adminPath(policy.id))", body: adminRevision((current ?? policy).revision), as: Deleted.self); control.notice = "Policy removed; host application state remains authoritative."
                }
            }
            Section("Required operator runtime destinations") {
                ForEach(Array((current ?? policy).requiredRuntimeDestinations.enumerated()), id: \.offset) { _, rule in Text("\(rule.kind): \(rule.value) · \(rule.ports.map(String.init).joined(separator: ",")) · \(rule.protocol)") }
            }
            Section("Apply to explicit machine set") {
                AdminMachineSelection(store: store, ids: $machines)
                AdminAction(title: "Apply desired policy", store: store, control: control) {
                    let page = try await store.mutate("POST", "/network-policies/\(adminPath(policy.id))/apply", body: ["machineIds": adminArray(machines.sorted())], as: Page<PolicyApplication>.self)
                    applications = page.items
                    try await loadApplications()
                }.disabled(machines.isEmpty)
                ForEach(Array(applications.enumerated()), id: \.offset) { _, value in
                    Text("\(value.machineId) · desired \(value.desiredRevision) · applied \(value.appliedRevision.map(String.init) ?? "unknown") · \(value.state)")
                    if let error = value.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    Text("Measured \(adminDate(Double(value.measuredAtMs)))").font(.caption)
                }
                Button("Refresh observed applications (does not reapply)") { Task { await control.perform { try await loadApplications() } } }
            }
        }.navigationTitle("Network policy").task {
            mode = policy.mode; rules = policy.rules.map { NetworkRuleDraft(kind: $0.kind, value: $0.value, ports: $0.ports.map(String.init).joined(separator: ","), transport: $0.protocol) }
            await control.perform { try await loadApplications() }
        }
    }
    private func loadApplications() async throws { applications = try await adminReadAll(store, "/network-policies/\(adminPath(policy.id))/applications", as: PolicyApplication.self) }
}

struct EgressRouteSettingsRow: View {
    let store: LemonBotStore
    let route: EgressRoute
    let refresh: () async throws -> Void
    @State private var control = AdminControl()
    var body: some View {
        VStack(alignment: .leading) {
            Text("\(route.machineId) → \(route.throughMachineId) · \(route.state)")
            Text("Remembered explicit preference: \(route.rememberedPreference ? "yes" : "no")")
            if let error = route.error { Text(error).foregroundStyle(.red) }
            AdminAction(title: route.enabled ? "Disable route" : "Enable route if authorized", store: store, control: control) {
                _ = try await store.mutate("PATCH", "/egress-routes/\(adminPath(route.id))", body: ["revision": .number(Double(route.revision)), "enabled": .bool(!route.enabled)], as: EgressRoute.self); try await refresh()
            }
            AdminAction(title: "Remove route", store: store, control: control, destructive: true) {
                _ = try await store.mutate("DELETE", "/egress-routes/\(adminPath(route.id))", body: adminRevision(route.revision), as: Deleted.self); try await refresh()
            }
            if let error = control.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
    }
}

