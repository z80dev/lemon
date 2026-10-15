import SwiftUI
import LemonBotKit

struct ConversationDetailsView: View {
    let store: LemonBotStore
    let conversationID: ID
    init(store: LemonBotStore, conversationID: ID) { self.store = store; self.conversationID = conversationID }
    @Environment(\.dismiss) private var dismiss
    @State private var room: Conversation?
    @State private var files: [Attachment] = []
    @State private var consent: ContentExportConsent?
    @State private var exportEnabled = false
    @State private var action = UIActionState()
    @State private var deletion: Confirmation?
    var body: some View {
        NavigationStack {
            Form {
                if let room {
                    SwiftUI.Section("Identity and participants") {
                        Text(room.name).font(.headline)
                        StatusBadge(text: room.kind)
                        Text("Owner: \(room.ownerUserId)")
                        if let lead = room.leadBotId { Text("Lead Bot: \(store.bots.first(where: { $0.id == lead })?.name ?? lead)") }
                        ForEach(store.bots.filter { room.botIds.contains($0.id) }) { bot in NavigationLink { BotOverviewView(store: store, botID: bot.id) } label: { BotIdentityAnchor(store: store, bot: bot) } }
                        if room.kind == "group" { Text("This group contains your own Bots. Selected Bots can access the group's inputs and files; credentials stay in their write-only destination flow.").font(.caption) }
                    }
                    if room.kind == "group" {
                        SwiftUI.Section("Delete this group") {
                            Text("Review the exact permanent deletion scope. Active or unconfirmed work must be resolved separately; deletion is never queued offline.")
                            Button("Review permanent conversation deletion", role: .destructive) { Task { await previewDelete() } }.disabled(action.busy || action.uncertain || store.connectionState != "online" || room.ownerUserId != store.user?.id)
                        }
                    }
                }
                SwiftUI.Section("Your explicit content export consent") {
                    Toggle("Allow this conversation's content to be exported", isOn: $exportEnabled)
                    Text("Off by default. Export also requires your workspace policy and explicit owner consent. Revocation stops new or undelivered packets but cannot erase already acknowledged external collector copies.").font(.caption)
                    Button("Save my consent") { Task { await saveConsent() } }.disabled(consent == nil || action.busy || store.connectionState != "online")
                    if let consent { Text("Recorded: \(consent.enabled ? "enabled" : "disabled") · revision \(consent.revision)").font(.caption) }
                }
                SwiftUI.Section("Authorized media and deliverables") {
                    ForEach(files) { file in AttachmentView(store: store, attachmentID: file.id) }
                }
                ActionErrorView(message: action.error)
            }.navigationTitle("Conversation details").toolbar { Button("Close") { dismiss() } }
                .task(id: conversationID) { await action.perform {
                    room = try await store.read(resourcePath("conversations", conversationID))
                    consent = try await store.read(resourcePath("conversations", conversationID, "/export-consent"))
                    exportEnabled = consent?.enabled ?? false
                    files = try await allResources(store, "/attachments", query: ["conversationId": conversationID])
                } }
                .sheet(isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })) {
                    if let deletion {
                        ScopeConfirmationView(store: store, confirmation: deletion, title: "Delete conversation") { body in
                            let _: Deleted = try await store.mutate("DELETE", resourcePath("conversations", conversationID), body: body)
                            store.selectedConversationID = nil
                            try await store.refresh()
                            dismiss()
                        }
                    }
                }
        }.frame(minWidth: 340, minHeight: 500)
    }
    private func saveConsent() async {
        await action.perform {
            guard let consent else { return }
            self.consent = try await store.mutate("PUT", resourcePath("conversations", conversationID, "/export-consent"), body: ["revision": .number(Double(consent.revision)), "enabled": .bool(exportEnabled)])
        }
    }
    private func previewDelete() async {
        await action.perform { deletion = try await store.mutate("POST", resourcePath("conversations", conversationID, "/preview"), body: ["action": .string("delete")]) }
    }
}
