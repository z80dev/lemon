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
                    if gate.state != "pending" { Text(["denied", "declined", "expired", "cancelled"].contains(gate.state) ? "No action was authorized." : gate.state == "approved" ? "Allowed. We haven't confirmed it ran." : gate.state == "outcome_unknown" ? "We couldn't confirm this ran. Don't repeat it; check the result first." : "Response recorded.").cardMeta() }
                    if expired || gate.state == "expired" { Text("This request expired. Ask the Bot to make a new one.").cardMeta() }
                    else if gate.state == "pending" && !store.isOnline { Text("Reconnect to respond.").cardMeta() }
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

enum AccessRequestPresentation {
    static let allowLabel = "Allow for this Bot"
    static let denyLabel = "Not now"
    static func reason(_ approval: Approval, botName: String) -> String? {
        guard let reason = approval.inputs["reason"]?.stringValue else { return nil }
        return "\(botName) says: “\(reason)”"
    }
    static func result(state: String, who: String) -> String {
        switch state {
        case "approved": return "Allowed by \(who) · turns on when this task finishes"
        case "denied": return "Not now"
        case "expired": return "Expired"
        default: return humanizedStatus(state)
        }
    }
}

/// Display-only escaping. Never use this text as an executable command or mutation payload.
struct ApprovalTextPresentation {
    let text: String
    let preview: String
    let truncated: Bool
    let hasControls: Bool

    init(_ value: String) {
        var escaped = ""
        var controls = false
        for scalar in value.unicodeScalars {
            let code = scalar.value
            if scalar.properties.generalCategory == .format || scalar.properties.isDefaultIgnorableCodePoint
                || (code < 0x20 && code != 0x09 && code != 0x0A)
                || (0x7F...0x9F).contains(code) || code == 0x2028 || code == 0x2029 {
                escaped += "⟨U+\(String(format: "%04X", code))⟩"
                controls = true
            } else {
                escaped.unicodeScalars.append(scalar)
            }
        }
        text = escaped
        hasControls = controls
        truncated = escaped.unicodeScalars.count > 160
        preview = truncated ? String(String.UnicodeScalarView(escaped.unicodeScalars.prefix(159))) + "…" : escaped
    }

    /// Isolate each paragraph so neither surrounding UI nor command text changes its base direction.
    static func isolated(_ text: String) -> String {
        "\u{2066}" + text.replacingOccurrences(of: "\n", with: "\u{2069}\n\u{2066}") + "\u{2069}"
    }
}

struct ApprovalReviewPresentation {
    struct Identity: Equatable {
        let id: ID
        let revision: Int
        let value: String
        let hasCommand: Bool

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id && lhs.revision == rhs.revision && lhs.hasCommand == rhs.hasCommand
                && lhs.value.unicodeScalars.elementsEqual(rhs.value.unicodeScalars)
        }
    }

    let identity: Identity
    let text: ApprovalTextPresentation
    let missingCommand: Bool
    let accessRequest: Bool
    let terminal: Bool

    init(_ approval: Approval) {
        accessRequest = approval.source == "access_request"
        terminal = !accessRequest && approval.target == "Terminal"
        let command = terminal ? approval.inputs["command"]?.stringValue : nil
        let value = command ?? approval.title
        identity = Identity(id: approval.id, revision: approval.revision, value: value, hasCommand: command != nil)
        text = ApprovalTextPresentation(value)
        missingCommand = terminal && (command?.isEmpty ?? true)
    }

    func allowsApproval(expanded: Identity?) -> Bool {
        !terminal || (!missingCommand && (!text.truncated || expanded == identity))
    }
}

@ViewBuilder
private func approvalDetailText(_ value: String, accessRequest: Bool) -> some View {
    if accessRequest {
        Text(verbatim: value)
            .lineLimit(nil).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    } else {
        let presentation = ApprovalTextPresentation(value)
        VStack(alignment: .leading, spacing: 4) {
            if presentation.hasControls { LabelChip(text: "Escaped controls", tint: LB.warning) }
            Text(verbatim: ApprovalTextPresentation.isolated(presentation.text))
                .lineLimit(nil).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .environment(\.layoutDirection, .leftToRight)
        }
    }
}

struct ApprovalReviewView: View {
    let store: LemonBotStore
    let approval: Approval
    init(store: LemonBotStore, approval: Approval) { self.store = store; self.approval = approval }
    @State private var action = UIActionState()
    @State private var resolved: Approval?
    @State private var botWide = false
    @State private var botWideReview: ApprovalReviewPresentation.Identity?
    @State private var expandedReview: ApprovalReviewPresentation.Identity?
    @State private var rememberedPolicy: EffectivePolicy?
    private var current: Approval { (resolved?.revision ?? 0) > approval.revision ? resolved! : approval }
    var body: some View {
        let proposal = current
        let accessRequest = proposal.source == "access_request"
        let review = ApprovalReviewPresentation(proposal)
        let expanded = expandedReview == review.identity
        let canApprove = review.allowsApproval(expanded: expandedReview)
        VStack(alignment: .leading, spacing: 10) {
            if review.terminal {
                if review.text.truncated && expanded {
                    ScrollView {
                        commandText(review.text.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 260)
                } else {
                    commandText(review.text.preview)
                }
                if review.text.hasControls {
                    LabelChip(text: "Escaped controls", tint: LB.warning)
                    CardNote(symbol: "exclamationmark.triangle", text: "Invisible or directional characters are shown as ⟨U+XXXX⟩. The original command is unchanged.", tint: LB.warning)
                }
                if review.text.truncated {
                    Button(expanded ? "Collapse command" : "Show full command") {
                        expandedReview = expanded ? nil : review.identity
                    }.buttonStyle(.pill(.secondary, compact: true))
                    if !expanded {
                        Text("Review the full command before allowing it.").cardMeta()
                    }
                }
                if review.missingCommand {
                    CardNote(symbol: "exclamationmark.triangle", text: "The full command is unavailable. Deny this request and ask the Bot to make a new one.", tint: LB.warning)
                }
            } else {
                CardHeader(symbol: "checkmark.shield", title: accessRequest ? proposal.title : ApprovalTextPresentation.isolated(review.text.text))
                if !accessRequest && review.text.hasControls {
                    LabelChip(text: "Escaped controls", tint: LB.warning)
                }
            }
            if accessRequest {
                Text(proposal.description).font(LBFont.rowSubtitle).foregroundStyle(.secondary)
                if let reason = AccessRequestPresentation.reason(proposal, botName: store.bots.first(where: { $0.id == proposal.botId })?.name ?? "Bot") {
                    Text(verbatim: reason).font(LBFont.body).textSelection(.enabled)
                }
            } else {
                approvalDetailText("\(proposal.target) on \(proposal.scope.machineLabel)", accessRequest: false).font(LBFont.rowSubtitle).foregroundStyle(.secondary)
            }
            CardDetails {
                approvalDetailText(proposal.title, accessRequest: accessRequest)
                approvalDetailText(proposal.description, accessRequest: accessRequest)
                approvalDetailText("Scope: \(proposal.scope.label)", accessRequest: accessRequest)
                approvalDetailText("Bot: \(store.bots.first(where: { $0.id == proposal.botId })?.name ?? proposal.botId)", accessRequest: accessRequest)
                ForEach(proposal.scope.consequences, id: \.self) { consequence in approvalDetailText(consequence, accessRequest: accessRequest) }
                GateStatusView(store: store, gate: proposal.gate, details: false)
                if accessRequest {
                    HStack(spacing: 6) { StatusBadge(text: proposal.category); StatusBadge(text: proposal.scope.kind) }
                } else {
                    approvalDetailText("Category: \(proposal.category)", accessRequest: false)
                    approvalDetailText("Scope kind: \(proposal.scope.kind)", accessRequest: false)
                }
                if let origin = proposal.scope.origin { approvalDetailText("Origin: \(origin)", accessRequest: accessRequest) }
                if let connector = proposal.scope.connectorId { approvalDetailText("Connector: \(connector)", accessRequest: accessRequest) }
                if let run = proposal.scope.runId { approvalDetailText("Run: \(run)", accessRequest: accessRequest) }
                Text("Review scope expires \(timestamp(Double(proposal.scope.expiresAtMs)).formatted())")
                ForEach(Array(proposal.inputs.keys.sorted()), id: \.self) { key in
                    approvalDetailText("\(key): \(inputSummary(proposal.inputs[key]!))", accessRequest: accessRequest)
                        .font(.system(.body, design: .monospaced))
                }
                approvalDetailText("Review: \(humanizedStatus(proposal.review)) · Policy: \(humanizedStatus(proposal.policyMode))", accessRequest: accessRequest)
                if let rule = proposal.ruleId { approvalDetailText("Rule: \(rule)", accessRequest: accessRequest) }
                Button("Copy support details") { copyText("Connector: \(proposal.scope.connectorId ?? "Not set")\nRun: \(proposal.scope.runId ?? "Not set")\nRule: \(proposal.ruleId ?? "Not set")") }.buttonStyle(.pill(.quiet, compact: true))
                if accessRequest {
                    GateDetailLines(store: store, gate: proposal.gate)
                } else {
                    approvalDetailText("Target user: \(proposal.gate.targetUserId == store.user?.id ? "You" : proposal.gate.targetUserId)", accessRequest: false)
                    Text("Expires \(timestamp(Double(proposal.gate.expiresAtMs)).formatted())")
                    Text("Revision \(proposal.gate.revision)")
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let expired = proposal.gate.state == "pending" && Double(proposal.gate.expiresAtMs) <= Date().timeIntervalSince1970 * 1000
                if proposal.gate.state == "pending" && !expired {
                    HStack(spacing: 8) {
                        Button(accessRequest ? AccessRequestPresentation.allowLabel : "Allow once") { Task { await resolve("approve_once", reviewed: review.identity) } }.buttonStyle(.cardPrimary).disabled(!canApprove)
                        if !accessRequest, let option = proposal.chatOption {
                            Button(option.label) { Task { await resolve("approve_chat", reviewed: review.identity) } }.buttonStyle(.pill(.secondary)).disabled(!canApprove)
                        }
                        if !accessRequest, proposal.chatOption != nil,
                           let bot = store.bots.first(where: { $0.id == proposal.botId }),
                           bot.ownerUserId == store.user?.id,
                           rememberedPolicy?.rememberedApprovals?.bot.isEmpty == false {
                            Menu {
                                Button("Always allow for this Bot…") { botWideReview = review.identity; botWide = true }
                            } label: { Image(systemName: "ellipsis") }
                            .disabled(!canApprove)
                        }
                        Button(accessRequest ? AccessRequestPresentation.denyLabel : "Deny", role: accessRequest ? nil : .destructive) { Task { await resolve("deny", reviewed: review.identity) } }.buttonStyle(.pill(.secondary))
                    }.disabled(action.busy || !gateAllowsAction(store, proposal.gate) || Double(proposal.scope.expiresAtMs) <= Date().timeIntervalSince1970 * 1000)
                } else {
                    let state = expired ? "expired" : proposal.gate.state
                    let who = proposal.gate.resolvedByUserId == store.user?.id ? "you" : proposal.gate.resolvedByUserId == nil ? "policy" : "another person"
                    let result = accessRequest ? AccessRequestPresentation.result(state: state, who: who) : state == "approved" ? "\(proposal.resolvedScope == "chat" ? "Allowed for this chat" : "Allowed once") by \(who)" : state == "denied" ? "Denied by \(who)" : humanizedStatus(state)
                    let time = proposal.gate.resolvedAtMs.map { " · " + timestamp(Double($0)).formatted(date: .omitted, time: .shortened) } ?? ""
                    Text(result + (accessRequest || state == "expired" ? "" : time)).font(LBFont.rowSubtitle)
                }
            }
            ActionErrorView(message: action.error)
        }
        .onChange(of: review.identity) { _, _ in
            expandedReview = nil
            botWideReview = nil
            botWide = false
        }
        .task(id: approval.botId) {
            guard approval.source != "access_request" else { return }
            do { rememberedPolicy = try await store.read("/policies/effective", query: ["botId": approval.botId]) }
            catch { action.error = error.localizedDescription }
        }
        .sheet(isPresented: $botWide) {
            if canApprove, botWideReview == review.identity,
               let bot = store.bots.first(where: { $0.id == proposal.botId }) {
                BotApprovalsView(store: store, bot: bot, previewOnOpen: true, afterConfirm: {
                    await resolve("approve_once", reviewed: review.identity)
                    botWide = false
                }).padding()
            }
        }
    }
    private func commandText(_ value: String) -> some View {
        Text(verbatim: ApprovalTextPresentation.isolated(value))
            .font(.system(.headline, design: .monospaced))
            .lineLimit(nil).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            .environment(\.layoutDirection, .leftToRight)
    }
    private func resolve(_ decision: String, reviewed: ApprovalReviewPresentation.Identity) async {
        let proposal = current
        let review = ApprovalReviewPresentation(proposal)
        guard decision == "deny" || (reviewed == review.identity && review.allowsApproval(expanded: expandedReview)) else { return }
        await action.perform {
            resolved = try await store.mutate("POST", resourcePath("approvals", proposal.id, "/resolve"), body: ["revision": .number(Double(proposal.revision)), "decision": .string(decision)])
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
                if let minimum = field.min { Text("At least \(minimum.formatted())").cardMeta() }
                if let maximum = field.max { Text("Up to \(maximum.formatted())").cardMeta() }
                if !(numberText[field.id] ?? "").isEmpty && answers[field.id] == nil { Text("Enter a number.").font(LBFont.meta).foregroundStyle(LB.danger) }
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
            CardNote(symbol: "lock.shield", text: "Stored for the destination only. Other Bots on this machine and the machine owner can read it. It's never saved in chat.", tint: LB.warning)
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
                    NavigationLink { MachineTerminalView(store: store, machineID: current.machineId) } label: { Text("Open terminal (full access)") }.buttonStyle(.pill(.secondary, compact: true))
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
