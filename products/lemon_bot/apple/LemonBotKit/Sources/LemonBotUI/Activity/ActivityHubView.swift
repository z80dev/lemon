import SwiftUI
import LemonBotKit

public struct ActivityHubView: View {
    let store: LemonBotStore
    @State private var tab = "activity"
    @State private var botID = ""
    @State private var machineID = ""
    @State private var timeFilter = false
    @State private var from = Date().addingTimeInterval(-7 * 86_400)
    @State private var to = Date().addingTimeInterval(30 * 86_400)
    @State private var activity: [ActivityItem] = []
    @State private var upcoming: [UpcomingItem] = []
    @State private var reminders: [Reminder] = []
    @State private var milestones: [Milestone] = []
    @State private var cursor: String?
    @State private var reminderPresented = false
    @State private var cancelling: Reminder?
    @State private var action = HubAction()
    public init(store: LemonBotStore) { self.store = store }
    public var body: some View {
        VStack {
            Picker("Destination", selection: $tab) { Text("Activity").tag("activity"); Text("Upcoming").tag("upcoming"); Text("Reminders").tag("reminders"); Text("Milestones").tag("milestones"); Text("Inbox").tag("inbox"); Text("Search").tag("search") }
            if tab == "inbox" { InboxHubView(store: store) }
            else if tab == "search" { SearchHubView(store: store) }
            else {
                List {
                    HubError(action: action, store: store)
                    Section("Filters") {
                        HubBotPicker(store: store, selection: $botID).onChange(of: botID) { Task { await load() } }
                        if ["activity", "upcoming"].contains(tab) {
                            HubMachinePicker(store: store, selection: $machineID).onChange(of: machineID) { Task { await load() } }
                            Toggle("Limit time range", isOn: $timeFilter)
                            if timeFilter { DatePicker("From", selection: $from); DatePicker("To", selection: $to) }
                        }
                        Button("Apply filters / refresh") { Task { await load() } }
                    }
                    if tab == "activity" {
                        ForEach(activity) { item in
                            VStack(alignment: .leading) {
                                Text("\(item.title) · \(item.status)").font(.headline)
                                Text(item.summary).textSelection(.enabled)
                                Text("\(item.machineLabel) · \(hubDate(item.occurredAtMs)) · Bot \(item.botId)").font(.caption)
                                Text("Run \(item.runId ?? "none") · task \(item.taskConversationId ?? "none")").font(.caption)
                                Button("Open exact context") { Task { await action.perform { try await open(item) } } }
                            }
                        }
                    } else if tab == "upcoming" {
                        ForEach(upcoming, id: \.id) { item in
                            VStack(alignment: .leading) {
                                Text(item.title).font(.headline)
                                Text("\(hubDate(item.dueAtMs)) · \(item.timezone)")
                                Text("\(item.machineLabel) · \(item.machineStatus) · last result \(item.lastRunStatus ?? "none")")
                                if let reason = item.blockedReason { Text(reason).foregroundStyle(.orange) }
                                if let routineID = item.routineId { NavigationLink("Open routine and exact history") { RoutineDetailView(store: store, routineID: routineID) } }
                                if let reminderID = item.reminderId { Text("Reminder: \(reminderID)").font(.caption) }
                            }
                        }
                    } else if tab == "reminders" {
                        Text("Reminders deliver one notification, not an agent run or a second scheduler.")
                        Button("Create reminder") { reminderPresented = true }
                        ForEach(reminders) { reminder in
                            VStack(alignment: .leading) {
                                Text(reminder.text).font(.headline)
                                Text("\(hubDate(reminder.dueAtMs)) · \(reminder.timezone) · \(reminder.state)")
                                Button("Open exact conversation") { Task { await action.perform { try await store.openConversation(reminder.conversationId) } } }
                                if reminder.state == "scheduled" { Button("Cancel reminder", role: .destructive) { cancelling = reminder } }
                            }
                        }
                    } else {
                        Text("Verified outcomes only, unique per Bot and user. Static checkmarks respect reduced motion; no acceptance-as-success celebration.")
                        if botID.isEmpty { Text("Select a Bot to inspect its verified milestones.") }
                        ForEach(milestones) { milestone in
                            VStack(alignment: .leading) {
                                Text("✓ \(milestone.kind)").font(.headline)
                                Text("Verified \(hubDate(milestone.earnedAtMs)) · evidence \(milestone.evidenceId)").font(.caption)
                                if milestone.acknowledgedAtMs == nil { Button("Acknowledge once across devices") { Task { await action.perform {
                                    let acknowledged: Milestone = try await store.mutate("POST", "/milestones/\(hubID(milestone.id))/ack", body: [:])
                                    if let index = milestones.firstIndex(where: { $0.id == acknowledged.id }) { milestones[index] = acknowledged }
                                } } }.disabled(action.busy || action.uncertain || store.connectionState != "online") }
                                else { Text("Acknowledged \(hubDate(milestone.acknowledgedAtMs))").font(.caption) }
                            }
                        }
                    }
                    if cursor != nil { Button("More results") { Task { await load(more: true) } } }
                }
            }
        }.padding(.horizontal).navigationTitle("Activity & Upcoming")
            .onChange(of: tab) { Task { await load() } }.task { await load() }
            .sheet(isPresented: $reminderPresented) { NavigationStack { ReminderCreateView(store: store) } }
            .confirmationDialog("Cancel this exact reminder? No agent run is cancelled.", isPresented: Binding(get: { cancelling != nil }, set: { if !$0 { cancelling = nil } })) {
                Button("Cancel reminder", role: .destructive) { guard let reminder = cancelling else { return }; Task { await action.perform {
                    let _: Reminder = try await store.mutate("DELETE", "/reminders/\(hubID(reminder.id))", body: ["revision": .number(Double(reminder.revision))]); cancelling = nil; try await refresh()
                } } }.disabled(action.busy || action.uncertain || store.connectionState != "online")
            }
    }
    private func open(_ item: ActivityItem) async throws {
        if let approvalID = item.approvalId {
            let approval: Approval = try await store.read("/approvals/\(hubID(approvalID))")
            try await hubNavigate(store: store, botID: approval.botId, conversationID: approval.conversationId, entryID: approval.entryId, approvalID: approval.id)
            return
        }
        if let conversation = item.taskConversationId ?? item.conversationId {
            try await hubNavigate(store: store, botID: item.botId, conversationID: conversation, taskID: item.taskConversationId, entryID: item.entryId, approvalID: item.approvalId)
        } else if let runID = item.runId {
            let run: Run = try await store.read("/runs/\(hubID(runID))")
            try await hubNavigate(store: store, botID: item.botId, conversationID: run.conversationId, entryID: item.entryId)
        } else if let entryID = item.entryId {
            let entry: TranscriptEntry = try await store.read("/entries/\(hubID(entryID))")
            try await hubNavigate(store: store, botID: item.botId, conversationID: entry.conversationId, entryID: entry.id)
        } else { try await hubNavigate(store: store, machineID: item.machineId, botID: item.botId) }
    }
    private func refresh(more: Bool = false) async throws {
        var query: [String: String] = [:]
        if !botID.isEmpty { query["botId"] = botID }
        if ["activity", "upcoming"].contains(tab) {
            if !machineID.isEmpty { query["machineId"] = machineID }
            if timeFilter { query["fromAtMs"] = String(Int(from.timeIntervalSince1970 * 1000)); query["toAtMs"] = String(Int(to.timeIntervalSince1970 * 1000)) }
        }
        if more, let cursor { query["cursor"] = cursor }
        switch tab {
        case "activity": let page: HubPage<ActivityItem> = try await store.read("/activity", query: query); activity = hubMerged(activity, page.items, append: more, id: \.id); cursor = page.nextCursor
        case "upcoming": let page: HubPage<UpcomingItem> = try await store.read("/upcoming", query: query); upcoming = hubMerged(upcoming, page.items, append: more, id: \.id); cursor = page.nextCursor
        case "reminders": let page: HubPage<Reminder> = try await store.read("/reminders", query: query); reminders = hubMerged(reminders, page.items, append: more, id: \.id); cursor = page.nextCursor
        case "milestones":
            guard !botID.isEmpty else { milestones = []; cursor = nil; return }
            query.removeValue(forKey: "botId")
            let page: HubPage<Milestone> = try await store.read("/bots/\(hubID(botID))/milestones", query: query); milestones = hubMerged(milestones, page.items, append: more, id: \.id); cursor = page.nextCursor
        default: break
        }
    }
    private func load(more: Bool = false) async { await action.perform(readOnly: true) { try await refresh(more: more) } }
}
struct ReminderCreateView: View {
    let store: LemonBotStore
    @Environment(\.dismiss) private var dismiss
    @State private var botID = ""
    @State private var conversationID = ""
    @State private var text = ""
    @State private var due = Date().addingTimeInterval(3600)
    @State private var timezone = TimeZone.current.identifier
    @State private var action = HubAction()
    var body: some View {
        Form {
            HubError(action: action, store: store)
            HubBotPicker(store: store, selection: $botID).onChange(of: botID) { conversationID = "" }
            Picker("Exact conversation", selection: $conversationID) { Text("Select conversation").tag(""); ForEach(store.conversations.filter { $0.botIds.contains(botID) }) { Text($0.name).tag($0.id) } }
            TextField("Reminder text", text: $text, axis: .vertical)
            DatePicker("Due", selection: $due, in: Date()...)
            Picker("Timezone", selection: $timezone) { ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) } }
            Text("This schedules one notification scoped to your Bot and conversation. It does not execute a task.")
            Button("Schedule reminder") { Task { await action.perform {
                let _: Reminder = try await store.mutate("POST", "/reminders", body: ["botId": .string(botID), "conversationId": .string(conversationID), "text": .string(text), "dueAtMs": .number(due.timeIntervalSince1970 * 1000), "timezone": .string(timezone)]); dismiss()
            } } }.disabled(botID.isEmpty || conversationID.isEmpty || text.isEmpty || action.busy || action.uncertain || store.connectionState != "online")
        }.navigationTitle("New reminder").toolbar { Button("Cancel") { dismiss() } }
    }
}
@MainActor func hubNavigate(store: LemonBotStore, machineID: ID? = nil, botID: ID? = nil, conversationID: ID? = nil, taskID: ID? = nil, entryID: ID? = nil, approvalID: ID? = nil) async throws {
    guard let workspace = store.workspace else { throw RoutineFormError.invalid("Sign in to the target workspace before navigating.") }
    var parentConversationID = conversationID
    var exactTaskID = taskID
    if let taskID {
        if approvalID != nil {
            parentConversationID = taskID; exactTaskID = nil
        } else if taskID == conversationID {
            let task: Conversation = try await store.read("/conversations/\(hubID(taskID))")
            guard task.kind == "task", let parent = task.parentConversationId else { throw RoutineFormError.invalid("The exact task has no authorized parent conversation.") }
            parentConversationID = parent
        }
    }
    var components = URLComponents(); components.scheme = "lemonbot"; components.host = "workspace"
    components.percentEncodedPath = "/\(hubID(workspace.id))/" + (machineID.map { "machine/\(hubID($0))" } ?? "bot/\(hubID(botID ?? ""))")
    var queries: [URLQueryItem] = []
    if machineID != nil, let botID { queries.append(URLQueryItem(name: "botId", value: botID)) }
    if let parentConversationID { queries.append(URLQueryItem(name: "conversationId", value: parentConversationID)) }
    if let exactTaskID { queries.append(URLQueryItem(name: "taskConversationId", value: exactTaskID)) }
    if let entryID { queries.append(URLQueryItem(name: "entryId", value: entryID)) }
    if let approvalID { queries.append(URLQueryItem(name: "approvalId", value: approvalID)) }
    components.queryItems = queries.isEmpty ? nil : queries
    guard let url = components.url else { throw RoutineFormError.invalid("Invalid exact target.") }
    try await store.navigate(url)
}
public struct RoutineDetailView: View {
    let store: LemonBotStore
    let routineID: ID
    @State private var routine: Routine?
    @State private var action = HubAction()
    public init(store: LemonBotStore, routineID: ID) { self.store = store; self.routineID = routineID }
    public var body: some View { Group { if let routine { RoutineEditorView(store: store, initial: routine) } else { VStack { HubError(action: action, store: store); Button("Reload exact routine") { Task { await load() } } } } }.task { await load() } }
    private func load() async { await action.perform(readOnly: true) { routine = try await store.read("/routines/\(hubID(routineID))") } }
}
