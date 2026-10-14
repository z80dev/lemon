import SwiftUI
import LemonBotKit

struct GroupEditorView: View {
    let store: LemonBotStore
    let conversation: Conversation?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var botIDs: Set<ID>
    @State private var humanIDs: Set<ID>
    @State private var lead: ID
    @State private var members: [Member] = []
    @State private var acceptedHistory = false
    @State private var action = UIActionState()
    init(store: LemonBotStore, conversation: Conversation? = nil) {
        self.store = store; self.conversation = conversation
        _name = State(initialValue: conversation?.name ?? "")
        _botIDs = State(initialValue: Set(conversation?.botIds ?? []))
        _humanIDs = State(initialValue: Set(conversation?.humanUserIds ?? [store.user?.id ?? ""]).subtracting([""]))
        _lead = State(initialValue: conversation?.leadBotId ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                SwiftUI.Section("Group") {
                    TextField("Group name", text: $name)
                    Text("Choose 2–6 authorized Bots. Each works on its own assigned machine; @everyone may start several billed provider runs. Ordinary inputs and files are shared with everyone in the group.")
                }
                SwiftUI.Section("Bots · \(botIDs.count)/6") {
                    ForEach(store.bots) { bot in Toggle(isOn: selected(bot.id, bots: true)) { BotIdentityAnchor(store: store, bot: bot) }.disabled(!botIDs.contains(bot.id) && botIDs.count >= 6) }
                    Picker("Lead Bot", selection: $lead) {
                        Text("Choose lead").tag("")
                        ForEach(store.bots.filter { botIDs.contains($0.id) }) { bot in Text(bot.name).tag(bot.id) }
                    }
                }
                SwiftUI.Section("People") {
                    ForEach(members.filter(\.enabled)) { member in
                        Toggle("\(member.displayName) · \(member.email)", isOn: selected(member.userId, bots: false)).disabled(member.userId == store.user?.id || member.userId == conversation?.ownerUserId)
                    }
                    Toggle("I understand added members can see all retained group history", isOn: $acceptedHistory)
                    Text("Private approvals, credentials, drafts and connector consent remain in the designated person's private task/DM. Group membership is not machine access or connector authorization.").font(.caption)
                }
                ActionErrorView(message: action.error)
                Button(conversation == nil ? "Create group" : "Update group") { Task { await save() } }
                    .disabled(action.busy || store.connectionState != "online" || !(2...6).contains(botIDs.count) || !botIDs.contains(lead) || !acceptedHistory || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.navigationTitle(conversation == nil ? "New group" : "Group members")
                .toolbar { Button("Cancel") { dismiss() } }
                .task { await action.perform {
                    var cursor: String?
                    repeat {
                        var query = ["limit": "200"]
                        if let cursor { query["cursor"] = cursor }
                        let page: Page<Member> = try await store.read("/members", query: query)
                        members += page.items; cursor = page.nextCursor
                    } while cursor != nil
                } }
        }.frame(minWidth: 320, minHeight: 520)
    }
    private func selected(_ id: ID, bots: Bool) -> Binding<Bool> {
        Binding(get: { bots ? botIDs.contains(id) : humanIDs.contains(id) }, set: { flag in
            if bots {
                if flag { botIDs.insert(id); if lead.isEmpty { lead = id } } else { botIDs.remove(id); if lead == id { lead = botIDs.sorted().first ?? "" } }
            } else { if flag { humanIDs.insert(id) } else { humanIDs.remove(id) } }
        })
    }
    private func save() async {
        await action.perform {
            var body: JSONObject = ["name": .string(name), "botIds": strings(botIDs.sorted()), "humanUserIds": strings(humanIDs.sorted()), "leadBotId": .string(lead)]
            let result: Conversation
            if let conversation {
                body["revision"] = .number(Double(conversation.revision))
                result = try await store.mutate("PATCH", resourcePath("conversations", conversation.id), body: body)
            } else {
                body["kind"] = .string("group")
                result = try await store.mutate("POST", "/conversations", body: body)
            }
            try await store.refresh(); store.selectedConversationID = result.id
            dismiss()
        }
    }
}
