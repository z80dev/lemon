import XCTest
@testable import LemonBotKit
@testable import LemonBotUI

private final class StatusSyncCredentials: AccountCredentialStore {
    func load() throws -> [StoredAccount] { [] }
    func save(_ account: StoredAccount) throws {}
    func remove(_ id: String) throws {}
    func loadPendingPairing() throws -> PendingDevicePairing? { nil }
    func savePendingPairing(_ pairing: PendingDevicePairing) throws {}
    func removePendingPairing() throws {}
}

@MainActor final class LiveStatusSyncTests: XCTestCase {
    private func store() throws -> LemonBotStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root); TestHTTPProtocol.handler = nil; TestHTTPProtocol.requests = [] }
        let value = LemonBotStore(keychain: StatusSyncCredentials(), persistence: ClientPersistence(root: root))
        value.account = StoredAccount(id: "status", baseURL: URL(string: "https://product.example/v1")!, email: "owner@example.org", displayName: "Owner", token: "session", userID: "owner", workspaceID: "workspace")
        value.transport = try HTTPTransport(baseURL: value.account!.baseURL, token: "session", session: TestHTTPProtocol.session())
        TestHTTPProtocol.requests = []
        return value
    }
    private func run(_ status: String, id: String = "run", revision: Int = 1) -> Run {
        Run(id: id, revision: revision, createdAtMs: 1, updatedAtMs: 2, conversationId: "chat", botId: "bot", initiatorUserId: "owner", clientNonce: id, status: status)
    }
    private func message(runID: String = "run", streaming: Bool = true, revision: Int = 1) -> MessageEntry {
        MessageEntry(id: "reply", revision: revision, createdAtMs: 1, updatedAtMs: 2, conversationId: "chat", seq: 1, timestampMs: 1, actor: Actor(kind: "bot", displayName: "Bot"), runId: runID, reactions: [], role: "assistant", text: "pong", streaming: streaming, attachmentIds: [])
    }
    private func presence(_ value: LemonBotStore, status: String = "idle") async throws {
        let presence = BotPresence(botId: "bot", status: status, machineId: "machine", machineLabel: "Mac", machineStatus: "online", summary: status, measuredAtMs: 2, stale: false)
        try await value.apply(RealtimeEvent(seq: "1", payload: .botPresence(presence), timestampMs: 2))
    }
    private func waitForReconciliation(_ value: LemonBotStore) async throws {
        for _ in 0..<200 where !value.reconcilingRunBots.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(value.reconcilingRunBots.isEmpty, "Reconciliation did not finish")
    }
    func testWritingRequiresTheMessagesOwnLiveRun() throws {
        let value = try store()
        value.entries["chat"] = [.message(message())]
        value.runs = [run("succeeded")]
        XCTAssertNil(value.currentStep(in: "chat"))
        XCTAssertFalse(value.isStreaming(message()))
        value.runs = [run("running", id: "other"), run("succeeded")]
        XCTAssertEqual(value.currentStep(in: "chat")?.title, "Thinking")
        let pet = value.petStatus()
        XCTAssertNotEqual(pet.detail, "Bot · Writing a reply")
        value.runs = [run("running")]
        XCTAssertEqual(value.currentStep(in: "chat")?.title, "Writing a reply")
        XCTAssertTrue(value.isStreaming(message()))
        value.runs = []
        XCTAssertTrue(value.isStreaming(message()), "Unknown runs retain streaming until authoritative completion")
    }
    func testPetDoesNotAttributeAnotherRunsStreamingReply() {
        let status = PetActivity.status(signedIn: true, connectionState: "online", userID: "owner", workspaceID: "workspace", bots: [], runs: [run("running", id: "other")], notifications: [], entries: ["chat": [.message(message())]])
        XCTAssertEqual(status.mood, .thinking)
        XCTAssertEqual(status.detail, "Bot · Thinking")
    }
    func testIdlePresenceRefetchesRunAndStreamingReplyWithoutBlockingApply() async throws {
        let value = try store()
        value.runs = [run("running")]
        value.entries["chat"] = [.message(message())]
        let terminal = run("succeeded", revision: 2)
        let final = TranscriptEntry.message(message(streaming: false, revision: 2))
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            switch request.url?.path {
            case "/v1/runs/run": return (200, [:], try JSONEncoder().encode(terminal))
            case "/v1/entries/reply": return (200, [:], try JSONEncoder().encode(final))
            default: XCTFail("Unexpected request"); throw URLError(.badURL)
            }
        }
        let presence = BotPresence(botId: "bot", status: "idle", machineId: "machine", machineLabel: "Mac", machineStatus: "online", summary: "Idle", measuredAtMs: 2, stale: false)
        try await value.apply(RealtimeEvent(seq: "1", payload: .botPresence(presence), timestampMs: 2))
        for _ in 0..<200 where !value.reconcilingRunBots.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(value.runs.first?.status, "succeeded")
        XCTAssertEqual(value.entries["chat"]?.first?.streaming, false)
        XCTAssertEqual(TestHTTPProtocol.requests.map { $0.url!.path }, ["/v1/runs/run", "/v1/entries/reply"])
        XCTAssertNil(value.currentStep(in: "chat"))
    }
    func testFailedFinalReplyReadRetriesAfterTerminalRunLeavesActiveList() async throws {
        let value = try store()
        value.runs = [run("running")]
        value.entries["chat"] = [.message(message())]
        let terminal = run("succeeded", revision: 2)
        let final = TranscriptEntry.message(message(streaming: false, revision: 2))
        var entryReads = 0
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            switch request.url?.path {
            case "/v1/runs/run": return (200, [:], try JSONEncoder().encode(terminal))
            case "/v1/entries/reply":
                entryReads += 1
                if entryReads == 1 { throw URLError(.networkConnectionLost) }
                return (200, [:], try JSONEncoder().encode(final))
            default: XCTFail("Unexpected request"); throw URLError(.badURL)
            }
        }
        try await presence(value)
        try await waitForReconciliation(value)
        XCTAssertEqual(value.runs.first?.status, "succeeded")
        XCTAssertEqual(value.entries["chat"]?.first?.streaming, true)
        XCTAssertNotNil(value.pendingRunEntryReconciliations["run"])
        value.runs = [] // A later sync contains only active runs.
        try await presence(value, status: "offline")
        try await waitForReconciliation(value)
        XCTAssertEqual(value.entries["chat"]?.first?.streaming, false)
        XCTAssertTrue(value.pendingRunEntryReconciliations.isEmpty)
        XCTAssertEqual(TestHTTPProtocol.requests.map { $0.url!.path }, ["/v1/runs/run", "/v1/entries/reply", "/v1/entries/reply"])
        try await presence(value)
        XCTAssertTrue(value.reconcilingRunBots.isEmpty)
        XCTAssertEqual(TestHTTPProtocol.requests.count, 3)
    }
    func testIdleReconcilesEveryNonterminalStatusIncludingUnknownOutcomes() async throws {
        for status in ["reserved", "queued", "running", "awaiting_input", "outcome_unknown"] {
            let value = try store()
            value.runs = [run(status)]
            let terminal = run("failed", revision: 2)
            TestHTTPProtocol.handler = { request in
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/v1/runs/run")
                return (200, [:], try JSONEncoder().encode(terminal))
            }
            if status == "outcome_unknown" {
                XCTAssertTrue(value.liveRuns(in: "chat").isEmpty, "Uncertain outcomes must not be presented as running")
            }
            try await presence(value)
            try await waitForReconciliation(value)
            XCTAssertEqual(value.runs.first?.status, "failed", status)
            XCTAssertTrue(value.pendingRunEntryReconciliations.isEmpty)
            XCTAssertEqual(TestHTTPProtocol.requests.count, 1)
        }
    }
    func testFailedRunReadRetriesOnLaterIdlePresence() async throws {
        let value = try store()
        value.runs = [run("outcome_unknown")]
        let terminal = run("cancelled", revision: 2)
        var reads = 0
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            reads += 1
            if reads == 1 { throw URLError(.timedOut) }
            return (200, [:], try JSONEncoder().encode(terminal))
        }
        try await presence(value)
        try await waitForReconciliation(value)
        XCTAssertEqual(value.runs.first?.status, "outcome_unknown")
        try await presence(value)
        try await waitForReconciliation(value)
        XCTAssertEqual(value.runs.first?.status, "cancelled")
        XCTAssertEqual(reads, 2)
    }
    func testInvalidOrStillStreamingFinalReplyRemainsPendingUntilFinalized() async throws {
        for invalid in [true, false] {
            let value = try store()
            value.runs = [run("succeeded", revision: 2)]
            value.entries["chat"] = [.message(message())]
            var first = message(streaming: !invalid, revision: 2)
            if invalid { first.runId = "unrelated" }
            let initial = TranscriptEntry.message(first)
            let final = TranscriptEntry.message(message(streaming: false, revision: 3))
            var reads = 0
            TestHTTPProtocol.handler = { request in
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/v1/entries/reply")
                reads += 1
                return (200, [:], try JSONEncoder().encode(reads == 1 ? initial : final))
            }
            try await presence(value)
            try await waitForReconciliation(value)
            XCTAssertEqual(value.entries["chat"]?.first?.streaming, true)
            XCTAssertNotNil(value.pendingRunEntryReconciliations["run"])
            try await presence(value)
            try await waitForReconciliation(value)
            XCTAssertEqual(value.entries["chat"]?.first?.streaming, false)
            XCTAssertTrue(value.pendingRunEntryReconciliations.isEmpty)
            XCTAssertEqual(reads, 2)
        }
    }
    func testOneFailedReplyDoesNotPreventOtherRepliesFromFinalizing() async throws {
        let value = try store()
        value.runs = [run("succeeded", revision: 2)]
        var second = message()
        second.id = "second"; second.seq = 2
        value.entries["chat"] = [.message(message()), .message(second)]
        second.streaming = false; second.revision = 2
        let final = TranscriptEntry.message(second)
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            if request.url?.path == "/v1/entries/reply" { throw URLError(.timedOut) }
            XCTAssertEqual(request.url?.path, "/v1/entries/second")
            return (200, [:], try JSONEncoder().encode(final))
        }
        try await presence(value)
        try await waitForReconciliation(value)
        XCTAssertEqual(value.entries["chat"]?.map(\.streaming), [true, false])
        XCTAssertNotNil(value.pendingRunEntryReconciliations["run"])
        XCTAssertEqual(TestHTTPProtocol.requests.map { $0.url!.path }, ["/v1/entries/reply", "/v1/entries/second"])
    }
    func testQueuedReconciliationCannotReadOrClearAnotherGenerationsWork() async throws {
        let value = try store()
        value.runs = [run("running")]
        value.scheduleRunReconciliation(botID: "bot")
        // Switch generations before the queued task can start, then reuse the same Bot ID.
        value.generation = UUID()
        value.reconcilingRunBots = []
        value.pendingRunEntryReconciliations = [:]
        value.runs = [run("outcome_unknown", id: "new")]
        let terminal = run("succeeded", id: "new", revision: 2)
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/runs/new")
            return (200, [:], try JSONEncoder().encode(terminal))
        }
        value.scheduleRunReconciliation(botID: "bot")
        try await waitForReconciliation(value)
        XCTAssertEqual(value.runs.map(\.id), ["new"])
        XCTAssertEqual(value.runs.first?.status, "succeeded")
        XCTAssertEqual(TestHTTPProtocol.requests.map { $0.url!.path }, ["/v1/runs/new"])
    }
    func testSignOutAndLostConversationAccessClearPendingReplyRecovery() async throws {
        let value = try store()
        value.pendingRunEntryReconciliations = ["run": run("succeeded")]
        value.clearConversationAccess("chat")
        XCTAssertTrue(value.pendingRunEntryReconciliations.isEmpty)
        value.pendingRunEntryReconciliations = ["run": run("succeeded")]
        let previousGeneration = value.generation
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/auth/logout")
            return (200, [:], try JSONEncoder().encode(Empty(ok: true)))
        }
        try await value.signOut()
        XCTAssertNotEqual(value.generation, previousGeneration)
        XCTAssertTrue(value.pendingRunEntryReconciliations.isEmpty)
        XCTAssertTrue(value.reconcilingRunBots.isEmpty)
        value.scheduleRunReconciliation(botID: "bot")
        XCTAssertTrue(value.reconcilingRunBots.isEmpty)
        XCTAssertEqual(TestHTTPProtocol.requests.count, 1)
    }
    func testGrantAndMachineEventsInvalidateOnlyAffectedBots() async throws {
        let value = try store()
        var bot = Bot(id: "bot", revision: 1, createdAtMs: 1, updatedAtMs: 1, ownerUserId: "owner", machineId: "machine", profileId: "profile", name: "Atlas", title: "", job: "", instructions: "", avatar: Avatar(kind: "shape", shape: "circle", color: "yellow"), voice: VoiceSettings(voiceId: "default", speed: 1), skillIds: [], referenceAttachmentIds: [], mainConversationId: "chat", sidebar: SidebarState(pinned: false, hidden: false, rank: 0, unread: false, notificationsEnabled: true), activity: "idle", activeRunIds: [])
        var other = bot; other.id = "other"; other.machineId = "different"
        bot.id = "bot"
        value.bots = [bot, other]
        let machine = Machine(id: bot.machineId, revision: 1, createdAtMs: 1, updatedAtMs: 1, nodeName: "mac", name: "Mac", ownerUserId: "owner", accessUserIds: [], status: "online", labels: [:], botIds: [bot.id])
        var grant = BotGrant(id: "grant", revision: 1, createdAtMs: 1, updatedAtMs: 1, botId: bot.id, machineId: bot.machineId, capabilityId: "terminal", requestedLevel: "off", effectiveLevel: "off", pendingLevel: nil, reasons: [])
        try await value.apply(RealtimeEvent(seq: "1", payload: .grantUpserted(grant), timestampMs: 1))
        XCTAssertEqual(value.grantsVersion, ["bot": 1])
        grant.revision = 2
        grant.pendingLevel = "read_interact"
        try await value.apply(RealtimeEvent(seq: "2", payload: .grantUpserted(grant), timestampMs: 2))
        XCTAssertEqual(value.grantsVersion, ["bot": 2])
        try await value.apply(RealtimeEvent(seq: "3", payload: .machineUpserted(machine), timestampMs: 3))
        XCTAssertEqual(value.grantsVersion, ["bot": 3])
    }
}
