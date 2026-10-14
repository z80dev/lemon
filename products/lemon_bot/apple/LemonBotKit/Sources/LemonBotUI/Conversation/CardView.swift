import SwiftUI
import LemonBotKit

struct TranscriptCardView: View {
    let store: LemonBotStore
    let card: Card
    init(store: LemonBotStore, card: Card) { self.store = store; self.card = card }
    @Environment(\.openURL) private var openURL
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let target = privateTarget, target != store.user?.id {
                Text("This private request is unavailable to this account. No action was authorized.")
            } else {
            switch card {
            case .text(let value): Text(.init(value.text)).textSelection(.enabled)
            case .attachment(let value):
                Text(value.caption)
                AttachmentView(store: store, attachmentID: value.attachmentId)
            case .link(let value):
                Text(value.title).font(.headline)
                Text(value.description)
                if let url = safeExternalURL(value.url) { Button("Open source · \(url.host ?? value.url)") { openURL(url) }; Text(url.absoluteString).font(.caption).textSelection(.enabled) }
                else { Text("Unsafe or unsupported link; not opened.").foregroundStyle(.orange) }
            case .widget(let value):
                Text(value.prompt)
                WidgetAnswerView(store: store, questionID: value.questionId)
            case .secretRequest(let value): SecretRequestView(store: store, request: value.request)
            case .humanStep(let value): HumanStepView(store: store, step: value.step)
            case .userForm(let value): QuestionAnswerView(store: store, question: value.question)
            case .emailDraft(let value): DraftReviewView(store: store, draft: value.draft)
            case .slackDraft(let value): DraftReviewView(store: store, draft: value.draft)
            case .messageDraft(let value): DraftReviewView(store: store, draft: value.draft)
            case .calendarEvent(let value):
                Text(value.event.subject).font(.headline)
                StatusBadge(text: value.event.status)
                Text("\(zonedTimestamp(Double(value.event.startAtMs), timezone: value.event.timezone)) – \(zonedTimestamp(Double(value.event.endAtMs), timezone: value.event.timezone)) · \(value.event.timezone)")
                if value.event.allDay { Text("All day") }
                Text("Guests: \(value.event.guests.joined(separator: ", "))")
                Text(value.event.location)
                if let source = value.event.sourceUrl, let url = safeExternalURL(source) { Button("Open source · \(url.host ?? source)") { openURL(url) } }
                Text("Calendar preview only; no calendar change was authorized by opening this card.").font(.caption)
            case .permissionRequest(let value): ApprovalReviewView(store: store, approval: value.approval)
            case .autoReviewApproval(let value): ApprovalReviewView(store: store, approval: value.approval)
            case .localToolPermission(let value): ApprovalReviewView(store: store, approval: value.approval)
            case .publishApproval(let value): ApprovalReviewView(store: store, approval: value.approval)
            case .connector(let value): ConnectorCardView(store: store, connector: value.connector)
            case .connectors(let value): ForEach(value.connectors) { connector in ConnectorCardView(store: store, connector: connector) }
            case .listenerConnect(let value): channel(value.channelBinding)
            case .slackConnect(let value): channel(value.channelBinding)
            case .scmConnect(let value):
                Label(value.provider, systemImage: "point.3.connected.trianglepath.dotted")
                Text(value.reason)
                ConnectorLookupView(store: store, connectorID: value.connectorId)
            case .teamAccess(let value): TeamAccessCardView(store: store, botID: value.botId, ownerID: value.ownerUserId, reason: value.reason, state: value.state)
            case .botTemplateShare(let value): TemplateShareCardView(store: store, templateID: value.templateId, name: value.name, shareURL: value.shareUrl, state: value.state)
            case .connectorGrant(let value): ConnectorConsentView(store: store, consent: value.consent)
            case .voiceMemo(let value): VoiceMemoView(store: store, attachmentID: value.attachmentId, transcript: value.transcript, durationMs: Double(value.durationMs), peaks: value.peaks.map(Double.init))
            case .handoff(let value):
                Label("Handoff to \(store.bots.first(where: { $0.id == value.targetBotId })?.name ?? value.targetBotId)", systemImage: "arrow.triangle.branch")
                Text(value.text)
                StatusBadge(text: value.state)
                NavigationLink("Open authorized task") { ConversationView(store: store, conversationID: value.targetConversationId) }
            case .unsupported(let value):
                Text("Message type \(value.type) requires a newer Lemon Bot client. No action was authorized.").foregroundStyle(.orange)
                if let text = value.text { Text(text).textSelection(.enabled) }
                if let id = value.attachmentId { AttachmentView(store: store, attachmentID: id) }
            }
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
    private var privateTarget: ID? {
        switch card {
        case .secretRequest(let value): return value.request.gate.targetUserId
        case .humanStep(let value): return value.step.gate.targetUserId
        case .permissionRequest(let value): return value.approval.gate.targetUserId
        case .autoReviewApproval(let value): return value.approval.gate.targetUserId
        case .localToolPermission(let value): return value.approval.gate.targetUserId
        case .publishApproval(let value): return value.approval.gate.targetUserId
        case .connectorGrant(let value): return value.consent.accountOwnerUserId
        case .emailDraft(let value): return value.draft.ownerUserId
        case .slackDraft(let value): return value.draft.ownerUserId
        case .messageDraft(let value): return value.draft.ownerUserId
        default: return nil
        }
    }
    private func channel(_ binding: ChannelBinding) -> some View {
        VStack(alignment: .leading) {
            Label("\(binding.adapter.capitalized) · \(binding.accountId)", systemImage: "link")
            Text("Target: \(binding.target)")
            StatusBadge(text: binding.state)
            Text(binding.enabled ? "Enabled" : "Disabled")
            Text("Events: \(binding.capabilities.events.joined(separator: ", ")) · inbound \(binding.capabilities.inbound ? "yes" : "no") · outbound \(binding.capabilities.outbound ? "yes" : "no")").font(.caption)
            ActionErrorView(message: binding.lastError)
            NavigationLink("Configure channel / check real setup") { IntegrationsHubView(store: store) }
            Text("Channel setup and posting-account consent are separate.").font(.caption)
        }
    }
}

struct ConnectorLookupView: View {
    let store: LemonBotStore
    let connectorID: ID
    init(store: LemonBotStore, connectorID: ID) { self.store = store; self.connectorID = connectorID }
    @State private var connector: Connector?
    @State private var action = UIActionState()
    var body: some View {
        VStack { if let connector { ConnectorCardView(store: store, connector: connector) }; ActionErrorView(message: action.error) }
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
    private var mayManage: Bool { current.ownerUserId == store.user?.id || (current.shared && store.bots.contains { $0.id == current.botId && ($0.ownerUserId == store.user?.id || $0.managerUserIds.contains(store.user?.id ?? "")) }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(current.name) · \(current.accountLabel)").font(.headline)
            Text("Server: \(URL(string: current.url)?.host ?? current.url)").font(.caption)
            StatusBadge(text: current.state)
            Text(current.shared ? "Deliberately shared service account" : "Personal account · consent required for another Bot")
            ActionErrorView(message: current.lastError)
            NavigationLink("Configure apps, tools and accounts") { IntegrationsHubView(store: store) }
            if mayManage {
                HStack {
                    Button(current.state == "connected" ? "Reauthenticate" : "Authenticate / reconnect") { Task { await authenticate() } }
                    if let auth, let url = safeExternalURL(auth.authorizationUrl), Double(auth.expiresAtMs) > Date().timeIntervalSince1970 * 1000 {
                        Button("Open authorization") { openURL(url) }
                        Button("Check authorization") { Task { await checkAuth() } }
                    }
                    Button("Disconnect", role: .destructive) { Task { await preview() } }
                }.disabled(action.busy || store.connectionState != "online")
            }
            if let auth { Text("Authorization: \(auth.state)").font(.caption) }
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
struct TeamAccessCardView: View {
    let store: LemonBotStore
    let botID: ID
    let ownerID: ID
    let reason: String
    let state: String
    init(store: LemonBotStore, botID: ID, ownerID: ID, reason: String, state: String) {
        self.store = store; self.botID = botID; self.ownerID = ownerID; self.reason = reason; self.state = state
    }
    @State private var bot: Bot?
    @State private var action = UIActionState()
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Team Bot · owner \(ownerID)").font(.headline)
            Text(reason)
            StatusBadge(text: bot.map { $0.published ? "published" : "unpublished" } ?? state)
            Text("Your new private chat does not import another member's transcript, notes or credentials.").font(.caption)
            if let bot, state != "unavailable" {
                if ownerID == store.user?.id && !bot.published {
                    Button("Publish shared Bot") { Task { await action.perform {
                        let result: Bot = try await store.mutate("PATCH", resourcePath("bots", botID), body: ["revision": .number(Double(bot.revision)), "published": .bool(true)])
                        self.bot = result
                    } } }.disabled(action.busy || store.connectionState != "online")
                }
                Button("Start my private chat") { Task { await action.perform {
                    let room: Conversation = try await store.mutate("POST", "/conversations", body: ["kind": .string("team_dm"), "botIds": strings([botID])])
                    try await store.openConversation(room.id)
                    store.selectedConversationID = room.id
                } } }.disabled(action.busy || !bot.published || store.connectionState != "online")
            }
            ActionErrorView(message: action.error)
        }.task(id: botID) { await action.perform { bot = try await store.read(resourcePath("bots", botID)) } }
    }
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
            Text(name).font(.headline)
            StatusBadge(text: state)
            if let url = safeExternalURL(shareURL) { Button("Open details link") { openURL(url) }; Button("Copy link") { copyText(shareURL) } }
            if let template {
                Text("Publisher: \(template.provenance.publisher) · \(template.audience)")
                if let source = template.provenance.sourceUrl, let url = safeExternalURL(source) { Link("Source · \(url.host ?? source)", destination: url) }
                if let terms = template.provenance.termsUrl, let url = safeExternalURL(terms) { Link("Read terms", destination: url) }
                DisclosureGroup("Review job and instructions") { Text(template.content.job); Text(template.content.instructions).textSelection(.enabled) }
                ForEach(Array(template.content.skills.enumerated()), id: \.offset) { _, skill in DisclosureGroup("Skill: \(skill.name)") { Text(skill.description); Text(skill.markdown).textSelection(.enabled) } }
                ForEach(Array(template.content.routines.enumerated()), id: \.offset) { _, routine in Text("Paused copy of routine: \(routine.name) · \(routine.instruction)") }
                Text("Connectors needed: \(template.content.connectorNames.joined(separator: ", "))")
                TextField("New Bot name", text: $importName)
                Picker("Assigned machine", selection: $machineID) { Text("Choose online machine").tag(""); ForEach(store.machines.filter { $0.status == "online" }) { machine in Text(machine.name).tag(machine.id) } }
                Toggle("I reviewed the declarative instructions and shared-host credential exposure", isOn: $reviewed)
                if template.provenance.thirdParty { Toggle("I accept the third-party terms", isOn: $acceptedTerms) }
                Button("Import as my separate Bot") { Task { await action.perform {
                    let bot: Bot = try await store.mutate("POST", resourcePath("templates", templateID, "/import"), body: ["name": .string(importName), "machineId": .string(machineID), "acceptedTerms": .bool(acceptedTerms)])
                    try await store.refresh(); store.selectedConversationID = bot.mainConversationId
                } } }.disabled(action.busy || state != "available" || !reviewed || importName.isEmpty || machineID.isEmpty || (template.provenance.thirdParty && !acceptedTerms) || store.connectionState != "online")
                Text("No original history, memory or credentials are copied. Routines start paused.").font(.caption)
            }
            ActionErrorView(message: action.error)
        }.task(id: templateID) {
            guard state == "available" else { return }
            await action.perform { template = try await store.read(resourcePath("templates", templateID)); importName = template?.content.name ?? name }
        }
    }
}
