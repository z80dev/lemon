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
}
