import XCTest
import LemonBotKit
@testable import LemonBotUI

final class GrantPresentationTests: XCTestCase {
    private var capability: MachineCapability {
        MachineCapability(id: "terminal", name: "Measured terminal", category: "shell", supported: true, configuredLevel: "read_interact", osGrant: "not_required", tools: ["bash"], reason: "destination_shell_measured", measuredAtMs: 1, stale: false)
    }
    private var grant: BotGrant {
        BotGrant(id: "grant", revision: 1, createdAtMs: 1, updatedAtMs: 1, botId: "bot", machineId: "machine", capabilityId: "terminal", requestedLevel: "read_interact", effectiveLevel: "read_interact", pendingLevel: nil, reasons: [capability.reason])
    }
    func testMeasuredNamesAndCategoriesWin() {
        XCTAssertEqual(GrantPresentation.name("terminal", capability), capability.name)
        XCTAssertEqual(GrantPresentation.name("connector:1", nil, connectorName: "Calendar"), "Calendar")
        XCTAssertEqual(GrantPresentation.group("custom", capability), "Everyday")
        XCTAssertEqual(GrantPresentation.group("connector:1", nil), "Connections")
        XCTAssertEqual(GrantPresentation.group("screen_recording", nil), "Control this Mac")
    }
    func testUnsupportedControls() {
        XCTAssertNotNil(GrantPresentation.controlReason("terminal", "read_only", capability))
        XCTAssertNotNil(GrantPresentation.controlReason("custom", "read_only", capability))
        XCTAssertNil(GrantPresentation.controlReason("terminal", "read_interact", capability))
        XCTAssertNil(GrantPresentation.controlReason("files", "read_only", nil))
        var desktop = capability; desktop.category = "os_app"
        XCTAssertNotNil(GrantPresentation.controlReason("screen_recording", "read_only", desktop))
    }
    func testBlockersTakePrecedenceOverReadiness() {
        let ready = GrantPresentation.status(grant, capability)
        var stale = capability; stale.stale = true
        XCTAssertNotEqual(GrantPresentation.status(grant, stale), ready)
        var policy = grant; policy.reasons.append("Local execution is deny; workspace ceiling is deny.")
        XCTAssertEqual(GrantPresentation.status(policy, stale), GrantPresentation.status(policy, capability))
        XCTAssertNotEqual(GrantPresentation.status(policy, capability), GrantPresentation.status(grant, stale))
        var pending = policy; pending.reasons.append("Tool-policy cutover has not been acknowledged.")
        XCTAssertNotEqual(GrantPresentation.status(pending, capability), GrantPresentation.status(policy, capability))
        var limited = grant; limited.effectiveLevel = "off"
        XCTAssertNotEqual(GrantPresentation.status(limited, capability), ready)
    }
    func testUnknownCodesStayInRawEvidence() {
        var unknown = grant; unknown.reasons = ["future_machine_code"]; unknown.effectiveLevel = "off"
        XCTAssertFalse(GrantPresentation.status(unknown, nil).contains("future_machine_code"))
        XCTAssertEqual(unknown.reasons, ["future_machine_code"])
    }
    func testQueuedGrantChangesUseRequestedRatherThanEffectiveLevel() {
        var queued = grant
        XCTAssertNil(GrantPresentation.pendingMessage(queued))
        queued.pendingLevel = "off"
        XCTAssertEqual(GrantPresentation.pendingMessage(queued), "Turns off when the current task finishes")
        queued.pendingLevel = "read_only"
        queued.effectiveLevel = "off"
        XCTAssertEqual(GrantPresentation.pendingMessage(queued), "Turns off when the current task finishes")
        queued.requestedLevel = "off"
        XCTAssertEqual(GrantPresentation.pendingMessage(queued), "Turns on when the current task finishes")
        queued.pendingLevel = nil
        XCTAssertNil(GrantPresentation.pendingMessage(queued))
    }
    func testAccessRequestLabelsQuotedReasonAndResolution() throws {
        let cards = try JSONDecoder().decode([Card].self, from: WireFixtures.cards)
        guard case .accessRequest(let card) = try XCTUnwrap(cards.first { $0.type == "access_request" }) else { return XCTFail("Missing access card") }
        XCTAssertEqual(AccessRequestPresentation.allowLabel, "Allow for this Bot")
        XCTAssertEqual(AccessRequestPresentation.denyLabel, "Not now")
        XCTAssertEqual(AccessRequestPresentation.reason(card.approval, botName: "Lemon"), "Lemon says: “I need Terminal to finish your request.”")
        XCTAssertEqual(AccessRequestPresentation.result(state: "approved", who: "you"), "Allowed by you · turns on when this task finishes")
        XCTAssertEqual(AccessRequestPresentation.result(state: "denied", who: "you"), "Not now")
        XCTAssertEqual(AccessRequestPresentation.result(state: "expired", who: "you"), "Expired")
    }
}
