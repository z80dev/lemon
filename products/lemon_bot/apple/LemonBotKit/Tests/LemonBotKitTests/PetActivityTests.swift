import XCTest
@testable import LemonBotKit

final class PetActivityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var ms: Double { now.timeIntervalSince1970 * 1000 }
    private func run(_ status: String, id: String = "run", age: Double = 0, conversation: String = "conversation") -> Run {
        Run(id: id, revision: 1, createdAtMs: ms - age * 1000, updatedAtMs: ms, conversationId: conversation, botId: "bot", initiatorUserId: "user", clientNonce: "nonce", status: status, completedAtMs: ["succeeded", "failed"].contains(status) ? ms - age * 1000 : nil)
    }
    private func notification(_ kind: String, id: String = "note", age: Double = 0, user: String = "user", link: String = "lemonbot://workspace/workspace/bot/bot?conversationId=conversation&entryId=entry") -> BotNotification {
        BotNotification(id: id, revision: 1, createdAtMs: ms - age * 1000, updatedAtMs: ms, userId: user, conversationId: "conversation", botId: "bot", kind: kind, title: "Notice", body: "", target: .entry(NotificationTargetEntry(botId: "bot", conversationId: "conversation", entryId: "entry")), deepLink: link)
    }
    private func tool(runID: String? = "run", status: String = "started", title: String = "Read source", tool: String = "read_file") -> TranscriptEntry {
        .toolCall(ToolCallEntry(id: "tool", revision: 1, createdAtMs: ms, updatedAtMs: ms, conversationId: "conversation", seq: 1, timestampMs: ms, actor: Actor(kind: "bot", id: "bot", displayName: "Atlas"), runId: runID, reactions: [], tool: tool, title: title, status: status))
    }
    private func status(signedIn: Bool = true, connection: String = "online", runs: [Run] = [], notifications: [BotNotification] = [], entries: [ID: [TranscriptEntry]] = [:], bots: [Bot] = [], workspace: String = "workspace", at: Date? = nil) -> PetStatus {
        PetActivity.status(signedIn: signedIn, connectionState: connection, userID: "user", workspaceID: workspace, bots: bots, runs: runs, notifications: notifications, entries: entries, now: at ?? now)
    }

    func testPriorityTableAndConnectionStartupStates() {
        let live = run("running"), failed = run("failed"), waiting = run("awaiting_input"), done = run("succeeded")
        let entries: [ID: [TranscriptEntry]] = ["conversation": [tool()]]
        XCTAssertEqual(status(signedIn: false, runs: [waiting, failed, live]).mood, .signedOut)
        XCTAssertEqual(status(signedIn: false).bubble, "Sign in to Lemon Bot")
        XCTAssertEqual(status(connection: "disconnected", runs: [waiting]).mood, .offline)
        XCTAssertEqual(status(connection: "disconnected").bubble, "Offline")
        XCTAssertEqual(status(connection: "reconnect_required").bubble, "Sign in again")
        for connection in ["connecting", "syncing", "online"] { XCTAssertEqual(status(connection: connection).mood, .idle) }
        XCTAssertEqual(status(runs: [waiting, failed, live, done], entries: entries).mood, .needsInput)
        XCTAssertEqual(status(runs: [failed, live, done], entries: entries).mood, .failed)
        XCTAssertEqual(status(runs: [live, done], entries: entries).mood, .working)
        XCTAssertEqual(status(runs: [live, done]).mood, .thinking)
        XCTAssertEqual(status(runs: [done]).mood, .done)
        XCTAssertEqual(status().mood, .idle)
    }

    func testAttentionKindsUnreadUserFilteringAndDeduplication() {
        for (kind, bubble) in [("approval", "Needs approval"), ("question", "Has a question"), ("human_step", "Needs your input")] {
            let note = notification(kind)
            XCTAssertEqual(status(notifications: [note]).bubble, bubble)
            XCTAssertEqual(status(runs: [run("awaiting_input")], notifications: [note]).bubble, bubble)
        }
        XCTAssertEqual(status(runs: [run("awaiting_input")]).bubble, "Needs your input")
        XCTAssertEqual(status(notifications: [notification("approval"), notification("question", id: "second")]).bubble, "2 need you")
        XCTAssertEqual(status(runs: [run("awaiting_input", conversation: "other")], notifications: [notification("approval")]).bubble, "2 need you")
        XCTAssertEqual(status(notifications: [notification("approval", user: "another")]).mood, .idle)
        var read = notification("approval"); read.readAtMs = ms
        var dismissed = notification("approval"); dismissed.dismissedAtMs = ms
        XCTAssertEqual(status(notifications: [read, dismissed, notification("result")]).mood, .idle)
    }

    func testNewestAttentionLinkAndRunFallbackAreValidated() throws {
        let old = notification("approval", age: 10)
        let newer = notification("question", id: "new", link: "lemonbot://workspace/workspace/bot/bot?conversationId=new")
        let newest = status(notifications: [old, newer])
        XCTAssertEqual(try DeepLinkTarget(url: XCTUnwrap(newest.deepLink)).conversationID, "new")
        let fallback = status(runs: [run("awaiting_input")], notifications: [notification("approval", link: "https://evil.example/")])
        XCTAssertEqual(try DeepLinkTarget(url: XCTUnwrap(fallback.deepLink)).conversationID, "conversation")
        XCTAssertNil(status(notifications: [notification("approval", link: "garbage")]).deepLink)
        XCTAssertNil(status(runs: [run("awaiting_input")], workspace: "invalid/id").deepLink)
        let encoded = status(runs: [run("running", conversation: "c&plus+")], workspace: "w&plus+")
        let target = try DeepLinkTarget(url: XCTUnwrap(encoded.deepLink))
        XCTAssertEqual(target.workspaceID, "w&plus+"); XCTAssertEqual(target.conversationID, "c&plus+")
    }

    func testFailureAndCompletionExpirationAndNewestSelection() throws {
        let failed = status(runs: [run("failed", age: 59)])
        XCTAssertEqual(failed.mood, .failed); XCTAssertEqual(failed.validUntil, now.addingTimeInterval(1))
        XCTAssertEqual(status(runs: [run("failed", age: 60)]).mood, .idle)
        XCTAssertEqual(status(runs: [run("failed", age: -1)]).mood, .idle)
        let error = status(notifications: [notification("error", age: 5)])
        XCTAssertEqual(error.bubble, "Run failed"); XCTAssertEqual(error.validUntil, now.addingTimeInterval(55))
        XCTAssertEqual(status(notifications: [notification("error", age: 60)]).mood, .idle)
        XCTAssertEqual(status(notifications: [notification("error", user: "other")]).mood, .idle)
        let done = status(runs: [run("succeeded", id: "old", age: 5), run("succeeded", id: "new", age: 2, conversation: "new")])
        XCTAssertEqual(done.bubble, "Done!"); XCTAssertEqual(done.validUntil, now.addingTimeInterval(4))
        XCTAssertEqual(try DeepLinkTarget(url: XCTUnwrap(done.deepLink)).conversationID, "new")
        XCTAssertEqual(status(runs: [run("succeeded", age: 6)]).mood, .idle)
        XCTAssertEqual(status(runs: [run("outcome_unknown"), run("cancelled")]).mood, .idle)
    }

    func testToolsMustBelongToLiveRunAndTitlesAreHumanized() {
        XCTAssertEqual(status(runs: [run("running")], entries: ["conversation": [tool()]]).detail, "Bot · Read source")
        XCTAssertEqual(status(runs: [run("running")], entries: ["conversation": [tool(title: "")]]).detail, "Bot · Read file")
        for entry in [tool(runID: "old"), tool(runID: nil), tool(status: "completed"), tool(status: "failed")] {
            XCTAssertEqual(status(runs: [run("running")], entries: ["conversation": [entry]]).mood, .thinking)
        }
        XCTAssertEqual(status(runs: [run("running")], entries: ["other": [tool()]]).mood, .thinking)
        XCTAssertEqual(status(runs: [run("running")]).detail, "Bot · Thinking")
        for state in ["reserved", "queued"] { XCTAssertEqual(status(runs: [run(state)]).detail, "Bot · Queued") }
    }

    func testStreamingNewestWorkingRunAndBotNames() throws {
        let bot = Bot(id: "bot", revision: 1, createdAtMs: ms, updatedAtMs: ms, ownerUserId: "user", machineId: "machine", profileId: "profile", name: "Atlas", title: "", job: "", instructions: "", avatar: Avatar(kind: "shape", shape: "circle", color: "yellow"), voice: VoiceSettings(voiceId: "default", speed: 1), skillIds: [], referenceAttachmentIds: [], mainConversationId: "conversation", sidebar: SidebarState(pinned: false, hidden: false, rank: 0, unread: false, notificationsEnabled: true), activity: "idle", activeRunIds: [])
        let message = TranscriptEntry.message(MessageEntry(id: "message", revision: 1, createdAtMs: ms, updatedAtMs: ms, conversationId: "conversation", seq: 1, timestampMs: ms, actor: Actor(kind: "bot", displayName: "Atlas"), runId: "run", reactions: [], role: "assistant", text: "Hello", streaming: true, attachmentIds: []))
        let writing = status(runs: [run("running")], entries: ["conversation": [message]], bots: [bot])
        XCTAssertEqual(writing.mood, .working); XCTAssertEqual(writing.detail, "Atlas · Writing a reply"); XCTAssertNil(writing.bubble)
        let newest = status(runs: [run("running", id: "old", age: 5), run("running", id: "new", conversation: "new")], entries: ["conversation": [tool(runID: "old")]])
        XCTAssertEqual(newest.mood, .working)
        XCTAssertEqual(try DeepLinkTarget(url: XCTUnwrap(newest.deepLink)).conversationID, "conversation")
    }

    @MainActor func testStoreAdapterUsesAccountPresence() {
        let store = LemonBotStore(keychain: PetMemoryCredentials(), persistence: ClientPersistence(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        XCTAssertEqual(store.petStatus(now: now).mood, .signedOut)
    }
}

private final class PetMemoryCredentials: AccountCredentialStore {
    func load() throws -> [StoredAccount] { [] }
    func save(_ account: StoredAccount) throws {}
    func remove(_ id: String) throws {}
    func loadPendingPairing() throws -> PendingDevicePairing? { nil }
    func savePendingPairing(_ pairing: PendingDevicePairing) throws {}
    func removePendingPairing() throws {}
}
