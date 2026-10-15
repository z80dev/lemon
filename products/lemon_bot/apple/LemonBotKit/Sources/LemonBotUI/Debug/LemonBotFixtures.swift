#if DEBUG
import Foundation
import LemonBotKit

/// Which fixture conversation starts selected. The workspace content is identical in every scenario.
public enum LemonBotFixtureScenario: Hashable {
    /// Zest (Chief of Staff): two days of conversation, grouped replies, markdown, code, a card.
    case chiefOfStaff
    /// Atlas (Research): live run with two completed tool calls and one started, plus a composer draft.
    case activeRun
    /// Marlow (Travel): a failed run rendered as an empty assistant message plus a retry-safe error.
    case failedRun
    /// Workspace loaded, nothing selected.
    case noSelection
    case backendDown, controllerDown, reconnectRequired

    public var conversationID: ID? {
        switch self {
        case .chiefOfStaff: return LemonBotFixtureID.zestMain
        case .activeRun: return LemonBotFixtureID.atlasMain
        case .failedRun: return LemonBotFixtureID.marlowMain
        case .noSelection: return nil
        case .backendDown, .controllerDown, .reconnectRequired: return LemonBotFixtureID.zestMain
        }
    }
}

/// Credentials never leave memory; fixtures hold no real secret.
private final class FixtureCredentialStore: AccountCredentialStore {
    func load() throws -> [StoredAccount] { [] }
    func save(_ account: StoredAccount) throws {}
    func remove(_ id: String) throws {}
    func loadPendingPairing() throws -> PendingDevicePairing? { nil }
    func savePendingPairing(_ pairing: PendingDevicePairing) throws {}
    func removePendingPairing() throws {}
}

/// DEBUG-only owner workspace for design review and snapshot tests. It drives the real `LemonBotStore`
/// against an in-process `URLProtocol` stub, so views behave exactly as they do against a backend.
public enum LemonBotFixtures {
    /// Returns immediately; the workspace finishes loading asynchronously (the root shows onboarding for a moment).
    /// Used by the iOS `-LBFixtures` launch mode.
    @MainActor public static func makeStore(scenario: LemonBotFixtureScenario = .chiefOfStaff) -> LemonBotStore {
        let store = newStore(scenario: scenario)
        Task { @MainActor in await populate(store, scenario: scenario) }
        return store
    }

    /// Returns once the workspace is fully loaded, selected, and pinned online. Used by the snapshot tests.
    @MainActor public static func loadStore(scenario: LemonBotFixtureScenario = .chiefOfStaff) async -> LemonBotStore {
        let store = newStore(scenario: scenario)
        await populate(store, scenario: scenario)
        return store
    }

    @MainActor private static func newStore(scenario: LemonBotFixtureScenario) -> LemonBotStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LemonBotFixtures-\(UUID().uuidString)", isDirectory: true)
        let store = LemonBotStore(keychain: FixtureCredentialStore(), persistence: ClientPersistence(root: root))
        store.installFixtureSession(FixtureURLProtocol.makeSession(controllerDown: scenario == .controllerDown))
        return store
    }

    @MainActor private static func populate(_ store: LemonBotStore, scenario: LemonBotFixtureScenario) async {
        let world = FixtureWorld.shared
        let account = StoredAccount(id: "fixture-account", baseURL: FixtureURLProtocol.baseURL, email: "sam@example.invalid", displayName: "Sam Rivera", token: "fixture-not-a-secret",
                                    userID: LemonBotFixtureID.user, workspaceID: LemonBotFixtureID.workspace, deviceID: "device_FixtureThisDevice", sessionID: "session_Fixture",
                                    sessionExpiresAtMs: (world.now.timeIntervalSince1970 + 86_400) * 1000)
        do {
            try await store.restoreAccount(account)
            store.pinFixtureOnline()
            // Preload transcripts and drafts for every conversation without selecting any of them
            // (`openConversation` selects, and a view opened mid-load would re-select its own conversation).
            for conversation in world.conversations {
                guard let id = conversation["id"] as? String else { continue }
                let page: Page<TranscriptEntry> = try await store.read("/conversations/\(id)/entries", query: ["limit": "200"])
                store.entries[id] = page.items
                let draft: ComposerDraft = try await store.read("/conversations/\(id)/composer")
                store.drafts[id] = LocalComposerDraft(text: draft.text, attachmentIDs: draft.attachmentIds, replyToEntryID: draft.replyToEntryId, revision: draft.revision)
            }
        } catch { store.errorMessage = "Fixture workspace failed to load: \(error.localizedDescription)" }
        store.selectedConversationID = scenario.conversationID
        store.pinFixtureOnline()
        switch scenario {
        case .backendDown:
            store.account?.baseURL = URL(string: "http://127.0.0.1:4080")!
            store.pinFixtureConnectionFailure(URLError(.cannotConnectToHost), nextRetry: Date().addingTimeInterval(12))
        case .controllerDown:
            if let status = try? JSONDecoder().decode(InstanceStatus.self, from: JSONSerialization.data(withJSONObject: world.instance(controllerDown: true))) { store.pinFixtureControllerDown(status) }
        case .reconnectRequired:
            store.connectionState = "reconnect_required"
            store.connectionIssue = ConnectionIssue.classify(ClientError.signedOut, baseURL: account.baseURL, email: account.email)
        default: break
        }
    }
}
#endif
