import Foundation
import XCTest

final class WorkerHostArgumentsTests: XCTestCase {
    private var fixture: URL!
    private var home: URL!
    private var program: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixture = FileManager.default.temporaryDirectory.appendingPathComponent("worker-host-arguments-\(UUID().uuidString)")
        home = fixture.appendingPathComponent("home")
        program = home.appendingPathComponent(".lemon/bin/lemon")
        try FileManager.default.createDirectory(at: program.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: program)
    }

    override func tearDownWithError() throws {
        defer {
            fixture = nil
            home = nil
            program = nil
        }
        if let fixture {
            try FileManager.default.removeItem(at: fixture)
        }
        try super.tearDownWithError()
    }

    func testExecResolvesProgramAndPreservesTargetArguments() throws {
        let argv = [program.path, "node", "start", "--name", "My Mac", "", "--status", "--json"]
        XCTAssertEqual(
            try Arguments.parse(["--"] + argv, home: home.path),
            .exec(program: program.resolvingSymlinksInPath().path, argv: argv)
        )
    }

    func testExecAllowsSymlinkToProgramInsideLemon() throws {
        let link = home.appendingPathComponent(".lemon/bin/worker")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: program)
        XCTAssertEqual(
            try Arguments.parse(["--", link.path, "node"], home: home.path),
            .exec(program: program.resolvingSymlinksInPath().path, argv: [link.path, "node"])
        )
    }

    func testExecRejectsRelativeMissingAndOutsidePrograms() throws {
        let outside = home.appendingPathComponent("outside")
        let adjacent = home.appendingPathComponent(".lemon-other/worker")
        try Data().write(to: outside)
        try FileManager.default.createDirectory(at: adjacent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: adjacent)

        for path in [
            "lemon", ".lemon/bin/lemon", "~/.lemon/bin/lemon", "",
            home.appendingPathComponent(".lemon/bin/missing").path,
            outside.path, adjacent.path,
            home.appendingPathComponent(".lemon/bin/../../outside").path,
            home.appendingPathComponent(".lemon").path,
            program.path + "\0/outside"
        ] {
            assertUsage(["--", path])
        }
    }

    func testExecRejectsSymlinkEscapingLemon() throws {
        let outside = home.appendingPathComponent("outside")
        let link = home.appendingPathComponent(".lemon/bin/escape")
        try Data().write(to: outside)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        assertUsage(["--", link.path])
    }

    func testExecResolvesHomeSymlinks() throws {
        let homeLink = fixture.appendingPathComponent("home-link")
        try FileManager.default.createSymbolicLink(at: homeLink, withDestinationURL: home)
        let alias = homeLink.appendingPathComponent(".lemon/bin/lemon").path
        XCTAssertEqual(
            try Arguments.parse(["--", alias], home: homeLink.path),
            .exec(program: program.resolvingSymlinksInPath().path, argv: [alias])
        )
    }

    func testStatusRequiresExactNonPromptingForm() throws {
        XCTAssertEqual(try Arguments.parse(["--status", "--json"], home: home.path), .status)
        for argv in [["--status"], ["--json"], ["--json", "--status"], ["--status", "--json", "extra"]] {
            assertUsage(argv)
        }
    }

    func testRequestsAcceptOnlySupportedServices() throws {
        XCTAssertEqual(try Arguments.parse(["--request", "screen-recording"], home: home.path), .request(.screenRecording))
        XCTAssertEqual(try Arguments.parse(["--request", "accessibility"], home: home.path), .request(.accessibility))
        for argv in [
            ["--request"], ["--request", "full-disk-access"], ["--request", "screenRecording"],
            ["--request", "accessibility", "--json"], ["--request", ""], ["--request", "listen-event"]
        ] {
            assertUsage(argv)
        }
    }

    func testUnknownAndMissingFormsAreUsageErrors() {
        for argv in [[], ["--"], ["--unknown"], [program.path], ["--exec", program.path], ["--help"]] {
            assertUsage(argv)
        }
    }

    private func assertUsage(_ argv: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try Arguments.parse(argv, home: home.path), file: file, line: line) { error in
            guard case Arguments.ParseError.usage = error else {
                return XCTFail("Expected a usage error", file: file, line: line)
            }
        }
    }
}
