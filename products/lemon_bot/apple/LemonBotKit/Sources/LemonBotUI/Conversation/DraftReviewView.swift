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
    @State private var editing = false
    init(store: LemonBotStore, draft: Draft) { self.store = store; self.draft = draft; _content = State(initialValue: draft.content) }
    private var current: Draft { (resolved?.revision ?? 0) > draft.revision ? resolved! : draft }
    private var editable: Bool { current.state == "editable" && current.ownerUserId == store.user?.id && store.connectionState == "online" && store.conversations.first(where: { $0.id == current.conversationId })?.kind != "group" }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(symbol: symbol, title: "Review \(kindName) draft") { StatusBadge(text: current.state) }
            Text("Drafted by \(store.bots.first(where: { $0.id == current.botId })?.name ?? current.botId)").cardMeta()
            if editing && editable { editFields } else { preview }
            ForEach(attachmentIDs, id: \.self) { id in
                HStack(spacing: 8) {
                    AttachmentView(store: store, attachmentID: id)
                    if editing && editable {
                        Button { setAttachments(attachmentIDs.filter { $0 != id }) } label: { Label("Remove file", systemImage: "xmark") }
                            .buttonStyle(GhostCircleButtonStyle(size: 28)).disabled(action.busy)
                    }
                }
            }
            if editing && editable { Button("Add files") { files = true }.buttonStyle(.pill(.secondary, compact: true)).disabled(action.busy) }
            CardNote(symbol: "paperplane", text: "Only Send authorizes these exact recipients, thread, body and files. Saving edits does not send. Reactions, opening and approval policy never send this draft.")
            CardActions {
                Group {
                    Button("Send") { Task { await submit("POST", "/send") } }.buttonStyle(.cardPrimary)
                    if editing {
                        Button("Save edits") { Task { await submit("PATCH", ""); if action.error == nil { editing = false } } }.buttonStyle(.pill(.secondary))
                    } else {
                        Button("Edit") { editing = true }.buttonStyle(.pill(.secondary))
                    }
                    CardMoreMenu {
                        if editing { Button("Revert changes") { content = current.content; editing = false } }
                        Button("Discard draft", role: .destructive) { Task { await submit("POST", "/discard") } }
                    }
                }.disabled(!editable || action.busy)
            }
            if current.state == "sending" { ProgressView("Send authorized · awaiting actual provider confirmation").font(LBFont.meta).foregroundStyle(LB.muted) }
            if current.state == "outcome_unknown" { CardNote(symbol: "exclamationmark.triangle.fill", text: "Send outcome is not confirmed. Inspect the actual provider before any new send. Do not automatically retry or discard a possibly sent message.", tint: LB.warning) }
            if let error = current.error { ActionErrorView(message: error) }
            ActionErrorView(message: action.error)
            CardDetails {
                Text("Owner: \(current.ownerUserId)").textSelection(.enabled)
                Text("Revision \(current.revision)")
                switch content {
                case .email(let email): Text("Email connector: \(email.connectorId)").textSelection(.enabled)
                case .slack(let slack): Text("Slack connector: \(slack.connectorId)").textSelection(.enabled)
                case .message(let message): Text("Channel binding: \(message.channelBindingId)").textSelection(.enabled)
                }
                if let providerID = current.providerMessageId { Text("Confirmed provider message: \(providerID)").textSelection(.enabled) }
            }
        }.fileImporter(isPresented: $files, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result { case .success(let urls): Task { await attach(urls) }; case .failure(let error): action.error = error.localizedDescription }
        }.onChange(of: draft.revision) { old, new in
            // A different device's revision is authoritative. Never overwrite it using a stale revision.
            content = draft.content
            if new > old && draft.state == "editable" { action.uncertain = false }
        }
    }
    private var symbol: String {
        switch content { case .email: return "envelope"; case .slack: return "number"; case .message: return "bubble.left" }
    }
    private var kindName: String {
        switch content { case .email: return "email"; case .slack: return "Slack"; case .message: return "message" }
    }
    private var bodyText: String {
        switch content { case .email(let value): return value.body; case .slack(let value): return value.body; case .message(let value): return value.body }
    }
    /// Read-only preview of exactly what Send would deliver.
    @ViewBuilder private var preview: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch content {
            case .email(let email):
                row("From", email.from)
                row("To", email.to.joined(separator: ", "))
                if !email.cc.isEmpty { row("Cc", email.cc.joined(separator: ", ")) }
                if !email.bcc.isEmpty { row("Bcc", email.bcc.joined(separator: ", ")) }
                row("Subject", email.subject)
            case .slack(let slack):
                row("Workspace", slack.workspace)
                row("To", slack.target)
                row("Thread", slack.thread ?? "None")
            case .message(let message):
                row("To", message.target)
                row("Thread", message.thread ?? "None")
            }
        }.font(LBFont.rowSubtitle).frame(maxWidth: .infinity, alignment: .leading)
        Group { if bodyText.isEmpty { Text("(empty body)").foregroundStyle(LB.muted) } else { Text(bodyText).foregroundStyle(LB.ink) } }
            .font(LBFont.body).lineSpacing(LBFont.bodyLineSpacing).textSelection(.enabled)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(LB.fill))
    }
    private func row(_ key: String, _ value: String) -> some View { cardFact(key, value.isEmpty ? "—" : value).textSelection(.enabled) }
    @ViewBuilder private var editFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch content {
            case .email:
                labeled("From", "From", "from")
                labeled("To", "Comma separated", "to")
                labeled("Cc", "Comma separated", "cc")
                labeled("Bcc", "Comma separated", "bcc")
                labeled("Subject", "Subject", "subject")
            case .slack:
                labeled("Workspace", "Workspace", "workspace")
                labeled("To", "Recipient or channel", "target")
                labeled("Thread", "Blank for no thread", "thread")
            case .message:
                labeled("To", "Recipient or channel", "target")
                labeled("Thread", "Blank for no thread", "thread")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Exact body to send").font(LBFont.metaEmphasis).foregroundStyle(LB.muted)
                TextField("Exact body to send", text: field("body"), axis: .vertical).lineLimit(4...20).cardField()
            }
        }.disabled(action.busy)
    }
    private func labeled(_ label: String, _ placeholder: String, _ name: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(LBFont.metaEmphasis).foregroundStyle(LB.muted)
            TextField(placeholder, text: field(name)).cardField()
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
