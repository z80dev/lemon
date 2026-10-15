import Compression
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LemonBotKit

final class PetPackageTests: XCTestCase {
    private var temporary: URL!
    private var library: PetLibrary!
    private static let v1 = try! atlas(.v1)
    private static let v2 = try! atlas(.v2)

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("PetPackageTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        library = PetLibrary(root: temporary.appendingPathComponent("installed"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    private func manifest(id: String = "test", name: String = "Test", path: String = "sheet.png", version: Int = 1) throws -> Data {
        try JSONEncoder().encode(PetManifest(id: id, displayName: name, description: String(repeating: "x", count: 300), spritesheetPath: path, spriteVersionNumber: version))
    }
    private func folder(_ name: String = "source", id: String = "test", version: Int = 1) throws -> URL {
        let directory = temporary.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try manifest(id: id, version: version).write(to: directory.appendingPathComponent("pet.json"))
        try (version == 1 ? Self.v1 : Self.v2).write(to: directory.appendingPathComponent("sheet.png"))
        return directory
    }

    func testFolderManifestAndCollectionImportReplaceAndRemove() throws {
        let directory = try folder()
        let first = try XCTUnwrap(library.importPackage(at: directory).first)
        XCTAssertEqual(first.manifest.description.count, 280)
        XCTAssertEqual(first.manifest.spritesheetPath, "spritesheet.png")
        XCTAssertEqual(try library.loadSprite(first).version, .v1)
        let second = try XCTUnwrap(library.importPackage(at: directory.appendingPathComponent("pet.json")).first)
        XCTAssertEqual(second.directory, first.directory)
        let collection = temporary.appendingPathComponent("collection")
        try FileManager.default.createDirectory(at: collection, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: directory, to: collection.appendingPathComponent("one"))
        XCTAssertEqual(try library.importPackage(at: collection).map(\.id), ["test"])
        XCTAssertEqual(library.installedPets().filter { !$0.isBuiltIn }.count, 1)
        try library.remove(second)
        XCTAssertTrue(library.installedPets().allSatisfy(\.isBuiltIn))
    }

    func testStoredRootAndDeflatedEnclosingZIPImports() throws {
        for prefix in ["", "buddy/"] {
            let data = try zip([(prefix + "pet.json", manifest()), (prefix + "sheet.png", Self.v1), ("__MACOSX/ignored", Data()), (".DS_Store", Data())], deflated: !prefix.isEmpty)
            let pet = try library.importPackage(zipData: data)
            XCTAssertEqual(try library.loadSprite(pet).version, .v1)
        }
        let url = temporary.appendingPathComponent("pet.zip")
        try zip([("pet.json", manifest()), ("sheet.png", Self.v1)]).write(to: url)
        XCTAssertEqual(try library.importPackage(at: url).count, 1)
    }

    func testManifestNormalizationAndBuiltInCollision() throws {
        let upper = try library.importPackage(zipData: zip([("pet.json", manifest(id: "UPPER.Safe_1")), ("sheet.png", Self.v1)]))
        XCTAssertEqual(upper.id, "upper.safe_1")
        let slug = try library.importPackage(zipData: zip([("pet.json", manifest(id: "../bad", name: "Café Buddy!")), ("sheet.png", Self.v1)]))
        XCTAssertEqual(slug.id, "cafe-buddy")
        let collision = try library.importPackage(at: folder("lemon-source", id: "lemon"))
        XCTAssertEqual(collision.first?.id, "lemon-imported")
        XCTAssertTrue(collision.allSatisfy { !$0.isBuiltIn })
        XCTAssertThrowsError(try PetPackage.manifest(manifest(name: ""), fallbackName: "x"))
        XCTAssertThrowsError(try PetPackage.manifest(manifest(name: String(repeating: "a", count: 65)), fallbackName: "x"))
        XCTAssertThrowsError(try PetPackage.manifest(manifest(id: "?", name: "🍋"), fallbackName: "🍋"))
        let fallback = try PetPackage.manifest(manifest(id: "?", name: "🍋"), fallbackName: "folder-name")
        XCTAssertEqual(fallback.id, "folder-name")
    }

    func testBundledOriginalLemonHasAllAnimationsAndLookDirections() throws {
        let lemon = try XCTUnwrap(library.installedPets().first { $0.id == "lemon" && $0.isBuiltIn })
        let sprite = try library.loadSprite(lemon)
        XCTAssertEqual(sprite.version, .v2)
        XCTAssertEqual(PetAnimation.allCases.map { sprite.frames(for: $0).count }, [6, 8, 8, 4, 5, 8, 6, 6, 6])
        XCTAssertEqual(sprite.lookFrames.compactMap { $0 }.count, 16)
        XCTAssertThrowsError(try library.remove(lemon))
    }

    func testBundledLemonIsCC0AndItsShareableZIPImports() throws {
        let lemon = try XCTUnwrap(library.installedPets().first { $0.id == "lemon" && $0.isBuiltIn })
        let files = try ["pet.json", "spritesheet.png", "LICENSE"].map { ($0, try Data(contentsOf: lemon.directory.appendingPathComponent($0))) }
        XCTAssertTrue(String(decoding: files[2].1, as: UTF8.self).contains("SPDX-License-Identifier: CC0-1.0"))
        // The gallery ZIP layout (root pet.json, sheet and LICENSE) imports; extra files are ignored.
        let imported = try library.importPackage(zipData: zip(files, deflated: true))
        XCTAssertEqual(imported.id, "lemon-imported")
        XCTAssertEqual(try library.loadSprite(imported).version, .v2)
    }

    func testImageMagicDimensionsVersionAndEmptyRowsAreRejected() throws {
        XCTAssertThrowsError(try PetPackage.sprite(manifest: PetPackage.manifest(manifest(), fallbackName: "test"), sheet: Data("not a PNG".utf8)))
        let v2Manifest = try PetPackage.manifest(manifest(version: 2), fallbackName: "test")
        XCTAssertThrowsError(try PetPackage.sprite(manifest: v2Manifest, sheet: Self.v1))
        XCTAssertThrowsError(try PetPackage.sprite(manifest: v2Manifest, sheet: Self.atlas(.v2, counts: Array(repeating: 0, count: 11))))
        XCTAssertThrowsError(try PetPackage.manifest(manifest(version: 3), fallbackName: "test"))
        XCTAssertThrowsError(try PetPackage.sprite(manifest: v2Manifest, sheet: Self.atlas(.v2, width: 10, height: 10)))
        let pet = try library.importPackage(at: folder(version: 2))[0]
        XCTAssertEqual(try library.loadSprite(pet).version, .v2)
    }

    func testSizeLimitsAreEnforcedBeforeInstallation() throws {
        XCTAssertThrowsError(try library.importPackage(zipData: Data(count: PetPackage.downloadLimit + 1)))
        XCTAssertThrowsError(try PetPackage.manifest(Data(repeating: 32, count: PetPackage.manifestLimit + 1), fallbackName: "test"))
        let directory = try folder()
        try Data(count: PetPackage.downloadLimit + 1).write(to: directory.appendingPathComponent("sheet.png"))
        XCTAssertThrowsError(try library.importPackage(at: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.appendingPathComponent("installed/test").path))
    }

    func testUnsafePathsSymlinksDuplicatesEncryptionAndArchivesAreRejected() throws {
        for name in ["../escape", "/absolute", "a/../escape", "C:/escape", "a\\escape", "./pet.json"] {
            XCTAssertThrowsError(try library.importPackage(zipData: zip([(name, Data())])))
        }
        for path in ["../sheet.png", "/sheet.png", "https://evil/sheet.png", "a/../../sheet.png"] {
            XCTAssertThrowsError(try PetPackage.manifest(manifest(path: path), fallbackName: "test"))
        }
        XCTAssertThrowsError(try PetZip.files(zip([("same", Data()), ("same", Data())])))
        XCTAssertThrowsError(try PetZip.files(zip([("A", Data()), ("a", Data())])))
        XCTAssertThrowsError(try PetZip.files(zip([("link", Data())], attributes: 0xa1ff0000)))
        XCTAssertThrowsError(try PetZip.files(zip([("secret", Data())], flags: 1)))
        XCTAssertThrowsError(try PetZip.files(zip([("nested.zip", Data())])))
        let directory = try folder()
        try FileManager.default.removeItem(at: directory.appendingPathComponent("sheet.png"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("sheet.png"), withDestinationURL: temporary.appendingPathComponent("outside"))
        XCTAssertThrowsError(try library.importPackage(at: directory))
    }

    func testZIPBombEntryCountCorruptionAndLayoutAreRejected() throws {
        let bomb = Data(repeating: 0, count: PetPackage.expandedLimit + 1)
        XCTAssertThrowsError(try PetZip.files(zip([("bomb", bomb)], deflated: true, claimedSize: 1))) { error in
            XCTAssertTrue(error.localizedDescription.contains("32 MiB"))
        }
        XCTAssertThrowsError(try PetZip.files(zip((0..<65).map { ("file\($0)", Data()) })))
        var corrupt = try zip([("pet.json", manifest()), ("sheet.png", Self.v1)])
        corrupt[30 + "pet.json".utf8.count] ^= 1
        XCTAssertThrowsError(try PetZip.files(corrupt))
        XCTAssertThrowsError(try library.importPackage(zipData: zip([("a/b/pet.json", manifest()), ("a/b/sheet.png", Self.v1)])))
        XCTAssertThrowsError(try library.importPackage(zipData: zip([("a/pet.json", manifest()), ("b/pet.json", manifest())])))
        XCTAssertThrowsError(try library.importPackage(zipData: zip([("readme", Data())])))
    }

    func testZIPIntegrityAndExpansionBoundaries() throws {
        XCTAssertEqual(PetZip.crc32(Data("123456789".utf8)), 0xcbf43926)
        XCTAssertEqual(try PetZip.files(zip((0..<64).map { ("file\($0)", Data()) })).count, 64)
        let half = Data(repeating: 0, count: PetPackage.expandedLimit / 2 + 1)
        XCTAssertThrowsError(try PetZip.files(zip([("first", half), ("second", half)], deflated: true))) { error in
            XCTAssertTrue(error.localizedDescription.contains("32 MiB"))
        }
        let signatures: [[UInt8]] = [[0x50, 0x4b, 0x05, 0x06], [0x1f, 0x8b], [0x42, 0x5a, 0x68], [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00], [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c]]
        for bytes in signatures {
            XCTAssertThrowsError(try PetZip.files(zip([("disguised.bin", Data(bytes))])))
        }
    }

    func testSpriteFrameCountingTimingAndLookFrames() throws {
        let counts = [2, 8, 7, 4, 5, 8, 6, 6, 6, 8, 8]
        let manifest = try PetPackage.manifest(self.manifest(version: 2), fallbackName: "test")
        let sprite = try PetPackage.sprite(manifest: manifest, sheet: Self.atlas(.v2, counts: counts))
        XCTAssertEqual(PetAnimation.allCases.map { sprite.frames(for: $0).count }, Array(counts.prefix(9)))
        XCTAssertEqual(PetAnimation.idle.durations(frameCount: 2), [280, 320])
        XCTAssertEqual(PetAnimation.waving.durations(frameCount: 4), [140, 140, 140, 280])
        XCTAssertEqual(PetAnimation.running.durations(frameCount: 1), [220])
        XCTAssertEqual(PetAnimation.review.durations(frameCount: 0), [])
        XCTAssertNotNil(sprite.lookFrame(degrees: 0)); XCTAssertNotNil(sprite.lookFrame(degrees: 360)); XCTAssertNotNil(sprite.lookFrame(degrees: -22.5))
        let v1 = try PetPackage.sprite(manifest: PetPackage.manifest(self.manifest(), fallbackName: "test"), sheet: Self.v1)
        XCTAssertNil(v1.lookFrame(degrees: 0))
    }

    func testRemoteRejectsNonHTTPSAndNonPackageURLs() async throws {
        for string in ["http://example.com/pet.zip", "file:///tmp/pet.zip", "ftp://example.com/pet.zip", "https://user:pw@example.com/pet.zip"] {
            do { _ = try await library.importPackage(from: URL(string: string)!); XCTFail("Accepted \(string)") }
            catch { XCTAssertTrue(error is PetPackageError) }
        }
    }

    func testRemoteHTTPSManifestAndZIPAndBoundedResponses() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PetPackageURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); PetPackageURLProtocol.responses = [:] }
        PetPackageURLProtocol.responses = [
            "/buddy/pet.json": (try manifest(), nil, nil),
            "/buddy/sheet.png": (Self.v1, nil, nil),
            "/buddy.zip": (try zip([("pet.json", manifest()), ("sheet.png", Self.v1)], deflated: true), nil, nil),
            "/api/download/buddy": (try zip([("pet.json", manifest()), ("sheet.png", Self.v1)]), nil, nil),
            "/gallery": (Data("<!doctype html><title>Pets</title>".utf8), nil, nil)
        ]
        let manifestPet = try await library.importPackage(from: URL(string: "https://pets.example/buddy/pet.json")!, session: session)
        XCTAssertEqual(manifestPet.id, "test")
        let zipPet = try await library.importPackage(from: URL(string: "https://pets.example/buddy.zip")!, session: session)
        XCTAssertEqual(try library.loadSprite(zipPet).version, .v1)
        let endpointPet = try await library.importPackage(from: URL(string: "https://pets.example/api/download/buddy")!, session: session)
        XCTAssertEqual(endpointPet.id, "test")
        do { _ = try await library.importPackage(from: URL(string: "https://pets.example/gallery")!, session: session); XCTFail("Accepted a gallery page") }
        catch { XCTAssertTrue(error is PetPackageError) }
        let responses: [(Data, Int?, URL?)] = [
            (Data(), PetPackage.manifestLimit + 1, nil),
            (Data(repeating: 32, count: PetPackage.manifestLimit + 1), nil, nil),
            (try manifest(), nil, URL(string: "https://different.example/pet.json"))
        ]
        for response in responses {
            PetPackageURLProtocol.responses["/buddy/pet.json"] = response
            do {
                _ = try await library.importPackage(from: URL(string: "https://pets.example/buddy/pet.json")!, session: session)
                XCTFail("Accepted an oversized or cross-origin response")
            } catch { XCTAssertTrue(error is PetPackageError) }
        }
    }

    func testInvalidImportsPreservePreviousPetAndIgnoreInvalidInstalledFolders() throws {
        let pet = try library.importPackage(at: folder())[0]
        let directory = try folder("bad")
        try Data("invalid".utf8).write(to: directory.appendingPathComponent("sheet.png"))
        XCTAssertThrowsError(try library.importPackage(at: directory))
        XCTAssertEqual(try library.loadSprite(pet).version, .v1)
        let broken = pet.directory.deletingLastPathComponent().appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: broken.appendingPathComponent("pet.json"))
        XCTAssertEqual(library.installedPets().filter { !$0.isBuiltIn }.map(\.id), ["test"])
        let validZip = try zip([("pet.json", manifest()), ("sheet.png", Self.v1)])
        var prefixed = Data([0]); prefixed.append(validZip)
        XCTAssertEqual(try library.importPackage(zipData: prefixed.dropFirst()).id, "test")
    }

    private static func atlas(_ version: PetAtlasVersion, counts: [Int]? = nil, width: Int? = nil, height: Int? = nil) throws -> Data {
        let w = width ?? version.pixelWidth, h = height ?? version.pixelHeight
        let context = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.1, alpha: 1))
        for row in 0..<version.rows {
            for column in 0..<(counts?[row] ?? 8) {
                context.fill(CGRect(x: column * 192 + 80, y: h - row * 208 - 110, width: 20, height: 20))
            }
        }
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// Minimal test ZIP writer using raw DEFLATE, with independently emitted local and central headers.
    private func zip(_ entries: [(String, Data)], deflated: Bool = false, attributes: UInt32 = 0, flags: UInt16 = 0, claimedSize: Int? = nil) throws -> Data {
        var result = Data(), directory = Data()
        func integer<T: FixedWidthInteger>(_ value: T, into data: inout Data) { var le = value.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        for (name, input) in entries {
            let bytes = Data(name.utf8), offset = result.count
            let compressed: Data
            if deflated {
                var buffer = [UInt8](repeating: 0, count: input.count + input.count / 8 + 1024)
                let size = input.withUnsafeBytes { source in
                    buffer.withUnsafeMutableBufferPointer { destination in
                        compression_encode_buffer(destination.baseAddress!, destination.count, source.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB)
                    }
                }
                guard size > 0 else { throw PetPackageError.invalid("Test ZIP compression failed") }
                compressed = Data(buffer.prefix(size))
            } else { compressed = input }
            let method: UInt16 = deflated ? 8 : 0, crc = PetZip.crc32(input), expanded = UInt32(claimedSize ?? input.count)
            integer(UInt32(0x04034b50), into: &result); integer(UInt16(20), into: &result); integer(flags, into: &result); integer(method, into: &result)
            integer(UInt32(0), into: &result); integer(crc, into: &result); integer(UInt32(compressed.count), into: &result); integer(expanded, into: &result)
            integer(UInt16(bytes.count), into: &result); integer(UInt16(0), into: &result); result.append(bytes); result.append(compressed)
            integer(UInt32(0x02014b50), into: &directory); integer(UInt16(0x0314), into: &directory); integer(UInt16(20), into: &directory)
            integer(flags, into: &directory); integer(method, into: &directory); integer(UInt32(0), into: &directory); integer(crc, into: &directory)
            integer(UInt32(compressed.count), into: &directory); integer(expanded, into: &directory); integer(UInt16(bytes.count), into: &directory)
            for _ in 0..<4 { integer(UInt16(0), into: &directory) }
            integer(attributes, into: &directory); integer(UInt32(offset), into: &directory); directory.append(bytes)
        }
        let start = result.count
        result.append(directory)
        integer(UInt32(0x06054b50), into: &result); integer(UInt32(0), into: &result)
        integer(UInt16(entries.count), into: &result); integer(UInt16(entries.count), into: &result)
        integer(UInt32(directory.count), into: &result); integer(UInt32(start), into: &result); integer(UInt16(0), into: &result)
        return result
    }
}

private final class PetPackageURLProtocol: URLProtocol {
    static var responses: [String: (Data, Int?, URL?)] = [:]
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "pets.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let (data, declaredLength, finalURL) = Self.responses[url.path] else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist)); return
        }
        let headers = declaredLength.map { ["Content-Length": String($0)] }
        let response = HTTPURLResponse(url: finalURL ?? url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
