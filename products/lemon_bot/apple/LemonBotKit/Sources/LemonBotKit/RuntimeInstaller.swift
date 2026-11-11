import Foundation
import CryptoKit
#if os(macOS)
import Darwin
#endif

// MARK: - ReleasePin

/// Pure description of the pinned release embedded in the Mac app.
public struct ReleasePin: Equatable, Sendable {
    public let version: String
    public let channel: String
    public let manifestSHA256: String?
    public let baseURL: URL

    public init(
        version: String,
        channel: String = "stable",
        manifestSHA256: String? = nil,
        baseURL: URL = URL(string: "https://github.com/z80dev/lemon")!
    ) {
        self.version = version
        self.channel = channel
        self.manifestSHA256 = manifestSHA256
        self.baseURL = baseURL
    }

    /// Parses a release pin from an Info.plist dictionary.
    ///
    /// Requires `LemonBotReleaseVersion`. Rejects non-https base URLs, URLs with query, fragment,
    /// or trailing slash, and non-64-hex SHA-256 digests.
    public static func from(infoDictionary: [String: Any]) -> ReleasePin? {
        guard let version = infoDictionary["LemonBotReleaseVersion"] as? String,
              !version.isEmpty,
              version.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil else {
            return nil
        }

        let channel: String
        if let rawChannel = infoDictionary["LemonBotReleaseChannel"] as? String, !rawChannel.isEmpty {
            guard rawChannel.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil else {
                return nil
            }
            channel = rawChannel
        } else {
            channel = "stable"
        }

        let baseURL: URL
        if let rawBaseURL = infoDictionary["LemonBotRuntimeBaseURL"] as? String, !rawBaseURL.isEmpty {
            guard let parsed = URL(string: rawBaseURL),
                  parsed.scheme == "https",
                  parsed.host != nil,
                  parsed.query == nil,
                  parsed.fragment == nil,
                  !rawBaseURL.hasSuffix("/") else {
                return nil
            }
            baseURL = parsed
        } else {
            baseURL = URL(string: "https://github.com/z80dev/lemon")!
        }

        let manifestSHA256: String?
        if let rawSHA = infoDictionary["LemonBotRuntimeManifestSHA256"] as? String, !rawSHA.isEmpty {
            guard rawSHA.count == 64,
                  rawSHA.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil else {
                return nil
            }
            manifestSHA256 = rawSHA.lowercased()
        } else {
            manifestSHA256 = nil
        }

        return ReleasePin(
            version: version,
            channel: channel,
            manifestSHA256: manifestSHA256,
            baseURL: baseURL
        )
    }

    /// The pinned release for the current running bundle, if configured.
    public static var current: ReleasePin? {
        Bundle.main.infoDictionary.flatMap { from(infoDictionary: $0) }
    }

    /// URL to the pinned release manifest.
    public var manifestURL: URL {
        baseURL.appendingPathComponent("releases/download/v\(version)/manifest.json")
    }

    /// Pinned install hint command for Terminal.
    public func installCommand() -> String {
        "curl -fsSL \(baseURL.absoluteString)/releases/download/v\(version)/install.sh | sh -s -- --profile bot"
    }

    /// Fallback unpinned install hint command when no pin is embedded.
    public static let fallbackInstallCommand: String =
        "curl -fsSL https://github.com/z80dev/lemon/releases/latest/download/install.sh | sh -s -- --profile bot"

    /// Resolved install command for an optional pin.
    public static func installCommand(for pin: ReleasePin?) -> String {
        pin?.installCommand() ?? fallbackInstallCommand
    }

    /// Whether this pin contains a verified manifest digest.
    public var isDigestEnforced: Bool {
        manifestSHA256 != nil
    }

    /// Checks whether the application bundle is located in a stable, non-translocated location.
    public static func isStableApplicationLocation(
        bundleURL: URL = Bundle.main.bundleURL,
        home: String = NSHomeDirectory()
    ) -> Bool {
        let path = bundleURL.standardizedFileURL.path
        guard !path.contains("/AppTranslocation/") else { return false }
        return path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
    }
}

// MARK: - RuntimeManifest

/// Release manifest subset conforming to schema 2.
public struct RuntimeManifest: Decodable, Sendable {
    public let schema: Int
    public let version: String
    public let channel: String
    public let artifacts: [Artifact]

    public struct Artifact: Decodable, Sendable {
        public let file: String
        public let sha256: String
        public let size: Int64
        public let platform: String?
        public let profile: String?
        public let os: String?
        public let arch: String?

        public init(
            file: String,
            sha256: String,
            size: Int64,
            platform: String? = nil,
            profile: String? = nil,
            os: String? = nil,
            arch: String? = nil
        ) {
            self.file = file
            self.sha256 = sha256
            self.size = size
            self.platform = platform
            self.profile = profile
            self.os = os
            self.arch = arch
        }
    }

    public init(
        schema: Int = 2,
        version: String,
        channel: String,
        artifacts: [Artifact]
    ) {
        self.schema = schema
        self.version = version
        self.channel = channel
        self.artifacts = artifacts
    }

    /// Selects an artifact matching the requested profile, platform, version, and channel.
    ///
    /// Follows the exact selection rules of `install.sh:302-413`.
    public func select(
        profile: String,
        platform: String,
        version wantVersion: String? = nil,
        channel wantChannel: String? = nil
    ) throws -> Artifact {
        guard schema == 2 else {
            throw RuntimeInstallError.manifestUnavailable(detail: "unsupported release manifest schema \(schema); expected 2")
        }
        guard version.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil else {
            throw RuntimeInstallError.manifestUnavailable(detail: "release manifest has no safe version")
        }
        guard channel.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil else {
            throw RuntimeInstallError.manifestUnavailable(detail: "release manifest has no safe channel")
        }
        if let wantVersion = wantVersion, wantVersion != version {
            throw RuntimeInstallError.manifestUnavailable(detail: "requested version \(wantVersion) but the manifest publishes \(version)")
        }
        if let wantChannel = wantChannel, wantChannel != channel {
            throw RuntimeInstallError.manifestUnavailable(detail: "requested channel \(wantChannel) but the manifest publishes \(channel)")
        }

        let matches = artifacts.filter { $0.platform == platform && $0.profile == profile }
        guard !matches.isEmpty else {
            throw RuntimeInstallError.artifactMissing(profile: profile)
        }
        guard matches.count == 1 else {
            throw RuntimeInstallError.manifestUnavailable(detail: "release manifest has \(matches.count) entries for \(profile)/\(platform)")
        }
        let artifact = matches[0]

        guard artifact.file.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil else {
            throw RuntimeInstallError.manifestUnavailable(detail: "artifact file must be a safe bare filename: \(artifact.file)")
        }
        guard artifact.sha256.count == 64,
              artifact.sha256.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil else {
            throw RuntimeInstallError.manifestUnavailable(detail: "artifact \(artifact.file) has no hexadecimal sha256")
        }
        guard artifact.size > 0 else {
            throw RuntimeInstallError.manifestUnavailable(detail: "artifact \(artifact.file) has no positive size")
        }

        if profile == "lemon_bot" {
            let expected = "lemon-\(version)-\(channel)-\(platform)-lemon_bot.tar.gz"
            guard artifact.file == expected else {
                throw RuntimeInstallError.manifestUnavailable(detail: "backend artifact must be named \(expected)")
            }
            let parts = platform.split(separator: "-", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                if let artOS = artifact.os, artOS != parts[0] {
                    throw RuntimeInstallError.manifestUnavailable(detail: "backend artifact OS does not match platform")
                }
                if let artArch = artifact.arch, artArch != parts[1] {
                    throw RuntimeInstallError.manifestUnavailable(detail: "backend artifact architecture does not match platform")
                }
            }
        }

        return artifact
    }
}

// MARK: - InstallLayout

/// File system layout matching `install.sh` and InvLifecycle D10 conventions.
public struct InstallLayout: Equatable, Sendable {
    public let home: URL

    public init(home: URL) {
        self.home = home.standardizedFileURL
    }

    public init() {
        self.init(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    // Runtime layout
    public var runtimeVersionsDir: URL {
        home.appendingPathComponent(".lemon/versions", isDirectory: true)
    }

    public func runtimeVersionDir(for version: String) -> URL {
        runtimeVersionsDir.appendingPathComponent(version, isDirectory: true)
    }

    public var runtimeCurrentLink: URL {
        runtimeVersionsDir.appendingPathComponent("current", isDirectory: false)
    }

    public var runtimeBinDir: URL {
        home.appendingPathComponent(".lemon/bin", isDirectory: true)
    }

    public var runtimeLemonLink: URL {
        runtimeBinDir.appendingPathComponent("lemon", isDirectory: false)
    }

    public var runtimeRunDir: URL {
        home.appendingPathComponent(".lemon/run", isDirectory: true)
    }

    public var runtimeStoreDir: URL {
        home.appendingPathComponent(".lemon/store", isDirectory: true)
    }

    public var runtimeTmpDir: URL {
        home.appendingPathComponent(".lemon/tmp", isDirectory: true)
    }

    // Backend layout
    public var backendVersionsDir: URL {
        home.appendingPathComponent(".lemon/lemon_bot/versions", isDirectory: true)
    }

    public func backendKey(version: String, channel: String, platform: String = "darwin-arm64") -> String {
        "\(version)-\(channel)-\(platform)"
    }

    public func backendVersionDir(key: String) -> URL {
        backendVersionsDir.appendingPathComponent(key, isDirectory: true)
    }

    public var backendCurrentLink: URL {
        home.appendingPathComponent(".lemon/lemon_bot/current", isDirectory: false)
    }

    public var backendLocalBinDir: URL {
        home.appendingPathComponent(".local/bin", isDirectory: true)
    }

    public var backendLemonBotLink: URL {
        backendLocalBinDir.appendingPathComponent("lemon-bot", isDirectory: false)
    }

    public var backendTmpDir: URL {
        home.appendingPathComponent(".lemon/lemon_bot/tmp", isDirectory: true)
    }

    // Update lock
    public var updatesDir: URL {
        home.appendingPathComponent(".lemon/updates", isDirectory: true)
    }

    public var lockFile: URL {
        updatesDir.appendingPathComponent(".operation.lock", isDirectory: false)
    }

    // Link targets
    public func runtimeCurrentTarget(version: String) -> String {
        version
    }

    public var runtimeLemonTarget: String {
        "../versions/current/bin/lemon"
    }

    public func backendCurrentTarget(key: String) -> String {
        "versions/\(key)"
    }

    public var backendLemonBotTarget: String {
        backendCurrentLink.path + "/bot/bin/lemon-bot"
    }
}

// MARK: - Progress & Errors

/// Progress steps during runtime installation.
public enum RuntimeInstallStep: Equatable, Sendable {
    case download(received: Int64, total: Int64)
    case verify
    case install
}

/// Errors raised by the native installer.
public enum RuntimeInstallError: LocalizedError, Equatable {
    case locked
    case planStale
    case manifestUnavailable(detail: String)
    case manifestMismatch
    case manifestMissingDigest
    case artifactMissing(profile: String)
    case downloadFailed(file: String, detail: String)
    case checksumMismatch(file: String)
    case unsafeArchive(file: String, detail: String)
    case verificationFailed(component: String, detail: String)
    case filesystem(detail: String)

    public var errorDescription: String? {
        switch self {
        case .locked:
            return "Another Lemon update or install is currently in progress."
        case .planStale:
            return "Lemon's installed components changed while this install was starting."
        case .manifestUnavailable(let detail):
            return "Could not retrieve release manifest: \(detail)"
        case .manifestMismatch:
            return "The release manifest did not match this app's signed digest."
        case .manifestMissingDigest:
            return "The release pin does not include a verified manifest digest."
        case .artifactMissing(let profile):
            return "No release artifact available for profile \(profile)."
        case .downloadFailed(let file, let detail):
            return "Failed to download \(file): \(detail)"
        case .checksumMismatch(let file):
            return "Integrity check failed for \(file)."
        case .unsafeArchive(let file, let detail):
            return "Archive \(file) is invalid or unsafe: \(detail)"
        case .verificationFailed(let component, let detail):
            return "Verification of \(component) failed: \(detail)"
        case .filesystem(let detail):
            return "Filesystem operation failed: \(detail)"
        }
    }
}

// MARK: - RuntimeInstaller

public enum RuntimeInstaller {

    /// Installation plan computed from existing installation state and pinned release.
    public struct Plan: Equatable, Sendable {
        public enum Action: Equatable, Sendable {
            case ready
            case installBoth(version: String, channel: String, digestEnforced: Bool)
            case installRuntime(version: String, channel: String, digestEnforced: Bool)
            case installBackend(version: String, channel: String, digestEnforced: Bool)
        }

        public let action: Action
        public let layout: InstallLayout
        public let baseURL: URL
        public let manifestSHA256: String?

        public init(
            action: Action,
            layout: InstallLayout,
            baseURL: URL,
            manifestSHA256: String?
        ) {
            self.action = action
            self.layout = layout
            self.baseURL = baseURL
            self.manifestSHA256 = manifestSHA256
        }

        public var isReady: Bool {
            action == .ready
        }

        public var isDigestEnforced: Bool {
            switch action {
            case .ready:
                return false
            case .installBoth(_, _, let digestEnforced),
                 .installRuntime(_, _, let digestEnforced),
                 .installBackend(_, _, let digestEnforced):
                return digestEnforced
            }
        }

        public var targetVersion: String? {
            switch action {
            case .ready:
                return nil
            case .installBoth(let version, _, _),
                 .installRuntime(let version, _, _),
                 .installBackend(let version, _, _):
                return version
            }
        }

        public var targetChannel: String? {
            switch action {
            case .ready:
                return nil
            case .installBoth(_, let channel, _),
                 .installRuntime(_, let channel, _),
                 .installBackend(_, let channel, _):
                return channel
            }
        }
    }

    /// Installed component pointers, read from the two `current` symlinks.
    struct Pointers: Equatable {
        let runtimeVersion: String?
        let backendVersion: String?
        let backendChannel: String?
    }

    static func pointers(layout: InstallLayout) -> Pointers {
        let fileManager = FileManager.default

        var runtimeVersion: String? = nil
        if let dest = try? fileManager.destinationOfSymbolicLink(atPath: layout.runtimeCurrentLink.path) {
            let name = URL(fileURLWithPath: dest).lastPathComponent
            if !name.isEmpty && name != "current" {
                runtimeVersion = name
            }
        }

        var backendVersion: String? = nil
        var backendChannel: String? = nil
        if let dest = try? fileManager.destinationOfSymbolicLink(atPath: layout.backendCurrentLink.path) {
            let key = URL(fileURLWithPath: dest).lastPathComponent
            if key.hasSuffix("-darwin-arm64") {
                let remainder = key.dropLast("-darwin-arm64".count)
                if let lastDash = remainder.lastIndex(of: "-") {
                    backendVersion = String(remainder[..<lastDash])
                    backendChannel = String(remainder[remainder.index(after: lastDash)...])
                }
            } else {
                let parts = key.split(separator: "-").map(String.init)
                if parts.count >= 2 {
                    backendVersion = parts[0]
                    backendChannel = parts[1]
                }
            }
        }

        return Pointers(runtimeVersion: runtimeVersion, backendVersion: backendVersion, backendChannel: backendChannel)
    }

    /// Evaluates current symlink pointers and returns the required installation plan.
    ///
    /// - Parameters:
    ///   - layout: The filesystem installation layout.
    ///   - pin: The release pin to target.
    /// - Throws: `RuntimeInstallError.manifestMissingDigest` if a native new install is planned
    ///   without a signed manifest digest in the pin.
    public static func plan(layout: InstallLayout, pin: ReleasePin) throws -> Plan {
        let state = pointers(layout: layout)

        switch (state.runtimeVersion, state.backendVersion) {
        case (.some, .some):
            // Row 5: both present -> ready
            return Plan(
                action: .ready,
                layout: layout,
                baseURL: pin.baseURL,
                manifestSHA256: pin.manifestSHA256
            )

        case (.none, .none):
            // Row 1: install both at V (digest-enforced)
            guard pin.manifestSHA256 != nil else {
                throw RuntimeInstallError.manifestMissingDigest
            }
            return Plan(
                action: .installBoth(version: pin.version, channel: pin.channel, digestEnforced: true),
                layout: layout,
                baseURL: pin.baseURL,
                manifestSHA256: pin.manifestSHA256
            )

        case (.some(let runtime), .none):
            if runtime == pin.version {
                // Row 2: =V | none -> install backend V (digest-enforced)
                guard pin.manifestSHA256 != nil else {
                    throw RuntimeInstallError.manifestMissingDigest
                }
                return Plan(
                    action: .installBackend(version: pin.version, channel: pin.channel, digestEnforced: true),
                    layout: layout,
                    baseURL: pin.baseURL,
                    manifestSHA256: pin.manifestSHA256
                )
            }
            // Row 4a: W | none -> install the missing backend at W (HTTPS + sha only)
            return Plan(
                action: .installBackend(version: runtime, channel: pin.channel, digestEnforced: false),
                layout: layout,
                baseURL: pin.baseURL,
                manifestSHA256: nil
            )

        case (.none, .some(let backend)):
            if backend == pin.version {
                // Row 3: none | =V -> install runtime V (digest-enforced)
                guard pin.manifestSHA256 != nil else {
                    throw RuntimeInstallError.manifestMissingDigest
                }
                return Plan(
                    action: .installRuntime(version: pin.version, channel: pin.channel, digestEnforced: true),
                    layout: layout,
                    baseURL: pin.baseURL,
                    manifestSHA256: pin.manifestSHA256
                )
            }
            // Row 4b: none | W -> install the missing runtime at W (HTTPS + sha only)
            return Plan(
                action: .installRuntime(version: backend, channel: state.backendChannel ?? pin.channel, digestEnforced: false),
                layout: layout,
                baseURL: pin.baseURL,
                manifestSHA256: nil
            )
        }
    }

    /// Convenience check for application bundle stability.
    public static func isStableApplicationLocation(
        bundleURL: URL = Bundle.main.bundleURL,
        home: String = NSHomeDirectory()
    ) -> Bool {
        ReleasePin.isStableApplicationLocation(bundleURL: bundleURL, home: home)
    }

#if os(macOS)

    /// One component the plan installs.
    private struct Component {
        let profile: String
        let artifact: RuntimeManifest.Artifact
        let tarball: URL
        let partialDir: URL
        let targetDir: URL
        let link: URL
        let linkTarget: String
        let launcherLink: URL
        let launcherTarget: String

        var isRuntime: Bool { profile == "lemon_runtime_full" }
    }

    /// Everything that has to be undone when a later step fails.
    private struct Journal {
        /// Directories moved aside before a promotion, newest first.
        var movedAside: [(previous: URL, original: URL)] = []
        /// Directories this install promoted into place (and therefore owns).
        var promoted: [URL] = []
        /// Links this install changed, with the target they pointed at before (nil = absent).
        var links: [(link: URL, previousTarget: String?)] = []
        /// Directories this install created, deepest last.
        var directories: [URL] = []
    }

    /// Executes the installation plan.
    ///
    /// - Parameters:
    ///   - plan: The installation plan to execute.
    ///   - session: Optional session whose configuration is reused (tests inject a stub protocol).
    ///   - progress: Callback reporting download, verification, and installation steps.
    /// - Throws: `CancellationError` when the surrounding task is cancelled, otherwise
    ///   `RuntimeInstallError`. Either way no pointer is left changed and no staging survives.
    public static func install(
        _ plan: Plan,
        session: URLSession? = nil,
        progress: @Sendable (RuntimeInstallStep) -> Void
    ) async throws {
        if plan.action == .ready { return }
        try Task.checkCancellation()

        let fileManager = FileManager.default
        let layout = plan.layout

        // Step 1: take ~/.lemon/updates/.operation.lock. A foreign lock is never removed.
        do {
            try fileManager.createDirectory(at: layout.updatesDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw RuntimeInstallError.filesystem(detail: "Could not create updates directory: \(error.localizedDescription)")
        }

        let lockPath = layout.lockFile.path
        let lockDescriptor = open(lockPath, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        if lockDescriptor < 0 {
            if errno == EEXIST { throw RuntimeInstallError.locked }
            throw RuntimeInstallError.filesystem(detail: "Could not acquire update lock: errno \(errno)")
        }
        let payload = Array("lemon-update-lock-v1\n".utf8)
        _ = payload.withUnsafeBufferPointer { write(lockDescriptor, $0.baseAddress, $0.count) }
        close(lockDescriptor)
        defer { unlink(lockPath) }

        // The plan was computed before the lock existed. Re-read the pointers now: another
        // installer may have finished a component in between, and this installer never flips
        // an existing `current` to a different version.
        let version: String
        let channel: String
        var needRuntime = false
        var needBackend = false
        let digestEnforced: Bool

        switch plan.action {
        case .ready:
            return
        case .installBoth(let planVersion, let planChannel, let enforced):
            version = planVersion; channel = planChannel; digestEnforced = enforced
            needRuntime = true; needBackend = true
        case .installRuntime(let planVersion, let planChannel, let enforced):
            version = planVersion; channel = planChannel; digestEnforced = enforced
            needRuntime = true
        case .installBackend(let planVersion, let planChannel, let enforced):
            version = planVersion; channel = planChannel; digestEnforced = enforced
            needBackend = true
        }

        let state = pointers(layout: layout)
        if needRuntime && state.runtimeVersion != nil { throw RuntimeInstallError.planStale }
        if needBackend && state.backendVersion != nil { throw RuntimeInstallError.planStale }

        if digestEnforced && plan.manifestSHA256 == nil {
            throw RuntimeInstallError.manifestMissingDigest
        }

        let configuration = (session?.configuration).map { copyConfiguration($0) } ?? URLSessionConfiguration.ephemeral

        // Step 2: fetch the manifest, bounded to 1 MiB and hashed while it streams.
        let manifestURL = plan.baseURL.appendingPathComponent("releases/download/v\(version)/manifest.json")
        let manifestResult: Fetch.Result
        do {
            manifestResult = try await Fetch.perform(
                configuration: configuration,
                url: manifestURL,
                destination: nil,
                maximumBytes: 1_048_576,
                overflow: .manifestUnavailable(detail: "the release manifest is larger than 1 MiB"),
                progress: nil
            )
        } catch let error as RuntimeInstallError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw RuntimeInstallError.manifestUnavailable(detail: error.localizedDescription)
        }
        try Task.checkCancellation()

        guard manifestResult.statusCode == 200 else {
            throw RuntimeInstallError.manifestUnavailable(detail: "HTTP \(manifestResult.statusCode)")
        }
        guard let manifestData = manifestResult.data else {
            throw RuntimeInstallError.manifestUnavailable(detail: "empty manifest response")
        }
        if digestEnforced, let expected = plan.manifestSHA256, manifestResult.sha256 != expected.lowercased() {
            throw RuntimeInstallError.manifestMismatch
        }

        let manifest: RuntimeManifest
        do {
            manifest = try JSONDecoder().decode(RuntimeManifest.self, from: manifestData)
        } catch {
            throw RuntimeInstallError.manifestUnavailable(detail: "release manifest is not readable JSON")
        }

        // Step 3: resolve the artifacts and staging paths.
        let platform = "darwin-arm64"
        let backendKey = layout.backendKey(version: version, channel: channel, platform: platform)
        var components: [Component] = []

        if needRuntime {
            let artifact = try manifest.select(profile: "lemon_runtime_full", platform: platform, version: version, channel: channel)
            let targetDir = layout.runtimeVersionDir(for: version)
            components.append(Component(
                profile: "lemon_runtime_full",
                artifact: artifact,
                tarball: layout.runtimeTmpDir.appendingPathComponent(artifact.file),
                partialDir: URL(fileURLWithPath: targetDir.path + ".partial"),
                targetDir: targetDir,
                link: layout.runtimeCurrentLink,
                linkTarget: layout.runtimeCurrentTarget(version: version),
                launcherLink: layout.runtimeLemonLink,
                launcherTarget: layout.runtimeLemonTarget
            ))
        }

        if needBackend {
            let artifact = try manifest.select(profile: "lemon_bot", platform: platform, version: version, channel: channel)
            let targetDir = layout.backendVersionDir(key: backendKey)
            components.append(Component(
                profile: "lemon_bot",
                artifact: artifact,
                tarball: layout.backendTmpDir.appendingPathComponent(artifact.file),
                partialDir: URL(fileURLWithPath: targetDir.path + ".partial"),
                targetDir: targetDir,
                link: layout.backendCurrentLink,
                linkTarget: layout.backendCurrentTarget(key: backendKey),
                launcherLink: layout.backendLemonBotLink,
                launcherTarget: layout.backendLemonBotTarget
            ))
        }

        var journal = Journal()
        var downloads: [URL] = []
        var partials: [URL] = []
        var committed = false

        defer {
            for file in downloads { try? fileManager.removeItem(at: file) }
            for partial in partials { try? fileManager.removeItem(at: partial) }
            if !committed { rollback(journal) }
        }

        for component in components {
            let directory = component.isRuntime ? layout.runtimeTmpDir : layout.backendTmpDir
            try createDirectory(directory, permissions: 0o700, journal: &journal)
        }

        // Step 4: download every artifact, streaming to disk with a streaming digest, before
        // anything is extracted (install.sh:945-967).
        let totalBytes = components.reduce(Int64(0)) { $0 + $1.artifact.size }
        progress(.download(received: 0, total: totalBytes))

        var completedBytes: Int64 = 0
        for component in components {
            try Task.checkCancellation()
            let artifact = component.artifact
            let downloadURL = plan.baseURL.appendingPathComponent("releases/download/v\(version)/\(artifact.file)")
            try? fileManager.removeItem(at: component.tarball)

            let base = completedBytes
            let result: Fetch.Result
            do {
                result = try await Fetch.perform(
                    configuration: configuration,
                    url: downloadURL,
                    destination: component.tarball,
                    maximumBytes: artifact.size,
                    overflow: .checksumMismatch(file: artifact.file),
                    progress: { received in progress(.download(received: base + received, total: totalBytes)) }
                )
            } catch let error as RuntimeInstallError {
                downloads.append(component.tarball)
                throw error
            } catch is CancellationError {
                downloads.append(component.tarball)
                throw CancellationError()
            } catch {
                downloads.append(component.tarball)
                if Task.isCancelled { throw CancellationError() }
                throw RuntimeInstallError.downloadFailed(file: artifact.file, detail: error.localizedDescription)
            }

            downloads.append(component.tarball)
            guard (200...299).contains(result.statusCode) else {
                throw RuntimeInstallError.downloadFailed(file: artifact.file, detail: "HTTP \(result.statusCode)")
            }
            guard result.byteCount == artifact.size, result.sha256 == artifact.sha256.lowercased() else {
                throw RuntimeInstallError.checksumMismatch(file: artifact.file)
            }

            completedBytes += result.byteCount
            progress(.download(received: completedBytes, total: totalBytes))
        }

        // Step 5: archive screening, extraction, tree walk and staged verification.
        progress(.verify)
        for component in components {
            try Task.checkCancellation()
            try validateArchiveMembers(tarball: component.tarball, file: component.artifact.file, isRuntime: component.isRuntime)

            try? fileManager.removeItem(at: component.partialDir)
            do {
                try fileManager.createDirectory(at: component.partialDir, withIntermediateDirectories: true)
            } catch {
                throw RuntimeInstallError.filesystem(detail: "Could not create staging directory: \(error.localizedDescription)")
            }
            partials.append(component.partialDir)

            let extraction = try runProcess(
                executable: URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: ["-xzf", component.tarball.path, "-C", component.partialDir.path, "--no-same-owner"],
                environment: ["PATH": "/usr/bin:/bin"],
                currentDirectory: nil,
                timeout: 600,
                component: component.artifact.file
            )
            guard extraction.status == 0 else {
                throw RuntimeInstallError.unsafeArchive(
                    file: component.artifact.file,
                    detail: "extraction failed with status \(extraction.status)"
                )
            }

            try? fileManager.removeItem(at: component.tarball)
            downloads.removeAll { $0 == component.tarball }

            try Task.checkCancellation()
            if component.isRuntime {
                try walkRuntimeTree(root: component.partialDir, file: component.artifact.file)
                try verifyStagedRuntime(root: component.partialDir, version: version)
            } else {
                try walkBackendTree(root: component.partialDir, file: component.artifact.file)
                try verifyStagedBackend(root: component.partialDir, version: version)
            }
        }

        // Step 6: promote, then flip. Every mutation from here on is journalled, so a failure
        // in the second half restores the first half instead of leaving a half-installed Lemon.
        try Task.checkCancellation()
        progress(.install)

        for component in components {
            try Task.checkCancellation()
            if fileManager.fileExists(atPath: component.targetDir.path) {
                let reusable: Bool
                if component.isRuntime {
                    reusable = (try? verifyStagedRuntime(root: component.targetDir, version: version)) != nil
                } else {
                    reusable = (try? verifyStagedBackend(root: component.targetDir, version: version)) != nil
                }
                if reusable {
                    try? fileManager.removeItem(at: component.partialDir)
                    partials.removeAll { $0 == component.partialDir }
                    continue
                }

                let aside = URL(fileURLWithPath: component.targetDir.path + ".previous.\(ProcessInfo.processInfo.processIdentifier)")
                try? fileManager.removeItem(at: aside)
                do {
                    try fileManager.moveItem(at: component.targetDir, to: aside)
                } catch {
                    throw RuntimeInstallError.filesystem(detail: "Could not move \(component.targetDir.lastPathComponent) aside: \(error.localizedDescription)")
                }
                journal.movedAside.append((previous: aside, original: component.targetDir))
            }

            do {
                try fileManager.createDirectory(at: component.targetDir.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: component.partialDir, to: component.targetDir)
            } catch {
                throw RuntimeInstallError.filesystem(detail: "Could not promote \(component.targetDir.lastPathComponent): \(error.localizedDescription)")
            }
            partials.removeAll { $0 == component.partialDir }
            journal.promoted.append(component.targetDir)
        }

        for component in components {
            try Task.checkCancellation()
            try createDirectory(component.link.deletingLastPathComponent(), permissions: nil, journal: &journal)
            try atomicSymlink(target: component.linkTarget, link: component.link, journal: &journal)
            try createDirectory(component.launcherLink.deletingLastPathComponent(), permissions: nil, journal: &journal)
            try atomicSymlink(target: component.launcherTarget, link: component.launcherLink, journal: &journal)

            if component.isRuntime {
                try createDirectory(layout.runtimeRunDir, permissions: 0o700, journal: &journal)
                try createDirectory(layout.runtimeStoreDir, permissions: 0o700, journal: &journal)
                try createDirectory(layout.runtimeTmpDir, permissions: 0o700, journal: &journal)
            }

            removeQuarantine(at: component.targetDir)
        }

        committed = true
        for record in journal.movedAside {
            try? fileManager.removeItem(at: record.previous)
        }
    }

    // MARK: - Rollback

    private static func rollback(_ journal: Journal) {
        let fileManager = FileManager.default

        for record in journal.links.reversed() {
            if let previous = record.previousTarget {
                var ignored = Journal()
                try? atomicSymlink(target: previous, link: record.link, journal: &ignored)
            } else {
                unlink(record.link.path)
            }
        }

        for directory in journal.promoted.reversed() {
            try? fileManager.removeItem(at: directory)
        }

        for record in journal.movedAside.reversed() {
            try? fileManager.removeItem(at: record.original)
            try? fileManager.moveItem(at: record.previous, to: record.original)
        }

        for directory in journal.directories.reversed() {
            if let contents = try? fileManager.contentsOfDirectory(atPath: directory.path), contents.isEmpty {
                try? fileManager.removeItem(at: directory)
            }
        }
    }

    private static func createDirectory(_ url: URL, permissions: Int?, journal: inout Journal) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue { return }
            throw RuntimeInstallError.filesystem(detail: "\(url.lastPathComponent) exists and is not a directory")
        }

        var attributes: [FileAttributeKey: Any] = [:]
        if let permissions = permissions { attributes[.posixPermissions] = permissions }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: attributes)
        } catch {
            throw RuntimeInstallError.filesystem(detail: "Could not create \(url.lastPathComponent): \(error.localizedDescription)")
        }
        journal.directories.append(url)
    }

    private static func atomicSymlink(target: String, link: URL, journal: inout Journal) throws {
        let parent = link.deletingLastPathComponent()
        let previous = readLinkTarget(link)
        let staging = parent.appendingPathComponent(".tmp.\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString)")
        unlink(staging.path)

        if symlink(target, staging.path) != 0 {
            throw RuntimeInstallError.filesystem(detail: "symlink failed for \(link.lastPathComponent): errno \(errno)")
        }
        if rename(staging.path, link.path) != 0 {
            let failure = errno
            unlink(staging.path)
            throw RuntimeInstallError.filesystem(detail: "rename failed for \(link.lastPathComponent): errno \(failure)")
        }
        journal.links.append((link: link, previousTarget: previous))
    }

    private static func readLinkTarget(_ url: URL) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = readlink(url.path, &buffer, buffer.count - 1)
        guard length > 0 else { return nil }
        buffer[length] = 0
        return String(cString: buffer)
    }

    // MARK: - Archive screening

    private static func validateArchiveMembers(tarball: URL, file: String, isRuntime: Bool) throws {
        let listing = try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-tzf", tarball.path],
            environment: ["PATH": "/usr/bin:/bin"],
            currentDirectory: nil,
            timeout: 300,
            component: file
        )
        guard listing.status == 0 else {
            throw RuntimeInstallError.unsafeArchive(file: file, detail: "could not list the archive (status \(listing.status))")
        }
        guard let output = String(data: listing.standardOutput, encoding: .utf8) else {
            throw RuntimeInstallError.unsafeArchive(file: file, detail: "archive listing is not valid UTF-8")
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let entry = String(rawLine)
            if entry.hasPrefix("/") {
                throw RuntimeInstallError.unsafeArchive(file: file, detail: "absolute archive path: \(entry)")
            }

            var name = entry
            while name.hasPrefix("./") { name.removeFirst(2) }
            while name.hasSuffix("/") { name.removeLast() }
            if name.isEmpty || name == "." { continue }

            let parts = name.components(separatedBy: "/")
            if parts.contains("..") || parts.contains("") {
                throw RuntimeInstallError.unsafeArchive(file: file, detail: "archive path escapes its root: \(entry)")
            }

            if isRuntime {
                if parts[0] == "bot" {
                    throw RuntimeInstallError.unsafeArchive(file: file, detail: "runtime archive contains an unexpected bot/ entry: \(entry)")
                }
            } else if parts[0] != "bot" {
                throw RuntimeInstallError.unsafeArchive(file: file, detail: "backend archive contains an unexpected top level: \(entry)")
            }
        }
    }

    private static func walkRuntimeTree(root: URL, file: String) throws {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw RuntimeInstallError.unsafeArchive(file: file, detail: "could not enumerate the staged runtime")
        }

        var entries = 0
        var bytes: Int64 = 0
        for case let url as URL in enumerator {
            entries += 1
            if entries > 200_000 {
                throw RuntimeInstallError.unsafeArchive(file: file, detail: "runtime exceeds 200000 entries")
            }

            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                throw RuntimeInstallError.unsafeArchive(file: file, detail: "could not inspect \(url.lastPathComponent)")
            }
            let kind = info.st_mode & S_IFMT
            if kind == S_IFLNK {
                throw RuntimeInstallError.unsafeArchive(file: file, detail: "runtime contains a symlink: \(url.lastPathComponent)")
            }
            guard kind == S_IFREG || kind == S_IFDIR else {
                throw RuntimeInstallError.unsafeArchive(file: file, detail: "runtime contains a special file: \(url.lastPathComponent)")
            }
            if kind == S_IFREG {
                bytes += Int64(info.st_size)
                if bytes > 4_294_967_296 {
                    throw RuntimeInstallError.unsafeArchive(file: file, detail: "runtime exceeds 4 GiB")
                }
            }
        }
    }

    private static func walkBackendTree(root: URL, file: String) throws {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw RuntimeInstallError.unsafeArchive(file: file, detail: "could not enumerate the staged backend")
        }

        let botRoot = root.appendingPathComponent("bot", isDirectory: true).standardizedFileURL.path
        for case let url as URL in enumerator {
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                throw RuntimeInstallError.unsafeArchive(file: file, detail: "could not inspect \(url.lastPathComponent)")
            }
            let kind = info.st_mode & S_IFMT
            if kind == S_IFLNK {
                guard let target = readLinkTarget(url) else {
                    throw RuntimeInstallError.unsafeArchive(file: file, detail: "could not read the symlink \(url.lastPathComponent)")
                }
                if target.hasPrefix("/") {
                    throw RuntimeInstallError.unsafeArchive(file: file, detail: "backend contains an absolute symlink: \(target)")
                }
                let resolved = url.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL.path
                guard resolved == botRoot || resolved.hasPrefix(botRoot + "/") else {
                    throw RuntimeInstallError.unsafeArchive(file: file, detail: "backend symlink escapes bot directory: \(target)")
                }
            } else if kind != S_IFREG && kind != S_IFDIR {
                throw RuntimeInstallError.unsafeArchive(file: file, detail: "backend contains a special file: \(url.lastPathComponent)")
            }
        }

        var binary = stat()
        guard lstat(root.appendingPathComponent("bot/bin/lemon-bot").path, &binary) == 0 else {
            throw RuntimeInstallError.unsafeArchive(file: file, detail: "backend has no bot/bin/lemon-bot")
        }
        guard (binary.st_mode & S_IFMT) == S_IFREG else {
            throw RuntimeInstallError.unsafeArchive(file: file, detail: "bot/bin/lemon-bot must be a regular file")
        }
    }

    // MARK: - Staged verification

    @discardableResult
    private static func verifyStagedRuntime(root: URL, version: String) throws -> Bool {
        let fileManager = FileManager.default
        let launcher = root.appendingPathComponent("bin/lemon")
        guard fileManager.isExecutableFile(atPath: launcher.path) else {
            throw RuntimeInstallError.verificationFailed(component: "runtime", detail: "no executable bin/lemon")
        }

        let home = fileManager.temporaryDirectory.appendingPathComponent("lemon-runtime-check-\(UUID().uuidString)")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }

        var environment = ProcessInfo.processInfo.environment
        for key in ["RELEASE_ROOT", "RELEASE_VSN", "RELEASE_NAME", "RELEASE_PROG", "RELEASE_COMMAND", "RELEASE_MODE"] {
            environment.removeValue(forKey: key)
        }
        environment["HOME"] = home.path
        environment["LEMON_STORE_PATH"] = home.appendingPathComponent(".lemon/store").path
        environment["LEMON_AGENT_DIR"] = home.appendingPathComponent(".lemon/agent").path
        environment["LEMON_DOTENV_DIR"] = home.path
        environment["RELEASE_TMP"] = home.appendingPathComponent("runtime").path

        let result = try runProcess(
            executable: launcher,
            arguments: ["node", "capabilities", "--json", "--require-bot", "--expected-version", version],
            environment: environment,
            currentDirectory: home,
            timeout: 120,
            component: "runtime"
        )
        guard result.status == 0 else {
            let detail = String(data: result.standardError.prefix(2048), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw RuntimeInstallError.verificationFailed(
                component: "runtime",
                detail: "node capabilities --require-bot failed (status \(result.status))\(detail.isEmpty ? "" : ": \(detail)")"
            )
        }
        return true
    }

    @discardableResult
    private static func verifyStagedBackend(root: URL, version: String) throws -> Bool {
        let fileManager = FileManager.default
        let binary = root.appendingPathComponent("bot/bin/lemon-bot")
        guard fileManager.isExecutableFile(atPath: binary.path) else {
            throw RuntimeInstallError.verificationFailed(component: "backend", detail: "no executable bot/bin/lemon-bot")
        }

        let web = root.appendingPathComponent("bot/web")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: web.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let contents = try? fileManager.contentsOfDirectory(atPath: web.path), !contents.isEmpty else {
            throw RuntimeInstallError.verificationFailed(component: "backend", detail: "no web assets")
        }

        let native = root.appendingPathComponent("bot/node_modules/@img/sharp-darwin-arm64")
        let libvips = root.appendingPathComponent("bot/node_modules/@img/sharp-libvips-darwin-arm64")
        guard fileManager.fileExists(atPath: native.appendingPathComponent("package.json").path),
              fileManager.fileExists(atPath: libvips.appendingPathComponent("package.json").path),
              fileManager.fileExists(atPath: native.appendingPathComponent("lib/sharp-darwin-arm64.node").path) else {
            throw RuntimeInstallError.verificationFailed(component: "backend", detail: "no host-native image runtime")
        }

        let home = fileManager.temporaryDirectory.appendingPathComponent("lemon-backend-check-\(UUID().uuidString)")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }

        let result = try runProcess(
            executable: binary,
            arguments: ["--version"],
            environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"],
            currentDirectory: home,
            timeout: 15,
            component: "backend"
        )
        guard result.status == 0,
              String(data: result.standardOutput, encoding: .utf8) == "lemon-bot \(version)\n" else {
            throw RuntimeInstallError.verificationFailed(component: "backend", detail: "--version did not report \(version)")
        }
        return true
    }

    private static func removeQuarantine(at url: URL) {
        _ = try? runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/xattr"),
            arguments: ["-dr", "com.apple.quarantine", url.path],
            environment: ["PATH": "/usr/bin:/bin"],
            currentDirectory: nil,
            timeout: 60,
            component: "quarantine"
        )
    }

    // MARK: - Process execution

    private struct ProcessResult {
        let status: Int32
        let standardOutput: Data
        let standardError: Data
    }

    /// Runs a child process, draining both pipes concurrently so a chatty child can never fill a
    /// pipe buffer and deadlock the wait, and bounding how much output is retained.
    private static func runProcess(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?,
        timeout: TimeInterval,
        component: String,
        maximumOutputBytes: Int = 16 * 1024 * 1024
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory = currentDirectory { process.currentDirectoryURL = currentDirectory }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outPipe
        process.standardError = errPipe

        let sink = OutputSink(limit: maximumOutputBytes)
        let group = DispatchGroup()
        group.enter(); group.enter()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                group.leave()
            } else {
                sink.appendOutput(chunk)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                group.leave()
            } else {
                sink.appendError(chunk)
            }
        }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw RuntimeInstallError.verificationFailed(component: component, detail: "could not run \(executable.lastPathComponent)")
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 5)
            }
        }
        _ = group.wait(timeout: .now() + 10)
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        try? outPipe.fileHandleForReading.close()
        try? errPipe.fileHandleForReading.close()

        if timedOut {
            throw RuntimeInstallError.verificationFailed(component: component, detail: "timed out after \(Int(timeout))s")
        }
        return ProcessResult(status: process.terminationStatus, standardOutput: sink.output, standardError: sink.error)
    }

    private final class OutputSink: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var outputBuffer = Data()
        private var errorBuffer = Data()

        init(limit: Int) { self.limit = limit }

        func appendOutput(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            if outputBuffer.count < limit { outputBuffer.append(chunk) }
        }

        func appendError(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            if errorBuffer.count < limit { errorBuffer.append(chunk) }
        }

        var output: Data {
            lock.lock(); defer { lock.unlock() }
            return outputBuffer
        }

        var error: Data {
            lock.lock(); defer { lock.unlock() }
            return errorBuffer
        }
    }

    // MARK: - Bounded streaming fetch

    private static func copyConfiguration(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        let copy = URLSessionConfiguration.ephemeral
        copy.protocolClasses = configuration.protocolClasses
        copy.timeoutIntervalForRequest = configuration.timeoutIntervalForRequest
        copy.timeoutIntervalForResource = configuration.timeoutIntervalForResource
        return copy
    }

    /// Streams an HTTPS response to memory (manifest) or to a file (artifacts), hashing as it
    /// goes and refusing to buffer or write more than `maximumBytes`.
    enum Fetch {
        struct Result {
            let statusCode: Int
            let data: Data?
            let sha256: String
            let byteCount: Int64
        }

        static func perform(
            configuration: URLSessionConfiguration,
            url: URL,
            destination: URL?,
            maximumBytes: Int64,
            overflow: RuntimeInstallError,
            progress: (@Sendable (Int64) -> Void)?
        ) async throws -> Result {
            let collector = try Collector(destination: destination, maximumBytes: maximumBytes, overflow: overflow, progress: progress)
            let session = URLSession(configuration: configuration, delegate: collector, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }

            var request = URLRequest(url: url)
            request.httpShouldHandleCookies = false
            let task = session.dataTask(with: request)

            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    collector.start(continuation: continuation)
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        }

        final class Collector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
            private let lock = NSLock()
            private let maximumBytes: Int64
            private let overflow: RuntimeInstallError
            private let destination: URL?
            private let progress: (@Sendable (Int64) -> Void)?
            private var handle: FileHandle?
            private var hasher = SHA256()
            private var buffer: Data?
            private var received: Int64 = 0
            private var statusCode = 0
            private var failure: Error?
            private var continuation: CheckedContinuation<Result, Error>?
            private var finished = false

            init(
                destination: URL?,
                maximumBytes: Int64,
                overflow: RuntimeInstallError,
                progress: (@Sendable (Int64) -> Void)?
            ) throws {
                self.destination = destination
                self.maximumBytes = maximumBytes
                self.overflow = overflow
                self.progress = progress
                if let destination = destination {
                    let manager = FileManager.default
                    try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    guard manager.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                        throw RuntimeInstallError.filesystem(detail: "could not create \(destination.lastPathComponent)")
                    }
                    self.handle = try FileHandle(forWritingTo: destination)
                } else {
                    self.buffer = Data()
                }
            }

            func start(continuation: CheckedContinuation<Result, Error>) {
                lock.lock()
                self.continuation = continuation
                lock.unlock()
            }

            private func finish(_ outcome: Swift.Result<Result, Error>) {
                lock.lock()
                guard !finished, let continuation = continuation else { lock.unlock(); return }
                finished = true
                self.continuation = nil
                try? handle?.close()
                handle = nil
                lock.unlock()
                continuation.resume(with: outcome)
            }

            func urlSession(
                _ session: URLSession,
                dataTask: URLSessionDataTask,
                didReceive response: URLResponse,
                completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
            ) {
                if let http = response as? HTTPURLResponse {
                    lock.lock(); statusCode = http.statusCode; lock.unlock()
                }
                completionHandler(.allow)
            }

            func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
                lock.lock()
                if finished { lock.unlock(); return }
                if received + Int64(data.count) > maximumBytes {
                    failure = overflow
                    lock.unlock()
                    dataTask.cancel()
                    return
                }
                received += Int64(data.count)
                hasher.update(data: data)
                if buffer != nil {
                    buffer?.append(data)
                } else {
                    do {
                        try handle?.write(contentsOf: data)
                    } catch {
                        failure = RuntimeInstallError.filesystem(detail: "could not write the download")
                        lock.unlock()
                        dataTask.cancel()
                        return
                    }
                }
                let total = received
                lock.unlock()
                progress?(total)
            }

            func urlSession(
                _ session: URLSession,
                task: URLSessionTask,
                willPerformHTTPRedirection response: HTTPURLResponse,
                newRequest request: URLRequest,
                completionHandler: @escaping (URLRequest?) -> Void
            ) {
                guard request.url?.scheme == "https" else {
                    lock.lock()
                    failure = RuntimeInstallError.manifestUnavailable(detail: "refused a non-https redirect")
                    lock.unlock()
                    completionHandler(nil)
                    return
                }
                completionHandler(request)
            }

            func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
                lock.lock()
                let recorded = failure
                let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                let result = Result(statusCode: statusCode, data: buffer, sha256: digest, byteCount: received)
                lock.unlock()

                if let recorded = recorded {
                    finish(.failure(recorded))
                } else if let error = error {
                    if (error as? URLError)?.code == .cancelled {
                        finish(.failure(CancellationError()))
                    } else {
                        finish(.failure(error))
                    }
                } else {
                    finish(.success(result))
                }
            }
        }
    }
#endif
}
