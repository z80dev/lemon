import Foundation

public struct AgentIdentity: Codable, Hashable, Identifiable {
    public var id: String
    public var name: String?
    public var kind: String
    public var sessionKey: String?
    public var label: String
    public var status: String?
}
public struct AgentIdentityResult: Codable, Hashable { public var agent: AgentIdentity }
public struct AgentRoster: Codable, Hashable { public var agents: [AgentIdentity] }
public struct AgentMessageReceipt: Codable, Hashable {
    public var messageId: String
    public var sourceId: String
    public var targetId: String
    public var status: String
    public var runId: String?
    public var response: String?
}

extension HTTPTransport {
    public func agentIdentity(botID: ID) async throws -> AgentIdentityResult {
        try await read("/bots/\(Self.pathID(botID))/agent-identity")
    }
    public func renameAgent(botID: ID, name: String?, clientNonce: String) async throws -> AgentIdentityResult {
        try await mutate("PATCH", "/bots/\(Self.pathID(botID))/agent-identity", body: ["clientNonce": .string(clientNonce), "name": name.map(JSONValue.string) ?? .null])
    }
    public func agents(botID: ID, query: String = "", limit: Int = 100) async throws -> AgentRoster {
        try await read("/bots/\(Self.pathID(botID))/agents", query: ["query": query, "limit": String(limit)])
    }
    /// One attempt; the caller retains clientNonce as the message ID for read reconciliation.
    public func messageAgent(botID: ID, target: String, text: String, clientNonce: String, conversationID: ID? = nil) async throws -> AgentMessageReceipt {
        var body: JSONObject = ["clientNonce": .string(clientNonce), "target": .string(target), "text": .string(text)]
        if let conversationID { body["conversationId"] = .string(conversationID) }
        let receipt: AgentMessageReceipt = try await mutate("POST", "/bots/\(Self.pathID(botID))/agent-messages", body: body)
        if receipt.status == "outcome_unknown" { throw ClientError.outcomeUnknown(clientNonce) }
        return receipt
    }
    public func agentMessage(botID: ID, messageID: String) async throws -> AgentMessageReceipt {
        try await read("/bots/\(Self.pathID(botID))/agent-messages/\(Self.pathID(messageID))")
    }
}
