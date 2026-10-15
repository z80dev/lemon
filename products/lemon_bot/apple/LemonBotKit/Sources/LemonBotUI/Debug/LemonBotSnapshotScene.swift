#if DEBUG
import SwiftUI
import LemonBotKit

/// The key screens captured by the macOS snapshot test (and previewable on any platform).
public enum LemonBotSnapshotScene: String, CaseIterable {
    case sidebarConversation, inspectorActivity, composerActiveRun, failedRun, settings, emptyState
    case backendDown, controllerDown, reconnectRequired
    case instancePane, instanceRunning
    case actionRecovery, newBotNoMachine, inboxEmpty
    case appsAndChannels, groupEditor, botLifecycle
    case composerFiles

    /// `sidebar-conversation`, used for output file names.
    public var slug: String {
        rawValue.reduce(into: "") { $0 += $1.isUppercase ? "-" + String($1).lowercased() : String($1) }
    }
    public var scenario: LemonBotFixtureScenario {
        switch self {
        case .sidebarConversation: return .chiefOfStaff
        case .inspectorActivity, .composerActiveRun: return .activeRun
        case .failedRun: return .failedRun
        case .settings, .actionRecovery, .newBotNoMachine, .inboxEmpty, .appsAndChannels, .groupEditor, .botLifecycle, .composerFiles: return .chiefOfStaff
        case .emptyState: return .noSelection
        case .backendDown: return .backendDown
        case .controllerDown: return .controllerDown
        case .reconnectRequired: return .reconnectRequired
        case .instancePane: return .chiefOfStaff
        case .instanceRunning: return .instanceRunning
        }
    }
    /// Point size of the offscreen window the scene is rendered into.
    public var windowSize: CGSize {
        if self == .instancePane || self == .instanceRunning { return CGSize(width: 1100, height: 840) }
        return self == .settings ? CGSize(width: 900, height: 620) : CGSize(width: 1320, height: 840)
    }

    @MainActor public static func view(for scene: LemonBotSnapshotScene, store: LemonBotStore) -> AnyView {
        store.selectedConversationID = scene.scenario.conversationID
        switch scene {
        case .inspectorActivity: return AnyView(LemonBotRootView(store: store, inspector: InspectorPresentation(isPresented: true, tab: .activity)))
        case .composerFiles:
            if let id = scene.scenario.conversationID {
                var draft = store.draft(for: id)
                draft.text = "Review this file."
                draft.fileURLs = [URL(fileURLWithPath: "/fixture/notes.pdf")]
                store.drafts[id] = draft
            }
            return AnyView(LemonBotRootView(store: store))
        case .appsAndChannels:
            return AnyView(NavigationStack { IntegrationsHubView(store: store) })
        case .groupEditor:
            return AnyView(GroupEditorView(store: store))
        case .botLifecycle:
            if let bot = store.bots.first { return AnyView(BotLifecycleView(store: store, bot: bot)) }
            return AnyView(EmptySelectionView())
        case .newBotNoMachine:
            store.machines = []
            return AnyView(BotEditorView(store: store))
        case .inboxEmpty:
            store.notifications = []
            return AnyView(NavigationStack { InboxView(store: store) })
        case .actionRecovery:
            return AnyView(VStack(alignment: .leading, spacing: 20) {
                Text("Unconfirmed actions").font(LBFont.title)
                ActionErrorView(message: humanErrorText(ClientError.outcomeUnknown("support-reference")))
                Text("Reconnect to check this action.").font(LBFont.meta).foregroundStyle(LB.muted)
                Text(pairingStatusLabel("pending_approval")).font(LBFont.body)
            }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(LB.canvas))
        case .settings:
            SettingsRouter.shared.pane = .account
            return AnyView(LemonBotSettingsView(store: store))
        case .instancePane, .instanceRunning:
            SettingsRouter.shared.pane = .instance
            return AnyView(LemonBotSettingsView(store: store))
        default: return AnyView(LemonBotRootView(store: store))
        }
    }
}
#endif
