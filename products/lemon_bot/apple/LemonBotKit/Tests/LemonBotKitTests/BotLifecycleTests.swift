import XCTest
import LemonBotKit
@testable import LemonBotUI

final class BotLifecycleTests: XCTestCase {
    private func botPayload() throws -> JSONObject {
        let events = try JSONDecoder().decode([JSONObject].self, from: WireFixtures.events)
        return try XCTUnwrap(events.first { $0["event"]?.stringValue == "bot.upserted" }?["payload"]?.objectValue)
    }

    func testBotLifecycleIsOptionalAndRoundTripsEveryStatus() throws {
        var payload = try botPayload()
        payload.removeValue(forKey: "lifecycle")
        let legacy = try JSONDecoder().decode(Bot.self, from: JSONEncoder().encode(payload))
        XCTAssertNil(legacy.lifecycle)
        let legacyWire = try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(legacyWire["lifecycle"])
        payload["lifecycle"] = .null
        XCTAssertNil(try JSONDecoder().decode(Bot.self, from: JSONEncoder().encode(payload)).lifecycle)
        for status in ["running", "failed", "outcome_unknown"] {
            var bot = legacy
            bot.lifecycle = BotLifecycle(action: "import", status: status, step: "profile_sync", message: "Reconnect the machine to continue.", canFinishSetup: status != "running", canReaddress: false, canDelete: status != "running")
            XCTAssertEqual(try JSONDecoder().decode(Bot.self, from: JSONEncoder().encode(bot)), bot)
        }
    }

    func testOfflineFailedCreateAndImportKeepRecoveryAndDeleteAvailable() throws {
        for action in ["create", "import"] {
            for status in ["failed", "outcome_unknown"] {
                var bot = try JSONDecoder().decode(Bot.self, from: JSONEncoder().encode(botPayload()))
                bot.activity = "offline"
                bot.lifecycle = BotLifecycle(action: action, status: status, step: "profile_sync", message: "Reconnect the machine to continue.", canFinishSetup: true, canReaddress: false, canDelete: true)
                XCTAssertEqual(BotLifecyclePresentation.operations(bot.lifecycle), ["finish-setup", "delete"])
                XCTAssertEqual(BotLifecyclePresentation.label("finish-setup"), "Finish setup")
                XCTAssertEqual(BotLifecyclePresentation.label("delete"), "Delete Bot")
            }
        }
    }

    func testStaleIssuerOffersUpdateAddressAndNeverInfersPermissionFromStatus() {
        var lifecycle = BotLifecycle(action: "readdress", status: "outcome_unknown", step: "followup_admission", message: "Update the Bot's address from http://old.invalid to https://new.invalid.", canFinishSetup: false, canReaddress: true, canDelete: false)
        XCTAssertEqual(BotLifecyclePresentation.operations(lifecycle), ["readdress"])
        XCTAssertEqual(BotLifecyclePresentation.label("readdress"), "Update address")
        XCTAssertEqual(BotLifecyclePresentation.status(lifecycle), "Result not confirmed")
        XCTAssertEqual(BotLifecyclePresentation.step(lifecycle), "Followup admission")
        lifecycle.canReaddress = false
        XCTAssertTrue(BotLifecyclePresentation.operations(lifecycle).isEmpty)
        lifecycle.status = "running"
        XCTAssertEqual(BotLifecyclePresentation.status(lifecycle), "In progress")
        XCTAssertTrue(BotLifecyclePresentation.operations(lifecycle).isEmpty)
        XCTAssertEqual(BotLifecyclePresentation.operations(nil), ["duplicate", "move", "reset", "delete"])
    }
}
