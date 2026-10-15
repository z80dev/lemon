import SwiftUI
import LemonBotKit

struct GroupEditorView: View {
    let store: LemonBotStore
    let conversation: Conversation?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var botIDs: Set<ID>
    @State private var lead: ID
    @State private var action = UIActionState()
    init(store: LemonBotStore, conversation: Conversation? = nil) {
        self.store = store; self.conversation = conversation
        _name = State(initialValue: conversation?.name ?? "")
        _botIDs = State(initialValue: Set(conversation?.botIds ?? []))
        _lead = State(initialValue: conversation?.leadBotId ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                SwiftUI.Section("Group") {
                    TextField("Group name", text: $name)
                    Text("Choose 2–6 of your Bots. Each works on its machine. Anyone in the group can start Bots, which may use paid providers. Selected Bots can see the group's messages and files.")
                }
                SwiftUI.Section("Bots · \(botIDs.count)/6") {
                    ForEach(store.bots.filter { $0.ownerUserId == store.user?.id }) { bot in Toggle(isOn: selected(bot.id)) { BotIdentityAnchor(store: store, bot: bot) }.disabled(!botIDs.contains(bot.id) && botIDs.count >= 6) }
                    Picker("Lead Bot", selection: $lead) {
                        Text("Choose lead").tag("")
                        ForEach(store.bots.filter { botIDs.contains($0.id) }) { bot in Text(bot.name).tag(bot.id) }
                    }
                }
                ActionErrorView(message: action.error)
                Button(conversation == nil ? "Create group" : "Update group") { Task { await save() } }
                    .disabled(action.busy || store.connectionState != "online" || !(2...6).contains(botIDs.count) || !botIDs.contains(lead) || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text(store.isOnline ? "Add a name, 2–6 Bots and a lead Bot to save." : "Reconnect to save this group.").font(LBFont.meta).foregroundStyle(LB.muted)
            }.navigationTitle(conversation == nil ? "New group" : "Group members")
                .toolbar { Button("Cancel") { dismiss() } }
        }.frame(minWidth: 320, minHeight: 520)
    }
    private func selected(_ id: ID) -> Binding<Bool> {
        Binding(get: { botIDs.contains(id) }, set: { flag in
            if flag { botIDs.insert(id); if lead.isEmpty { lead = id } }
            else { botIDs.remove(id); if lead == id { lead = botIDs.sorted().first ?? "" } }
        })
    }
    private func save() async {
        await action.perform {
            var body: JSONObject = ["name": .string(name), "botIds": strings(botIDs.sorted()), "leadBotId": .string(lead)]
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
