#if DEBUG
import Foundation
import XCTest
import LemonBotKit
@testable import LemonBotUI

@MainActor
final class InstanceHealthTests: XCTestCase {
    private func status(controllerDown: Bool = false, runtimeRunning: Bool = false) throws -> InstanceStatus {
        let json = FixtureWorld.shared.instance(controllerDown: controllerDown, runtimeRunning: runtimeRunning)
        return try JSONDecoder().decode(InstanceStatus.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testHealthFixtureShowsBuildCredentialsAndChannelErrors() throws {
        let value = try status()
        var lemon = try XCTUnwrap(value.lemon)
        XCTAssertEqual(instanceBuildLine(lemon), "2026.10.15 · preview · abc1234")
        lemon.build?.channel = nil
        XCTAssertEqual(instanceBuildLine(lemon), "2026.10.15 · abc1234")
        lemon.version = nil
        lemon.build = nil
        XCTAssertEqual(instanceBuildLine(lemon), "Unavailable")
        let providers = try XCTUnwrap(value.lemon?.providers)
        XCTAssertTrue(providers[0].isDefault)
        XCTAssertEqual(providers[1].credential, .missing)
        XCTAssertNotNil(providers[1].lastError)
        XCTAssertEqual(providers[2].credential, .notRequired)
        let channels = try XCTUnwrap(value.lemon?.channels?.details)
        XCTAssertEqual(channels.map(\.state), [.connected, .error, .configured])
        XCTAssertNotNil(channels[1].lastError)
        XCTAssertEqual(instanceServiceName("openai"), "OpenAI")
        XCTAssertEqual(instanceServiceName("custom_provider"), "Custom Provider")
        XCTAssertFalse(instanceErrorAge(value.measuredAtMs - 120_000, measuredAtMs: value.measuredAtMs).isEmpty)
    }

    func testLauncherAndRemoteFixturesAdvertiseOnlyAvailableActions() throws {
        let launcher = try status()
        XCTAssertEqual(launcher.runtime.via, .launcher)
        XCTAssertEqual(launcher.runtime.actions, [.stop, .restart])
        XCTAssertTrue(try XCTUnwrap(instanceLifecycleCopy(launcher.runtime.via)).contains("service host"))
        XCTAssertTrue(instanceConfirmation(.stop, via: .launcher).contains("start it from here"))
        let remote = try status(runtimeRunning: true)
        XCTAssertEqual(remote.runtime.via, .controller)
        XCTAssertEqual(remote.runtime.actions, [.restart, .stop])
        XCTAssertNotNil(remote.runtime.reason)
        XCTAssertEqual(remote.runtime.operation?.state, .running)
        XCTAssertNil(remote.runtime.operation?.exitCode)
        XCTAssertTrue(instanceConfirmation(.stop, via: .controller).contains("cannot start Lemon remotely"))
        let down = try status(controllerDown: true)
        XCTAssertNil(down.lemon)
        XCTAssertEqual(down.runtime.via, .controller)
        XCTAssertTrue(down.runtime.actions.isEmpty)
        XCTAssertNotNil(down.runtime.reason)
        XCTAssertTrue(try XCTUnwrap(instanceLifecycleCopy(down.runtime.via)).contains("Start isn’t possible"))
    }

    func testOperationLabelsAreHumanCopy() {
        XCTAssertEqual(runtimeOperationLabel(.restart, state: .running), "Restarting Lemon…")
        XCTAssertEqual(runtimeOperationLabel(.stop, state: .succeeded), "Lemon stopped")
        XCTAssertEqual(runtimeOperationLabel(.start, state: .failed), "Lemon couldn’t start")
    }
}
#endif
