import XCTest
import Foundation
import LemonBotKit
@testable import LemonBotUI

@MainActor final class ComposerActionTests: XCTestCase {
    func testAuthoritativeResolutionClearsOnlyTheOriginalMessageUncertaintyAndError() async {
        let action = UIActionState()
        await action.perform { throw ClientError.outcomeUnknown("original_message_nonce") }
        XCTAssertTrue(action.busy); XCTAssertNotNil(action.error)
        XCTAssertEqual(action.errorNonce, "original_message_nonce")
        action.resolveUncertainty("another_nonce")
        XCTAssertTrue(action.uncertain); XCTAssertNotNil(action.error)
        action.resolveUncertainty("original_message_nonce")
        XCTAssertFalse(action.busy); XCTAssertFalse(action.uncertain)
        XCTAssertNil(action.error); XCTAssertNil(action.errorNonce); XCTAssertNil(action.uncertainNonce)
    }
    func testResolvingAnOldMessageDoesNotSuppressAnUnrelatedCurrentFailure() async {
        let action = UIActionState()
        await action.perform { throw ClientError.outcomeUnknown("original_message_nonce") }
        await action.perform { throw BackendError(status: 503, failure: ErrorEnvelopeError(code: "capability_unavailable", message: "Configure the upload provider", requestId: "actual_failure", retrySafe: true)) }
        XCTAssertNil(action.errorNonce)
        action.resolveUncertainty("original_message_nonce")
        XCTAssertFalse(action.uncertain)
        XCTAssertTrue(action.error?.contains("Configure the upload provider") == true)
        XCTAssertTrue(action.error?.contains("actual_failure") == true)
    }
    func testRecordedRefusalKeepsItsExactDiagnosticBeforeReceiptReconciliation() async {
        let action = UIActionState()
        await action.perform { throw BackendError(status: 503, failure: ErrorEnvelopeError(code: "capability_unavailable", message: "Destination provider is unavailable", requestId: "refused_target", retrySafe: true, details: ["clientNonce": .string("refused_nonce"), "runIds": .array([.string("failed_run")]), "entryIds": .array([.string("authored_entry")])])) }
        XCTAssertEqual(action.uncertainNonce, "refused_nonce")
        XCTAssertEqual(action.errorNonce, "refused_nonce")
        XCTAssertTrue(action.error?.contains("Destination provider is unavailable") == true)
        XCTAssertTrue(action.error?.contains("failed_run") == true)
    }
}
