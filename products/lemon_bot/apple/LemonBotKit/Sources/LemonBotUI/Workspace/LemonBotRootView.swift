import SwiftUI
import LemonBotKit

public struct LemonBotRootView: View {
    private let store: LemonBotStore
    @State private var destination = "conversation"
    @State private var visibility: NavigationSplitViewVisibility = .all
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @State private var newBot = false
    @State private var newGroup = false
    @State private var newAccount = false
    @State private var search = false
    @State private var unreadOnly = false
    @State private var hidden = false
    @State private var rosterQuery = ""
    @State private var sectionEditor = false
    @State private var action = UIActionState()
    @FocusState private var rosterFocused: Bool
    public init(store: LemonBotStore) { self.store = store }
    private var selectedBot: Bot? {
        guard let room = store.conversations.first(where: { $0.id == store.selectedConversationID }) else { return nil }
        return store.bots.first { $0.id == room.botIds.first }
    }
    public var body: some View {
        Group {
            if store.account == nil { OnboardingView(store: store) }
            else {
                #if os(macOS)
                NavigationSplitView(columnVisibility: $visibility) {
                    roster.navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 380)
                } content: {
                    NavigationStack { selectedContent }
                        .navigationSplitViewColumnWidth(min: 400, ideal: 660)
                } detail: {
                    NavigationStack {
                        if let selectedBot, destination == "conversation" { BotOverviewView(store: store, botID: selectedBot.id) }
                        else { Text("Select a Bot to inspect its identity, host, capabilities and work.").foregroundStyle(.secondary).padding() }
                    }.navigationSplitViewColumnWidth(min: 270, ideal: 360, max: 520)
                }
                #else
                NavigationSplitView(columnVisibility: $visibility, preferredCompactColumn: $compactColumn) { roster } detail: { NavigationStack { selectedContent } }
                #endif
            }
        }.id(store.account?.id).sheet(isPresented: $newBot) { BotEditorView(store: store) }
            .sheet(isPresented: $newGroup) { GroupEditorView(store: store) }
            .sheet(isPresented: $search) { SearchPaletteView(store: store) }
            .sheet(isPresented: $sectionEditor) { SectionEditorView(store: store) }
            .sheet(isPresented: $newAccount) { OnboardingView(store: store) }
            .onChange(of: store.account?.id) { _, _ in newAccount = false; destination = "conversation"; compactColumn = .sidebar }
            .preferredColorScheme(store.user?.preferences.appearance == "dark" ? .dark : store.user?.preferences.appearance == "light" ? .light : nil)
            .onChange(of: store.selectedConversationID) { _, id in if id != nil { destination = "conversation"; compactColumn = .detail } }
            .onChange(of: store.navigationTarget) { _, target in
                guard let target else { return }
                if target.machineID != nil { destination = "linked-machine" }
                else if target.routineRunID != nil && store.selectedConversationID != nil { destination = "conversation" }
                else if target.routineID != nil { destination = "linked-routine" }
                else if target.taskConversationID != nil || target.conversationID != nil { destination = "conversation" }
                else if target.botID != nil { destination = "linked-bot" }
                compactColumn = .detail
            }
    }
    private var roster: some View {
        List {
            SwiftUI.Section {
                Text(store.workspace?.name ?? "Lemon Bot").font(.headline)
                StatusBadge(text: store.connectionState)
                TextField("Search Bots / groups", text: $rosterQuery).autocorrectionDisabled().focused($rosterFocused)
                Toggle("Unread only", isOn: $unreadOnly)
                Toggle("Show hidden Bots", isOn: $hidden)
                HStack {
                    Button("New Bot", systemImage: "plus") { newBot = true }.keyboardShortcut("n", modifiers: .command)
                    Button("Group", systemImage: "person.2.badge.plus") { newGroup = true }
                }.disabled(store.connectionState != "online")
            }
            if store.bots.isEmpty {
                SwiftUI.Section("Finish real setup") {
                    Text("First attach an owned machine, wait for verified Online, then create a focused Bot. Setup is not complete without a real Bot on a real machine.").font(.caption)
                    Button("Attach a machine") { choose("machines") }
                }
            }
            botSection("Pinned", bots: visibleBots.filter(\.sidebar.pinned))
            ForEach(store.sections.sorted { $0.rank < $1.rank }) { section in
                SwiftUI.Section {
                    if !section.collapsed { ForEach(visibleBots.filter { !$0.sidebar.pinned && $0.sidebar.sectionId == section.id }) { bot in botRow(bot) } }
                } header: {
                    HStack { Text(section.name); Spacer(); Button(section.collapsed ? "Expand" : "Collapse") { Task { await changeSection(section, collapsed: !section.collapsed) } }.font(.caption) }
                }
            }
            botSection(hidden ? "Hidden / unassigned" : "Teammates", bots: visibleBots.filter { !$0.sidebar.pinned && $0.sidebar.sectionId == nil })
            SwiftUI.Section("Groups and tasks") {
                ForEach(store.conversations.filter { ["group", "task"].contains($0.kind) && (!unreadOnly || $0.unreadCount > 0) && (rosterQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(rosterQuery)) }) { room in
                    Button { openRoom(room.id) } label: {
                        HStack { Label(room.name, systemImage: room.kind == "group" ? "person.2" : "arrow.triangle.branch"); Spacer(); if room.unreadCount > 0 { Text("\(room.unreadCount)").font(.caption.bold()) } }
                    }
                }
            }
            SwiftUI.Section("Workspace") {
                hubButton("Search / jump", "magnifyingglass", "search")
                hubButton("Inbox", "tray", "inbox")
                if !store.pendingIntents.isEmpty { hubButton("Unconfirmed actions · \(store.pendingIntents.count)", "exclamationmark.arrow.triangle.2.circlepath", "pending") }
                hubButton("Activity + Upcoming", "clock", "activity")
                hubButton("Machines", "desktopcomputer", "machines")
                hubButton("Skills, routines and memory", "books.vertical", "library")
                hubButton("Templates", "square.on.square", "templates")
                hubButton("Connect apps and channels", "link", "integrations")
                hubButton("Settings", "gearshape", "settings")
                Button("Organize synced sections") { sectionEditor = true }
            }
            SwiftUI.Section("Account") {
                Text(store.user?.displayName ?? store.account?.displayName ?? "")
                ForEach(store.accounts.filter { $0.id != store.account?.id }) { account in Button("Switch to \(account.displayName) · \(account.baseURL.host ?? "")") { Task { await action.perform { try await store.restoreAccount(account) } } } }
                Button("Add another account or backend") { newAccount = true }
                Button("Sign out") { Task { await action.perform { try await store.signOut() } } }
                Button("Refresh authoritative state") { Task { await action.perform { try await store.refresh() } } }
                ActionErrorView(message: action.error ?? store.errorMessage)
            }
        }.listStyle(.sidebar).navigationTitle("Teammates")
            .toolbar {
                Button("Search", systemImage: "magnifyingglass") { search = true }.keyboardShortcut("k", modifiers: .command)
                Button("Toggle roster", systemImage: "sidebar.left") {
                    #if os(macOS)
                    visibility = visibility == .all ? .doubleColumn : .all
                    #else
                    visibility = visibility == .all ? .detailOnly : .all
                    #endif
                }.keyboardShortcut("b", modifiers: .command)
                Menu("Keyboard navigation") {
                    Button("Find Bots") { rosterFocused = true }.keyboardShortcut("f", modifiers: [.command, .shift])
                    Button("Settings") { choose("settings") }.keyboardShortcut(",", modifiers: .command)
                    Button("Connect apps") { choose("integrations") }.keyboardShortcut("m", modifiers: [.command, .shift])
                    Button("Skills and routines") { choose("library") }.keyboardShortcut("w", modifiers: [.command, .shift])
                    Button("Bot overview / settings") { choose("overview") }.keyboardShortcut(",", modifiers: [.command, .shift])
                    Button("Previous Bot") { Task { await adjacentBot(-1) } }.keyboardShortcut(.upArrow, modifiers: .option)
                    Button("Next Bot") { Task { await adjacentBot(1) } }.keyboardShortcut(.downArrow, modifiers: .option)
                    ForEach(Array(visibleBots.prefix(9).enumerated()), id: \.element.id) { index, bot in
                        Button(bot.name) { Task { await openBot(bot) } }.keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    }
                }
                #if os(iOS)
                EditButton()
                #endif
            }
    }
    private var visibleBots: [Bot] {
        store.bots.filter { $0.sidebar.hidden == hidden && (!unreadOnly || $0.sidebar.unread) && (rosterQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(rosterQuery) || $0.title.localizedCaseInsensitiveContains(rosterQuery)) }.sorted { $0.sidebar.rank < $1.sidebar.rank }
    }
    private func botSection(_ title: String, bots: [Bot]) -> some View { SwiftUI.Section(title) { ForEach(bots) { bot in botRow(bot) }.onMove { indices, target in Task { await reorder(bots, from: indices, to: target) } } } }
    private func botRow(_ bot: Bot) -> some View {
        Button { Task { await openBot(bot) } } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack { Text(bot.name).fontWeight(bot.sidebar.unread ? .bold : .regular); Spacer(); if bot.sidebar.unread { Image(systemName: "circle.fill").font(.system(size: 7)) }; StatusBadge(text: store.connectionState == "online" ? bot.activity : "last known: \(bot.activity)") }
                Text("\(bot.title) · \(store.machines.first(where: { $0.id == bot.machineId })?.name ?? bot.machineId)").font(.caption).foregroundStyle(.secondary)
            }
        }.buttonStyle(.plain).contextMenu {
            Button(bot.sidebar.pinned ? "Unpin" : "Pin") { Task { await sidebar(bot, ["pinned": .bool(!bot.sidebar.pinned)]) } }
            Button(bot.sidebar.hidden ? "Unhide" : "Hide · work continues") { Task { await sidebar(bot, ["hidden": .bool(!bot.sidebar.hidden)]) } }.disabled(bot.required && bot.ownerUserId != store.user?.id)
            Button(bot.sidebar.unread ? "Mark read" : "Mark unread") { Task { await sidebar(bot, ["unread": .bool(!bot.sidebar.unread)]) } }
            Menu("Move to section") {
                Button("Unassigned") { Task { await sidebar(bot, ["sectionId": .null]) } }
                ForEach(store.sections) { section in Button(section.name) { Task { await sidebar(bot, ["sectionId": .string(section.id)]) } } }
            NavigationLink("Overview / identity / Job") { BotOverviewView(store: store, botID: bot.id) }
        }
    }
    private func hubButton(_ label: String, _ icon: String, _ target: String) -> some View { Button { if target == "search" { search = true } else { choose(target) } } label: { Label(label, systemImage: icon) } }
    private func choose(_ target: String) { destination = target; compactColumn = .detail }
    @ViewBuilder private var selectedContent: some View {
        switch destination {
        case "machines": MachineHubView(store: store)
        case "library": LibraryHubView(store: store)
        case "settings": SettingsHubView(store: store)
        case "integrations": IntegrationsHubView(store: store)
        case "activity": ActivityHubView(store: store)
        case "templates": TemplateHubView(store: store)
        case "inbox": InboxView(store: store)
        case "pending": PendingIntentView(store: store)
        case "overview": if let selectedBot { BotOverviewView(store: store, botID: selectedBot.id) } else { EmptySelectionView() }
        case "linked-machine": if let id = store.navigationTarget?.machineID { MachineDetailView(store: store, machineID: id) } else { EmptySelectionView() }
        case "linked-bot": if let id = store.navigationTarget?.botID { BotOverviewView(store: store, botID: id) } else { EmptySelectionView() }
        case "linked-routine": if let id = store.navigationTarget?.routineID { RoutineDetailView(store: store, routineID: id) } else { EmptySelectionView() }
        default:
            if let id = store.selectedConversationID { ConversationView(store: store, conversationID: id).id(id) }
            else { EmptySelectionView() }
        }
    }
    private func openRoom(_ id: ID) { store.selectedConversationID = id; destination = "conversation"; compactColumn = .detail }
    private func adjacentBot(_ offset: Int) async {
        let bots = visibleBots
        guard !bots.isEmpty else { return }
        let index = bots.firstIndex { $0.id == selectedBot?.id } ?? 0
        let next = (index + offset + bots.count) % bots.count
        await openBot(bots[next])
    }
    private func openBot(_ bot: Bot) async {
        if bot.visibility == "personal" { openRoom(bot.mainConversationId); return }
        await action.perform {
            let room: Conversation = try await store.mutate("POST", "/conversations", body: ["kind": .string("team_dm"), "botIds": strings([bot.id])])
            try await store.refresh(); openRoom(room.id)
        }
    }
    private func sidebar(_ bot: Bot, _ fields: JSONObject) async {
        guard store.connectionState == "online" else { return }
        await action.perform { var body = fields; body["revision"] = .number(Double(bot.revision)); let updated: Bot = try await store.mutate("PATCH", resourcePath("bots", bot.id, "/sidebar"), body: body); if let index = store.bots.firstIndex(where: { $0.id == updated.id }) { store.bots[index] = updated } }
    }
    private func reorder(_ bots: [Bot], from: IndexSet, to: Int) async {
        guard store.connectionState == "online" else { return }
        await action.perform {
            var ordered = bots; ordered.move(fromOffsets: from, toOffset: to)
            for (rank, bot) in ordered.enumerated() {
                let latest: Bot = try await store.read(resourcePath("bots", bot.id))
                let _: Bot = try await store.mutate("PATCH", resourcePath("bots", bot.id, "/sidebar"), body: ["revision": .number(Double(latest.revision)), "rank": .number(Double(rank))])
            }
            try await store.refresh()
        }
    }
    private func changeSection(_ section: LemonBotKit.Section, collapsed: Bool) async {
        await action.perform { let _: LemonBotKit.Section = try await store.mutate("PATCH", resourcePath("sections", section.id), body: ["revision": .number(Double(section.revision)), "collapsed": .bool(collapsed)]); try await store.refresh() }
    }
}

struct SectionEditorView: View {
    let store: LemonBotStore
    init(store: LemonBotStore) { self.store = store }
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var editedNames: [ID: String] = [:]
    @State private var deleteSection: LemonBotKit.Section?
    @State private var action = UIActionState()
    var body: some View {
        NavigationStack {
            Form {
                SwiftUI.Section("New section") {
                    TextField("Name", text: $name)
                    Button("Create") { Task { await action.perform { let _: LemonBotKit.Section = try await store.mutate("POST", "/sections", body: ["name": .string(name), "rank": .number(Double(store.sections.count))]); name = ""; try await store.refresh() } } }.disabled(name.isEmpty)
                }
                SwiftUI.Section("Synced organization") {
                    ForEach(store.sections.sorted { $0.rank < $1.rank }) { section in
                        HStack {
                            TextField(section.name, text: Binding(get: { editedNames[section.id] ?? section.name }, set: { editedNames[section.id] = $0 }))
                            Button("Rename") { Task { await action.perform { let _: LemonBotKit.Section = try await store.mutate("PATCH", resourcePath("sections", section.id), body: ["revision": .number(Double(section.revision)), "name": .string(editedNames[section.id] ?? section.name)]); try await store.refresh() } } }
                            Button("Delete", role: .destructive) { deleteSection = section }
                        }
                    }.onMove { indices, target in Task { await action.perform {
                        var ordered = store.sections.sorted { $0.rank < $1.rank }; ordered.move(fromOffsets: indices, toOffset: target)
                        for (rank, section) in ordered.enumerated() { let _: LemonBotKit.Section = try await store.mutate("PATCH", resourcePath("sections", section.id), body: ["revision": .number(Double(section.revision)), "rank": .number(Double(rank))]) }
                        try await store.refresh()
                    } } }
                }
                Text("Deleting a section unassigns your Bots; it does not delete them.").font(.caption)
                ActionErrorView(message: action.error)
            }.disabled(action.busy || store.connectionState != "online").navigationTitle("Organize Bots")
                .toolbar {
                    Button("Close") { dismiss() }
                    #if os(iOS)
                    EditButton()
                    #endif
                }
                .confirmationDialog("Delete section \(deleteSection?.name ?? "")? Bots will be unassigned, not deleted.", isPresented: Binding(get: { deleteSection != nil }, set: { if !$0 { deleteSection = nil } })) {
                    Button("Delete section", role: .destructive) { Task { await action.perform { guard let section = deleteSection else { return }; let _: Deleted = try await store.mutate("DELETE", resourcePath("sections", section.id), body: ["revision": .number(Double(section.revision))]); deleteSection = nil; try await store.refresh() } } }
                }
        }.frame(minWidth: 320, minHeight: 400)
    }
}
