import SwiftUI
import LemonBotKit

/// One compact meta line (state · expiry · who it is for); revision and raw target ID live in Details.
struct GateStatusView: View {
    let store: LemonBotStore
    let gate: Gate
    /// Show the Details disclosure. Cards that already have their own Details group pass false and include `GateDetailLines`.
    var details = true
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let expired = gate.state == "pending" && Double(gate.expiresAtMs) <= context.date.timeIntervalSince1970 * 1000
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        StatusBadge(text: expired ? "expired" : gate.state)
                        Text(metaText(now: context.date, expired: expired)).cardMeta()
                    }
                    if gate.state != "pending" { Text(["denied", "declined", "expired", "cancelled"].contains(gate.state) ? "No action was authorized." : gate.state == "approved" ? "Permission recorded; execution is not yet proven." : gate.state == "outcome_unknown" ? "Outcome not confirmed. Do not replay this action." : "Authoritative response recorded.").cardMeta() }
                }
            }
            if details { CardDetails { GateDetailLines(store: store, gate: gate) } }
        }
    }
    private func metaText(now: Date, expired: Bool) -> String {
        let audience = gate.targetUserId == store.user?.id ? "for you" : "for someone else"
        guard gate.state == "pending", !expired else { return audience }
        return "Expires in \(compactDuration(from: now, to: timestamp(Double(gate.expiresAtMs)))) · \(audience)"
    }
}
/// Exact gate facts for a Details disclosure.
struct GateDetailLines: View {
    let store: LemonBotStore
    let gate: Gate
    var body: some View {
        Text("Target user: \(gate.targetUserId == store.user?.id ? "You" : gate.targetUserId)").textSelection(.enabled)
        Text("Expires \(timestamp(Double(gate.expiresAtMs)).formatted())")
        Text("Revision \(gate.revision)")
    }
}
@MainActor
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
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(symbol: "checkmark.shield", title: proposal.title)
            if !proposal.description.isEmpty { Text(proposal.description).font(LBFont.body).foregroundStyle(LB.ink) }
            // Key facts stay visible: exact target, scope, Bot, machine and consequences.
            VStack(alignment: .leading, spacing: 3) {
                cardFact("Target", proposal.target).textSelection(.enabled)
                cardFact("Scope", proposal.scope.label)
                cardFact("Bot · Machine", "\(store.bots.first(where: { $0.id == proposal.botId })?.name ?? proposal.botId) · \(proposal.scope.machineLabel)")
                ForEach(proposal.scope.consequences, id: \.self) { consequence in CardNote(symbol: "exclamationmark.triangle.fill", text: consequence, tint: LB.warning) }
            }.font(LBFont.rowSubtitle).frame(maxWidth: .infinity, alignment: .leading)
            GateStatusView(store: store, gate: proposal.gate, details: false)
            CardDetails {
                HStack(spacing: 6) { StatusBadge(text: proposal.category); StatusBadge(text: proposal.scope.kind) }
                if let origin = proposal.scope.origin { Text("Origin: \(origin)").textSelection(.enabled) }
                if let connector = proposal.scope.connectorId { Text("Connector: \(connector)").textSelection(.enabled) }
                if let run = proposal.scope.runId { Text("Run: \(run)").textSelection(.enabled) }
                Text("Review scope expires \(timestamp(Double(proposal.scope.expiresAtMs)).formatted())")
                ForEach(Array(proposal.inputs.keys.sorted()), id: \.self) { key in
                    Text("\(key): \(inputSummary(proposal.inputs[key]!))").textSelection(.enabled)
                }
                Text("Review: \(proposal.review) · policy: \(proposal.policyMode)\(proposal.ruleId.map { " · rule \($0)" } ?? "")")
                GateDetailLines(store: store, gate: proposal.gate)
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 8) {
                    Button("Allow once") { Task { await resolve("approve_once") } }.buttonStyle(.cardPrimary)
                    Button("Deny", role: .destructive) { Task { await resolve("deny") } }.buttonStyle(.pill(.secondary))
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
            CardHeader(symbol: "questionmark.bubble", title: current.title)
            CardNote(symbol: "eye", text: "Answers are visible to the Bot. Do not enter passwords, one-time codes or confidential credentials.")
            ForEach(current.fields, id: \.id) { field in
                fieldView(field).disabled(!gateAllowsAction(store, current.gate) || action.busy)
            }
            if let recorded = current.answers { ForEach(current.fields, id: \.id) { field in if let value = recorded[field.id] { Text("\(field.label): \(inputSummary(value))").cardMeta() } } }
            GateStatusView(store: store, gate: current.gate)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 8) {
                    Button("Submit") { Task { await resolve(answer: true) } }.buttonStyle(.cardPrimary).disabled(!valid)
                    Button("Decline") { Task { await resolve(answer: false) } }.buttonStyle(.pill(.secondary))
                }.disabled(action.busy || !gateAllowsAction(store, current.gate))
            }
            ActionErrorView(message: action.error)
        }
    }
    @ViewBuilder private func fieldView(_ field: Field) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            let label = field.label + (field.required ? " *" : "")
            if field.kind != "boolean" { Text(label).font(LBFont.metaEmphasis).foregroundStyle(LB.muted) }
            switch field.kind {
            case "boolean":
                Toggle(label, isOn: Binding(get: { answers[field.id]?.boolValue ?? false }, set: { answers[field.id] = .bool($0) })).cardToggle()
            case "single_select":
                CardChoice(placeholder: "Choose…", selection: Binding(get: { answers[field.id]?.stringValue ?? "" }, set: { if $0.isEmpty { answers.removeValue(forKey: field.id) } else { answers[field.id] = .string($0) } }),
                           options: (field.options ?? []).map { (value: $0.value, label: $0.label) })
            case "multi_select":
                ForEach(field.options ?? [], id: \.value) { option in
                    Toggle(option.label, isOn: Binding(get: { answers[field.id]?.arrayValue?.contains(.string(option.value)) ?? false }, set: { selected in
                        var values = answers[field.id]?.arrayValue ?? []
                        values.removeAll { $0 == .string(option.value) }
                        if selected { values.append(.string(option.value)) }
                        answers[field.id] = .array(values)
                    })).cardToggle()
                }
            case "number":
                TextField(field.label, text: Binding(get: { numberText[field.id] ?? answers[field.id].map(inputSummary) ?? "" }, set: { text in
                    numberText[field.id] = text
                    if let number = Double(text), number.isFinite { answers[field.id] = .number(number) } else { answers.removeValue(forKey: field.id) }
                })).cardField()
                if field.min != nil || field.max != nil { Text("Range: \(field.min.map { String($0) } ?? "unbounded") – \(field.max.map { String($0) } ?? "unbounded")").cardMeta() }
                if !(numberText[field.id] ?? "").isEmpty && answers[field.id] == nil { Text("Enter a finite number.").font(LBFont.meta).foregroundStyle(LB.danger) }
            case "multiline":
                TextField(field.label, text: stringBinding(field), axis: .vertical).lineLimit(3...8).cardField()
            default: TextField(field.label, text: stringBinding(field)).cardField()
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
        VStack(alignment: .leading, spacing: 8) {
            if let question { QuestionAnswerView(store: store, question: question) }
            if action.inFlight { ProgressView("Loading current question…").font(LBFont.meta).foregroundStyle(LB.muted) }
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
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(symbol: "lock", title: "Save secret securely: \(current.name)")
            if !current.description.isEmpty { Text(current.description).font(LBFont.body).foregroundStyle(LB.ink) }
            cardFact("Scope", "\(current.scope) · Bot \(store.bots.first(where: { $0.id == current.botId })?.name ?? current.botId) · machine \(store.machines.first(where: { $0.id == current.machineId })?.name ?? current.machineId)")
                .font(LBFont.rowSubtitle).textSelection(.enabled)
            CardNote(symbol: "lock.shield", text: "Write-only destination storage. Co-resident Bots and the privileged machine owner may access shared host credentials. The value is never saved in this composer or transcript.", tint: LB.warning)
            SecureField("Secret value", text: $value).cardField().disabled(!gateAllowsAction(store, current.gate))
            GateStatusView(store: store, gate: current.gate, details: false)
            CardDetails {
                Text("Bot ID: \(current.botId)").textSelection(.enabled)
                Text("Machine ID: \(current.machineId)").textSelection(.enabled)
                GateDetailLines(store: store, gate: current.gate)
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 8) {
                    Button("Save securely") { Task { await resolve(save: true) } }.buttonStyle(.cardPrimary).disabled(value.isEmpty)
                    Button("Decline") { value = ""; Task { await resolve(save: false) } }.buttonStyle(.pill(.secondary))
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
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(symbol: "person.badge.key", title: current.title) { StatusBadge(text: current.reason) }
            Text(current.instructions).font(LBFont.body).foregroundStyle(LB.ink)
            CardNote(symbol: "lock", text: "Complete login or verification on the machine or external site. Do not paste credentials into chat. “I'm done” asks the Bot to recheck; it does not prove login succeeded.")
            CardActions {
                NavigationLink { MachineDetailView(store: store, machineID: current.machineId) } label: { Text("Open machine") }.buttonStyle(.pill(.secondary, compact: true))
                if hostAccess {
                    NavigationLink { MachineTerminalView(store: store, machineID: current.machineId) } label: { Text("Open terminal") }.buttonStyle(.pill(.secondary, compact: true))
                        .accessibilityLabel("Open terminal, full host access").help("Open terminal · full host access")
                }
                if let external = current.externalUrl, let url = safeExternalURL(external), url.scheme == "https" {
                    Button("Open \(url.host ?? "external site")") { openURL(url) }.buttonStyle(.pill(.secondary, compact: true))
                }
            }
            GateStatusView(store: store, gate: current.gate)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 8) {
                    Button("I'm done") { Task { await resolve("done") } }.buttonStyle(.cardPrimary)
                    Button("Skip") { Task { await resolve("skip") } }.buttonStyle(.pill(.secondary))
                }.disabled(action.busy || !gateAllowsAction(store, current.gate))
            }
            ActionErrorView(message: action.error)
        }
    }
    private var hostAccess: Bool { store.machines.contains { $0.id == current.machineId && ($0.ownerUserId == store.user?.id || $0.accessUserIds.contains(store.user?.id ?? "") || ["owner", "admin"].contains(store.member?.role ?? "")) } }
    private func resolve(_ decision: String) async { await action.perform { resolved = try await store.mutate("POST", resourcePath("human-steps", current.id, "/resolve"), body: ["revision": .number(Double(current.revision)), "decision": .string(decision)]) } }
}
