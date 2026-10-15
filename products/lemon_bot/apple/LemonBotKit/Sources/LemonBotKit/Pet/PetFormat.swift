import CoreGraphics
import Foundation

/// Rows of the Codex desktop-pet atlas, in row order (openai/skills `hatch-pet` contract).
public enum PetAnimation: String, CaseIterable, Codable, Sendable {
    case idle
    case runningRight = "running-right"
    case runningLeft = "running-left"
    case waving, jumping, failed, waiting, running, review

    /// Zero-based atlas row.
    public var row: Int {
        switch self {
        case .idle: return 0
        case .runningRight: return 1
        case .runningLeft: return 2
        case .waving: return 3
        case .jumping: return 4
        case .failed: return 5
        case .waiting: return 6
        case .running: return 7
        case .review: return 8
        }
    }

    /// Contract frame timings in milliseconds for the recommended frame count.
    public var contractDurations: [Int] {
        switch self {
        case .idle: return [280, 110, 110, 140, 140, 320]
        case .runningRight, .runningLeft: return Array(repeating: 120, count: 7) + [220]
        case .waving: return [140, 140, 140, 280]
        case .jumping: return [140, 140, 140, 140, 280]
        case .failed: return Array(repeating: 140, count: 7) + [240]
        case .waiting: return Array(repeating: 150, count: 5) + [260]
        case .running: return Array(repeating: 120, count: 5) + [220]
        case .review: return Array(repeating: 150, count: 5) + [280]
        }
    }

    /// Timings for a row with `frameCount` frames: contract timings, with the row's final hold on the last frame.
    public func durations(frameCount: Int) -> [Int] {
        guard frameCount > 0 else { return [] }
        let contract = contractDurations
        var values = (0..<frameCount).map { contract[min($0, contract.count - 2)] }
        values[frameCount - 1] = contract[contract.count - 1]
        return values
    }
}

/// Codex atlas geometry. V1 has the nine animation rows; V2 adds two rows of 16 clockwise look directions.
public enum PetAtlasVersion: Int, Codable, Sendable {
    case v1 = 1
    case v2 = 2

    public static let columns = 8
    public static let cellWidth = 192
    public static let cellHeight = 208

    public var rows: Int { self == .v1 ? 9 : 11 }
    public var pixelWidth: Int { Self.columns * Self.cellWidth }
    public var pixelHeight: Int { rows * Self.cellHeight }
}

/// Codex `pet.json`. Field validation (lengths, identifiers, paths) belongs to package import.
public struct PetManifest: Codable, Hashable, Sendable {
    public var id: String
    public var displayName: String
    public var description: String
    public var spritesheetPath: String
    public var spriteVersionNumber: Int?

    public init(id: String, displayName: String, description: String, spritesheetPath: String, spriteVersionNumber: Int? = nil) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.spritesheetPath = spritesheetPath
        self.spriteVersionNumber = spriteVersionNumber
    }

    /// Omitted or `1` is V1, `2` is V2; any other value is unsupported (nil).
    public var atlasVersion: PetAtlasVersion? {
        switch spriteVersionNumber {
        case nil, 1: return .v1
        case 2: return .v2
        default: return nil
        }
    }
}

public enum PetFormatError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case atlasSize(expectedWidth: Int, expectedHeight: Int, width: Int, height: Int)
    case emptyAnimation(PetAnimation)
    case unreadableAtlas

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let value):
            return "This pet uses sprite version \(value). Lemon Bot supports Codex pet versions 1 and 2."
        case let .atlasSize(expectedWidth, expectedHeight, width, height):
            return "The spritesheet is \(width)×\(height) pixels; this pet version requires exactly \(expectedWidth)×\(expectedHeight)."
        case .emptyAnimation(let animation):
            return "The spritesheet has no frames for the “\(animation.rawValue)” animation."
        case .unreadableAtlas:
            return "The spritesheet image couldn't be read."
        }
    }
}

/// A validated pet ready to draw. Frames are cropped from the atlas once; crops share its pixel storage.
public final class PetSprite: @unchecked Sendable {
    public let manifest: PetManifest
    public let version: PetAtlasVersion
    /// Consecutive non-empty frames from column 0 for each animation; never empty.
    public let frames: [PetAnimation: [CGImage]]
    /// V2 only: 16 entries, index 0 = up (12 o'clock), clockwise in 22.5° steps; nil where the cell is empty.
    public let lookFrames: [CGImage?]

    public init(manifest: PetManifest, atlas: CGImage) throws {
        guard let version = manifest.atlasVersion else { throw PetFormatError.unsupportedVersion(manifest.spriteVersionNumber ?? 0) }
        guard atlas.width == version.pixelWidth, atlas.height == version.pixelHeight else {
            throw PetFormatError.atlasSize(expectedWidth: version.pixelWidth, expectedHeight: version.pixelHeight, width: atlas.width, height: atlas.height)
        }
        let alpha = try Self.alphaPlane(atlas)
        let cellWidth = PetAtlasVersion.cellWidth, cellHeight = PetAtlasVersion.cellHeight
        func cell(_ row: Int, _ column: Int) -> CGImage? {
            let x0 = column * cellWidth, y0 = row * cellHeight
            var occupied = false
            scan: for y in y0..<(y0 + cellHeight) {
                let base = y * atlas.width
                for x in x0..<(x0 + cellWidth) where alpha[base + x] > 8 { occupied = true; break scan }
            }
            guard occupied else { return nil }
            return atlas.cropping(to: CGRect(x: x0, y: y0, width: cellWidth, height: cellHeight))
        }
        var frames: [PetAnimation: [CGImage]] = [:]
        for animation in PetAnimation.allCases {
            var row: [CGImage] = []
            for column in 0..<PetAtlasVersion.columns {
                guard let image = cell(animation.row, column) else { break }
                row.append(image)
            }
            guard !row.isEmpty else { throw PetFormatError.emptyAnimation(animation) }
            frames[animation] = row
        }
        var look: [CGImage?] = []
        if version == .v2 {
            for index in 0..<16 { look.append(cell(9 + index / PetAtlasVersion.columns, index % PetAtlasVersion.columns)) }
        }
        self.manifest = manifest
        self.version = version
        self.frames = frames
        self.lookFrames = look
    }

    public func frames(for animation: PetAnimation) -> [CGImage] { frames[animation] ?? [] }

    /// Look frame for a pointer direction in degrees (0 = up, clockwise), or nil for V1/missing cells.
    public func lookFrame(degrees: Double) -> CGImage? {
        guard lookFrames.count == 16 else { return nil }
        let normalized = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return lookFrames[Int((normalized / 22.5).rounded()) % 16]
    }

    /// Top-down 8-bit alpha plane of the atlas.
    private static func alphaPlane(_ image: CGImage) throws -> [UInt8] {
        var plane = [UInt8](repeating: 0, count: image.width * image.height)
        let drawn = plane.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { throw PetFormatError.unreadableAtlas }
        return plane
    }
}

/// What the pet is expressing about Lemon Bot's live state.
public enum PetMood: String, CaseIterable, Codable, Sendable {
    case idle, thinking, working, needsInput, done, failed, offline, signedOut

    public var animation: PetAnimation {
        switch self {
        case .idle, .signedOut: return .idle
        case .thinking: return .review
        case .working: return .running
        case .needsInput: return .waiting
        case .done: return .jumping
        case .failed, .offline: return .failed
        }
    }
}

/// One derived pet presentation. Equality drives redraws; `validUntil` asks the owner to re-derive.
public struct PetStatus: Equatable, Sendable {
    public var mood: PetMood
    /// Short speech-bubble text shown without hovering (attention, completion, errors, connection).
    public var bubble: String?
    /// Longer hover text, e.g. "Atlas · Running shell command".
    public var detail: String?
    /// `lemonbot://workspace/...` link a click opens; nil opens the main window.
    public var deepLink: URL?
    /// When a transient mood (done/failed) expires.
    public var validUntil: Date?

    public init(mood: PetMood, bubble: String? = nil, detail: String? = nil, deepLink: URL? = nil, validUntil: Date? = nil) {
        self.mood = mood
        self.bubble = bubble
        self.detail = detail
        self.deepLink = deepLink
        self.validUntil = validUntil
    }
}
