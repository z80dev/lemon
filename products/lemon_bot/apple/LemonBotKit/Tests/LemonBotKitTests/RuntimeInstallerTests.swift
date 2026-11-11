import XCTest
import Foundation
import CryptoKit
@testable import LemonBotKit

// MARK: - MockURLProtocol

final class MockURLProtocol: URLProtocol {
    static var handlers: [String: (Int, [String: String], Data)] = [:]
    static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        guard let url = request.url, let (status, headers, data) = Self.handlers[url.absoluteString] else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func reset() {
        handlers.removeAll()
        requests.removeAll()
    }
}

/// Thread-safe collector for the installer's progress callbacks.
final class StepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RuntimeInstallStep] = []

    func record(_ step: RuntimeInstallStep) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(step)
    }

    var steps: [RuntimeInstallStep] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
}

// MARK: - RuntimeInstallerTests

final class RuntimeInstallerTests: XCTestCase {
    private var tempDir: URL!
    private var layout: InstallLayout!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("RuntimeInstallerTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        layout = InstallLayout(home: tempDir)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        if let temp = tempDir {
            try? FileManager.default.removeItem(at: temp)
        }
        super.tearDown()
    }

    // MARK: - 1. ReleasePin Tests

    func testReleasePinAbsent() {
        XCTAssertNil(ReleasePin.from(infoDictionary: [:]))
        XCTAssertNil(ReleasePin.from(infoDictionary: ["LemonBotReleaseVersion": ""]))
    }

    func testReleasePinMalformedDigest() {
        let shortDigest = [
            "LemonBotReleaseVersion": "2026.11.1",
            "LemonBotRuntimeManifestSHA256": "abcdef"
        ]
        XCTAssertNil(ReleasePin.from(infoDictionary: shortDigest))

        let nonHex = [
            "LemonBotReleaseVersion": "2026.11.1",
            "LemonBotRuntimeManifestSHA256": String(repeating: "z", count: 64)
        ]
        XCTAssertNil(ReleasePin.from(infoDictionary: nonHex))
    }

    func testReleasePinHttpBase() {
        let httpBase = [
            "LemonBotReleaseVersion": "2026.11.1",
            "LemonBotRuntimeBaseURL": "http://insecure.example.com"
        ]
        XCTAssertNil(ReleasePin.from(infoDictionary: httpBase))

        let trailingSlash = [
            "LemonBotReleaseVersion": "2026.11.1",
            "LemonBotRuntimeBaseURL": "https://github.com/z80dev/lemon/"
        ]
        XCTAssertNil(ReleasePin.from(infoDictionary: trailingSlash))

        let queryBase = [
            "LemonBotReleaseVersion": "2026.11.1",
            "LemonBotRuntimeBaseURL": "https://github.com/z80dev/lemon?query=1"
        ]
        XCTAssertNil(ReleasePin.from(infoDictionary: queryBase))
    }

    func testReleasePinOK() {
        let sha = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        let dict: [String: Any] = [
            "LemonBotReleaseVersion": "2026.11.1",
            "LemonBotReleaseChannel": "preview",
            "LemonBotRuntimeManifestSHA256": sha,
            "LemonBotRuntimeBaseURL": "https://github.com/custom/lemon"
        ]
        let pin = ReleasePin.from(infoDictionary: dict)
        XCTAssertNotNil(pin)
        XCTAssertEqual(pin?.version, "2026.11.1")
        XCTAssertEqual(pin?.channel, "preview")
        XCTAssertEqual(pin?.manifestSHA256, sha)
        XCTAssertEqual(pin?.baseURL, URL(string: "https://github.com/custom/lemon")!)
        XCTAssertEqual(pin?.manifestURL.absoluteString, "https://github.com/custom/lemon/releases/download/v2026.11.1/manifest.json")
        XCTAssertEqual(pin?.installCommand(), "curl -fsSL https://github.com/custom/lemon/releases/download/v2026.11.1/install.sh | sh -s -- --profile bot")
        XCTAssertTrue(pin?.isDigestEnforced ?? false)

        // Fallback command
        XCTAssertEqual(ReleasePin.fallbackInstallCommand, "curl -fsSL https://github.com/z80dev/lemon/releases/latest/download/install.sh | sh -s -- --profile bot")
        XCTAssertEqual(ReleasePin.installCommand(for: nil), ReleasePin.fallbackInstallCommand)
        XCTAssertEqual(ReleasePin.installCommand(for: pin), pin?.installCommand())
    }

    func testStableApplicationLocation() {
        let appDir = URL(fileURLWithPath: "/Applications/Lemon Bot.app")
        XCTAssertTrue(ReleasePin.isStableApplicationLocation(bundleURL: appDir, home: "/Users/alice"))

        let userAppDir = URL(fileURLWithPath: "/Users/alice/Applications/Lemon Bot.app")
        XCTAssertTrue(ReleasePin.isStableApplicationLocation(bundleURL: userAppDir, home: "/Users/alice"))

        let translocated = URL(fileURLWithPath: "/private/var/folders/xx/AppTranslocation/d1/d/Lemon Bot.app")
        XCTAssertFalse(ReleasePin.isStableApplicationLocation(bundleURL: translocated, home: "/Users/alice"))

        let downloads = URL(fileURLWithPath: "/Users/alice/Downloads/Lemon Bot.app")
        XCTAssertFalse(ReleasePin.isStableApplicationLocation(bundleURL: downloads, home: "/Users/alice"))
    }

    // MARK: - 2. Manifest Tests

    func testManifestDigestMismatch() async {
        let manifestData = """
        {
          "schema": 2,
          "version": "2026.11.1",
          "channel": "stable",
          "artifacts": []
        }
        """.data(using: .utf8)!

        let manifestURL = "https://github.com/z80dev/lemon/releases/download/v2026.11.1/manifest.json"
        MockURLProtocol.handlers[manifestURL] = (200, ["Content-Type": "application/json"], manifestData)

        let pin = ReleasePin(
            version: "2026.11.1",
            channel: "stable",
            manifestSHA256: "0000000000000000000000000000000000000000000000000000000000000000",
            baseURL: URL(string: "https://github.com/z80dev/lemon")!
        )

        let plan = try! RuntimeInstaller.plan(layout: layout, pin: pin)
        do {
            try await RuntimeInstaller.install(plan, session: MockURLProtocol.session()) { _ in }
            XCTFail("Expected manifestMismatch error")
        } catch let error as RuntimeInstallError {
            XCTAssertEqual(error, .manifestMismatch)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testManifestSelectRules() throws {
        let artifacts: [RuntimeManifest.Artifact] = [
            .init(file: "lemon-2026.11.1-stable-darwin-arm64-lemon_bot.tar.gz", sha256: String(repeating: "a", count: 64), size: 100, platform: "darwin-arm64", profile: "lemon_bot", os: "darwin", arch: "arm64"),
            .init(file: "lemon-2026.11.1-darwin-arm64-lemon_runtime_full.tar.gz", sha256: String(repeating: "b", count: 64), size: 200, platform: "darwin-arm64", profile: "lemon_runtime_full", os: "darwin", arch: "arm64")
        ]
        let manifest = RuntimeManifest(schema: 2, version: "2026.11.1", channel: "stable", artifacts: artifacts)

        // Select exact
        let botArt = try manifest.select(profile: "lemon_bot", platform: "darwin-arm64", version: "2026.11.1", channel: "stable")
        XCTAssertEqual(botArt.file, "lemon-2026.11.1-stable-darwin-arm64-lemon_bot.tar.gz")

        // Missing profile
        XCTAssertThrowsError(try manifest.select(profile: "missing_profile", platform: "darwin-arm64")) { error in
            XCTAssertEqual(error as? RuntimeInstallError, .artifactMissing(profile: "missing_profile"))
        }

        // Version mismatch
        XCTAssertThrowsError(try manifest.select(profile: "lemon_bot", platform: "darwin-arm64", version: "2026.10.1"))

        // Channel mismatch
        XCTAssertThrowsError(try manifest.select(profile: "lemon_bot", platform: "darwin-arm64", channel: "preview"))

        // Backend name mismatch
        let badNameArt = RuntimeManifest.Artifact(file: "bad-name.tar.gz", sha256: String(repeating: "c", count: 64), size: 50, platform: "darwin-arm64", profile: "lemon_bot", os: "darwin", arch: "arm64")
        let badManifest = RuntimeManifest(schema: 2, version: "2026.11.1", channel: "stable", artifacts: [badNameArt])
        XCTAssertThrowsError(try badManifest.select(profile: "lemon_bot", platform: "darwin-arm64"))
    }

    // MARK: - 3. Downloads Tests

    func testDownloadSizeMismatch() async throws {
        let (runtimeTarball, runtimeSize, runtimeSha) = try makeFakeRuntimeTarball(baseDir: tempDir, version: "2026.11.1")
        defer { try? FileManager.default.removeItem(at: runtimeTarball) }

        let manifestJSON = """
        {
          "schema": 2,
          "version": "2026.11.1",
          "channel": "stable",
          "artifacts": [
            {
              "file": "\(runtimeTarball.lastPathComponent)",
              "sha256": "\(runtimeSha)",
              "size": \(runtimeSize + 9999),
              "platform": "darwin-arm64",
              "profile": "lemon_runtime_full",
              "os": "darwin",
              "arch": "arm64"
            }
          ]
        }
        """
        let manifestData = manifestJSON.data(using: .utf8)!
        let manifestSha = SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined()

        let base = "https://github.com/z80dev/lemon"
        MockURLProtocol.handlers["\(base)/releases/download/v2026.11.1/manifest.json"] = (200, ["Content-Type": "application/json"], manifestData)
        MockURLProtocol.handlers["\(base)/releases/download/v2026.11.1/\(runtimeTarball.lastPathComponent)"] = (200, ["Content-Type": "application/octet-stream"], try Data(contentsOf: runtimeTarball))

        let pin = ReleasePin(version: "2026.11.1", channel: "stable", manifestSHA256: manifestSha, baseURL: URL(string: base)!)
        let plan = RuntimeInstaller.Plan(
            action: .installRuntime(version: "2026.11.1", channel: "stable", digestEnforced: true),
            layout: layout,
            baseURL: pin.baseURL,
            manifestSHA256: pin.manifestSHA256
        )

        do {
            try await RuntimeInstaller.install(plan, session: MockURLProtocol.session()) { _ in }
            XCTFail("Expected checksumMismatch error")
        } catch let error as RuntimeInstallError {
            XCTAssertEqual(error, .checksumMismatch(file: runtimeTarball.lastPathComponent))
        }

        // Assert nothing was extracted
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.runtimeVersionDir(for: "2026.11.1").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.runtimeVersionDir(for: "2026.11.1").path + ".partial"))
    }

    func testDownloadShaMismatch() async throws {
        let (runtimeTarball, runtimeSize, _) = try makeFakeRuntimeTarball(baseDir: tempDir, version: "2026.11.1")
        defer { try? FileManager.default.removeItem(at: runtimeTarball) }

        let wrongSha = String(repeating: "0", count: 64)
        let manifestJSON = """
        {
          "schema": 2,
          "version": "2026.11.1",
          "channel": "stable",
          "artifacts": [
            {
              "file": "\(runtimeTarball.lastPathComponent)",
              "sha256": "\(wrongSha)",
              "size": \(runtimeSize),
              "platform": "darwin-arm64",
              "profile": "lemon_runtime_full",
              "os": "darwin",
              "arch": "arm64"
            }
          ]
        }
        """
        let manifestData = manifestJSON.data(using: .utf8)!
        let manifestSha = SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined()

        let base = "https://github.com/z80dev/lemon"
        MockURLProtocol.handlers["\(base)/releases/download/v2026.11.1/manifest.json"] = (200, ["Content-Type": "application/json"], manifestData)
        MockURLProtocol.handlers["\(base)/releases/download/v2026.11.1/\(runtimeTarball.lastPathComponent)"] = (200, ["Content-Type": "application/octet-stream"], try Data(contentsOf: runtimeTarball))

        let pin = ReleasePin(version: "2026.11.1", channel: "stable", manifestSHA256: manifestSha, baseURL: URL(string: base)!)
        let plan = RuntimeInstaller.Plan(
            action: .installRuntime(version: "2026.11.1", channel: "stable", digestEnforced: true),
            layout: layout,
            baseURL: pin.baseURL,
            manifestSHA256: pin.manifestSHA256
        )

        do {
            try await RuntimeInstaller.install(plan, session: MockURLProtocol.session()) { _ in }
            XCTFail("Expected checksumMismatch error")
        } catch let error as RuntimeInstallError {
            XCTAssertEqual(error, .checksumMismatch(file: runtimeTarball.lastPathComponent))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.runtimeVersionDir(for: "2026.11.1").path))
    }

    // MARK: - 4. Archive Tests

    func testArchiveRuntimeSymlink() async throws {
        let (runtimeTarball, runtimeSize, runtimeSha) = try makeFakeRuntimeTarball(baseDir: tempDir, version: "2026.11.1", includeSymlink: true)
        defer { try? FileManager.default.removeItem(at: runtimeTarball) }

        let manifestJSON = """
        {
          "schema": 2,
          "version": "2026.11.1",
          "channel": "stable",
          "artifacts": [
            {
              "file": "\(runtimeTarball.lastPathComponent)",
              "sha256": "\(runtimeSha)",
              "size": \(runtimeSize),
              "platform": "darwin-arm64",
              "profile": "lemon_runtime_full",
              "os": "darwin",
              "arch": "arm64"
            }
          ]
        }
        """
        let manifestData = manifestJSON.data(using: .utf8)!
        let manifestSha = SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined()

        let base = "https://github.com/z80dev/lemon"
        MockURLProtocol.handlers["\(base)/releases/download/v2026.11.1/manifest.json"] = (200, ["Content-Type": "application/json"], manifestData)
        MockURLProtocol.handlers["\(base)/releases/download/v2026.11.1/\(runtimeTarball.lastPathComponent)"] = (200, ["Content-Type": "application/octet-stream"], try Data(contentsOf: runtimeTarball))

        let pin = ReleasePin(version: "2026.11.1", channel: "stable", manifestSHA256: manifestSha, baseURL: URL(string: base)!)
        let plan = RuntimeInstaller.Plan(
            action: .installRuntime(version: "2026.11.1", channel: "stable", digestEnforced: true),
            layout: layout,
            baseURL: pin.baseURL,
            manifestSHA256: pin.manifestSHA256
        )

        do {
            try await RuntimeInstaller.install(plan, session: MockURLProtocol.session()) { _ in }
            XCTFail("Expected unsafeArchive error for symlink in runtime")
        } catch let error as RuntimeInstallError {
            switch error {
            case .unsafeArchive(let file, let detail):
                XCTAssertEqual(file, runtimeTarball.lastPathComponent)
                XCTAssertTrue(detail.contains("symlink"))
            default:
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testArchiveBackendSymlinkEscapingBot() async throws {
        let (backendTarball, backendSize, backendSha) = try makeFakeBackendTarball(baseDir: tempDir, version: "2026.11.1", symlinkEscaping: true)
        defer { try? FileManager.default.removeItem(at: backendTarball) }

        let fileName = "lemon-2026.11.1-stable-darwin-arm64-lemon_bot.tar.gz"
        let manifestJSON = """
        {
          "schema": 2,
          "version": "2026.11.1",
          "channel": "stable",
          "artifacts": [
            {
              "file": "\(fileName)",
              "sha256": "\(backendSha)",
              "size": \(backendSize),
              "platform": "darwin-arm64",
              "profile": "lemon_bot",
              "os": "darwin",
              "arch": "arm64"
            }
          ]
        }
        """
        let manifestData = manifestJSON.data(using: .utf8)!
        let manifestSha = SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined()

        let base = "https://github.com/z80dev/lemon"
        MockURLProtocol.handlers["\(base)/releases/download/v2026.11.1/manifest.json"] = (200, ["Content-Type": "application/json"], manifestData)
        MockURLProtocol.handlers["\(base)/releases/download/v2026.11.1/\(fileName)"] = (200, ["Content-Type": "application/octet-stream"], try Data(contentsOf: backendTarball))

        let pin = ReleasePin(version: "2026.11.1", channel: "stable", manifestSHA256: manifestSha, baseURL: URL(string: base)!)
        let plan = RuntimeInstaller.Plan(
            action: .installBackend(version: "2026.11.1", channel: "stable", digestEnforced: true),
            layout: layout,
            baseURL: pin.baseURL,
            manifestSHA256: pin.manifestSHA256
        )

        do {
            try await RuntimeInstaller.install(plan, session: MockURLProtocol.session()) { _ in }
            XCTFail("Expected unsafeArchive error for escaping symlink")
        } catch let error as RuntimeInstallError {
            switch error {
            case .unsafeArchive(let file, let detail):
                XCTAssertEqual(file, fileName)
                XCTAssertTrue(detail.contains("escapes bot directory"))
            default:
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testArchiveUnexpectedTopLevel() async throws {
        // Runtime tarball with bot/ top level
        let (runtimeTarball, runtimeSize, runtimeSha) = try makeFakeRuntimeTarball(baseDir: tempDir, version: "2026.11.1", includeBotDir: true)
        defer { try? FileManager.default.removeItem(at: runtimeTarball) }

        let manifestJSON = """
        {
          "schema": 2,
          "version": "2026.11.1",
          "channel": "stable",
          "artifacts": [
            {
              "file": "\(runtimeTarball.lastPathComponent)",
              "sha256": "\(runtimeSha)",
              "size": \(runtimeSize),
              "platform": "darwin-arm64",
              "profile": "lemon_runtime_full",
              "os": "darwin",
              "arch": "arm64"
            }
          ]
        }
        """
        let manifestData = manifestJSON.data(using: .utf8)!
        let manifestSha = SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined()

        let base = "https://github.com/z80dev/lemon"
        MockURLProtocol.handlers["\(base)/releases/download/v2026.11.1/manifest.json"] = (200, ["Content-Type": "application/json"], manifestData)
        MockURLProtocol.handlers["\(base)/releases/download/v2026.11.1/\(runtimeTarball.lastPathComponent)"] = (200, ["Content-Type": "application/octet-stream"], try Data(contentsOf: runtimeTarball))

        let pin = ReleasePin(version: "2026.11.1", channel: "stable", manifestSHA256: manifestSha, baseURL: URL(string: base)!)
        let plan = RuntimeInstaller.Plan(
            action: .installRuntime(version: "2026.11.1", channel: "stable", digestEnforced: true),
            layout: layout,
            baseURL: pin.baseURL,
            manifestSHA256: pin.manifestSHA256
        )

        do {
            try await RuntimeInstaller.install(plan, session: MockURLProtocol.session()) { _ in }
            XCTFail("Expected unsafeArchive error for unexpected top level in runtime")
        } catch let error as RuntimeInstallError {
            switch error {
            case .unsafeArchive(_, let detail):
                XCTAssertTrue(detail.contains("bot/"))
            default:
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    // MARK: - 5. Verification Tests

    func testVerificationFailingRequireBot() async throws {
        let (runtimeTarball, runtimeSize, runtimeSha) = try makeFakeRuntimeTarball(baseDir: tempDir, version: "2026.11.1", failCapabilities: true)
        defer { try? FileManager.default.removeItem(at: runtimeTarball) }

        let manifestJSON = """
        {
          "schema": 2,
          "version": "2026.11.1",
          "channel": "stable",
          "artifacts": [
            {
              "file": "\(runtimeTarball.lastPathComponent)",
              "sha256": "\(runtimeSha)",
              "size": \(runtimeSize),
              "platform": "darwin-arm64",
              "profile": "lemon_runtime_full",
              "os": "darwin",
              "arch": "arm64"
            }
          ]
        }
        """
        let manifestData = manifestJSON.data(using: .utf8)!
        let manifestSha = SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined()

        let base = "https://github.com/z80dev/lemon"
        MockURLProtocol.handlers["\(base)/releases/download/v2026.11.1/manifest.json"] = (200, ["Content-Type": "application/json"], manifestData)
        MockURLProtocol.handlers["\(base)/releases/download/v2026.11.1/\(runtimeTarball.lastPathComponent)"] = (200, ["Content-Type": "application/octet-stream"], try Data(contentsOf: runtimeTarball))

        let pin = ReleasePin(version: "2026.11.1", channel: "stable", manifestSHA256: manifestSha, baseURL: URL(string: base)!)
        let plan = RuntimeInstaller.Plan(
            action: .installRuntime(version: "2026.11.1", channel: "stable", digestEnforced: true),
            layout: layout,
            baseURL: pin.baseURL,
            manifestSHA256: pin.manifestSHA256
        )

        do {
            try await RuntimeInstaller.install(plan, session: MockURLProtocol.session()) { _ in }
            XCTFail("Expected verificationFailed error")
        } catch let error as RuntimeInstallError {
            switch error {
            case .verificationFailed(let component, let detail):
                XCTAssertEqual(component, "runtime")
                XCTAssertTrue(detail.contains("capabilities"))
            default:
                XCTFail("Unexpected error: \(error)")
            }
        }

        // Clean up check: no .partial, no target directory
        let targetDir = layout.runtimeVersionDir(for: "2026.11.1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetDir.path + ".partial"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.runtimeCurrentLink.path))
    }

    // MARK: - 6. Plan Table Tests (All 5 Rows)

    func testPlanTableAllFiveRows() throws {
        let pin = ReleasePin(
            version: "2026.11.1",
            channel: "stable",
            manifestSHA256: String(repeating: "1", count: 64),
            baseURL: URL(string: "https://github.com/z80dev/lemon")!
        )
        let fm = FileManager.default

        // Row 1: none | none -> install both at V (digest-enforced)
        let plan1 = try RuntimeInstaller.plan(layout: layout, pin: pin)
        XCTAssertEqual(plan1.action, .installBoth(version: "2026.11.1", channel: "stable", digestEnforced: true))
        XCTAssertTrue(plan1.isDigestEnforced)

        // Digest required for new install:
        let pinNoDigest = ReleasePin(version: "2026.11.1", channel: "stable", manifestSHA256: nil, baseURL: pin.baseURL)
        XCTAssertThrowsError(try RuntimeInstaller.plan(layout: layout, pin: pinNoDigest)) { error in
            XCTAssertEqual(error as? RuntimeInstallError, .manifestMissingDigest)
        }

        // Set up runtime = 2026.11.1
        try fm.createDirectory(at: layout.runtimeVersionsDir, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: layout.runtimeCurrentLink.path, withDestinationPath: "2026.11.1")

        // Row 2: =V | none -> install backend V (digest-enforced)
        let plan2 = try RuntimeInstaller.plan(layout: layout, pin: pin)
        XCTAssertEqual(plan2.action, .installBackend(version: "2026.11.1", channel: "stable", digestEnforced: true))

        // Set up backend = 2026.11.1, remove runtime
        try fm.removeItem(at: layout.runtimeCurrentLink)
        try fm.createDirectory(at: layout.backendVersionsDir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: layout.backendCurrentLink.path, withDestinationPath: "versions/2026.11.1-stable-darwin-arm64")

        // Row 3: none | =V -> install runtime V (digest-enforced)
        let plan3 = try RuntimeInstaller.plan(layout: layout, pin: pin)
        XCTAssertEqual(plan3.action, .installRuntime(version: "2026.11.1", channel: "stable", digestEnforced: true))

        // Row 4a: runtime = W (2026.10.25) | backend = none
        try fm.removeItem(at: layout.backendCurrentLink)
        try fm.createSymbolicLink(atPath: layout.runtimeCurrentLink.path, withDestinationPath: "2026.10.25")
        let plan4a = try RuntimeInstaller.plan(layout: layout, pin: pin)
        XCTAssertEqual(plan4a.action, .installBackend(version: "2026.10.25", channel: "stable", digestEnforced: false))
        XCTAssertFalse(plan4a.isDigestEnforced)

        // Row 4b: runtime = none | backend = W (2026.10.25)
        try fm.removeItem(at: layout.runtimeCurrentLink)
        try fm.createSymbolicLink(atPath: layout.backendCurrentLink.path, withDestinationPath: "versions/2026.10.25-stable-darwin-arm64")
        let plan4b = try RuntimeInstaller.plan(layout: layout, pin: pin)
        XCTAssertEqual(plan4b.action, .installRuntime(version: "2026.10.25", channel: "stable", digestEnforced: false))
        XCTAssertFalse(plan4b.isDigestEnforced)

        // Row 5: both present -> ready
        try fm.createSymbolicLink(atPath: layout.runtimeCurrentLink.path, withDestinationPath: "2026.11.1")
        let plan5 = try RuntimeInstaller.plan(layout: layout, pin: pin)
        XCTAssertEqual(plan5.action, .ready)
        XCTAssertTrue(plan5.isReady)
    }

    // MARK: - 7. Exact Link Targets Tests

    func testExactLinkTargetsEqualInstallScript() {
        let version = "2026.11.1"
        let channel = "stable"
        let platform = "darwin-arm64"
        let key = layout.backendKey(version: version, channel: channel, platform: platform)

        // Runtime current link target (relative version string, install.sh:1051)
        XCTAssertEqual(layout.runtimeCurrentTarget(version: version), "2026.11.1")

        // Runtime launcher target (relative to ~/.lemon/bin/lemon, install.sh:582)
        XCTAssertEqual(layout.runtimeLemonTarget, "../versions/current/bin/lemon")

        // Backend current link target (relative versions/<key>, install.sh:1049)
        XCTAssertEqual(layout.backendCurrentTarget(key: key), "versions/2026.11.1-stable-darwin-arm64")

        // Backend launcher target (absolute path, install.sh:590)
        let expectedBackendTarget = layout.home.path + "/.lemon/lemon_bot/current/bot/bin/lemon-bot"
        XCTAssertEqual(layout.backendLemonBotTarget, expectedBackendTarget)
    }

    // MARK: - 8. Lock Tests

    func testExistingLockReturnsLocked() async throws {
        try FileManager.default.createDirectory(at: layout.updatesDir, withIntermediateDirectories: true)
        let lockContent = "foreign-lock-v1\n"
        try lockContent.write(to: layout.lockFile, atomically: true, encoding: .utf8)

        let pin = ReleasePin(
            version: "2026.11.1",
            channel: "stable",
            manifestSHA256: String(repeating: "1", count: 64),
            baseURL: URL(string: "https://github.com/z80dev/lemon")!
        )
        let plan = RuntimeInstaller.Plan(
            action: .installBoth(version: "2026.11.1", channel: "stable", digestEnforced: true),
            layout: layout,
            baseURL: pin.baseURL,
            manifestSHA256: pin.manifestSHA256
        )

        do {
            try await RuntimeInstaller.install(plan, session: MockURLProtocol.session()) { _ in }
            XCTFail("Expected .locked error")
        } catch let error as RuntimeInstallError {
            XCTAssertEqual(error, .locked)
        }

        // Lock file must NOT be deleted or overwritten
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.lockFile.path))
        let remainingContent = try String(contentsOf: layout.lockFile, encoding: .utf8)
        XCTAssertEqual(remainingContent, lockContent)
    }

    // MARK: - 9. Successful End-to-End Install Test

    func testSuccessfulEndToEndInstall() async throws {
        let (runtimeTarball, runtimeSize, runtimeSha) = try makeFakeRuntimeTarball(baseDir: tempDir, version: "2026.11.1")
        defer { try? FileManager.default.removeItem(at: runtimeTarball) }

        let (backendTarball, backendSize, backendSha) = try makeFakeBackendTarball(baseDir: tempDir, version: "2026.11.1")
        defer { try? FileManager.default.removeItem(at: backendTarball) }

        let backendFileName = "lemon-2026.11.1-stable-darwin-arm64-lemon_bot.tar.gz"
        let manifestJSON = """
        {
          "schema": 2,
          "version": "2026.11.1",
          "channel": "stable",
          "artifacts": [
            {
              "file": "\(runtimeTarball.lastPathComponent)",
              "sha256": "\(runtimeSha)",
              "size": \(runtimeSize),
              "platform": "darwin-arm64",
              "profile": "lemon_runtime_full",
              "os": "darwin",
              "arch": "arm64"
            },
            {
              "file": "\(backendFileName)",
              "sha256": "\(backendSha)",
              "size": \(backendSize),
              "platform": "darwin-arm64",
              "profile": "lemon_bot",
              "os": "darwin",
              "arch": "arm64"
            }
          ]
        }
        """
        let manifestData = manifestJSON.data(using: .utf8)!
        let manifestSha = SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined()

        let base = "https://github.com/z80dev/lemon"
        MockURLProtocol.handlers["\(base)/releases/download/v2026.11.1/manifest.json"] = (200, ["Content-Type": "application/json"], manifestData)
        MockURLProtocol.handlers["\(base)/releases/download/v2026.11.1/\(runtimeTarball.lastPathComponent)"] = (200, ["Content-Type": "application/octet-stream"], try Data(contentsOf: runtimeTarball))
        MockURLProtocol.handlers["\(base)/releases/download/v2026.11.1/\(backendFileName)"] = (200, ["Content-Type": "application/octet-stream"], try Data(contentsOf: backendTarball))

        let pin = ReleasePin(version: "2026.11.1", channel: "stable", manifestSHA256: manifestSha, baseURL: URL(string: base)!)
        let plan = try RuntimeInstaller.plan(layout: layout, pin: pin)

        let recorder = StepRecorder()
        try await RuntimeInstaller.install(plan, session: MockURLProtocol.session()) { step in
            recorder.record(step)
        }

        // Verify progress step progression
        let steps = recorder.steps
        XCTAssertTrue(steps.contains { if case .download = $0 { return true } else { return false } })
        XCTAssertTrue(steps.contains(.verify))
        XCTAssertTrue(steps.contains(.install))

        // Verify directories and symlinks
        let fm = FileManager.default
        let runtimeTarget = layout.runtimeVersionDir(for: "2026.11.1")
        XCTAssertTrue(fm.fileExists(atPath: runtimeTarget.path))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: layout.runtimeCurrentLink.path), "2026.11.1")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: layout.runtimeLemonLink.path), "../versions/current/bin/lemon")

        let backendKey = layout.backendKey(version: "2026.11.1", channel: "stable", platform: "darwin-arm64")
        let backendTarget = layout.backendVersionDir(key: backendKey)
        XCTAssertTrue(fm.fileExists(atPath: backendTarget.path))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: layout.backendCurrentLink.path), "versions/\(backendKey)")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: layout.backendLemonBotLink.path), layout.backendLemonBotTarget)

        // Lock removed
        XCTAssertFalse(fm.fileExists(atPath: layout.lockFile.path))

        // Subsequent plan should now be .ready
        let nextPlan = try RuntimeInstaller.plan(layout: layout, pin: pin)
        XCTAssertEqual(nextPlan.action, .ready)
    }

    // MARK: - Helper Tarball Creation

    private func makeTarball(stagingDir: URL, tarballName: String, relativePaths: [String]? = nil) throws -> (url: URL, size: Int64, sha256: String) {
        let tmpDir = stagingDir.deletingLastPathComponent()
        let tarballURL = tmpDir.appendingPathComponent(tarballName)
        try? FileManager.default.removeItem(at: tarballURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        var args = ["-czf", tarballURL.path, "-C", stagingDir.path]
        if let rels = relativePaths {
            args.append(contentsOf: rels)
        } else {
            args.append(".")
        }
        process.arguments = args
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "TarError", code: Int(process.terminationStatus))
        }

        let data = try Data(contentsOf: tarballURL)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (tarballURL, Int64(data.count), sha)
    }

    private func makeFakeRuntimeTarball(
        baseDir: URL,
        version: String,
        failCapabilities: Bool = false,
        includeSymlink: Bool = false,
        includeBotDir: Bool = false
    ) throws -> (url: URL, size: Int64, sha256: String) {
        let staging = baseDir.appendingPathComponent("runtime_staging_\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: staging.appendingPathComponent("bin"), withIntermediateDirectories: true)

        let lemonScript = """
        #!/bin/sh
        if [ "$1" = "node" ] && [ "$2" = "capabilities" ]; then
            if [ "\(failCapabilities ? "1" : "0")" = "1" ]; then
                echo "error: capability probe failed" >&2
                exit 1
            fi
            echo '{"botReady": true}'
            exit 0
        elif [ "$1" = "version" ]; then
            echo "lemon \(version)"
            exit 0
        fi
        exit 0
        """
        let scriptURL = staging.appendingPathComponent("bin/lemon")
        try lemonScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        if includeSymlink {
            let symURL = staging.appendingPathComponent("forbidden_symlink")
            try fm.createSymbolicLink(at: symURL, withDestinationURL: scriptURL)
        }

        if includeBotDir {
            try fm.createDirectory(at: staging.appendingPathComponent("bot"), withIntermediateDirectories: true)
            try "fake".write(to: staging.appendingPathComponent("bot/fake.txt"), atomically: true, encoding: .utf8)
        }

        return try makeTarball(stagingDir: staging, tarballName: "lemon-\(version)-darwin-arm64-lemon_runtime_full.tar.gz")
    }

    private func makeFakeBackendTarball(
        baseDir: URL,
        version: String,
        symlinkEscaping: Bool = false
    ) throws -> (url: URL, size: Int64, sha256: String) {
        let staging = baseDir.appendingPathComponent("backend_staging_\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: staging.appendingPathComponent("bot/bin"), withIntermediateDirectories: true)

        let botScript = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
            echo "lemon-bot \(version)"
            exit 0
        fi
        exit 0
        """
        let scriptURL = staging.appendingPathComponent("bot/bin/lemon-bot")
        try botScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let webDir = staging.appendingPathComponent("bot/web")
        try fm.createDirectory(at: webDir, withIntermediateDirectories: true)
        try "<html></html>".write(to: webDir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

        let sharpDir = staging.appendingPathComponent("bot/node_modules/@img/sharp-darwin-arm64/lib")
        let sharpVipsDir = staging.appendingPathComponent("bot/node_modules/@img/sharp-libvips-darwin-arm64")
        try fm.createDirectory(at: sharpDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: sharpVipsDir, withIntermediateDirectories: true)
        try "{}".write(to: staging.appendingPathComponent("bot/node_modules/@img/sharp-darwin-arm64/package.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: sharpVipsDir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "addon".write(to: sharpDir.appendingPathComponent("sharp-darwin-arm64.node"), atomically: true, encoding: .utf8)

        if symlinkEscaping {
            let escapeLink = staging.appendingPathComponent("bot/escape_link")
            try fm.createSymbolicLink(atPath: escapeLink.path, withDestinationPath: "../../etc/passwd")
        }

        return try makeTarball(stagingDir: staging, tarballName: "lemon-\(version)-stable-darwin-arm64-lemon_bot.tar.gz", relativePaths: ["bot"])
    }
}
