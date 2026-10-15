import SwiftUI
import LemonBotKit

/// What the detail column shows besides a conversation.
enum WorkspaceDestination: Equatable {
    case conversation, activity, inbox, pending, linkedMachine, linkedBot, linkedRoutine
}

/// Messaging-first conversation list: search and new-Bot buttons, pinned avatars, Bot rows,
/// groups and tasks, and the account / Connect apps footer.
struct SidebarView: View {
    let store: LemonBotStore
    @Binding var destination: WorkspaceDestination
    let inspector: InspectorPresentation
    let openConversation: (ID) -> Void
    let openDestination: (WorkspaceDestination) -> Void
    let openSettings: (SettingsPane) -> Void
    let newBot: () -> Void
    let newGroup: () -> Void
    let searchEverything: () -> Void
    let reconnect: () -> Void
    @Binding var filterFocusRequest: Int

    @State private var searching = false
    @State private var query = ""
    @State private var showHidden = false
    @State private var unreadOnly = false
    @State private var visibleRows: Set<ID> = []
    @State private var previews: [ID: SidebarPreview] = [:]
    @State private var action = UIActionState()
    @State private var showConnection = false
    @FocusState private var filterFocused: Bool
    @Environment(\.lbReduceMotion) private var reduceMotion

    private var selectedConversationID: ID? { destination == .conversation ? store.selectedConversationID : nil }
    private var selectedBotID: ID? {
        guard let id = selectedConversationID, let room = store.conversations.first(where: { $0.id == id }), room.kind == "dm" || room.kind == "task" else { return nil }
        return room.botIds.first
    }
    private func matches(_ text: String) -> Bool { query.isEmpty || text.localizedCaseInsensitiveContains(query) }
    /// True while the list is narrowed by search text or the Unread filter.
    private var filtering: Bool { !query.isEmpty || unreadOnly }
    private var rankedBots: [Bot] { store.bots.sorted { $0.sidebar.rank < $1.sidebar.rank } }
    private var pinned: [Bot] { rankedBots.filter { $0.sidebar.pinned && !$0.sidebar.hidden && !filtering } }
    private var listBots: [Bot] {
        rankedBots.filter { bot in
            (showHidden ? true : !bot.sidebar.hidden) && (!bot.sidebar.pinned || filtering) && (!unreadOnly || bot.sidebar.unread)
                && (matches(bot.name) || matches(bot.title) || matches(bot.job))
        }
    }
    private var hiddenCount: Int { store.bots.filter(\.sidebar.hidden).count }
    private var rooms: [Conversation] {
        store.conversations.filter { ["group", "task"].contains($0.kind) && matches($0.name) && (!unreadOnly || $0.unreadCount > 0) }
            .sorted { $0.updatedAtMs > $1.updatedAtMs }
    }
    private var unreadInbox: Int { store.notifications.filter { $0.readAtMs == nil && $0.dismissedAtMs == nil }.count }
    /// Rows with unread content that are currently scrolled out of view.
    private var offscreenUnread: [ID] {
        listBots.filter { $0.sidebar.unread && !visibleRows.contains($0.id) }.map(\.id)
            + rooms.filter { $0.unreadCount > 0 && !visibleRows.contains($0.id) }.map(\.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollViewReader { proxy in
                rowsContainer
                .overlay(alignment: .bottom) {
                    if let first = offscreenUnread.first {
                        Button { lbWithAnimation(reduceMotion) { proxy.scrollTo(first, anchor: .center) } } label: {
                            Label("More unreads", systemImage: "arrow.down").font(LBFont.metaEmphasis)
                        }
                        .buttonStyle(.pill(.primary(LB.unread, .white), compact: true))
                        .shadow(color: LB.shadow, radius: 8, y: 3)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .lbAnimation(LBMotion.snappy, value: offscreenUnread.first)
            }
            footer
        }
        #if os(macOS)
        .background(LB.sidebar)
        #else
        .background(LB.canvas)
        .searchable(text: $query, isPresented: $searching, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search Bots and groups")
        .toolbar { phoneToolbar }
        #endif
        .task(id: previewKey) { await loadPreviews() }
        #if os(macOS)
        .popover(isPresented: $showConnection) { ScrollView { ConnectionStatusView(store: store).padding(12) }.frame(width: 440, height: 520) }
        #else
        .sheet(isPresented: $showConnection) {
            NavigationStack { ScrollView { ConnectionStatusView(store: store).padding() }.navigationTitle("Connection").toolbar { Button("Done") { showConnection = false } } }
        }
        #endif
        .onChange(of: store.connectionIssue) { _, issue in if issue == nil && store.connectionState == "online" { showConnection = false } }
        .onChange(of: filterFocusRequest) { _, _ in
            lbWithAnimation(reduceMotion, LBMotion.snappy) { searching = true }
            filterFocused = true
        }
    }

    @ViewBuilder private var rows: some View {
        #if os(macOS)
        if searching { filterField.padding(.horizontal, 12).padding(.bottom, 8) }
        #endif
        if !pinned.isEmpty { pinnedRow.padding(.bottom, 10).sidebarRow() }
        utilityRows
        if store.bots.isEmpty { setupRow.sidebarRow() }
        botList
        roomList
        if hiddenCount > 0 && !filtering {
            Button(showHidden ? "Hide hidden Bots" : "Show \(hiddenCount) hidden \(hiddenCount == 1 ? "Bot" : "Bots")") {
                lbWithAnimation(reduceMotion, LBMotion.snappy) { showHidden.toggle() }
            }.buttonStyle(.pill(.quiet, compact: true)).foregroundStyle(LB.muted).padding(.leading, 12).padding(.top, 6).sidebarRow()
        }
        Color.clear.frame(height: 72).sidebarRow()
    }

    /// macOS: a lazy stack (custom highlight, hover). iOS: a plain List so rows get native swipe actions.
    @ViewBuilder private var rowsContainer: some View {
        #if os(iOS)
        List { rows }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 1)
        #else
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) { rows }.padding(.horizontal, 8)
        }.scrollIndicators(.never)
        #endif
    }

    // MARK: Top bar

    @ViewBuilder private var topBar: some View {
        #if os(macOS)
        HStack(spacing: 8) {
            Spacer()
            connectionPill
            Button {
                lbWithAnimation(reduceMotion, LBMotion.snappy) { searching.toggle() }
                if searching { filterFocused = true } else { query = "" }
            } label: { Label("Search Bots", systemImage: "magnifyingglass") }
                .buttonStyle(GhostCircleButtonStyle(size: 32))
                .help("Search Bots (⌘⇧F) · Search everything (⌘K)")
            Button(action: newBot) { Label("New Bot", systemImage: "plus") }
                .buttonStyle(GhostCircleButtonStyle(size: 32))
                .disabled(!store.isOnline)
                .help("New Bot (⌘N)")
                .contextMenu { Button("New group of Bots", systemImage: "person.2", action: newGroup) }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        #else
        // iPhone uses the navigation bar (large "Chats" title, + button) and pull-down search.
        if !store.isOnline || store.connectionIssue != nil { HStack { Spacer(); connectionPill }.padding(.horizontal, 16).padding(.vertical, 4) }
        #endif
    }

    #if os(iOS)
    @ToolbarContentBuilder private var phoneToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Toggle(isOn: $unreadOnly) { Label("Unread only", systemImage: "envelope.badge") }
                Button(showHidden ? "Hide hidden Bots" : "Show hidden Bots", systemImage: showHidden ? "eye.slash" : "eye") { showHidden.toggle() }
                Divider()
                Button("Search everything", systemImage: "magnifyingglass", action: searchEverything)
                Button("New group of Bots", systemImage: "person.2", action: newGroup).disabled(!store.isOnline)
            } label: { Label("Filter", systemImage: unreadOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: newBot) { Label("New Bot", systemImage: "square.and.pencil") }.disabled(!store.isOnline)
        }
    }
    #endif

    @ViewBuilder private var connectionPill: some View {
        if !store.isOnline || store.connectionIssue != nil {
            Button { showConnection = true } label: {
                HStack(spacing: 5) {
                    Circle().fill(LB.warning).frame(width: 6, height: 6)
                    Text(store.connectionIssue?.layer == .controllerDown ? "Lemon offline" : store.connectionState == "reconnect_required" ? "Sign in again" : store.connectionState == "syncing" ? "Syncing" : "Offline")
                }.font(LBFont.chip).foregroundStyle(LB.muted)
            }.buttonStyle(.pill(.secondary, compact: true)).accessibilityHint("Show connection details and fixes")
        }
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(LB.muted)
            TextField("Search Bots and groups", text: $query)
                .textFieldStyle(.plain).font(LBFont.rowSubtitle)
                .focused($filterFocused)
                .autocorrectionDisabled()
                .onSubmit { if let first = listBots.first { openConversation(first.mainConversationId) } }
                .onKeyPress(.escape) { query = ""; unreadOnly = false; searching = false; return .handled }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(LB.faint) }.buttonStyle(.plain).accessibilityLabel("Clear search")
            }
            Button { unreadOnly.toggle() } label: { Text("Unread") }
                .buttonStyle(.pill(unreadOnly ? .primary(LB.unread, .white) : .secondary, compact: true))
                .accessibilityAddTraits(unreadOnly ? .isSelected : [])
            Button("All", action: searchEverything).buttonStyle(.pill(.secondary, compact: true)).help("Search messages, files and routines (⌘K)")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: LBMetric.rowRadius, style: .continuous).fill(LB.fill))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: Pinned avatars

    private var pinnedRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(pinned) { bot in
                    let selected = bot.id == selectedBotID
                    Button { openConversation(bot.mainConversationId) } label: {
                        VStack(spacing: 6) {
                            BotBadgedAvatar(store: store, bot: bot, size: 56, presence: presence(bot), unread: bot.sidebar.unread, ring: selected ? LB.sidebar : LB.sidebar)
                            Text(bot.name).font(LBFont.meta).foregroundStyle(LB.ink).lineLimit(1).truncationMode(.tail)
                        }
                        .frame(width: 84).padding(.vertical, 10)
                        .rowHighlight(selected: selected, radius: 14)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { botMenu(bot) }
                    .accessibilityLabel("\(bot.name)\(bot.sidebar.unread ? ", unread" : "")")
                }
            }.padding(.horizontal, 4)
        }.scrollIndicators(.never)
    }

    // MARK: Utility rows

    @ViewBuilder private var utilityRows: some View {
        if !filtering {
            utilityRow("Inbox", symbol: "tray", count: unreadInbox, selected: destination == .inbox) { openDestination(.inbox) }
            utilityRow("Activity", symbol: "clock.arrow.circlepath", count: 0, selected: destination == .activity) { openDestination(.activity) }
            if !store.pendingIntents.isEmpty {
                utilityRow("Unconfirmed actions", symbol: "exclamationmark.arrow.triangle.2.circlepath", count: store.pendingIntents.count, selected: destination == .pending, tint: LB.warning) { openDestination(.pending) }
            }
            Color.clear.frame(height: 6).sidebarRow()
        }
    }
    private func utilityRow(_ title: String, symbol: String, count: Int, selected: Bool, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(tint ?? LB.muted).frame(width: 24)
                Text(title).font(LBFont.rowSubtitle).foregroundStyle(LB.ink)
                Spacer()
                if count > 0 { Text("\(count)").font(LBFont.chip).foregroundStyle(LB.muted) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .rowHighlight(selected: selected, radius: 10)
        }.buttonStyle(.plain).sidebarRow()
    }

    private var setupRow: some View {
        SoftCard(fill: LB.raised) {
            Text("Set up your first Bot").font(LBFont.rowTitle).foregroundStyle(LB.ink)
            Text("Attach one of your machines, wait until it's online, then create a Bot on it.").font(LBFont.meta).foregroundStyle(LB.muted)
            Button("Attach a machine") { openSettings(.machines) }.buttonStyle(.lemonPrimary)
        }.padding(.horizontal, 4).padding(.vertical, 8)
    }

    // MARK: Bots

    @ViewBuilder private var botList: some View {
        let sections = store.sections.sorted { $0.rank < $1.rank }
        let unsectioned = listBots.filter { bot in bot.sidebar.sectionId == nil || !sections.contains { $0.id == bot.sidebar.sectionId } || filtering }
        ForEach(unsectioned) { bot in botRow(bot) }
        if !filtering {
            ForEach(sections) { section in
                let members = listBots.filter { $0.sidebar.sectionId == section.id }
                if !members.isEmpty {
                    sectionHeader(section)
                    if !section.collapsed { ForEach(members) { bot in botRow(bot) } }
                }
            }
        }
    }
    private func sectionHeader(_ section: LemonBotKit.Section) -> some View {
        Button { Task { await setCollapsed(section, !section.collapsed) } } label: {
            HStack(spacing: 4) {
                Text(section.name).font(LBFont.metaEmphasis).foregroundStyle(LB.muted)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(LB.faint)
                    .rotationEffect(.degrees(section.collapsed ? 0 : 90))
                Spacer()
            }.padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 4).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!store.isOnline)
            .accessibilityLabel("\(section.name), \(section.collapsed ? "collapsed" : "expanded")")
            .sidebarRow()
    }

    private func botRow(_ bot: Bot) -> some View {
        let selected = bot.id == selectedBotID
        let step = store.currentStep(in: bot.mainConversationId)
        return Button { openConversation(bot.mainConversationId) } label: {
            HStack(spacing: 12) {
                BotBadgedAvatar(store: store, bot: bot, size: 40, presence: presence(bot), ring: LB.sidebar)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(bot.name).font(LBFont.rowTitle).foregroundStyle(LB.ink).lineLimit(1)
                        if !bot.title.isEmpty { LabelChip(text: bot.title).layoutPriority(-1) }
                        if bot.sidebar.hidden { Image(systemName: "eye.slash").font(.system(size: 10)).foregroundStyle(LB.faint) }
                    }
                    previewLine(bot: bot, step: step)
                }
                Spacer(minLength: 4)
                if bot.sidebar.unread { UnreadDot() }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .rowHighlight(selected: selected)
        }
        .buttonStyle(.plain)
        .id(bot.id)
        .onAppear { visibleRows.insert(bot.id) }
        .onDisappear { visibleRows.remove(bot.id) }
        .contextMenu { botMenu(bot) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .sidebarRow()
        #if os(iOS)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { Task { await sidebar(bot, ["unread": .bool(!bot.sidebar.unread)]) } } label: {
                Label(bot.sidebar.unread ? "Read" : "Unread", systemImage: bot.sidebar.unread ? "envelope.open" : "envelope.badge")
            }.tint(LB.unread)
        }
        .swipeActions(edge: .trailing) {
            Button { Task { await sidebar(bot, ["hidden": .bool(!bot.sidebar.hidden)]) } } label: {
                Label(bot.sidebar.hidden ? "Unhide" : "Hide", systemImage: bot.sidebar.hidden ? "eye" : "eye.slash")
            }.tint(LB.faint)
            Button { Task { await sidebar(bot, ["pinned": .bool(!bot.sidebar.pinned)]) } } label: {
                Label(bot.sidebar.pinned ? "Unpin" : "Pin", systemImage: bot.sidebar.pinned ? "pin.slash" : "pin")
            }.tint(LB.accent)
        }
        #endif
    }

    @ViewBuilder private func previewLine(bot: Bot, step: LiveStep?) -> some View {
        if let step {
            HStack(spacing: 4) {
                Image(systemName: step.needsInput ? "hand.raised.fill" : "ellipsis").font(.system(size: 10, weight: .bold))
                Text(step.needsInput ? "Needs you" : step.title + "…").lineLimit(1)
            }.font(LBFont.rowSubtitle).foregroundStyle(step.needsInput ? LB.warning : LB.accent)
        } else {
            Text(previews[bot.mainConversationId]?.text ?? (bot.job.isEmpty ? "No messages yet" : bot.job))
                .font(LBFont.rowSubtitle).foregroundStyle(LB.muted).lineLimit(1)
        }
    }

    @ViewBuilder private func botMenu(_ bot: Bot) -> some View {
        Button("Open chat", systemImage: "bubble.left") { openConversation(bot.mainConversationId) }
        Button("Bot details", systemImage: "info.circle") { openConversation(bot.mainConversationId); inspector.show(.details) }
        Button("Activity", systemImage: "waveform.path.ecg") { openConversation(bot.mainConversationId); inspector.show(.activity) }
        Divider()
        Group {
            Button(bot.sidebar.pinned ? "Unpin" : "Pin", systemImage: bot.sidebar.pinned ? "pin.slash" : "pin") { Task { await sidebar(bot, ["pinned": .bool(!bot.sidebar.pinned)]) } }
            Button(bot.sidebar.unread ? "Mark as read" : "Mark as unread", systemImage: bot.sidebar.unread ? "envelope.open" : "envelope.badge") { Task { await sidebar(bot, ["unread": .bool(!bot.sidebar.unread)]) } }
            Button(bot.sidebar.hidden ? "Unhide" : "Hide (work continues)", systemImage: bot.sidebar.hidden ? "eye" : "eye.slash") { Task { await sidebar(bot, ["hidden": .bool(!bot.sidebar.hidden)]) } }
            Menu("Move to section") {
                Button("No section") { Task { await sidebar(bot, ["sectionId": .null]) } }
                ForEach(store.sections) { section in Button(section.name) { Task { await sidebar(bot, ["sectionId": .string(section.id)]) } } }
                Divider()
                Button("Organize sections…") { openSettings(.workspace) }
            }
            Button("Move up", systemImage: "arrow.up") { Task { await move(bot, by: -1) } }
            Button("Move down", systemImage: "arrow.down") { Task { await move(bot, by: 1) } }
        }.disabled(!store.isOnline)
    }

    // MARK: Groups and tasks

    @ViewBuilder private var roomList: some View {
        if !rooms.isEmpty {
            HStack {
                Text("Groups and tasks").font(LBFont.metaEmphasis).foregroundStyle(LB.muted)
                Spacer()
                Button(action: newGroup) { Image(systemName: "plus").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(LB.muted).accessibilityLabel("New group").disabled(!store.isOnline)
            }.padding(.horizontal, 12).padding(.top, 16).padding(.bottom, 4).sidebarRow()
            ForEach(rooms) { room in roomRow(room) }
        }
    }
    private func roomRow(_ room: Conversation) -> some View {
        let members = room.botIds.compactMap { id in store.bots.first { $0.id == id } }
        let selected = selectedConversationID == room.id
        return Button { openConversation(room.id) } label: {
            HStack(spacing: 12) {
                ZStack {
                    if room.kind == "task", let bot = members.first {
                        BotAvatarView(store: store, bot: bot).frame(width: 30, height: 30)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "arrow.triangle.branch").font(.system(size: 8, weight: .bold)).foregroundStyle(LB.ink)
                                    .frame(width: 16, height: 16).background(Circle().fill(LB.raised)).offset(x: 6, y: 6)
                            }
                    } else {
                        ForEach(Array(members.prefix(3).enumerated()), id: \.element.id) { index, bot in
                            BotAvatarView(store: store, bot: bot).frame(width: 26, height: 26)
                                .offset(x: CGFloat(index) * 8 - 8, y: CGFloat(index % 2) * 6 - 3)
                        }
                    }
                }.frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(room.name.isEmpty ? members.map(\.name).joined(separator: ", ") : room.name).font(LBFont.rowTitle).foregroundStyle(LB.ink).lineLimit(1)
                    if let step = store.currentStep(in: room.id) {
                        Text(step.title + "…").font(LBFont.rowSubtitle).foregroundStyle(LB.accent).lineLimit(1)
                    } else {
                        Text(previews[room.id]?.text ?? (room.kind == "task" ? "Task" : members.map(\.name).joined(separator: ", ")))
                            .font(LBFont.rowSubtitle).foregroundStyle(LB.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if room.unreadCount > 0 { UnreadDot() }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .rowHighlight(selected: selected)
        }
        .buttonStyle(.plain)
        .id(room.id)
        .onAppear { visibleRows.insert(room.id) }
        .onDisappear { visibleRows.remove(room.id) }
        .accessibilityElement(children: .combine)
        .sidebarRow()
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button { openSettings(.account) } label: {
                AccountInitials(name: store.user?.displayName ?? store.account?.displayName ?? "")
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityLabel("Account and settings")
            .contextMenu {
                Text(store.user?.displayName ?? store.account?.displayName ?? "")
                Button("Settings…", systemImage: "gearshape") { openSettings(.account) }
                #if os(macOS)
                Button("Connect iPhone…", systemImage: "iphone") { openSettings(.devices) }
                #endif
                Button("Machines", systemImage: "desktopcomputer") { openSettings(.machines) }
                Button("Skills and routines", systemImage: "books.vertical") { openSettings(.library) }
                Divider()
                Button("Search everything", systemImage: "magnifyingglass", action: searchEverything)
            }
            Button { openSettings(.apps) } label: {
                HStack(spacing: 8) {
                    Text("Connect apps").font(LBFont.sectionTitle)
                    Image(systemName: "square.grid.2x2").font(.system(size: 12, weight: .medium)).foregroundStyle(LB.muted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .foregroundStyle(LB.ink)
                .background(Capsule().fill(LB.raised))
                .overlay(Capsule().stroke(LB.separator, lineWidth: 1))
                .contentShape(Capsule())
            }.buttonStyle(.plain).help("Connectors and channels (⌘⇧M)")
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    // MARK: Data

    private func presence(_ bot: Bot) -> AvatarPresence { AvatarPresence(activity: bot.activity, online: store.isOnline) }

    private var previewKey: String {
        (store.bots.map(\.mainConversationId) + rooms.map(\.id)).map { id in "\(id):\(store.conversations.first { $0.id == id }?.lastEntryId ?? "")" }.joined(separator: "|")
    }
    private func loadPreviews() async {
        for room in store.conversations where ["dm", "task", "group"].contains(room.kind) {
            guard let lastID = room.lastEntryId, previews[room.id]?.entryID != lastID else { continue }
            let entry: TranscriptEntry?
            if let cached = store.entries[room.id]?.last(where: { $0.id == lastID }) { entry = cached }
            else if store.isOnline { entry = try? await store.read(resourcePath("entries", lastID)) }
            else { entry = nil }
            if let entry, let preview = SidebarPreview(entry: entry, userID: store.user?.id) { previews[room.id] = preview }
        }
    }
    private func sidebar(_ bot: Bot, _ fields: JSONObject) async {
        guard store.isOnline else { return }
        await action.perform {
            var body = fields; body["revision"] = .number(Double(bot.revision))
            let updated: Bot = try await store.mutate("PATCH", resourcePath("bots", bot.id, "/sidebar"), body: body)
            if let index = store.bots.firstIndex(where: { $0.id == updated.id }) { store.bots[index] = updated }
        }
    }
    private func move(_ bot: Bot, by offset: Int) async {
        guard store.isOnline else { return }
        var ordered = listBots
        guard let index = ordered.firstIndex(where: { $0.id == bot.id }) else { return }
        let target = index + offset
        guard ordered.indices.contains(target) else { return }
        ordered.swapAt(index, target)
        await action.perform {
            for (rank, item) in ordered.enumerated() where item.sidebar.rank != rank {
                let latest: Bot = try await store.read(resourcePath("bots", item.id))
                let _: Bot = try await store.mutate("PATCH", resourcePath("bots", item.id, "/sidebar"), body: ["revision": .number(Double(latest.revision)), "rank": .number(Double(rank))])
            }
            try await store.refresh()
        }
    }
    private func setCollapsed(_ section: LemonBotKit.Section, _ collapsed: Bool) async {
        await action.perform { let _: LemonBotKit.Section = try await store.mutate("PATCH", resourcePath("sections", section.id), body: ["revision": .number(Double(section.revision)), "collapsed": .bool(collapsed)]); try await store.refresh() }
    }
}

private extension View {
    /// Row chrome for the iOS List container (no separators/backgrounds, tight insets); no-op on macOS.
    @ViewBuilder func sidebarRow() -> some View {
        #if os(iOS)
        self.listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        #else
        self
        #endif
    }
}

/// One-line last-message preview for a sidebar row.
struct SidebarPreview: Equatable {
    var entryID: ID
    var text: String
    /// Markdown → single-line plain text ("**Done** — `x`" → "Done — x").
    static func plain(_ markdown: String) -> String {
        let lines = markdown.split(whereSeparator: \.isNewline).map { line in
            String(line).replacingOccurrences(of: #"^\s*(?:[#>]+|[-*+]|\d+[.)])\s+"#, with: "", options: .regularExpression)
        }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("```") }
        let joined = lines.joined(separator: " ")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let plain = (try? AttributedString(markdown: joined, options: options)).map { String($0.characters) } ?? joined
        return plain.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    init?(entry: TranscriptEntry, userID: ID?) {
        entryID = entry.id
        switch entry {
        case .message(let message):
            let body = SidebarPreview.plain(message.text)
            if body.isEmpty && message.attachmentIds.isEmpty {
                guard message.role != "user", !message.streaming else { return nil }
                text = "Couldn't finish the last request"
            } else {
                let content = body.isEmpty ? "Sent an attachment" : body
                text = message.role == "user" ? "You: \(content)" : content
            }
        case .userAttachment: text = "You: Sent an attachment"
        case .card: text = "Needs a look"
        case .voiceCall: text = "Voice chat"
        case .notice(let notice): text = notice.text
        default: return nil
        }
    }
}

/// Round account avatar with initials in lemon.
struct AccountInitials: View {
    let name: String
    var size: CGFloat = 34
    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        Text(initials.isEmpty ? "·" : initials)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(LB.lemonInk)
            .frame(width: size, height: size)
            .background(Circle().fill(LB.lemon))
            .accessibilityHidden(true)
    }
}
