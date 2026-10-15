import Darwin
import Foundation

public struct InstalledPet: Identifiable, Hashable, Sendable {
    public var id: String { manifest.id }
    public let manifest: PetManifest
    public let directory: URL
    public let isBuiltIn: Bool

    public init(manifest: PetManifest, directory: URL, isBuiltIn: Bool) {
        self.manifest = manifest; self.directory = directory; self.isBuiltIn = isBuiltIn
    }
}

/// Imports Codex pet packages without running code or writing any archive-supplied paths.
public final class PetLibrary {
    public static let defaultPetID = "lemon"
    public static var bundledPetsDirectory: URL { Bundle.module.resourceURL!.appendingPathComponent("Pets", isDirectory: true) }
    private let root: URL
    private let builtInDirectory: URL?
    private let fm = FileManager.default

    public static func defaultRoot() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = support.appendingPathComponent("Lemon Bot/Pets", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    public init(root: URL, builtInDirectory: URL? = PetLibrary.bundledPetsDirectory) {
        self.root = root; self.builtInDirectory = builtInDirectory
    }

    public func installedPets() -> [InstalledPet] {
        func pets(_ directory: URL?, builtIn: Bool) -> [InstalledPet] {
            guard let directory, let children = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return [] }
            return children.compactMap { child in
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isDirectory == true, values.isSymbolicLink != true,
                      let manifest = try? folderManifest(child) else { return nil }
                let pet = InstalledPet(manifest: manifest, directory: child, isBuiltIn: builtIn)
                guard (try? loadSprite(pet)) != nil else { return nil }
                return pet
            }.sorted { $0.manifest.displayName.localizedStandardCompare($1.manifest.displayName) == .orderedAscending }
        }
        return pets(builtInDirectory, builtIn: true) + pets(root, builtIn: false)
    }

    public func loadSprite(_ pet: InstalledPet) throws -> PetSprite {
        let sheet = try sheetURL(pet.manifest.spritesheetPath, in: pet.directory)
        return try PetPackage.sprite(manifest: pet.manifest, sheet: PetPackage.read(sheet, limit: PetPackage.downloadLimit))
    }

    public func importPackage(at url: URL) throws -> [InstalledPet] {
        guard url.isFileURL else { throw PetPackageError.invalid("Choose a local pet folder, pet.json or ZIP, or import an HTTPS URL.") }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw PetPackageError.invalid("The selected pet is a symbolic link. Choose the actual pet folder or file.") }
        if values.isDirectory == true {
            if fm.fileExists(atPath: url.appendingPathComponent("pet.json").path) { return [try importFolder(url)] }
            let children = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]).sorted { $0.lastPathComponent < $1.lastPathComponent }
            let folders = try children.filter { child in
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values.isDirectory == true && values.isSymbolicLink != true && fm.fileExists(atPath: child.appendingPathComponent("pet.json").path)
            }
            guard !folders.isEmpty else { throw PetPackageError.invalid("This folder doesn't contain a pet.json or any pet folders. Choose a Codex pet package or your pets folder.") }
            return try folders.map(importFolder)
        }
        if url.lastPathComponent == "pet.json" { return [try importFolder(url.deletingLastPathComponent())] }
        if url.pathExtension.lowercased() == "zip" { return [try importPackage(zipData: PetPackage.read(url, limit: PetPackage.downloadLimit))] }
        throw PetPackageError.invalid("Choose a pet folder, a pet.json file or a .zip package. Lemon Bot doesn't run pet installers.")
    }

    public func importPackage(zipData: Data) throws -> InstalledPet {
        let files = try PetZip.files(zipData)
        let manifestPath: String
        if files["pet.json"] != nil { manifestPath = "pet.json" }
        else {
            let candidates = files.keys.filter { $0.split(separator: "/").count == 2 && $0.hasSuffix("/pet.json") }
            guard candidates.count == 1, let candidate = candidates.first,
                  files.keys.allSatisfy({ $0.hasPrefix(String(candidate.dropLast("pet.json".count))) }) else {
                throw PetPackageError.invalid("This ZIP doesn't contain a pet.json at its root or inside exactly one enclosing folder. Choose a ZIP containing one Codex pet.")
            }
            manifestPath = candidate
        }
        let prefix = String(manifestPath.dropLast("pet.json".count))
        let manifest = try PetPackage.manifest(files[manifestPath]!, fallbackName: String(prefix.dropLast()))
        guard let sheet = files[prefix + manifest.spritesheetPath] else { throw PetPackageError.invalid("The ZIP is missing the spritesheet named in pet.json. Include that PNG or WebP inside the same package.") }
        return try install(manifest, sheet: sheet)
    }

    public func importPackage(from remote: URL, session: URLSession = .shared) async throws -> InstalledPet {
        guard remote.scheme?.lowercased() == "https", remote.host != nil, remote.user == nil, remote.password == nil else {
            throw PetPackageError.invalid("Use an HTTPS URL to a pet ZIP or pet.json. HTTP, file URLs and other schemes aren't accepted for remote pets.")
        }
        if remote.pathExtension.lowercased() == "zip" {
            return try importPackage(zipData: await download(remote, limit: PetPackage.downloadLimit, session: session))
        }
        guard remote.lastPathComponent == "pet.json" else { throw PetPackageError.invalid("The HTTPS URL must point to a .zip or pet.json file, not a gallery page or installer.") }
        let data = try await download(remote, limit: PetPackage.manifestLimit, session: session)
        let manifest = try PetPackage.manifest(data, fallbackName: remote.deletingLastPathComponent().lastPathComponent)
        // Append components as literal filenames, not a URL reference (which could contain a query or fragment).
        let sheet = remote.deletingLastPathComponent().appendingPathComponent(manifest.spritesheetPath)
        guard PetDownloadPolicy.sameOrigin(remote, sheet) else { throw PetPackageError.invalid("The spritesheet must be on the same HTTPS origin as pet.json.") }
        return try install(manifest, sheet: await download(sheet, limit: PetPackage.downloadLimit, session: session))
    }

    public func remove(_ pet: InstalledPet) throws {
        guard !pet.isBuiltIn else { throw PetPackageError.builtIn }
        let destination = root.appendingPathComponent(pet.id, isDirectory: true).standardizedFileURL
        guard pet.directory.standardizedFileURL == destination, (try? PetPackage.relativePath(pet.id)) == pet.id else {
            throw PetPackageError.invalid("Only pets installed in Lemon Bot's pet library can be removed.")
        }
        try fm.removeItem(at: destination)
    }

    private func folderManifest(_ directory: URL) throws -> PetManifest {
        try PetPackage.manifest(PetPackage.read(directory.appendingPathComponent("pet.json"), limit: PetPackage.manifestLimit), fallbackName: directory.lastPathComponent)
    }

    private func sheetURL(_ path: String, in directory: URL) throws -> URL {
        _ = try PetPackage.relativePath(path)
        var url = directory
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw PetPackageError.invalid("The spritesheet path contains a symbolic link. Keep the image inside the pet package.")
            }
        }
        return url
    }

    private func importFolder(_ directory: URL) throws -> InstalledPet {
        let manifest = try folderManifest(directory)
        let sheet = try PetPackage.read(sheetURL(manifest.spritesheetPath, in: directory), limit: PetPackage.downloadLimit)
        return try install(manifest, sheet: sheet)
    }

    private func install(_ input: PetManifest, sheet: Data) throws -> InstalledPet {
        _ = try PetPackage.sprite(manifest: input, sheet: sheet)
        var manifest = input
        let builtInIDs: Set<String> = Set((try? builtInDirectory.map { try fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil).compactMap { try? folderManifest($0).id } }) ?? [])
        if builtInIDs.contains(manifest.id) { manifest.id = String(manifest.id.prefix(55)) + "-imported" }
        manifest.spritesheetPath = "spritesheet." + (try PetPackage.imageExtension(sheet))
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".import-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("pet.json"), options: .atomic)
        try sheet.write(to: staging.appendingPathComponent(manifest.spritesheetPath), options: .atomic)
        let destination = root.appendingPathComponent(manifest.id, isDirectory: true)
        if fm.fileExists(atPath: destination.path) {
            guard try destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isSymbolicLink != true else { throw PetPackageError.invalid("The installed pet path is a symbolic link. Remove the link before importing this pet.") }
            let result = staging.withUnsafeFileSystemRepresentation { source in destination.withUnsafeFileSystemRepresentation { target in renameatx_np(AT_FDCWD, source!, AT_FDCWD, target!, UInt32(RENAME_SWAP)) } }
            guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        } else { try fm.moveItem(at: staging, to: destination) }
        return InstalledPet(manifest: manifest, directory: destination, isBuiltIn: false)
    }

    private func download(_ url: URL, limit: Int, session: URLSession) async throws -> Data {
        let policy = PetDownloadPolicy(origin: url)
        let (bytes, response) = try await session.bytes(for: URLRequest(url: url), delegate: policy)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              let finalURL = response.url, PetDownloadPolicy.sameOrigin(url, finalURL) else { throw PetPackageError.invalid("The pet couldn't be downloaded from that HTTPS origin. Choose a direct, accessible ZIP or pet.json URL.") }
        guard response.expectedContentLength <= limit else { throw PetPackage.sizeError(limit) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw PetPackage.sizeError(limit) }
            data.append(byte)
        }
        return data
    }
}

private final class PetDownloadPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let origin: URL
    init(origin: URL) { self.origin = origin }
    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        rhs.scheme?.lowercased() == "https" && lhs.host?.lowercased() == rhs.host?.lowercased() && (lhs.port ?? 443) == (rhs.port ?? 443) && rhs.user == nil && rhs.password == nil
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map { Self.sameOrigin(origin, $0) } == true ? request : nil)
    }
}
