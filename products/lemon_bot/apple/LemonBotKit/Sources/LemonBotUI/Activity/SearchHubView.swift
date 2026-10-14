import SwiftUI
import LemonBotKit
import QuickLook

private extension SearchHit {
    var hubIdentity: String {
        switch self {
        case .bot(let value): return "bot:" + value.bot.id
        case .group(let value): return "group:" + value.conversation.id
        case .message(let value): return "message:" + value.entry.id
        case .file(let value): return "file:" + value.attachment.id
        case .routine(let value): return "routine:" + value.routine.id
        case .skill(let value): return "skill:" + value.skill.id
        case .memory(let value): return "memory:" + value.memory.id
        }
    }
}
public struct SearchHubView: View {
    let store: LemonBotStore
    let initialConversationID: ID?
    @State private var query = ""
    @State private var kind = "all"
    @State private var botID = ""
    @State private var conversationID = ""
    @State private var hits: [SearchHit] = []
    @State private var cursor: String?
    @State private var previewURL: URL?
    @State private var searched = false
    @State private var action = HubAction()
    public init(store: LemonBotStore, conversationID: ID? = nil) { self.store = store; initialConversationID = conversationID }
    public var body: some View {
        List {
            HubError(action: action)
            Section("Authorized search filters") {
                TextField("Search visible content", text: $query).onSubmit { Task { await search() } }
                Picker("Kind", selection: $kind) { Text("All").tag("all"); Text("Messages").tag("message"); Text("Bots").tag("bot"); Text("Groups").tag("group"); Text("Files").tag("file"); Text("Routines").tag("routine"); Text("Skills").tag("skill"); Text("Memory").tag("memory") }
                HubBotPicker(store: store, selection: $botID)
                Picker("Conversation", selection: $conversationID) { Text("All conversations").tag(""); ForEach(store.conversations) { Text($0.name).tag($0.id) } }
                Button("Search") { Task { await search() } }.disabled(query.isEmpty || action.busy)
                Text("Search is ACL-scoped before snippets. Index errors stay visible rather than appearing as no matches. In-conversation search jumps to the exact matching entry.").font(.caption)
            }
            if searched && hits.isEmpty && action.error == nil { Text("No authorized matches for these filters.") }
            ForEach(hits, id: \.hubIdentity) { hit in row(hit) }
            if cursor != nil { Button("More matching results") { Task { await search(more: true) } } }
        }.navigationTitle("Search").quickLookPreview($previewURL)
            .task { conversationID = initialConversationID ?? "" }
            .onChange(of: kind) { invalidate() }.onChange(of: botID) { invalidate() }.onChange(of: conversationID) { invalidate() }.onChange(of: query) { invalidate() }
    }
    @ViewBuilder private func row(_ hit: SearchHit) -> some View {
        switch hit {
        case .bot(let value): NavigationLink("Bot · \(value.bot.name)") { BotOverviewView(store: store, botID: value.bot.id) }
        case .group(let value): Button("Group · \(value.conversation.name)") { Task { await action.perform(readOnly: true) { try await store.openConversation(value.conversation.id) } } }
        case .message(let value):
            let entry = value.entry
            let snippet = value.snippet
            VStack(alignment: .leading) {
                Text(snippet).textSelection(.enabled)
                Text("\(entry.actor.displayName) · entry \(entry.seq)").font(.caption)
                Button("Jump to exact message") { Task { await action.perform {
                    let conversation: Conversation = try await store.read("/conversations/\(hubID(entry.conversationId))")
                    guard let botID = conversation.botIds.first else { throw RoutineFormError.invalid("The matching conversation has no available Bot target.") }
                    try await hubNavigate(store: store, botID: botID, conversationID: conversation.id, taskID: conversation.kind == "task" ? conversation.id : nil, entryID: entry.id)
                } } }
            }
        case .file(let value):
            let file = value.attachment
            VStack(alignment: .leading) {
                Text("File · \(file.filename)").font(.headline)
                Text("\(file.mime) · \(file.size) bytes · \(file.preview)")
                Text("Bot \(file.provenance.botId ?? "none") · machine \(file.provenance.machineId ?? "none") · run \(file.provenance.runId ?? "none")").font(.caption)
                Button("Authorized native preview / original download") { Task { await action.perform { previewURL = try await store.download(attachmentID: file.id) } } }
            }
        case .routine(let value): NavigationLink("Routine · \(value.routine.name) · \(value.routine.scheduleDescription)") { RoutineEditorView(store: store, initial: value.routine) }
        case .skill(let value): NavigationLink("Skill · \(value.skill.name) · \(value.skill.scope)") { SkillEditorView(store: store, initial: value.skill) }
        case .memory(let value): NavigationLink { MemoryHubView(store: store, botID: value.memory.botId, memoryID: value.memory.id) } label: { VStack(alignment: .leading) { Text(value.memory.text); Text("Memory · \(value.memory.scope) · Bot \(value.memory.botId)").font(.caption) } }
        }
    }
    private func invalidate() { hits = []; cursor = nil; searched = false }
    private func search(more: Bool = false) async { await action.perform(readOnly: true) {
        guard !query.isEmpty else { return }
        var filters = ["q": query]; if kind != "all" { filters["kinds"] = kind }; if !botID.isEmpty { filters["botId"] = botID }; if !conversationID.isEmpty { filters["conversationId"] = conversationID }; if more, let cursor { filters["cursor"] = cursor }
        let page: HubPage<SearchHit> = try await store.read("/search", query: filters)
        guard filters["q"] == query, (filters["kinds"] ?? "all") == kind, (filters["botId"] ?? "") == botID, (filters["conversationId"] ?? "") == conversationID else { return }
        hits = hubMerged(hits, page.items, append: more, id: \.hubIdentity); cursor = page.nextCursor; searched = true
    } }
}
