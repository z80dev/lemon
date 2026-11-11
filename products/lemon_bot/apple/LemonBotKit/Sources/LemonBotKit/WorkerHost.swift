#if os(macOS)
import Foundation
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
}
#endif
