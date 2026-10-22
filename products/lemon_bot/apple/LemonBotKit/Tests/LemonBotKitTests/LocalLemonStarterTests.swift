import XCTest
@testable import LemonBotKit

private final class FakeHandoff: TerminalHandoff, @unchecked Sendable {
    struct Boom: LocalizedError { var errorDescription: String? { "token=hunter2 failed in /Users/me/x" } }
    private let lock = NSLock()
    private var _scripts: [String] = []
    let fail: Bool
    init(fail: Bool = false) { self.fail = fail }
    var scripts: [String] { lock.lock(); defer { lock.unlock() }; return _scripts }
    func open(command: String) async throws {
        lock.withLock { _scripts.append(command) }
        if fail { throw Boom() }
    }
}

private actor Counter { var n = 0; func next() -> Int { n += 1; return n } }
private actor SuspendedHealthCheck {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?
    init(started: XCTestExpectation) { self.started = started }
    func check() async -> Bool {
        started.fulfill()
        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }
    func complete(with healthy: Bool) {
        result = healthy
        continuation?.resume(returning: healthy)
        continuation = nil
    }
}

private final class States: @unchecked Sendable {
    private let lock = NSLock(); private var v: [LemonStartState] = []
    func add(_ s: LemonStartState) { lock.lock(); v.append(s); lock.unlock() }
    var all: [LemonStartState] { lock.lock(); defer { lock.unlock() }; return v }
}

final class LocalLemonStarterTests: XCTestCase {
    private func starter(_ h: FakeHandoff, checkout: String? = nil, attempts: Int = 3, healthy: @escaping @Sendable () async -> Bool = { true }) -> LocalLemonStarter {
        LocalLemonStarter(handoff: h, isHealthy: healthy, checkout: { checkout }, homeDirectory: "/Users/me", healthAttempts: attempts, healthInterval: .milliseconds(1))
    }

    func testCommandUsesAbsoluteQuotedPaths() throws {
        let script = try LemonStartCommand.command(checkout: "/Users/me/my lemon's repo", home: "/Users/me")
        XCTAssertTrue(script.contains("cd '/Users/me/my lemon'\\''s repo'"))
        XCTAssertTrue(script.contains("'/Users/me/.lemon/bin/lemon'"))
        XCTAssertTrue(script.contains("'/Users/me/.local/bin/lemon'"))
        XCTAssertTrue(script.contains("'/opt/homebrew/bin/lemon'"))
        XCTAssertTrue(script.contains("'/Users/me/bin/lemon'"))
        XCTAssertTrue(script.contains("'/usr/local/bin/lemon' '/Users/me/my lemon'\\''s repo/bin/lemon'"))
        XCTAssertTrue(script.contains("'/Users/me/.bun/bin/bun'"))
        XCTAssertTrue(script.contains("\"$lemon\" start"))
        XCTAssertTrue(script.contains("run --cwd 'products/lemon_bot/backend' start --no-open"))
        XCTAssertTrue(script.contains("pick '/Users/me/.local/bin/lemon-bot'"))
    }

    func testInstalledLemonBotIsPreferredOverCheckout() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/lemon-bot-test-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        let bot = home.appendingPathComponent(".local/bin/lemon-bot")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: bot.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A stand-in launcher that reports its arguments instead of starting a backend.
        try "#!/bin/sh\nprintf 'lemon-bot %s' \"$*\"\n".write(to: bot, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bot.path)
        let command = try LemonStartCommand.command(checkout: root.appendingPathComponent("missing-checkout").path, home: home.path)
        let process = Process(); let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "lemon-bot --no-open")
    }

    func testCommandRejectsRelativeAndControlCharacterPaths() {
        for bad in ["lemon", "~/lemon", "/a\nrm -rf /", "/a\u{0}b", ""] {
            XCTAssertThrowsError(try LemonStartCommand.command(checkout: bad, home: "/Users/me"), bad)
        }
        XCTAssertThrowsError(try LemonStartCommand.command(checkout: "/ok", home: "relative"))
    }

    func testShellQuoteNeutralizesMetacharacters() {
        XCTAssertEqual(LemonStartCommand.shellQuote("a'; rm -rf / #"), "'a'\\''; rm -rf / #'")
        XCTAssertEqual(LemonStartCommand.shellQuote("$(x) `y`"), "'$(x) `y`'")
    }

    func testRuntimeResolutionIncludesCheckoutOnlyInstallAndPrefersInstalledLauncher() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/launcher-test-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        let checkout = root.appendingPathComponent("checkout ' $(unused)")
        let installed = home.appendingPathComponent(".lemon/bin/lemon")
        let source = checkout.appendingPathComponent("bin/lemon")
        defer { try? FileManager.default.removeItem(at: root) }
        for launcher in [installed, source] {
            try FileManager.default.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
        let command = try LemonStartCommand.command(checkout: checkout.path, home: home.path)
        let lines = command.components(separatedBy: "\n")
        let pick = try XCTUnwrap(lines.first { $0.hasPrefix("pick()") })
        let resolve = try XCTUnwrap(lines.first { $0.hasPrefix("lemon=$(pick ") })
        // Mask system installations so this exercises a checkout-only machine.
        let isolatedResolve = resolve
            .replacingOccurrences(of: "'/opt/homebrew/bin/lemon'", with: LemonStartCommand.shellQuote(root.path + "/missing-homebrew"))
            .replacingOccurrences(of: "'/usr/local/bin/lemon'", with: LemonStartCommand.shellQuote(root.path + "/missing-local"))
        func selected() throws -> String {
            let process = Process(); let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", pick + "\n" + isolatedResolve + "\nprintf '%s' \"$lemon\""]
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            return String(decoding: data, as: UTF8.self)
        }
        XCTAssertEqual(try selected(), source.path)
        try FileManager.default.createSymbolicLink(at: installed, withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
        XCTAssertEqual(try selected(), installed.path)
    }

    func testCancellationBeforeStartNeverHandsOffOrChecksHealth() async {
        let h = FakeHandoff(); let counter = Counter(); let states = States()
        let s = starter(h, healthy: { _ = await counter.next(); return true })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await s.start { states.add($0) }
        }
        let result = await task.value
        let checks = await counter.n
        XCTAssertEqual(result, .failed(reason: "Start was cancelled."))
        XCTAssertEqual(states.all, [result])
        XCTAssertTrue(h.scripts.isEmpty)
        XCTAssertEqual(checks, 0)
    }

    func testCancellationDuringHealthCheckOverridesHealthyAndUnhealthyResults() async {
        for healthy in [true, false] {
            let h = FakeHandoff(); let counter = Counter(); let states = States()
            let started = expectation(description: "Health check is in flight")
            let health = SuspendedHealthCheck(started: started)
            let s = starter(h, healthy: { _ = await counter.next(); return await health.check() })
            let task = Task { await s.start { states.add($0) } }
            await fulfillment(of: [started], timeout: 5)
            task.cancel()
            await health.complete(with: healthy)
            let result = await task.value
            let checks = await counter.n
            XCTAssertEqual(result, .failed(reason: "Start was cancelled."))
            XCTAssertEqual(states.all, [.openingTerminal, .waitingForHealth(attempt: 1, of: 3), result])
            XCTAssertEqual(h.scripts.count, 1)
            XCTAssertEqual(checks, 1)
        }
    }

    func testDefaultCheckoutIsHomeLemonAndConfiguredWins() {
        XCTAssertEqual(starter(FakeHandoff()).checkoutPath(), "/Users/me/lemon")
        XCTAssertEqual(starter(FakeHandoff(), checkout: " /src/lemon ").checkoutPath(), "/src/lemon")
    }

    func testStartsOnlyAfterHealthPasses() async {
        let h = FakeHandoff(); let counter = Counter(); let states = States()
        let result = await starter(h, healthy: { await counter.next() >= 2 }).start { states.add($0) }
        XCTAssertEqual(result, .started)
        XCTAssertEqual(h.scripts.count, 1)
        XCTAssertEqual(states.all, [.openingTerminal, .waitingForHealth(attempt: 1, of: 3), .waitingForHealth(attempt: 2, of: 3), .started])
    }

    func testHealthOnFinalAttemptReportsStarted() async {
        let h = FakeHandoff(); let counter = Counter(); let states = States()
        let result = await starter(h, healthy: { await counter.next() == 3 }).start { states.add($0) }
        let checks = await counter.n
        XCTAssertEqual(result, .started)
        XCTAssertEqual(states.all, [.openingTerminal, .waitingForHealth(attempt: 1, of: 3), .waitingForHealth(attempt: 2, of: 3), .waitingForHealth(attempt: 3, of: 3), .started])
        XCTAssertEqual(h.scripts.count, 1)
        XCTAssertEqual(checks, 3)
    }

    func testTimesOutAfterAllHealthAttemptsAndNeverReportsStarted() async {
        let h = FakeHandoff(); let counter = Counter(); let states = States()
        let result = await starter(h, healthy: { _ = await counter.next(); return false }).start { states.add($0) }
        let checks = await counter.n
        guard case .failed(let reason) = result else { return XCTFail("expected failure") }
        XCTAssertTrue(reason.contains("healthy in time"))
        XCTAssertTrue(reason.contains("Paste it into Terminal and press Return"))
        XCTAssertEqual(states.all, [.openingTerminal, .waitingForHealth(attempt: 1, of: 3), .waitingForHealth(attempt: 2, of: 3), .waitingForHealth(attempt: 3, of: 3), result])
        XCTAssertEqual(h.scripts.count, 1)
        XCTAssertEqual(checks, 3)
    }

    func testNonpositiveAttemptLimitsStillCheckHealthOnce() async {
        for attempts in [0, -1] {
            let h = FakeHandoff(); let counter = Counter(); let states = States()
            let result = await starter(h, attempts: attempts, healthy: { _ = await counter.next(); return false }).start { states.add($0) }
            let checks = await counter.n
            guard case .failed = result else { return XCTFail("expected failure") }
            XCTAssertEqual(states.all, [.openingTerminal, .waitingForHealth(attempt: 1, of: 1), result])
            XCTAssertEqual(h.scripts.count, 1)
            XCTAssertEqual(checks, 1)
        }
    }

    func testHandoffFailureIsRedactedAndBoundedWithoutCheckingHealth() async {
        let h = FakeHandoff(fail: true); let counter = Counter(); let states = States()
        let result = await starter(h, healthy: { _ = await counter.next(); return true }).start { states.add($0) }
        let checks = await counter.n
        guard case .failed(let reason) = result else { return XCTFail("expected failure") }
        XCTAssertLessThanOrEqual(reason.count, LocalLemonStarter.maxReasonLength)
        XCTAssertFalse(reason.contains("hunter2")); XCTAssertFalse(reason.contains("/Users/me"))
        XCTAssertEqual(states.all, [.openingTerminal, result])
        XCTAssertEqual(h.scripts.count, 1)
        XCTAssertEqual(checks, 0)
    }

    func testBoundedTruncatesAndRedacts() {
        let s = starter(FakeHandoff())
        let out = s.bounded("Bearer abc.def sk-abcdefghijklmnop1234\n" + String(repeating: "x ", count: 500))
        XCTAssertLessThanOrEqual(out.count, LocalLemonStarter.maxReasonLength)
        XCTAssertFalse(out.contains("abc.def")); XCTAssertFalse(out.contains("sk-abcdefghijklmnop1234"))
    }

    func testInvalidCheckoutFailsWithoutHandoff() async {
        let h = FakeHandoff(); let counter = Counter(); let states = States()
        let result = await starter(h, checkout: "relative/lemon", healthy: { _ = await counter.next(); return true }).start { states.add($0) }
        let checks = await counter.n
        guard case .failed = result else { return XCTFail("expected failure") }
        XCTAssertEqual(states.all, [.openingTerminal, result])
        XCTAssertTrue(h.scripts.isEmpty)
        XCTAssertEqual(checks, 0)
    }
}
