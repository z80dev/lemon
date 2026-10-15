import SwiftUI
import LemonBotKit

/// Messaging-first workspace: Bot list on the left, the conversation (with its inspector) on the right.
/// Admin surfaces live in Settings; Inbox and Activity are compact sidebar entries.
public struct LemonBotRootView: View {
    private let store: LemonBotStore
    /// Device-specific settings (iOS permissions, shared items) shown as Settings → This iPhone.
    private let platformSettings: AnyView?
    @State private var destination: WorkspaceDestination = .conversation
    @State private var visibility: NavigationSplitViewVisibility = .all
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @State private var inspector: InspectorPresentation
    @State private var newBot = false
    @State private var newGroup = false
    @State private var newAccount = false
    @State private var search = false
    @State private var pairing = false
    @State private var settings = false
    @State private var filterFocusRequest = 0
    #if os(macOS)
    @Environment(\.openSettings) private var openSettingsScene
    #endif
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    public init(store: LemonBotStore) { self.store = store; platformSettings = nil; _inspector = State(initialValue: InspectorPresentation()) }
    public init<Platform: View>(store: LemonBotStore, @ViewBuilder platformSettings: () -> Platform) {
        self.store = store; self.platformSettings = AnyView(platformSettings()); _inspector = State(initialValue: InspectorPresentation())
    }
    init(store: LemonBotStore, inspector: InspectorPresentation) { self.store = store; platformSettings = nil; _inspector = State(initialValue: inspector) }
    private var reduceMotion: Bool { systemReduceMotion || store.prefersReducedMotion }
    private var selectedBot: Bot? { store.bot(for: store.conversations.first { $0.id == store.selectedConversationID }) }
    private var orderedBots: [Bot] {
        let visible = store.bots.filter { !$0.sidebar.hidden }
        return visible.filter(\.sidebar.pinned).sorted { $0.sidebar.rank < $1.sidebar.rank } + visible.filter { !$0.sidebar.pinned }.sorted { $0.sidebar.rank < $1.sidebar.rank }
    }

    public var body: some View {
        Group {
            if store.account == nil { OnboardingView(store: store) }
            else { workspace }
        }
        .id(store.account?.id)
        .environment(\.lbReduceMotion, store.prefersReducedMotion)
        .tint(LB.accent)
        .sheet(isPresented: $newBot) { BotEditorView(store: store) }
        .sheet(isPresented: $newGroup) { GroupEditorView(store: store) }
        .sheet(isPresented: $search) { SearchPaletteView(store: store) }
        .sheet(isPresented: $newAccount) { OnboardingView(store: store) }
        .sheet(isPresented: $pairing) {
            #if os(macOS)
            OwnerPairingView(store: store)
            #else
            PhonePairingView(store: store)
            #endif
        }
        #if os(iOS)
        .sheet(isPresented: $settings) {
            if let platformSettings { LemonBotSettingsView(store: store) { platformSettings } } else { LemonBotSettingsView(store: store) }
        }
        #endif
        .onChange(of: store.account?.id) { _, _ in newAccount = false; destination = .conversation; compactColumn = .sidebar }
        .preferredColorScheme(store.user?.preferences.appearance == "dark" ? .dark : store.user?.preferences.appearance == "light" ? .light : nil)
        .onChange(of: store.selectedConversationID) { _, id in if id != nil { destination = .conversation; compactColumn = .detail } }
        .onChange(of: store.navigationTarget) { _, target in
            guard let target else { return }
            if target.machineID != nil { destination = .linkedMachine }
            else if target.routineRunID != nil && store.selectedConversationID != nil { destination = .conversation }
            else if target.routineID != nil { destination = .linkedRoutine }
            else if target.taskConversationID != nil || target.conversationID != nil { destination = .conversation }
            else if target.botID != nil { destination = .linkedBot }
            compactColumn = .detail
        }
    }

    private var workspace: some View {
        NavigationSplitView(columnVisibility: $visibility, preferredCompactColumn: $compactColumn) {
            SidebarView(
                store: store, destination: $destination, inspector: inspector,
                openConversation: openRoom, openDestination: { destination = $0; compactColumn = .detail }, openSettings: openSettings,
                newBot: { newBot = true }, newGroup: { newGroup = true },
                searchEverything: { search = true }, reconnect: { pairing = true },
                filterFocusRequest: $filterFocusRequest
            )
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 380)
            .ignoresSafeArea(edges: .top)
            #else
            .navigationTitle("Chats")
            #endif
        } detail: {
            VStack(spacing: 0) {
                #if os(macOS)
                if store.connectionIssue != nil { ConnectionStatusView(store: store).padding(12) }
                #endif
                NavigationStack { detail }.frame(maxHeight: .infinity)
            }
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 460, ideal: 760)
            #endif
        }
        .navigationSplitViewStyle(.balanced)
        .background { shortcuts }
    }

    @ViewBuilder private var detail: some View {
        Group {
            switch destination {
            case .activity: ActivityHubView(store: store).navigationTitle("Activity")
            case .inbox: InboxView(store: store).navigationTitle("Inbox")
            case .pending: PendingIntentView(store: store)
            case .linkedMachine: if let id = store.navigationTarget?.machineID { MachineDetailView(store: store, machineID: id) } else { EmptySelectionView() }
            case .linkedBot: if let id = store.navigationTarget?.botID { BotOverviewView(store: store, botID: id) } else { EmptySelectionView() }
            case .linkedRoutine: if let id = store.navigationTarget?.routineID { RoutineDetailView(store: store, routineID: id) } else { EmptySelectionView() }
            case .conversation:
                if let id = store.selectedConversationID {
                    ConversationView(store: store, conversationID: id, inspector: inspector).id(id)
                        .transition(.opacity)
                } else { EmptySelectionView() }
            }
        }
        .animation(reduceMotion ? nil : LBMotion.fade, value: store.selectedConversationID)
        .background(LB.canvas)
    }

    /// Keyboard shortcuts that act on the whole workspace (zero-size buttons keep them active without chrome).
    private var shortcuts: some View {
        ZStack {
            Button("Search everything") { search = true }.keyboardShortcut("k", modifiers: .command)
            Button("New Bot") { newBot = true }.keyboardShortcut("n", modifiers: .command).disabled(!store.isOnline)
            Button("Find Bots") { filterFocusRequest += 1 }.keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Previous Bot") { adjacentBot(-1) }.keyboardShortcut("[", modifiers: .command)
            Button("Next Bot") { adjacentBot(1) }.keyboardShortcut("]", modifiers: .command)
            Button("Previous Bot") { adjacentBot(-1) }.keyboardShortcut(.upArrow, modifiers: .option)
            Button("Next Bot") { adjacentBot(1) }.keyboardShortcut(.downArrow, modifiers: .option)
            Button("Toggle Bot details") { lbWithAnimation(reduceMotion) { inspector.toggle() } }.keyboardShortcut("i", modifiers: [.command, .option])
            Button("Bot details") { inspector.show(.details) }.keyboardShortcut(",", modifiers: [.command, .shift])
            Button("Connect apps") { openSettings(.apps) }.keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Skills and routines") { openSettings(.library) }.keyboardShortcut("w", modifiers: [.command, .shift])
            #if os(iOS)
            Button("Settings") { openSettings(.account) }.keyboardShortcut(",", modifiers: .command)
            #endif
            ForEach(Array(orderedBots.prefix(9).enumerated()), id: \.element.id) { index, bot in
                Button(bot.name) { openRoom(bot.mainConversationId) }.keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }
        .buttonStyle(.plain)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func openRoom(_ id: ID) {
        destination = .conversation
        store.selectedConversationID = id
        compactColumn = .detail
    }
    private func openSettings(_ pane: SettingsPane) {
        SettingsRouter.shared.pane = pane
        #if os(macOS)
        openSettingsScene()
        #else
        settings = true
        #endif
    }
    private func adjacentBot(_ offset: Int) {
        let bots = orderedBots
        guard !bots.isEmpty else { return }
        let index = bots.firstIndex { $0.id == selectedBot?.id } ?? (offset > 0 ? -1 : 0)
        openRoom(bots[(index + offset + bots.count) % bots.count].mainConversationId)
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
            }.formStyle(.grouped).disabled(action.busy || store.connectionState != "online").navigationTitle("Organize Bots")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                    #if os(iOS)
                    ToolbarItem(placement: .primaryAction) { EditButton() }
                    #endif
                }
                .confirmationDialog("Delete section \(deleteSection?.name ?? "")? Bots will be unassigned, not deleted.", isPresented: Binding(get: { deleteSection != nil }, set: { if !$0 { deleteSection = nil } })) {
                    Button("Delete section", role: .destructive) { Task { await action.perform { guard let section = deleteSection else { return }; let _: Deleted = try await store.mutate("DELETE", resourcePath("sections", section.id), body: ["revision": .number(Double(section.revision))]); deleteSection = nil; try await store.refresh() } } }
                }
        }.frame(minWidth: 320, minHeight: 400)
    }
}
