import SwiftUI
import LemonBotKit

struct GateStatusView: View {
    let store: LemonBotStore
    let gate: Gate
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 4) {
                StatusBadge(text: gate.state == "pending" && Double(gate.expiresAtMs) <= context.date.timeIntervalSince1970 * 1000 ? "expired" : gate.state)
                Text("Target: \(gate.targetUserId == store.user?.id ? "You" : gate.targetUserId) · expires \(timestamp(Double(gate.expiresAtMs)).formatted()) · revision \(gate.revision)").font(.caption)
                if gate.state != "pending" { Text(["denied", "declined", "expired", "cancelled"].contains(gate.state) ? "No action was authorized." : gate.state == "approved" ? "Permission recorded; execution is not yet proven." : gate.state == "outcome_unknown" ? "Outcome not confirmed. Do not replay this action." : "Authoritative response recorded.").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}
func gateAllowsAction(_ store: LemonBotStore, _ gate: Gate) -> Bool {
    store.connectionState == "online" && gate.targetUserId == store.user?.id && gate.state == "pending" && Double(gate.expiresAtMs) > Date().timeIntervalSince1970 * 1000
}

struct ApprovalReviewView: View {
    let store: LemonBotStore
    let approval: Approval
    init(store: LemonBotStore, approval: Approval) { self.store = store; self.approval = approval }
    @State private var action = UIActionState()
    @State private var resolved: Approval?
    private var current: Approval { (resolved?.revision ?? 0) > approval.revision ? resolved! : approval }
    var body: some View {
        let proposal = current
        VStack(alignment: .leading, spacing: 8) {
            Label(proposal.title, systemImage: "checkmark.shield").font(.headline)
            Text(proposal.description)
            HStack { StatusBadge(text: proposal.category); StatusBadge(text: proposal.scope.kind) }
            Text("Bot: \(store.bots.first(where: { $0.id == proposal.botId })?.name ?? proposal.botId) · Machine: \(proposal.scope.machineLabel)").font(.caption)
            Text("Target: \(proposal.target)").textSelection(.enabled)
            Text(proposal.scope.label)
            if let origin = proposal.scope.origin { Text("Origin: \(origin)").font(.caption).textSelection(.enabled) }
            if let connector = proposal.scope.connectorId { Text("Connector: \(connector)").font(.caption) }
            if let run = proposal.scope.runId { Text("Run: \(run)").font(.caption) }
            Text("Review scope expires \(timestamp(Double(proposal.scope.expiresAtMs)).formatted())").font(.caption)
            ForEach(Array(proposal.inputs.keys.sorted()), id: \.self) { key in
                Text("\(key): \(inputSummary(proposal.inputs[key]!))").font(.callout).textSelection(.enabled)
            }
            ForEach(proposal.scope.consequences, id: \.self) { consequence in Label(consequence, systemImage: "exclamationmark.circle") }
            Text("Review: \(proposal.review) · policy: \(proposal.policyMode)\(proposal.ruleId.map { " · rule \($0)" } ?? "")").font(.caption)
            GateStatusView(store: store, gate: proposal.gate)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack {
                    Button("Allow once") { Task { await resolve("approve_once") } }
                    Button("Deny", role: .destructive) { Task { await resolve("deny") } }
                }.disabled(action.busy || !gateAllowsAction(store, proposal.gate) || Double(proposal.scope.expiresAtMs) <= Date().timeIntervalSince1970 * 1000)
            }
            ActionErrorView(message: action.error)
        }
    }
    private func resolve(_ decision: String) async {
        await action.perform {
            resolved = try await store.mutate("POST", resourcePath("approvals", current.id, "/resolve"), body: ["revision": .number(Double(current.revision)), "decision": .string(decision)])
        }
    }
}
private func inputSummary(_ value: JSONValue) -> String {
    switch value {
    case .null: return "None"
    case .string(let text): return text
    case .number(let number): return String(number)
    case .bool(let flag): return flag ? "Yes" : "No"
    case .array(let items): return items.map(inputSummary).joined(separator: ", ")
    case .object(let object): return object.keys.sorted().map { "\($0): \(inputSummary(object[$0]!))" }.joined(separator: "; ")
    }
}

struct QuestionAnswerView: View {
    let store: LemonBotStore
    let question: Question
    @State private var answers: JSONObject = [:]
    @State private var numberText: [String: String] = [:]
    @State private var resolved: Question?
    @State private var action = UIActionState()
    init(store: LemonBotStore, question: Question) {
        self.store = store; self.question = question
        _answers = State(initialValue: Dictionary(uniqueKeysWithValues: question.fields.filter { $0.required && $0.kind == "boolean" }.map { ($0.id, JSONValue.bool(false)) }))
    }
    private var current: Question { (resolved?.revision ?? 0) > question.revision ? resolved! : question }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(current.title).font(.headline)
            Text("Ordinary answers are visible to the Bot. Do not enter passwords, one-time codes or confidential credentials.").font(.caption).foregroundStyle(.orange)
            ForEach(current.fields, id: \.id) { field in
                fieldView(field).disabled(!gateAllowsAction(store, current.gate) || action.busy)
            }
            if let recorded = current.answers { ForEach(current.fields, id: \.id) { field in if let value = recorded[field.id] { Text("\(field.label): \(inputSummary(value))").font(.caption) } } }
            GateStatusView(store: store, gate: current.gate)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack {
                    Button("Submit") { Task { await resolve(answer: true) } }.disabled(!valid)
                    Button("Decline") { Task { await resolve(answer: false) } }
                }.disabled(action.busy || !gateAllowsAction(store, current.gate))
            }
            ActionErrorView(message: action.error)
        }
    }
    @ViewBuilder private func fieldView(_ field: Field) -> some View {
        VStack(alignment: .leading) {
            Text(field.label + (field.required ? " *" : ""))
            switch field.kind {
            case "boolean":
                Toggle(field.label, isOn: Binding(get: { answers[field.id]?.boolValue ?? false }, set: { answers[field.id] = .bool($0) }))
            case "single_select":
                Picker(field.label, selection: Binding(get: { answers[field.id]?.stringValue ?? "" }, set: { if $0.isEmpty { answers.removeValue(forKey: field.id) } else { answers[field.id] = .string($0) } })) {
                    Text("Choose…").tag("")
                    ForEach(field.options ?? [], id: \.value) { option in Text(option.label).tag(option.value) }
                }
            case "multi_select":
                ForEach(field.options ?? [], id: \.value) { option in
                    Toggle(option.label, isOn: Binding(get: { answers[field.id]?.arrayValue?.contains(.string(option.value)) ?? false }, set: { selected in
                        var values = answers[field.id]?.arrayValue ?? []
                        values.removeAll { $0 == .string(option.value) }
                        if selected { values.append(.string(option.value)) }
                        answers[field.id] = .array(values)
                    }))
                }
            case "number":
                TextField(field.label, text: Binding(get: { numberText[field.id] ?? answers[field.id].map(inputSummary) ?? "" }, set: { text in
                    numberText[field.id] = text
                    if let number = Double(text), number.isFinite { answers[field.id] = .number(number) } else { answers.removeValue(forKey: field.id) }
                })).textFieldStyle(.roundedBorder)
                if field.min != nil || field.max != nil { Text("Range: \(field.min.map { String($0) } ?? "unbounded") – \(field.max.map { String($0) } ?? "unbounded")").font(.caption) }
                if !(numberText[field.id] ?? "").isEmpty && answers[field.id] == nil { Text("Enter a finite number.").font(.caption).foregroundStyle(.red) }
            case "multiline":
                TextField(field.label, text: stringBinding(field), axis: .vertical).lineLimit(3...8).textFieldStyle(.roundedBorder)
            default: TextField(field.label, text: stringBinding(field)).textFieldStyle(.roundedBorder)
            }
        }
    }
    private func stringBinding(_ field: Field) -> Binding<String> {
        Binding(get: { answers[field.id]?.stringValue ?? "" }, set: { if $0.isEmpty && !field.required { answers.removeValue(forKey: field.id) } else { answers[field.id] = .string($0) } })
    }
    private var valid: Bool {
        current.fields.allSatisfy { field in
            guard let value = answers[field.id] else { return !field.required && (field.kind != "number" || (numberText[field.id] ?? "").isEmpty) }
            switch field.kind {
            case "boolean": return value.boolValue != nil
            case "number":
                guard case .number(let number) = value else { return false }
                return number.isFinite && (field.min.map { number >= Double($0) } ?? true) && (field.max.map { number <= Double($0) } ?? true)
            case "single_select": return field.options?.contains { $0.value == value.stringValue } ?? false
            case "multi_select":
                guard let values = value.arrayValue else { return false }
                return (!field.required || !values.isEmpty) && values.allSatisfy { item in field.options?.contains { $0.value == item.stringValue } ?? false }
            default: return !field.required || !(value.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }
    private func resolve(answer: Bool) async {
        await action.perform {
            var body: JSONObject = ["revision": .number(Double(current.revision)), "decision": .string(answer ? "answer" : "decline")]
            if answer { body["answers"] = .object(answers) }
            resolved = try await store.mutate("POST", resourcePath("questions", current.id, "/resolve"), body: body)
        }
    }
}
struct WidgetAnswerView: View {
    let store: LemonBotStore
    let questionID: ID
    init(store: LemonBotStore, questionID: ID) { self.store = store; self.questionID = questionID }
    @State private var question: Question?
    @State private var action = UIActionState()
    var body: some View {
        VStack(alignment: .leading) {
            if let question { QuestionAnswerView(store: store, question: question) }
            if action.inFlight { ProgressView("Loading current question…") }
            ActionErrorView(message: action.error)
        }.task(id: "\(questionID):\(store.eventVersion)") { await action.perform { question = try await store.read(resourcePath("questions", questionID)) } }
    }
}

struct SecretRequestView: View {
    let store: LemonBotStore
    let request: SecretRequest
    init(store: LemonBotStore, request: SecretRequest) { self.store = store; self.request = request }
    @State private var value = ""
    @State private var resolved: SecretRequest?
    @State private var action = UIActionState()
    private var current: SecretRequest { (resolved?.revision ?? 0) > request.revision ? resolved! : request }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Save secret securely: \(current.name)", systemImage: "lock").font(.headline)
            Text(current.description)
            Text("\(current.scope) scope · Bot \(current.botId) · machine \(current.machineId)").font(.caption)
            Text("Write-only destination storage. Co-resident Bots and the privileged machine owner may access shared host credentials. The value is never saved in this composer or transcript.").font(.caption).foregroundStyle(.orange)
            SecureField("Secret value", text: $value).textFieldStyle(.roundedBorder).disabled(!gateAllowsAction(store, current.gate))
            GateStatusView(store: store, gate: current.gate)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack {
                    Button("Save securely") { Task { await resolve(save: true) } }.disabled(value.isEmpty)
                    Button("Decline") { value = ""; Task { await resolve(save: false) } }
                }.disabled(action.busy || !gateAllowsAction(store, current.gate))
            }
            ActionErrorView(message: action.error)
        }.onDisappear { value = "" }
    }
    private func resolve(save: Bool) async {
        let captured = value
        value = ""
        await action.perform {
            var body: JSONObject = ["revision": .number(Double(current.revision)), "decision": .string(save ? "save" : "decline")]
            if save { body["value"] = .string(captured) }
            resolved = try await store.mutate("POST", resourcePath("secret-requests", current.id, "/resolve"), body: body)
        }
    }
}
struct HumanStepView: View {
    let store: LemonBotStore
    let step: HumanStep
    init(store: LemonBotStore, step: HumanStep) { self.store = store; self.step = step }
    @Environment(\.openURL) private var openURL
    @State private var resolved: HumanStep?
    @State private var action = UIActionState()
    private var current: HumanStep { (resolved?.revision ?? 0) > step.revision ? resolved! : step }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(current.title, systemImage: "person.badge.key").font(.headline)
            StatusBadge(text: current.reason)
            Text(current.instructions)
            NavigationLink("Open machine") { MachineDetailView(store: store, machineID: current.machineId) }
            if hostAccess {
                NavigationLink("Open terminal · full host access") { MachineTerminalView(store: store, machineID: current.machineId) }
            }
            if let external = current.externalUrl, let url = safeExternalURL(external), url.scheme == "https" {
                Button("Open \(url.host ?? "external site")") { openURL(url) }
            }
            Text("Complete login or verification on the machine or external site. Do not paste credentials into chat. “I'm done” asks the Bot to recheck; it does not prove login succeeded.").font(.caption)
            GateStatusView(store: store, gate: current.gate)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack { Button("I'm done") { Task { await resolve("done") } }; Button("Skip") { Task { await resolve("skip") } } }
                    .disabled(action.busy || !gateAllowsAction(store, current.gate))
            }
            ActionErrorView(message: action.error)
        }
    }
    private var hostAccess: Bool { store.machines.contains { $0.id == current.machineId && ($0.ownerUserId == store.user?.id || $0.accessUserIds.contains(store.user?.id ?? "") || ["owner", "admin"].contains(store.member?.role ?? "")) } }
    private func resolve(_ decision: String) async { await action.perform { resolved = try await store.mutate("POST", resourcePath("human-steps", current.id, "/resolve"), body: ["revision": .number(Double(current.revision)), "decision": .string(decision)]) } }
}
struct ConnectorConsentView: View {
    let store: LemonBotStore
    let consent: ConnectorConsent
    init(store: LemonBotStore, consent: ConnectorConsent) { self.store = store; self.consent = consent }
    @State private var resolved: ConnectorConsent?
    @State private var connector: Connector?
    @State private var rememberedExpiry = Date().addingTimeInterval(86400 * 7)
    @State private var action = UIActionState()
    private var current: ConnectorConsent { (resolved?.revision ?? 0) > consent.revision ? resolved! : consent }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Allow this account for the requested Bot?", systemImage: "person.crop.circle.badge.checkmark").font(.headline)
            if let connector { Text("\(connector.name) · \(connector.accountLabel)"); Text(connector.url).font(.caption).textSelection(.enabled) }
            Text("Account owner: \(current.accountOwnerUserId) · Bot: \(store.bots.first(where: { $0.id == current.botId })?.name ?? current.botId)")
            Text("This permits only this account and scope. Consequential writes still require their own review or explicit draft Send.").font(.caption)
            DatePicker("Remember until", selection: $rememberedExpiry, in: Date()...)
            GateStatusView(store: store, gate: current.gate)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack {
                    Button("Allow once") { Task { await resolve("allow_once") } }
                    Button("Allow this Bot") { Task { await resolve("allow_bot") } }
                    Button("Decline") { Task { await resolve("decline") } }
                }.disabled(action.busy || !gateAllowsAction(store, current.gate) || current.accountOwnerUserId != store.user?.id)
            }
            ActionErrorView(message: action.error)
        }.task(id: "\(consent.connectorId):\(store.eventVersion)") { await action.perform { connector = try await visibleConnector(store, consent.connectorId, botID: consent.botId) } }
    }
    private func resolve(_ decision: String) async {
        await action.perform {
            var body: JSONObject = ["revision": .number(Double(current.revision)), "decision": .string(decision)]
            if decision == "allow_bot" { body["expiresAtMs"] = .number(rememberedExpiry.timeIntervalSince1970 * 1000) }
            resolved = try await store.mutate("POST", resourcePath("consents", current.id, "/resolve"), body: body)
        }
    }
}
