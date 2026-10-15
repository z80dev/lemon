import SwiftUI
import LemonBotKit

/// Fixture data for the DEBUG snapshot harness. When non-nil the inspector performs no network loads.
struct BotInspectorPreview {
    var overview: BotOverview? = nil
    var recentRuns: [Run] = []
}

/// Deeper screens opened from the inspector as sheets (the inspector itself is not inside a navigation stack).
enum InspectorDestination: Identifiable, Hashable {
    case machine(ID), activityHub, memory, skillsLibrary, templates, routine(ID), overview, apps, job, editor, lifecycle
    var id: String {
        switch self {
        case .machine(let id): return "machine-\(id)"
        case .routine(let id): return "routine-\(id)"
        case .activityHub: return "activityHub"
        case .memory: return "memory"
        case .skillsLibrary: return "skills"
        case .templates: return "templates"
        case .overview: return "overview"
        case .apps: return "apps"
        case .job: return "job"
        case .editor: return "editor"
        case .lifecycle: return "lifecycle"
        }
    }
}

/// Right-hand inspector for a Bot: what it is doing (Activity), who it is (Details), what it keeps (Library).
struct BotInspectorView: View {
    let store: LemonBotStore
    let botID: ID
    let presentation: InspectorPresentation
    let preview: BotInspectorPreview?
    init(store: LemonBotStore, botID: ID, presentation: InspectorPresentation, preview: BotInspectorPreview? = nil) {
        self.store = store; self.botID = botID; self.presentation = presentation; self.preview = preview
    }
    @State private var loadedOverview: BotOverview?
    @State private var loadedRuns: [Run] = []
    @State private var skills: [Skill] = []
    @State private var routines: [Routine] = []
    @State private var loadError: String?
    @State private var destination: InspectorDestination?
    @Namespace private var tabNamespace
    @Environment(\.lbReduceMotion) private var reduceMotion

    private var overview: BotOverview? { preview != nil ? preview?.overview : loadedOverview }
    private var runs: [Run] { preview != nil ? (preview?.recentRuns ?? []) : loadedRuns }
    private var bot: Bot? { store.bots.first { $0.id == botID } ?? overview?.bot }
    private var manages: Bool { bot.map { $0.ownerUserId == store.user?.id } ?? false }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                VStack(spacing: 16) {
                    if let bot {
                        InspectorHeader(store: store, bot: bot, overview: overview, edit: manages ? { destination = .editor } : nil)
                        tabBar
                        Group {
                            switch presentation.tab {
                            case .activity:
                                InspectorActivityTab(store: store, bot: bot, overview: overview, runs: runs, open: { destination = $0 })
                            case .details:
                                InspectorDetailsTab(store: store, bot: bot, overview: overview, skills: skills, manages: manages, open: { destination = $0 })
                            case .library:
                                InspectorLibraryTab(store: store, bot: bot, routines: routines, open: { destination = $0 })
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(presentation.tab)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                    } else {
                        ProgressView().padding(.top, 80)
                    }
                    ActionErrorView(message: loadError)
                }
                .padding(.horizontal, 16).padding(.top, 44).padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            Button { presentation.isPresented = false } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)) }
                .buttonStyle(GhostCircleButtonStyle(size: 30))
                .accessibilityLabel("Close details")
                .keyboardShortcut(.cancelAction)
                .padding(.top, 10).padding(.trailing, 12)
        }
        .background(LB.sidebar)
        .lbAnimation(LBMotion.spring, value: presentation.tab)
        .task(id: "\(botID):\(store.eventVersion):\(preview == nil)") { await load() }
        .sheet(item: $destination) { sheet(for: $0) }
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(InspectorTab.allCases) { tab in
                let selected = presentation.tab == tab
                Button { lbWithAnimation(reduceMotion, LBMotion.spring) { presentation.tab = tab } } label: {
                    Text(tab.title).font(LBFont.metaEmphasis)
                        .foregroundStyle(selected ? LB.ink : LB.muted)
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                        .background { if selected { Capsule().fill(LB.selected).matchedGeometryEffect(id: "tab", in: tabNamespace) } }
                        .contentShape(Capsule())
                }.buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(3).background(Capsule().fill(LB.fill))
    }

    @ViewBuilder private func sheet(for destination: InspectorDestination) -> some View {
        if let bot {
            switch destination {
            case .editor: BotEditorView(store: store, bot: bot)
            case .lifecycle: BotLifecycleView(store: store, bot: bot)
            default: InspectorSheet(close: { self.destination = nil }) { deeper(destination, bot) }
            }
        }
    }
    @ViewBuilder private func deeper(_ destination: InspectorDestination, _ bot: Bot) -> some View {
        switch destination {
        case .machine(let id): MachineDetailView(store: store, machineID: id)
        case .activityHub: ActivityHubView(store: store)
        case .memory: MemoryHubView(store: store, botID: bot.id)
        case .skillsLibrary: LibraryHubView(store: store)
        case .templates: TemplateHubView(store: store)
        case .routine(let id): RoutineDetailView(store: store, routineID: id)
        case .overview: BotOverviewView(store: store, botID: bot.id)
        case .apps: IntegrationsHubView(store: store)
        case .job: ScrollView { BotJobEditorView(store: store, bot: bot).padding() }.navigationTitle("Job and instructions")
        case .editor, .lifecycle: EmptyView()
        }
    }

    private func load() async {
        guard preview == nil else { return }
        var failure: String?
        do { loadedOverview = try await store.read(resourcePath("bots", botID, "/overview")) } catch { failure = error.localizedDescription }
        do { loadedRuns = try await allResources(store, "/runs", query: ["botId": botID]).sorted { $0.createdAtMs > $1.createdAtMs } } catch { failure = failure ?? error.localizedDescription }
        do { skills = try await allResources(store, "/skills") } catch { failure = failure ?? error.localizedDescription }
        do { routines = try await allResources(store, "/routines").filter { $0.botId == botID } } catch { failure = failure ?? error.localizedDescription }
        loadError = failure
    }
}

/// Navigation container for a deeper screen presented from the inspector.
private struct InspectorSheet<Content: View>: View {
    let close: () -> Void
    @ViewBuilder var content: Content
    var body: some View {
        NavigationStack {
            content.toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done", action: close) } }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 600)
        #endif
    }
}

// MARK: - Header

private struct InspectorHeader: View {
    let store: LemonBotStore
    let bot: Bot
    let overview: BotOverview?
    let edit: (() -> Void)?
    private var activity: String { overview?.presence.status ?? bot.activity }
    private var machine: Machine? { store.machine(for: bot) ?? overview?.machine }
    var body: some View {
        VStack(spacing: 8) {
            BotBadgedAvatar(store: store, bot: bot, size: 72, presence: AvatarPresence(activity: bot.activity, online: store.isOnline), ring: LB.sidebar)
            Text(bot.name).font(LBFont.title).foregroundStyle(LB.ink).lineLimit(1)
            labelLine
            HStack(spacing: 6) {
                StatusBadge(text: store.isOnline ? activity : "last known: \(activity)")
                HStack(spacing: 5) {
                    Circle().fill(StatusTone(machine?.status ?? overview?.presence.machineStatus ?? "unknown").color).frame(width: 6, height: 6)
                    Text(machine?.name ?? overview?.presence.machineLabel ?? "Unknown machine").lineLimit(1)
                }
                .font(LBFont.chip).foregroundStyle(LB.ink.opacity(0.85))
                .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(LB.fill))
                .accessibilityElement(children: .combine)
            }
        }.frame(maxWidth: .infinity)
    }
    @ViewBuilder private var labelLine: some View {
        let text = bot.title.isEmpty ? "Add a label" : bot.title
        let line = Text(text).font(LBFont.rowSubtitle).foregroundStyle(bot.title.isEmpty ? LB.faint : LB.muted).lineLimit(1)
        if let edit { Button(action: edit) { line }.buttonStyle(.plain).accessibilityLabel("Edit label: \(text)") } else { line }
    }
}

// MARK: - Shared rows

/// Soft tappable row: icon, title, meta, chevron.
struct InspectorRow: View {
    let symbol: String
    let title: String
    var meta: String? = nil
    var chevron = true
    var tint: Color = LB.muted
    var action: (() -> Void)? = nil
    var body: some View {
        if let action { Button(action: action) { content }.buttonStyle(.plain) } else { content }
    }
    private var content: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(LBFont.rowTitle).foregroundStyle(LB.ink).lineLimit(1)
                if let meta, !meta.isEmpty { Text(meta).font(LBFont.meta).foregroundStyle(LB.muted).lineLimit(2).multilineTextAlignment(.leading) }
            }
            Spacer(minLength: 6)
            if chevron { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(LB.faint) }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: LBMetric.rowRadius, style: .continuous).fill(LB.bubble))
        .rowHighlight(selected: false)
        .contentShape(RoundedRectangle(cornerRadius: LBMetric.rowRadius, style: .continuous))
    }
}

/// Section label + stacked rows.
struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title: title).padding(.leading, 4)
            content
        }
    }
}
