import SwiftUI
import LemonBotKit

// MARK: - Compact card building blocks (shared by CardView, GateViews, DraftReviewView)

/// Small tinted symbol in a 26pt circle, a title, and an optional inline badge.
struct CardHeader<Trailing: View>: View {
    let symbol: String
    let title: String
    var tint: Color = LB.accent
    let trailing: Trailing
    init(symbol: String, title: String, tint: Color = LB.accent, @ViewBuilder trailing: () -> Trailing) {
        self.symbol = symbol; self.title = title; self.tint = tint; self.trailing = trailing()
    }
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 26, height: 26).background(Circle().fill(tint.opacity(0.14))).accessibilityHidden(true)
            Text(title).font(LBFont.bodyEmphasis).foregroundStyle(LB.ink).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            trailing
            Spacer(minLength: 0)
        }
    }
}
extension CardHeader where Trailing == EmptyView {
    init(symbol: String, title: String, tint: Color = LB.accent) { self.init(symbol: symbol, title: title, tint: tint) { EmptyView() } }
}

/// One muted meta line with a small leading icon (warnings, notes).
struct CardNote: View {
    let symbol: String
    let text: String
    var tint: Color = LB.muted
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint).accessibilityHidden(true)
            Text(text).font(LBFont.meta).foregroundStyle(LB.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Details" disclosure for technical information; collapsed by default.
struct CardDetails<Content: View>: View {
    var title = "Details"
    @ViewBuilder var content: Content
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) { content }
                .font(LBFont.meta).foregroundStyle(LB.muted)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
        } label: { Text(title).font(LBFont.metaEmphasis).foregroundStyle(LB.muted) }
    }
}

/// Key + value fact line: muted key, ink value.
func cardFact(_ key: String, _ value: String) -> Text {
    Text(key + "  ").foregroundStyle(LB.muted) + Text(value).foregroundStyle(LB.ink)
}

extension View {
    /// Muted 12pt meta text.
    func cardMeta() -> some View { font(LBFont.meta).foregroundStyle(LB.muted) }
    /// Compact rounded plain text field on a soft fill.
    func cardField() -> some View {
        textFieldStyle(.plain).font(LBFont.rowSubtitle)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(LB.fill))
    }
    /// Checkbox on macOS, switch on iOS, at meta size.
    func cardToggle() -> some View {
        #if os(macOS)
        toggleStyle(.checkbox).font(LBFont.rowSubtitle)
        #else
        font(LBFont.rowSubtitle)
        #endif
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    /// Primary card action: olive pill with legible text in light and dark.
    static var cardPrimary: PillButtonStyle { PillButtonStyle(kind: .primary(LB.accent, Color(light: 0xFFFFFF, dark: 0x14201A))) }
}

/// `…` overflow menu for secondary card actions.
struct CardMoreMenu<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        Menu { content } label: {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(LB.ink)
                .frame(width: 28, height: 28).background(Circle().fill(LB.fill)).contentShape(Circle())
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("More actions")
    }
}

/// Soft dropdown field (replaces the grey bezel popup).
struct CardChoice: View {
    let placeholder: String
    @Binding var selection: String
    let options: [(value: String, label: String)]
    var body: some View {
        Menu {
            Button(placeholder) { selection = "" }
            ForEach(options, id: \.value) { option in Button(option.label) { selection = option.value } }
        } label: {
            HStack(spacing: 6) {
                Text(options.first(where: { $0.value == selection })?.label ?? placeholder).lineLimit(1)
                    .foregroundStyle(selection.isEmpty ? LB.muted : LB.ink)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(LB.muted)
            }.font(LBFont.rowSubtitle).padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(LB.fill)).contentShape(Rectangle())
        }.menuStyle(.borderlessButton).menuIndicator(.hidden)
    }
}

/// Wrapping row of action pills.
struct CardActions: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth { y += rowHeight + spacing; x = 0; rowHeight = 0 }
            x += size.width + spacing; rowHeight = max(rowHeight, size.height); width = max(width, x - spacing)
        }
        return CGSize(width: width, height: y + rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > bounds.width { y += rowHeight + spacing; x = 0; rowHeight = 0 }
            subview.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Transcript card

struct TranscriptCardView: View {
    let store: LemonBotStore
    let card: Card
    init(store: LemonBotStore, card: Card) { self.store = store; self.card = card }
    @Environment(\.openURL) private var openURL
    var body: some View {
        Group {
            if isBare {
                VStack(alignment: .leading, spacing: 6) { content }
            } else {
                SoftCard { content }
            }
        }.frame(maxWidth: LBMetric.bubbleMaxWidth, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
    }
    /// Attachment cards render chromeless (thumbnail or file pill) with no surrounding card.
    private var isBare: Bool {
        if privateTarget != nil, privateTarget != store.user?.id { return false }
        if case .attachment = card { return true }
        return false
    }
    @ViewBuilder private var content: some View {
        if let target = privateTarget, target != store.user?.id {
            CardNote(symbol: "lock", text: "This private request is unavailable to this account. No action was authorized.")
        } else {
            switch card {
            case .text(let value): Text(.init(value.text)).font(LBFont.body).lineSpacing(LBFont.bodyLineSpacing).foregroundStyle(LB.ink).textSelection(.enabled)
            case .attachment(let value):
                if !value.caption.isEmpty { Text(value.caption).font(LBFont.body).foregroundStyle(LB.ink) }
                AttachmentView(store: store, attachmentID: value.attachmentId)
            case .link(let value):
                CardHeader(symbol: "link", title: value.title)
                if !value.description.isEmpty { Text(value.description).font(LBFont.body).foregroundStyle(LB.ink) }
                if let url = safeExternalURL(value.url) {
                    Button { openURL(url) } label: { Label(url.host ?? value.url, systemImage: "arrow.up.right") }
                        .buttonStyle(.pill(.secondary, compact: true)).accessibilityLabel("Open source \(url.host ?? value.url)").help(url.absoluteString)
                    Text(url.absoluteString).cardMeta().lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                } else { CardNote(symbol: "exclamationmark.triangle", text: "Unsafe or unsupported link; not opened.", tint: LB.warning) }
            case .widget(let value):
                Text(value.prompt).font(LBFont.body).foregroundStyle(LB.ink)
                WidgetAnswerView(store: store, questionID: value.questionId)
            case .secretRequest(let value): SecretRequestView(store: store, request: value.request)
            case .humanStep(let value): HumanStepView(store: store, step: value.step)
            case .userForm(let value): QuestionAnswerView(store: store, question: value.question)
            case .emailDraft(let value): DraftReviewView(store: store, draft: value.draft)
            case .slackDraft(let value): DraftReviewView(store: store, draft: value.draft)
            case .messageDraft(let value): DraftReviewView(store: store, draft: value.draft)
            case .calendarEvent(let value): calendar(value.event)
            case .permissionRequest(let value): ApprovalReviewView(store: store, approval: value.approval)
            case .autoReviewApproval(let value): ApprovalReviewView(store: store, approval: value.approval)
            case .localToolPermission(let value): ApprovalReviewView(store: store, approval: value.approval)
            case .publishApproval(let value): ApprovalReviewView(store: store, approval: value.approval)
            case .connector(let value): ConnectorCardView(store: store, connector: value.connector)
            case .connectors(let value):
                VStack(alignment: .leading, spacing: 18) { ForEach(value.connectors) { connector in ConnectorCardView(store: store, connector: connector) } }
            case .listenerConnect(let value): channel(value.channelBinding)
            case .slackConnect(let value): channel(value.channelBinding)
            case .scmConnect(let value):
                CardHeader(symbol: "point.3.connected.trianglepath.dotted", title: value.provider)
                Text(value.reason).font(LBFont.body).foregroundStyle(LB.ink)
                ConnectorLookupView(store: store, connectorID: value.connectorId)
            case .botTemplateShare(let value): TemplateShareCardView(store: store, templateID: value.templateId, name: value.name, shareURL: value.shareUrl, state: value.state)
            case .voiceMemo(let value): VoiceMemoView(store: store, attachmentID: value.attachmentId, transcript: value.transcript, durationMs: Double(value.durationMs), peaks: value.peaks)
            case .handoff(let value):
                CardHeader(symbol: "arrow.triangle.branch", title: "Handoff to \(store.bots.first(where: { $0.id == value.targetBotId })?.name ?? value.targetBotId)") { StatusBadge(text: value.state) }
                Text(value.text).font(LBFont.body).foregroundStyle(LB.ink)
                NavigationLink { ConversationView(store: store, conversationID: value.targetConversationId) } label: { Text("Open task") }
                    .buttonStyle(.cardPrimary).accessibilityLabel("Open authorized task").help("Open authorized task")
            case .unsupported(let value):
                CardNote(symbol: "exclamationmark.triangle", text: "Message type \(value.type) requires a newer Lemon Bot client. No action was authorized.", tint: LB.warning)
                if let text = value.text { Text(text).font(LBFont.body).foregroundStyle(LB.ink).textSelection(.enabled) }
                if let id = value.attachmentId { AttachmentView(store: store, attachmentID: id) }
            }
        }
    }
    private var privateTarget: ID? {
        switch card {
        case .secretRequest(let value): return value.request.gate.targetUserId
        case .humanStep(let value): return value.step.gate.targetUserId
        case .permissionRequest(let value): return value.approval.gate.targetUserId
        case .autoReviewApproval(let value): return value.approval.gate.targetUserId
        case .localToolPermission(let value): return value.approval.gate.targetUserId
        case .publishApproval(let value): return value.approval.gate.targetUserId
        case .emailDraft(let value): return value.draft.ownerUserId
        case .slackDraft(let value): return value.draft.ownerUserId
        case .messageDraft(let value): return value.draft.ownerUserId
        default: return nil
        }
    }
    @ViewBuilder private func calendar(_ event: CalendarEvent) -> some View {
        let when = calendarWhen(event)
        CardHeader(symbol: "calendar", title: event.subject) { StatusBadge(text: event.status) }
        VStack(alignment: .leading, spacing: 1) {
            Text(when.day).font(LBFont.body).foregroundStyle(LB.ink)
            if !when.time.isEmpty { Text(when.time).font(LBFont.rowSubtitle).foregroundStyle(LB.muted) }
        }
        if !event.guests.isEmpty { Label(event.guests.joined(separator: ", "), systemImage: "person.2").labelStyle(CardMetaLabelStyle()).accessibilityLabel("Guests: \(event.guests.joined(separator: ", "))") }
        if !event.location.isEmpty { Label(event.location, systemImage: "mappin.and.ellipse").labelStyle(CardMetaLabelStyle()).accessibilityLabel("Location: \(event.location)") }
        if let source = event.sourceUrl, let url = safeExternalURL(source) {
            Button { openURL(url) } label: { Label(url.host ?? source, systemImage: "arrow.up.right") }
                .buttonStyle(.pill(.secondary, compact: true)).accessibilityLabel("Open source \(url.host ?? source)").help(url.absoluteString)
        }
        CardNote(symbol: "info.circle", text: "Preview only. Opening this card authorizes no calendar change.")
    }
    private func channel(_ binding: ChannelBinding) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(symbol: "link", title: "\(binding.adapter.capitalized) · \(binding.accountId)") {
                StatusBadge(text: binding.state)
                if !binding.enabled { LabelChip(text: "Disabled") }
            }
            Text("Target \(binding.target)").cardMeta().textSelection(.enabled)
            Text("Events: \(binding.capabilities.events.joined(separator: ", ")) · inbound \(binding.capabilities.inbound ? "yes" : "no") · outbound \(binding.capabilities.outbound ? "yes" : "no")").cardMeta()
            ActionErrorView(message: binding.lastError)
            NavigationLink { IntegrationsHubView(store: store) } label: { Text("Set up channel") }
                .buttonStyle(.cardPrimary).accessibilityLabel("Configure channel and check real setup")
                .help("Configure channel and check real setup. Channel setup and posting-account consent are separate.")
        }
    }
}

private struct CardMetaLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.font(.system(size: 11)).foregroundStyle(LB.faint).frame(width: 14)
            configuration.title.font(LBFont.rowSubtitle).foregroundStyle(LB.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Two tidy lines for a calendar card: the day, then the time range and zone.
private func calendarWhen(_ event: CalendarEvent) -> (day: String, time: String) {
    guard let zone = TimeZone(identifier: event.timezone) else { return (zonedTimestamp(Double(event.startAtMs), timezone: event.timezone), "") }
    let start = timestamp(Double(event.startAtMs)), end = timestamp(Double(event.endAtMs))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let sameDay = calendar.isDate(start, inSameDayAs: end)
    let day = Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: zone)
    let time = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone)
    let both = Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: zone)
    if event.allDay { return (sameDay ? start.formatted(day) : "\(start.formatted(day)) – \(end.formatted(day))", "All day · \(event.timezone)") }
    if sameDay { return (start.formatted(day), "\(start.formatted(time)) – \(end.formatted(time)) · \(event.timezone)") }
    return (start.formatted(both), "until \(end.formatted(both)) · \(event.timezone)")
}

struct ConnectorLookupView: View {
    let store: LemonBotStore
    let connectorID: ID
    init(store: LemonBotStore, connectorID: ID) { self.store = store; self.connectorID = connectorID }
    @State private var connector: Connector?
    @State private var action = UIActionState()
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { if let connector { ConnectorCardView(store: store, connector: connector) }; ActionErrorView(message: action.error) }
            .task(id: "\(connectorID):\(store.eventVersion)") { await action.perform { connector = try await visibleConnector(store, connectorID) } }
    }
}
struct ConnectorCardView: View {
    let store: LemonBotStore
    let connector: Connector
    init(store: LemonBotStore, connector: Connector) { self.store = store; self.connector = connector }
    @Environment(\.openURL) private var openURL
    @State private var auth: ConnectorAuth?
    @State private var refreshed: Connector?
    @State private var confirmation: Confirmation?
    @State private var action = UIActionState()
    private var current: Connector { (refreshed?.revision ?? 0) > connector.revision ? refreshed! : connector }
    private var mayManage: Bool { current.ownerUserId == store.user?.id }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(symbol: "puzzlepiece.extension", title: "\(current.name) · \(current.accountLabel)") { StatusBadge(text: current.state) }
            Text("Server \(URL(string: current.url)?.host ?? current.url) · Your account").cardMeta()
                .help("Your account · requested tool access is separate from approval to act")
            ActionErrorView(message: current.lastError)
            CardActions {
                if mayManage {
                    Group {
                        Button(current.state == "connected" ? "Reauthenticate" : "Connect") { Task { await authenticate() } }.buttonStyle(.cardPrimary)
                            .help("Authenticate / reconnect")
                        if let auth, let url = safeExternalURL(auth.authorizationUrl), Double(auth.expiresAtMs) > Date().timeIntervalSince1970 * 1000 {
                            Button("Open authorization") { openURL(url) }.buttonStyle(.pill(.secondary))
                            Button("Check authorization") { Task { await checkAuth() } }.buttonStyle(.pill(.secondary))
                        }
                        CardMoreMenu { Button("Disconnect", role: .destructive) { Task { await preview() } } }
                    }.disabled(action.busy || store.connectionState != "online")
                }
                NavigationLink { IntegrationsHubView(store: store) } label: { Text("Configure") }
                    .buttonStyle(.pill(.quiet)).accessibilityLabel("Configure apps, tools and accounts").help("Configure apps, tools and accounts")
            }
            if let auth { Text("Authorization: \(humanizedStatus(auth.state))").cardMeta() }
            ActionErrorView(message: action.error)
        }.sheet(isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
            if let confirmation { ScopeConfirmationView(store: store, confirmation: confirmation, title: "Disconnect connector") { body in
                let _: Deleted = try await store.mutate("DELETE", resourcePath("connectors", current.id), body: body)
            } }
        }
    }
    private func authenticate() async { await action.perform { auth = try await store.mutate("POST", resourcePath("connectors", current.id, "/auth"), body: [:]) } }
    private func checkAuth() async {
        await action.perform {
            guard let auth else { return }
            self.auth = try await store.read(resourcePath("connector-auth", auth.id))
            // Connector list is the authoritative source; auth pending never means connected.
            refreshed = try await visibleConnector(store, current.id, botID: current.botId)
        }
    }
    private func preview() async { await action.perform { confirmation = try await store.mutate("POST", resourcePath("connectors", current.id, "/preview"), body: ["action": .string("disconnect")]) } }
}
struct TemplateShareCardView: View {
    let store: LemonBotStore
    let templateID: ID
    let name: String
    let shareURL: String
    let state: String
    init(store: LemonBotStore, templateID: ID, name: String, shareURL: String, state: String) {
        self.store = store; self.templateID = templateID; self.name = name; self.shareURL = shareURL; self.state = state
    }
    @Environment(\.openURL) private var openURL
    @State private var template: BotTemplate?
    @State private var importName = ""
    @State private var machineID = ""
    @State private var reviewed = false
    @State private var acceptedTerms = false
    @State private var action = UIActionState()
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(symbol: "square.on.square", title: name) { StatusBadge(text: state) }
            if let template {
                Text("Publisher \(template.provenance.publisher) · \(template.audience)").cardMeta()
                CardDetails(title: "Review job and instructions") {
                    Text(template.content.job).foregroundStyle(LB.ink)
                    Text(template.content.instructions).textSelection(.enabled)
                }
                ForEach(Array(template.content.skills.enumerated()), id: \.offset) { _, skill in
                    CardDetails(title: "Skill: \(skill.name)") { Text(skill.description).foregroundStyle(LB.ink); Text(skill.markdown).textSelection(.enabled) }
                }
                ForEach(Array(template.content.routines.enumerated()), id: \.offset) { _, routine in Text("Paused copy of routine: \(routine.name) · \(routine.instruction)").cardMeta() }
                Text("Connectors needed: \(template.content.connectorNames.joined(separator: ", "))").cardMeta()
                TextField("New Bot name", text: $importName).cardField()
                CardChoice(placeholder: "Choose online machine", selection: $machineID, options: store.machines.filter { $0.status == "online" }.map { (value: $0.id, label: $0.name) })
                Toggle("I reviewed the declarative instructions and shared-host credential exposure", isOn: $reviewed).cardToggle()
                if template.provenance.thirdParty { Toggle("I accept the third-party terms", isOn: $acceptedTerms).cardToggle() }
            }
            CardActions {
                if template != nil {
                    Button("Import as my separate Bot") { Task { await action.perform {
                        let bot: Bot = try await store.mutate("POST", resourcePath("templates", templateID, "/import"), body: ["name": .string(importName), "machineId": .string(machineID), "acceptedTerms": .bool(acceptedTerms)])
                        try await store.refresh(); store.selectedConversationID = bot.mainConversationId
                    } } }.buttonStyle(.cardPrimary)
                        .disabled(action.busy || state != "available" || !reviewed || importName.isEmpty || machineID.isEmpty || (template?.provenance.thirdParty == true && !acceptedTerms) || store.connectionState != "online")
                }
                if let url = safeExternalURL(shareURL) {
                    Button("Open details") { openURL(url) }.buttonStyle(.pill(.secondary)).help(url.absoluteString)
                    CardMoreMenu { Button("Copy link") { copyText(shareURL) } }
                }
            }
            if let template {
                if let source = template.provenance.sourceUrl, let url = safeExternalURL(source) { Link("Source · \(url.host ?? source)", destination: url).font(LBFont.meta).foregroundStyle(LB.accent) }
                if let terms = template.provenance.termsUrl, let url = safeExternalURL(terms) { Link("Read terms", destination: url).font(LBFont.meta).foregroundStyle(LB.accent) }
                CardNote(symbol: "info.circle", text: "No original history, memory or credentials are copied. Routines start paused.")
            }
            ActionErrorView(message: action.error)
        }.task(id: templateID) {
            guard state == "available" else { return }
            await action.perform { template = try await store.read(resourcePath("templates", templateID)); importName = template?.content.name ?? name }
        }
    }
}
