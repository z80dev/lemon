#if DEBUG
import Foundation

typealias FixtureJSON = [String: Any]

/// Stable IDs for the fixture workspace (opaque-looking, shaped like real backend IDs).
public enum LemonBotFixtureID {
    public static let user = "user_FixtureOwner0000000000"
    public static let workspace = "workspace_FixtureHome000000"
    // Bots
    public static let zest = "bot_FixtureZest0000000000"
    public static let pip = "bot_FixturePip00000000000"
    public static let atlas = "bot_FixtureAtlas000000000"
    public static let marlow = "bot_FixtureMarlow00000000"
    public static let ledger = "bot_FixtureLedger00000000"
    public static let sage = "bot_FixtureSage0000000000"
    public static let scout = "bot_FixtureScout00000000"
    public static let juno = "bot_FixtureJuno0000000000"
    // Main conversations (1:1 with the Bots above)
    public static let zestMain = "conversation_FixtureZest0000"
    public static let pipMain = "conversation_FixturePip00000"
    public static let atlasMain = "conversation_FixtureAtlas000"
    public static let marlowMain = "conversation_FixtureMarlow00"
    public static let ledgerMain = "conversation_FixtureLedger00"
    public static let sageMain = "conversation_FixtureSage00000"
    public static let scoutMain = "conversation_FixtureScout0000"
    public static let junoMain = "conversation_FixtureJuno00000"
    // Group + task
    public static let tripGroup = "conversation_FixtureGroupTrip"
    public static let flightsTask = "conversation_FixtureTaskFlights"
    // Machines
    public static let studioMac = "machine_FixtureStudioMac00"
    public static let homeServer = "machine_FixtureHomeServer"
    public static let oldLaptop = "machine_FixtureOldLaptop0"
    // Runs
    public static let atlasLiveRun = "run_FixtureAtlasLive00000"
    public static let marlowFailedRun = "run_FixtureMarlowFailed000"
    public static let ledgerWaitingRun = "run_FixtureLedgerWaiting00"
    public static let failedRequestID = "req_fixture123"
}

/// The immutable fixture workspace. Every payload is built as JSON so it decodes through the real
/// Codable models (including their strict validation) exactly like a backend response.
final class FixtureWorld: @unchecked Sendable {
    static let shared = FixtureWorld()
    typealias ID = LemonBotFixtureID

    let now = Date()
    private(set) var user: FixtureJSON = [:]
    private(set) var workspace: FixtureJSON = [:]
    private(set) var member: FixtureJSON = [:]
    private(set) var capabilities: FixtureJSON = [:]
    private(set) var bots: [FixtureJSON] = []
    private(set) var machines: [FixtureJSON] = []
    private(set) var conversations: [FixtureJSON] = []
    private(set) var entries: [String: [FixtureJSON]] = [:]
    private(set) var runs: [FixtureJSON] = []
    private(set) var composerText: [String: String] = [:]
    private(set) var overviews: [String: FixtureJSON] = [:]
    private(set) var ideas: [String: [FixtureJSON]] = [:]
    private(set) var activity: [FixtureJSON] = []
    private(set) var upcoming: [FixtureJSON] = []

    // MARK: Time helpers
    private func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }
    private func minutesAgo(_ minutes: Double) -> Int64 { ms(now.addingTimeInterval(-minutes * 60)) }
    private let calendar = Calendar.current
    /// Yesterday at hh:mm.
    private func yesterday(_ hour: Int, _ minute: Int) -> Int64 {
        let day = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        return ms(calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!)
    }
    /// Today, offset from a base that is 8:05 am, pulled back when the fixture is built early in the morning.
    private func today(_ minutesAfterBase: Double) -> Int64 {
        let start = calendar.startOfDay(for: now)
        let base = max(start.addingTimeInterval(60), min(start.addingTimeInterval(8 * 3600 + 5 * 60), now.addingTimeInterval(-110 * 60)))
        return ms(base.addingTimeInterval(minutesAfterBase * 60))
    }

    // MARK: Builders
    private func userActor() -> FixtureJSON { ["kind": "user", "id": ID.user, "displayName": "Sam Rivera"] }
    private func botActor(_ id: String, _ name: String) -> FixtureJSON { ["kind": "bot", "id": id, "displayName": name] }
    private func entryBase(_ conversation: String, _ seq: Int, at: Int64, actor: FixtureJSON, runId: String? = nil, nonce: String? = nil) -> FixtureJSON {
        ["id": "entry_\(conversation.dropFirst(13))_\(seq)", "conversationId": conversation, "seq": seq, "timestampMs": at, "actor": actor,
         "clientNonce": nonce ?? NSNull(), "batchId": NSNull(), "replyToEntryId": NSNull(), "runId": runId ?? NSNull(), "targetedUserId": NSNull(),
         "reactions": [FixtureJSON](), "revision": 1, "createdAtMs": at, "updatedAtMs": at]
    }
    private func message(_ conversation: String, _ seq: Int, at: Int64, from actor: FixtureJSON, role: String, _ text: String, runId: String? = nil) -> FixtureJSON {
        var value = entryBase(conversation, seq, at: at, actor: actor, runId: runId, nonce: role == "user" ? "nonce_\(conversation.dropFirst(13))_\(seq)" : nil)
        value["kind"] = "message"; value["role"] = role; value["text"] = text; value["streaming"] = false; value["attachmentIds"] = [String]()
        return value
    }
    private func toolCall(_ conversation: String, _ seq: Int, at: Int64, bot: (String, String), runId: String, tool: String, title: String, status: String, detail: String?) -> FixtureJSON {
        var value = entryBase(conversation, seq, at: at, actor: botActor(bot.0, bot.1), runId: runId)
        value["kind"] = "tool_call"; value["tool"] = tool; value["title"] = title; value["status"] = status; value["detail"] = detail ?? NSNull()
        return value
    }
    private func card(_ conversation: String, _ seq: Int, at: Int64, bot: (String, String), runId: String?, _ card: FixtureJSON) -> FixtureJSON {
        var value = entryBase(conversation, seq, at: at, actor: botActor(bot.0, bot.1), runId: runId)
        value["kind"] = "card"; value["card"] = card
        return value
    }
    private func event(_ conversation: String, _ seq: Int, at: Int64, bot: (String, String), _ event: FixtureJSON) -> FixtureJSON {
        var value = entryBase(conversation, seq, at: at, actor: botActor(bot.0, bot.1))
        value["kind"] = "event"; value["event"] = event
        return value
    }
    private func run(_ id: String, conversation: String, bot: String, status: String, started: Int64?, completed: Int64?, error: FixtureJSON? = nil, created: Int64) -> FixtureJSON {
        ["id": id, "conversationId": conversation, "botId": bot, "initiatorUserId": ID.user, "clientNonce": "nonce_\(id)", "status": status,
         "error": error ?? NSNull(), "startedAtMs": started ?? NSNull(), "completedAtMs": completed ?? NSNull(), "routineRunId": NSNull(),
         "revision": 3, "createdAtMs": created, "updatedAtMs": completed ?? started ?? created]
    }
    private func machine(_ id: String, name: String, node: String, status: String, seen: Int64, bots: [String]) -> FixtureJSON {
        ["id": id, "nodeId": "node-\(id.suffix(6))", "nodeName": node, "name": name, "ownerUserId": ID.user, "accessUserIds": [String](), "status": status,
         "lastSeenAtMs": seen, "labels": [String: String](), "botIds": bots, "revision": 3, "createdAtMs": yesterday(7, 0) - 86_400_000 * 20, "updatedAtMs": seen]
    }
    private struct BotSpec {
        let id: String, name: String, title: String, job: String, color: String, machine: String, conversation: String
        let activity: String, activeRuns: [String], pinned: Bool, unread: Bool, rank: Int
    }
    private func bot(_ s: BotSpec) -> FixtureJSON {
        ["id": s.id, "revision": 8, "createdAtMs": yesterday(7, 0) - 86_400_000 * 20, "updatedAtMs": minutesAgo(30), "ownerUserId": ID.user, "machineId": s.machine,
         "profileId": "lb-" + s.id.suffix(10).lowercased(), "name": s.name, "title": s.title, "job": s.job,
         "instructions": "You are \(s.name), the owner's \(s.title.lowercased()). Keep replies short and ask before consequential actions.",
         "avatar": ["kind": "character", "shape": "round", "color": s.color, "attachmentId": NSNull()] as FixtureJSON,
         "voice": ["voiceId": "default", "speed": 1, "language": NSNull()] as FixtureJSON, "language": NSNull(),
         "skillIds": [String](), "referenceAttachmentIds": [String](), "mainConversationId": s.conversation, "activity": s.activity, "activeRunIds": s.activeRuns,
         "sidebar": ["pinned": s.pinned, "hidden": false, "sectionId": NSNull(), "rank": s.rank, "unread": s.unread, "notificationsEnabled": true] as FixtureJSON]
    }
    private func conversation(_ id: String, kind: String = "dm", name: String, bots: [String], lead: String?, parent: String? = nil, updated: Int64,
                              last: String, activity: [FixtureJSON] = [], lastRead: Int, unread: Int) -> FixtureJSON {
        ["id": id, "revision": 5, "createdAtMs": yesterday(7, 0) - 86_400_000 * 10, "updatedAtMs": updated, "kind": kind, "name": name, "botIds": bots, "ownerUserId": ID.user,
         "parentConversationId": parent ?? NSNull(), "leadBotId": lead ?? NSNull(), "channelBindingId": NSNull(), "lastEntryId": last, "activity": activity,
         "lastReadSeq": lastRead, "unreadCount": unread]
    }
    private func activityItem(_ id: String, bot: String, machine: String, label: String, conversation: String?, runId: String?, kind: String, status: String, title: String, summary: String, at: Int64) -> FixtureJSON {
        ["id": id, "revision": 1, "createdAtMs": at, "updatedAtMs": at, "botId": bot, "machineId": machine, "machineLabel": label, "conversationId": conversation ?? NSNull(),
         "taskConversationId": NSNull(), "runId": runId ?? NSNull(), "approvalId": NSNull(), "entryId": NSNull(), "kind": kind, "status": status, "title": title, "summary": summary, "occurredAtMs": at]
    }
    private func upcomingItem(_ id: String, bot: String, machine: String, label: String, title: String, due: Int64, lastStatus: String?) -> FixtureJSON {
        ["id": id, "kind": "routine", "botId": bot, "machineId": machine, "machineLabel": label, "machineStatus": "online", "title": title, "dueAtMs": due, "timezone": "America/Los_Angeles",
         "routineId": "routine_\(id.suffix(8))", "reminderId": NSNull(), "lastRunId": NSNull(), "lastRunStatus": lastStatus ?? NSNull(), "blockedReason": NSNull()]
    }
    init() {
        let created = yesterday(7, 0) - 86_400_000 * 30
        user = ["id": ID.user, "email": "sam@example.invalid", "displayName": "Sam Rivera", "avatarAttachmentId": NSNull(),
                "preferences": ["appearance": "system", "language": NSNull(), "timezone": "America/Los_Angeles", "botColors": true, "threadsBesideChat": false,
                                "voice": ["voiceId": "default", "speed": 1, "language": NSNull()] as FixtureJSON, "celebrationsEnabled": false] as FixtureJSON,
                "notifications": ["enabled": true, "sound": true, "previews": true, "completed": true, "needsInput": true] as FixtureJSON,
                "revision": 1, "createdAtMs": created, "updatedAtMs": created]
        workspace = ["id": ID.workspace, "name": "Sam's Lemon Bot", "ownerUserId": ID.user, "enabled": true, "timezone": "America/Los_Angeles", "revision": 1, "createdAtMs": created, "updatedAtMs": created]
        member = ["id": "member_FixtureOwner00000", "userId": ID.user, "email": "sam@example.invalid", "displayName": "Sam Rivera", "role": "owner", "enabled": true, "revision": 1, "createdAtMs": created, "updatedAtMs": created]
        capabilities = ["controlConnected": true, "methods": ["agent", "chat.send", "chat.history"], "stt": false, "tts": false, "imageGeneration": false, "apns": false, "webPush": false,
                        "vapidPublicKey": NSNull(), "attachmentMaxBytes": 26_214_400, "videoMaxBytes": 209_715_200, "maxAttachments": 6,
                        "minClientVersions": ["web": "0.1.0", "macos": "0.1.0", "ios": "0.1.0"] as FixtureJSON]

        // Machines
        let seen = minutesAgo(1)
        machines = [
            machine(ID.studioMac, name: "Studio Mac", node: "studio-mac.local", status: "online", seen: seen, bots: [ID.zest, ID.pip, ID.atlas, ID.sage, ID.juno]),
            machine(ID.homeServer, name: "Home server", node: "home-server.local", status: "online", seen: seen, bots: [ID.marlow, ID.ledger]),
            machine(ID.oldLaptop, name: "Old laptop", node: "old-laptop.local", status: "offline", seen: minutesAgo(60 * 26), bots: [ID.scout])
        ]

        // MARK: Zest — Chief of Staff (main conversation, two days)
        let zest = (ID.zest, "Zest"), z = ID.zestMain
        var zestEntries: [FixtureJSON] = []
        zestEntries.append(message(z, 1, at: yesterday(18, 42), from: userActor(), role: "user", "Can you clean up my inbox? It's a mess after the conference."))
        zestEntries.append(toolCall(z, 2, at: yesterday(18, 42) + 4_000, bot: zest, runId: "run_FixtureZest1", tool: "email_read", title: "Reading your inbox", status: "completed", detail: "214 unread"))
        zestEntries.append(message(z, 3, at: yesterday(18, 43), from: botActor(zest.0, zest.1), role: "assistant", """
        On it. I found **214 unread** messages from the last two weeks. Here's how I'd sort them:

        - **Newsletters** (96): archive and unsubscribe from the ones you never open
        - **Receipts** (41): file into *Finance/2026*
        - **Conference follow-ups** (28): keep, flagged for you
        - **Everything else** (49): needs a quick look

        Want me to go ahead with the first two groups?
        """, runId: "run_FixtureZest1"))
        zestEntries.append(message(z, 4, at: yesterday(18, 43) + 9_000, from: botActor(zest.0, zest.1), role: "assistant", "Nothing gets deleted. Everything is archived and can be restored.", runId: "run_FixtureZest1"))
        zestEntries.append(message(z, 5, at: yesterday(18, 51), from: userActor(), role: "user", "Yes, do it. Leave the conference ones alone."))
        zestEntries.append(message(z, 6, at: yesterday(18, 58), from: botActor(zest.0, zest.1), role: "assistant", "Done. I archived 96 newsletters and filed 41 receipts. You have 77 messages left, 28 of them flagged for the conference follow-up.", runId: "run_FixtureZest2"))
        zestEntries.append(message(z, 7, at: today(0), from: userActor(), role: "user", "Morning! Can you help me plan a trip to Lisbon? Four days, around October 14th."))
        zestEntries.append(message(z, 8, at: today(1), from: botActor(zest.0, zest.1), role: "assistant", """
        Good morning! Here's a rough shape for four days:

        1. **Day 1**: arrive, walk Alfama, early dinner
        2. **Day 2**: Belém, pastéis, LX Factory
        3. **Day 3**: day trip to Sintra
        4. **Day 4**: Chiado, then the flight home
        """, runId: "run_FixtureZest3"))
        zestEntries.append(message(z, 9, at: today(1) + 6_000, from: botActor(zest.0, zest.1), role: "assistant", "Do you prefer a hotel in Baixa, or somewhere quieter like Estrela?", runId: "run_FixtureZest3"))
        zestEntries.append(message(z, 10, at: today(9), from: userActor(), role: "user", "Baixa is fine. And can you keep an eye on fares for me?"))
        zestEntries.append(message(z, 11, at: today(10), from: botActor(zest.0, zest.1), role: "assistant", """
        Yes. I set it up as a daily routine. If you ever want to run the check yourself, this is what it does:

        ```bash
        flight-watch --from SFO --to LIS --depart 2026-10-14 --max-price 620
        ```

        Fares usually dip on Tuesdays, so I'll flag anything under $620.
        """, runId: "run_FixtureZest4"))
        zestEntries.append(event(z, 12, at: today(10) + 8_000, bot: zest, ["type": "routine_changed", "routineId": "routine_FixtureFares", "action": "created"] as FixtureJSON))
        zestEntries.append(message(z, 13, at: today(24), from: userActor(), role: "user", "Great. What's on my calendar Thursday?"))
        zestEntries.append(message(z, 14, at: today(25), from: botActor(zest.0, zest.1), role: "assistant", "Thursday is light: dentist at 10:30 and a 2 pm check-in with Marlow about the Lisbon flights.", runId: "run_FixtureZest5"))
        zestEntries.append(card(z, 15, at: today(25) + 5_000, bot: zest, runId: "run_FixtureZest5", ["type": "calendar_event", "event": [
            "subject": "Lisbon planning", "startAtMs": today(24 * 60 + 8 * 60), "endAtMs": today(24 * 60 + 9 * 60), "timezone": "America/Los_Angeles", "allDay": false,
            "guests": ["marlow@lemon.test"], "location": "Studio Mac", "sourceUrl": NSNull(), "status": "proposed"] as FixtureJSON] as FixtureJSON))

        // MARK: Pip — Inbox Triage (unread)
        let pip = (ID.pip, "Pip"), p = ID.pipMain
        let pipEntries: [FixtureJSON] = [
            message(p, 1, at: yesterday(9, 12), from: userActor(), role: "user", "Anything urgent from the landlord this week?"),
            message(p, 2, at: yesterday(9, 13), from: botActor(pip.0, pip.1), role: "assistant", "Nothing urgent. One reminder about the parking permit renewal, due on the 30th.", runId: "run_FixturePip1"),
            message(p, 3, at: today(40), from: botActor(pip.0, pip.1), role: "assistant", "Heads up: your landlord just sent the lease renewal. I filed it under Home and flagged it for you.", runId: "run_FixturePip2"),
            message(p, 4, at: today(40) + 6_000, from: botActor(pip.0, pip.1), role: "assistant", "It asks for an answer by Friday.", runId: "run_FixturePip2")
        ]

        // MARK: Atlas — Research (working, live run)
        let atlas = (ID.atlas, "Atlas"), a = ID.atlasMain
        let atlasStart = minutesAgo(3)
        let atlasEntries: [FixtureJSON] = [
            message(a, 1, at: minutesAgo(26), from: userActor(), role: "user", "Compare the three best noise-cancelling headphones under $400 and give me a short recommendation."),
            message(a, 2, at: minutesAgo(25), from: botActor(atlas.0, atlas.1), role: "assistant", "Sure. I'll check recent reviews and prices, then compare battery life and comfort.", runId: ID.atlasLiveRun),
            toolCall(a, 3, at: minutesAgo(3), bot: atlas, runId: ID.atlasLiveRun, tool: "web_search", title: "Searching the web", status: "completed", detail: "noise cancelling headphones 2026 reviews"),
            toolCall(a, 4, at: minutesAgo(2), bot: atlas, runId: ID.atlasLiveRun, tool: "web_fetch", title: "Reading 4 pages", status: "completed", detail: nil),
            toolCall(a, 5, at: minutesAgo(1), bot: atlas, runId: ID.atlasLiveRun, tool: "analysis", title: "Comparing battery life and price", status: "started", detail: nil)
        ]
        composerText = [ID.atlasMain: "Also check whether any of them support multipoint"]

        // MARK: Marlow — Travel (failed run)
        let marlow = (ID.marlow, "Marlow"), m = ID.marlowMain
        let marlowEntries: [FixtureJSON] = [
            message(m, 1, at: yesterday(20, 5), from: userActor(), role: "user", "Which neighborhoods in Lisbon are best for a first visit?"),
            message(m, 2, at: yesterday(20, 6), from: botActor(marlow.0, marlow.1), role: "assistant", "Baixa and Chiado are the easiest bases: walkable, well connected, and close to the river. Alfama is lovely but hilly.", runId: "run_FixtureMarlow1"),
            message(m, 3, at: minutesAgo(58), from: userActor(), role: "user", "Look up direct flights from SFO to Lisbon for October 14th."),
            message(m, 4, at: minutesAgo(57), from: botActor(marlow.0, marlow.1), role: "assistant", "", runId: ID.marlowFailedRun)
        ]
        let failedError: FixtureJSON = ["code": "upstream_unavailable", "message": "The runtime reported that this run failed.", "requestId": ID.failedRequestID, "retrySafe": true]

        // MARK: Ledger — Finance (needs input)
        let ledger = (ID.ledger, "Ledger"), l = ID.ledgerMain
        let ledgerEntries: [FixtureJSON] = [
            message(l, 1, at: minutesAgo(14), from: userActor(), role: "user", "File the conference expense report."),
            message(l, 2, at: minutesAgo(13), from: botActor(ledger.0, ledger.1), role: "assistant", "I found 6 receipts totaling $1,284.30. One question before I submit.", runId: ID.ledgerWaitingRun),
            card(l, 3, at: minutesAgo(13) + 4_000, bot: ledger, runId: ID.ledgerWaitingRun, ["type": "widget", "questionId": "question_FixtureLedger", "prompt": "Which card should the reimbursement go to?",
                "options": [["value": "visa", "label": "Visa ending 4417"], ["value": "amex", "label": "Amex ending 2008"]] as [FixtureJSON], "multiSelect": false,
                "gate": ["id": "gate_FixtureLedger", "state": "pending", "targetUserId": ID.user, "expiresAtMs": ms(now.addingTimeInterval(3600 * 6)), "resolvedAtMs": NSNull(), "resolvedByUserId": NSNull(), "revision": 1] as FixtureJSON] as FixtureJSON)
        ]

        // MARK: Sage / Scout / Juno
        let sage = (ID.sage, "Sage"), sg = ID.sageMain
        let sageEntries: [FixtureJSON] = [
            message(sg, 1, at: yesterday(15, 30), from: userActor(), role: "user", "Tighten this intro: \"We are very excited to be announcing our new product launch.\""),
            message(sg, 2, at: yesterday(15, 31), from: botActor(sage.0, sage.1), role: "assistant", "Try: **\"We're launching something new.\"** Shorter, and it keeps the energy.", runId: "run_FixtureSage1")
        ]
        let scout = (ID.scout, "Scout"), sc = ID.scoutMain
        let scoutEntries: [FixtureJSON] = [
            message(sc, 1, at: yesterday(11, 2), from: userActor(), role: "user", "Check whether the backup finished overnight."),
            message(sc, 2, at: yesterday(11, 3), from: botActor(scout.0, scout.1), role: "assistant", "The nightly backup finished at 3:12 am. 41 GB, no errors.", runId: "run_FixtureScout1")
        ]
        let juno = (ID.juno, "Juno"), j = ID.junoMain
        let junoEntries: [FixtureJSON] = [
            message(j, 1, at: yesterday(8, 20), from: userActor(), role: "user", "Move my 3 pm to Friday."),
            message(j, 2, at: yesterday(8, 21), from: botActor(juno.0, juno.1), role: "assistant", "Moved. I let the other two attendees know.", runId: "run_FixtureJuno1")
        ]

        // MARK: Group + task conversations
        let g = ID.tripGroup
        let groupEntries: [FixtureJSON] = [
            message(g, 1, at: today(30), from: userActor(), role: "user", "Team, let's lock the Lisbon plan. Zest, hotel; Marlow, flights."),
            message(g, 2, at: today(31), from: botActor(zest.0, zest.1), role: "assistant", "Shortlisted three hotels in Baixa, all under $210 a night. Sending the comparison to you.", runId: "run_FixtureGroup1"),
            message(g, 3, at: today(31) + 30_000, from: botActor(marlow.0, marlow.1), role: "assistant", "I'm comparing direct and one-stop flights now.", runId: "run_FixtureGroup2")
        ]
        let t = ID.flightsTask
        let taskEntries: [FixtureJSON] = [
            message(t, 1, at: today(33), from: userActor(), role: "user", "Compare direct and one-stop flights SFO to LIS on October 14th."),
            event(t, 2, at: today(34), bot: marlow, ["type": "task_changed", "conversationId": ID.flightsTask, "status": "succeeded"] as FixtureJSON),
            message(t, 3, at: today(35), from: botActor(marlow.0, marlow.1), role: "assistant", "Direct is $598 with TAP (10h 40m). The one-stop via Frankfurt is $512 but adds 4 hours.", runId: "run_FixtureTask1")
        ]

        let allEntries: [String: [FixtureJSON]] = [
            ID.zestMain: zestEntries, ID.pipMain: pipEntries, ID.atlasMain: atlasEntries, ID.marlowMain: marlowEntries, ID.ledgerMain: ledgerEntries,
            ID.sageMain: sageEntries, ID.scoutMain: scoutEntries, ID.junoMain: junoEntries, ID.tripGroup: groupEntries, ID.flightsTask: taskEntries
        ]
        entries = allEntries

        // Conversations derive their lastEntryId/updatedAt from the entries above.
        func last(_ id: String) -> (String, Int64) {
            let e = entries[id]!.last!
            return (e["id"] as! String, e["timestampMs"] as! Int64)
        }
        let working: [FixtureJSON] = [["botId": ID.atlas, "phase": "working"]]
        conversations = [
            conversation(ID.zestMain, name: "Zest", bots: [ID.zest], lead: ID.zest, updated: last(ID.zestMain).1, last: last(ID.zestMain).0, lastRead: 15, unread: 0),
            conversation(ID.pipMain, name: "Pip", bots: [ID.pip], lead: ID.pip, updated: last(ID.pipMain).1, last: last(ID.pipMain).0, lastRead: 2, unread: 2),
            conversation(ID.atlasMain, name: "Atlas", bots: [ID.atlas], lead: ID.atlas, updated: last(ID.atlasMain).1, last: last(ID.atlasMain).0, activity: working, lastRead: 5, unread: 0),
            conversation(ID.marlowMain, name: "Marlow", bots: [ID.marlow], lead: ID.marlow, updated: last(ID.marlowMain).1, last: last(ID.marlowMain).0, lastRead: 4, unread: 0),
            conversation(ID.ledgerMain, name: "Ledger", bots: [ID.ledger], lead: ID.ledger, updated: last(ID.ledgerMain).1, last: last(ID.ledgerMain).0, lastRead: 2, unread: 1),
            conversation(ID.sageMain, name: "Sage", bots: [ID.sage], lead: ID.sage, updated: last(ID.sageMain).1, last: last(ID.sageMain).0, lastRead: 2, unread: 0),
            conversation(ID.scoutMain, name: "Scout", bots: [ID.scout], lead: ID.scout, updated: last(ID.scoutMain).1, last: last(ID.scoutMain).0, lastRead: 2, unread: 0),
            conversation(ID.junoMain, name: "Juno", bots: [ID.juno], lead: ID.juno, updated: last(ID.junoMain).1, last: last(ID.junoMain).0, lastRead: 2, unread: 0),
            conversation(ID.tripGroup, kind: "group", name: "Lisbon trip crew", bots: [ID.zest, ID.marlow, ID.pip], lead: ID.zest, updated: last(ID.tripGroup).1, last: last(ID.tripGroup).0, lastRead: 3, unread: 0),
            conversation(ID.flightsTask, kind: "task", name: "Compare Lisbon flights", bots: [ID.marlow], lead: ID.marlow, parent: ID.marlowMain, updated: last(ID.flightsTask).1, last: last(ID.flightsTask).0, lastRead: 3, unread: 0)
        ]

        // Bots
        bots = [
            bot(BotSpec(id: ID.zest, name: "Zest", title: "Chief of Staff", job: "Keeps my week, inbox and travel in order.", color: "yellow", machine: ID.studioMac, conversation: ID.zestMain, activity: "idle", activeRuns: [], pinned: true, unread: false, rank: 0)),
            bot(BotSpec(id: ID.pip, name: "Pip", title: "Inbox Triage", job: "Sorts email and surfaces what matters.", color: "green", machine: ID.studioMac, conversation: ID.pipMain, activity: "idle", activeRuns: [], pinned: true, unread: true, rank: 1)),
            bot(BotSpec(id: ID.atlas, name: "Atlas", title: "Research", job: "Digs into questions and compares options.", color: "blue", machine: ID.studioMac, conversation: ID.atlasMain, activity: "working", activeRuns: [ID.atlasLiveRun], pinned: false, unread: false, rank: 2)),
            bot(BotSpec(id: ID.marlow, name: "Marlow", title: "Travel", job: "Plans trips and watches fares.", color: "pink", machine: ID.homeServer, conversation: ID.marlowMain, activity: "idle", activeRuns: [], pinned: false, unread: false, rank: 3)),
            bot(BotSpec(id: ID.ledger, name: "Ledger", title: "Finance", job: "Files expenses and tracks receipts.", color: "orange", machine: ID.homeServer, conversation: ID.ledgerMain, activity: "needs_input", activeRuns: [ID.ledgerWaitingRun], pinned: false, unread: true, rank: 4)),
            bot(BotSpec(id: ID.sage, name: "Sage", title: "Writing", job: "Edits drafts and tightens copy.", color: "purple", machine: ID.studioMac, conversation: ID.sageMain, activity: "idle", activeRuns: [], pinned: false, unread: false, rank: 5)),
            bot(BotSpec(id: ID.scout, name: "Scout", title: "Home Ops", job: "Watches backups, devices and the network.", color: "red", machine: ID.oldLaptop, conversation: ID.scoutMain, activity: "offline", activeRuns: [], pinned: false, unread: false, rank: 6)),
            bot(BotSpec(id: ID.juno, name: "Juno", title: "Calendar", job: "Schedules meetings and protects focus time.", color: "blue", machine: ID.studioMac, conversation: ID.junoMain, activity: "idle", activeRuns: [], pinned: false, unread: false, rank: 7))
        ]

        // Runs (live + failed also appear in the snapshot's activeRuns like the real backend)
        let atlasLive = run(ID.atlasLiveRun, conversation: ID.atlasMain, bot: ID.atlas, status: "running", started: atlasStart, completed: nil, created: minutesAgo(25))
        let marlowFailed = run(ID.marlowFailedRun, conversation: ID.marlowMain, bot: ID.marlow, status: "failed", started: minutesAgo(57), completed: minutesAgo(56), error: failedError, created: minutesAgo(57))
        let ledgerWaiting = run(ID.ledgerWaitingRun, conversation: ID.ledgerMain, bot: ID.ledger, status: "awaiting_input", started: minutesAgo(13), completed: nil, created: minutesAgo(14))
        func done(_ id: String, _ conversation: String, _ bot: String, _ at: Int64) -> FixtureJSON {
            run(id, conversation: conversation, bot: bot, status: "succeeded", started: at - 20_000, completed: at, created: at - 25_000)
        }
        runs = [
            atlasLive, marlowFailed, ledgerWaiting,
            done("run_FixtureZest1", ID.zestMain, ID.zest, yesterday(18, 43)), done("run_FixtureZest2", ID.zestMain, ID.zest, yesterday(18, 58)),
            done("run_FixtureZest3", ID.zestMain, ID.zest, today(1)), done("run_FixtureZest4", ID.zestMain, ID.zest, today(10)), done("run_FixtureZest5", ID.zestMain, ID.zest, today(25)),
            done("run_FixturePip1", ID.pipMain, ID.pip, yesterday(9, 13)), done("run_FixturePip2", ID.pipMain, ID.pip, today(40)),
            done("run_FixtureMarlow1", ID.marlowMain, ID.marlow, yesterday(20, 6)), done("run_FixtureTask1", ID.flightsTask, ID.marlow, today(35))
        ]

        // Presence + overview content
        let activityRows: [FixtureJSON] = [
            activityItem("activity_FixtureA1", bot: ID.atlas, machine: ID.studioMac, label: "Studio Mac", conversation: ID.atlasMain, runId: ID.atlasLiveRun, kind: "run", status: "working", title: "Comparing headphones", summary: "Reading reviews and prices.", at: minutesAgo(1)),
            activityItem("activity_FixtureA2", bot: ID.zest, machine: ID.studioMac, label: "Studio Mac", conversation: ID.zestMain, runId: "run_FixtureZest5", kind: "run", status: "succeeded", title: "Checked your calendar", summary: "Thursday has two events.", at: today(25)),
            activityItem("activity_FixtureA3", bot: ID.zest, machine: ID.studioMac, label: "Studio Mac", conversation: ID.zestMain, runId: "run_FixtureZest4", kind: "tool", status: "succeeded", title: "Set up fare watch", summary: "Daily routine for SFO to LIS.", at: today(10)),
            activityItem("activity_FixtureA4", bot: ID.zest, machine: ID.studioMac, label: "Studio Mac", conversation: ID.zestMain, runId: "run_FixtureZest2", kind: "run", status: "succeeded", title: "Cleaned up inbox", summary: "Archived 96 newsletters, filed 41 receipts.", at: yesterday(18, 58)),
            activityItem("activity_FixtureA5", bot: ID.marlow, machine: ID.homeServer, label: "Home server", conversation: ID.marlowMain, runId: ID.marlowFailedRun, kind: "run", status: "failed", title: "Flight search", summary: "The runtime was unavailable.", at: minutesAgo(56)),
            activityItem("activity_FixtureA6", bot: ID.ledger, machine: ID.homeServer, label: "Home server", conversation: ID.ledgerMain, runId: ID.ledgerWaitingRun, kind: "approval", status: "pending", title: "Expense report", summary: "Waiting for a card choice.", at: minutesAgo(13)),
            activityItem("activity_FixtureA7", bot: ID.pip, machine: ID.studioMac, label: "Studio Mac", conversation: ID.pipMain, runId: "run_FixturePip2", kind: "run", status: "succeeded", title: "Filed lease renewal", summary: "Flagged for your reply by Friday.", at: today(40))
        ]
        activity = activityRows
        let upcomingRows: [FixtureJSON] = [
            upcomingItem("upcoming_FixtureU1", bot: ID.zest, machine: ID.studioMac, label: "Studio Mac", title: "Morning brief", due: today(24 * 60 + 0), lastStatus: "succeeded"),
            upcomingItem("upcoming_FixtureU2", bot: ID.zest, machine: ID.studioMac, label: "Studio Mac", title: "Watch fares SFO to LIS", due: today(24 * 60 + 60), lastStatus: nil),
            upcomingItem("upcoming_FixtureU3", bot: ID.atlas, machine: ID.studioMac, label: "Studio Mac", title: "Weekly industry digest", due: today(3 * 24 * 60), lastStatus: "succeeded")
        ]
        upcoming = upcomingRows

        var overviewMap: [String: FixtureJSON] = [:]
        let botByID = Dictionary(uniqueKeysWithValues: bots.map { ($0["id"] as! String, $0) })
        let machineByID = Dictionary(uniqueKeysWithValues: machines.map { ($0["id"] as! String, $0) })
        let summaries: [String: String] = [
            ID.atlas: "Comparing headphones", ID.ledger: "Waiting for your card choice", ID.scout: "Studio is offline", ID.zest: "Ready", ID.pip: "Ready", ID.marlow: "Ready", ID.sage: "Ready", ID.juno: "Ready"
        ]
        for (id, botJSON) in botByID {
            let machineJSON = machineByID[botJSON["machineId"] as! String]!
            let grants: [FixtureJSON] = [("files", "read_interact"), ("shell", "read_only"), ("browser", "read_interact")].enumerated().map { index, pair in
                ["id": "grant_\(id.suffix(8))_\(index)", "revision": 1, "createdAtMs": created, "updatedAtMs": created, "botId": id, "machineId": botJSON["machineId"] as! String, "capabilityId": pair.0,
                 "requestedLevel": pair.1, "effectiveLevel": pair.1, "reasons": [String]()] as FixtureJSON
            }
            let presence: FixtureJSON = ["botId": id, "status": botJSON["activity"] as! String, "machineId": botJSON["machineId"] as! String, "machineLabel": machineJSON["name"] as! String,
                "machineStatus": machineJSON["status"] as! String, "currentRunId": (botJSON["activeRunIds"] as! [String]).first ?? NSNull(), "taskConversationId": NSNull(),
                "summary": summaries[id] ?? "Ready", "evidenceEntryId": NSNull(), "measuredAtMs": minutesAgo(1), "stale": false]
            overviewMap[id] = ["bot": botJSON, "presence": presence, "machine": machineJSON, "grants": grants,
                               "activity": page(activityRows.filter { $0["botId"] as? String == id }), "upcoming": page(upcomingRows.filter { $0["botId"] as? String == id })]
        }
        overviews = overviewMap
        ideas = Dictionary(uniqueKeysWithValues: bots.map { b in
            let id = b["id"] as! String
            let idea: FixtureJSON = ["id": "idea_\(id.suffix(8))", "botId": id, "title": "Weekly review", "prompt": "Summarize what happened this week and what needs my attention.",
                                     "expectedOutput": "A short summary with next steps.", "requiredSkillIds": [String](), "requiredConnectorIds": [String](), "requiredCapabilityIds": [String](), "ready": true, "blockedReasons": [String]()]
            return (id, [idea])
        })
    }

    // MARK: Derived payloads
    var snapshot: FixtureJSON {
        ["cursor": "9001", "user": user, "workspace": workspace, "member": member, "capabilities": capabilities, "bots": bots, "machines": machines, "conversations": conversations,
         "sections": [FixtureJSON](), "notifications": [FixtureJSON](),
         "activeRuns": runs.filter { ["running", "awaiting_input", "failed"].contains($0["status"] as? String ?? "") },
         "hasMore": ["bots": false, "machines": false, "conversations": false, "notifications": false] as FixtureJSON]
    }
    func entries(for conversationID: String) -> [FixtureJSON] { entries[conversationID] ?? [] }
    func composer(for conversationID: String) -> FixtureJSON {
        ["conversationId": conversationID, "text": composerText[conversationID] ?? "", "attachmentIds": [String](), "replyToEntryId": NSNull(), "updatedAtMs": minutesAgo(0.2), "revision": 1]
    }
    func entry(id: String) -> FixtureJSON? { entries.values.joined().first { $0["id"] as? String == id } }
    func page(_ items: [FixtureJSON]) -> FixtureJSON { ["items": items, "nextCursor": NSNull()] }
}
#endif
