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
    @State private var successorID: ID = ""
    @State private var leaveReviewed = false
    @State private var deletion: Confirmation?
    var body: some View {
        NavigationStack {
            Form {
                if let room {
                    SwiftUI.Section("Identity and participants") {
                        Text(room.name).font(.headline)
                        StatusBadge(text: room.kind)
                        Text("Owner: \(room.ownerUserId)")
                        Text("Humans: \(room.humanUserIds.joined(separator: ", "))")
                        if let lead = room.leadBotId { Text("Lead Bot: \(store.bots.first(where: { $0.id == lead })?.name ?? lead)") }
                        ForEach(store.bots.filter { room.botIds.contains($0.id) }) { bot in NavigationLink { BotOverviewView(store: store, botID: bot.id) } label: { BotIdentityAnchor(store: store, bot: bot) } }
                        if room.kind == "group" { Text("Added members can see retained history and shared inputs/files. Private gates and credentials must remain in their designated private task/DM.").font(.caption) }
                    }
                    if room.kind == "group" {
                        SwiftUI.Section("Leave this group explicitly") {
                            Text("Leaving removes your access and membership; it does not delete everyone else's retained group history or transfer Bot/machine/workspace ownership.")
                            if room.humanUserIds.count <= 1 {
                                Text("The last human cannot leave an ownerless group. Use the exact conversation deletion preview instead.").foregroundStyle(.orange)
                                Button("Review permanent conversation deletion", role: .destructive) { Task { await previewDelete() } }.disabled(action.busy || store.connectionState != "online" || room.ownerUserId != store.user?.id)
                            } else {
                                if room.ownerUserId == store.user?.id {
                                    Picker("Existing human successor", selection: $successorID) {
                                        Text("Choose explicitly").tag("")
                                        ForEach(room.humanUserIds.filter { $0 != store.user?.id }, id: \.self) { id in Text(id).tag(id) }
                                    }
                                    Text("The selected existing human becomes group manager only. No new person is invited or assigned a workspace role.").font(.caption)
                                }
                                Toggle("I reviewed membership and history consequences", isOn: $leaveReviewed)
                                Text("Your active, reserved or unconfirmed room work and delegated returns must reach a verified terminal outcome before leaving. A conflict lists exact run IDs and changes nothing; Stop must be separately acknowledged.").font(.caption)
                                ForEach(store.runs.filter { $0.conversationId == conversationID && $0.initiatorUserId == store.user?.id && ["reserved", "queued", "running", "awaiting_input", "outcome_unknown"].contains($0.status) }) { run in Text("Owned run \(run.id): \(run.status)").font(.caption) }
                                Button("Leave group", role: .destructive) { Task { await leave(room) } }.disabled(action.busy || store.connectionState != "online" || !leaveReviewed || (room.ownerUserId == store.user?.id && !room.humanUserIds.filter { $0 != store.user?.id }.contains(successorID)))
                            }
                        }
                    }
                }
                SwiftUI.Section("Your explicit content export consent") {
                    Toggle("Allow this conversation's content to be exported", isOn: $exportEnabled)
                    Text("Off by default. Export also requires workspace policy and explicit consent from every current human participant. You cannot consent for someone else. Revocation stops new or undelivered packets but cannot erase already acknowledged external collector copies.").font(.caption)
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
    private func leave(_ room: Conversation) async {
        await action.perform {
            var body: JSONObject = [:]
            if room.ownerUserId == store.user?.id { body["newOwnerUserId"] = .string(successorID) }
            let _: Empty = try await store.mutate("POST", resourcePath("conversations", conversationID, "/leave"), body: body)
            if store.selectedConversationID == conversationID { store.selectedConversationID = nil }
            try await store.refresh()
            dismiss()
        }
    }
    private func previewDelete() async {
        await action.perform { deletion = try await store.mutate("POST", resourcePath("conversations", conversationID, "/preview"), body: ["action": .string("delete")]) }
    }
}
