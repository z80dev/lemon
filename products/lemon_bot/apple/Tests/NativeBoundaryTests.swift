import Foundation
import XCTest
import LemonBotKit

final class NativeBoundaryTests: XCTestCase {
    func testDestructivePreviewRetainsExactScopeAndResidualEffects() throws {
        let data = Data(#"{"confirmationToken":"preview_once","revision":7,"confirmName":"Research","expiresAtMs":1791940000000,"effects":["Remove selected memory"],"affected":[{"resourceType":"memory","id":"fact_private","machineId":"host_remote","operation":"delete","explanation":"Only this selected fact is removed."},{"resourceType":"conversation","id":"chat_main","machineId":"host_remote","operation":"retain","explanation":"Transcript and operator backups remain."}]}"#.utf8)
        let preview = try JSONDecoder().decode(Confirmation.self, from: data)
        XCTAssertEqual(preview.revision, 7)
        XCTAssertEqual(preview.confirmationToken, "preview_once")
        XCTAssertEqual(preview.affected.map(\.id), ["fact_private", "chat_main"])
        XCTAssertEqual(preview.affected.map(\.operation), ["delete", "retain"])
        XCTAssertEqual(preview.affected.last?.machineId, "host_remote")
    }

    func testUnknownMutationOutcomePreservesReconciliationIdentity() throws {
        let data = Data(#"{"error":{"code":"outcome_unknown","message":"Check the existing run before sending again.","requestId":"request_existing","retrySafe":false,"details":{"resourceIds":["run_reserved"],"runId":"run_reserved"}}}"#.utf8)
        let failure = try JSONDecoder().decode(ErrorEnvelope.self, from: data)
        XCTAssertEqual(failure.error.code, "outcome_unknown")
        XCTAssertFalse(failure.error.retrySafe)
        XCTAssertEqual(failure.error.requestId, "request_existing")
        XCTAssertEqual(failure.error.details?["runId"]?.stringValue, "run_reserved")
        XCTAssertEqual(failure.error.details?["resourceIds"]?.arrayValue?.first?.stringValue, "run_reserved")
    }

    func testPagedOpaqueCursorIsNotConvertedToFloatingPoint() throws {
        let data = Data(#"{"items":[{"id":"removed_fact","deleted":true}],"nextCursor":"18446744073709551615"}"#.utf8)
        let page = try JSONDecoder().decode(Page<Deleted>.self, from: data)
        XCTAssertEqual(page.items.first?.id, "removed_fact")
        XCTAssertEqual(page.nextCursor, "18446744073709551615")
        let encoded = try JSONEncoder().encode(page)
        let decoded = try JSONDecoder().decode(Page<Deleted>.self, from: encoded)
        XCTAssertEqual(decoded.nextCursor, page.nextCursor)
    }

    func testTaskNotificationTargetSurvivesRoundTripWithoutLosingTaskIdentity() throws {
        let data = Data(#"{"kind":"entry","botId":"bot_named","conversationId":"task_review","taskConversationId":"task_review","entryId":"entry_result"}"#.utf8)
        let target = try JSONDecoder().decode(NotificationTarget.self, from: data)
        let encoded = try JSONEncoder().encode(target)
        let roundTrip = try JSONSerialization.jsonObject(with: encoded) as? [String: String]
        XCTAssertEqual(roundTrip?["conversationId"], "task_review")
        XCTAssertEqual(roundTrip?["taskConversationId"], "task_review")
        XCTAssertEqual(roundTrip?["entryId"], "entry_result")
        XCTAssertEqual(roundTrip?["kind"], "entry")
    }

    func testMissingMailboxObservationRemainsUnknown() throws {
        let data = Data(#"{"id":"mailbox_owned","revision":1,"createdAtMs":1000,"updatedAtMs":1000,"userId":"user_owner","provider":"registered_mail","address":"owner@example.org","immutableAddress":true,"state":"active","channelBindingId":null}"#.utf8)
        let account = try JSONDecoder().decode(EmailAccount.self, from: data)
        XCTAssertNil(account.indexingDelayed)
        XCTAssertNil(account.indexingMeasuredAtMs)
    }

    func testMeasuredMailboxDelayRetainsObservationTime() throws {
        let data = Data(#"{"id":"mailbox_owned","revision":2,"createdAtMs":1000,"updatedAtMs":2000,"userId":"user_owner","provider":"registered_mail","address":"owner@example.org","immutableAddress":true,"state":"active","channelBindingId":null,"indexingDelayed":true,"indexingMeasuredAtMs":1900}"#.utf8)
        let account = try JSONDecoder().decode(EmailAccount.self, from: data)
        XCTAssertEqual(account.indexingDelayed ?? nil, true)
        XCTAssertEqual(account.indexingMeasuredAtMs ?? nil, 1900)
    }

    func testRejectedDeliveryPreservesFailedRunReasonWithoutInventingStart() throws {
        let data = Data(#"{"entries":[],"runs":[{"id":"run_refused","revision":1,"createdAtMs":1000,"updatedAtMs":1000,"conversationId":"chat_owned","botId":"bot_remote","initiatorUserId":"user_owner","clientNonce":"receipt_fixed_nonce","status":"failed","error":{"code":"policy_denied","message":"Spend limit exhausted.","requestId":"request_admission","retrySafe":true},"startedAtMs":null,"completedAtMs":1000,"routineRunId":null}],"clientNonce":"receipt_fixed_nonce","status":"accepted","delivery":[{"botId":"bot_remote","requestedMode":"followup","effectiveMode":"rejected","targetRunId":null,"runId":"run_refused"}]}"#.utf8)
        let receipt = try JSONDecoder().decode(MessageReceipt.self, from: data)
        XCTAssertEqual(receipt.delivery.first?.effectiveMode, "rejected")
        XCTAssertEqual(receipt.runs.first?.status, "failed")
        XCTAssertEqual(receipt.runs.first?.error?.code, "policy_denied")
        XCTAssertNil(receipt.runs.first?.startedAtMs)
        XCTAssertNil(receipt.delivery.first?.targetRunId)
        XCTAssertEqual(receipt.clientNonce, "receipt_fixed_nonce")
    }

    func testProductCleanupDoesNotHideUnknownProviderOutcome() throws {
        let data = Data(#"{"id":"cleanup_fixed","revision":3,"createdAtMs":1000,"updatedAtMs":2000,"operation":"delete_account","userId":"user_deleted","workspaceId":"workspace_owned","state":"outcome_unknown","productCleanup":{"state":"completed","updatedAtMs":1900,"errorCode":null},"providerCleanup":[{"providerId":"registered_mail","kind":"email","receiptId":"receipt_original","state":"outcome_unknown","updatedAtMs":2000,"errorCode":"upstream_unavailable"}],"requestId":"request_delete","startedAtMs":1200,"completedAtMs":null}"#.utf8)
        let operation = try JSONDecoder().decode(AccountTeardown.self, from: data)
        XCTAssertEqual(operation.productCleanup.state, "completed")
        XCTAssertEqual(operation.state, "outcome_unknown")
        XCTAssertEqual(operation.providerCleanup.first?.state, "outcome_unknown")
        XCTAssertEqual(operation.providerCleanup.first?.receiptId, "receipt_original")
        XCTAssertNil(operation.completedAtMs)
    }

    func testPendingXConnectionDoesNotInventVerifiedAccountIdentity() throws {
        let data = Data(#"{"id":"x_pending","revision":1,"createdAtMs":1000,"updatedAtMs":1000,"userId":"user_owner","externalAccountId":null,"username":null,"mainBotId":"bot_owned","enabled":true,"state":"pending","lastError":null}"#.utf8)
        let connection = try JSONDecoder().decode(XConnection.self, from: data)
        XCTAssertEqual(connection.state, "pending")
        XCTAssertNil(connection.username)
        XCTAssertNil(connection.externalAccountId)
    }

    func testOwnerGroupCarriesBotsAndOneOwnerWithoutHumanMembership() throws {
        let data = Data(#"{"id":"group_owned","revision":3,"createdAtMs":1000,"updatedAtMs":2000,"kind":"group","name":"Review","botIds":["bot_research","bot_review"],"ownerUserId":"user_owner","parentConversationId":null,"leadBotId":"bot_review","channelBindingId":null,"lastEntryId":null,"unreadCount":0,"lastReadSeq":0,"activity":[]}"#.utf8)
        let conversation = try JSONDecoder().decode(Conversation.self, from: data)
        XCTAssertEqual(conversation.ownerUserId, "user_owner")
        XCTAssertEqual(conversation.botIds, ["bot_research", "bot_review"])
        XCTAssertEqual(conversation.leadBotId, "bot_review")
        let wire = try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(conversation))
        XCTAssertNil(wire["humanUserIds"])
        XCTAssertEqual(wire["parentConversationId"], .null)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), .object(wire))
        let update = ConversationUpdate(clientNonce: "group_fixed_nonce", revision: 3, botIds: ["bot_research", "bot_review"], leadBotId: .some(nil))
        let request = try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(update))
        XCTAssertEqual(request["leadBotId"], .null)
        XCTAssertNil(request["humanUserIds"])
    }

    func testPairingRealtimeStateCannotSupplyPhoneSessionAuthority() throws {
        let data = Data(#"{"type":"event","seq":"18446744073709551615","event":"pairing.upserted","timestampMs":2000,"payload":{"id":"pairing_owned","revision":2,"createdAtMs":1000,"updatedAtMs":2000,"workspaceId":"workspace_owned","ownerUserId":"user_owner","clusterName":"Owner desktop","backendUrl":"https://desktop.example.ts.net","status":"pending_approval","expiresAtMs":301000,"deviceName":"Owner iPhone","verificationCode":"123456"}}"#.utf8)
        let event = try JSONDecoder().decode(RealtimeEvent.self, from: data)
        guard case .pairingUpserted(let pairing) = event.payload else { return XCTFail("Expected safe pairing state") }
        XCTAssertEqual(pairing.status, "pending_approval")
        XCTAssertEqual(pairing.verificationCode, "123456")
        XCTAssertEqual(event.seq, "18446744073709551615")
        let wire = try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(event))
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), .object(wire))
    }

    func testPersistentPairedSessionRequiresExplicitNullExpiryAndDeviceIdentity() throws {
        let data = Data(#"{"id":"session_paired","revision":1,"createdAtMs":1000,"updatedAtMs":1000,"userId":"user_owner","deviceId":"device_phone","expiresAtMs":null,"lastSeenAtMs":1000,"current":true}"#.utf8)
        let session = try JSONDecoder().decode(AuthSession.self, from: data)
        XCTAssertEqual(session.deviceId, "device_phone")
        XCTAssertNil(session.expiresAtMs)
        var fields = try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(fields["expiresAtMs"], .null)
        fields.removeValue(forKey: "expiresAtMs")
        XCTAssertThrowsError(try JSONDecoder().decode(AuthSession.self, from: JSONEncoder().encode(fields)))
        fields["expiresAtMs"] = .number(301000)
        XCTAssertEqual(try JSONDecoder().decode(AuthSession.self, from: JSONEncoder().encode(fields)).expiresAtMs, 301000)
    }

    func testPairingPreviewIsReadOnlyAndContainsNoClaimOrSessionCapability() throws {
        let data = Data(#"{"clusterName":"Owner desktop","backendUrl":"https://desktop.example.ts.net","expiresAtMs":301000}"#.utf8)
        let result = try JSONDecoder().decode(PairingPreviewResult.self, from: data)
        XCTAssertEqual(result.clusterName, "Owner desktop")
        XCTAssertEqual(result.backendUrl, "https://desktop.example.ts.net")
        XCTAssertEqual(result.expiresAtMs, 301000)
        let output = try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(Set(output.keys), ["clusterName", "backendUrl", "expiresAtMs"])
    }
}
