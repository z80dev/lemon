#if DEBUG
import SwiftUI
import LemonBotKit

/// The key screens captured by the macOS snapshot test (and previewable on any platform).
public enum LemonBotSnapshotScene: String, CaseIterable {
    case sidebarConversation, inspectorActivity, composerActiveRun, failedRun, settings, emptyState
    case backendDown, controllerDown, reconnectRequired
    case instancePane, instanceRunning
    case actionRecovery

    /// `sidebar-conversation`, used for output file names.
    public var slug: String {
        rawValue.reduce(into: "") { $0 += $1.isUppercase ? "-" + String($1).lowercased() : String($1) }
    }
    public var scenario: LemonBotFixtureScenario {
        switch self {
        case .sidebarConversation: return .chiefOfStaff
        case .inspectorActivity, .composerActiveRun: return .activeRun
        case .failedRun: return .failedRun
        case .settings, .actionRecovery: return .chiefOfStaff
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
