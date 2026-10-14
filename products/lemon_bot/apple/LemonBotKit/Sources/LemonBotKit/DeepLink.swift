import Foundation

public struct DeepLinkTarget: Hashable {
    public let workspaceID: ID
    public let botID: ID?
    public let machineID: ID?
    public let routineID: ID?
    public let routineRunID: ID?
    public let conversationID: ID?
    public let taskConversationID: ID?
    public let entryID: ID?
    public let approvalID: ID?

    public init(url: URL) throws {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == "lemonbot", c.host == "workspace",
              c.user == nil, c.password == nil, c.port == nil, c.fragment == nil else { throw ClientError.invalidDeepLink }
        let segments = c.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.first == "", !segments.dropFirst().contains("") else { throw ClientError.invalidDeepLink }
        func id(_ raw: String) throws -> ID {
            guard let decoded = raw.removingPercentEncoding, !decoded.isEmpty,
                  !decoded.contains("/"), !decoded.contains("\\"), !decoded.contains("%"),
                  decoded != ".", decoded != "..", !decoded.contains(where: { $0.isWhitespace || $0.asciiValue.map({ $0 < 32 || $0 == 127 }) == true }) else { throw ClientError.invalidDeepLink }
            return decoded
        }
        let path = Array(segments.dropFirst()).map(String.init)
        guard path.count == 3 || path.count == 5 else { throw ClientError.invalidDeepLink }
        workspaceID = try id(path[0])
        var query: [String: ID] = [:]
        for item in c.queryItems ?? [] {
            guard query[item.name] == nil, let value = item.value else { throw ClientError.invalidDeepLink }
            query[item.name] = try id(value)
        }
        var bot: ID?, machine: ID?, routine: ID?
        let allowed: Set<String>
        switch path[1] {
        case "machine":
            guard path.count == 3 else { throw ClientError.invalidDeepLink }
            machine = try id(path[2]); bot = query["botId"]; allowed = ["botId"]
        case "bot":
            bot = try id(path[2])
            if path.count == 5 {
                guard path[3] == "routine" else { throw ClientError.invalidDeepLink }
                routine = try id(path[4]); allowed = ["routineRunId"]
            } else if query["approvalId"] != nil {
                guard query["conversationId"] != nil, query["entryId"] != nil else { throw ClientError.invalidDeepLink }
                allowed = ["conversationId", "entryId", "approvalId"]
            } else {
                allowed = ["conversationId", "taskConversationId", "entryId"]
                guard query["taskConversationId"] == nil || query["conversationId"] != nil,
                      query["entryId"] == nil || query["conversationId"] != nil else { throw ClientError.invalidDeepLink }
            }
        default: throw ClientError.invalidDeepLink
        }
        guard Set(query.keys).isSubset(of: allowed) else { throw ClientError.invalidDeepLink }
        botID = bot; machineID = machine; routineID = routine; routineRunID = query["routineRunId"]
        conversationID = query["conversationId"]; taskConversationID = query["taskConversationId"]
        entryID = query["entryId"]; approvalID = query["approvalId"]
    }
}
