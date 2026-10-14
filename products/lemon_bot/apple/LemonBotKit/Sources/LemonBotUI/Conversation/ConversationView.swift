import SwiftUI
import LemonBotKit

public struct ConversationView: View {
    private let store: LemonBotStore
    private let conversationID: ID
    @State private var action = UIActionState()
    @State private var olderCursor: String?
    @State private var find = ""
    @State private var groupEdit = false
    @State private var confirmation: Confirmation?
    @State private var renderedReadSeq = 0
    @State private var jumpID: ID?
    @State private var searchChat = false
    @State private var details = false
    public init(store: LemonBotStore, conversationID: ID) { self.store = store; self.conversationID = conversationID }
    private var conversation: Conversation? { store.conversations.first { $0.id == conversationID } }
    private var entries: [TranscriptEntry] { (store.entries[conversationID] ?? []).sorted { $0.seq < $1.seq } }
    private var bot: Bot? { store.bots.first { conversation?.botIds.first == $0.id } }
    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if olderCursor != nil { Button("Load older history") { Task { await loadOlder() } }.disabled(action.busy) }
                        ForEach(entries) { entry in
                            if entry.seq == (conversation?.lastReadSeq ?? 0) + 1 && (conversation?.unreadCount ?? 0) > 0 {
                                HStack { Divider(); Text("Unread").font(.caption); Divider() }
                            }
                            TranscriptEntryView(store: store, entry: entry).id(entry.id)
                                .onAppear { Task { await markRendered(entry.seq) } }
                        }
                    }.padding().frame(maxWidth: 960, alignment: .leading).frame(maxWidth: .infinity)
                }.onChange(of: entries.last?.id) { old, new in
                    if old == nil, let new { proxy.scrollTo(new, anchor: .bottom) }
                }.onChange(of: jumpID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
                    .onChange(of: store.navigationTarget?.entryID) { _, _ in Task { await loadTargetEntry() } }
            }
            if !find.isEmpty {
                HStack {
                    Text("Find in this chat")
                    ForEach(entries.filter { $0.text?.localizedCaseInsensitiveContains(find) == true }.prefix(8)) { entry in Button("\(entry.actor.displayName) · #\(entry.seq)") { jumpID = entry.id } }
                }.font(.caption).padding(8)
            }
            ActionErrorView(message: action.error ?? store.errorMessage)
            if let receipt = action.receipt { Text(receipt).font(.caption).textSelection(.enabled).padding(8) }
            Divider()
            ComposerView(store: store, conversationID: conversationID).id(conversationID)
        }.navigationTitle(conversation?.name.isEmpty == false ? conversation!.name : bot?.name ?? "Conversation")
            .toolbar {
                TextField("Find in chat", text: $find).frame(maxWidth: 180)
                Button("Search this chat") { searchChat = true }.keyboardShortcut("f", modifiers: .command)
                Button("Focus composer") { NotificationCenter.default.post(name: Notification.Name("LemonBot.focusComposer"), object: nil, userInfo: ["conversationID": conversationID]) }.keyboardShortcut("i", modifiers: .command)
                Menu("Conversation") {
                    Button("Details, media and my export consent") { details = true }
                    Button("New task") { Task { await createTask() } }.disabled(bot == nil)
                    if conversation?.kind == "group" && conversation?.ownerUserId == store.user?.id { Button("Edit group members") { groupEdit = true } }
                    Button("Mark unread") { Task { await markUnread() } }
                    if conversation?.ownerUserId == store.user?.id { Button("Delete conversation…", role: .destructive) { Task { await previewDelete() } } }
                }.disabled(store.connectionState != "online")
            }
            .task(id: conversationID) { await open() }
            .onAppear { NotificationCenter.default.post(name: Notification.Name("LemonBot.visibleConversationChanged"), object: nil, userInfo: ["conversationID": conversationID]) }
            .onDisappear {
                NotificationCenter.default.post(name: Notification.Name("LemonBot.visibleConversationChanged"), object: nil, userInfo: ["conversationID": NSNull()])
            }
            .sheet(isPresented: $groupEdit) { GroupEditorView(store: store, conversation: conversation) }
            .sheet(isPresented: $searchChat) { NavigationStack { SearchHubView(store: store, conversationID: conversationID) } }
            .sheet(isPresented: $details) { ConversationDetailsView(store: store, conversationID: conversationID) }
            .sheet(isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
                if let confirmation { ScopeConfirmationView(store: store, confirmation: confirmation, title: "Delete conversation") { body in
                    let _: Deleted = try await store.mutate("DELETE", resourcePath("conversations", conversationID), body: body)
                    store.selectedConversationID = nil
                    try await store.refresh()
                } }
            }
    }
    private var header: some View {
        HStack {
            if let bot {
                NavigationLink { BotOverviewView(store: store, botID: bot.id) } label: { BotIdentityAnchor(store: store, bot: bot) }.buttonStyle(.plain)
            } else { Label(conversation?.name ?? "Loading conversation", systemImage: "person.2") }
            if conversation?.kind == "task" { StatusBadge(text: "task") }
            if let conversation, !conversation.activity.isEmpty { Text(conversation.activity.map { activity in "\(store.bots.first(where: { $0.id == activity.botId })?.name ?? activity.botId): \(activity.phase)" }.joined(separator: " · ")).font(.caption) }
            if !activeRuns.isEmpty {
                Button("Stop", systemImage: "stop.fill") { Task { await stop() } }.disabled(action.busy || store.connectionState != "online")
            }
        }.padding(12)
    }
    private var activeRuns: [Run] { store.runs.filter { $0.conversationId == conversationID && ["reserved", "queued", "running", "awaiting_input", "outcome_unknown"].contains($0.status) } }
    private func open() async {
        await action.perform {
            try await store.openConversation(conversationID)
            let page: Page<TranscriptEntry> = try await store.read(resourcePath("conversations", conversationID, "/entries"))
            olderCursor = page.nextCursor
            merge(page.items)
            if let target = store.navigationTarget, let entryID = target.entryID,
               (target.taskConversationID ?? target.conversationID) == conversationID {
                let current: TranscriptEntry = try await store.read(resourcePath("entries", entryID))
                guard current.conversationId == conversationID else { return }
                merge([current])
                jumpID = entryID
            }
        }
    }
    private func loadTargetEntry() async {
        guard let target = store.navigationTarget, let id = target.entryID,
              (target.taskConversationID ?? target.conversationID) == conversationID else { return }
        do {
            let entry: TranscriptEntry = try await store.read(resourcePath("entries", id))
            guard entry.conversationId == conversationID else { return }
            merge([entry])
            jumpID = id
        } catch { action.error = error.localizedDescription }
    }
    private func markRendered(_ through: Int) async {
        guard through > renderedReadSeq, store.connectionState == "online" else { return }
        renderedReadSeq = through
        do {
            let updated: Conversation = try await store.mutate("POST", resourcePath("conversations", conversationID, "/read"), body: ["throughSeq": .number(Double(through))])
            if let index = store.conversations.firstIndex(where: { $0.id == updated.id }), updated.revision >= store.conversations[index].revision { store.conversations[index] = updated }
        } catch { action.error = error.localizedDescription }
    }
    private func merge(_ page: [TranscriptEntry]) {
        var keyed = Dictionary(uniqueKeysWithValues: (store.entries[conversationID] ?? []).map { ($0.id, $0) })
        for entry in page where entry.revision >= (keyed[entry.id]?.revision ?? 0) { keyed[entry.id] = entry }
        store.entries[conversationID] = keyed.values.sorted { $0.seq < $1.seq }
    }
    private func loadOlder() async { await action.perform { guard let olderCursor else { return }; let page: Page<TranscriptEntry> = try await store.read(resourcePath("conversations", conversationID, "/entries"), query: ["cursor": olderCursor]); merge(page.items); self.olderCursor = page.nextCursor } }
    private func stop() async {
        await action.perform {
            var statuses: [String] = []
            for run in activeRuns {
                let receipt: Run = try await store.mutate("POST", resourcePath("runs", run.id, "/cancel"), body: ["reason": .string("Explicit user Stop")])
                if let index = store.runs.firstIndex(where: { $0.id == receipt.id }) { store.runs[index] = receipt }
                statuses.append("\(receipt.id): \(receipt.status == "cancelled" ? "Cancelled" : "Stop requested · \(receipt.status)")")
            }
            action.receipt = statuses.joined(separator: " · ") + ". Completed external effects are not rolled back."
        }
    }
    private func createTask() async {
        await action.perform {
            guard let bot else { return }
            let task: Conversation = try await store.mutate("POST", "/conversations", body: ["kind": .string("task"), "botIds": strings([bot.id]), "parentConversationId": .string(conversationID), "name": .string("Task with \(bot.name)")])
            try await store.refresh(); store.selectedConversationID = task.id
        }
    }
    private func markUnread() async { await action.perform { let _: Conversation = try await store.mutate("POST", resourcePath("conversations", conversationID, "/read"), body: ["throughSeq": .number(Double(conversation?.lastReadSeq ?? 0)), "unread": .bool(true)]); try await store.refresh() } }
    private func previewDelete() async { await action.perform { confirmation = try await store.mutate("POST", resourcePath("conversations", conversationID, "/preview"), body: ["action": .string("delete")]) } }
}

struct TranscriptEntryView: View {
    let store: LemonBotStore
    let entry: TranscriptEntry
    init(store: LemonBotStore, entry: TranscriptEntry) { self.store = store; self.entry = entry }
    @State private var action = UIActionState()
    @State private var feedback = false
    @State private var comment = ""
    @State private var reasons: Set<String> = []
    @State private var sentiment = "good"
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.actor.displayName).font(.headline)
                StatusBadge(text: entry.actor.kind)
                Text(timestamp(Double(entry.timestampMs)), style: .time).font(.caption).foregroundStyle(.secondary)
                if entry.streaming { ProgressView().controlSize(.small) }
                Spacer()
                Menu {
                    if let text = entry.text { Button("Copy") { copyText(text) } }
                    Button("Reply") { let draft = store.draft(for: entry.conversationId); store.setLocalDraft(conversationID: entry.conversationId, text: draft.text, attachmentIDs: draft.attachmentIDs, replyTo: entry.id) }
                    ForEach(["👍", "❤️", "🎉", "👀"], id: \.self) { emoji in Button("React \(emoji)") { Task { await react(emoji) } } }
                    Button("Give feedback") { feedback = true }
                    Button("Copy entry ID") { copyText(entry.id) }
                } label: { Image(systemName: "ellipsis") }.disabled(action.busy || (entry.targetedUserId.map { $0 != store.user?.id } ?? false))
            }
            if let reply = entry.replyToEntryId {
                let quoted = store.entries[entry.conversationId]?.first { $0.id == reply && ($0.targetedUserId == nil || $0.targetedUserId == store.user?.id) }
                Text("↳ \(quoted?.actor.displayName ?? "Referenced entry") · \(quoted?.text.map { String($0.prefix(180)) } ?? "File, card or unavailable entry")").font(.caption).foregroundStyle(.secondary)
            }
            if let target = entry.targetedUserId, target != store.user?.id {
                Text("Private entry unavailable to this account.")
            } else { content }
            if !entry.reactions.isEmpty {
                HStack { ForEach(entry.reactions, id: \.emoji) { reaction in Button("\(reaction.emoji) \(reaction.userIds.count)") { Task { await react(reaction.emoji) } }.buttonStyle(.borderless).disabled(store.connectionState != "online") } }
            }
            ActionErrorView(message: action.error)
        }.padding(.vertical, 4)
            .sheet(isPresented: $feedback) {
                NavigationStack {
                    Form {
                        Picker("Feedback", selection: $sentiment) { Text("Good").tag("good"); Text("Bad").tag("bad") }
                        ForEach(["not_requested", "inaccurate", "low_quality", "slow"], id: \.self) { reason in Toggle(reason.replacingOccurrences(of: "_", with: " ").capitalized, isOn: Binding(get: { reasons.contains(reason) }, set: { if $0 { reasons.insert(reason) } else { reasons.remove(reason) } })) }
                        TextField("Comment", text: $comment, axis: .vertical)
                        Text("Feedback does not authorize an action.").font(.caption)
                        ActionErrorView(message: action.error)
                        Button("Save feedback") { Task { await action.perform { let _: Feedback = try await store.mutate("POST", resourcePath("entries", entry.id, "/feedback"), body: ["sentiment": .string(sentiment), "reasons": strings(Array(reasons)), "comment": .string(comment)]); feedback = false } } }.disabled(action.busy || store.connectionState != "online")
                    }.navigationTitle("Feedback").toolbar { Button("Cancel") { feedback = false } }
                }.frame(minWidth: 320, minHeight: 320)
            }
    }
    @ViewBuilder private var content: some View {
        switch entry {
        case .message(let message):
            if !message.text.isEmpty { Text(.init(message.text)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading) }
            ForEach(message.attachmentIds, id: \.self) { id in AttachmentView(store: store, attachmentID: id) }
        case .card(let card): TranscriptCardView(store: store, card: card.card)
        case .userAttachment(let attachment):
            if !isGroupedAttachment(attachment.attachmentId) { AttachmentView(store: store, attachmentID: attachment.attachmentId) }
        case .toolCall(let tool):
            DisclosureGroup { if let detail = tool.detail { Text(detail).font(.caption).textSelection(.enabled) }; Text("Tool: \(tool.tool)").font(.caption) } label: { Label("\(tool.title) · \(tool.status)", systemImage: tool.status == "failed" ? "exclamationmark.circle" : "gearshape") }
        case .mcpApp(let app):
            Text("App snapshot · \(app.state) · connector \(app.connectorId)").font(.caption)
            Text(app.resourceUri).font(.caption).textSelection(.enabled)
            if let id = app.snapshotAttachmentId { AttachmentView(store: store, attachmentID: id) }
            else { Text("No authorized snapshot is available. Ask the Bot to refresh through chat.").font(.caption) }
        case .notice(let notice):
            Label(notice.text, systemImage: notice.severity == "error" ? "exclamationmark.triangle" : "info.circle").textSelection(.enabled)
            if let id = notice.requestId { Button("Copy request \(id)") { copyText(id) }.font(.caption) }
        case .event(let event): TranscriptEventView(store: store, event: event.event)
        case .feedback(let feedback): Text("Feedback: \(feedback.feedback.sentiment) · \(feedback.feedback.reasons.joined(separator: ", ")) · \(feedback.feedback.comment)").font(.caption)
        case .voiceCall(let voice):
            VoiceCallSummaryView(store: store, session: voice.voiceSession)
        case .unsupported(let value):
            Text("Entry type \(value.kind) requires a newer client; no action was authorized.").foregroundStyle(.orange)
            if let text = value.text { Text(text).textSelection(.enabled) }
            if let id = value.attachmentId { AttachmentView(store: store, attachmentID: id) }
        }
    }
    private func isGroupedAttachment(_ id: ID) -> Bool {
        store.entries[entry.conversationId]?.contains { candidate in
            guard candidate.batchId != nil, candidate.batchId == entry.batchId, case .message(let message) = candidate else { return false }
            return message.attachmentIds.contains(id)
        } ?? false
    }
    private func react(_ emoji: String) async {
        guard store.connectionState == "online" else { return }
        await action.perform {
            let remove = entry.reactions.contains { $0.emoji == emoji && $0.userIds.contains(store.user?.id ?? "") }
            let result: TranscriptEntry = try await store.mutate(remove ? "DELETE" : "POST", resourcePath("entries", entry.id, "/reactions"), body: ["emoji": .string(emoji)])
            if let index = store.entries[entry.conversationId]?.firstIndex(where: { $0.id == result.id }) { store.entries[entry.conversationId]?[index] = result }
        }
    }
}

struct TranscriptEventView: View {
    let store: LemonBotStore
    let event: TranscriptEvent
    var body: some View {
        Group {
            switch event {
            case .nameChanged(let value): Text("Name changed to \(value.name)")
            case .channelConnected(let value): Text("Channel connected · \(value.channelBindingId)")
            case .channelDisconnected(let value): Text("Channel disconnected · \(value.channelBindingId)")
            case .routineChanged(let value): NavigationLink("Routine \(value.action) · \(value.routineId)") { RoutineDetailView(store: store, routineID: value.routineId) }
            case .taskChanged(let value): NavigationLink("Task \(value.status)") { ConversationView(store: store, conversationID: value.conversationId) }
            case .teamShared(let value): botLink(value.botId, "Team copy shared")
            case .teamBotPublished(let value): botLink(value.botId, "Team Bot published")
            case .teamBotUnpublished(let value): botLink(value.botId, "Team Bot unpublished")
            case .personAdded(let value): Text("Person added · \(value.userId). Added members can see retained group history.")
            case .personRemoved(let value): Text("Person removed · \(value.userId)")
            case .personLeft(let value): Text("Person left · \(value.userId)")
            case .botAdded(let value): botLink(value.botId, "Bot added")
            case .botRemoved(let value): Text("Bot removed · \(value.botId)")
            case .handoff(let value): NavigationLink("\(value.sourceBotId) → \(value.targetBotId): \(value.text)") { ConversationView(store: store, conversationID: value.targetConversationId) }
            case .machineMoved(let value): Text("Bot \(value.botId) moved: \(value.sourceMachineId) → \(value.targetMachineId). Files and credentials were not copied.")
            }
        }.font(.caption).foregroundStyle(.secondary)
    }
    private func botLink(_ id: ID, _ label: String) -> some View { NavigationLink(label) { BotOverviewView(store: store, botID: id) } }
}
