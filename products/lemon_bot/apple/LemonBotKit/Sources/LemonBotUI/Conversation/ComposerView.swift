import SwiftUI
import LemonBotKit
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

public struct ComposerView: View {
    private let store: LemonBotStore
    private let conversationID: ID
    private let compact: Bool
    private let owningAccountID: String?
    @State private var action = UIActionState()
    @State private var files = false
    @State private var mode = "followup"
    @State private var skills: [Skill] = []
    @State private var routines: [Routine] = []
    @State private var connectors: [Connector] = []
    @State private var pastedFiles: [URL] = []
    @State private var receipt: MessageReceipt?
    @State private var unconfirmedDraft: LocalComposerDraft?
    @State private var reconciledRuns: [Run] = []
    @State private var stagedFilenames: [String] = []
    @FocusState private var focused: Bool
    public init(store: LemonBotStore, conversationID: ID, compact: Bool = false) {
        self.store = store
        self.conversationID = conversationID
        self.compact = compact
        self.owningAccountID = store.account?.id
    }
    private var draft: LocalComposerDraft { store.draft(for: conversationID) }
    private var text: Binding<String> { Binding(get: { draft.text }, set: { store.setLocalDraft(conversationID: conversationID, text: $0, attachmentIDs: draft.attachmentIDs, replyTo: draft.replyToEntryID) }) }
    private var online: Bool { store.connectionState == "online" && store.account?.id == owningAccountID }
    private var conversation: Conversation? { store.conversations.first { $0.id == conversationID } }
    private var voiceAllowed: Bool {
        guard let conversation, ["dm", "task"].contains(conversation.kind), conversation.ownerUserId == store.user?.id,
              let botID = conversation.botIds.first, let bot = store.bots.first(where: { $0.id == botID }) else { return false }
        return bot.ownerUserId == store.user?.id
    }
    private var mentions: Set<ID> {
        get { Set(draft.mentions) }
        nonmutating set { store.setLocalComposerRouting(conversationID: conversationID, references: references, mentions: newValue.sorted(), everyone: everyone) }
    }
    private var everyone: Bool {
        get { draft.everyone }
        nonmutating set { store.setLocalComposerRouting(conversationID: conversationID, references: references, mentions: mentions.sorted(), everyone: newValue) }
    }
    private var references: [Reference] {
        get { draft.references }
        nonmutating set { store.setLocalComposerRouting(conversationID: conversationID, references: newValue, mentions: mentions.sorted(), everyone: everyone) }
    }
    private var pendingMessageNonce: String? {
        store.pendingIntents.first { $0.method == "POST" && $0.path == resourcePath("conversations", conversationID, "/messages") }?.clientNonce
    }
    private var messageUncertain: Bool { pendingMessageNonce != nil || (action.uncertain && unconfirmedDraft != nil) }
    public var body: some View {
        composerContent
            .fileImporter(isPresented: $files, allowedContentTypes: [.item], allowsMultipleSelection: true, onCompletion: handleSelectedFiles)
            .confirmationDialog("Attach pasted files to this conversation?", isPresented: Binding(get: { !pastedFiles.isEmpty }, set: { if !$0 { pastedFiles = [] } })) {
                Button("Attach \(pastedFiles.count) selected files") { let urls = pastedFiles; pastedFiles = []; Task { await attach(urls) } }
                Button("Cancel", role: .cancel) { pastedFiles = [] }
            } message: { Text(pastedFiles.map(\.lastPathComponent).joined(separator: "\n")) }
            .task(id: conversationID) { await loadReferences() }
            .onAppear { platform("stagedFiles") }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("LemonBot.platformStagedFilesChanged"))) { notice in
                guard notice.userInfo?["conversationID"] as? String == conversationID else { return }
                stagedFilenames = notice.userInfo?["filenames"] as? [String] ?? []
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("LemonBot.focusComposer"))) { notice in
                if notice.userInfo?["conversationID"] as? String == conversationID { focused = true }
            }
            .onDisappear(perform: retainDepartingDraft)
    }

    private var composerContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            replyContext
            attachmentInputs
            messageInput
            routingContext
            composerControls
            deliveryStatus
        }.padding(12)
    }

    @ViewBuilder private var replyContext: some View {
        if let reply = draft.replyToEntryID {
            HStack {
                Label("Reply to \(store.entries[conversationID]?.first(where: { $0.id == reply })?.actor.displayName ?? reply)", systemImage: "arrowshape.turn.up.left")
                Spacer()
                Button("Cancel reply") { store.setLocalDraft(conversationID: conversationID, text: draft.text, attachmentIDs: draft.attachmentIDs, replyTo: nil) }
            }.font(.caption)
        }
    }

    @ViewBuilder private var attachmentInputs: some View {
        ForEach(draft.attachmentIDs, id: \.self) { id in
            HStack {
                AttachmentView(store: store, attachmentID: id)
                Button("Remove", role: .destructive) { store.setLocalDraft(conversationID: conversationID, text: draft.text, attachmentIDs: draft.attachmentIDs.filter { $0 != id }, replyTo: draft.replyToEntryID) }
            }
        }
        ForEach(draft.fileURLs, id: \.self) { url in
            HStack {
                Label(url.lastPathComponent + " · local, not uploaded", systemImage: "doc.badge.clock")
                Button("Remove local file") { Task { await action.perform { try store.removeDraftFile(url, conversationID: conversationID) } } }.disabled(action.inFlight)
            }.font(.caption)
        }
        if !draft.fileURLs.isEmpty {
            Button("Upload selected files to this conversation") { Task { await uploadSelectedFiles() } }.disabled(!online || action.busy)
            Text("Reconnecting never uploads or sends these files automatically.").font(.caption)
        }
        if !stagedFilenames.isEmpty {
            VStack(alignment: .leading) {
                Text("Selected files awaiting review: \(stagedFilenames.joined(separator: ", "))").font(.caption)
                Button("Review selected files") { platform("shares") }
                Text("These files are local and not uploaded or sent.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var messageInput: some View {
        TextField("Message your assistant…", text: text, axis: .vertical)
            .lineLimit(compact ? 1...4 : 2...8)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Unsent message draft")
            .focused($focused)
            .submitLabel(.send)
            .onSubmit { Task { await send() } }
            .onKeyPress(keys: [.return], phases: .down, action: handleComposerKeyPress)
    }

    private func handleComposerKeyPress(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.shift) { return .ignored }
        guard online, !action.busy, pendingMessageNonce == nil, draft.fileURLs.isEmpty,
              !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.attachmentIDs.isEmpty else { return .handled }
        Task { await send() }
        return .handled
    }

    @ViewBuilder private var routingContext: some View {
        if !mentions.isEmpty || everyone || !references.isEmpty {
            Text(routingSummary).font(.caption)
            Button("Clear mentions and references") { mentions = []; everyone = false; references = [] }.font(.caption)
        }
    }

    private var routingSummary: String {
        var labels: [String] = []
        if everyone { labels.append("@everyone") }
        for id in mentions { labels.append("@\(store.bots.first(where: { $0.id == id })?.name ?? id)") }
        for reference in references { labels.append("\(reference.kind):\(reference.id)") }
        return labels.joined(separator: " · ")
    }

    private var composerControls: some View {
        HStack {
            attachMenu
            referenceMenu
            Button { platform("dictation") } label: { Label("Dictate", systemImage: "mic") }
                .keyboardShortcut("d", modifiers: .command).disabled(action.inFlight)
            if draft.text.isEmpty && draft.attachmentIDs.isEmpty && draft.fileURLs.isEmpty && stagedFilenames.isEmpty {
                Button { platform("voice") } label: { Label("Voice", systemImage: "phone") }
                    .disabled(!online || !voiceAllowed)
                    .help("Live voice requires your own private Bot conversation, not a group or channel.")
            }
            Spacer()
            if !compact {
                Picker("Delivery", selection: $mode) {
                    Text("Follow-up").tag("followup")
                    Text("Steer").tag("steer")
                    Text("Interrupt").tag("interrupt")
                }.frame(maxWidth: 150)
            }
            Button("Send", systemImage: "arrow.up") { Task { await send() } }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!online || action.busy || pendingMessageNonce != nil || !draft.fileURLs.isEmpty || (draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.attachmentIDs.isEmpty))
        }.buttonStyle(.borderless)
    }

    private var attachMenu: some View {
        Menu {
            Button("Choose files") { files = true }
            Button("Paste selected files") { readPastedFiles() }
            #if os(iOS)
            Button("Camera") { platform("camera") }
            Button("Photo library") { platform("photos") }
            #endif
        } label: { Label("Attach", systemImage: "paperclip") }
            .disabled(action.inFlight || draft.attachmentIDs.count + draft.fileURLs.count >= 6)
    }

    @ViewBuilder private var deliveryStatus: some View {
        if mode != "followup" { Text("\(mode == "steer" ? "Update active work if the worker acknowledges it; otherwise queue a follow-up." : "Request cancellation and a new priority turn.") Completed external effects are not rolled back.").font(.caption).foregroundStyle(.secondary) }
        if !online { Text("Offline · your draft stays here. Sending, upload and approvals are never queued automatically.").font(.caption).foregroundStyle(.orange) }
        if let receipt {
            ForEach(Array(receipt.delivery.enumerated()), id: \.offset) { _, delivery in
                Text("\(store.bots.first(where: { $0.id == delivery.botId })?.name ?? delivery.botId): \(delivery.effectiveMode.replacingOccurrences(of: "_", with: " ").capitalized) · run \(delivery.runId)").font(.caption).textSelection(.enabled)
                if let run = receipt.runs.first(where: { $0.id == delivery.runId }), let error = run.error {
                    ActionErrorView(message: BackendError(status: 0, failure: ErrorEnvelopeError(code: error.code, message: error.message, requestId: error.requestId, retrySafe: error.retrySafe, details: error.details)).localizedDescription)
                }
            }
            if receipt.status == "outcome_unknown" { Text("Outcome not confirmed. Do not resend; inspect the retained run and provider before another action.").foregroundStyle(.orange).font(.caption) }
        }
        if messageUncertain {
            Text("This intent is fenced until its exact nonce/run is reconciled. No new Send is allowed for a possibly accepted message.").font(.caption).foregroundStyle(.orange)
            Button("Check exact submission · never resend") { Task { await reconcile() } }.disabled(!online || action.inFlight)
        }
        ForEach(reconciledRuns) { run in
            Text("Authoritative run \(run.id): \(run.status)").font(.caption).textSelection(.enabled)
            if let error = run.error { ActionErrorView(message: BackendError(status: 0, failure: ErrorEnvelopeError(code: error.code, message: error.message, requestId: error.requestId, retrySafe: error.retrySafe, details: error.details)).localizedDescription) }
        }
        ActionErrorView(message: action.error)
        if action.uncertain && !messageUncertain { Text("An upload outcome is unconfirmed. No upload is retried automatically; inspect authorized files before another attempt.").font(.caption).foregroundStyle(.orange) }
        if let receipt = action.receipt { Text(receipt).font(.caption) }
    }

    private func handleSelectedFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls): Task { await attach(urls) }
        case .failure(let error): action.error = error.localizedDescription
        }
    }

    private func retainDepartingDraft() {
        let captured = draft
        guard online else { return }
        Task {
            guard online else { return }
            do { try await store.saveDraft(conversationID: conversationID, text: captured.text, attachmentIDs: captured.attachmentIDs, replyTo: captured.replyToEntryID) }
            catch { if store.account?.id == owningAccountID { store.errorMessage = error.localizedDescription } }
        }
    }
    private var referenceMenu: some View {
        Menu {
            if conversation?.kind == "group" {
                Toggle("@everyone", isOn: Binding(get: { everyone }, set: { everyone = $0 }))
                ForEach(store.bots.filter { conversation?.botIds.contains($0.id) == true }) { bot in
                    Button("@\(bot.name)\(mentions.contains(bot.id) ? " ✓" : "")") { if mentions.contains(bot.id) { mentions.remove(bot.id) } else { mentions.insert(bot.id) } }
                }
            }
            Menu("Bots") { ForEach(store.bots) { bot in Button(bot.name) { addReference("bot", bot.id) } } }
            Menu("Skills /") { ForEach(skills) { skill in Button(skill.name) { addReference("skill", skill.id) } } }
            Menu("Routines") { ForEach(routines) { routine in Button(routine.name) { addReference("routine", routine.id) } } }
            Menu("Apps") { ForEach(connectors) { connector in Button("\(connector.name) · \(connector.accountLabel)") { addReference("connector", connector.id) } } }
            Menu("Groups") { ForEach(store.conversations.filter { $0.kind == "group" }) { group in Button(group.name) { addReference("group", group.id) } } }
        } label: { Label("Reference", systemImage: "at") }
    }
    private func addReference(_ kind: String, _ id: ID) {
        if !references.contains(where: { $0.kind == kind && $0.id == id }) { references.append(Reference(kind: kind, id: id)) }
    }
    private func platform(_ action: String) { NotificationCenter.default.post(name: Notification.Name("LemonBot.platformComposerRequest"), object: nil, userInfo: ["conversationID": conversationID, "action": action]) }
    private func loadReferences() async {
        await action.perform {
            skills = try await allResources(store, "/skills")
            routines = try await allResources(store, "/routines")
            if let botID = conversation?.botIds.first {
                connectors = try await allResources(store, resourcePath("bots", botID, "/connectors"))
            }
        }
    }
    private func readPastedFiles() {
        #if os(macOS)
        pastedFiles = (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        #else
        pastedFiles = UIPasteboard.general.urls?.filter(\.isFileURL) ?? []
        #endif
        if pastedFiles.isEmpty { action.error = "No selected files are on the clipboard. Choose files explicitly; clipboard history is never captured." }
    }
    private func attach(_ urls: [URL]) async {
        await action.perform {
            guard draft.attachmentIDs.count + draft.fileURLs.count + urls.count <= 6 else { throw ComposerError.message("A message can contain at most six files.") }
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                _ = try store.stageDraftFile(url, conversationID: conversationID)
            }
        }
    }
    private func uploadSelectedFiles() async {
        await action.perform {
            guard online else { throw ComposerError.message("Reconnect before explicit upload. Nothing was queued.") }
            for url in draft.fileURLs {
                guard online else { throw ComposerError.message("The account or connection changed. Remaining selected files were not uploaded.") }
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                let attachment = try await store.upload(fileURL: url, mime: mime, metadata: ["conversationId": .string(conversationID), "purpose": .string("message")])
                guard store.account?.id == owningAccountID else { throw ComposerError.message("The upload belongs to the previous account; its receipt was not attached to this account.") }
                guard store.setLocalDraft(conversationID: conversationID, text: draft.text, attachmentIDs: draft.attachmentIDs + [attachment.id], replyTo: draft.replyToEntryID) else { throw ComposerError.message(store.errorMessage ?? "Local draft retention failed; upload receipt is not discarded.") }
                try store.removeDraftFile(url, conversationID: conversationID)
            }
        }
    }
    private func matchesDraft(_ captured: LocalComposerDraft) -> Bool {
        draft.text == captured.text && draft.attachmentIDs == captured.attachmentIDs && draft.replyToEntryID == captured.replyToEntryID && draft.references == captured.references && Set(draft.mentions) == Set(captured.mentions) && draft.everyone == captured.everyone && draft.fileURLs == captured.fileURLs
    }
    private func send() async {
        await action.perform {
            guard online else { throw ClientError.offline }
            guard pendingMessageNonce == nil && !action.uncertain else { throw ComposerError.message("This submission is fenced. Read the exact outcome before any new Send.") }
            let captured = draft
            guard !captured.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !captured.attachmentIDs.isEmpty else { throw ComposerError.message("Write a message or attach a ready file before Send.") }
            guard captured.fileURLs.isEmpty else { throw ComposerError.message("Explicitly upload or remove selected local files before Send.") }
            unconfirmedDraft = captured
            let result = try await store.send(conversationID: conversationID, text: captured.text, attachmentIDs: captured.attachmentIDs, replyTo: captured.replyToEntryID, mode: mode, mentions: captured.mentions, everyone: captured.everyone, references: captured.references)
            guard store.account?.id == owningAccountID else { return }
            receipt = result
            if result.status == "outcome_unknown" { action.uncertain = true; action.uncertainNonce = result.clientNonce }
            if result.status != "outcome_unknown" {
                if matchesDraft(captured) {
                    store.setLocalDraft(conversationID: conversationID, text: "", attachmentIDs: [], replyTo: nil)
                    store.setLocalComposerRouting(conversationID: conversationID, references: [], mentions: [], everyone: false)
                }
                unconfirmedDraft = nil
            }
        }
    }
    private func reconcile() async {
        await action.perform {
            guard online else { throw ClientError.offline }
            var nonce = pendingMessageNonce ?? action.uncertainNonce ?? receipt?.clientNonce
            if nonce == nil, let id = action.uncertainRunID {
                let run: Run = try await store.read(resourcePath("runs", id))
                guard run.conversationId == conversationID else { return }
                nonce = run.clientNonce
            }
            guard let nonce else {
                action.receipt = "The server did not provide a submission identifier. Reload this conversation and inspect provider outcomes; this draft remains fenced."
                return
            }
            let settled = try await store.reconcileMutation(nonce)
            guard store.account?.id == owningAccountID else { return }
            reconciledRuns = store.runs.filter { $0.conversationId == conversationID && $0.clientNonce == nonce }
            guard settled else { return }
            if let captured = unconfirmedDraft, matchesDraft(captured) {
                store.setLocalDraft(conversationID: conversationID, text: "", attachmentIDs: [], replyTo: nil)
                store.setLocalComposerRouting(conversationID: conversationID, references: [], mentions: [], everyone: false)
            }
            action.uncertain = false; action.uncertainNonce = nil; action.uncertainRunID = nil
            receipt = nil; unconfirmedDraft = nil
            action.receipt = "The original submission is recorded. No content was resubmitted. Review any retained draft before deliberately sending a new intent."
        }
    }
}
private enum ComposerError: LocalizedError { case message(String); var errorDescription: String? { if case .message(let value) = self { return value }; return nil } }
