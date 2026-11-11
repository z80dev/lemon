import XCTest
@testable import LemonBotKit
@testable import LemonBotUI

@MainActor final class LiveStatusSyncTests: XCTestCase {
    private func store() throws -> LemonBotStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root); TestHTTPProtocol.handler = nil; TestHTTPProtocol.requests = [] }
        let value = LemonBotStore(persistence: ClientPersistence(root: root))
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
    func testGrantAndMachineEventsInvalidateOnlyAffectedBots() async throws {
        let value = try store()
        var bot = Bot(id: "bot", revision: 1, createdAtMs: 1, updatedAtMs: 1, ownerUserId: "owner", machineId: "machine", profileId: "profile", name: "Atlas", title: "", job: "", instructions: "", avatar: Avatar(kind: "shape", shape: "circle", color: "yellow"), voice: VoiceSettings(voiceId: "default", speed: 1), skillIds: [], referenceAttachmentIds: [], mainConversationId: "chat", sidebar: SidebarState(pinned: false, hidden: false, rank: 0, unread: false, notificationsEnabled: true), activity: "idle", activeRunIds: [])
        var other = bot; other.id = "other"; other.machineId = "different"
        bot.id = "bot"
        value.bots = [bot, other]
        let machine = Machine(id: bot.machineId, revision: 1, createdAtMs: 1, updatedAtMs: 1, nodeName: "mac", name: "Mac", ownerUserId: "owner", accessUserIds: [], status: "online", labels: [:], botIds: [bot.id])
        let grant = BotGrant(id: "grant", revision: 1, createdAtMs: 1, updatedAtMs: 1, botId: bot.id, machineId: bot.machineId, capabilityId: "terminal", requestedLevel: "off", effectiveLevel: "off", reasons: [])
        try await value.apply(RealtimeEvent(seq: "1", payload: .grantUpserted(grant), timestampMs: 1))
        XCTAssertEqual(value.grantsVersion, ["bot": 1])
        try await value.apply(RealtimeEvent(seq: "2", payload: .machineUpserted(machine), timestampMs: 1))
        XCTAssertEqual(value.grantsVersion, ["bot": 2])
    }
}
