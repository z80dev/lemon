import SwiftUI
import Observation
import LemonBotKit

@MainActor @Observable
final class ShareImportModel {
    let store: LemonBotStore
    var captures: [SharedCapture] = []
    var conversations: [Conversation] = []
    var error: String?
    var busy = false
    var chosenConversation: [String: ID] = [:]

    init(store: LemonBotStore) { self.store = store }

    func reload() {
        do { captures = try ShareInbox.captures(); error = nil }
        catch { self.error = error.localizedDescription }
    }

    func loadConversations() async {
        guard store.account != nil else { conversations = []; return }
        let accountID = store.account?.id
        do {
            var rows: [Conversation] = []
            var cursor: String?
            repeat {
                var query = ["limit": "200"]
                if let cursor { query["cursor"] = cursor }
                let page: Page<Conversation> = try await store.read("/conversations", query: query)
                guard store.account?.id == accountID else { return }
                rows.append(contentsOf: page.items)
                cursor = page.nextCursor
            } while cursor != nil
            conversations = rows
        } catch { self.error = error.localizedDescription }
    }

    func attach(_ id: String) async {
        guard !busy, var capture = captures.first(where: { $0.id == id }) else { return }
        guard store.connectionState == "online" else { error = "Reconnect before uploading selected files. Local staged content is retained; nothing is queued or sent."; return }
        guard let account = store.account, let user = store.user, let workspace = store.workspace else { error = "Sign in and choose an account before importing."; return }
        guard let conversationID = capture.conversationID ?? chosenConversation[id], !conversationID.isEmpty else { error = "Explicitly select the conversation that will receive this unsent draft."; return }
        if let boundAccount = capture.accountID, boundAccount != account.id || capture.workspaceID != workspace.id || capture.userID != user.id {
            error = "This capture is bound to another account. Switch back to that account to attach it; it will not be moved or uploaded elsewhere."
            return
        }
        busy = true
        error = nil
        defer { busy = false; reloadPreservingError() }
        do {
            // Fetch ACL and load the retained per-chat draft before appending anything.
            try await store.openConversation(conversationID)
            let draft = store.draft(for: conversationID)
            let newlyAttachedCount = capture.files.filter { file in
                guard let attachmentID = file.attachmentID else { return true }
                return !draft.attachmentIDs.contains(attachmentID)
            }.count
            guard draft.attachmentIDs.count + newlyAttachedCount <= 6 else { throw CaptureError.message("This draft would contain more than six attachments. Remove files from the composer or use another capture.") }
            capture.accountID = account.id
            capture.workspaceID = workspace.id
            capture.userID = user.id
            capture.conversationID = conversationID
            capture.error = nil
            try ShareInbox.save(capture)
            for index in capture.files.indices {
                guard store.account?.id == account.id else { throw CaptureError.message("Account changed. Upload stopped; content remains bound to the original account.") }
                if capture.files[index].attachmentID == nil {
                    do {
                        let file = capture.files[index]
                        let attachment = try await store.upload(fileURL: ShareInbox.fileURL(file, in: capture), filename: file.filename, mime: file.mime, metadata: [
                            "conversationId": .string(conversationID), "purpose": .string("message"), "clientNonce": .string(file.uploadNonce)
                        ])
                        capture.files[index].attachmentID = attachment.id
                        capture.files[index].error = nil
                        try ShareInbox.save(capture)
                    } catch {
                        capture.files[index].error = error.localizedDescription
                        throw error
                    }
                }
                if let attachmentID = capture.files[index].attachmentID {
                    let current = store.draft(for: conversationID)
                    if !current.attachmentIDs.contains(attachmentID) {
                        guard store.setLocalDraft(conversationID: conversationID, text: current.text, attachmentIDs: current.attachmentIDs + [attachmentID], replyTo: current.replyToEntryID) else {
                            throw CaptureError.message(store.errorMessage ?? "Could not retain the attachment in this conversation's local draft.")
                        }
                    }
                }
            }
            if !capture.textApplied, !capture.text.isEmpty {
                let current = store.draft(for: conversationID)
                if capture.proposedDraftText == nil {
                    capture.priorDraftText = current.text
                    capture.proposedDraftText = current.text + (current.text.isEmpty ? "" : "\n") + capture.text
                    try ShareInbox.save(capture)
                }
                guard current.text == capture.priorDraftText || current.text == capture.proposedDraftText else {
                    throw CaptureError.message("This draft changed after share import began. Your selected text is retained above; review it against the composer before attaching it manually.")
                }
                guard let text = capture.proposedDraftText,
                      store.setLocalDraft(conversationID: conversationID, text: text, attachmentIDs: current.attachmentIDs, replyTo: current.replyToEntryID) else {
                    throw CaptureError.message(store.errorMessage ?? "Could not retain selected text in this conversation's local draft.")
                }
                capture.textApplied = true
                try ShareInbox.save(capture)
            }
        } catch {
            capture.error = error.localizedDescription
            self.error = error.localizedDescription
            do { try ShareInbox.save(capture) }
            catch { self.error = (self.error ?? "") + "\nCould not save import status: " + error.localizedDescription }
        }
    }

    func discard(_ capture: SharedCapture) {
        do { try ShareInbox.discard(capture); reload() }
        catch { self.error = error.localizedDescription }
    }

    private func reloadPreservingError() {
        do { captures = try ShareInbox.captures() }
        catch { self.error = error.localizedDescription }
    }
}

struct ShareImportView: View {
    @State private var model: ShareImportModel
    @Environment(\.dismiss) private var dismiss
    @State private var discard: SharedCapture?
    init(store: LemonBotStore) { _model = State(initialValue: ShareImportModel(store: store)) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account and destination") {
                    if let account = model.store.account {
                        Text("\(account.displayName) · \(account.email)")
                        Text(account.baseURL.absoluteString).font(.caption)
                    } else { Text("Sign in to Lemon Bot before importing. Your selected files remain stored locally.") }
                    if model.store.accounts.count > 1 {
                        Menu("Switch saved account") {
                            ForEach(model.store.accounts, id: \.id) { account in
                                Button("\(account.displayName) · \(account.baseURL.host ?? "")") {
                                    Task {
                                        do { try await model.store.restoreAccount(account); await model.loadConversations() }
                                        catch { model.error = error.localizedDescription }
                                    }
                                }
                            }
                        }.disabled(model.busy)
                    }
                    Text("Attach uploads only to the explicitly selected conversation and adds content to its unsent composer. Review in chat and press Send separately. Files remain locally staged across launches and chat switches until you discard them.").font(.caption)
                }
                if model.captures.isEmpty { ContentUnavailableView("No staged shares", systemImage: "square.and.arrow.down", description: Text("Use another app's Share sheet or choose Camera, Photos or Files in a conversation.")) }
                ForEach(model.captures) { capture in
                    Section(capture.createdAt.formatted(date: .abbreviated, time: .shortened)) {
                        if !capture.text.isEmpty {
                            Text(capture.text).textSelection(.enabled)
                            if capture.textApplied { Label("Text added to composer", systemImage: "checkmark") }
                        }
                        ForEach(capture.files) { file in
                            VStack(alignment: .leading) {
                                Text(file.filename)
                                Text("\(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)) · \(file.attachmentID == nil ? "Staged locally" : "Uploaded; local copy retained")").font(.caption)
                                if let error = file.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                            }
                        }
                        if let conversationID = capture.conversationID {
                            Text("Bound conversation: \(model.conversations.first(where: { $0.id == conversationID })?.name ?? conversationID)")
                        } else {
                            Picker("Choose conversation", selection: Binding(get: { model.chosenConversation[capture.id] ?? "" }, set: { model.chosenConversation[capture.id] = $0 })) {
                                Text("Select explicitly…").tag("")
                                ForEach(model.conversations) { conversation in Text(conversation.name).tag(conversation.id) }
                            }
                        }
                        if let error = capture.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                        Button("Attach to unsent composer") { Task { await model.attach(capture.id) } }
                            .disabled(model.busy || model.store.connectionState != "online" || model.store.account == nil || (capture.conversationID == nil && (model.chosenConversation[capture.id] ?? "").isEmpty))
                        Button("Discard local staged content", role: .destructive) { discard = capture }.disabled(model.busy)
                    }
                }
                if model.busy { ProgressView("Uploading selected files…") }
                if let error = model.error { Section("Import error") { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
            }
            .navigationTitle("Selected shares")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Discard this local capture? Uploaded attachments and existing composer content are not deleted.", isPresented: Binding(get: { discard != nil }, set: { if !$0 { discard = nil } }), titleVisibility: .visible) {
                Button("Discard staged files", role: .destructive) { if let discard { model.discard(discard) }; discard = nil }
            }
            .task { model.reload(); await model.loadConversations() }
        }
    }
}
