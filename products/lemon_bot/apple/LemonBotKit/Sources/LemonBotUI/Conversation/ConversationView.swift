import SwiftUI
import LemonBotKit

public struct ConversationView: View {
    private let store: LemonBotStore
    private let conversationID: ID
    private let externalInspector: InspectorPresentation?
    @State private var ownInspector = InspectorPresentation()
    @State private var action = UIActionState()
    @State private var olderCursor: String?
    @State private var findOpen = false
    @State private var find = ""
    @State private var findIndex = 0
    @State private var groupEdit = false
    @State private var confirmation: Confirmation?
    @State private var renderedReadSeq = 0
    @State private var readTarget = 0
    @State private var readInFlight = false
    @State private var jumpID: ID?
    @State private var jumpTick = 0
    @State private var flashID: ID?
    @State private var pinTick = 0
    @State private var searchChat = false
    @State private var details = false
    @State private var loadedRuns: [Run] = []
    @State private var runsError: String?
    @State private var unreadFromSeq: Int?
    @State private var atBottom = true
    @State private var leftBottomAt = Date.distantPast
    @State private var hasNewBelow = false
    @State private var settled = false
    @State private var toast: StatusToast?
    @Environment(\.lbReduceMotion) private var reduceMotion

    private static let bottomID = "transcript-bottom"
    #if os(macOS)
    private static let topInset: CGFloat = 64
    #else
    private static let topInset: CGFloat = 12
    #endif

    public init(store: LemonBotStore, conversationID: ID) { self.store = store; self.conversationID = conversationID; self.externalInspector = nil }
    init(store: LemonBotStore, conversationID: ID, inspector: InspectorPresentation) { self.store = store; self.conversationID = conversationID; self.externalInspector = inspector }

    private var inspector: InspectorPresentation { externalInspector ?? ownInspector }
    private var conversation: Conversation? { store.conversations.first { $0.id == conversationID } }
    private var entries: [TranscriptEntry] { (store.entries[conversationID] ?? []).sorted { $0.seq < $1.seq } }
    private var bot: Bot? { store.bot(for: conversation) }
    private var isGroup: Bool { (conversation?.botIds.count ?? 0) > 1 || ["group", "channel"].contains(conversation?.kind ?? "") }
    private var title: String {
        if let name = conversation?.name, !name.isEmpty, conversation?.kind != "dm" { return name }
        if let bot { return bot.name }
        if let name = conversation?.name, !name.isEmpty { return name }
        return "Conversation"
    }
    private var headerBots: [Bot] {
        let list = (conversation?.botIds ?? []).compactMap { id in store.bots.first { $0.id == id } }
        return list.count > 1 ? list : (bot.map { [$0] } ?? [])
    }
    private var palette: BotPalette { (bot ?? store.bots.first)?.palette ?? BotPalette.named(nil) }
    private var isWorking: Bool { store.isOnline && (!store.liveRuns(in: conversationID).isEmpty || ["working", "making"].contains(bot?.activity ?? "")) }
    private var runs: [Run] {
        var byID = Dictionary(loadedRuns.map { ($0.id, $0) }, uniquingKeysWith: { first, second in first.revision >= second.revision ? first : second })
        for run in store.runs where run.conversationId == conversationID && run.revision >= (byID[run.id]?.revision ?? 0) { byID[run.id] = run }
        return Array(byID.values)
    }
    private var activeRuns: [Run] { store.runs.filter { $0.conversationId == conversationID && stoppableRunStatuses.contains($0.status) } }
    private var showTyping: Bool {
        let live = store.liveRuns(in: conversationID)
        guard live.contains(where: { $0.status != "awaiting_input" }) else { return false }
        return !(store.entries[conversationID] ?? []).sorted { $0.seq < $1.seq }.suffix(5).contains { $0.streaming }
    }
    private var visibleError: String? { action.error ?? store.errorMessage }
    private var canMutate: Bool { store.connectionState == "online" }
    private var ownsConversation: Bool { conversation?.ownerUserId == store.user?.id }

    // MARK: Body

    public var body: some View {
        content
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(LB.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) { headerPill(floating: false) }
                ToolbarItem(placement: .topBarTrailing) { actionsMenu }
            }
            #endif
            .task(id: conversationID) { await open() }
            .onAppear { NotificationCenter.default.post(name: Notification.Name("LemonBot.visibleConversationChanged"), object: nil, userInfo: ["conversationID": conversationID]) }
            .onDisappear {
                NotificationCenter.default.post(name: Notification.Name("LemonBot.visibleConversationChanged"), object: nil, userInfo: ["conversationID": NSNull()])
            }
            .sheet(isPresented: $groupEdit) { GroupEditorView(store: store, conversation: conversation) }
            .sheet(isPresented: $searchChat) { NavigationStack { SearchHubView(store: store, conversationID: conversationID) } }
            .sheet(isPresented: $details) { ConversationDetailsView(store: store, conversationID: conversationID) }
            .sheet(isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
                if let confirmation { ScopeConfirmationView(store: store, confirmation: confirmation, title: "Delete conversation") { body in
                    let _: Deleted = try await store.mutate("DELETE", resourcePath("conversations", conversationID), body: body)
                    store.selectedConversationID = nil
                    try await store.refresh()
                } }
            }
            .inspector(isPresented: Binding(get: { inspector.isPresented && bot != nil }, set: { inspector.isPresented = $0 })) {
                if let bot {
                    BotInspectorView(store: store, botID: bot.id, presentation: inspector)
                        .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
                }
            }
    }

    private var content: some View {
        let entries = self.entries
        let rows = TranscriptLayout.rows(entries: entries, runs: runs, unreadFromSeq: unreadFromSeq ?? ((conversation?.unreadCount ?? 0) > 0 ? (conversation?.lastReadSeq ?? 0) + 1 : nil))
        let matches = findMatches(entries)
        let current = matches.isEmpty ? nil : matches[min(max(findIndex, 0), matches.count - 1)]
        return VStack(spacing: 0) {
            transcript(rows, entries: entries, typing: showTyping, highlight: findOpen && !find.isEmpty ? current : flashID)
            bottomStack
        }
        .background(LB.canvas)
        .overlay(alignment: .top) { chrome(matches: matches, current: current) }
        .background { shortcuts }
    }

    // MARK: Transcript

    private struct TailSignature: Equatable { var rowID: String?; var revision: Int; var textCount: Int; var typing: Bool }

    @ViewBuilder private func transcript(_ rows: [TranscriptRow], entries: [TranscriptEntry], typing: Bool, highlight: ID?) -> some View {
        let anchors = Dictionary(rows.flatMap { row in row.entryIDs.map { ($0, row.id) } }, uniquingKeysWith: { first, _ in first })
        let last = entries.last
        let tail = TailSignature(rowID: rows.last?.id, revision: last?.revision ?? 0, textCount: last?.text?.count ?? 0, typing: typing)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if olderCursor != nil {
                        Button("Load older messages") {
                            Task {
                                let first = rows.first?.id
                                await loadOlder()
                                await Task.yield()
                                if let first { proxy.scrollTo(first, anchor: .top) }
                            }
                        }.buttonStyle(.pill(.secondary, compact: true)).disabled(action.busy)
                            .frame(maxWidth: .infinity).padding(.bottom, 12)
                    }
                    ForEach(rows) { row in
                        rowView(row, highlight: highlight)
                            .padding(.top, row.topGap)
                            .id(row.id)
                            .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .bottom)))
                    }
                    if typing {
                        TypingBubble().frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8).id("typing")
                            .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .bottom)))
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                        .onAppear { atBottom = true; hasNewBelow = false }
                        .onDisappear { leftBottomAt = .now; atBottom = false }
                }
                .frame(maxWidth: LBMetric.transcriptMaxWidth)
                .padding(.horizontal, 20).padding(.top, Self.topInset).padding(.bottom, 12)
                .frame(maxWidth: .infinity)
                .animation(settled && !reduceMotion ? LBMotion.spring : nil, value: rows.map(\.id) + [typing ? "typing" : ""])
            }
            .defaultScrollAnchor(.bottom)
            .overlay(alignment: .bottom) {
                if !atBottom && !rows.isEmpty {
                    JumpToLatestPill(hasNew: hasNewBelow, tint: palette) {
                        hasNewBelow = false
                        withAnimation(reduceMotion ? nil : LBMotion.spring) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    }.padding(.bottom, 10).transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .lbAnimation(LBMotion.snappy, value: atBottom)
            .overlay { if rows.isEmpty && !typing && !action.inFlight { emptyHint } }
            .onChange(of: tail) { old, new in
                let mineArrived = old.rowID != new.rowID && last.map(isMine) == true
                follow(proxy, animated: old.rowID != new.rowID || old.typing != new.typing, force: mineArrived)
            }
            .onChange(of: jumpTick) { _, _ in
                guard let id = jumpID else { return }
                let target = anchors[id] ?? id
                Task { @MainActor in
                    await Task.yield()
                    withAnimation(reduceMotion ? nil : LBMotion.spring) { proxy.scrollTo(target, anchor: .center) }
                }
            }
            .onChange(of: pinTick) { _, _ in
                Task { @MainActor in await Task.yield(); proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onChange(of: store.navigationTarget?.entryID) { _, _ in Task { await loadTargetEntry() } }
            .task(id: flashID) {
                guard flashID != nil else { return }
                try? await Task.sleep(for: .seconds(2.5))
                if !Task.isCancelled { flashID = nil }
            }
        }
    }

    private func isMine(_ entry: TranscriptEntry) -> Bool {
        entry.actor.kind == "user" && (entry.actor.id == nil || entry.actor.id == store.user?.id || store.user == nil)
    }

    private func follow(_ proxy: ScrollViewProxy, animated: Bool, force: Bool) {
        let following = force || atBottom || Date().timeIntervalSince(leftBottomAt) < 0.2
        guard following else { if settled { hasNewBelow = true }; return }
        Task { @MainActor in
            await Task.yield()
            if animated && settled && !reduceMotion { withAnimation(LBMotion.spring) { proxy.scrollTo(Self.bottomID, anchor: .bottom) } }
            else { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
        }
    }

    @ViewBuilder private func rowView(_ row: TranscriptRow, highlight: ID?) -> some View {
        switch row.kind {
        case .separator(let date):
            Text(separatorDate(date)).font(LBFont.meta).foregroundStyle(LB.faint)
                .frame(maxWidth: .infinity).padding(.top, 20).padding(.bottom, 8)
        case .unread:
            UnreadDivider()
        case .entry(let entry):
            TranscriptEntryView(store: store, entry: entry, bot: bot, showsName: isGroup && row.startsGroup, highlighted: highlight == entry.id)
                .onAppear { Task { await markRendered(entry.seq) } }
        case .tools(let tools):
            ToolActivityRow(tools: tools).onAppear { Task { await markRendered(row.seq) } }
        case .failure(let run):
            RunFailureRow(run: run, retry: { retry(run) }, loadError: runsError)
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            if let bot { BotAvatarView(store: store, bot: bot).frame(width: 64, height: 64) } else { LemonMark(size: 64) }
            Text("Message \(title)").font(LBFont.rowSubtitle).foregroundStyle(LB.muted)
        }.accessibilityElement(children: .combine)
    }

    // MARK: Bottom stack

    private var bottomStack: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                if let message = visibleError {
                    HStack(alignment: .top, spacing: 6) {
                        ActionErrorView(message: message)
                        Button { action.error = nil; store.errorMessage = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(GhostCircleButtonStyle(size: 24, filled: false)).accessibilityLabel("Dismiss error")
                    }
                }
                if let toast {
                    ToastLine(toast: toast, persistent: toast.text == "Stopping…" && action.inFlight) { self.toast = nil }
                }
                if let step = store.currentStep(in: conversationID) {
                    LiveWorkingRow(step: step, canStop: !activeRuns.isEmpty && canMutate, stopping: action.busy,
                                   onStop: { Task { await stop() } }, onOpen: { inspector.show(.activity) })
                }
            }
            .frame(maxWidth: LBMetric.transcriptMaxWidth)
            .padding(.horizontal, 16).padding(.top, 4)
            .frame(maxWidth: .infinity)
            .lbAnimation(LBMotion.snappy, value: store.currentStep(in: conversationID))
            ComposerView(store: store, conversationID: conversationID).id(conversationID)
        }
    }

    // MARK: Chrome

    private func headerPill(floating: Bool) -> some View {
        ConversationHeaderPill(store: store, bots: headerBots, title: title, working: isWorking, floating: floating) { inspector.toggle() }
    }

    @ViewBuilder private func chrome(matches: [ID], current: ID?) -> some View {
        #if os(macOS)
        ZStack(alignment: .top) {
            headerPill(floating: true).padding(.top, 10)
            HStack { Spacer(); actionsMenu.background(Circle().fill(LB.raised)) }.padding(.top, 8).padding(.trailing, 14)
            if findOpen { findBar(matches: matches, current: current).padding(.top, 52).transition(.opacity.combined(with: .move(edge: .top))) }
        }
        .lbAnimation(LBMotion.snappy, value: findOpen)
        #else
        if findOpen { findBar(matches: matches, current: current).padding(.top, 8).transition(.opacity.combined(with: .move(edge: .top))) }
        #endif
    }

    private func findBar(matches: [ID], current: ID?) -> some View {
        TranscriptFindBar(
            query: $find, matchCount: matches.count, position: current.flatMap { matches.firstIndex(of: $0) }.map { $0 + 1 } ?? 0,
            onPrevious: { stepFind(-1) }, onNext: { stepFind(1) }, onClose: closeFind
        ).onChange(of: find) { _, _ in
            let matches = findMatches(entries)
            findIndex = max(matches.count - 1, 0)
            if let last = matches.last { jump(to: last) }
        }
    }

    private var actionsMenu: some View {
        Menu {
            Button { details = true } label: { Label("Details, media and my export consent", systemImage: "info.circle") }
            Button { openFind() } label: { Label("Find in chat", systemImage: "magnifyingglass") }
            Button { searchChat = true } label: { Label("Search this chat…", systemImage: "text.magnifyingglass") }
            Divider()
            Button { Task { await createTask() } } label: { Label("New task", systemImage: "checklist") }.disabled(bot == nil || !canMutate)
            if conversation?.kind == "group" && ownsConversation {
                Button { groupEdit = true } label: { Label("Edit group members", systemImage: "person.2") }.disabled(!canMutate)
            }
            Button { Task { await markUnread() } } label: { Label("Mark unread", systemImage: "circle.fill") }.disabled(!canMutate)
            if !activeRuns.isEmpty {
                Button { Task { await stop() } } label: { Label("Stop", systemImage: "stop.fill") }.disabled(action.busy || !canMutate)
            }
            if ownsConversation {
                Divider()
                Button(role: .destructive) { Task { await previewDelete() } } label: { Label("Delete conversation…", systemImage: "trash") }.disabled(!canMutate)
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        #if os(macOS)
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(GhostCircleButtonStyle(size: 32, filled: true)).fixedSize()
        #endif
        .accessibilityLabel("Conversation options")
    }

    /// Keyboard shortcuts that must work without the menu being open.
    private var shortcuts: some View {
        ZStack {
            Button("Find in chat") { findOpen ? closeFind() : openFind() }.keyboardShortcut("f", modifiers: .command)
            Button("Focus composer") { focusComposer() }.keyboardShortcut("i", modifiers: .command)
        }.opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }

    // MARK: Find

    private func findMatches(_ entries: [TranscriptEntry]) -> [ID] {
        guard findOpen, !find.isEmpty else { return [] }
        return entries.filter { !TranscriptLayout.isHiddenEmpty($0) && $0.text?.localizedCaseInsensitiveContains(find) == true }.map(\.id)
    }
    private func openFind() { findOpen = true }
    private func closeFind() { findOpen = false; find = ""; findIndex = 0 }
    private func stepFind(_ delta: Int) {
        let matches = findMatches(entries)
        guard !matches.isEmpty else { return }
        findIndex = ((min(max(findIndex, 0), matches.count - 1) + delta) % matches.count + matches.count) % matches.count
        jump(to: matches[findIndex])
    }
    private func jump(to id: ID) { jumpID = id; jumpTick += 1 }
    private func focusComposer() {
        NotificationCenter.default.post(name: Notification.Name("LemonBot.focusComposer"), object: nil, userInfo: ["conversationID": conversationID])
    }

    // MARK: Loading

    private func open() async {
        settled = false; atBottom = true; hasNewBelow = false; renderedReadSeq = 0; readTarget = 0; loadedRuns = []; runsError = nil
        if let conversation, conversation.unreadCount > 0 { unreadFromSeq = conversation.lastReadSeq + 1 } else { unreadFromSeq = nil }
        let runsTask = Task { await loadRuns() }
        await action.perform {
            try await store.openConversation(conversationID)
            let page: Page<TranscriptEntry> = try await store.read(resourcePath("conversations", conversationID, "/entries"))
            olderCursor = page.nextCursor
            merge(page.items)
            if let target = store.navigationTarget, let entryID = target.entryID,
               (target.taskConversationID ?? target.conversationID) == conversationID {
                let current: TranscriptEntry = try await store.read(resourcePath("entries", entryID))
                guard current.conversationId == conversationID else { return }
                merge([current])
                flashID = entryID
                jump(to: entryID)
            }
        }
        await runsTask.value
        if jumpID == nil { pinTick += 1 }
        try? await Task.sleep(for: .milliseconds(250))
        settled = true
    }
    private func loadRuns() async {
        do {
            let all: [Run] = try await allResources(store, "/runs", query: ["conversationId": conversationID])
            loadedRuns = all.filter { $0.conversationId == conversationID }
            runsError = nil
        } catch { runsError = error.localizedDescription }
    }
    private func loadTargetEntry() async {
        guard let target = store.navigationTarget, let id = target.entryID,
              (target.taskConversationID ?? target.conversationID) == conversationID else { return }
        do {
            let entry: TranscriptEntry = try await store.read(resourcePath("entries", id))
            guard entry.conversationId == conversationID else { return }
            merge([entry])
            flashID = id
            jump(to: id)
        } catch { action.error = error.localizedDescription }
    }
    /// Read receipts are best-effort and coalesced: one POST in flight, then one more for the highest seq requested meanwhile.
    /// Failures (including cancellation) are silent; the next row that appears retries.
    private func markRendered(_ through: Int) async {
        guard store.connectionState == "online" else { return }
        readTarget = max(readTarget, through)
        guard !readInFlight else { return }
        readInFlight = true
        defer { readInFlight = false }
        while readTarget > renderedReadSeq {
            let seq = readTarget
            do {
                let updated: Conversation = try await store.mutate("POST", resourcePath("conversations", conversationID, "/read"), body: ["throughSeq": .number(Double(seq))])
                renderedReadSeq = seq
                if let index = store.conversations.firstIndex(where: { $0.id == updated.id }), updated.revision >= store.conversations[index].revision { store.conversations[index] = updated }
            } catch { return }
        }
    }
    private func merge(_ page: [TranscriptEntry]) {
        var keyed = Dictionary(uniqueKeysWithValues: (store.entries[conversationID] ?? []).map { ($0.id, $0) })
        for entry in page where entry.revision >= (keyed[entry.id]?.revision ?? 0) { keyed[entry.id] = entry }
        store.entries[conversationID] = keyed.values.sorted { $0.seq < $1.seq }
    }
    private func loadOlder() async { await action.perform { guard let olderCursor else { return }; let page: Page<TranscriptEntry> = try await store.read(resourcePath("conversations", conversationID, "/entries"), query: ["cursor": olderCursor]); merge(page.items); self.olderCursor = page.nextCursor } }

    // MARK: Actions

    private func stop() async {
        guard !action.busy else { return }
        toast = StatusToast(text: "Stopping…")
        await action.perform {
            var statuses: [String] = []
            var allCancelled = true
            for run in activeRuns {
                let receipt: Run = try await store.mutate("POST", resourcePath("runs", run.id, "/cancel"), body: ["reason": .string("Explicit user Stop")])
                if let index = store.runs.firstIndex(where: { $0.id == receipt.id }) { store.runs[index] = receipt }
                if receipt.status != "cancelled" { allCancelled = false }
                statuses.append("\(receipt.id): \(receipt.status == "cancelled" ? "Cancelled" : "Stop requested · \(receipt.status)")")
            }
            toast = StatusToast(text: allCancelled ? "Stopped" : "Stopping…", detail: statuses.joined(separator: " · ") + ". Completed external effects are not rolled back.")
        }
        if action.error != nil { toast = nil }
    }
    private func createTask() async {
        await action.perform {
            guard let bot else { return }
            let task: Conversation = try await store.mutate("POST", "/conversations", body: ["kind": .string("task"), "botIds": strings([bot.id]), "parentConversationId": .string(conversationID), "name": .string("Task with \(bot.name)")])
            try await store.refresh(); store.selectedConversationID = task.id
        }
    }
    private func markUnread() async { await action.perform { let _: Conversation = try await store.mutate("POST", resourcePath("conversations", conversationID, "/read"), body: ["throughSeq": .number(Double(conversation?.lastReadSeq ?? 0)), "unread": .bool(true)]); try await store.refresh() } }
    private func previewDelete() async { await action.perform { confirmation = try await store.mutate("POST", resourcePath("conversations", conversationID, "/preview"), body: ["action": .string("delete")]) } }

    /// Retry never resends: it puts the triggering message back in the composer so the owner sends it deliberately.
    private func retry(_ run: Run) {
        if let text = triggeringText(for: run) {
            let draft = store.draft(for: conversationID)
            let merged = draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : draft.text + "\n\n" + text
            store.setLocalDraft(conversationID: conversationID, text: merged, attachmentIDs: draft.attachmentIDs, replyTo: draft.replyToEntryID)
        }
        focusComposer()
    }
    private func triggeringText(for run: Run) -> String? {
        let all = entries
        func userText(_ entry: TranscriptEntry) -> String? {
            if case .message(let message) = entry, message.role == "user", !message.text.isEmpty { return message.text }
            return nil
        }
        if let hit = all.first(where: { userText($0) != nil && ($0.runId == run.id || $0.clientNonce == run.clientNonce) }) { return userText(hit) }
        let time = Double(run.completedAtMs ?? run.updatedAtMs)
        let anchor = all.last(where: { $0.runId == run.id })?.seq ?? all.last(where: { Double($0.timestampMs) <= time })?.seq ?? Int.max
        return all.last(where: { $0.seq < anchor && userText($0) != nil }).flatMap(userText)
    }
}

// MARK: - Entry views

struct TranscriptEntryView: View {
    let store: LemonBotStore
    let entry: TranscriptEntry
    var bot: Bot?
    var showsName: Bool
    var highlighted: Bool
    init(store: LemonBotStore, entry: TranscriptEntry, bot: Bot? = nil, showsName: Bool = false, highlighted: Bool = false) {
        self.store = store; self.entry = entry; self.bot = bot; self.showsName = showsName; self.highlighted = highlighted
    }
    @State private var action = UIActionState()
    @State private var feedback = false
    @State private var comment = ""
    @State private var reasons: Set<String> = []
    @State private var sentiment = "good"
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.lbReduceMotion) private var reduceMotion

    private var isMine: Bool { entry.actor.kind == "user" && (entry.actor.id == nil || entry.actor.id == store.user?.id || store.user == nil) }
    private var privateUnavailable: Bool { entry.targetedUserId.map { $0 != store.user?.id } ?? false }
    private var palette: BotPalette { (bot ?? store.bots.first { $0.id == entry.actor.id })?.palette ?? BotPalette.named(nil) }
    private var alignment: HorizontalAlignment { isMine ? .trailing : .leading }

    var body: some View {
        if privateUnavailable {
            Text("Private entry unavailable to this account.").font(LBFont.meta).foregroundStyle(LB.muted).frame(maxWidth: .infinity)
        } else {
            switch entry {
            case .toolCall(let tool): ToolActivityRow(tools: [tool])
            case .notice(let notice): NoticeRow(notice: notice)
            case .event(let event): TranscriptEventView(store: store, event: event.event)
            case .feedback(let value):
                Text("Feedback: \(value.feedback.sentiment)\(value.feedback.reasons.isEmpty ? "" : " · " + value.feedback.reasons.map(humanizedStatus).joined(separator: ", "))\(value.feedback.comment.isEmpty ? "" : " · " + value.feedback.comment)")
                    .font(LBFont.meta).foregroundStyle(LB.muted).multilineTextAlignment(.center).textSelection(.enabled).frame(maxWidth: .infinity)
            default: bubbleRow
            }
        }
    }

    private var bubbleRow: some View {
        HStack(alignment: .top, spacing: 0) {
            if isMine { Spacer(minLength: 24) }
            VStack(alignment: alignment, spacing: 4) {
                if showsName && !isMine { Text(entry.actor.displayName).font(LBFont.metaEmphasis).foregroundStyle(LB.muted).padding(.leading, 4) }
                replyQuote
                HStack(alignment: .top, spacing: 6) {
                    if isMine { hoverActions }
                    VStack(alignment: alignment, spacing: 4) {
                        mainContent
                            .overlay { if highlighted { RoundedRectangle(cornerRadius: LBMetric.bubbleRadius, style: .continuous).stroke(LB.lemon, lineWidth: 2) } }
                            .help(Text(timestamp(Double(entry.timestampMs)).formatted(date: .abbreviated, time: .shortened)))
                        extras
                    }
                    .frame(maxWidth: LBMetric.bubbleMaxWidth, alignment: isMine ? .trailing : .leading)
                    .contextMenu { contextItems }
                    if !isMine { hoverActions }
                }
                reactionsRow
                ActionErrorView(message: action.error)
            }
            if !isMine { Spacer(minLength: 24) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityAction(named: "Reply") { reply() }
        .accessibilityAction(named: "React with thumbs up") { Task { await react("👍") } }
        .sheet(isPresented: $feedback) { feedbackSheet }
    }

    @ViewBuilder private var replyQuote: some View {
        if let reply = entry.replyToEntryId {
            let quoted = store.entries[entry.conversationId]?.first { $0.id == reply && ($0.targetedUserId == nil || $0.targetedUserId == store.user?.id) }
            HStack(spacing: 6) {
                Image(systemName: "arrowshape.turn.up.left").font(.system(size: 10))
                Text("\(quoted?.actor.displayName ?? "Referenced message") · \(quoted?.text.map { String($0.prefix(120)) } ?? "File, card or unavailable message")").lineLimit(1)
            }.font(LBFont.meta).foregroundStyle(LB.muted).padding(.horizontal, 4)
        }
    }

    @ViewBuilder private var mainContent: some View {
        switch entry {
        case .message(let message):
            if !message.text.isEmpty || message.streaming { MessageBubble(text: message.text, streaming: message.streaming, mine: isMine, palette: palette) }
        case .card(let card):
            TranscriptCardView(store: store, card: card.card).frame(maxWidth: LBMetric.bubbleMaxWidth, alignment: .leading)
        case .userAttachment(let attachment):
            AttachmentView(store: store, attachmentID: attachment.attachmentId)
        case .mcpApp(let app):
            QuietBubble {
                Label("App snapshot", systemImage: "square.grid.2x2").font(LBFont.metaEmphasis).foregroundStyle(LB.ink)
                Text(humanizedStatus(app.state)).font(LBFont.meta).foregroundStyle(LB.muted)
                Text(app.resourceUri).font(LBFont.meta).foregroundStyle(LB.faint).textSelection(.enabled)
                if let id = app.snapshotAttachmentId { AttachmentView(store: store, attachmentID: id) }
                else { Text("No authorized snapshot is available. Ask the Bot to refresh through chat.").font(LBFont.meta).foregroundStyle(LB.muted) }
            }.help("Connector \(app.connectorId)")
        case .voiceCall(let voice):
            VoiceCallSummaryView(store: store, session: voice.voiceSession)
        case .unsupported(let value):
            QuietBubble {
                Text("Entry type \(value.kind) requires a newer client; no action was authorized.").font(LBFont.meta).foregroundStyle(LB.warning)
                if let text = value.text { Text(text).font(LBFont.body).foregroundStyle(LB.ink).textSelection(.enabled) }
                if let id = value.attachmentId { AttachmentView(store: store, attachmentID: id) }
            }
        case .toolCall, .notice, .event, .feedback:
            EmptyView()
        }
    }

    @ViewBuilder private var extras: some View {
        if case .message(let message) = entry {
            ForEach(message.attachmentIds, id: \.self) { id in AttachmentView(store: store, attachmentID: id) }
        }
    }

    @ViewBuilder private var reactionsRow: some View {
        if !entry.reactions.isEmpty {
            HStack(spacing: 6) {
                ForEach(entry.reactions, id: \.emoji) { reaction in
                    let mine = reaction.userIds.contains(store.user?.id ?? "")
                    Button { Task { await react(reaction.emoji) } } label: {
                        Text("\(reaction.emoji) \(reaction.userIds.count)").font(LBFont.chip).foregroundStyle(LB.ink)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(mine ? LB.accent.opacity(0.2) : LB.fill))
                    }.buttonStyle(.plain).disabled(store.connectionState != "online")
                        .accessibilityLabel("\(reaction.emoji), \(reaction.userIds.count) reaction\(reaction.userIds.count == 1 ? "" : "s")")
                }
            }.padding(.horizontal, 4)
        }
    }

    // MARK: Actions

    /// macOS: a small floating row beside the bubble, visible only on hover. iOS uses the context menu.
    @ViewBuilder private var hoverActions: some View {
        #if os(macOS)
        HStack(spacing: 1) {
            Button { Task { await react("👍") } } label: { Text("👍") }
                .buttonStyle(GhostCircleButtonStyle(size: 26, filled: false)).help("React 👍").accessibilityLabel("React with thumbs up")
            if let text = entry.text, !text.isEmpty {
                Button { copyText(text) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(GhostCircleButtonStyle(size: 26, filled: false)).help("Copy").accessibilityLabel("Copy message")
            }
            Button { reply() } label: { Image(systemName: "arrowshape.turn.up.left") }
                .buttonStyle(GhostCircleButtonStyle(size: 26, filled: false)).help("Reply").accessibilityLabel("Reply")
            Menu { moreItems } label: { Image(systemName: "ellipsis") }
                .menuStyle(.button).menuIndicator(.hidden).buttonStyle(GhostCircleButtonStyle(size: 26, filled: false)).fixedSize()
                .help("More").accessibilityLabel("More actions")
        }
        .padding(3)
        .background(Capsule().fill(LB.raised))
        .shadow(color: scheme == .light ? LB.shadow : .clear, radius: 8, y: 2)
        .disabled(action.busy)
        .opacity(hovering ? 1 : 0)
        .allowsHitTesting(hovering)
        .accessibilityHidden(!hovering)
        .lbAnimation(LBMotion.fade, value: hovering)
        #else
        EmptyView()
        #endif
    }

    @ViewBuilder private var moreItems: some View {
        ForEach(["❤️", "🎉", "👀"], id: \.self) { emoji in Button("React \(emoji)") { Task { await react(emoji) } } }
        Divider()
        Button { feedback = true } label: { Label("Give feedback", systemImage: "hand.thumbsup") }
        Button { copyText(entry.id) } label: { Label("Copy message ID", systemImage: "number") }
    }

    @ViewBuilder private var contextItems: some View {
        if let text = entry.text, !text.isEmpty { Button { copyText(text) } label: { Label("Copy", systemImage: "doc.on.doc") } }
        Button { reply() } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
        ForEach(["👍", "❤️", "🎉", "👀"], id: \.self) { emoji in Button("React \(emoji)") { Task { await react(emoji) } } }
        Divider()
        Button { feedback = true } label: { Label("Give feedback", systemImage: "hand.thumbsup") }
        Button { copyText(entry.id) } label: { Label("Copy message ID", systemImage: "number") }
    }

    private func reply() {
        let draft = store.draft(for: entry.conversationId)
        store.setLocalDraft(conversationID: entry.conversationId, text: draft.text, attachmentIDs: draft.attachmentIDs, replyTo: entry.id)
        NotificationCenter.default.post(name: Notification.Name("LemonBot.focusComposer"), object: nil, userInfo: ["conversationID": entry.conversationId])
    }

    private var feedbackSheet: some View {
        NavigationStack {
            Form {
                Picker("Feedback", selection: $sentiment) { Text("Good").tag("good"); Text("Bad").tag("bad") }.pickerStyle(.segmented)
                Section("Reasons") {
                    ForEach(["not_requested", "inaccurate", "low_quality", "slow"], id: \.self) { reason in Toggle(reason.replacingOccurrences(of: "_", with: " ").capitalized, isOn: Binding(get: { reasons.contains(reason) }, set: { if $0 { reasons.insert(reason) } else { reasons.remove(reason) } })) }
                }
                TextField("Comment", text: $comment, axis: .vertical)
                Text("Feedback does not authorize an action.").font(LBFont.meta).foregroundStyle(LB.muted)
                ActionErrorView(message: action.error)
                Button("Save feedback") { Task { await action.perform { let _: Feedback = try await store.mutate("POST", resourcePath("entries", entry.id, "/feedback"), body: ["sentiment": .string(sentiment), "reasons": strings(Array(reasons)), "comment": .string(comment)]); feedback = false } } }
                    .buttonStyle(.lemonPrimary).disabled(action.busy || store.connectionState != "online")
            }
            .formStyle(.grouped)
            .navigationTitle("Feedback").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { feedback = false } } }
        }.frame(minWidth: 320, minHeight: 360)
    }

    private func react(_ emoji: String) async {
        guard store.connectionState == "online" else { return }
        await action.perform {
            let remove = entry.reactions.contains { $0.emoji == emoji && $0.userIds.contains(store.user?.id ?? "") }
            let result: TranscriptEntry = try await store.mutate(remove ? "DELETE" : "POST", resourcePath("entries", entry.id, "/reactions"), body: ["emoji": .string(emoji)])
            if let index = store.entries[entry.conversationId]?.firstIndex(where: { $0.id == result.id }) { store.entries[entry.conversationId]?[index] = result }
        }
    }
}

struct TranscriptEventView: View {
    let store: LemonBotStore
    let event: TranscriptEvent
    var body: some View {
        HStack(spacing: 6) {
            switch event {
            case .nameChanged(let value): Text("Name changed to \(value.name)")
            case .channelConnected: Text("Channel connected")
            case .channelDisconnected: Text("Channel disconnected")
            case .routineChanged(let value):
                Text("Routine \(value.action)")
                link("Open routine") { RoutineDetailView(store: store, routineID: value.routineId) }
            case .taskChanged(let value):
                Text("Task \(humanizedStatus(value.status).lowercased())")
                link("Open task") { ConversationView(store: store, conversationID: value.conversationId) }
            case .botAdded(let value):
                Text("\(botName(value.botId)) was added")
                link("View") { BotOverviewView(store: store, botID: value.botId) }
            case .botRemoved(let value): Text("\(botName(value.botId)) was removed")
            case .handoff(let value):
                Text("\(botName(value.sourceBotId)) → \(botName(value.targetBotId)): \(value.text)")
                link("Open") { ConversationView(store: store, conversationID: value.targetConversationId) }
            case .machineMoved(let value):
                Text("\(botName(value.botId)) moved to \(store.machines.first { $0.id == value.targetMachineId }?.name ?? "another machine"). Files and credentials were not copied.")
            }
        }
        .font(LBFont.meta).foregroundStyle(LB.muted).multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
    private func botName(_ id: ID) -> String { store.bots.first { $0.id == id }?.name ?? "A Bot" }
    private func link<Destination: View>(_ label: String, @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink { destination() } label: { Text(label).font(LBFont.metaEmphasis).foregroundStyle(LB.accent) }.buttonStyle(.plain)
    }
}
