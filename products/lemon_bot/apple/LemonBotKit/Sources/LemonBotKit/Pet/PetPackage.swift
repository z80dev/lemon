import Foundation
import ImageIO

public enum PetPackageError: LocalizedError, Equatable {
    case invalid(String)
    case tooLarge(String)
    case builtIn

    public var errorDescription: String? {
        switch self {
        case .invalid(let message), .tooLarge(let message): return message
        case .builtIn: return "The bundled lemon pet can't be removed. Choose an imported pet to remove instead."
        }
    }
}

/// Untrusted packages are data only: JSON and a dimension-checked PNG/WebP, never executable code.
enum PetPackage {
    static let downloadLimit = 20 * 1024 * 1024
    static let manifestLimit = 64 * 1024
    static let expandedLimit = 32 * 1024 * 1024

    static func relativePath(_ path: String) throws -> String {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.contains("\\"), !path.contains(":"), !path.contains("\0"),
              pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw PetPackageError.invalid("The pet contains an unsafe path. Lemon Bot expects relative paths inside the pet folder, without '..' or URLs.")
        }
        return path
    }

    static func read(_ url: URL, limit: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
            throw PetPackageError.invalid("The pet contains a link or a non-file. Lemon Bot expects regular pet.json and image files.")
        }
        guard (values.fileSize ?? 0) <= limit else { throw sizeError(limit) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw sizeError(limit) }
        return data
    }

    static func sizeError(_ limit: Int) -> PetPackageError {
        .tooLarge(limit == manifestLimit ? "The pet.json is too large. Lemon Bot expects a manifest no larger than 64 KiB." : "This pet download or spritesheet is too large. Lemon Bot expects no more than 20 MiB.")
    }

    static func manifest(_ data: Data, fallbackName: String) throws -> PetManifest {
        guard data.count <= manifestLimit else { throw sizeError(manifestLimit) }
        var value: PetManifest
        do { value = try JSONDecoder().decode(PetManifest.self, from: data) }
        catch { throw PetPackageError.invalid("The pet.json couldn't be read. Lemon Bot expects a JSON object with id, displayName, description and spritesheetPath.") }
        value.displayName = value.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...64).contains(value.displayName.count) else {
            throw PetPackageError.invalid("The pet needs a displayName between 1 and 64 characters.")
        }
        value.description = String(value.description.prefix(280))
        let lower = value.id.lowercased()
        if lower.range(of: "^[a-z0-9][a-z0-9._-]{0,63}$", options: .regularExpression) != nil { value.id = lower }
        else {
            func slug(_ text: String) -> String {
                let ascii = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
                return String(ascii.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(64))
            }
            value.id = slug(value.displayName)
            if value.id.isEmpty { value.id = slug(fallbackName) }
            guard !value.id.isEmpty else { throw PetPackageError.invalid("The pet needs a name containing a letter or number so Lemon Bot can give it a safe identifier.") }
        }
        _ = try relativePath(value.spritesheetPath)
        guard value.atlasVersion != nil else { throw PetFormatError.unsupportedVersion(value.spriteVersionNumber ?? 0) }
        return value
    }

    static func imageExtension(_ data: Data) throws -> String {
        if data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) { return "png" }
        if data.count >= 12, data.prefix(4) == Data("RIFF".utf8), data[8..<12] == Data("WEBP".utf8) { return "webp" }
        throw PetPackageError.invalid("The spritesheet isn't a PNG or WebP image. Lemon Bot checks the file contents, not just its extension.")
    }

    static func sprite(manifest: PetManifest, sheet: Data) throws -> PetSprite {
        guard sheet.count <= downloadLimit else { throw sizeError(downloadLimit) }
        _ = try imageExtension(sheet)
        guard let version = manifest.atlasVersion else { throw PetFormatError.unsupportedVersion(manifest.spriteVersionNumber ?? 0) }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(sheet as CFData, options),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw PetFormatError.unreadableAtlas }
        guard width == version.pixelWidth, height == version.pixelHeight else {
            throw PetFormatError.atlasSize(expectedWidth: version.pixelWidth, expectedHeight: version.pixelHeight, width: width, height: height)
        }
        guard let atlas = CGImageSourceCreateImageAtIndex(source, 0, options) else { throw PetFormatError.unreadableAtlas }
        return try PetSprite(manifest: manifest, atlas: atlas)
    }
}
