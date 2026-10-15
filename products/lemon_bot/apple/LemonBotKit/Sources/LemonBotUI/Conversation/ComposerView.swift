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
    @State private var messageNonce: String?
    @State private var reconciledRuns: [Run] = []
    @State private var stagedFilenames: [String] = []
    #if os(macOS)
    @FocusState private var focused: Bool
    #else
    @State private var focused = false
    @State private var deliveryDetailsOpen = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
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
    private var resolvedMessage: MessageReceipt? { messageNonce.flatMap { store.reconciledMessageReceipts[$0] } }
    private var unresolvedAction: Bool { action.uncertain && (action.uncertainNonce != messageNonce || resolvedMessage == nil) }
    private var messageUncertain: Bool { pendingMessageNonce != nil || (unresolvedAction && unconfirmedDraft != nil) }
    private var actionError: String? { action.errorNonce == messageNonce && resolvedMessage != nil ? nil : action.error }
    public var body: some View {
        composerContent
            .fileImporter(isPresented: $files, allowedContentTypes: [.item], allowsMultipleSelection: true, onCompletion: handleSelectedFiles)
            #if os(iOS)
            .sheet(isPresented: $deliveryDetailsOpen) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Last send details").font(.headline)
                    if let receipt { receiptDetails(receipt) }
                    ForEach(reconciledRuns) { run in Text("Run \(run.id): \(run.status)").textSelection(.enabled) }
                    Button("Close") { deliveryDetailsOpen = false }.buttonStyle(.pill(.secondary))
                }.padding().frame(maxWidth: .infinity, alignment: .leading)
                    .presentationDetents([.medium, .large])
            }
            #endif
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
            .onChange(of: resolvedMessage) { _, _ in applyMessageReconciliation() }
            .onChange(of: action.uncertainNonce) { _, _ in applyMessageReconciliation() }
    }

    @Environment(\.colorScheme) private var scheme
    private var composerBot: Bot? {
        guard let botID = conversation?.botIds.first else { return nil }
        return store.bots.first { $0.id == botID }
    }
    private var placeholder: String {
        if conversation?.kind == "group", let name = conversation?.name, !name.isEmpty { return "Message \(name)" }
        if let name = composerBot?.name, !name.isEmpty { return "Message \(name)" }
        return "Message your assistant"
    }
    private var draftIsEmpty: Bool { draft.text.isEmpty && draft.attachmentIDs.isEmpty && draft.fileURLs.isEmpty && stagedFilenames.isEmpty }
    private var sendDisabled: Bool {
        !online || action.inFlight || unresolvedAction || pendingMessageNonce != nil || !draft.fileURLs.isEmpty || (draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.attachmentIDs.isEmpty)
    }
    private var multiline: Bool { draft.text.contains("\n") || draft.text.count > 70 }
    private var compactKeyboardLayout: Bool {
        #if os(iOS)
        verticalSizeClass == .compact
        #else
        false
        #endif
    }
    private var hasDeliveryStatus: Bool {
        !online || messageUncertain || action.error != nil || action.uncertain || action.receipt != nil
            || (receipt != nil && !compactKeyboardLayout) || receipt?.status == "outcome_unknown"
            || receipt?.runs.contains(where: { $0.error != nil }) == true
            || (!reconciledRuns.isEmpty && !compactKeyboardLayout) || reconciledRuns.contains(where: { $0.error != nil })
    }

    private var composerContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            contextChips
            pill
            #if os(iOS)
            if hasDeliveryStatus { deliveryStatus }
            #else
            deliveryStatus
            #endif
        }
        .padding(.horizontal, 16)
        #if os(iOS)
        .padding(.bottom, compactKeyboardLayout ? 0 : focused ? 4 : 14)
        #else
        .padding(.bottom, 14)
        #endif
        .frame(maxWidth: LBMetric.transcriptMaxWidth)
        .frame(maxWidth: .infinity)
    }

    private var pill: some View {
        let shape = RoundedRectangle(cornerRadius: multiline ? 22 : 24, style: .continuous)
        return HStack(alignment: .bottom, spacing: 6) {
            plusMenu
            messageInput.padding(.vertical, 7)
            Button { platform("dictation") } label: { Image(systemName: "mic").font(.system(size: 14, weight: .medium)) }
                .buttonStyle(GhostCircleButtonStyle(size: 32, filled: false))
                .keyboardShortcut("d", modifiers: .command).disabled(action.inFlight)
                .accessibilityLabel("Dictate").help("Dictate (⌘D)")
            primaryButton
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .background(LB.raised, in: shape)
        .overlay(shape.strokeBorder(focused ? LB.accent.opacity(0.35) : LB.separator, lineWidth: 1))
        .shadow(color: scheme == .light ? LB.shadow : .clear, radius: 12, y: 4)
    }

    @ViewBuilder private var primaryButton: some View {
        let tint = composerBot?.palette.tint ?? LB.accent
        let onTint = composerBot?.palette.onTint ?? .white
        if draftIsEmpty && voiceAllowed {
            Button { platform("voice") } label: {
                Image(systemName: "waveform").font(.system(size: 14, weight: .bold)).foregroundStyle(onTint).frame(width: 32, height: 32).background(tint, in: Circle())
            }
            .buttonStyle(.plain).disabled(!online).opacity(online ? 1 : 0.4)
            .accessibilityLabel("Voice chat").help("Start a live voice chat")
        } else {
            Button { Task { await send() } } label: {
                Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)).foregroundStyle(onTint).frame(width: 32, height: 32).background(tint, in: Circle())
            }
            .buttonStyle(.plain).keyboardShortcut(.return, modifiers: .command)
            .disabled(sendDisabled).opacity(sendDisabled ? 0.4 : 1)
            .accessibilityLabel("Send").help("Send (⌘↩)")
        }
    }

    private var plusMenu: some View {
        Menu {
            Button("Choose files") { files = true }.disabled(action.inFlight || draft.attachmentIDs.count + draft.fileURLs.count >= 6)
            Button("Paste selected files") { readPastedFiles() }.disabled(action.inFlight || draft.attachmentIDs.count + draft.fileURLs.count >= 6)
            #if os(iOS)
            Button("Camera") { platform("camera") }
            Button("Photo library") { platform("photos") }
            if compactKeyboardLayout && (receipt != nil || !reconciledRuns.isEmpty) {
                Button("Last send details") { deliveryDetailsOpen = true }
            }
            #endif
            Divider()
            Menu("Reference") { referenceItems }
            Menu("Delivery") {
                Picker("Delivery", selection: $mode) {
                    Text("Follow-up").tag("followup")
                    Text("Steer").tag("steer")
                    Text("Interrupt").tag("interrupt")
                }.pickerStyle(.inline)
            }
        } label: {
            Image(systemName: "plus").font(.system(size: 14, weight: .semibold)).foregroundStyle(LB.ink)
                .frame(width: 32, height: 32).background(LB.fill, in: Circle()).contentShape(Circle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Add attachment, reference or delivery option")
    }

    private func chip(_ title: String, symbol: String, tint: Color = LB.muted, removeLabel: String = "Remove", remove: (() -> Void)? = nil) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(title).lineLimit(1).foregroundStyle(LB.ink)
            if let remove {
                Button(action: remove) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(LB.muted) }
                    .buttonStyle(.plain).accessibilityLabel(removeLabel)
            }
        }
        .font(LBFont.chip).padding(.horizontal, 10).padding(.vertical, 5).background(LB.fill, in: Capsule())
    }

    private var hasChips: Bool {
        draft.replyToEntryID != nil || mode != "followup" || !mentions.isEmpty || everyone || !references.isEmpty
            || !draft.attachmentIDs.isEmpty || !draft.fileURLs.isEmpty || !stagedFilenames.isEmpty
    }

    @ViewBuilder private var contextChips: some View {
        if hasChips {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    replyContext
                    deliveryModeChip
                    routingContext
                    attachmentInputs
                }.padding(.horizontal, 4)
            }
        }
    }

    @ViewBuilder private var deliveryModeChip: some View {
        if mode != "followup" {
            chip(mode == "steer" ? "Steer" : "Interrupt", symbol: mode == "steer" ? "arrow.turn.up.right" : "bolt.fill", tint: LB.warning, removeLabel: "Use follow-up delivery") { mode = "followup" }
                .help("\(mode == "steer" ? "Update active work if the worker acknowledges it; otherwise queue a follow-up." : "Request cancellation and a new priority turn.") Completed external effects are not rolled back.")
        }
    }

    @ViewBuilder private var replyContext: some View {
        if let reply = draft.replyToEntryID {
            chip("Replying to \(store.entries[conversationID]?.first(where: { $0.id == reply })?.actor.displayName ?? "message")", symbol: "arrowshape.turn.up.left", removeLabel: "Cancel reply") {
                store.setLocalDraft(conversationID: conversationID, text: draft.text, attachmentIDs: draft.attachmentIDs, replyTo: nil)
            }
        }
    }

    @ViewBuilder private var attachmentInputs: some View {
        ForEach(draft.attachmentIDs, id: \.self) { id in
            HStack(spacing: 6) {
                AttachmentView(store: store, attachmentID: id).frame(maxHeight: 40).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Button { store.setLocalDraft(conversationID: conversationID, text: draft.text, attachmentIDs: draft.attachmentIDs.filter { $0 != id }, replyTo: draft.replyToEntryID) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(LB.muted)
                }.buttonStyle(.plain).accessibilityLabel("Remove attachment")
            }
            .padding(4).background(LB.fill, in: Capsule())
        }
        ForEach(draft.fileURLs, id: \.self) { url in
            chip(url.lastPathComponent + " · not uploaded", symbol: "doc.badge.clock", removeLabel: "Remove local file") {
                Task { await action.perform { try store.removeDraftFile(url, conversationID: conversationID) } }
            }
        }
        if !draft.fileURLs.isEmpty {
            Button("Upload") { Task { await uploadSelectedFiles() } }
                .buttonStyle(.pill(.quiet, compact: true)).disabled(!online || action.busy)
                .help("Upload selected files to this conversation. Reconnecting never uploads or sends these files automatically.")
        }
        if !stagedFilenames.isEmpty {
            chip(stagedFilenames.count == 1 ? stagedFilenames[0] : "\(stagedFilenames.count) files", symbol: "doc.on.doc")
                .help("Selected files awaiting review: \(stagedFilenames.joined(separator: ", ")). These files are local and not uploaded or sent.")
            Button("Review") { platform("shares") }.buttonStyle(.pill(.quiet, compact: true))
        }
    }

    @ViewBuilder private var messageInput: some View {
        #if os(iOS)
        IOSComposerInput(text: text, focused: $focused, maximumLines: verticalSizeClass == .compact ? 2 : compact ? 4 : 8)
            .overlay(alignment: .topLeading) {
                if draft.text.isEmpty {
                    Text(placeholder).font(LBFont.body).foregroundStyle(LB.faint)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
        #else
        TextField(placeholder, text: text, axis: .vertical)
            .lineLimit(compact ? 1...4 : 1...8)
            .textFieldStyle(.plain)
            .font(LBFont.body)
            .foregroundStyle(LB.ink)
            .accessibilityLabel("Unsent message draft")
            .focused($focused)
            .submitLabel(.send)
            .onSubmit { Task { await send() } }
            .onKeyPress(keys: [.return], phases: .down, action: handleComposerKeyPress)
        #endif
    }

    #if os(macOS)
    private func handleComposerKeyPress(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.shift) { return .ignored }
        guard online, !action.busy, pendingMessageNonce == nil, draft.fileURLs.isEmpty,
              !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.attachmentIDs.isEmpty else { return .handled }
        Task { await send() }
        return .handled
    }
    #endif

    @ViewBuilder private var routingContext: some View {
        if everyone { chip("@everyone", symbol: "at", removeLabel: "Remove @everyone") { everyone = false } }
        ForEach(Array(mentions).sorted(), id: \.self) { id in
            chip("@\(store.bots.first(where: { $0.id == id })?.name ?? "bot")", symbol: "at", removeLabel: "Remove mention") { mentions.remove(id) }
        }
        ForEach(references, id: \.id) { reference in
            chip(referenceName(reference), symbol: "link", removeLabel: "Remove reference") { references.removeAll { $0.kind == reference.kind && $0.id == reference.id } }
        }
    }

    private func referenceName(_ reference: Reference) -> String {
        switch reference.kind {
        case "bot": return store.bots.first { $0.id == reference.id }?.name ?? "Bot"
        case "skill": return skills.first { $0.id == reference.id }?.name ?? "Skill"
        case "routine": return routines.first { $0.id == reference.id }?.name ?? "Routine"
        case "connector": return connectors.first { $0.id == reference.id }?.name ?? "App"
        case "group": return store.conversations.first { $0.id == reference.id }?.name ?? "Group"
        default: return reference.kind.capitalized
        }
    }

    @ViewBuilder private var deliveryStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !online { Text("Offline — your draft is saved here.").font(LBFont.meta).foregroundStyle(LB.muted).help("Sending, upload and approvals are never queued automatically.") }
            if messageUncertain {
                HStack(spacing: 8) {
                    Label("Checking whether your last message was sent", systemImage: "exclamationmark.triangle.fill")
                        .font(LBFont.chip).foregroundStyle(LB.warning)
                    Button("Check") { Task { await reconcile() } }.buttonStyle(.pill(.quiet, compact: true)).disabled(!online || action.inFlight)
                }
                .padding(.horizontal, 10).padding(.vertical, 5).background(LB.warning.opacity(0.12), in: Capsule())
                .help("This message is held until its exact submission is confirmed. Nothing is resent.")
            }
            if let receipt {
                ForEach(Array(receipt.delivery.enumerated()), id: \.offset) { _, delivery in
                    if let run = receipt.runs.first(where: { $0.id == delivery.runId }), let error = run.error {
                        ActionErrorView(message: BackendError(status: 0, failure: ErrorEnvelopeError(code: error.code, message: error.message, requestId: error.requestId, retrySafe: error.retrySafe, details: error.details)).localizedDescription)
                    }
                }
                if receipt.status == "outcome_unknown" { Text("Not confirmed yet — don't resend. Check the submission first.").foregroundStyle(LB.warning).font(LBFont.meta) }
                if !compactKeyboardLayout {
                    DisclosureGroup("Details") {
                        VStack(alignment: .leading, spacing: 2) { receiptDetails(receipt) }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.font(LBFont.meta).foregroundStyle(LB.muted)
                }
            }
            ForEach(reconciledRuns) { run in
                if let error = run.error { ActionErrorView(message: BackendError(status: 0, failure: ErrorEnvelopeError(code: error.code, message: error.message, requestId: error.requestId, retrySafe: error.retrySafe, details: error.details)).localizedDescription) }
            }
            if !reconciledRuns.isEmpty && !compactKeyboardLayout {
                DisclosureGroup("Details") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(reconciledRuns) { run in Text("Run \(run.id): \(run.status)").textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.font(LBFont.meta).foregroundStyle(LB.muted)
            }
            ActionErrorView(message: actionError)
            if unresolvedAction && !messageUncertain { Text("An upload isn't confirmed. Nothing is retried automatically — check your files before trying again.").font(LBFont.meta).foregroundStyle(LB.warning) }
            if let receipt = action.receipt { Text(receipt).font(LBFont.meta).foregroundStyle(LB.muted) }
        }.padding(.horizontal, 8)
    }

    @ViewBuilder private func receiptDetails(_ receipt: MessageReceipt) -> some View {
        ForEach(Array(receipt.delivery.enumerated()), id: \.offset) { _, delivery in
            Text("\(store.bots.first(where: { $0.id == delivery.botId })?.name ?? delivery.botId): \(delivery.effectiveMode.replacingOccurrences(of: "_", with: " ").capitalized) · run \(delivery.runId)").textSelection(.enabled)
        }
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
    @ViewBuilder private var referenceItems: some View {
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
    }
    private func addReference(_ kind: String, _ id: ID) {
        if !references.contains(where: { $0.kind == kind && $0.id == id }) { references.append(Reference(kind: kind, id: id)) }
    }
    private func platform(_ action: String) { NotificationCenter.default.post(name: Notification.Name("LemonBot.platformComposerRequest"), object: nil, userInfo: ["conversationID": conversationID, "action": action]) }
    private func loadReferences() async {
        guard store.connectionState != "reconnect_required" else { return }
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
            guard pendingMessageNonce == nil && !unresolvedAction else { throw ComposerError.message("This submission is fenced. Read the exact outcome before any new Send.") }
            let captured = draft
            guard !captured.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !captured.attachmentIDs.isEmpty else { throw ComposerError.message("Write a message or attach a ready file before Send.") }
            guard captured.fileURLs.isEmpty else { throw ComposerError.message("Explicitly upload or remove selected local files before Send.") }
            unconfirmedDraft = captured
            let nonce = UUID().uuidString
            messageNonce = nonce
            let result = try await store.send(conversationID: conversationID, text: captured.text, attachmentIDs: captured.attachmentIDs, replyTo: captured.replyToEntryID, mode: mode, mentions: captured.mentions, everyone: captured.everyone, references: captured.references, clientNonce: nonce)
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
        if action.uncertain {
            if let original = action.uncertainNonce, original != messageNonce { unconfirmedDraft = nil; messageNonce = original }
            if action.uncertainNonce == nil { action.uncertainNonce = messageNonce }
            if action.error != nil { action.errorNonce = messageNonce }
        }
        applyMessageReconciliation()
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
            applyMessageReconciliation(nonce)
        }
    }
    private func applyMessageReconciliation(_ nonce: String? = nil) {
        guard store.account?.id == owningAccountID, let nonce = nonce ?? messageNonce,
              let recorded = store.reconciledMessageReceipts[nonce] else { return }
        if let captured = unconfirmedDraft, matchesDraft(captured) {
            store.setLocalDraft(conversationID: conversationID, text: "", attachmentIDs: [], replyTo: nil)
            store.setLocalComposerRouting(conversationID: conversationID, references: [], mentions: [], everyone: false)
        }
        reconciledRuns = recorded.runs
        action.resolveUncertainty(nonce)
        receipt = nil; unconfirmedDraft = nil
        action.receipt = "The original message is recorded. No content was resubmitted; target errors remain shown."
    }
}
private enum ComposerError: LocalizedError { case message(String); var errorDescription: String? { if case .message(let value) = self { return value }; return nil } }
