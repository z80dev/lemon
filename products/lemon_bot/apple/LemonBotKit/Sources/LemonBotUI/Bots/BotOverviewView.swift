import SwiftUI
import LemonBotKit

public struct BotOverviewView: View {
    private let store: LemonBotStore
    private let botID: ID
    @State private var overview: BotOverview?
    @State private var ideas: [BotIdea] = []
    @State private var preferences: [PreferenceChange] = []
    @State private var milestones: [Milestone] = []
    @State private var tab = "overview"
    @State private var action = UIActionState()
    @State private var editor = false
    @State private var lifecycle = false
    @State private var voiceSample: SpeechResult?
    public init(store: LemonBotStore, botID: ID) { self.store = store; self.botID = botID }
    private var bot: Bot? { store.bots.first { $0.id == botID } ?? overview?.bot }
    private var manages: Bool { bot.map { $0.ownerUserId == store.user?.id || $0.managerUserIds.contains(store.user?.id ?? "") } ?? false }
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let bot {
                    BotIdentityAnchor(store: store, bot: bot)
                    Picker("Bot details", selection: $tab) { Text("Overview").tag("overview"); Text("Identity").tag("identity"); Text("Job").tag("job"); Text("Memory").tag("memory"); Text("Preferences").tag("preferences") }.pickerStyle(.segmented)
                    switch tab {
                    case "identity": identity(bot)
                    case "job": BotJobEditorView(store: store, bot: bot)
                    case "memory": NavigationLink("Open scoped memory, private notes and guided import") { MemoryHubView(store: store, botID: bot.id) }
                    case "preferences": preferenceHistory(bot)
                    default: overviewBody(bot)
                    }
                    if manages {
                        HStack {
                            Button("Edit identity / settings") { editor = true }
                            Button("Duplicate, team copy, move, reset or delete…") { lifecycle = true }
                        }
                    }
                    if !manages && bot.visibility == "team" && ["owner", "admin"].contains(store.member?.role ?? "") {
                        Button("Review Team Bot deletion…") { lifecycle = true }
                    }
                    NavigationLink("Connect apps / account consent") { IntegrationsHubView(store: store) }
                    NavigationLink("Skills and routines") { LibraryHubView(store: store) }
                    NavigationLink("Assigned machine") { MachineDetailView(store: store, machineID: bot.machineId) }
                } else if action.inFlight { ProgressView("Loading Bot overview…") }
                ActionErrorView(message: action.error)
                if let receipt = action.receipt { Text(receipt).font(.caption) }
                Button("Reload current facts") { Task { await load() } }.disabled(action.busy)
            }.padding().frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
        }.navigationTitle(bot?.name ?? "Bot overview")
            .task(id: "\(botID):\(store.eventVersion)") { await load() }
            .sheet(isPresented: $editor) { if let bot { BotEditorView(store: store, bot: bot) } }
            .sheet(isPresented: $lifecycle) { if let bot { BotLifecycleView(store: store, bot: bot) } }
    }
    private func identity(_ bot: Bot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(bot.title).font(.title3)
            Text("Owner: \(bot.ownerUserId) · \(bot.visibility) · \(bot.published ? "Published" : "Unpublished")").font(.caption)
            Text("Managers: \(bot.managerUserIds.joined(separator: ", "))").font(.caption)
            Text("Voice: \(bot.voice.voiceId) · speed \(bot.voice.speed) · language \(bot.voice.language ?? "auto")")
            Text("Reply language: \(bot.language ?? "automatic")")
            Button("Preview real voice sample") { Task { await action.perform { voiceSample = try await store.mutate("POST", resourcePath("bots", bot.id, "/voice/preview"), body: [:]) } } }.disabled(action.busy || store.connectionState != "online")
            if let voiceSample { VoiceMemoView(store: store, attachmentID: voiceSample.attachment.id, transcript: "Hello, I’m your Lemon Bot teammate. Ready when you are.", durationMs: voiceSample.attachment.durationMs, peaks: []) }
            Text("Voice preview does not start a run or conversation. Missing provider configuration is shown verbatim above; device speech is a separate platform option.").font(.caption)
            ForEach(bot.referenceAttachmentIds, id: \.self) { id in AttachmentView(store: store, attachmentID: id) }
        }
    }
    private func overviewBody(_ bot: Bot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let overview {
                Text(overview.presence.summary)
                if overview.presence.stale || store.connectionState != "online" { Label("Last measured status is stale or realtime is disconnected; not proof work is still running.", systemImage: "clock.badge.exclamationmark").foregroundStyle(.orange) }
                Text("Machine: \(overview.presence.machineLabel) · \(overview.presence.machineStatus) · measured \(timestamp(Double(overview.presence.measuredAtMs)).formatted())").font(.caption)
                if let task = overview.presence.taskConversationId { NavigationLink("Open current task") { ConversationView(store: store, conversationID: task) } }
                if let run = overview.presence.currentRunId { Text("Current run: \(run)").font(.caption).textSelection(.enabled) }
                if let evidence = overview.presence.evidenceEntryId { Text("Making evidence: \(evidence)").font(.caption).textSelection(.enabled) }
                DisclosureGroup("Bot authorization · distinct from machine permissions") {
                    Text("Effective access is bounded by host configuration, measured OS grants and required policy. A requested level is not proof of authorization.").font(.caption)
                    ForEach(overview.grants) { grant in BotGrantRow(store: store, grant: grant, manages: manages) }
                }
                Text("Recent Activity").font(.headline)
                ForEach(overview.activity.items) { item in
                    VStack(alignment: .leading) {
                        HStack { Text(item.title); StatusBadge(text: item.status) }
                        Text(item.summary)
                        Text("\(item.machineLabel) · \(timestamp(Double(item.occurredAtMs)).formatted())").font(.caption)
                        if let room = item.taskConversationId ?? item.conversationId { NavigationLink("Open exact work context") { ConversationView(store: store, conversationID: room) } }
                    }
                }
                Text("Upcoming").font(.headline)
                ForEach(overview.upcoming.items, id: \.id) { item in
                    VStack(alignment: .leading) { Text(item.title); Text("\(zonedTimestamp(Double(item.dueAtMs), timezone: item.timezone)) · \(item.timezone) · \(item.machineLabel) · \(item.machineStatus)").font(.caption); if let blocked = item.blockedReason { Text(blocked).foregroundStyle(.orange) }; if let outcome = item.lastRunStatus { Text("Last outcome: \(outcome)").font(.caption) } }
                }
                NavigationLink("All Activity and Upcoming") { ActivityHubView(store: store) }
            }
            Text("Ideas · useful outcomes, not automatic work").font(.headline)
            ForEach(ideas, id: \.id) { idea in
                VStack(alignment: .leading, spacing: 5) {
                    Text(idea.title).font(.headline)
                    Text(idea.expectedOutput)
                    Text("Skills: \(idea.requiredSkillIds.joined(separator: ", ")) · apps: \(idea.requiredConnectorIds.joined(separator: ", ")) · capabilities: \(idea.requiredCapabilityIds.joined(separator: ", "))").font(.caption)
                    ForEach(idea.blockedReasons, id: \.self) { reason in Text(reason).foregroundStyle(.orange) }
                    Button("Draft this prompt") { Task { await draftIdea(idea, bot: bot) } }.disabled(action.inFlight)
                }
            }
            ForEach(milestones.filter { $0.acknowledgedAtMs == nil }) { milestone in
                HStack { Label(milestone.kind.replacingOccurrences(of: "_", with: " ").capitalized, systemImage: "checkmark.seal"); Text("Verified evidence: \(milestone.evidenceId)").font(.caption); Button("Acknowledge") { Task { await acknowledge(milestone) } } }
            }
        }
    }
    private func preferenceHistory(_ bot: Bot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(preferences) { change in
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(change.scope.capitalized) · \(change.state)").font(.headline)
                    Text("By \(change.userId) · machine \(change.machineId) · source \(change.sourceEntryId ?? "manual edit")").font(.caption)
                    Text(change.reason)
                    PreferencePatchView(title: "Before", patch: change.before)
                    PreferencePatchView(title: "After", patch: change.after)
                    if manages && change.state == "applied" {
                        Button("Undo this exact change") { Task { await action.perform {
                            let current: Bot = try await store.read(resourcePath("bots", botID))
                            let _: PreferenceChange = try await store.mutate("POST", resourcePath("preference-changes", change.id, "/undo"), body: ["revision": .number(Double(change.revision)), "botRevision": .number(Double(current.revision))])
                            try await store.refresh(); try await loadResources()
                        } } }.disabled(action.busy || store.connectionState != "online")
                    }
                }.padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
            Text("Undo rejects conflicting later edits; it never silently overwrites them.").font(.caption)
        }
    }
    private func draftIdea(_ idea: BotIdea, bot: Bot) async {
        await action.perform {
            let roomID: ID
            if bot.visibility == "team" {
                if let existing = store.conversations.first(where: { $0.kind == "team_dm" && $0.ownerUserId == store.user?.id && $0.botIds == [bot.id] }) {
                    roomID = existing.id
                } else {
                    guard store.connectionState == "online" else { throw ClientError.offline }
                    let room: Conversation = try await store.mutate("POST", "/conversations", body: ["kind": .string("team_dm"), "botIds": strings([bot.id])])
                    roomID = room.id
                }
            } else { roomID = bot.mainConversationId }
            let draft = store.draft(for: roomID)
            guard store.setLocalDraft(conversationID: roomID, text: draft.text.isEmpty ? idea.prompt : draft.text + "\n\n" + idea.prompt, attachmentIDs: draft.attachmentIDs, replyTo: draft.replyToEntryID) else { throw ClientError.invalidBinary }
            var references = draft.references
            for id in idea.requiredSkillIds where !references.contains(where: { $0.kind == "skill" && $0.id == id }) { references.append(Reference(kind: "skill", id: id)) }
            for id in idea.requiredConnectorIds where !references.contains(where: { $0.kind == "connector" && $0.id == id }) { references.append(Reference(kind: "connector", id: id)) }
            store.setLocalComposerRouting(conversationID: roomID, references: references, mentions: draft.mentions, everyone: draft.everyone)
            store.selectedConversationID = roomID
        }
    }
    private func load() async { await action.perform { try await loadResources() } }
    private func loadResources() async throws {
        overview = try await store.read(resourcePath("bots", botID, "/overview"))
        ideas = try await store.read(resourcePath("bots", botID, "/ideas"))
        milestones = try await allResources(store, resourcePath("bots", botID, "/milestones"))
        if manages { preferences = try await allResources(store, resourcePath("bots", botID, "/preference-changes")) }
    }
    private func acknowledge(_ milestone: Milestone) async {
        await action.perform {
            let result: Milestone = try await store.mutate("POST", resourcePath("milestones", milestone.id, "/ack"), body: [:])
            if let index = milestones.firstIndex(where: { $0.id == result.id }) { milestones[index] = result }
            if store.user?.preferences.celebrationsEnabled == true { action.receipt = "✓ Verified milestone recorded; evidence \(result.evidenceId)." }
        }
    }
}
struct PreferencePatchView: View {
    let title: String
    let patch: JobPreferencePatch
    var body: some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption.bold())
            if let job = patch.job { Text("Job: \(job)") }
            if let instructions = patch.instructions { Text("Instructions: \(instructions)") }
            if let voice = patch.voice { Text("Voice: \(voice.voiceId) · \(voice.speed) · \(voice.language ?? "auto")") }
            if let language = patch.language { Text("Language: \(language ?? "Automatic")") }
        }.textSelection(.enabled)
    }
}
struct BotGrantRow: View {
    let store: LemonBotStore
    let grant: BotGrant
    let manages: Bool
    init(store: LemonBotStore, grant: BotGrant, manages: Bool) { self.store = store; self.grant = grant; self.manages = manages }
    @State private var updated: BotGrant?
    @State private var action = UIActionState()
    private var current: BotGrant { (updated?.revision ?? 0) > grant.revision ? updated! : grant }
    var body: some View {
        VStack(alignment: .leading) {
            Text(current.capabilityId).font(.headline)
            Text("Requested: \(current.requestedLevel) · effective: \(current.effectiveLevel)").font(.caption)
            ForEach(current.reasons, id: \.self) { reason in Text(reason).font(.caption) }
            if manages {
                Menu("Request Bot access level") {
                    ForEach(["off", "read_only", "read_interact"], id: \.self) { level in Button(level.replacingOccurrences(of: "_", with: " ")) { Task { await action.perform { updated = try await store.mutate("PATCH", resourcePath("bots", current.botId, "/grants/" + current.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!), body: ["revision": .number(Double(current.revision)), "requestedLevel": .string(level)]) } } } }
                }.disabled(action.busy || store.connectionState != "online")
            }
            ActionErrorView(message: action.error)
        }
    }
}
struct BotJobEditorView: View {
    let store: LemonBotStore
    let bot: Bot
    @State private var job: String
    @State private var instructions: String
    @State private var reason = "Manual Job edit"
    @State private var action = UIActionState()
    init(store: LemonBotStore, bot: Bot) { self.store = store; self.bot = bot; _job = State(initialValue: bot.job); _instructions = State(initialValue: bot.instructions) }
    private var manages: Bool { bot.ownerUserId == store.user?.id || bot.managerUserIds.contains(store.user?.id ?? "") }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Job and standing boundaries").font(.headline)
            TextField("Job", text: $job, axis: .vertical).lineLimit(3...12)
            TextField("Instructions / style / boundaries", text: $instructions, axis: .vertical).lineLimit(4...16)
            TextField("Reason for durable change", text: $reason)
            Text("Durable instructions are distinct from one-time chat requests and Memory. Hard workspace policy remains a separate ceiling.").font(.caption)
            Button("Save inspectable preference change") { Task { await action.perform {
                let _: PreferenceChange = try await store.mutate("POST", resourcePath("bots", bot.id, "/preference-changes"), body: ["revision": .number(Double(bot.revision)), "changes": .object(["job": .string(job), "instructions": .string(instructions)]), "reason": .string(reason)])
                try await store.refresh()
            } } }.disabled(action.busy || !manages || store.connectionState != "online" || reason.isEmpty)
            ActionErrorView(message: action.error)
        }.textFieldStyle(.roundedBorder).disabled(!manages)
    }
}
