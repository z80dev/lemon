import Darwin
import Foundation

enum Arguments {
    enum Service: String, Equatable {
        case screenRecording = "screen-recording"
        case accessibility
    }

    enum Mode: Equatable {
        case exec(program: String, argv: [String])
        case status
        case request(Service)
    }

    enum ParseError: Error {
        case usage
    }

    static let usage = "Usage: Lemon Bot Worker -- <absolute program under ~/.lemon> [args] | --status --json | --request screen-recording|accessibility"

    static func parse(_ argv: [String], home: String) throws -> Mode {
        if argv == ["--status", "--json"] {
            return .status
        }
        if argv.count == 2, argv[0] == "--request", let service = Service(rawValue: argv[1]) {
            return .request(service)
        }
        guard argv.count >= 2, argv[0] == "--", argv[1].hasPrefix("/"),
              !argv[1].contains("\0"), !home.contains("\0"),
              let program = canonicalPath(argv[1]),
              let root = canonicalPath(URL(fileURLWithPath: home).appendingPathComponent(".lemon").path),
              program.hasPrefix(root + "/") else {
            throw ParseError.usage
        }
        return .exec(program: program, argv: Array(argv.dropFirst()))
    }

    private static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
