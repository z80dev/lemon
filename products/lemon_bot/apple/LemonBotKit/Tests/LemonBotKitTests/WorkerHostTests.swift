#if os(macOS)
import XCTest
@testable import LemonBotKit

final class WorkerHostTests: XCTestCase {
    func testPermissionStatesAndLocalRoleGate() {
        XCTAssertEqual(MacPermissionState.measure(grants: ["granted", "granted"], stale: false), .allowed)
        XCTAssertEqual(MacPermissionState.measure(grants: ["granted", "denied"], stale: false), .denied)
        XCTAssertEqual(MacPermissionState.measure(grants: ["unknown"], stale: false), .unchecked)
        XCTAssertEqual(MacPermissionState.measure(grants: [], stale: false), .unchecked)
        XCTAssertEqual(MacPermissionState.measure(grants: ["granted"], stale: true), .offline)
        XCTAssertTrue(WorkerHost.canManage(nodeName: "mac", localNodeName: "mac", role: "owner"))
        XCTAssertTrue(WorkerHost.canManage(nodeName: "mac", localNodeName: "mac", role: "admin"))
        XCTAssertFalse(WorkerHost.canManage(nodeName: "remote", localNodeName: "mac", role: "owner"))
        XCTAssertFalse(WorkerHost.canManage(nodeName: "mac", localNodeName: "mac", role: "member"))
        XCTAssertFalse(WorkerHost.canManage(nodeName: "mac", localNodeName: nil, role: "owner"))
    }

    func testLocatorAndWorkerUnit() throws {
        let home = URL(fileURLWithPath: "/tmp/tcc-helper-scratch").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let app = home.appendingPathComponent("Applications/Lemon Bot.app")
        let helper = app.appendingPathComponent("Contents/Helpers/Lemon Bot Worker.app")
        let executable = helper.appendingPathComponent("Contents/MacOS/Lemon Bot Worker")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": WorkerHost.bundleIdentifier, "CFBundleExecutable": "Lemon Bot Worker", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: helper.appendingPathComponent("Contents/Info.plist"))
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        XCTAssertEqual(WorkerHost.executableURL(appBundle: app, home: home.path)?.path, executable.path)
        XCTAssertEqual(WorkerHost.appURL(appBundle: app, home: home.path)?.path, helper.path)
        XCTAssertNil(WorkerHost.executableURL(appBundle: home.appendingPathComponent("Downloads/Lemon Bot.app"), home: home.path))
        XCTAssertNil(WorkerHost.executableURL(appBundle: home.appendingPathComponent("Applications/AppTranslocation/Lemon Bot.app"), home: home.path))
        let agents = home.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let unit = agents.appendingPathComponent("org.lemon.node.local-mac.plist")
        func save(_ arguments: [String], to target: URL) throws {
            try PropertyListSerialization.data(fromPropertyList: ["ProgramArguments": arguments], format: .xml, options: 0).write(to: target)
        }
        try save([executable.path, "--", home.appendingPathComponent(".lemon/bin/lemon").path], to: unit)
        XCTAssertEqual(WorkerHost.workerUnit(home: home.path)?.nodeName, "local-mac")
        XCTAssertEqual(WorkerHost.workerUnit(home: home.path)?.wrapped, true)
        try save(["/usr/bin/env", "lemon"], to: unit)
        XCTAssertEqual(WorkerHost.workerUnit(home: home.path)?.wrapped, false)
        try save(["/usr/bin/env"], to: agents.appendingPathComponent("org.lemon.node.other.plist"))
        XCTAssertNil(WorkerHost.workerUnit(home: home.path))
    }
}
#endif
