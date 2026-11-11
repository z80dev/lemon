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

    /// Evaluates current symlink pointers and returns the required installation plan.
    ///
    /// - Parameters:
    ///   - layout: The filesystem installation layout.
    ///   - pin: The release pin to target.
    /// - Throws: `RuntimeInstallError.manifestMissingDigest` if a native new install is planned
    ///   without a signed manifest digest in the pin.
    public static func plan(layout: InstallLayout, pin: ReleasePin) throws -> Plan {
        let fileManager = FileManager.default

        // 1. Detect runtime current
        var runtimeVersion: String? = nil
        if let dest = try? fileManager.destinationOfSymbolicLink(atPath: layout.runtimeCurrentLink.path) {
            let name = URL(fileURLWithPath: dest).lastPathComponent
            if !name.isEmpty && name != "current" {
                runtimeVersion = name
            }
        }

        // 2. Detect backend current
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

        // 3. Evaluate plan table (§3.B)
        switch (runtimeVersion, backendVersion) {
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

        case (.some(let rV), .none):
            if rV == pin.version {
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
            } else {
                // Row 4a: W | none -> install backend at W (HTTPS + sha only)
                return Plan(
                    action: .installBackend(version: rV, channel: pin.channel, digestEnforced: false),
                    layout: layout,
                    baseURL: pin.baseURL,
                    manifestSHA256: nil
                )
            }

        case (.none, .some(let bV)):
            if bV == pin.version {
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
            } else {
                // Row 4b: none | W -> install runtime at W (HTTPS + sha only)
                let channel = backendChannel ?? pin.channel
                return Plan(
                    action: .installRuntime(version: bV, channel: channel, digestEnforced: false),
                    layout: layout,
                    baseURL: pin.baseURL,
                    manifestSHA256: nil
                )
            }
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
    /// Executes the installation plan.
    ///
    /// - Parameters:
    ///   - plan: The installation plan to execute.
    ///   - session: Optional custom URLSession (for testing). When nil, an ephemeral session
    ///     with HTTPS-only redirection is used.
    ///   - progress: Callback reporting download, verification, and installation steps.
    public static func install(
        _ plan: Plan,
        session: URLSession? = nil,
        progress: @Sendable (RuntimeInstallStep) -> Void
    ) async throws {
        if plan.action == .ready {
            return
        }

        let fileManager = FileManager.default

        // Step 1: Take ~/.lemon/updates/.operation.lock
        let updatesDir = plan.layout.updatesDir
        do {
            try fileManager.createDirectory(at: updatesDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw RuntimeInstallError.filesystem(detail: "Could not create updates directory: \(error.localizedDescription)")
        }

        let lockPath = plan.layout.lockFile.path
        let fd = open(lockPath, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        if fd < 0 {
            if errno == EEXIST {
                throw RuntimeInstallError.locked
            } else {
                throw RuntimeInstallError.filesystem(detail: "Could not acquire update lock: errno \(errno)")
            }
        }

        let lockPayload = "lemon-update-lock-v1\n"
        _ = lockPayload.withCString { ptr in
            write(fd, ptr, strlen(ptr))
        }
        close(fd)

        defer { unlink(lockPath) }

        // Determine plan parameters
        let version: String
        let channel: String
        let needRuntime: Bool
        let needBackend: Bool
        let digestEnforced: Bool

        switch plan.action {
        case .ready:
            return
        case .installBoth(let v, let c, let de):
            version = v; channel = c; needRuntime = true; needBackend = true; digestEnforced = de
        case .installRuntime(let v, let c, let de):
            version = v; channel = c; needRuntime = true; needBackend = false; digestEnforced = de
        case .installBackend(let v, let c, let de):
            version = v; channel = c; needRuntime = false; needBackend = true; digestEnforced = de
        }

        if digestEnforced && plan.manifestSHA256 == nil {
            throw RuntimeInstallError.manifestMissingDigest
        }

        // Step 2: Fetch manifest
        let manifestURL = plan.baseURL.appendingPathComponent("releases/download/v\(version)/manifest.json")
        let sessionToUse: URLSession
        if let customSession = session {
            sessionToUse = customSession
        } else {
            let config = URLSessionConfiguration.ephemeral
            sessionToUse = URLSession(configuration: config, delegate: HTTPSOnlyDelegate(), delegateQueue: nil)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await sessionToUse.data(from: manifestURL)
        } catch {
            throw RuntimeInstallError.manifestUnavailable(detail: error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw RuntimeInstallError.manifestUnavailable(detail: "HTTP \(http.statusCode)")
        }

        guard data.count <= 1_048_576 else {
            throw RuntimeInstallError.manifestUnavailable(detail: "Manifest exceeds 1 MiB limit")
        }

        if digestEnforced {
            guard let expected = plan.manifestSHA256 else {
                throw RuntimeInstallError.manifestMissingDigest
            }
            let computed = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard computed.lowercased() == expected.lowercased() else {
                throw RuntimeInstallError.manifestMismatch
            }
        }

        let manifest: RuntimeManifest
        do {
            manifest = try JSONDecoder().decode(RuntimeManifest.self, from: data)
        } catch {
            throw RuntimeInstallError.manifestUnavailable(detail: "JSON decode error: \(error.localizedDescription)")
        }

        // Step 3: Select artifacts
        let platform = "darwin-arm64"
        struct ArtifactTarget {
            let profile: String
            let artifact: RuntimeManifest.Artifact
            let tmpTarball: URL
            let partialDir: URL
            let finalDir: URL
        }

        var targets: [ArtifactTarget] = []

        if needRuntime {
            let art = try manifest.select(profile: "lemon_runtime_full", platform: platform, version: version, channel: channel)
            let tmp = plan.layout.runtimeTmpDir.appendingPathComponent(art.file)
            let finalDir = plan.layout.runtimeVersionDir(for: version)
            let partial = URL(fileURLWithPath: finalDir.path + ".partial")
            targets.append(ArtifactTarget(profile: "lemon_runtime_full", artifact: art, tmpTarball: tmp, partialDir: partial, finalDir: finalDir))
        }

        if needBackend {
            let art = try manifest.select(profile: "lemon_bot", platform: platform, version: version, channel: channel)
            let tmp = plan.layout.backendTmpDir.appendingPathComponent(art.file)
            let key = plan.layout.backendKey(version: version, channel: channel, platform: platform)
            let finalDir = plan.layout.backendVersionDir(key: key)
            let partial = URL(fileURLWithPath: finalDir.path + ".partial")
            targets.append(ArtifactTarget(profile: "lemon_bot", artifact: art, tmpTarball: tmp, partialDir: partial, finalDir: finalDir))
        }

        // Ensure temporary directories exist
        try? fileManager.createDirectory(at: plan.layout.runtimeTmpDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fileManager.createDirectory(at: plan.layout.backendTmpDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let totalBytes = targets.reduce(Int64(0)) { $0 + $1.artifact.size }
        progress(.download(received: 0, total: totalBytes))

        var downloadedFiles: [URL] = []
        var stagedPartials: [URL] = []
        var movedPrevious: [(previous: URL, original: URL)] = []

        defer {
            // Clean up downloads and partials if an error occurred before completion
            for file in downloadedFiles {
                try? fileManager.removeItem(at: file)
            }
            for partial in stagedPartials {
                try? fileManager.removeItem(at: partial)
            }
        }

        // Download all artifacts and verify integrity before extraction
        var currentReceived: Int64 = 0
        for item in targets {
            let downloadURL = plan.baseURL.appendingPathComponent("releases/download/v\(version)/\(item.artifact.file)")

            let (artifactData, artResponse): (Data, URLResponse)
            do {
                (artifactData, artResponse) = try await sessionToUse.data(from: downloadURL)
            } catch {
                throw RuntimeInstallError.downloadFailed(file: item.artifact.file, detail: error.localizedDescription)
            }

            if let http = artResponse as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw RuntimeInstallError.downloadFailed(file: item.artifact.file, detail: "HTTP \(http.statusCode)")
            }

            guard Int64(artifactData.count) == item.artifact.size else {
                throw RuntimeInstallError.checksumMismatch(file: item.artifact.file)
            }

            let computedSHA = SHA256.hash(data: artifactData).map { String(format: "%02x", $0) }.joined()
            guard computedSHA.lowercased() == item.artifact.sha256.lowercased() else {
                throw RuntimeInstallError.checksumMismatch(file: item.artifact.file)
            }

            do {
                try artifactData.write(to: item.tmpTarball, options: .atomic)
            } catch {
                throw RuntimeInstallError.filesystem(detail: "Failed to write \(item.tmpTarball.lastPathComponent): \(error.localizedDescription)")
            }

            downloadedFiles.append(item.tmpTarball)
            currentReceived += Int64(artifactData.count)
            progress(.download(received: currentReceived, total: totalBytes))
        }

        // Step 4: Validate tar archive paths before extraction
        progress(.verify)
        for item in targets {
            try validateArchiveMembers(tarball: item.tmpTarball, isRuntime: item.profile == "lemon_runtime_full")

            // Clean any existing .partial
            try? fileManager.removeItem(at: item.partialDir)
            try fileManager.createDirectory(at: item.partialDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            stagedPartials.append(item.partialDir)

            // Extract with /usr/bin/tar
            let tarProcess = Process()
            tarProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tarProcess.arguments = ["-xzf", item.tmpTarball.path, "-C", item.partialDir.path, "--no-same-owner"]
            let errPipe = Pipe()
            tarProcess.standardError = errPipe
            do {
                try tarProcess.run()
                tarProcess.waitUntilExit()
            } catch {
                throw RuntimeInstallError.unsafeArchive(file: item.artifact.file, detail: "tar execution failed: \(error.localizedDescription)")
            }
            guard tarProcess.terminationStatus == 0 else {
                throw RuntimeInstallError.unsafeArchive(file: item.artifact.file, detail: "Extraction failed with exit code \(tarProcess.terminationStatus)")
            }

            // Remove downloaded tarball now that extraction succeeded
            try? fileManager.removeItem(at: item.tmpTarball)
            downloadedFiles.removeAll { $0 == item.tmpTarball }

            // Step 5: Walk tree with lstat
            if item.profile == "lemon_runtime_full" {
                try walkRuntimeTree(root: item.partialDir, file: item.artifact.file)
            } else {
                try walkBackendTree(root: item.partialDir, file: item.artifact.file)
            }

            // Step 6: Verify component functionality in staged .partial
            if item.profile == "lemon_runtime_full" {
                try verifyStagedRuntime(root: item.partialDir, version: version)
            } else {
                try verifyStagedBackend(root: item.partialDir, version: version)
            }
        }

        // Step 7: Promotion
        progress(.install)
        for item in targets {
            let targetDir = item.finalDir
            if fileManager.fileExists(atPath: targetDir.path) {
                // If existing directory passes verification, reuse it
                let isExistingValid: Bool
                if item.profile == "lemon_runtime_full" {
                    isExistingValid = (try? verifyStagedRuntime(root: targetDir, version: version)) != nil
                } else {
                    isExistingValid = (try? verifyStagedBackend(root: targetDir, version: version)) != nil
                }

                if isExistingValid {
                    // Reuse existing directory, discard .partial
                    try? fileManager.removeItem(at: item.partialDir)
                    stagedPartials.removeAll { $0 == item.partialDir }
                    continue
                }

                // Move existing target directory aside to .previous.<pid>
                let prev = URL(fileURLWithPath: targetDir.path + ".previous.\(ProcessInfo.processInfo.processIdentifier)")
                try? fileManager.removeItem(at: prev)
                do {
                    try fileManager.moveItem(at: targetDir, to: prev)
                    movedPrevious.append((previous: prev, original: targetDir))
                } catch {
                    throw RuntimeInstallError.filesystem(detail: "Could not move existing \(targetDir.lastPathComponent) aside: \(error.localizedDescription)")
                }
            }

            // Move .partial to targetDir
            do {
                try fileManager.moveItem(at: item.partialDir, to: targetDir)
                stagedPartials.removeAll { $0 == item.partialDir }
            } catch {
                // Attempt rollback of previous directory
                if let idx = movedPrevious.firstIndex(where: { $0.original == targetDir }) {
                    let record = movedPrevious.remove(at: idx)
                    try? fileManager.moveItem(at: record.previous, to: targetDir)
                }
                throw RuntimeInstallError.filesystem(detail: "Could not promote staged directory to \(targetDir.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // Step 8 & 9: Flip symlinks and remove quarantine
        if needRuntime {
            let versionsDir = plan.layout.runtimeVersionsDir
            try fileManager.createDirectory(at: versionsDir, withIntermediateDirectories: true)
            try atomicSymlink(target: plan.layout.runtimeCurrentTarget(version: version), link: plan.layout.runtimeCurrentLink)

            let binDir = plan.layout.runtimeBinDir
            try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
            try atomicSymlink(target: plan.layout.runtimeLemonTarget, link: plan.layout.runtimeLemonLink)

            try? fileManager.createDirectory(at: plan.layout.runtimeRunDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? fileManager.createDirectory(at: plan.layout.runtimeStoreDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? fileManager.createDirectory(at: plan.layout.runtimeTmpDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

            removeQuarantine(at: plan.layout.runtimeVersionDir(for: version))
        }

        if needBackend {
            let backendKey = plan.layout.backendKey(version: version, channel: channel, platform: platform)
            let versionsDir = plan.layout.backendVersionsDir
            try fileManager.createDirectory(at: versionsDir, withIntermediateDirectories: true)
            try atomicSymlink(target: plan.layout.backendCurrentTarget(key: backendKey), link: plan.layout.backendCurrentLink)

            let localBin = plan.layout.backendLocalBinDir
            try fileManager.createDirectory(at: localBin, withIntermediateDirectories: true)
            try atomicSymlink(target: plan.layout.backendLemonBotTarget, link: plan.layout.backendLemonBotLink)

            removeQuarantine(at: plan.layout.backendVersionDir(key: backendKey))
        }

        // Clean up any moved .previous directories now that promotion committed
        for record in movedPrevious {
            try? fileManager.removeItem(at: record.previous)
        }
    }

    // MARK: - Internal Verification Helpers

    private static func validateArchiveMembers(tarball: URL, isRuntime: Bool) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-tzf", tarball.path]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw RuntimeInstallError.unsafeArchive(file: tarball.lastPathComponent, detail: "Listing tarball failed: \(error.localizedDescription)")
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw RuntimeInstallError.unsafeArchive(file: tarball.lastPathComponent, detail: "Listing tarball failed with status \(process.terminationStatus)")
        }

        guard let output = String(data: data, encoding: .utf8) else {
            throw RuntimeInstallError.unsafeArchive(file: tarball.lastPathComponent, detail: "Tarball listing contains invalid UTF-8")
        }

        let lines = output.components(separatedBy: "\n")
        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if trimmed.hasPrefix("/") {
                throw RuntimeInstallError.unsafeArchive(file: tarball.lastPathComponent, detail: "Absolute path in archive: \(trimmed)")
            }

            var name = trimmed
            while name.hasPrefix("./") {
                name.removeFirst(2)
            }
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !name.isEmpty, name != "." else { continue }

            let parts = name.components(separatedBy: "/")
            if parts.contains("..") {
                throw RuntimeInstallError.unsafeArchive(file: tarball.lastPathComponent, detail: "Archive member contains '..': \(trimmed)")
            }

            if isRuntime {
                if parts[0] == "bot" {
                    throw RuntimeInstallError.unsafeArchive(file: tarball.lastPathComponent, detail: "Runtime archive contains unexpected bot/ entry: \(trimmed)")
                }
            } else {
                if parts[0] != "bot" {
                    throw RuntimeInstallError.unsafeArchive(file: tarball.lastPathComponent, detail: "Backend archive contains unexpected non-bot/ entry: \(trimmed)")
                }
            }
        }
    }

    private static func walkRuntimeTree(root: URL, file: String) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw RuntimeInstallError.unsafeArchive(file: file, detail: "Cannot enumerate runtime tree")
        }

        var entryCount = 0
        var totalBytes: Int64 = 0

        for case let fileURL as URL in enumerator {
            entryCount += 1
            if entryCount > 200_000 {
                throw RuntimeInstallError.unsafeArchive(file: file, detail: "Runtime exceeds 200,000 entries")
            }

            var statBuf = stat()
            guard lstat(fileURL.path, &statBuf) == 0 else {
                throw RuntimeInstallError.unsafeArchive(file: file, detail: "Cannot lstat \(fileURL.lastPathComponent)")
            }

            let mode = statBuf.st_mode
            if (mode & S_IFMT) == S_IFLNK {
                throw RuntimeInstallError.unsafeArchive(file: file, detail: "Runtime contains forbidden symlink: \(fileURL.lastPathComponent)")
            }
            if (mode & S_IFMT) != S_IFREG && (mode & S_IFMT) != S_IFDIR {
                throw RuntimeInstallError.unsafeArchive(file: file, detail: "Runtime contains non-regular entry: \(fileURL.lastPathComponent)")
            }
            if (mode & S_IFMT) == S_IFREG {
                totalBytes += Int64(statBuf.st_size)
                if totalBytes > 4_294_967_296 {
                    throw RuntimeInstallError.unsafeArchive(file: file, detail: "Runtime exceeds 4 GiB size limit")
                }
            }
        }
    }

    private static func walkBackendTree(root: URL, file: String) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw RuntimeInstallError.unsafeArchive(file: file, detail: "Cannot enumerate backend tree")
        }

        let botRoot = root.appendingPathComponent("bot", isDirectory: true).standardizedFileURL.path

        for case let fileURL as URL in enumerator {
            var statBuf = stat()
            guard lstat(fileURL.path, &statBuf) == 0 else {
                throw RuntimeInstallError.unsafeArchive(file: file, detail: "Cannot lstat \(fileURL.lastPathComponent)")
            }

            let mode = statBuf.st_mode
            if (mode & S_IFMT) == S_IFLNK {
                var linkBuf = [CChar](repeating: 0, count: Int(PATH_MAX))
                let len = readlink(fileURL.path, &linkBuf, linkBuf.count - 1)
                guard len > 0 else {
                    throw RuntimeInstallError.unsafeArchive(file: file, detail: "Cannot readlink \(fileURL.lastPathComponent)")
                }
                linkBuf[len] = 0
                let targetStr = String(cString: linkBuf)
                if targetStr.hasPrefix("/") {
                    throw RuntimeInstallError.unsafeArchive(file: file, detail: "Absolute symlink in backend: \(targetStr)")
                }
                let parent = fileURL.deletingLastPathComponent().standardizedFileURL
                let resolved = parent.appendingPathComponent(targetStr).standardizedFileURL.path
                guard resolved.hasPrefix(botRoot) else {
                    throw RuntimeInstallError.unsafeArchive(file: file, detail: "Backend symlink escapes bot directory: \(targetStr)")
                }
            } else if (mode & S_IFMT) != S_IFREG && (mode & S_IFMT) != S_IFDIR {
                throw RuntimeInstallError.unsafeArchive(file: file, detail: "Backend contains non-regular entry: \(fileURL.lastPathComponent)")
            }
        }

        let binaryURL = root.appendingPathComponent("bot/bin/lemon-bot")
        var binStat = stat()
        guard lstat(binaryURL.path, &binStat) == 0 else {
            throw RuntimeInstallError.unsafeArchive(file: file, detail: "Backend is missing bot/bin/lemon-bot")
        }
        guard (binStat.st_mode & S_IFMT) == S_IFREG else {
            throw RuntimeInstallError.unsafeArchive(file: file, detail: "bot/bin/lemon-bot must be a regular file")
        }
    }

    private static func verifyStagedRuntime(root: URL, version: String) throws {
        let fm = FileManager.default
        let lemonBin = root.appendingPathComponent("bin/lemon")
        guard fm.isExecutableFile(atPath: lemonBin.path) else {
            throw RuntimeInstallError.verificationFailed(component: "runtime", detail: "Missing executable bin/lemon")
        }

        let checkHome = fm.temporaryDirectory.appendingPathComponent("lemon_check_\(UUID().uuidString)")
        try fm.createDirectory(at: checkHome, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: checkHome) }

        var env = ProcessInfo.processInfo.environment
        env["HOME"] = checkHome.path
        env["LEMON_STORE_PATH"] = checkHome.appendingPathComponent(".lemon/store").path
        env["LEMON_AGENT_DIR"] = checkHome.appendingPathComponent(".lemon/agent").path
        env["LEMON_DOTENV_DIR"] = checkHome.path
        env["RELEASE_TMP"] = checkHome.appendingPathComponent("runtime").path
        env.removeValue(forKey: "RELEASE_ROOT")
        env.removeValue(forKey: "RELEASE_VSN")
        env.removeValue(forKey: "RELEASE_NAME")
        env.removeValue(forKey: "RELEASE_PROG")
        env.removeValue(forKey: "RELEASE_COMMAND")
        env.removeValue(forKey: "RELEASE_MODE")

        let (status, _, errData) = try executeProcess(
            executable: lemonBin,
            arguments: ["node", "capabilities", "--json", "--require-bot", "--expected-version", version],
            environment: env,
            currentDirectory: checkHome,
            timeout: 120
        )

        guard status == 0 else {
            let errString = String(data: errData, encoding: .utf8) ?? ""
            throw RuntimeInstallError.verificationFailed(component: "runtime", detail: "node capabilities check failed (status \(status)): \(errString)")
        }
    }

    private static func verifyStagedBackend(root: URL, version: String) throws {
        let fm = FileManager.default
        let botBin = root.appendingPathComponent("bot/bin/lemon-bot")
        guard fm.isExecutableFile(atPath: botBin.path) else {
            throw RuntimeInstallError.verificationFailed(component: "backend", detail: "Missing executable bot/bin/lemon-bot")
        }

        let webDir = root.appendingPathComponent("bot/web")
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: webDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw RuntimeInstallError.verificationFailed(component: "backend", detail: "Missing bot/web directory")
        }
        let webItems = (try? fm.contentsOfDirectory(atPath: webDir.path)) ?? []
        guard !webItems.isEmpty else {
            throw RuntimeInstallError.verificationFailed(component: "backend", detail: "bot/web directory is empty")
        }

        let sharpRoot = root.appendingPathComponent("bot/node_modules/@img/sharp-darwin-arm64")
        let sharpVipsRoot = root.appendingPathComponent("bot/node_modules/@img/sharp-libvips-darwin-arm64")
        guard fm.fileExists(atPath: sharpRoot.appendingPathComponent("package.json").path),
              fm.fileExists(atPath: sharpVipsRoot.appendingPathComponent("package.json").path),
              fm.fileExists(atPath: sharpRoot.appendingPathComponent("lib/sharp-darwin-arm64.node").path) else {
            throw RuntimeInstallError.verificationFailed(component: "backend", detail: "Missing host-native image addon or dependencies")
        }

        let checkHome = fm.temporaryDirectory.appendingPathComponent("lemon_bot_check_\(UUID().uuidString)")
        try fm.createDirectory(at: checkHome, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: checkHome) }

        let env = ["HOME": checkHome.path, "PATH": "/usr/bin:/bin"]
        let (status, outData, _) = try executeProcess(
            executable: botBin,
            arguments: ["--version"],
            environment: env,
            currentDirectory: checkHome,
            timeout: 15
        )

        guard status == 0 else {
            throw RuntimeInstallError.verificationFailed(component: "backend", detail: "lemon-bot --version returned status \(status)")
        }

        let outString = String(data: outData, encoding: .utf8) ?? ""
        let expected = "lemon-bot \(version)\n"
        guard outString == expected else {
            throw RuntimeInstallError.verificationFailed(component: "backend", detail: "lemon-bot --version reported '\(outString)'; expected '\(expected)'")
        }
    }

    private static func executeProcess(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL? = nil,
        timeout: TimeInterval
    ) throws -> (status: Int32, stdout: Data, stderr: Data) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let dir = currentDirectory {
            process.currentDirectoryURL = dir
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw RuntimeInstallError.verificationFailed(component: executable.lastPathComponent, detail: "Could not execute: \(error.localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            throw RuntimeInstallError.verificationFailed(component: executable.lastPathComponent, detail: "Execution timed out after \(timeout)s")
        }

        let stdoutData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, stdoutData, stderrData)
    }

    private static func atomicSymlink(target: String, link: URL) throws {
        let parentDir = link.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        let tmpLink = parentDir.appendingPathComponent(".tmp.\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString)")
        unlink(tmpLink.path)

        if symlink(target, tmpLink.path) != 0 {
            throw RuntimeInstallError.filesystem(detail: "symlink failed for \(tmpLink.lastPathComponent): errno \(errno)")
        }
        if rename(tmpLink.path, link.path) != 0 {
            unlink(tmpLink.path)
            throw RuntimeInstallError.filesystem(detail: "rename failed for symlink \(link.lastPathComponent): errno \(errno)")
        }
    }

    private static func removeQuarantine(at url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", url.path]
        try? process.run()
        process.waitUntilExit()
    }

    private final class HTTPSOnlyDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let url = request.url, url.scheme == "https" else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }
#endif
}
