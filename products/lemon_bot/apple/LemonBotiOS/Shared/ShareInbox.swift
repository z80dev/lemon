import Foundation
import UniformTypeIdentifiers

struct SharedFile: Codable, Identifiable {
    var id: String
    var filename: String
    var storedName: String
    var mime: String
    var size: Int64
    var uploadNonce: String
    var attachmentID: String?
    var error: String?
}

struct SharedCapture: Codable, Identifiable {
    var id: String
    var createdAt: Date
    var text: String
    var files: [SharedFile]
    var accountID: String?
    var workspaceID: String?
    var userID: String?
    var conversationID: String?
    var textApplied: Bool
    var error: String?
    var priorDraftText: String?
    var proposedDraftText: String?
}

/// A package is published only after all selected provider files have been copied.
/// No credentials or backend connections are available to the extension.
enum ShareInbox {
    static let groupID = "group.org.lemonbot.shared"

    static func root() throws -> URL {
        let container: URL
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            container = group
        } else if !Bundle.main.bundlePath.hasSuffix(".appex") {
            // Personal-team builds cannot sign App Groups. The app keeps camera/photo/file
            // staging in its own container; only the share extension handoff is unavailable.
            container = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        } else {
            throw CaptureError.message("Sharing into Lemon Bot needs the App Group \(groupID), which this build is not signed with. Open Lemon Bot and attach the file there instead.")
        }
        let root = container.appendingPathComponent("ShareInbox", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func begin() throws -> SharedCapture {
        let capture = SharedCapture(id: UUID().uuidString, createdAt: Date(), text: "", files: [], textApplied: false)
        try FileManager.default.createDirectory(at: directory(capture.id), withIntermediateDirectories: true)
        return capture
    }

    static func directory(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw CaptureError.message("Invalid local capture identifier.") }
        return try root().appendingPathComponent(id, isDirectory: true)
    }

    static func copy(_ source: URL, filename: String? = nil, mime: String? = nil, into capture: SharedCapture) throws -> SharedFile {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey])
        guard values.isRegularFile == true else { throw CaptureError.message("Select a regular file, not a folder or symbolic link.") }
        let name = String((filename ?? source.lastPathComponent).split(separator: "/").last ?? "attachment")
        let type = values.contentType ?? UTType(filenameExtension: source.pathExtension)
        let detectedMIME = mime ?? type?.preferredMIMEType ?? "application/octet-stream"
        let limit = detectedMIME.hasPrefix("video/") ? 200 * 1024 * 1024 : 25 * 1024 * 1024
        let size = Int64(values.fileSize ?? 0)
        guard size > 0, size <= limit else { throw CaptureError.message("\(name) must be nonempty and no larger than \(limit / 1024 / 1024) MiB.") }
        let id = UUID().uuidString
        let storedName = id + (source.pathExtension.isEmpty ? "" : "." + source.pathExtension)
        let destination = try directory(capture.id).appendingPathComponent(storedName)
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
        return SharedFile(id: id, filename: name, storedName: storedName, mime: detectedMIME, size: size, uploadNonce: UUID().uuidString)
    }

    static func save(_ capture: SharedCapture) throws {
        let data = try JSONEncoder().encode(capture)
        try data.write(to: directory(capture.id).appendingPathComponent("capture.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func captures() throws -> [SharedCapture] {
        let dirs = try FileManager.default.contentsOfDirectory(at: root(), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return try dirs.compactMap { directory in
            let manifest = directory.appendingPathComponent("capture.json")
            guard FileManager.default.fileExists(atPath: manifest.path) else { return nil }
            return try JSONDecoder().decode(SharedCapture.self, from: Data(contentsOf: manifest))
        }.sorted { $0.createdAt < $1.createdAt }
    }

    static func fileURL(_ file: SharedFile, in capture: SharedCapture) throws -> URL {
        guard file.storedName == URL(fileURLWithPath: file.storedName).lastPathComponent,
              !file.storedName.contains("..") else { throw CaptureError.message("Invalid staged filename.") }
        return try directory(capture.id).appendingPathComponent(file.storedName)
    }

    static func discard(_ capture: SharedCapture) throws {
        try FileManager.default.removeItem(at: directory(capture.id))
    }
}

enum CaptureError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}
