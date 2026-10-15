import XCTest
@testable import LemonBotKit

final class ProtocolTests: XCTestCase {
    func testEveryDeclaredCardRoundTripsWithExactDiscriminator() throws {
        let cards = try JSONDecoder().decode([Card].self, from: WireFixtures.cards)
        let reencoded = try JSONEncoder().encode(cards)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: reencoded), try JSONDecoder().decode(JSONValue.self, from: WireFixtures.cards))
    }
    func testAllEntriesAndRealtimeEventsDecodeAndRoundTrip() throws {
        let entries = try JSONDecoder().decode([TranscriptEntry].self, from: WireFixtures.entries)
        XCTAssertTrue(entries.allSatisfy { $0.id == "resource" && $0.seq == 1 })
        XCTAssertEqual(try JSONDecoder().decode([TranscriptEntry].self, from: JSONEncoder().encode(entries)), entries)
        let events = try JSONDecoder().decode([RealtimeEvent].self, from: WireFixtures.events)
        XCTAssertTrue(events.allSatisfy { $0.seq == "9007199254740993123456" })
        XCTAssertEqual(try JSONDecoder().decode([RealtimeEvent].self, from: JSONEncoder().encode(events)), events)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(events)), try JSONDecoder().decode(JSONValue.self, from: WireFixtures.events))
    }
    func testKnownCardCannotDecodeWithoutItsRequiredResource() {
        XCTAssertThrowsError(try JSONDecoder().decode(Card.self, from: Data(#"{"type":"secret_request"}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(Card.self, from: Data(#"{"type":"widget","prompt":"Choose"}"#.utf8)))
    }
    func testUnknownCardPreservesSafeFallbackWithoutInventedGate() throws {
        let card = try JSONDecoder().decode(Card.self, from: Data(#"{"type":"future_card","text":"Update the client","attachmentId":"a","untrustedAction":"approve"}"#.utf8))
        guard case .unsupported(let fallback) = card else { return XCTFail("Expected bounded unsupported card") }
        XCTAssertEqual(fallback.type, "future_card"); XCTAssertEqual(fallback.attachmentId, "a")
        XCTAssertEqual(fallback.text, "Update the client")
    }
    func testRequiredNullAndOptionalOmissionAreDifferent() throws {
        let voice = VoiceSettings(voiceId: "default", speed: 1, language: nil)
        let value = try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(voice))
        XCTAssertEqual(value["language"], .null)
        let update = ComposerDraftUpdate(clientNonce: "nonce_123456789012", revision: 2, text: "Draft", attachmentIds: [])
        let body = try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(update))
        XCTAssertNil(body["replyToEntryId"])
    }
    func testOptionalNullRoundTripPreservesAutomaticLanguageAndFractionalBounds() throws {
        let explicit = try JSONDecoder().decode(JobPreferencePatch.self, from: Data(#"{"language":null}"#.utf8))
        XCTAssertNotNil(explicit.language as Any?)
        let encoded = try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(explicit))
        XCTAssertEqual(encoded["language"], .null)
        let omitted = try JSONDecoder().decode(JobPreferencePatch.self, from: Data("{}".utf8))
        XCTAssertNil(omitted.language as Any?)
        let field = try JSONDecoder().decode(Field.self, from: Data(#"{"id":"n","label":"Amount","kind":"number","required":true,"min":0.5,"max":2.25}"#.utf8))
        XCTAssertEqual(field.min, 0.5); XCTAssertEqual(field.max, 2.25)
        XCTAssertThrowsError(try JSONDecoder().decode(VoiceSettings.self, from: Data(#"{"voiceId":"default","speed":1}"#.utf8)))
    }

    func testCursorComparisonDoesNotLoseIntegerPrecision() throws {
        XCTAssertTrue(try WorkspaceCursor.isAfter("9007199254740993123457", "9007199254740993123456"))
        XCTAssertFalse(try WorkspaceCursor.isAfter("00042", "42"))
        XCTAssertTrue(try WorkspaceCursor.isAfter("100000000000000000000000000", "99999999999999999999999999"))
        XCTAssertEqual(try WorkspaceCursor.normalized("0000"), "0")
        for invalid in ["", "-1", "1.0", "+1", "1e4", "١"] { XCTAssertThrowsError(try WorkspaceCursor.normalized(invalid)) }
    }
    func testStrictDeepLinkGrammar() throws {
        let target = try DeepLinkTarget(url: XCTUnwrap(URL(string: "lemonbot://workspace/w/bot/b?conversationId=c&taskConversationId=t&entryId=e")))
        XCTAssertEqual(target.workspaceID, "w"); XCTAssertEqual(target.taskConversationID, "t")
        let approval = try DeepLinkTarget(url: XCTUnwrap(URL(string: "lemonbot://workspace/w/bot/b?conversationId=c&entryId=e&approvalId=a")))
        XCTAssertEqual(approval.approvalID, "a")
        let urls = [
            "https://workspace/w/bot/b", "lemonbot://evil/w/bot/b", "lemonbot://workspace/w/bot/b?token=secret",
            "lemonbot://workspace/w/bot/b?conversationId=c&conversationId=x", "lemonbot://workspace/w/bot/b?approvalId=a",
            "lemonbot://workspace/w/bot/b?taskConversationId=t", "lemonbot://workspace/w/bot/b?entryId=e",
            "lemonbot://workspace/w/bot/b%2Fother", "lemonbot://workspace/w/bot/b%252Fother",
            "lemonbot://workspace/w/machine/m?conversationId=c", "lemonbot://workspace/w/bot/b/routine/r?entryId=e",
            "lemonbot://workspace/w/bot/b#approve", "lemonbot://user:password@workspace/w/bot/b",
            "lemonbot://workspace/w/bot/b/", "lemonbot://workspace/w//bot/b"
        ]
        for text in urls { XCTAssertThrowsError(try DeepLinkTarget(url: XCTUnwrap(URL(string: text))), text) }
    }
    func testProviderDiscoveryUsesTypedSecretFreeFields() throws {
        let info = try JSONDecoder().decode(ChannelProviderInfo.self, from: Data(#"{"id":"slack","kind":"channel","label":"Slack","configured":false,"prerequisites":["Register Slack OAuth app"],"capabilities":[],"adapter":"slack","supportsBotAppInstall":true}"#.utf8))
        XCTAssertFalse(info.configured); XCTAssertEqual(info.prerequisites, ["Register Slack OAuth app"])
        XCTAssertEqual(info.adapter, "slack")
    }
    func testBackendPrerequisiteAndDiagnosticSurvivePresentation() throws {
        let error = BackendError(status: 503, failure: ErrorEnvelopeError(code: "capability_unavailable", message: "Host driver not configured", requestId: "request_1", retrySafe: true, details: ["prerequisite": .string("Configure launchd host driver for machine m")]))
        XCTAssertTrue(error.localizedDescription.contains("Configure launchd host driver for machine m"))
        XCTAssertTrue(String(describing: error).contains("capability_unavailable"))
        XCTAssertTrue(String(describing: error).contains("request_1"))
        XCTAssertTrue(String(describing: ClientError.outcomeUnknown("fixed_nonce")).contains("outcome_unknown"))
    }
    func testRejectedDeliveryAndUnknownIndexingRemainDistinct() throws {
        let delivery = try JSONDecoder().decode(MessageReceiptDelivery.self, from: Data(#"{"botId":"b","requestedMode":"followup","effectiveMode":"rejected","targetRunId":null,"runId":"r"}"#.utf8))
        XCTAssertEqual(delivery.effectiveMode, "rejected"); XCTAssertNil(delivery.targetRunId)
        var resource = try JSONDecoder().decode([JSONObject].self, from: WireFixtures.events).first { $0["event"]?.stringValue == "email_account.upserted" }!["payload"]!.objectValue!
        resource["indexingDelayed"] = .null; resource["indexingMeasuredAtMs"] = .null
        let account = try JSONDecoder().decode(EmailAccount.self, from: JSONEncoder().encode(resource))
        let encoded = try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(account))
        XCTAssertEqual(encoded["indexingDelayed"], .null); XCTAssertEqual(encoded["indexingMeasuredAtMs"], .null)
        XCTAssertNil(account.indexingDelayed ?? nil)
        XCTAssertNil(account.indexingMeasuredAtMs ?? nil)
    }
    func testAllEphemeralClientAndServerFramesRoundTrip() throws {
        let clients = Data(#"""
        [{"type":"auth","token":"session","deviceId":"d"},{"type":"subscribe","requestId":"s","cursor":"42","conversationIds":["c"]},{"type":"ack","cursor":"42"},{"type":"ping","requestId":"p"},{"type":"typing","conversationId":"c","active":true},{"type":"presence","foreground":true,"conversationId":null},{"type":"terminal_subscribe","terminalId":"t","afterSeq":4},{"type":"voice","voiceSessionId":"v","action":"mute"}]
        """#.utf8)
        let clientFrames = try JSONDecoder().decode([RealtimeClientFrame].self, from: clients)
        XCTAssertEqual(clientFrames.count, 8)
        XCTAssertEqual(try JSONDecoder().decode([RealtimeClientFrame].self, from: JSONEncoder().encode(clientFrames)), clientFrames)
        let servers = Data(#"""
        [{"type":"ready","userId":"u","workspaceId":"w","cursor":"42","earliestCursor":"1","heartbeatMs":25000},{"type":"subscribed","requestId":"s","cursor":"42","conversationIds":["c"]},{"type":"caught_up","cursor":"42"},{"type":"watermark","cursor":"43"},{"type":"pong","requestId":"p"},{"type":"error","error":{"code":"cursor_expired","message":"Refetch sync","requestId":"req","retrySafe":true}},{"type":"typing","conversationId":"c","userId":"u","active":true,"expiresAtMs":1000},{"type":"terminal_output","terminalId":"t","seq":1,"dataBase64":"eA=="},{"type":"terminal_exit","terminalId":"t","code":null},{"type":"terminal_gap","terminalId":"t","earliestSeq":5,"latestSeq":10}]
        """#.utf8)
        let serverFrames = try JSONDecoder().decode([RealtimeServerFrame].self, from: servers)
        XCTAssertEqual(serverFrames.count, 10)
        XCTAssertEqual(try JSONDecoder().decode([RealtimeServerFrame].self, from: JSONEncoder().encode(serverFrames)), serverFrames)
    }
    func testReadOnlyTeardownAndUnverifiedXIdentityDecodeWithoutInventedSuccess() throws {
        let cleanup = try JSONDecoder().decode(ProviderCleanupResult.self, from: Data(#"{"state":"outcome_unknown","updatedAtMs":1,"errorCode":"upstream_unavailable","providerId":"mail","kind":"email","receiptId":null}"#.utf8))
        XCTAssertEqual(cleanup.state, "outcome_unknown"); XCTAssertNil(cleanup.receiptId)
        let events = try JSONDecoder().decode([RealtimeEvent].self, from: WireFixtures.events)
        let x = try XCTUnwrap(events.first { $0.event == "x_connection.upserted" })
        guard case .xConnectionUpserted(let connection) = x.payload else { return XCTFail("Expected typed X connection") }
        XCTAssertNil(connection.externalAccountId); XCTAssertNil(connection.username)
        let encoded = try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(connection))
        XCTAssertEqual(encoded["externalAccountId"], .null); XCTAssertEqual(encoded["username"], .null)
    }
}

extension ProtocolTests {
    func testFeedbackReasonArraysPreserveExactValuesAndRejectUnknownReasons() throws {
        let reasons = ["not_requested", "inaccurate", "low_quality", "slow"]
        let request = FeedbackCreate(clientNonce: "feedback_nonce_123456", sentiment: "bad", reasons: reasons, comment: "Reviewed")
        let decoded = try JSONDecoder().decode(FeedbackCreate.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.reasons, reasons)
        XCTAssertThrowsError(try JSONDecoder().decode(FeedbackCreate.self, from: Data(#"{"clientNonce":"feedback_nonce_123456","sentiment":"bad","reasons":["inaccurate","future_reason"]}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(FeedbackCreate.self, from: Data(#"{"clientNonce":"feedback_nonce_123456","sentiment":"bad","reasons":null}"#.utf8)))
        var invalid = request
        invalid.reasons = ["inaccurate", "future_reason"]
        XCTAssertThrowsError(try JSONEncoder().encode(invalid))
        var response = Feedback(id: "feedback", revision: 1, createdAtMs: 1, updatedAtMs: 1, entryId: "entry", userId: "user", sentiment: "bad", reasons: reasons, comment: "")
        XCTAssertEqual(try JSONDecoder().decode(Feedback.self, from: JSONEncoder().encode(response)).reasons, reasons)
        response.reasons = ["future_reason"]
        XCTAssertThrowsError(try JSONEncoder().encode(response))
        let omitted = try JSONDecoder().decode(FeedbackCreate.self, from: Data(#"{"clientNonce":"feedback_nonce_123456","sentiment":"good"}"#.utf8))
        XCTAssertNil(omitted.reasons)
    }

    func testExportStreamArraysValidateRequestsResponsesAndOptionalUpdates() throws {
        let streams = ["audit", "action", "usage", "conversation_content"]
        var destination = ExportDestination(id: "export", revision: 1, createdAtMs: 1, updatedAtMs: 1, name: "Collector", url: "https://collector.example", protocol: "otlp_http", streams: streams, enabled: true)
        var create = ExportDestinationCreate(clientNonce: "export_nonce_123456", name: "Collector", url: "https://collector.example", protocol: "ndjson_webhook", streams: streams, enabled: true)
        var update = ExportDestinationUpdate(clientNonce: "export_nonce_123456", revision: 1, streams: streams)
        XCTAssertEqual(try JSONDecoder().decode(ExportDestination.self, from: JSONEncoder().encode(destination)).streams, streams)
        XCTAssertEqual(try JSONDecoder().decode(ExportDestinationCreate.self, from: JSONEncoder().encode(create)).streams, streams)
        XCTAssertEqual(try JSONDecoder().decode(ExportDestinationUpdate.self, from: JSONEncoder().encode(update)).streams, streams)
        destination.streams = ["future_stream"]; create.streams = ["future_stream"]; update.streams = ["future_stream"]
        XCTAssertThrowsError(try JSONEncoder().encode(destination))
        XCTAssertThrowsError(try JSONEncoder().encode(create))
        XCTAssertThrowsError(try JSONEncoder().encode(update))
        XCTAssertThrowsError(try JSONDecoder().decode(ExportDestinationUpdate.self, from: Data(#"{"clientNonce":"export_nonce_123456","revision":1,"streams":["audit","future_stream"]}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(ExportDestinationUpdate.self, from: Data(#"{"clientNonce":"export_nonce_123456","revision":1,"streams":null}"#.utf8)))
        XCTAssertNil(try JSONDecoder().decode(ExportDestinationUpdate.self, from: Data(#"{"clientNonce":"export_nonce_123456","revision":1}"#.utf8)).streams)
    }

    func testXMediaArraysUseOnlyTheDeclaredWireKinds() throws {
        let media = ["photo", "video", "gif"]
        var provider = XProviderInfo(id: "x", kind: "x", label: "X", configured: false, prerequisites: [], capabilities: [], publicHandle: "bot", oauthScopes: [], allowedMedia: media, deniedCountries: [])
        XCTAssertEqual(try JSONDecoder().decode(XProviderInfo.self, from: JSONEncoder().encode(provider)).allowedMedia, media)
        XCTAssertThrowsError(try JSONDecoder().decode(XProviderInfo.self, from: Data(#"{"id":"x","kind":"x","label":"X","configured":false,"prerequisites":[],"capabilities":[],"publicHandle":"bot","oauthScopes":[],"allowedMedia":["photo","audio"],"deniedCountries":[]}"#.utf8)))
        provider.allowedMedia = ["audio"]
        XCTAssertThrowsError(try JSONEncoder().encode(provider))
        let oauth = OAuthProviderConfig(id: "oauth", clientId: "client", clientSecretRef: "operator-reference", authorizeUrl: "https://provider.example/authorize", tokenUrl: "https://provider.example/token", scopes: [], redirectUris: [], allowedOrigins: [])
        var configuration = OperatorConfigurationXProvider(oauth: oauth, publicHandle: "bot", signingSecretRef: "signing-reference", apiBaseUrl: "https://provider.example", deniedCountries: [], allowedMedia: media)
        XCTAssertEqual(try JSONDecoder().decode(OperatorConfigurationXProvider.self, from: JSONEncoder().encode(configuration)).allowedMedia, media)
        configuration.allowedMedia = ["audio"]
        XCTAssertThrowsError(try JSONEncoder().encode(configuration))
    }

    func testNullableActorIdentityDoesNotBecomeANestedIdentifiableID() throws {
        let actor = try JSONDecoder().decode(Actor.self, from: Data(#"{"kind":"system","id":null,"displayName":"System"}"#.utf8))
        XCTAssertNil(actor.id)
        let named = try JSONDecoder().decode(Actor.self, from: Data(#"{"kind":"bot","id":"bot_owned","displayName":"Research"}"#.utf8))
        XCTAssertEqual(named.id, "bot_owned")
    }
}

extension ProtocolTests {
    func testEveryOwnerTranscriptEventRoundTripsWithoutCrossHumanEvents() throws {
        let events = try JSONDecoder().decode([TranscriptEvent].self, from: WireFixtures.transcriptEvents)
        XCTAssertEqual(Set(events.map(\.type)), ["name_changed", "channel_connected", "channel_disconnected", "routine_changed", "task_changed", "bot_added", "bot_removed", "handoff", "machine_moved"])
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(events)), try JSONDecoder().decode(JSONValue.self, from: WireFixtures.transcriptEvents))
        for type in ["team_shared", "team_bot_published", "team_bot_unpublished", "person_added", "person_removed", "person_left", "future_event"] {
            XCTAssertThrowsError(try JSONDecoder().decode(TranscriptEvent.self, from: JSONEncoder().encode(["type": type])), type)
        }
    }

    func testPairedSessionExpiryIsRequiredNullableRatherThanOmitted() throws {
        let auth = try JSONDecoder().decode(AuthResult.self, from: WireFixtures.pairedAuth)
        XCTAssertNil(auth.session.expiresAtMs)
        var session = try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(auth.session))
        XCTAssertEqual(session["expiresAtMs"], .null)
        session.removeValue(forKey: "expiresAtMs")
        XCTAssertThrowsError(try JSONDecoder().decode(AuthSession.self, from: JSONEncoder().encode(session)))
        session["expiresAtMs"] = .number(1790000300000)
        XCTAssertEqual(try JSONDecoder().decode(AuthSession.self, from: JSONEncoder().encode(session)).expiresAtMs, 1790000300000)
        session["expiresAtMs"] = .string("never")
        XCTAssertThrowsError(try JSONDecoder().decode(AuthSession.self, from: JSONEncoder().encode(session)))
    }

    func testPairingStatesRetainSafeResourceAndRequireNullableKeys() throws {
        var wire = try JSONDecoder().decode(JSONObject.self, from: WireFixtures.pairing)
        for status in ["waiting", "pending_approval", "approved", "denied", "expired", "consumed"] {
            wire["status"] = .string(status)
            wire["deviceName"] = .null
            wire["verificationCode"] = .null
            let pairing = try JSONDecoder().decode(Pairing.self, from: JSONEncoder().encode(wire))
            XCTAssertEqual(pairing.status, status)
            XCTAssertEqual(pairing.ownerUserId, "resource")
            XCTAssertEqual(pairing.backendUrl, "https://desktop.example.ts.net")
            XCTAssertNil(pairing.deviceName)
            XCTAssertNil(pairing.verificationCode)
            XCTAssertEqual(try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(pairing)), wire)
        }
        for key in ["deviceName", "verificationCode", "ownerUserId", "workspaceId", "status", "expiresAtMs"] {
            var missing = wire
            missing.removeValue(forKey: key)
            XCTAssertThrowsError(try JSONDecoder().decode(Pairing.self, from: JSONEncoder().encode(missing)), key)
        }
        wire["status"] = .string("connected")
        XCTAssertThrowsError(try JSONDecoder().decode(Pairing.self, from: JSONEncoder().encode(wire)))
        var invalid = try JSONDecoder().decode(Pairing.self, from: WireFixtures.pairing)
        invalid.status = "future_status"
        XCTAssertThrowsError(try JSONEncoder().encode(invalid))
        let safe = try JSONDecoder().decode(JSONObject.self, from: WireFixtures.pairing)
        var legacy = safe
        for key in ["pairCode", "pairUrl", "claimToken", "token"] {
            legacy[key] = .string("must-not-leak-\(key)")
        }
        let pairing = try JSONDecoder().decode(Pairing.self, from: JSONEncoder().encode(legacy))
        XCTAssertEqual(try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(pairing)), safe)
    }

    func testNamedPairingRequestsAndResultsRoundTripExactWireKeys() throws {
        func roundTrip<T: Codable & Equatable>(_ type: T.Type, _ text: String) throws {
            let data = Data(text.utf8)
            let value = try JSONDecoder().decode(type, from: data)
            let encoded = try JSONEncoder().encode(value)
            XCTAssertEqual(try JSONDecoder().decode(type, from: encoded), value)
            XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: encoded), try JSONDecoder().decode(JSONValue.self, from: data))
            let fields = try JSONDecoder().decode(JSONObject.self, from: data)
            for key in fields.keys {
                var missing = fields
                missing.removeValue(forKey: key)
                XCTAssertThrowsError(try JSONDecoder().decode(type, from: JSONEncoder().encode(missing)), "\(type).\(key)")
                var null = fields
                null[key] = .null
                XCTAssertThrowsError(try JSONDecoder().decode(type, from: JSONEncoder().encode(null)), "\(type).\(key)")
            }
        }
        try roundTrip(PairingStart.self, #"{"clientNonce":"start_fixed"}"#)
        try roundTrip(PairingLink.self, #"{"backendUrl":"https://desktop.example.ts.net","workspaceId":"workspace_owned","pairCode":"short_lived_fixture_code"}"#)
        try roundTrip(PairingPreviewRequest.self, #"{"pairCode":"short_lived_fixture_code","workspaceId":"workspace_owned"}"#)
        try roundTrip(PairingPreviewResult.self, #"{"clusterName":"Owner desktop","backendUrl":"https://desktop.example.ts.net","expiresAtMs":1790000300000}"#)
        try roundTrip(PairingClaim.self, #"{"clientNonce":"claim_fixed","pairCode":"short_lived_fixture_code","workspaceId":"workspace_owned","installationId":"installation_phone","deviceName":"Owner iPhone","appVersion":"1.0"}"#)
        try roundTrip(PairingClaimResult.self, #"{"pairingId":"pairing_owned","claimToken":"fixture_claim_token","verificationCode":"123456","expiresAtMs":1790000300000,"clusterName":"Owner desktop","backendUrl":"https://desktop.example.ts.net"}"#)
        try roundTrip(PairingApprove.self, #"{"clientNonce":"approve_fixed","revision":2,"verificationCode":"123456"}"#)
        try roundTrip(PairingDeny.self, #"{"clientNonce":"deny_fixed","revision":2}"#)
        try roundTrip(PairingComplete.self, #"{"clientNonce":"complete_fixed","claimToken":"fixture_claim_token"}"#)
        let pairing = try JSONDecoder().decode(Pairing.self, from: WireFixtures.pairing)
        let issued = PairingIssued(pairing: pairing, pairUrl: "lemonbot://pair?backend=https%3A%2F%2Fdesktop.example.ts.net&cluster=workspace_owned&code=short_lived_fixture_code")
        XCTAssertEqual(try JSONDecoder().decode(PairingIssued.self, from: JSONEncoder().encode(issued)), issued)
        let encoded = try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(issued))
        XCTAssertEqual(Set(encoded.keys), ["pairing", "pairUrl"])
        for key in ["pairing", "pairUrl"] {
            var missing = encoded
            missing.removeValue(forKey: key)
            XCTAssertThrowsError(try JSONDecoder().decode(PairingIssued.self, from: JSONEncoder().encode(missing)))
        }
    }

    func testPairingCompletionDiscriminatesProgressFromDeviceBoundAuthority() throws {
        let completions = try JSONDecoder().decode([PairingCompletion].self, from: WireFixtures.pairingCompletions)
        XCTAssertEqual(completions.map(\.status), ["pending", "denied", "expired", "connected"])
        for completion in completions.prefix(3) {
            guard case .pending(let result) = completion else { return XCTFail("Expected credential-free state") }
            XCTAssertEqual(result.pairingId, "pairing_owned")
            XCTAssertEqual(result.expiresAtMs, 1790000300000)
            let fields = try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(completion))
            XCTAssertEqual(Set(fields.keys), ["status", "pairingId", "expiresAtMs"])
        }
        guard case .connected(let result) = completions[3] else { return XCTFail("Expected connected session and device") }
        XCTAssertEqual(result.status, "connected")
        XCTAssertEqual(result.device.platform, "ios")
        XCTAssertEqual(result.auth.session.deviceId, result.device.id)
        XCTAssertNil(result.auth.session.expiresAtMs)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(completions)), try JSONDecoder().decode(JSONValue.self, from: WireFixtures.pairingCompletions))
        for invalid in [
            #"{"status":"approved","pairingId":"p","expiresAtMs":1}"#,
            #"{"status":"pending","expiresAtMs":1}"#,
            #"{"status":"expired","pairingId":"p","expiresAtMs":null}"#,
            #"{"status":"connected","pairingId":"p","expiresAtMs":1}"#,
            #"{"status":"connected","auth":null,"device":null}"#,
            #"{"pairingId":"p","expiresAtMs":1}"#
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(PairingCompletion.self, from: Data(invalid.utf8)), invalid)
        }
        let invalid = PairingCompletion.pending(PairingCompletionPending(status: "connected", pairingId: "p", expiresAtMs: 1))
        XCTAssertThrowsError(try JSONEncoder().encode(invalid))
    }

    func testOwnerResourceFixturesDoNotReencodeEliminatedAuthorityFields() throws {
        let clean = try JSONDecoder().decode([RealtimeEvent].self, from: WireFixtures.events)
        var legacy = try JSONDecoder().decode([JSONObject].self, from: WireFixtures.events)
        let eliminated: [String: JSONObject] = [
            "bot.upserted": ["managerUserIds": .array([.string("legacy_manager")]), "visibility": .string("team"), "published": .bool(true), "required": .bool(true)],
            "conversation.upserted": ["humanUserIds": .array([.string("legacy_human")])],
            "skill.upserted": ["scope": .string("team")],
            "memory.upserted": ["scope": .string("team"), "userId": .string("legacy_user")],
            "memory.deleted": ["scope": .string("team"), "userId": .string("legacy_user")],
            "connector.upserted": ["shared": .bool(true)],
            "group_policy.upserted": ["defaultBotIds": .array([.string("legacy_bot")])]
        ]
        // Populate every removed field: an optional property reintroduced in the
        // model must not pass merely because the current fixtures omit its key.
        for (event, fields) in eliminated {
            let index = try XCTUnwrap(legacy.firstIndex { $0["event"]?.stringValue == event })
            var payload = try XCTUnwrap(legacy[index]["payload"]?.objectValue)
            payload.merge(fields) { _, legacyValue in legacyValue }
            legacy[index]["payload"] = .object(payload)
        }
        let events = try JSONDecoder().decode([RealtimeEvent].self, from: JSONEncoder().encode(legacy))
        XCTAssertEqual(events, clean, "Legacy authority must not enter the typed resources")
        let wire = try JSONDecoder().decode([JSONObject].self, from: JSONEncoder().encode(events))
        for (event, fields) in eliminated {
            let payload = try XCTUnwrap(wire.first { $0["event"]?.stringValue == event }?["payload"]?.objectValue)
            for key in fields.keys { XCTAssertNil(payload[key], "\(event).\(key)") }
        }
        let pairingEvent = try XCTUnwrap(events.first { $0.event == "pairing.upserted" })
        guard case .pairingUpserted(let pairing) = pairingEvent.payload else { return XCTFail("Expected typed pairing resource") }
        XCTAssertEqual(pairing.id, "pairing_owned")
        for name in ["conversation.left", "consent.upserted", "future.event"] {
            XCTAssertThrowsError(try JSONDecoder().decode(RealtimeEvent.self, from: JSONEncoder().encode(["type": JSONValue.string("event"), "seq": .string("42"), "event": .string(name), "payload": .object([:]), "timestampMs": .number(1)])), name)
        }
        for action in ["team_publish", "connector_consent", "future_action"] {
            XCTAssertThrowsError(try JSONDecoder().decode(CardAction.self, from: JSONEncoder().encode(["action": action])), action)
        }
    }

    func testOwnerConversationKindsRejectEliminatedTeamDirectMessages() throws {
        for kind in ["dm", "task", "group", "channel"] {
            let request = ConversationCreate(clientNonce: "conversation_fixed", kind: kind, botIds: ["bot_owned", "bot_second"])
            XCTAssertEqual(try JSONDecoder().decode(ConversationCreate.self, from: JSONEncoder().encode(request)), request)
        }
        let invalid = ConversationCreate(clientNonce: "conversation_fixed", kind: "team_dm", botIds: ["bot_owned"])
        XCTAssertThrowsError(try JSONEncoder().encode(invalid))
        XCTAssertThrowsError(try JSONDecoder().decode(ConversationCreate.self, from: Data(#"{"clientNonce":"conversation_fixed","kind":"team_dm","botIds":["bot_owned"]}"#.utf8)))
        var resource = try XCTUnwrap(try JSONDecoder().decode([JSONObject].self, from: WireFixtures.events).first { $0["event"]?.stringValue == "conversation.upserted" }?["payload"]?.objectValue)
        resource["kind"] = .string("team_dm")
        XCTAssertThrowsError(try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(resource)))
    }
}
