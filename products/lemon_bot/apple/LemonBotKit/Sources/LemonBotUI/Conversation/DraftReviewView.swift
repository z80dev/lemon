import SwiftUI
import LemonBotKit
import UniformTypeIdentifiers

struct DraftReviewView: View {
    let store: LemonBotStore
    let draft: Draft
    @State private var content: DraftContent
    @State private var resolved: Draft?
    @State private var action = UIActionState()
    @State private var files = false
    init(store: LemonBotStore, draft: Draft) { self.store = store; self.draft = draft; _content = State(initialValue: draft.content) }
    private var current: Draft { (resolved?.revision ?? 0) > draft.revision ? resolved! : draft }
    private var editable: Bool { current.state == "editable" && current.ownerUserId == store.user?.id && store.connectionState == "online" && store.conversations.first(where: { $0.id == current.conversationId })?.kind != "group" }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Review outward draft", systemImage: "envelope.badge").font(.headline)
            StatusBadge(text: current.state)
            Text("Bot \(store.bots.first(where: { $0.id == current.botId })?.name ?? current.botId) · owner \(current.ownerUserId) · revision \(current.revision)").font(.caption)
            VStack(alignment: .leading, spacing: 8) {
                switch content {
                case .email(let email):
                    Text("Email · connector \(email.connectorId)").font(.caption)
                    TextField("From", text: field("from"))
                    TextField("To (comma separated)", text: field("to"))
                    TextField("Cc (comma separated)", text: field("cc"))
                    TextField("Bcc (comma separated)", text: field("bcc"))
                    TextField("Subject", text: field("subject"))
                case .slack(let slack):
                    Text("Slack · connector \(slack.connectorId)").font(.caption)
                    TextField("Workspace", text: field("workspace"))
                    TextField("Recipient or channel", text: field("target"))
                    TextField("Thread (blank for no thread)", text: field("thread"))
                case .message(let message):
                    Text("Message · channel binding \(message.channelBindingId)").font(.caption)
                    TextField("Recipient or channel", text: field("target"))
                    TextField("Thread (blank for no thread)", text: field("thread"))
                }
                TextField("Exact body to send", text: field("body"), axis: .vertical).lineLimit(4...20)
                ForEach(attachmentIDs, id: \.self) { id in
                    HStack {
                        AttachmentView(store: store, attachmentID: id)
                        Button("Remove file", role: .destructive) { setAttachments(attachmentIDs.filter { $0 != id }) }
                    }
                }
                Button("Choose draft files") { files = true }
            }.textFieldStyle(.roundedBorder).disabled(!editable || action.busy)
            Text("Only explicit Send authorizes these exact edited recipients, thread, body and files. Save edits does not send. Reaction, opening and approval policy never send this draft.").font(.caption)
            HStack {
                Button("Save edits") { Task { await submit("PATCH", "") } }
                Button("Send") { Task { await submit("POST", "/send") } }
                Button("Discard", role: .destructive) { Task { await submit("POST", "/discard") } }
            }.disabled(!editable || action.busy)
            if current.state == "sending" { ProgressView("Send authorized · awaiting actual provider confirmation") }
            if current.state == "outcome_unknown" { Text("Send outcome is not confirmed. Inspect the actual provider before any new send. Do not automatically retry or discard a possibly sent message.").foregroundStyle(.orange) }
            if let error = current.error { ActionErrorView(message: error) }
            if let providerID = current.providerMessageId { Text("Confirmed provider message: \(providerID)").font(.caption).textSelection(.enabled) }
            ActionErrorView(message: action.error)
        }.fileImporter(isPresented: $files, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result { case .success(let urls): Task { await attach(urls) }; case .failure(let error): action.error = error.localizedDescription }
        }.onChange(of: draft.revision) { old, new in
            // A different device's revision is authoritative. Never overwrite it using a stale revision.
            content = draft.content
            if new > old && draft.state == "editable" { action.uncertain = false }
        }
    }
    private var attachmentIDs: [ID] {
        switch content { case .email(let value): return value.attachmentIds; case .slack(let value): return value.attachmentIds; case .message(let value): return value.attachmentIds }
    }
    private func setAttachments(_ ids: [ID]) {
        switch content {
        case .email(var value): value.attachmentIds = ids; content = .email(value)
        case .slack(var value): value.attachmentIds = ids; content = .slack(value)
        case .message(var value): value.attachmentIds = ids; content = .message(value)
        }
    }
    private func field(_ name: String) -> Binding<String> {
        Binding(get: {
            switch content {
            case .email(let value):
                switch name { case "from": return value.from; case "to": return value.to.joined(separator: ", "); case "cc": return value.cc.joined(separator: ", "); case "bcc": return value.bcc.joined(separator: ", "); case "subject": return value.subject; default: return value.body }
            case .slack(let value):
                switch name { case "workspace": return value.workspace; case "target": return value.target; case "thread": return value.thread ?? ""; default: return value.body }
            case .message(let value):
                switch name { case "target": return value.target; case "thread": return value.thread ?? ""; default: return value.body }
            }
        }, set: { text in
            switch content {
            case .email(var value):
                switch name { case "from": value.from = text; case "to": value.to = recipients(text); case "cc": value.cc = recipients(text); case "bcc": value.bcc = recipients(text); case "subject": value.subject = text; default: value.body = text }
                content = .email(value)
            case .slack(var value):
                switch name { case "workspace": value.workspace = text; case "target": value.target = text; case "thread": value.thread = text.isEmpty ? nil : text; default: value.body = text }
                content = .slack(value)
            case .message(var value):
                switch name { case "target": value.target = text; case "thread": value.thread = text.isEmpty ? nil : text; default: value.body = text }
                content = .message(value)
            }
        })
    }
    private func recipients(_ text: String) -> [String] { text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    private func submit(_ method: String, _ suffix: String) async {
        await action.perform {
            var body: JSONObject = ["revision": .number(Double(current.revision))]
            if suffix != "/discard" { body["content"] = .object(try wireObject(content)) }
            let result: Draft = try await store.mutate(method, resourcePath("drafts", current.id, suffix), body: body)
            resolved = result
            content = result.content
        }
    }
    private func attach(_ urls: [URL]) async {
        await action.perform {
            guard editable else { return }
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let result = try await store.upload(fileURL: url, mime: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream", metadata: ["conversationId": .string(current.conversationId), "purpose": .string("message")])
                setAttachments(attachmentIDs + [result.id])
            }
        }
    }
}
