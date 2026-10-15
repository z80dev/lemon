import Compression
import Foundation

/// A deliberately small ZIP reader. Entries are inflated to bounded memory, never extracted to paths.
enum PetZip {
    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
        return crc
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 255)] ^ (crc >> 8) }
        return crc ^ UInt32.max
    }

    private static func invalid(_ reason: String) -> PetPackageError {
        .invalid("This ZIP \(reason). Lemon Bot expects an unencrypted ZIP containing pet.json and a PNG or WebP spritesheet.")
    }

    static func files(_ data: Data) throws -> [String: Data] {
        guard data.count <= PetPackage.downloadLimit else { throw PetPackage.sizeError(PetPackage.downloadLimit) }
        func u16(_ offset: Int) throws -> Int {
            guard offset >= 0, offset <= data.count - 2 else { throw invalid("is incomplete") }
            return Int(data[offset]) | Int(data[offset + 1]) << 8
        }
        func u32(_ offset: Int) throws -> Int {
            guard offset >= 0, offset <= data.count - 4 else { throw invalid("is incomplete") }
            return Int(data[offset]) | Int(data[offset + 1]) << 8 | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
        }
        guard data.count >= 22 else { throw invalid("is incomplete") }
        var end: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
            if try u32(offset) == 0x06054b50, offset + 22 + (try u16(offset + 20)) == data.count { end = offset; break }
        }
        guard let end else { throw invalid("has no valid directory") }
        let count = try u16(end + 10), directorySize = try u32(end + 12), directory = try u32(end + 16)
        guard try u16(end + 4) == 0, try u16(end + 6) == 0, try u16(end + 8) == count,
              directory <= end, directorySize == end - directory else { throw invalid("uses an unsupported multi-volume or ZIP64 layout") }
        guard count <= 64 else { throw invalid("has too many entries (the limit is 64)") }
        var cursor = directory, total = 0
        var names = Set<String>(), ranges: [Range<Int>] = [], files: [String: Data] = [:]
        for _ in 0..<count {
            guard try u32(cursor) == 0x02014b50, cursor + 46 <= end else { throw invalid("has a damaged directory") }
            let flags = try u16(cursor + 8), method = try u16(cursor + 10), crc = try u32(cursor + 16)
            let compressed = try u32(cursor + 20), expanded = try u32(cursor + 24)
            let nameCount = try u16(cursor + 28), extraCount = try u16(cursor + 30), commentCount = try u16(cursor + 32)
            let attributes = try u32(cursor + 38), local = try u32(cursor + 42)
            let next = cursor + 46 + nameCount + extraCount + commentCount
            guard next <= end, try u16(cursor + 34) == 0 else { throw invalid("has a damaged entry") }
            guard flags & 0x2041 == 0, method == 0 || method == 8 else { throw invalid("contains encrypted entries or unsupported compression") }
            guard (attributes >> 16) & 0xf000 != 0xa000 else { throw invalid("contains a symbolic link") }
            guard let rawName = String(data: data[(cursor + 46)..<(cursor + 46 + nameCount)], encoding: .utf8) else { throw invalid("has an unreadable filename") }
            let isDirectory = rawName.hasSuffix("/")
            let name = try PetPackage.relativePath(isDirectory ? String(rawName.dropLast()) : rawName)
            guard names.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw invalid("contains duplicate filenames") }
            guard try u32(local) == 0x04034b50, local + 30 <= directory,
                  try u16(local + 6) == flags, try u16(local + 8) == method else { throw invalid("has a damaged local entry") }
            let localNameCount = try u16(local + 26), localExtraCount = try u16(local + 28)
            let start = local + 30 + localNameCount + localExtraCount
            guard start <= directory, compressed <= directory - start,
                  data[(local + 30)..<(local + 30 + localNameCount)] == data[(cursor + 46)..<(cursor + 46 + nameCount)] else { throw invalid("has inconsistent filenames or sizes") }
            if flags & 8 == 0 {
                guard try u32(local + 14) == crc, try u32(local + 18) == compressed, try u32(local + 22) == expanded else { throw invalid("has inconsistent entry sizes") }
            }
            let range = local..<(start + compressed)
            guard !ranges.contains(where: { $0.overlaps(range) }) else { throw invalid("contains overlapping entries") }
            ranges.append(range)
            let input = data.subdata(in: start..<(start + compressed))
            let output: Data
            if method == 0 {
                guard input.count <= PetPackage.expandedLimit - total else { throw invalid("expands beyond the 32 MiB limit") }
                output = input
            } else { output = try inflate(input, limit: PetPackage.expandedLimit - total) }
            total += output.count
            guard output.count == expanded, crc32(output) == UInt32(crc) else { throw invalid("failed its size or CRC integrity check") }
            if isDirectory {
                guard output.isEmpty else { throw invalid("contains a directory with file contents") }
            } else {
                let ext = (name as NSString).pathExtension.lowercased()
                guard !["zip", "gz", "tgz", "tar", "bz2", "xz", "7z", "rar", "jar"].contains(ext),
                      !output.starts(with: [0x50, 0x4b, 0x03, 0x04]), !output.starts(with: [0x1f, 0x8b]) else { throw invalid("contains a nested archive") }
                if !name.hasPrefix("__MACOSX/"), (name as NSString).lastPathComponent != ".DS_Store" { files[name] = output }
            }
            cursor = next
        }
        guard cursor == end else { throw invalid("has unexpected directory data") }
        return files
    }

    private static func inflate(_ input: Data, limit: Int) throws -> Data {
        guard !input.isEmpty else { throw invalid("contains empty DEFLATE data") }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024), output = Data()
        try input.withUnsafeBytes { source in
            try buffer.withUnsafeMutableBufferPointer { destination in
                var stream = compression_stream(dst_ptr: destination.baseAddress!, dst_size: destination.count, src_ptr: source.bindMemory(to: UInt8.self).baseAddress!, src_size: input.count, state: nil)
                guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else { throw invalid("couldn't initialize decompression") }
                defer { compression_stream_destroy(&stream) }
                stream.src_ptr = source.bindMemory(to: UInt8.self).baseAddress!
                stream.src_size = input.count
                while true {
                    stream.dst_ptr = destination.baseAddress!
                    stream.dst_size = destination.count
                    let previousInput = stream.src_size
                    let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    let produced = destination.count - stream.dst_size
                    guard produced <= limit - output.count else { throw invalid("expands beyond the 32 MiB limit") }
                    output.append(destination.baseAddress!, count: produced)
                    if status == COMPRESSION_STATUS_END {
                        guard stream.src_size == 0 else { throw invalid("has trailing compressed data") }
                        break
                    }
                    guard status == COMPRESSION_STATUS_OK, produced > 0 || stream.src_size < previousInput else { throw invalid("contains damaged DEFLATE data") }
                }
            }
        }
        return output
    }
}
