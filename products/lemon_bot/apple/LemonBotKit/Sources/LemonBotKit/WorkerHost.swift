#if os(macOS)
import Foundation
import AppKit

public enum MacPermission: String, Identifiable, Sendable {
    case screenRecording = "screen-recording"
    case accessibility
    public var id: String { rawValue }
}

public enum MacPermissionState: String, Sendable {
    case allowed = "Allowed", denied = "Not allowed", unchecked = "Not checked", offline = "Offline"
    public static func measure(grants: [String], stale: Bool) -> Self {
        if stale { return .offline }
        if grants.isEmpty || grants.contains("unknown") { return .unchecked }
        return grants.allSatisfy { $0 == "granted" } ? .allowed : .denied
    }
}
public enum WorkerHost {
    public static let bundleIdentifier = "org.lemonbot.mac.worker"
    /// Signed helper that owns macOS privacy grants for this Mac's worker. nil when absent (dev builds) or when the app is not in a stable location.
    public static func executableURL(appBundle: URL = Bundle.main.bundleURL, home: String = NSHomeDirectory()) -> URL? {
        let path = appBundle.standardizedFileURL.path
        guard (path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")), !path.contains("/AppTranslocation/") else { return nil }
        let helper = appBundle.appendingPathComponent("Contents/Helpers/Lemon Bot Worker.app", isDirectory: true)
        guard let bundle = Bundle(url: helper), bundle.bundleIdentifier == bundleIdentifier,
              let executable = bundle.executableURL, FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return executable
    }

    public static func appURL(appBundle: URL = Bundle.main.bundleURL, home: String = NSHomeDirectory()) -> URL? {
        guard executableURL(appBundle: appBundle, home: home) != nil else { return nil }
        return appBundle.appendingPathComponent("Contents/Helpers/Lemon Bot Worker.app", isDirectory: true)
    }

    @MainActor public static func request(_ service: MacPermission) async throws {
        guard let app = appURL() else { throw HostEnrollment.Failure.unexpected(detail: unavailableReason) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--request", service.rawValue]
        configuration.createsNewApplicationInstance = true
        _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
    }

    public static let unavailableReason = "Install Lemon Bot in Applications with its Lemon Bot Worker helper, then try again."

    public static func workerUnit(home: String = NSHomeDirectory()) -> (nodeName: String, wrapped: Bool)? {
        let directory = URL(fileURLWithPath: home).appendingPathComponent("Library/LaunchAgents")
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        let units = files.sorted { $0.path < $1.path }.compactMap { file -> (nodeName: String, wrapped: Bool)? in
            let name = file.lastPathComponent
            guard name.hasPrefix("org.lemon.node."), name.hasSuffix(".plist"),
                  let data = try? Data(contentsOf: file),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let arguments = plist["ProgramArguments"] as? [String], let program = arguments.first else { return nil }
            let node = String(name.dropFirst("org.lemon.node.".count).dropLast(".plist".count))
            guard !node.isEmpty else { return nil }
            var parent = URL(fileURLWithPath: program).deletingLastPathComponent()
            while parent.path != "/" {
                if parent.pathExtension == "app" {
                    return (node, Bundle(url: parent)?.bundleIdentifier == bundleIdentifier)
                }
                parent.deleteLastPathComponent()
            }
            return (node, false)
        }
        // Multiple local workers are ambiguous; never expose another machine's permissions.
        return units.count == 1 ? units[0] : nil
    }

    public static func canManage(nodeName: String, localNodeName: String?, role: String?) -> Bool {
        localNodeName == nodeName && ["owner", "admin"].contains(role ?? "")
    }

    public static func useForWorker() async throws {
        guard let wrapper = executableURL() else { throw HostEnrollment.Failure.unexpected(detail: unavailableReason) }
        let checkout = UserDefaults.standard.string(forKey: MachineBootstrap.checkoutDefaultsKey) ?? NSHomeDirectory() + "/lemon"
        let output = try await CommandRunner.script(HostEnrollment.setupScript, on: .thisMac, arguments: [checkout, wrapper.path], timeout: 600)
        _ = try BootstrapProgress.result(output).requireMachine(machine: "this Mac")
    }
}
#endif
