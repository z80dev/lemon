import XCTest
@testable import LemonBotKit

final class ProtocolTests: XCTestCase {
    func testEveryDeclaredCardRoundTripsWithExactDiscriminator() throws {
        let cards = try JSONDecoder().decode([Card].self, from: WireFixtures.cards)
        XCTAssertEqual(cards.count, 25)
        XCTAssertEqual(Set(cards.map(\.type)).count, 25)
        let reencoded = try JSONEncoder().encode(cards)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: reencoded), try JSONDecoder().decode(JSONValue.self, from: WireFixtures.cards))
    }
    func testAllEntriesAndRealtimeEventsDecodeAndRoundTrip() throws {
        let entries = try JSONDecoder().decode([TranscriptEntry].self, from: WireFixtures.entries)
        XCTAssertEqual(Set(entries.map(\.kind)).count, 9)
        XCTAssertTrue(entries.allSatisfy { $0.id == "resource" && $0.seq == 1 })
        XCTAssertEqual(try JSONDecoder().decode([TranscriptEntry].self, from: JSONEncoder().encode(entries)), entries)
        let events = try JSONDecoder().decode([RealtimeEvent].self, from: WireFixtures.events)
        XCTAssertEqual(events.count, 72)
        XCTAssertEqual(Set(events.map(\.event)).count, 72)
        XCTAssertTrue(events.allSatisfy { $0.seq == "9007199254740993123456" })
        XCTAssertEqual(try JSONDecoder().decode([RealtimeEvent].self, from: JSONEncoder().encode(events)), events)
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
        let named = try JSONDecoder().decode(Actor.self, from: Data(#"{"kind":"bot","id":"bot_owned","displayName":"Teammate"}"#.utf8))
        XCTAssertEqual(named.id, "bot_owned")
    }
}
