// Mirrors committed contracts/protocol.ts v1: owner-only live resources and device pairing.
// Required nullable fields require a wire key and encode null; optional nullable fields use
// nested Optional: nil omits, .some(nil) clears, .some(.some(value)) assigns.
// FileChunk.size is total source-file bytes; decoded dataBase64 length is the chunk length.
import Foundation

extension KeyedDecodingContainer {
    /// Absent optional keys are omitted; explicit null is legal only for nullable wire types.
    func decodeOptional<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        guard contains(key) else { return nil }
        return try decode(type, forKey: key)
    }
}

private enum FeedbackReasonValue: String {
    case notRequested = "not_requested"
    case inaccurate, lowQuality = "low_quality", slow
}

private enum ExportStreamValue: String {
    case audit, action, usage, conversationContent = "conversation_content"
}

private enum XMediaValue: String {
    case photo, video, gif
}

public struct Resource: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
    }
}

public struct PageQuery: Codable, Hashable {
    public var `cursor`: Cursor?
    public var `limit`: Int?
    public init(cursor: Cursor? = nil, limit: Int? = nil) {
        self.`cursor` = cursor
        self.`limit` = limit
    }
    enum CodingKeys: String, CodingKey { case `cursor`, `limit` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`cursor` = try c.decodeOptional(Cursor.self, forKey: .`cursor`)
        self.`limit` = try c.decodeOptional(Int.self, forKey: .`limit`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(`cursor`, forKey: .`cursor`)
        try c.encodeIfPresent(`limit`, forKey: .`limit`)
    }
}

public struct Mutation: Codable, Hashable {
    public var `clientNonce`: String
    public init(clientNonce: String) {
        self.`clientNonce` = clientNonce
    }
    enum CodingKeys: String, CodingKey { case `clientNonce` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
    }
}

public struct Update: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public init(clientNonce: String, revision: Int) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
    }
}

public struct Confirm: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `confirmationToken`: String
    public var `confirmName`: String
    public init(clientNonce: String, revision: Int, confirmationToken: String, confirmName: String) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`confirmationToken` = confirmationToken
        self.`confirmName` = confirmName
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `confirmationToken`, `confirmName` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`confirmationToken` = try c.decode(String.self, forKey: .`confirmationToken`)
        self.`confirmName` = try c.decode(String.self, forKey: .`confirmName`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`confirmationToken`, forKey: .`confirmationToken`)
        try c.encode(`confirmName`, forKey: .`confirmName`)
    }
}

public struct PreviewRequest: Codable, Hashable {
    public var `clientNonce`: String
    public var `action`: String
    public var `targetMachineId`: ID?
    public var `resetScopes`: [BotResetScope]?
    public init(clientNonce: String, action: String, targetMachineId: ID? = nil, resetScopes: [BotResetScope]? = nil) {
        self.`clientNonce` = clientNonce
        self.`action` = action
        self.`targetMachineId` = targetMachineId
        self.`resetScopes` = resetScopes
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `action`, `targetMachineId`, `resetScopes` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`action` = try c.decode(String.self, forKey: .`action`)
        guard ["delete", "detach", "move", "forget", "disconnect", "reset"].contains(`action`) else { throw DecodingError.dataCorruptedError(forKey: .`action`, in: c, debugDescription: "Invalid PreviewRequest.action") }
        self.`targetMachineId` = try c.decodeOptional(ID.self, forKey: .`targetMachineId`)
        self.`resetScopes` = try c.decodeOptional([BotResetScope].self, forKey: .`resetScopes`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`action`, forKey: .`action`)
        try c.encodeIfPresent(`targetMachineId`, forKey: .`targetMachineId`)
        try c.encodeIfPresent(`resetScopes`, forKey: .`resetScopes`)
    }
}

public struct Confirmation: Codable, Hashable {
    public var `confirmationToken`: String
    public var `revision`: Int
    public var `confirmName`: String
    public var `expiresAtMs`: TimestampMs
    public var `effects`: [String]
    public var `affected`: [ScopeEffect]
    public init(confirmationToken: String, revision: Int, confirmName: String, expiresAtMs: TimestampMs, effects: [String], affected: [ScopeEffect]) {
        self.`confirmationToken` = confirmationToken
        self.`revision` = revision
        self.`confirmName` = confirmName
        self.`expiresAtMs` = expiresAtMs
        self.`effects` = effects
        self.`affected` = affected
    }
    enum CodingKeys: String, CodingKey { case `confirmationToken`, `revision`, `confirmName`, `expiresAtMs`, `effects`, `affected` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`confirmationToken` = try c.decode(String.self, forKey: .`confirmationToken`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`confirmName` = try c.decode(String.self, forKey: .`confirmName`)
        self.`expiresAtMs` = try c.decode(TimestampMs.self, forKey: .`expiresAtMs`)
        self.`effects` = try c.decode([String].self, forKey: .`effects`)
        self.`affected` = try c.decode([ScopeEffect].self, forKey: .`affected`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`confirmationToken`, forKey: .`confirmationToken`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`confirmName`, forKey: .`confirmName`)
        try c.encode(`expiresAtMs`, forKey: .`expiresAtMs`)
        try c.encode(`effects`, forKey: .`effects`)
        try c.encode(`affected`, forKey: .`affected`)
    }
}

public struct Deleted: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `deleted`: Bool
    public init(id: ID, deleted: Bool) {
        self.`id` = id
        self.`deleted` = deleted
    }
    enum CodingKeys: String, CodingKey { case `id`, `deleted` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`deleted` = try c.decode(Bool.self, forKey: .`deleted`)
        guard `deleted` == true else { throw DecodingError.dataCorruptedError(forKey: .`deleted`, in: c, debugDescription: "Invalid literal Deleted.deleted") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`deleted`, forKey: .`deleted`)
    }
}

public struct Empty: Codable, Hashable {
    public var `ok`: Bool
    public init(ok: Bool) {
        self.`ok` = ok
    }
    enum CodingKeys: String, CodingKey { case `ok` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`ok` = try c.decode(Bool.self, forKey: .`ok`)
        guard `ok` == true else { throw DecodingError.dataCorruptedError(forKey: .`ok`, in: c, debugDescription: "Invalid literal Empty.ok") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`ok`, forKey: .`ok`)
    }
}

public struct OAuthCallbackQuery: Codable, Hashable {
    public var `state`: String
    public var `code`: String?
    public var `error`: String?
    public init(state: String, code: String? = nil, error: String? = nil) {
        self.`state` = state
        self.`code` = code
        self.`error` = error
    }
    enum CodingKeys: String, CodingKey { case `state`, `code`, `error` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`state` = try c.decode(String.self, forKey: .`state`)
        self.`code` = try c.decodeOptional(String.self, forKey: .`code`)
        self.`error` = try c.decodeOptional(String.self, forKey: .`error`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`state`, forKey: .`state`)
        try c.encodeIfPresent(`code`, forKey: .`code`)
        try c.encodeIfPresent(`error`, forKey: .`error`)
    }
}

public struct ErrorEnvelope: Codable, Hashable {
    public var `error`: ErrorEnvelopeError
    public init(error: ErrorEnvelopeError) {
        self.`error` = error
    }
    enum CodingKeys: String, CodingKey { case `error` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`error` = try c.decode(ErrorEnvelopeError.self, forKey: .`error`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`error`, forKey: .`error`)
    }
}

public struct VoiceSettings: Codable, Hashable {
    public var `voiceId`: String
    public var `speed`: Double
    public var `language`: String?
    public init(voiceId: String, speed: Double, language: String? = nil) {
        self.`voiceId` = voiceId
        self.`speed` = speed
        self.`language` = language
    }
    enum CodingKeys: String, CodingKey { case `voiceId`, `speed`, `language` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`voiceId` = try c.decode(String.self, forKey: .`voiceId`)
        self.`speed` = try c.decode(Double.self, forKey: .`speed`)
        self.`language` = try c.decode(String?.self, forKey: .`language`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`voiceId`, forKey: .`voiceId`)
        try c.encode(`speed`, forKey: .`speed`)
        try c.encode(`language`, forKey: .`language`)
    }
}

public struct Preferences: Codable, Hashable {
    public var `appearance`: String
    public var `language`: String?
    public var `timezone`: String
    public var `botColors`: Bool
    public var `threadsBesideChat`: Bool
    public var `voice`: VoiceSettings
    public var `celebrationsEnabled`: Bool
    public init(appearance: String, language: String? = nil, timezone: String, botColors: Bool, threadsBesideChat: Bool, voice: VoiceSettings, celebrationsEnabled: Bool) {
        self.`appearance` = appearance
        self.`language` = language
        self.`timezone` = timezone
        self.`botColors` = botColors
        self.`threadsBesideChat` = threadsBesideChat
        self.`voice` = voice
        self.`celebrationsEnabled` = celebrationsEnabled
    }
    enum CodingKeys: String, CodingKey { case `appearance`, `language`, `timezone`, `botColors`, `threadsBesideChat`, `voice`, `celebrationsEnabled` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`appearance` = try c.decode(String.self, forKey: .`appearance`)
        guard ["system", "light", "dark"].contains(`appearance`) else { throw DecodingError.dataCorruptedError(forKey: .`appearance`, in: c, debugDescription: "Invalid Preferences.appearance") }
        self.`language` = try c.decode(String?.self, forKey: .`language`)
        self.`timezone` = try c.decode(String.self, forKey: .`timezone`)
        self.`botColors` = try c.decode(Bool.self, forKey: .`botColors`)
        self.`threadsBesideChat` = try c.decode(Bool.self, forKey: .`threadsBesideChat`)
        self.`voice` = try c.decode(VoiceSettings.self, forKey: .`voice`)
        self.`celebrationsEnabled` = try c.decode(Bool.self, forKey: .`celebrationsEnabled`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`appearance`, forKey: .`appearance`)
        try c.encode(`language`, forKey: .`language`)
        try c.encode(`timezone`, forKey: .`timezone`)
        try c.encode(`botColors`, forKey: .`botColors`)
        try c.encode(`threadsBesideChat`, forKey: .`threadsBesideChat`)
        try c.encode(`voice`, forKey: .`voice`)
        try c.encode(`celebrationsEnabled`, forKey: .`celebrationsEnabled`)
    }
}

public struct NotificationPreferences: Codable, Hashable {
    public var `enabled`: Bool
    public var `sound`: Bool
    public var `previews`: Bool
    public var `completed`: Bool
    public var `needsInput`: Bool
    public init(enabled: Bool, sound: Bool, previews: Bool, completed: Bool, needsInput: Bool) {
        self.`enabled` = enabled
        self.`sound` = sound
        self.`previews` = previews
        self.`completed` = completed
        self.`needsInput` = needsInput
    }
    enum CodingKeys: String, CodingKey { case `enabled`, `sound`, `previews`, `completed`, `needsInput` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`enabled` = try c.decode(Bool.self, forKey: .`enabled`)
        self.`sound` = try c.decode(Bool.self, forKey: .`sound`)
        self.`previews` = try c.decode(Bool.self, forKey: .`previews`)
        self.`completed` = try c.decode(Bool.self, forKey: .`completed`)
        self.`needsInput` = try c.decode(Bool.self, forKey: .`needsInput`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`enabled`, forKey: .`enabled`)
        try c.encode(`sound`, forKey: .`sound`)
        try c.encode(`previews`, forKey: .`previews`)
        try c.encode(`completed`, forKey: .`completed`)
        try c.encode(`needsInput`, forKey: .`needsInput`)
    }
}

public struct User: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `email`: String
    public var `displayName`: String
    public var `avatarAttachmentId`: ID?
    public var `preferences`: Preferences
    public var `notifications`: NotificationPreferences
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, email: String, displayName: String, avatarAttachmentId: ID? = nil, preferences: Preferences, notifications: NotificationPreferences) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`email` = email
        self.`displayName` = displayName
        self.`avatarAttachmentId` = avatarAttachmentId
        self.`preferences` = preferences
        self.`notifications` = notifications
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `email`, `displayName`, `avatarAttachmentId`, `preferences`, `notifications` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`email` = try c.decode(String.self, forKey: .`email`)
        self.`displayName` = try c.decode(String.self, forKey: .`displayName`)
        self.`avatarAttachmentId` = try c.decode(ID?.self, forKey: .`avatarAttachmentId`)
        self.`preferences` = try c.decode(Preferences.self, forKey: .`preferences`)
        self.`notifications` = try c.decode(NotificationPreferences.self, forKey: .`notifications`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`email`, forKey: .`email`)
        try c.encode(`displayName`, forKey: .`displayName`)
        try c.encode(`avatarAttachmentId`, forKey: .`avatarAttachmentId`)
        try c.encode(`preferences`, forKey: .`preferences`)
        try c.encode(`notifications`, forKey: .`notifications`)
    }
}

public struct Workspace: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `name`: String
    public var `ownerUserId`: ID
    public var `enabled`: Bool
    public var `timezone`: String
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, name: String, ownerUserId: ID, enabled: Bool, timezone: String) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`name` = name
        self.`ownerUserId` = ownerUserId
        self.`enabled` = enabled
        self.`timezone` = timezone
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `name`, `ownerUserId`, `enabled`, `timezone` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`ownerUserId` = try c.decode(ID.self, forKey: .`ownerUserId`)
        self.`enabled` = try c.decode(Bool.self, forKey: .`enabled`)
        self.`timezone` = try c.decode(String.self, forKey: .`timezone`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`ownerUserId`, forKey: .`ownerUserId`)
        try c.encode(`enabled`, forKey: .`enabled`)
        try c.encode(`timezone`, forKey: .`timezone`)
    }
}

public struct Member: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `userId`: ID
    public var `displayName`: String
    public var `email`: String
    public var `role`: Role
    public var `enabled`: Bool
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, userId: ID, displayName: String, email: String, role: Role, enabled: Bool) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`userId` = userId
        self.`displayName` = displayName
        self.`email` = email
        self.`role` = role
        self.`enabled` = enabled
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `userId`, `displayName`, `email`, `role`, `enabled` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`userId` = try c.decode(ID.self, forKey: .`userId`)
        self.`displayName` = try c.decode(String.self, forKey: .`displayName`)
        self.`email` = try c.decode(String.self, forKey: .`email`)
        self.`role` = try c.decode(Role.self, forKey: .`role`)
        self.`enabled` = try c.decode(Bool.self, forKey: .`enabled`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`userId`, forKey: .`userId`)
        try c.encode(`displayName`, forKey: .`displayName`)
        try c.encode(`email`, forKey: .`email`)
        try c.encode(`role`, forKey: .`role`)
        try c.encode(`enabled`, forKey: .`enabled`)
    }
}

public struct MemberInvite: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `email`: String
    public var `role`: String
    public var `expiresAtMs`: TimestampMs
    public var `status`: String
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, email: String, role: String, expiresAtMs: TimestampMs, status: String) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`email` = email
        self.`role` = role
        self.`expiresAtMs` = expiresAtMs
        self.`status` = status
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `email`, `role`, `expiresAtMs`, `status` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`email` = try c.decode(String.self, forKey: .`email`)
        self.`role` = try c.decode(String.self, forKey: .`role`)
        guard ["admin", "member"].contains(`role`) else { throw DecodingError.dataCorruptedError(forKey: .`role`, in: c, debugDescription: "Invalid MemberInvite.role") }
        self.`expiresAtMs` = try c.decode(TimestampMs.self, forKey: .`expiresAtMs`)
        self.`status` = try c.decode(String.self, forKey: .`status`)
        guard ["pending", "accepted", "revoked", "expired"].contains(`status`) else { throw DecodingError.dataCorruptedError(forKey: .`status`, in: c, debugDescription: "Invalid MemberInvite.status") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`email`, forKey: .`email`)
        try c.encode(`role`, forKey: .`role`)
        try c.encode(`expiresAtMs`, forKey: .`expiresAtMs`)
        try c.encode(`status`, forKey: .`status`)
    }
}

public struct AuthSession: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `userId`: ID
    public var `deviceId`: ID?
    public var `expiresAtMs`: TimestampMs?
    public var `lastSeenAtMs`: TimestampMs
    public var `current`: Bool
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, userId: ID, deviceId: ID? = nil, expiresAtMs: TimestampMs?, lastSeenAtMs: TimestampMs, current: Bool) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`userId` = userId
        self.`deviceId` = deviceId
        self.`expiresAtMs` = expiresAtMs
        self.`lastSeenAtMs` = lastSeenAtMs
        self.`current` = current
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `userId`, `deviceId`, `expiresAtMs`, `lastSeenAtMs`, `current` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`userId` = try c.decode(ID.self, forKey: .`userId`)
        self.`deviceId` = try c.decode(ID?.self, forKey: .`deviceId`)
        self.`expiresAtMs` = try c.decode(TimestampMs?.self, forKey: .`expiresAtMs`)
        self.`lastSeenAtMs` = try c.decode(TimestampMs.self, forKey: .`lastSeenAtMs`)
        self.`current` = try c.decode(Bool.self, forKey: .`current`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`userId`, forKey: .`userId`)
        try c.encode(`deviceId`, forKey: .`deviceId`)
        try c.encode(`expiresAtMs`, forKey: .`expiresAtMs`)
        try c.encode(`lastSeenAtMs`, forKey: .`lastSeenAtMs`)
        try c.encode(`current`, forKey: .`current`)
    }
}

public typealias PairingStatus = String

/// Safe owner-visible pairing state; QR and claim secrets are never resource fields.
public struct Pairing: Codable, Hashable, Identifiable {
    public var id: ID
    public var revision: Int
    public var createdAtMs: TimestampMs
    public var updatedAtMs: TimestampMs
    public var workspaceId: ID
    public var ownerUserId: ID
    public var clusterName: String
    public var backendUrl: String
    public var status: PairingStatus
    public var expiresAtMs: TimestampMs
    public var deviceName: String?
    public var verificationCode: String?
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, workspaceId: ID, ownerUserId: ID, clusterName: String, backendUrl: String, status: PairingStatus, expiresAtMs: TimestampMs, deviceName: String? = nil, verificationCode: String? = nil) {
        self.id = id
        self.revision = revision
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs
        self.workspaceId = workspaceId
        self.ownerUserId = ownerUserId
        self.clusterName = clusterName
        self.backendUrl = backendUrl
        self.status = status
        self.expiresAtMs = expiresAtMs
        self.deviceName = deviceName
        self.verificationCode = verificationCode
    }
    enum CodingKeys: String, CodingKey { case id, revision, createdAtMs, updatedAtMs, workspaceId, ownerUserId, clusterName, backendUrl, status, expiresAtMs, deviceName, verificationCode }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ID.self, forKey: .id)
        revision = try c.decode(Int.self, forKey: .revision)
        createdAtMs = try c.decode(TimestampMs.self, forKey: .createdAtMs)
        updatedAtMs = try c.decode(TimestampMs.self, forKey: .updatedAtMs)
        workspaceId = try c.decode(ID.self, forKey: .workspaceId)
        ownerUserId = try c.decode(ID.self, forKey: .ownerUserId)
        clusterName = try c.decode(String.self, forKey: .clusterName)
        backendUrl = try c.decode(String.self, forKey: .backendUrl)
        status = try c.decode(PairingStatus.self, forKey: .status)
        guard ["waiting", "pending_approval", "approved", "denied", "expired", "consumed"].contains(status) else { throw DecodingError.dataCorruptedError(forKey: .status, in: c, debugDescription: "Invalid Pairing.status") }
        expiresAtMs = try c.decode(TimestampMs.self, forKey: .expiresAtMs)
        deviceName = try c.decode(String?.self, forKey: .deviceName)
        verificationCode = try c.decode(String?.self, forKey: .verificationCode)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        guard ["waiting", "pending_approval", "approved", "denied", "expired", "consumed"].contains(status) else { throw EncodingError.invalidValue(status, .init(codingPath: c.codingPath + [CodingKeys.status], debugDescription: "Invalid Pairing.status")) }
        try c.encode(id, forKey: .id)
        try c.encode(revision, forKey: .revision)
        try c.encode(createdAtMs, forKey: .createdAtMs)
        try c.encode(updatedAtMs, forKey: .updatedAtMs)
        try c.encode(workspaceId, forKey: .workspaceId)
        try c.encode(ownerUserId, forKey: .ownerUserId)
        try c.encode(clusterName, forKey: .clusterName)
        try c.encode(backendUrl, forKey: .backendUrl)
        try c.encode(status, forKey: .status)
        try c.encode(expiresAtMs, forKey: .expiresAtMs)
        try c.encode(deviceName, forKey: .deviceName)
        try c.encode(verificationCode, forKey: .verificationCode)
    }
}

public struct PairingStart: Codable, Hashable {
    public var clientNonce: String
    public init(clientNonce: String) { self.clientNonce = clientNonce }
    enum CodingKeys: String, CodingKey { case clientNonce }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clientNonce = try c.decode(String.self, forKey: .clientNonce)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(clientNonce, forKey: .clientNonce)
    }
}

/// The short-lived QR secret is returned only to the issuing owner.
public struct PairingIssued: Codable, Hashable {
    public var pairing: Pairing
    public var pairUrl: String
    public init(pairing: Pairing, pairUrl: String) { self.pairing = pairing; self.pairUrl = pairUrl }
    enum CodingKeys: String, CodingKey { case pairing, pairUrl }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pairing = try c.decode(Pairing.self, forKey: .pairing)
        pairUrl = try c.decode(String.self, forKey: .pairUrl)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pairing, forKey: .pairing)
        try c.encode(pairUrl, forKey: .pairUrl)
    }
}

public struct PairingLink: Codable, Hashable {
    public var backendUrl: String
    public var workspaceId: ID
    public var pairCode: String
    public init(backendUrl: String, workspaceId: ID, pairCode: String) {
        self.backendUrl = backendUrl
        self.workspaceId = workspaceId
        self.pairCode = pairCode
    }
    enum CodingKeys: String, CodingKey { case backendUrl, workspaceId, pairCode }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        backendUrl = try c.decode(String.self, forKey: .backendUrl)
        workspaceId = try c.decode(ID.self, forKey: .workspaceId)
        pairCode = try c.decode(String.self, forKey: .pairCode)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(backendUrl, forKey: .backendUrl)
        try c.encode(workspaceId, forKey: .workspaceId)
        try c.encode(pairCode, forKey: .pairCode)
    }
}

/// Read-only secret-bound preview, not a nonce-bearing mutation or claim.
public struct PairingPreviewRequest: Codable, Hashable {
    public var pairCode: String
    public var workspaceId: ID
    public init(pairCode: String, workspaceId: ID) { self.pairCode = pairCode; self.workspaceId = workspaceId }
    enum CodingKeys: String, CodingKey { case pairCode, workspaceId }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pairCode = try c.decode(String.self, forKey: .pairCode)
        workspaceId = try c.decode(ID.self, forKey: .workspaceId)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pairCode, forKey: .pairCode)
        try c.encode(workspaceId, forKey: .workspaceId)
    }
}

public struct PairingPreviewResult: Codable, Hashable {
    public var clusterName: String
    public var backendUrl: String
    public var expiresAtMs: TimestampMs
    public init(clusterName: String, backendUrl: String, expiresAtMs: TimestampMs) {
        self.clusterName = clusterName
        self.backendUrl = backendUrl
        self.expiresAtMs = expiresAtMs
    }
    enum CodingKeys: String, CodingKey { case clusterName, backendUrl, expiresAtMs }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clusterName = try c.decode(String.self, forKey: .clusterName)
        backendUrl = try c.decode(String.self, forKey: .backendUrl)
        expiresAtMs = try c.decode(TimestampMs.self, forKey: .expiresAtMs)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(clusterName, forKey: .clusterName)
        try c.encode(backendUrl, forKey: .backendUrl)
        try c.encode(expiresAtMs, forKey: .expiresAtMs)
    }
}

public struct PairingClaim: Codable, Hashable {
    public var clientNonce: String
    public var pairCode: String
    public var workspaceId: ID
    public var installationId: String
    public var deviceName: String
    public var appVersion: String
    public init(clientNonce: String, pairCode: String, workspaceId: ID, installationId: String, deviceName: String, appVersion: String) {
        self.clientNonce = clientNonce
        self.pairCode = pairCode
        self.workspaceId = workspaceId
        self.installationId = installationId
        self.deviceName = deviceName
        self.appVersion = appVersion
    }
    enum CodingKeys: String, CodingKey { case clientNonce, pairCode, workspaceId, installationId, deviceName, appVersion }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clientNonce = try c.decode(String.self, forKey: .clientNonce)
        pairCode = try c.decode(String.self, forKey: .pairCode)
        workspaceId = try c.decode(ID.self, forKey: .workspaceId)
        installationId = try c.decode(String.self, forKey: .installationId)
        deviceName = try c.decode(String.self, forKey: .deviceName)
        appVersion = try c.decode(String.self, forKey: .appVersion)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(clientNonce, forKey: .clientNonce)
        try c.encode(pairCode, forKey: .pairCode)
        try c.encode(workspaceId, forKey: .workspaceId)
        try c.encode(installationId, forKey: .installationId)
        try c.encode(deviceName, forKey: .deviceName)
        try c.encode(appVersion, forKey: .appVersion)
    }
}

public struct PairingClaimResult: Codable, Hashable {
    public var pairingId: ID
    public var claimToken: String
    public var verificationCode: String
    public var expiresAtMs: TimestampMs
    public var clusterName: String
    public var backendUrl: String
    public init(pairingId: ID, claimToken: String, verificationCode: String, expiresAtMs: TimestampMs, clusterName: String, backendUrl: String) {
        self.pairingId = pairingId
        self.claimToken = claimToken
        self.verificationCode = verificationCode
        self.expiresAtMs = expiresAtMs
        self.clusterName = clusterName
        self.backendUrl = backendUrl
    }
    enum CodingKeys: String, CodingKey { case pairingId, claimToken, verificationCode, expiresAtMs, clusterName, backendUrl }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pairingId = try c.decode(ID.self, forKey: .pairingId)
        claimToken = try c.decode(String.self, forKey: .claimToken)
        verificationCode = try c.decode(String.self, forKey: .verificationCode)
        expiresAtMs = try c.decode(TimestampMs.self, forKey: .expiresAtMs)
        clusterName = try c.decode(String.self, forKey: .clusterName)
        backendUrl = try c.decode(String.self, forKey: .backendUrl)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pairingId, forKey: .pairingId)
        try c.encode(claimToken, forKey: .claimToken)
        try c.encode(verificationCode, forKey: .verificationCode)
        try c.encode(expiresAtMs, forKey: .expiresAtMs)
        try c.encode(clusterName, forKey: .clusterName)
        try c.encode(backendUrl, forKey: .backendUrl)
    }
}

public struct PairingApprove: Codable, Hashable {
    public var clientNonce: String
    public var revision: Int
    public var verificationCode: String
    public init(clientNonce: String, revision: Int, verificationCode: String) {
        self.clientNonce = clientNonce
        self.revision = revision
        self.verificationCode = verificationCode
    }
    enum CodingKeys: String, CodingKey { case clientNonce, revision, verificationCode }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clientNonce = try c.decode(String.self, forKey: .clientNonce)
        revision = try c.decode(Int.self, forKey: .revision)
        verificationCode = try c.decode(String.self, forKey: .verificationCode)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(clientNonce, forKey: .clientNonce)
        try c.encode(revision, forKey: .revision)
        try c.encode(verificationCode, forKey: .verificationCode)
    }
}

public struct PairingDeny: Codable, Hashable {
    public var clientNonce: String
    public var revision: Int
    public init(clientNonce: String, revision: Int) { self.clientNonce = clientNonce; self.revision = revision }
    enum CodingKeys: String, CodingKey { case clientNonce, revision }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clientNonce = try c.decode(String.self, forKey: .clientNonce)
        revision = try c.decode(Int.self, forKey: .revision)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(clientNonce, forKey: .clientNonce)
        try c.encode(revision, forKey: .revision)
    }
}

public struct PairingComplete: Codable, Hashable {
    public var clientNonce: String
    public var claimToken: String
    public init(clientNonce: String, claimToken: String) { self.clientNonce = clientNonce; self.claimToken = claimToken }
    enum CodingKeys: String, CodingKey { case clientNonce, claimToken }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clientNonce = try c.decode(String.self, forKey: .clientNonce)
        claimToken = try c.decode(String.self, forKey: .claimToken)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(clientNonce, forKey: .clientNonce)
        try c.encode(claimToken, forKey: .claimToken)
    }
}

public struct PairingCompletionPending: Codable, Hashable {
    public var status: String
    public var pairingId: ID
    public var expiresAtMs: TimestampMs
    public init(status: String, pairingId: ID, expiresAtMs: TimestampMs) {
        self.status = status
        self.pairingId = pairingId
        self.expiresAtMs = expiresAtMs
    }
    enum CodingKeys: String, CodingKey { case status, pairingId, expiresAtMs }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(String.self, forKey: .status)
        guard ["pending", "denied", "expired"].contains(status) else { throw DecodingError.dataCorruptedError(forKey: .status, in: c, debugDescription: "Invalid PairingCompletionPending.status") }
        pairingId = try c.decode(ID.self, forKey: .pairingId)
        expiresAtMs = try c.decode(TimestampMs.self, forKey: .expiresAtMs)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        guard ["pending", "denied", "expired"].contains(status) else { throw EncodingError.invalidValue(status, .init(codingPath: c.codingPath + [CodingKeys.status], debugDescription: "Invalid PairingCompletionPending.status")) }
        try c.encode(status, forKey: .status)
        try c.encode(pairingId, forKey: .pairingId)
        try c.encode(expiresAtMs, forKey: .expiresAtMs)
    }
}

public struct PairingCompletionConnected: Codable, Hashable {
    public var status: String { "connected" }
    public var auth: AuthResult
    public var device: Device
    public init(auth: AuthResult, device: Device) { self.auth = auth; self.device = device }
    enum CodingKeys: String, CodingKey { case status, auth, device }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(String.self, forKey: .status) == "connected" else { throw DecodingError.dataCorruptedError(forKey: .status, in: c, debugDescription: "Invalid PairingCompletionConnected.status") }
        auth = try c.decode(AuthResult.self, forKey: .auth)
        device = try c.decode(Device.self, forKey: .device)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status)
        try c.encode(auth, forKey: .auth)
        try c.encode(device, forKey: .device)
    }
}

public enum PairingCompletion: Codable, Hashable {
    case pending(PairingCompletionPending)
    case connected(PairingCompletionConnected)
    private enum CodingKeys: String, CodingKey { case status }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let status = try c.decode(String.self, forKey: .status)
        switch status {
        case "pending", "denied", "expired": self = .pending(try PairingCompletionPending(from: decoder))
        case "connected": self = .connected(try PairingCompletionConnected(from: decoder))
        default: throw DecodingError.dataCorruptedError(forKey: .status, in: c, debugDescription: "Unsupported PairingCompletion discriminator: \(status)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .pending(let value): try value.encode(to: encoder)
        case .connected(let value): try value.encode(to: encoder)
        }
    }
    public var status: String {
        switch self {
        case .pending(let value): return value.status
        case .connected(let value): return value.status
        }
    }
}

public struct AuthResult: Codable, Hashable {
    public var `token`: String
    public var `session`: AuthSession
    public var `user`: User
    public var `workspace`: Workspace
    public var `member`: Member
    public init(token: String, session: AuthSession, user: User, workspace: Workspace, member: Member) {
        self.`token` = token
        self.`session` = session
        self.`user` = user
        self.`workspace` = workspace
        self.`member` = member
    }
    enum CodingKeys: String, CodingKey { case `token`, `session`, `user`, `workspace`, `member` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`token` = try c.decode(String.self, forKey: .`token`)
        self.`session` = try c.decode(AuthSession.self, forKey: .`session`)
        self.`user` = try c.decode(User.self, forKey: .`user`)
        self.`workspace` = try c.decode(Workspace.self, forKey: .`workspace`)
        self.`member` = try c.decode(Member.self, forKey: .`member`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`token`, forKey: .`token`)
        try c.encode(`session`, forKey: .`session`)
        try c.encode(`user`, forKey: .`user`)
        try c.encode(`workspace`, forKey: .`workspace`)
        try c.encode(`member`, forKey: .`member`)
    }
}

public struct SetupStatus: Codable, Hashable {
    public var `setupRequired`: Bool
    public var `version`: String
    public var `apiVersion`: Int
    public init(setupRequired: Bool, version: String, apiVersion: Int) {
        self.`setupRequired` = setupRequired
        self.`version` = version
        self.`apiVersion` = apiVersion
    }
    enum CodingKeys: String, CodingKey { case `setupRequired`, `version`, `apiVersion` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`setupRequired` = try c.decode(Bool.self, forKey: .`setupRequired`)
        self.`version` = try c.decode(String.self, forKey: .`version`)
        self.`apiVersion` = try c.decode(Int.self, forKey: .`apiVersion`)
        guard `apiVersion` == 1 else { throw DecodingError.dataCorruptedError(forKey: .`apiVersion`, in: c, debugDescription: "Invalid literal SetupStatus.apiVersion") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`setupRequired`, forKey: .`setupRequired`)
        try c.encode(`version`, forKey: .`version`)
        try c.encode(`apiVersion`, forKey: .`apiVersion`)
    }
}

public struct SetupRequest: Codable, Hashable {
    public var `clientNonce`: String
    public var `setupCode`: String
    public var `email`: String
    public var `password`: String
    public var `displayName`: String
    public var `workspaceName`: String
    public init(clientNonce: String, setupCode: String, email: String, password: String, displayName: String, workspaceName: String) {
        self.`clientNonce` = clientNonce
        self.`setupCode` = setupCode
        self.`email` = email
        self.`password` = password
        self.`displayName` = displayName
        self.`workspaceName` = workspaceName
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `setupCode`, `email`, `password`, `displayName`, `workspaceName` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`setupCode` = try c.decode(String.self, forKey: .`setupCode`)
        self.`email` = try c.decode(String.self, forKey: .`email`)
        self.`password` = try c.decode(String.self, forKey: .`password`)
        self.`displayName` = try c.decode(String.self, forKey: .`displayName`)
        self.`workspaceName` = try c.decode(String.self, forKey: .`workspaceName`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`setupCode`, forKey: .`setupCode`)
        try c.encode(`email`, forKey: .`email`)
        try c.encode(`password`, forKey: .`password`)
        try c.encode(`displayName`, forKey: .`displayName`)
        try c.encode(`workspaceName`, forKey: .`workspaceName`)
    }
}

public struct LoginRequest: Codable, Hashable {
    public var `clientNonce`: String
    public var `email`: String
    public var `password`: String
    public var `deviceId`: ID?
    public init(clientNonce: String, email: String, password: String, deviceId: ID? = nil) {
        self.`clientNonce` = clientNonce
        self.`email` = email
        self.`password` = password
        self.`deviceId` = deviceId
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `email`, `password`, `deviceId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`email` = try c.decode(String.self, forKey: .`email`)
        self.`password` = try c.decode(String.self, forKey: .`password`)
        self.`deviceId` = try c.decodeOptional(ID.self, forKey: .`deviceId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`email`, forKey: .`email`)
        try c.encode(`password`, forKey: .`password`)
        try c.encodeIfPresent(`deviceId`, forKey: .`deviceId`)
    }
}

public struct AcceptInviteRequest: Codable, Hashable {
    public var `clientNonce`: String
    public var `inviteToken`: String
    public var `email`: String
    public var `password`: String
    public var `displayName`: String
    public init(clientNonce: String, inviteToken: String, email: String, password: String, displayName: String) {
        self.`clientNonce` = clientNonce
        self.`inviteToken` = inviteToken
        self.`email` = email
        self.`password` = password
        self.`displayName` = displayName
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `inviteToken`, `email`, `password`, `displayName` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`inviteToken` = try c.decode(String.self, forKey: .`inviteToken`)
        self.`email` = try c.decode(String.self, forKey: .`email`)
        self.`password` = try c.decode(String.self, forKey: .`password`)
        self.`displayName` = try c.decode(String.self, forKey: .`displayName`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`inviteToken`, forKey: .`inviteToken`)
        try c.encode(`email`, forKey: .`email`)
        try c.encode(`password`, forKey: .`password`)
        try c.encode(`displayName`, forKey: .`displayName`)
    }
}

public struct ReauthRequest: Codable, Hashable {
    public var `password`: String
    public init(password: String) {
        self.`password` = password
    }
    enum CodingKeys: String, CodingKey { case `password` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`password` = try c.decode(String.self, forKey: .`password`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`password`, forKey: .`password`)
    }
}

public struct ReauthResult: Codable, Hashable {
    public var `reauthToken`: String
    public var `expiresAtMs`: TimestampMs
    public init(reauthToken: String, expiresAtMs: TimestampMs) {
        self.`reauthToken` = reauthToken
        self.`expiresAtMs` = expiresAtMs
    }
    enum CodingKeys: String, CodingKey { case `reauthToken`, `expiresAtMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`reauthToken` = try c.decode(String.self, forKey: .`reauthToken`)
        self.`expiresAtMs` = try c.decode(TimestampMs.self, forKey: .`expiresAtMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`reauthToken`, forKey: .`reauthToken`)
        try c.encode(`expiresAtMs`, forKey: .`expiresAtMs`)
    }
}

public struct UserUpdate: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `displayName`: String?
    public var `email`: String?
    public var `avatarAttachmentId`: ID??
    public var `preferences`: Preferences?
    public var `notifications`: NotificationPreferences?
    public init(clientNonce: String, revision: Int, displayName: String? = nil, email: String? = nil, avatarAttachmentId: ID?? = nil, preferences: Preferences? = nil, notifications: NotificationPreferences? = nil) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`displayName` = displayName
        self.`email` = email
        self.`avatarAttachmentId` = avatarAttachmentId
        self.`preferences` = preferences
        self.`notifications` = notifications
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `displayName`, `email`, `avatarAttachmentId`, `preferences`, `notifications` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`displayName` = try c.decodeOptional(String.self, forKey: .`displayName`)
        self.`email` = try c.decodeOptional(String.self, forKey: .`email`)
        self.`avatarAttachmentId` = c.contains(.`avatarAttachmentId`) ? .some(try c.decodeIfPresent(ID.self, forKey: .`avatarAttachmentId`)) : nil
        self.`preferences` = try c.decodeOptional(Preferences.self, forKey: .`preferences`)
        self.`notifications` = try c.decodeOptional(NotificationPreferences.self, forKey: .`notifications`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encodeIfPresent(`displayName`, forKey: .`displayName`)
        try c.encodeIfPresent(`email`, forKey: .`email`)
        if let value = `avatarAttachmentId` { try c.encode(value, forKey: .`avatarAttachmentId`) }
        try c.encodeIfPresent(`preferences`, forKey: .`preferences`)
        try c.encodeIfPresent(`notifications`, forKey: .`notifications`)
    }
}

public struct PasswordUpdate: Codable, Hashable {
    public var `clientNonce`: String
    public var `currentPassword`: String
    public var `newPassword`: String
    public init(clientNonce: String, currentPassword: String, newPassword: String) {
        self.`clientNonce` = clientNonce
        self.`currentPassword` = currentPassword
        self.`newPassword` = newPassword
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `currentPassword`, `newPassword` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`currentPassword` = try c.decode(String.self, forKey: .`currentPassword`)
        self.`newPassword` = try c.decode(String.self, forKey: .`newPassword`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`currentPassword`, forKey: .`currentPassword`)
        try c.encode(`newPassword`, forKey: .`newPassword`)
    }
}

public struct AccountDelete: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `confirmationToken`: String
    public var `confirmName`: String
    public var `reauthToken`: String
    public init(clientNonce: String, revision: Int, confirmationToken: String, confirmName: String, reauthToken: String) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`confirmationToken` = confirmationToken
        self.`confirmName` = confirmName
        self.`reauthToken` = reauthToken
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `confirmationToken`, `confirmName`, `reauthToken` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`confirmationToken` = try c.decode(String.self, forKey: .`confirmationToken`)
        self.`confirmName` = try c.decode(String.self, forKey: .`confirmName`)
        self.`reauthToken` = try c.decode(String.self, forKey: .`reauthToken`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`confirmationToken`, forKey: .`confirmationToken`)
        try c.encode(`confirmName`, forKey: .`confirmName`)
        try c.encode(`reauthToken`, forKey: .`reauthToken`)
    }
}

public struct WorkspaceUpdate: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `name`: String?
    public var `timezone`: String?
    public var `enabled`: Bool?
    public var `ownerUserId`: ID?
    public init(clientNonce: String, revision: Int, name: String? = nil, timezone: String? = nil, enabled: Bool? = nil, ownerUserId: ID? = nil) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`name` = name
        self.`timezone` = timezone
        self.`enabled` = enabled
        self.`ownerUserId` = ownerUserId
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `name`, `timezone`, `enabled`, `ownerUserId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`name` = try c.decodeOptional(String.self, forKey: .`name`)
        self.`timezone` = try c.decodeOptional(String.self, forKey: .`timezone`)
        self.`enabled` = try c.decodeOptional(Bool.self, forKey: .`enabled`)
        self.`ownerUserId` = try c.decodeOptional(ID.self, forKey: .`ownerUserId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encodeIfPresent(`name`, forKey: .`name`)
        try c.encodeIfPresent(`timezone`, forKey: .`timezone`)
        try c.encodeIfPresent(`enabled`, forKey: .`enabled`)
        try c.encodeIfPresent(`ownerUserId`, forKey: .`ownerUserId`)
    }
}

public struct MemberUpdate: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `role`: Role?
    public var `enabled`: Bool?
    public init(clientNonce: String, revision: Int, role: Role? = nil, enabled: Bool? = nil) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`role` = role
        self.`enabled` = enabled
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `role`, `enabled` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`role` = try c.decodeOptional(Role.self, forKey: .`role`)
        self.`enabled` = try c.decodeOptional(Bool.self, forKey: .`enabled`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encodeIfPresent(`role`, forKey: .`role`)
        try c.encodeIfPresent(`enabled`, forKey: .`enabled`)
    }
}

public struct InviteCreate: Codable, Hashable {
    public var `clientNonce`: String
    public var `email`: String
    public var `role`: String
    public var `expiresInMs`: Int?
    public init(clientNonce: String, email: String, role: String, expiresInMs: Int? = nil) {
        self.`clientNonce` = clientNonce
        self.`email` = email
        self.`role` = role
        self.`expiresInMs` = expiresInMs
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `email`, `role`, `expiresInMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`email` = try c.decode(String.self, forKey: .`email`)
        self.`role` = try c.decode(String.self, forKey: .`role`)
        guard ["admin", "member"].contains(`role`) else { throw DecodingError.dataCorruptedError(forKey: .`role`, in: c, debugDescription: "Invalid InviteCreate.role") }
        self.`expiresInMs` = try c.decodeOptional(Int.self, forKey: .`expiresInMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`email`, forKey: .`email`)
        try c.encode(`role`, forKey: .`role`)
        try c.encodeIfPresent(`expiresInMs`, forKey: .`expiresInMs`)
    }
}

public struct InviteIssued: Codable, Hashable {
    public var `invite`: MemberInvite
    public var `inviteToken`: String
    public var `inviteUrl`: String
    public init(invite: MemberInvite, inviteToken: String, inviteUrl: String) {
        self.`invite` = invite
        self.`inviteToken` = inviteToken
        self.`inviteUrl` = inviteUrl
    }
    enum CodingKeys: String, CodingKey { case `invite`, `inviteToken`, `inviteUrl` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`invite` = try c.decode(MemberInvite.self, forKey: .`invite`)
        self.`inviteToken` = try c.decode(String.self, forKey: .`inviteToken`)
        self.`inviteUrl` = try c.decode(String.self, forKey: .`inviteUrl`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`invite`, forKey: .`invite`)
        try c.encode(`inviteToken`, forKey: .`inviteToken`)
        try c.encode(`inviteUrl`, forKey: .`inviteUrl`)
    }
}

public struct Device: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `userId`: ID
    public var `platform`: String
    public var `name`: String
    public var `appVersion`: String
    public var `pushEnabled`: Bool
    public var `lastSeenAtMs`: TimestampMs
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, userId: ID, platform: String, name: String, appVersion: String, pushEnabled: Bool, lastSeenAtMs: TimestampMs) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`userId` = userId
        self.`platform` = platform
        self.`name` = name
        self.`appVersion` = appVersion
        self.`pushEnabled` = pushEnabled
        self.`lastSeenAtMs` = lastSeenAtMs
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `userId`, `platform`, `name`, `appVersion`, `pushEnabled`, `lastSeenAtMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`userId` = try c.decode(ID.self, forKey: .`userId`)
        self.`platform` = try c.decode(String.self, forKey: .`platform`)
        guard ["web", "macos", "ios"].contains(`platform`) else { throw DecodingError.dataCorruptedError(forKey: .`platform`, in: c, debugDescription: "Invalid Device.platform") }
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`appVersion` = try c.decode(String.self, forKey: .`appVersion`)
        self.`pushEnabled` = try c.decode(Bool.self, forKey: .`pushEnabled`)
        self.`lastSeenAtMs` = try c.decode(TimestampMs.self, forKey: .`lastSeenAtMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`userId`, forKey: .`userId`)
        try c.encode(`platform`, forKey: .`platform`)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`appVersion`, forKey: .`appVersion`)
        try c.encode(`pushEnabled`, forKey: .`pushEnabled`)
        try c.encode(`lastSeenAtMs`, forKey: .`lastSeenAtMs`)
    }
}

public struct DeviceRegister: Codable, Hashable {
    public var `clientNonce`: String
    public var `installationId`: String
    public var `platform`: String
    public var `name`: String
    public var `appVersion`: String
    public var `push`: PushRegistration?
    public init(clientNonce: String, installationId: String, platform: String, name: String, appVersion: String, push: PushRegistration? = nil) {
        self.`clientNonce` = clientNonce
        self.`installationId` = installationId
        self.`platform` = platform
        self.`name` = name
        self.`appVersion` = appVersion
        self.`push` = push
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `installationId`, `platform`, `name`, `appVersion`, `push` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`installationId` = try c.decode(String.self, forKey: .`installationId`)
        self.`platform` = try c.decode(String.self, forKey: .`platform`)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`appVersion` = try c.decode(String.self, forKey: .`appVersion`)
        self.`push` = try c.decodeOptional(PushRegistration.self, forKey: .`push`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`installationId`, forKey: .`installationId`)
        try c.encode(`platform`, forKey: .`platform`)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`appVersion`, forKey: .`appVersion`)
        try c.encodeIfPresent(`push`, forKey: .`push`)
    }
}

public struct DeviceUpdate: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `name`: String?
    public var `appVersion`: String?
    public var `push`: PushRegistration??
    public var `pushEnabled`: Bool?
    public init(clientNonce: String, revision: Int, name: String? = nil, appVersion: String? = nil, push: PushRegistration?? = nil, pushEnabled: Bool? = nil) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`name` = name
        self.`appVersion` = appVersion
        self.`push` = push
        self.`pushEnabled` = pushEnabled
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `name`, `appVersion`, `push`, `pushEnabled` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`name` = try c.decodeOptional(String.self, forKey: .`name`)
        self.`appVersion` = try c.decodeOptional(String.self, forKey: .`appVersion`)
        self.`push` = c.contains(.`push`) ? .some(try c.decodeIfPresent(PushRegistration.self, forKey: .`push`)) : nil
        self.`pushEnabled` = try c.decodeOptional(Bool.self, forKey: .`pushEnabled`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encodeIfPresent(`name`, forKey: .`name`)
        try c.encodeIfPresent(`appVersion`, forKey: .`appVersion`)
        if let value = `push` { try c.encode(value, forKey: .`push`) }
        try c.encodeIfPresent(`pushEnabled`, forKey: .`pushEnabled`)
    }
}

public struct Capabilities: Codable, Hashable {
    public var `controlConnected`: Bool
    public var `methods`: [String]
    public var `stt`: Bool
    public var `tts`: Bool
    public var `imageGeneration`: Bool
    public var `apns`: Bool
    public var `webPush`: Bool
    public var `vapidPublicKey`: String?
    public var `attachmentMaxBytes`: Int
    public var `videoMaxBytes`: Int
    public var `maxAttachments`: Int
    public var `minClientVersions`: CapabilitiesMinClientVersions
    public init(controlConnected: Bool, methods: [String], stt: Bool, tts: Bool, imageGeneration: Bool, apns: Bool, webPush: Bool, vapidPublicKey: String? = nil, attachmentMaxBytes: Int, videoMaxBytes: Int, maxAttachments: Int, minClientVersions: CapabilitiesMinClientVersions) {
        self.`controlConnected` = controlConnected
        self.`methods` = methods
        self.`stt` = stt
        self.`tts` = tts
        self.`imageGeneration` = imageGeneration
        self.`apns` = apns
        self.`webPush` = webPush
        self.`vapidPublicKey` = vapidPublicKey
        self.`attachmentMaxBytes` = attachmentMaxBytes
        self.`videoMaxBytes` = videoMaxBytes
        self.`maxAttachments` = maxAttachments
        self.`minClientVersions` = minClientVersions
    }
    enum CodingKeys: String, CodingKey { case `controlConnected`, `methods`, `stt`, `tts`, `imageGeneration`, `apns`, `webPush`, `vapidPublicKey`, `attachmentMaxBytes`, `videoMaxBytes`, `maxAttachments`, `minClientVersions` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`controlConnected` = try c.decode(Bool.self, forKey: .`controlConnected`)
        self.`methods` = try c.decode([String].self, forKey: .`methods`)
        self.`stt` = try c.decode(Bool.self, forKey: .`stt`)
        self.`tts` = try c.decode(Bool.self, forKey: .`tts`)
        self.`imageGeneration` = try c.decode(Bool.self, forKey: .`imageGeneration`)
        self.`apns` = try c.decode(Bool.self, forKey: .`apns`)
        self.`webPush` = try c.decode(Bool.self, forKey: .`webPush`)
        self.`vapidPublicKey` = try c.decode(String?.self, forKey: .`vapidPublicKey`)
        self.`attachmentMaxBytes` = try c.decode(Int.self, forKey: .`attachmentMaxBytes`)
        self.`videoMaxBytes` = try c.decode(Int.self, forKey: .`videoMaxBytes`)
        self.`maxAttachments` = try c.decode(Int.self, forKey: .`maxAttachments`)
        self.`minClientVersions` = try c.decode(CapabilitiesMinClientVersions.self, forKey: .`minClientVersions`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`controlConnected`, forKey: .`controlConnected`)
        try c.encode(`methods`, forKey: .`methods`)
        try c.encode(`stt`, forKey: .`stt`)
        try c.encode(`tts`, forKey: .`tts`)
        try c.encode(`imageGeneration`, forKey: .`imageGeneration`)
        try c.encode(`apns`, forKey: .`apns`)
        try c.encode(`webPush`, forKey: .`webPush`)
        try c.encode(`vapidPublicKey`, forKey: .`vapidPublicKey`)
        try c.encode(`attachmentMaxBytes`, forKey: .`attachmentMaxBytes`)
        try c.encode(`videoMaxBytes`, forKey: .`videoMaxBytes`)
        try c.encode(`maxAttachments`, forKey: .`maxAttachments`)
        try c.encode(`minClientVersions`, forKey: .`minClientVersions`)
    }
}

public struct Machine: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `nodeId`: ID?
    public var `nodeName`: String
    public var `name`: String
    public var `ownerUserId`: ID
    public var `accessUserIds`: [ID]
    public var `status`: String
    public var `lastSeenAtMs`: TimestampMs?
    public var `labels`: [String: String]
    public var `botIds`: [ID]
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, nodeId: ID? = nil, nodeName: String, name: String, ownerUserId: ID, accessUserIds: [ID], status: String, lastSeenAtMs: TimestampMs? = nil, labels: [String: String], botIds: [ID]) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`nodeId` = nodeId
        self.`nodeName` = nodeName
        self.`name` = name
        self.`ownerUserId` = ownerUserId
        self.`accessUserIds` = accessUserIds
        self.`status` = status
        self.`lastSeenAtMs` = lastSeenAtMs
        self.`labels` = labels
        self.`botIds` = botIds
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `nodeId`, `nodeName`, `name`, `ownerUserId`, `accessUserIds`, `status`, `lastSeenAtMs`, `labels`, `botIds` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`nodeId` = try c.decode(ID?.self, forKey: .`nodeId`)
        self.`nodeName` = try c.decode(String.self, forKey: .`nodeName`)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`ownerUserId` = try c.decode(ID.self, forKey: .`ownerUserId`)
        self.`accessUserIds` = try c.decode([ID].self, forKey: .`accessUserIds`)
        self.`status` = try c.decode(String.self, forKey: .`status`)
        guard ["pending", "online", "offline", "revoked"].contains(`status`) else { throw DecodingError.dataCorruptedError(forKey: .`status`, in: c, debugDescription: "Invalid Machine.status") }
        self.`lastSeenAtMs` = try c.decode(TimestampMs?.self, forKey: .`lastSeenAtMs`)
        self.`labels` = try c.decode([String: String].self, forKey: .`labels`)
        self.`botIds` = try c.decode([ID].self, forKey: .`botIds`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`nodeId`, forKey: .`nodeId`)
        try c.encode(`nodeName`, forKey: .`nodeName`)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`ownerUserId`, forKey: .`ownerUserId`)
        try c.encode(`accessUserIds`, forKey: .`accessUserIds`)
        try c.encode(`status`, forKey: .`status`)
        try c.encode(`lastSeenAtMs`, forKey: .`lastSeenAtMs`)
        try c.encode(`labels`, forKey: .`labels`)
        try c.encode(`botIds`, forKey: .`botIds`)
    }
}

public struct HostInfo: Codable, Hashable {
    public var `hostname`: String
    public var `os`: String
    public var `osVersion`: String
    public var `arch`: String
    public var `cpuCount`: Int
    public var `memTotalBytes`: Int
    public var `memFreeBytes`: Int
    public var `diskTotalBytes`: Int
    public var `diskFreeBytes`: Int
    public var `uptimeSec`: Double
    public var `lemonVersion`: String
    public var `defaultCwd`: String
    public var `user`: String
    public var `measuredAtMs`: TimestampMs
    public init(hostname: String, os: String, osVersion: String, arch: String, cpuCount: Int, memTotalBytes: Int, memFreeBytes: Int, diskTotalBytes: Int, diskFreeBytes: Int, uptimeSec: Double, lemonVersion: String, defaultCwd: String, user: String, measuredAtMs: TimestampMs) {
        self.`hostname` = hostname
        self.`os` = os
        self.`osVersion` = osVersion
        self.`arch` = arch
        self.`cpuCount` = cpuCount
        self.`memTotalBytes` = memTotalBytes
        self.`memFreeBytes` = memFreeBytes
        self.`diskTotalBytes` = diskTotalBytes
        self.`diskFreeBytes` = diskFreeBytes
        self.`uptimeSec` = uptimeSec
        self.`lemonVersion` = lemonVersion
        self.`defaultCwd` = defaultCwd
        self.`user` = user
        self.`measuredAtMs` = measuredAtMs
    }
    enum CodingKeys: String, CodingKey { case `hostname`, `os`, `osVersion`, `arch`, `cpuCount`, `memTotalBytes`, `memFreeBytes`, `diskTotalBytes`, `diskFreeBytes`, `uptimeSec`, `lemonVersion`, `defaultCwd`, `user`, `measuredAtMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`hostname` = try c.decode(String.self, forKey: .`hostname`)
        self.`os` = try c.decode(String.self, forKey: .`os`)
        self.`osVersion` = try c.decode(String.self, forKey: .`osVersion`)
        self.`arch` = try c.decode(String.self, forKey: .`arch`)
        self.`cpuCount` = try c.decode(Int.self, forKey: .`cpuCount`)
        self.`memTotalBytes` = try c.decode(Int.self, forKey: .`memTotalBytes`)
        self.`memFreeBytes` = try c.decode(Int.self, forKey: .`memFreeBytes`)
        self.`diskTotalBytes` = try c.decode(Int.self, forKey: .`diskTotalBytes`)
        self.`diskFreeBytes` = try c.decode(Int.self, forKey: .`diskFreeBytes`)
        self.`uptimeSec` = try c.decode(Double.self, forKey: .`uptimeSec`)
        self.`lemonVersion` = try c.decode(String.self, forKey: .`lemonVersion`)
        self.`defaultCwd` = try c.decode(String.self, forKey: .`defaultCwd`)
        self.`user` = try c.decode(String.self, forKey: .`user`)
        self.`measuredAtMs` = try c.decode(TimestampMs.self, forKey: .`measuredAtMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`hostname`, forKey: .`hostname`)
        try c.encode(`os`, forKey: .`os`)
        try c.encode(`osVersion`, forKey: .`osVersion`)
        try c.encode(`arch`, forKey: .`arch`)
        try c.encode(`cpuCount`, forKey: .`cpuCount`)
        try c.encode(`memTotalBytes`, forKey: .`memTotalBytes`)
        try c.encode(`memFreeBytes`, forKey: .`memFreeBytes`)
        try c.encode(`diskTotalBytes`, forKey: .`diskTotalBytes`)
        try c.encode(`diskFreeBytes`, forKey: .`diskFreeBytes`)
        try c.encode(`uptimeSec`, forKey: .`uptimeSec`)
        try c.encode(`lemonVersion`, forKey: .`lemonVersion`)
        try c.encode(`defaultCwd`, forKey: .`defaultCwd`)
        try c.encode(`user`, forKey: .`user`)
        try c.encode(`measuredAtMs`, forKey: .`measuredAtMs`)
    }
}

public struct MachineInvite: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `machineId`: ID
    public var `inviteCode`: String
    public var `joinCommand`: String
    public var `expiresAtMs`: TimestampMs
    public var `status`: String
    public var `enrollment`: String
    public var `lastError`: String?
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, machineId: ID, inviteCode: String, joinCommand: String, expiresAtMs: TimestampMs, status: String, enrollment: String, lastError: String? = nil) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`machineId` = machineId
        self.`inviteCode` = inviteCode
        self.`joinCommand` = joinCommand
        self.`expiresAtMs` = expiresAtMs
        self.`status` = status
        self.`enrollment` = enrollment
        self.`lastError` = lastError
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `machineId`, `inviteCode`, `joinCommand`, `expiresAtMs`, `status`, `enrollment`, `lastError` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`machineId` = try c.decode(ID.self, forKey: .`machineId`)
        self.`inviteCode` = try c.decode(String.self, forKey: .`inviteCode`)
        self.`joinCommand` = try c.decode(String.self, forKey: .`joinCommand`)
        self.`expiresAtMs` = try c.decode(TimestampMs.self, forKey: .`expiresAtMs`)
        self.`status` = try c.decode(String.self, forKey: .`status`)
        guard ["pending", "joined", "expired", "revoked"].contains(`status`) else { throw DecodingError.dataCorruptedError(forKey: .`status`, in: c, debugDescription: "Invalid MachineInvite.status") }
        self.`enrollment` = try c.decode(String.self, forKey: .`enrollment`)
        guard ["invited", "waiting_for_join", "connecting", "verifying", "online", "expired", "failed", "revoked"].contains(`enrollment`) else { throw DecodingError.dataCorruptedError(forKey: .`enrollment`, in: c, debugDescription: "Invalid MachineInvite.enrollment") }
        self.`lastError` = try c.decode(String?.self, forKey: .`lastError`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`machineId`, forKey: .`machineId`)
        try c.encode(`inviteCode`, forKey: .`inviteCode`)
        try c.encode(`joinCommand`, forKey: .`joinCommand`)
        try c.encode(`expiresAtMs`, forKey: .`expiresAtMs`)
        try c.encode(`status`, forKey: .`status`)
        try c.encode(`enrollment`, forKey: .`enrollment`)
        try c.encode(`lastError`, forKey: .`lastError`)
    }
}

public struct MachineAttach: Codable, Hashable {
    public var `clientNonce`: String
    public var `name`: String
    public var `nodeName`: String
    public var `labels`: [String: String]?
    public var `expiresInMs`: Int?
    public init(clientNonce: String, name: String, nodeName: String, labels: [String: String]? = nil, expiresInMs: Int? = nil) {
        self.`clientNonce` = clientNonce
        self.`name` = name
        self.`nodeName` = nodeName
        self.`labels` = labels
        self.`expiresInMs` = expiresInMs
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `name`, `nodeName`, `labels`, `expiresInMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`nodeName` = try c.decode(String.self, forKey: .`nodeName`)
        self.`labels` = try c.decodeOptional([String: String].self, forKey: .`labels`)
        self.`expiresInMs` = try c.decodeOptional(Int.self, forKey: .`expiresInMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`nodeName`, forKey: .`nodeName`)
        try c.encodeIfPresent(`labels`, forKey: .`labels`)
        try c.encodeIfPresent(`expiresInMs`, forKey: .`expiresInMs`)
    }
}

public struct MachineAttachResult: Codable, Hashable {
    public var `machine`: Machine
    public var `invite`: MachineInvite
    public init(machine: Machine, invite: MachineInvite) {
        self.`machine` = machine
        self.`invite` = invite
    }
    enum CodingKeys: String, CodingKey { case `machine`, `invite` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`machine` = try c.decode(Machine.self, forKey: .`machine`)
        self.`invite` = try c.decode(MachineInvite.self, forKey: .`invite`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`machine`, forKey: .`machine`)
        try c.encode(`invite`, forKey: .`invite`)
    }
}

public struct MachineUpdate: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `name`: String?
    public var `accessUserIds`: [ID]?
    public var `labels`: [String: String]?
    public init(clientNonce: String, revision: Int, name: String? = nil, accessUserIds: [ID]? = nil, labels: [String: String]? = nil) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`name` = name
        self.`accessUserIds` = accessUserIds
        self.`labels` = labels
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `name`, `accessUserIds`, `labels` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`name` = try c.decodeOptional(String.self, forKey: .`name`)
        self.`accessUserIds` = try c.decodeOptional([ID].self, forKey: .`accessUserIds`)
        self.`labels` = try c.decodeOptional([String: String].self, forKey: .`labels`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encodeIfPresent(`name`, forKey: .`name`)
        try c.encodeIfPresent(`accessUserIds`, forKey: .`accessUserIds`)
        try c.encodeIfPresent(`labels`, forKey: .`labels`)
    }
}

public struct MachineReconnect: Codable, Hashable {
    public var `clientNonce`: String
    public var `expiresInMs`: Int?
    public init(clientNonce: String, expiresInMs: Int? = nil) {
        self.`clientNonce` = clientNonce
        self.`expiresInMs` = expiresInMs
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `expiresInMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`expiresInMs` = try c.decodeOptional(Int.self, forKey: .`expiresInMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encodeIfPresent(`expiresInMs`, forKey: .`expiresInMs`)
    }
}

public struct FileInfo: Codable, Hashable {
    public var `path`: String
    public var `name`: String
    public var `kind`: String
    public var `size`: Int
    public var `mime`: String?
    public var `modifiedAtMs`: TimestampMs
    public var `readable`: Bool
    public var `writable`: Bool
    public init(path: String, name: String, kind: String, size: Int, mime: String? = nil, modifiedAtMs: TimestampMs, readable: Bool, writable: Bool) {
        self.`path` = path
        self.`name` = name
        self.`kind` = kind
        self.`size` = size
        self.`mime` = mime
        self.`modifiedAtMs` = modifiedAtMs
        self.`readable` = readable
        self.`writable` = writable
    }
    enum CodingKeys: String, CodingKey { case `path`, `name`, `kind`, `size`, `mime`, `modifiedAtMs`, `readable`, `writable` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`path` = try c.decode(String.self, forKey: .`path`)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["file", "directory", "symlink"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid FileInfo.kind") }
        self.`size` = try c.decode(Int.self, forKey: .`size`)
        self.`mime` = try c.decode(String?.self, forKey: .`mime`)
        self.`modifiedAtMs` = try c.decode(TimestampMs.self, forKey: .`modifiedAtMs`)
        self.`readable` = try c.decode(Bool.self, forKey: .`readable`)
        self.`writable` = try c.decode(Bool.self, forKey: .`writable`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`path`, forKey: .`path`)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`size`, forKey: .`size`)
        try c.encode(`mime`, forKey: .`mime`)
        try c.encode(`modifiedAtMs`, forKey: .`modifiedAtMs`)
        try c.encode(`readable`, forKey: .`readable`)
        try c.encode(`writable`, forKey: .`writable`)
    }
}

public struct FileListQuery: Codable, Hashable {
    public var `cursor`: Cursor?
    public var `limit`: Int?
    public var `path`: String
    public var `showHidden`: Bool?
    public init(cursor: Cursor? = nil, limit: Int? = nil, path: String, showHidden: Bool? = nil) {
        self.`cursor` = cursor
        self.`limit` = limit
        self.`path` = path
        self.`showHidden` = showHidden
    }
    enum CodingKeys: String, CodingKey { case `cursor`, `limit`, `path`, `showHidden` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`cursor` = try c.decodeOptional(Cursor.self, forKey: .`cursor`)
        self.`limit` = try c.decodeOptional(Int.self, forKey: .`limit`)
        self.`path` = try c.decode(String.self, forKey: .`path`)
        self.`showHidden` = try c.decodeOptional(Bool.self, forKey: .`showHidden`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(`cursor`, forKey: .`cursor`)
        try c.encodeIfPresent(`limit`, forKey: .`limit`)
        try c.encode(`path`, forKey: .`path`)
        try c.encodeIfPresent(`showHidden`, forKey: .`showHidden`)
    }
}

public struct FilePathQuery: Codable, Hashable {
    public var `path`: String
    public init(path: String) {
        self.`path` = path
    }
    enum CodingKeys: String, CodingKey { case `path` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`path` = try c.decode(String.self, forKey: .`path`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`path`, forKey: .`path`)
    }
}

public struct FileReadQuery: Codable, Hashable {
    public var `path`: String
    public var `offset`: Int?
    public var `length`: Int?
    public init(path: String, offset: Int? = nil, length: Int? = nil) {
        self.`path` = path
        self.`offset` = offset
        self.`length` = length
    }
    enum CodingKeys: String, CodingKey { case `path`, `offset`, `length` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`path` = try c.decode(String.self, forKey: .`path`)
        self.`offset` = try c.decodeOptional(Int.self, forKey: .`offset`)
        self.`length` = try c.decodeOptional(Int.self, forKey: .`length`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`path`, forKey: .`path`)
        try c.encodeIfPresent(`offset`, forKey: .`offset`)
        try c.encodeIfPresent(`length`, forKey: .`length`)
    }
}

public struct FileChunk: Codable, Hashable {
    public var `path`: String
    public var `offset`: Int
    public var `dataBase64`: String
    public var `size`: Int
    public var `mime`: String
    public var `eof`: Bool
    public init(path: String, offset: Int, dataBase64: String, size: Int, mime: String, eof: Bool) {
        self.`path` = path
        self.`offset` = offset
        self.`dataBase64` = dataBase64
        self.`size` = size
        self.`mime` = mime
        self.`eof` = eof
    }
    enum CodingKeys: String, CodingKey { case `path`, `offset`, `dataBase64`, `size`, `mime`, `eof` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`path` = try c.decode(String.self, forKey: .`path`)
        self.`offset` = try c.decode(Int.self, forKey: .`offset`)
        self.`dataBase64` = try c.decode(String.self, forKey: .`dataBase64`)
        self.`size` = try c.decode(Int.self, forKey: .`size`)
        self.`mime` = try c.decode(String.self, forKey: .`mime`)
        self.`eof` = try c.decode(Bool.self, forKey: .`eof`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`path`, forKey: .`path`)
        try c.encode(`offset`, forKey: .`offset`)
        try c.encode(`dataBase64`, forKey: .`dataBase64`)
        try c.encode(`size`, forKey: .`size`)
        try c.encode(`mime`, forKey: .`mime`)
        try c.encode(`eof`, forKey: .`eof`)
    }
}

public struct FileWrite: Codable, Hashable {
    public var `clientNonce`: String
    public var `path`: String
    public var `dataBase64`: String
    public var `offset`: Int?
    public var `truncate`: Bool?
    public var `mkdirs`: Bool?
    public var `expectedModifiedAtMs`: TimestampMs?
    public init(clientNonce: String, path: String, dataBase64: String, offset: Int? = nil, truncate: Bool? = nil, mkdirs: Bool? = nil, expectedModifiedAtMs: TimestampMs? = nil) {
        self.`clientNonce` = clientNonce
        self.`path` = path
        self.`dataBase64` = dataBase64
        self.`offset` = offset
        self.`truncate` = truncate
        self.`mkdirs` = mkdirs
        self.`expectedModifiedAtMs` = expectedModifiedAtMs
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `path`, `dataBase64`, `offset`, `truncate`, `mkdirs`, `expectedModifiedAtMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`path` = try c.decode(String.self, forKey: .`path`)
        self.`dataBase64` = try c.decode(String.self, forKey: .`dataBase64`)
        self.`offset` = try c.decodeOptional(Int.self, forKey: .`offset`)
        self.`truncate` = try c.decodeOptional(Bool.self, forKey: .`truncate`)
        self.`mkdirs` = try c.decodeOptional(Bool.self, forKey: .`mkdirs`)
        self.`expectedModifiedAtMs` = try c.decodeOptional(TimestampMs.self, forKey: .`expectedModifiedAtMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`path`, forKey: .`path`)
        try c.encode(`dataBase64`, forKey: .`dataBase64`)
        try c.encodeIfPresent(`offset`, forKey: .`offset`)
        try c.encodeIfPresent(`truncate`, forKey: .`truncate`)
        try c.encodeIfPresent(`mkdirs`, forKey: .`mkdirs`)
        try c.encodeIfPresent(`expectedModifiedAtMs`, forKey: .`expectedModifiedAtMs`)
    }
}

public struct FileMkdir: Codable, Hashable {
    public var `clientNonce`: String
    public var `path`: String
    public init(clientNonce: String, path: String) {
        self.`clientNonce` = clientNonce
        self.`path` = path
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `path` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`path` = try c.decode(String.self, forKey: .`path`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`path`, forKey: .`path`)
    }
}

public struct FileMove: Codable, Hashable {
    public var `clientNonce`: String
    public var `path`: String
    public var `destination`: String
    public var `expectedModifiedAtMs`: TimestampMs
    public init(clientNonce: String, path: String, destination: String, expectedModifiedAtMs: TimestampMs) {
        self.`clientNonce` = clientNonce
        self.`path` = path
        self.`destination` = destination
        self.`expectedModifiedAtMs` = expectedModifiedAtMs
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `path`, `destination`, `expectedModifiedAtMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`path` = try c.decode(String.self, forKey: .`path`)
        self.`destination` = try c.decode(String.self, forKey: .`destination`)
        self.`expectedModifiedAtMs` = try c.decode(TimestampMs.self, forKey: .`expectedModifiedAtMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`path`, forKey: .`path`)
        try c.encode(`destination`, forKey: .`destination`)
        try c.encode(`expectedModifiedAtMs`, forKey: .`expectedModifiedAtMs`)
    }
}

public struct FileDelete: Codable, Hashable {
    public var `clientNonce`: String
    public var `path`: String
    public var `confirmationToken`: String
    public var `confirmName`: String
    public init(clientNonce: String, path: String, confirmationToken: String, confirmName: String) {
        self.`clientNonce` = clientNonce
        self.`path` = path
        self.`confirmationToken` = confirmationToken
        self.`confirmName` = confirmName
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `path`, `confirmationToken`, `confirmName` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`path` = try c.decode(String.self, forKey: .`path`)
        self.`confirmationToken` = try c.decode(String.self, forKey: .`confirmationToken`)
        self.`confirmName` = try c.decode(String.self, forKey: .`confirmName`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`path`, forKey: .`path`)
        try c.encode(`confirmationToken`, forKey: .`confirmationToken`)
        try c.encode(`confirmName`, forKey: .`confirmName`)
    }
}

public struct FilePreview: Codable, Hashable {
    public var `clientNonce`: String
    public var `path`: String
    public var `action`: String
    public init(clientNonce: String, path: String, action: String) {
        self.`clientNonce` = clientNonce
        self.`path` = path
        self.`action` = action
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `path`, `action` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`path` = try c.decode(String.self, forKey: .`path`)
        self.`action` = try c.decode(String.self, forKey: .`action`)
        guard ["delete"].contains(`action`) else { throw DecodingError.dataCorruptedError(forKey: .`action`, in: c, debugDescription: "Invalid FilePreview.action") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`path`, forKey: .`path`)
        try c.encode(`action`, forKey: .`action`)
    }
}

public struct Secret: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `name`: String
    public var `description`: String
    public var `scope`: String
    public var `botId`: ID?
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, name: String, description: String, scope: String, botId: ID? = nil) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`name` = name
        self.`description` = description
        self.`scope` = scope
        self.`botId` = botId
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `name`, `description`, `scope`, `botId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`description` = try c.decode(String.self, forKey: .`description`)
        self.`scope` = try c.decode(String.self, forKey: .`scope`)
        guard ["machine", "bot"].contains(`scope`) else { throw DecodingError.dataCorruptedError(forKey: .`scope`, in: c, debugDescription: "Invalid Secret.scope") }
        self.`botId` = try c.decode(ID?.self, forKey: .`botId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`description`, forKey: .`description`)
        try c.encode(`scope`, forKey: .`scope`)
        try c.encode(`botId`, forKey: .`botId`)
    }
}

public struct SecretSet: Codable, Hashable {
    public var `clientNonce`: String
    public var `description`: String
    public var `value`: String
    public var `scope`: String
    public var `botId`: ID?
    public init(clientNonce: String, description: String, value: String, scope: String, botId: ID? = nil) {
        self.`clientNonce` = clientNonce
        self.`description` = description
        self.`value` = value
        self.`scope` = scope
        self.`botId` = botId
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `description`, `value`, `scope`, `botId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`description` = try c.decode(String.self, forKey: .`description`)
        self.`value` = try c.decode(String.self, forKey: .`value`)
        self.`scope` = try c.decode(String.self, forKey: .`scope`)
        guard ["machine", "bot"].contains(`scope`) else { throw DecodingError.dataCorruptedError(forKey: .`scope`, in: c, debugDescription: "Invalid SecretSet.scope") }
        self.`botId` = try c.decodeOptional(ID.self, forKey: .`botId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`description`, forKey: .`description`)
        try c.encode(`value`, forKey: .`value`)
        try c.encode(`scope`, forKey: .`scope`)
        try c.encodeIfPresent(`botId`, forKey: .`botId`)
    }
}

public struct Terminal: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `machineId`: ID
    public var `userId`: ID
    public var `deviceId`: ID
    public var `cwd`: String
    public var `cols`: Int
    public var `rows`: Int
    public var `state`: String
    public var `exitCode`: Int?
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, machineId: ID, userId: ID, deviceId: ID, cwd: String, cols: Int, rows: Int, state: String, exitCode: Int? = nil) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`machineId` = machineId
        self.`userId` = userId
        self.`deviceId` = deviceId
        self.`cwd` = cwd
        self.`cols` = cols
        self.`rows` = rows
        self.`state` = state
        self.`exitCode` = exitCode
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `machineId`, `userId`, `deviceId`, `cwd`, `cols`, `rows`, `state`, `exitCode` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`machineId` = try c.decode(ID.self, forKey: .`machineId`)
        self.`userId` = try c.decode(ID.self, forKey: .`userId`)
        self.`deviceId` = try c.decode(ID.self, forKey: .`deviceId`)
        self.`cwd` = try c.decode(String.self, forKey: .`cwd`)
        self.`cols` = try c.decode(Int.self, forKey: .`cols`)
        self.`rows` = try c.decode(Int.self, forKey: .`rows`)
        self.`state` = try c.decode(String.self, forKey: .`state`)
        guard ["open", "closed"].contains(`state`) else { throw DecodingError.dataCorruptedError(forKey: .`state`, in: c, debugDescription: "Invalid Terminal.state") }
        self.`exitCode` = try c.decode(Int?.self, forKey: .`exitCode`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`machineId`, forKey: .`machineId`)
        try c.encode(`userId`, forKey: .`userId`)
        try c.encode(`deviceId`, forKey: .`deviceId`)
        try c.encode(`cwd`, forKey: .`cwd`)
        try c.encode(`cols`, forKey: .`cols`)
        try c.encode(`rows`, forKey: .`rows`)
        try c.encode(`state`, forKey: .`state`)
        try c.encode(`exitCode`, forKey: .`exitCode`)
    }
}

public struct TerminalOpen: Codable, Hashable {
    public var `clientNonce`: String
    public var `deviceId`: ID
    public var `cwd`: String?
    public var `cols`: Int
    public var `rows`: Int
    public init(clientNonce: String, deviceId: ID, cwd: String? = nil, cols: Int, rows: Int) {
        self.`clientNonce` = clientNonce
        self.`deviceId` = deviceId
        self.`cwd` = cwd
        self.`cols` = cols
        self.`rows` = rows
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `deviceId`, `cwd`, `cols`, `rows` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`deviceId` = try c.decode(ID.self, forKey: .`deviceId`)
        self.`cwd` = try c.decodeOptional(String.self, forKey: .`cwd`)
        self.`cols` = try c.decode(Int.self, forKey: .`cols`)
        self.`rows` = try c.decode(Int.self, forKey: .`rows`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`deviceId`, forKey: .`deviceId`)
        try c.encodeIfPresent(`cwd`, forKey: .`cwd`)
        try c.encode(`cols`, forKey: .`cols`)
        try c.encode(`rows`, forKey: .`rows`)
    }
}

public struct TerminalInput: Codable, Hashable {
    public var `clientNonce`: String
    public var `dataBase64`: String
    public init(clientNonce: String, dataBase64: String) {
        self.`clientNonce` = clientNonce
        self.`dataBase64` = dataBase64
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `dataBase64` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`dataBase64` = try c.decode(String.self, forKey: .`dataBase64`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`dataBase64`, forKey: .`dataBase64`)
    }
}

public struct TerminalResize: Codable, Hashable {
    public var `clientNonce`: String
    public var `cols`: Int
    public var `rows`: Int
    public init(clientNonce: String, cols: Int, rows: Int) {
        self.`clientNonce` = clientNonce
        self.`cols` = cols
        self.`rows` = rows
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `cols`, `rows` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`cols` = try c.decode(Int.self, forKey: .`cols`)
        self.`rows` = try c.decode(Int.self, forKey: .`rows`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`cols`, forKey: .`cols`)
        try c.encode(`rows`, forKey: .`rows`)
    }
}

public struct Avatar: Codable, Hashable {
    public var `kind`: String
    public var `shape`: String
    public var `color`: String
    public var `attachmentId`: ID?
    public init(kind: String, shape: String, color: String, attachmentId: ID? = nil) {
        self.`kind` = kind
        self.`shape` = shape
        self.`color` = color
        self.`attachmentId` = attachmentId
    }
    enum CodingKeys: String, CodingKey { case `kind`, `shape`, `color`, `attachmentId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["character", "image"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid Avatar.kind") }
        self.`shape` = try c.decode(String.self, forKey: .`shape`)
        self.`color` = try c.decode(String.self, forKey: .`color`)
        self.`attachmentId` = try c.decode(ID?.self, forKey: .`attachmentId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`shape`, forKey: .`shape`)
        try c.encode(`color`, forKey: .`color`)
        try c.encode(`attachmentId`, forKey: .`attachmentId`)
    }
}

public struct SidebarState: Codable, Hashable {
    public var `pinned`: Bool
    public var `hidden`: Bool
    public var `sectionId`: ID?
    public var `rank`: Int
    public var `unread`: Bool
    public var `notificationsEnabled`: Bool
    public init(pinned: Bool, hidden: Bool, sectionId: ID? = nil, rank: Int, unread: Bool, notificationsEnabled: Bool) {
        self.`pinned` = pinned
        self.`hidden` = hidden
        self.`sectionId` = sectionId
        self.`rank` = rank
        self.`unread` = unread
        self.`notificationsEnabled` = notificationsEnabled
    }
    enum CodingKeys: String, CodingKey { case `pinned`, `hidden`, `sectionId`, `rank`, `unread`, `notificationsEnabled` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`pinned` = try c.decode(Bool.self, forKey: .`pinned`)
        self.`hidden` = try c.decode(Bool.self, forKey: .`hidden`)
        self.`sectionId` = try c.decode(ID?.self, forKey: .`sectionId`)
        self.`rank` = try c.decode(Int.self, forKey: .`rank`)
        self.`unread` = try c.decode(Bool.self, forKey: .`unread`)
        self.`notificationsEnabled` = try c.decode(Bool.self, forKey: .`notificationsEnabled`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`pinned`, forKey: .`pinned`)
        try c.encode(`hidden`, forKey: .`hidden`)
        try c.encode(`sectionId`, forKey: .`sectionId`)
        try c.encode(`rank`, forKey: .`rank`)
        try c.encode(`unread`, forKey: .`unread`)
        try c.encode(`notificationsEnabled`, forKey: .`notificationsEnabled`)
    }
}

public struct Bot: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `ownerUserId`: ID
    public var `machineId`: ID
    public var `profileId`: String
    public var `name`: String
    public var `title`: String
    public var `job`: String
    public var `instructions`: String
    public var `avatar`: Avatar
    public var `voice`: VoiceSettings
    public var `language`: String?
    public var `skillIds`: [ID]
    public var `referenceAttachmentIds`: [ID]
    public var `mainConversationId`: ID
    public var `sidebar`: SidebarState
    public var `activity`: String
    public var `activeRunIds`: [ID]
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, ownerUserId: ID, machineId: ID, profileId: String, name: String, title: String, job: String, instructions: String, avatar: Avatar, voice: VoiceSettings, language: String? = nil, skillIds: [ID], referenceAttachmentIds: [ID], mainConversationId: ID, sidebar: SidebarState, activity: String, activeRunIds: [ID]) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`ownerUserId` = ownerUserId
        self.`machineId` = machineId
        self.`profileId` = profileId
        self.`name` = name
        self.`title` = title
        self.`job` = job
        self.`instructions` = instructions
        self.`avatar` = avatar
        self.`voice` = voice
        self.`language` = language
        self.`skillIds` = skillIds
        self.`referenceAttachmentIds` = referenceAttachmentIds
        self.`mainConversationId` = mainConversationId
        self.`sidebar` = sidebar
        self.`activity` = activity
        self.`activeRunIds` = activeRunIds
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `ownerUserId`, `machineId`, `profileId`, `name`, `title`, `job`, `instructions`, `avatar`, `voice`, `language`, `skillIds`, `referenceAttachmentIds`, `mainConversationId`, `sidebar`, `activity`, `activeRunIds` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`ownerUserId` = try c.decode(ID.self, forKey: .`ownerUserId`)
        self.`machineId` = try c.decode(ID.self, forKey: .`machineId`)
        self.`profileId` = try c.decode(String.self, forKey: .`profileId`)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`title` = try c.decode(String.self, forKey: .`title`)
        self.`job` = try c.decode(String.self, forKey: .`job`)
        self.`instructions` = try c.decode(String.self, forKey: .`instructions`)
        self.`avatar` = try c.decode(Avatar.self, forKey: .`avatar`)
        self.`voice` = try c.decode(VoiceSettings.self, forKey: .`voice`)
        self.`language` = try c.decode(String?.self, forKey: .`language`)
        self.`skillIds` = try c.decode([ID].self, forKey: .`skillIds`)
        self.`referenceAttachmentIds` = try c.decode([ID].self, forKey: .`referenceAttachmentIds`)
        self.`mainConversationId` = try c.decode(ID.self, forKey: .`mainConversationId`)
        self.`sidebar` = try c.decode(SidebarState.self, forKey: .`sidebar`)
        self.`activity` = try c.decode(String.self, forKey: .`activity`)
        self.`activeRunIds` = try c.decode([ID].self, forKey: .`activeRunIds`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`ownerUserId`, forKey: .`ownerUserId`)
        try c.encode(`machineId`, forKey: .`machineId`)
        try c.encode(`profileId`, forKey: .`profileId`)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`title`, forKey: .`title`)
        try c.encode(`job`, forKey: .`job`)
        try c.encode(`instructions`, forKey: .`instructions`)
        try c.encode(`avatar`, forKey: .`avatar`)
        try c.encode(`voice`, forKey: .`voice`)
        try c.encode(`language`, forKey: .`language`)
        try c.encode(`skillIds`, forKey: .`skillIds`)
        try c.encode(`referenceAttachmentIds`, forKey: .`referenceAttachmentIds`)
        try c.encode(`mainConversationId`, forKey: .`mainConversationId`)
        try c.encode(`sidebar`, forKey: .`sidebar`)
        try c.encode(`activity`, forKey: .`activity`)
        try c.encode(`activeRunIds`, forKey: .`activeRunIds`)
    }
}

public struct BotCreate: Codable, Hashable {
    public var `clientNonce`: String
    public var `name`: String
    public var `machineId`: ID
    public var `title`: String?
    public var `job`: String?
    public var `instructions`: String?
    public var `avatar`: Avatar?
    public var `voice`: VoiceSettings?
    public var `language`: String??
    public var `skillIds`: [ID]?
    public var `templateId`: ID?
    public init(clientNonce: String, name: String, machineId: ID, title: String? = nil, job: String? = nil, instructions: String? = nil, avatar: Avatar? = nil, voice: VoiceSettings? = nil, language: String?? = nil, skillIds: [ID]? = nil, templateId: ID? = nil) {
        self.`clientNonce` = clientNonce
        self.`name` = name
        self.`machineId` = machineId
        self.`title` = title
        self.`job` = job
        self.`instructions` = instructions
        self.`avatar` = avatar
        self.`voice` = voice
        self.`language` = language
        self.`skillIds` = skillIds
        self.`templateId` = templateId
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `name`, `machineId`, `title`, `job`, `instructions`, `avatar`, `voice`, `language`, `skillIds`, `templateId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`machineId` = try c.decode(ID.self, forKey: .`machineId`)
        self.`title` = try c.decodeOptional(String.self, forKey: .`title`)
        self.`job` = try c.decodeOptional(String.self, forKey: .`job`)
        self.`instructions` = try c.decodeOptional(String.self, forKey: .`instructions`)
        self.`avatar` = try c.decodeOptional(Avatar.self, forKey: .`avatar`)
        self.`voice` = try c.decodeOptional(VoiceSettings.self, forKey: .`voice`)
        self.`language` = c.contains(.`language`) ? .some(try c.decodeIfPresent(String.self, forKey: .`language`)) : nil
        self.`skillIds` = try c.decodeOptional([ID].self, forKey: .`skillIds`)
        self.`templateId` = try c.decodeOptional(ID.self, forKey: .`templateId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`machineId`, forKey: .`machineId`)
        try c.encodeIfPresent(`title`, forKey: .`title`)
        try c.encodeIfPresent(`job`, forKey: .`job`)
        try c.encodeIfPresent(`instructions`, forKey: .`instructions`)
        try c.encodeIfPresent(`avatar`, forKey: .`avatar`)
        try c.encodeIfPresent(`voice`, forKey: .`voice`)
        if let value = `language` { try c.encode(value, forKey: .`language`) }
        try c.encodeIfPresent(`skillIds`, forKey: .`skillIds`)
        try c.encodeIfPresent(`templateId`, forKey: .`templateId`)
    }
}

public struct BotUpdate: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `name`: String?
    public var `title`: String?
    public var `job`: String?
    public var `instructions`: String?
    public var `avatar`: Avatar?
    public var `voice`: VoiceSettings?
    public var `language`: String??
    public var `skillIds`: [ID]?
    public var `referenceAttachmentIds`: [ID]?
    public init(clientNonce: String, revision: Int, name: String? = nil, title: String? = nil, job: String? = nil, instructions: String? = nil, avatar: Avatar? = nil, voice: VoiceSettings? = nil, language: String?? = nil, skillIds: [ID]? = nil, referenceAttachmentIds: [ID]? = nil) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`name` = name
        self.`title` = title
        self.`job` = job
        self.`instructions` = instructions
        self.`avatar` = avatar
        self.`voice` = voice
        self.`language` = language
        self.`skillIds` = skillIds
        self.`referenceAttachmentIds` = referenceAttachmentIds
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `name`, `title`, `job`, `instructions`, `avatar`, `voice`, `language`, `skillIds`, `referenceAttachmentIds` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`name` = try c.decodeOptional(String.self, forKey: .`name`)
        self.`title` = try c.decodeOptional(String.self, forKey: .`title`)
        self.`job` = try c.decodeOptional(String.self, forKey: .`job`)
        self.`instructions` = try c.decodeOptional(String.self, forKey: .`instructions`)
        self.`avatar` = try c.decodeOptional(Avatar.self, forKey: .`avatar`)
        self.`voice` = try c.decodeOptional(VoiceSettings.self, forKey: .`voice`)
        self.`language` = c.contains(.`language`) ? .some(try c.decodeIfPresent(String.self, forKey: .`language`)) : nil
        self.`skillIds` = try c.decodeOptional([ID].self, forKey: .`skillIds`)
        self.`referenceAttachmentIds` = try c.decodeOptional([ID].self, forKey: .`referenceAttachmentIds`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encodeIfPresent(`name`, forKey: .`name`)
        try c.encodeIfPresent(`title`, forKey: .`title`)
        try c.encodeIfPresent(`job`, forKey: .`job`)
        try c.encodeIfPresent(`instructions`, forKey: .`instructions`)
        try c.encodeIfPresent(`avatar`, forKey: .`avatar`)
        try c.encodeIfPresent(`voice`, forKey: .`voice`)
        if let value = `language` { try c.encode(value, forKey: .`language`) }
        try c.encodeIfPresent(`skillIds`, forKey: .`skillIds`)
        try c.encodeIfPresent(`referenceAttachmentIds`, forKey: .`referenceAttachmentIds`)
    }
}

public struct BotDuplicate: Codable, Hashable {
    public var `clientNonce`: String
    public var `name`: String
    public var `machineId`: ID
    public var `includeSkills`: Bool
    public var `includeRoutines`: Bool
    public init(clientNonce: String, name: String, machineId: ID, includeSkills: Bool, includeRoutines: Bool) {
        self.`clientNonce` = clientNonce
        self.`name` = name
        self.`machineId` = machineId
        self.`includeSkills` = includeSkills
        self.`includeRoutines` = includeRoutines
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `name`, `machineId`, `includeSkills`, `includeRoutines` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`machineId` = try c.decode(ID.self, forKey: .`machineId`)
        self.`includeSkills` = try c.decode(Bool.self, forKey: .`includeSkills`)
        self.`includeRoutines` = try c.decode(Bool.self, forKey: .`includeRoutines`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`machineId`, forKey: .`machineId`)
        try c.encode(`includeSkills`, forKey: .`includeSkills`)
        try c.encode(`includeRoutines`, forKey: .`includeRoutines`)
    }
}

public struct BotMove: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `confirmationToken`: String
    public var `confirmName`: String
    public var `machineId`: ID
    public init(clientNonce: String, revision: Int, confirmationToken: String, confirmName: String, machineId: ID) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`confirmationToken` = confirmationToken
        self.`confirmName` = confirmName
        self.`machineId` = machineId
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `confirmationToken`, `confirmName`, `machineId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`confirmationToken` = try c.decode(String.self, forKey: .`confirmationToken`)
        self.`confirmName` = try c.decode(String.self, forKey: .`confirmName`)
        self.`machineId` = try c.decode(ID.self, forKey: .`machineId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`confirmationToken`, forKey: .`confirmationToken`)
        try c.encode(`confirmName`, forKey: .`confirmName`)
        try c.encode(`machineId`, forKey: .`machineId`)
    }
}


public struct SidebarUpdate: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `pinned`: Bool?
    public var `hidden`: Bool?
    public var `sectionId`: ID??
    public var `rank`: Int?
    public var `unread`: Bool?
    public var `notificationsEnabled`: Bool?
    public init(clientNonce: String, revision: Int, pinned: Bool? = nil, hidden: Bool? = nil, sectionId: ID?? = nil, rank: Int? = nil, unread: Bool? = nil, notificationsEnabled: Bool? = nil) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`pinned` = pinned
        self.`hidden` = hidden
        self.`sectionId` = sectionId
        self.`rank` = rank
        self.`unread` = unread
        self.`notificationsEnabled` = notificationsEnabled
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `pinned`, `hidden`, `sectionId`, `rank`, `unread`, `notificationsEnabled` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`pinned` = try c.decodeOptional(Bool.self, forKey: .`pinned`)
        self.`hidden` = try c.decodeOptional(Bool.self, forKey: .`hidden`)
        self.`sectionId` = c.contains(.`sectionId`) ? .some(try c.decodeIfPresent(ID.self, forKey: .`sectionId`)) : nil
        self.`rank` = try c.decodeOptional(Int.self, forKey: .`rank`)
        self.`unread` = try c.decodeOptional(Bool.self, forKey: .`unread`)
        self.`notificationsEnabled` = try c.decodeOptional(Bool.self, forKey: .`notificationsEnabled`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encodeIfPresent(`pinned`, forKey: .`pinned`)
        try c.encodeIfPresent(`hidden`, forKey: .`hidden`)
        if let value = `sectionId` { try c.encode(value, forKey: .`sectionId`) }
        try c.encodeIfPresent(`rank`, forKey: .`rank`)
        try c.encodeIfPresent(`unread`, forKey: .`unread`)
        try c.encodeIfPresent(`notificationsEnabled`, forKey: .`notificationsEnabled`)
    }
}

public struct AvatarGenerate: Codable, Hashable {
    public var `clientNonce`: String
    public var `prompt`: String
    public init(clientNonce: String, prompt: String) {
        self.`clientNonce` = clientNonce
        self.`prompt` = prompt
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `prompt` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`prompt` = try c.decode(String.self, forKey: .`prompt`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`prompt`, forKey: .`prompt`)
    }
}

public struct Section: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `userId`: ID
    public var `name`: String
    public var `rank`: Int
    public var `collapsed`: Bool
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, userId: ID, name: String, rank: Int, collapsed: Bool) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`userId` = userId
        self.`name` = name
        self.`rank` = rank
        self.`collapsed` = collapsed
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `userId`, `name`, `rank`, `collapsed` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`userId` = try c.decode(ID.self, forKey: .`userId`)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`rank` = try c.decode(Int.self, forKey: .`rank`)
        self.`collapsed` = try c.decode(Bool.self, forKey: .`collapsed`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`userId`, forKey: .`userId`)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`rank`, forKey: .`rank`)
        try c.encode(`collapsed`, forKey: .`collapsed`)
    }
}

public struct SectionCreate: Codable, Hashable {
    public var `clientNonce`: String
    public var `name`: String
    public var `rank`: Int?
    public init(clientNonce: String, name: String, rank: Int? = nil) {
        self.`clientNonce` = clientNonce
        self.`name` = name
        self.`rank` = rank
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `name`, `rank` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`rank` = try c.decodeOptional(Int.self, forKey: .`rank`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`name`, forKey: .`name`)
        try c.encodeIfPresent(`rank`, forKey: .`rank`)
    }
}

public struct SectionUpdate: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `name`: String?
    public var `rank`: Int?
    public var `collapsed`: Bool?
    public init(clientNonce: String, revision: Int, name: String? = nil, rank: Int? = nil, collapsed: Bool? = nil) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`name` = name
        self.`rank` = rank
        self.`collapsed` = collapsed
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `name`, `rank`, `collapsed` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`name` = try c.decodeOptional(String.self, forKey: .`name`)
        self.`rank` = try c.decodeOptional(Int.self, forKey: .`rank`)
        self.`collapsed` = try c.decodeOptional(Bool.self, forKey: .`collapsed`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encodeIfPresent(`name`, forKey: .`name`)
        try c.encodeIfPresent(`rank`, forKey: .`rank`)
        try c.encodeIfPresent(`collapsed`, forKey: .`collapsed`)
    }
}

public struct TemplateContent: Codable, Hashable {
    public var `name`: String
    public var `title`: String
    public var `job`: String
    public var `instructions`: String
    public var `avatar`: Avatar
    public var `voice`: VoiceSettings
    public var `skills`: [TemplateContentSkills]
    public var `routines`: [RoutineSpec]
    public var `connectorNames`: [String]
    public init(name: String, title: String, job: String, instructions: String, avatar: Avatar, voice: VoiceSettings, skills: [TemplateContentSkills], routines: [RoutineSpec], connectorNames: [String]) {
        self.`name` = name
        self.`title` = title
        self.`job` = job
        self.`instructions` = instructions
        self.`avatar` = avatar
        self.`voice` = voice
        self.`skills` = skills
        self.`routines` = routines
        self.`connectorNames` = connectorNames
    }
    enum CodingKeys: String, CodingKey { case `name`, `title`, `job`, `instructions`, `avatar`, `voice`, `skills`, `routines`, `connectorNames` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`title` = try c.decode(String.self, forKey: .`title`)
        self.`job` = try c.decode(String.self, forKey: .`job`)
        self.`instructions` = try c.decode(String.self, forKey: .`instructions`)
        self.`avatar` = try c.decode(Avatar.self, forKey: .`avatar`)
        self.`voice` = try c.decode(VoiceSettings.self, forKey: .`voice`)
        self.`skills` = try c.decode([TemplateContentSkills].self, forKey: .`skills`)
        self.`routines` = try c.decode([RoutineSpec].self, forKey: .`routines`)
        self.`connectorNames` = try c.decode([String].self, forKey: .`connectorNames`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`title`, forKey: .`title`)
        try c.encode(`job`, forKey: .`job`)
        try c.encode(`instructions`, forKey: .`instructions`)
        try c.encode(`avatar`, forKey: .`avatar`)
        try c.encode(`voice`, forKey: .`voice`)
        try c.encode(`skills`, forKey: .`skills`)
        try c.encode(`routines`, forKey: .`routines`)
        try c.encode(`connectorNames`, forKey: .`connectorNames`)
    }
}

public struct BotTemplate: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `ownerUserId`: ID
    public var `audience`: String
    public var `sourceBotId`: ID?
    public var `content`: TemplateContent
    public var `provenance`: BotTemplateProvenance
    public var `shareUrl`: String
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, ownerUserId: ID, audience: String, sourceBotId: ID? = nil, content: TemplateContent, provenance: BotTemplateProvenance, shareUrl: String) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`ownerUserId` = ownerUserId
        self.`audience` = audience
        self.`sourceBotId` = sourceBotId
        self.`content` = content
        self.`provenance` = provenance
        self.`shareUrl` = shareUrl
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `ownerUserId`, `audience`, `sourceBotId`, `content`, `provenance`, `shareUrl` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`ownerUserId` = try c.decode(ID.self, forKey: .`ownerUserId`)
        self.`audience` = try c.decode(String.self, forKey: .`audience`)
        guard ["workspace", "public"].contains(`audience`) else { throw DecodingError.dataCorruptedError(forKey: .`audience`, in: c, debugDescription: "Invalid BotTemplate.audience") }
        self.`sourceBotId` = try c.decode(ID?.self, forKey: .`sourceBotId`)
        self.`content` = try c.decode(TemplateContent.self, forKey: .`content`)
        self.`provenance` = try c.decode(BotTemplateProvenance.self, forKey: .`provenance`)
        self.`shareUrl` = try c.decode(String.self, forKey: .`shareUrl`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`ownerUserId`, forKey: .`ownerUserId`)
        try c.encode(`audience`, forKey: .`audience`)
        try c.encode(`sourceBotId`, forKey: .`sourceBotId`)
        try c.encode(`content`, forKey: .`content`)
        try c.encode(`provenance`, forKey: .`provenance`)
        try c.encode(`shareUrl`, forKey: .`shareUrl`)
    }
}

public struct TemplateCreate: Codable, Hashable {
    public var `clientNonce`: String
    public var `botId`: ID
    public var `audience`: String
    public var `reviewed`: Bool
    public init(clientNonce: String, botId: ID, audience: String, reviewed: Bool) {
        self.`clientNonce` = clientNonce
        self.`botId` = botId
        self.`audience` = audience
        self.`reviewed` = reviewed
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `botId`, `audience`, `reviewed` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`botId` = try c.decode(ID.self, forKey: .`botId`)
        self.`audience` = try c.decode(String.self, forKey: .`audience`)
        self.`reviewed` = try c.decode(Bool.self, forKey: .`reviewed`)
        guard `reviewed` == true else { throw DecodingError.dataCorruptedError(forKey: .`reviewed`, in: c, debugDescription: "Invalid literal TemplateCreate.reviewed") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`audience`, forKey: .`audience`)
        try c.encode(`reviewed`, forKey: .`reviewed`)
    }
}

public struct TemplateUpdate: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `audience`: String?
    public var `content`: TemplateContent?
    public var `reviewed`: Bool
    public init(clientNonce: String, revision: Int, audience: String? = nil, content: TemplateContent? = nil, reviewed: Bool) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`audience` = audience
        self.`content` = content
        self.`reviewed` = reviewed
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `audience`, `content`, `reviewed` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`audience` = try c.decodeOptional(String.self, forKey: .`audience`)
        self.`content` = try c.decodeOptional(TemplateContent.self, forKey: .`content`)
        self.`reviewed` = try c.decode(Bool.self, forKey: .`reviewed`)
        guard `reviewed` == true else { throw DecodingError.dataCorruptedError(forKey: .`reviewed`, in: c, debugDescription: "Invalid literal TemplateUpdate.reviewed") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encodeIfPresent(`audience`, forKey: .`audience`)
        try c.encodeIfPresent(`content`, forKey: .`content`)
        try c.encode(`reviewed`, forKey: .`reviewed`)
    }
}

public struct TemplateImport: Codable, Hashable {
    public var `clientNonce`: String
    public var `name`: String
    public var `machineId`: ID
    public var `acceptedTerms`: Bool
    public init(clientNonce: String, name: String, machineId: ID, acceptedTerms: Bool) {
        self.`clientNonce` = clientNonce
        self.`name` = name
        self.`machineId` = machineId
        self.`acceptedTerms` = acceptedTerms
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `name`, `machineId`, `acceptedTerms` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`machineId` = try c.decode(ID.self, forKey: .`machineId`)
        self.`acceptedTerms` = try c.decode(Bool.self, forKey: .`acceptedTerms`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`machineId`, forKey: .`machineId`)
        try c.encode(`acceptedTerms`, forKey: .`acceptedTerms`)
    }
}

public struct Conversation: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `kind`: ConversationKind
    public var `name`: String
    public var `botIds`: [ID]
    public var `ownerUserId`: ID
    public var `parentConversationId`: ID?
    public var `leadBotId`: ID?
    public var `channelBindingId`: ID?
    public var `lastEntryId`: ID?
    public var `unreadCount`: Int
    public var `lastReadSeq`: Int
    public var `activity`: [ConversationActivity]
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, kind: ConversationKind, name: String, botIds: [ID], ownerUserId: ID, parentConversationId: ID? = nil, leadBotId: ID? = nil, channelBindingId: ID? = nil, lastEntryId: ID? = nil, unreadCount: Int, lastReadSeq: Int, activity: [ConversationActivity]) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`kind` = kind
        self.`name` = name
        self.`botIds` = botIds
        self.`ownerUserId` = ownerUserId
        self.`parentConversationId` = parentConversationId
        self.`leadBotId` = leadBotId
        self.`channelBindingId` = channelBindingId
        self.`lastEntryId` = lastEntryId
        self.`unreadCount` = unreadCount
        self.`lastReadSeq` = lastReadSeq
        self.`activity` = activity
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `kind`, `name`, `botIds`, `ownerUserId`, `parentConversationId`, `leadBotId`, `channelBindingId`, `lastEntryId`, `unreadCount`, `lastReadSeq`, `activity` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`kind` = try c.decode(ConversationKind.self, forKey: .`kind`)
        guard ["dm", "task", "group", "channel"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid Conversation.kind") }
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`botIds` = try c.decode([ID].self, forKey: .`botIds`)
        self.`ownerUserId` = try c.decode(ID.self, forKey: .`ownerUserId`)
        self.`parentConversationId` = try c.decode(ID?.self, forKey: .`parentConversationId`)
        self.`leadBotId` = try c.decode(ID?.self, forKey: .`leadBotId`)
        self.`channelBindingId` = try c.decode(ID?.self, forKey: .`channelBindingId`)
        self.`lastEntryId` = try c.decode(ID?.self, forKey: .`lastEntryId`)
        self.`unreadCount` = try c.decode(Int.self, forKey: .`unreadCount`)
        self.`lastReadSeq` = try c.decode(Int.self, forKey: .`lastReadSeq`)
        self.`activity` = try c.decode([ConversationActivity].self, forKey: .`activity`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        guard ["dm", "task", "group", "channel"].contains(`kind`) else { throw EncodingError.invalidValue(`kind`, .init(codingPath: c.codingPath + [CodingKeys.kind], debugDescription: "Invalid Conversation.kind")) }
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`botIds`, forKey: .`botIds`)
        try c.encode(`ownerUserId`, forKey: .`ownerUserId`)
        try c.encode(`parentConversationId`, forKey: .`parentConversationId`)
        try c.encode(`leadBotId`, forKey: .`leadBotId`)
        try c.encode(`channelBindingId`, forKey: .`channelBindingId`)
        try c.encode(`lastEntryId`, forKey: .`lastEntryId`)
        try c.encode(`unreadCount`, forKey: .`unreadCount`)
        try c.encode(`lastReadSeq`, forKey: .`lastReadSeq`)
        try c.encode(`activity`, forKey: .`activity`)
    }
}

public struct ConversationCreate: Codable, Hashable {
    public var `clientNonce`: String
    public var `kind`: ConversationKind
    public var `name`: String?
    public var `botIds`: [ID]
    public var `parentConversationId`: ID?
    public var `leadBotId`: ID?
    public init(clientNonce: String, kind: ConversationKind, name: String? = nil, botIds: [ID], parentConversationId: ID? = nil, leadBotId: ID? = nil) {
        self.`clientNonce` = clientNonce
        self.`kind` = kind
        self.`name` = name
        self.`botIds` = botIds
        self.`parentConversationId` = parentConversationId
        self.`leadBotId` = leadBotId
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `kind`, `name`, `botIds`, `parentConversationId`, `leadBotId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`kind` = try c.decode(ConversationKind.self, forKey: .`kind`)
        guard ["dm", "task", "group", "channel"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid ConversationCreate.kind") }
        self.`name` = try c.decodeOptional(String.self, forKey: .`name`)
        self.`botIds` = try c.decode([ID].self, forKey: .`botIds`)
        self.`parentConversationId` = try c.decodeOptional(ID.self, forKey: .`parentConversationId`)
        self.`leadBotId` = try c.decodeOptional(ID.self, forKey: .`leadBotId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        guard ["dm", "task", "group", "channel"].contains(`kind`) else { throw EncodingError.invalidValue(`kind`, .init(codingPath: c.codingPath + [CodingKeys.kind], debugDescription: "Invalid ConversationCreate.kind")) }
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encodeIfPresent(`name`, forKey: .`name`)
        try c.encode(`botIds`, forKey: .`botIds`)
        try c.encodeIfPresent(`parentConversationId`, forKey: .`parentConversationId`)
        try c.encodeIfPresent(`leadBotId`, forKey: .`leadBotId`)
    }
}

public struct ConversationUpdate: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `name`: String?
    public var `botIds`: [ID]?
    public var `leadBotId`: ID??
    public init(clientNonce: String, revision: Int, name: String? = nil, botIds: [ID]? = nil, leadBotId: ID?? = nil) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`name` = name
        self.`botIds` = botIds
        self.`leadBotId` = leadBotId
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `name`, `botIds`, `leadBotId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`name` = try c.decodeOptional(String.self, forKey: .`name`)
        self.`botIds` = try c.decodeOptional([ID].self, forKey: .`botIds`)
        self.`leadBotId` = c.contains(.`leadBotId`) ? .some(try c.decodeIfPresent(ID.self, forKey: .`leadBotId`)) : nil
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encodeIfPresent(`name`, forKey: .`name`)
        try c.encodeIfPresent(`botIds`, forKey: .`botIds`)
        if let value = `leadBotId` { try c.encode(value, forKey: .`leadBotId`) }
    }
}

public struct ReadRequest: Codable, Hashable {
    public var `clientNonce`: String
    public var `throughSeq`: Int
    public var `unread`: Bool?
    public init(clientNonce: String, throughSeq: Int, unread: Bool? = nil) {
        self.`clientNonce` = clientNonce
        self.`throughSeq` = throughSeq
        self.`unread` = unread
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `throughSeq`, `unread` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`throughSeq` = try c.decode(Int.self, forKey: .`throughSeq`)
        self.`unread` = try c.decodeOptional(Bool.self, forKey: .`unread`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`throughSeq`, forKey: .`throughSeq`)
        try c.encodeIfPresent(`unread`, forKey: .`unread`)
    }
}

public struct ComposerDraft: Codable, Hashable {
    public var `conversationId`: ID
    public var `text`: String
    public var `attachmentIds`: [ID]
    public var `replyToEntryId`: ID?
    public var `updatedAtMs`: TimestampMs
    public var `revision`: Int
    public init(conversationId: ID, text: String, attachmentIds: [ID], replyToEntryId: ID? = nil, updatedAtMs: TimestampMs, revision: Int) {
        self.`conversationId` = conversationId
        self.`text` = text
        self.`attachmentIds` = attachmentIds
        self.`replyToEntryId` = replyToEntryId
        self.`updatedAtMs` = updatedAtMs
        self.`revision` = revision
    }
    enum CodingKeys: String, CodingKey { case `conversationId`, `text`, `attachmentIds`, `replyToEntryId`, `updatedAtMs`, `revision` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`conversationId` = try c.decode(ID.self, forKey: .`conversationId`)
        self.`text` = try c.decode(String.self, forKey: .`text`)
        self.`attachmentIds` = try c.decode([ID].self, forKey: .`attachmentIds`)
        self.`replyToEntryId` = try c.decode(ID?.self, forKey: .`replyToEntryId`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`conversationId`, forKey: .`conversationId`)
        try c.encode(`text`, forKey: .`text`)
        try c.encode(`attachmentIds`, forKey: .`attachmentIds`)
        try c.encode(`replyToEntryId`, forKey: .`replyToEntryId`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`revision`, forKey: .`revision`)
    }
}

public struct ComposerDraftUpdate: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `text`: String
    public var `attachmentIds`: [ID]
    public var `replyToEntryId`: ID??
    public init(clientNonce: String, revision: Int, text: String, attachmentIds: [ID], replyToEntryId: ID?? = nil) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`text` = text
        self.`attachmentIds` = attachmentIds
        self.`replyToEntryId` = replyToEntryId
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `text`, `attachmentIds`, `replyToEntryId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`text` = try c.decode(String.self, forKey: .`text`)
        self.`attachmentIds` = try c.decode([ID].self, forKey: .`attachmentIds`)
        self.`replyToEntryId` = c.contains(.`replyToEntryId`) ? .some(try c.decodeIfPresent(ID.self, forKey: .`replyToEntryId`)) : nil
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`text`, forKey: .`text`)
        try c.encode(`attachmentIds`, forKey: .`attachmentIds`)
        if let value = `replyToEntryId` { try c.encode(value, forKey: .`replyToEntryId`) }
    }
}

public struct MessageSend: Codable, Hashable {
    public var `clientNonce`: String
    public var `text`: String
    public var `attachmentIds`: [ID]?
    public var `replyToEntryId`: ID?
    public var `mentions`: [ID]?
    public var `everyone`: Bool?
    public var `references`: [Reference]?
    public var `mode`: String?
    public var `voiceSessionId`: ID?
    public init(clientNonce: String, text: String, attachmentIds: [ID]? = nil, replyToEntryId: ID? = nil, mentions: [ID]? = nil, everyone: Bool? = nil, references: [Reference]? = nil, mode: String? = nil, voiceSessionId: ID? = nil) {
        self.`clientNonce` = clientNonce
        self.`text` = text
        self.`attachmentIds` = attachmentIds
        self.`replyToEntryId` = replyToEntryId
        self.`mentions` = mentions
        self.`everyone` = everyone
        self.`references` = references
        self.`mode` = mode
        self.`voiceSessionId` = voiceSessionId
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `text`, `attachmentIds`, `replyToEntryId`, `mentions`, `everyone`, `references`, `mode`, `voiceSessionId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`text` = try c.decode(String.self, forKey: .`text`)
        self.`attachmentIds` = try c.decodeOptional([ID].self, forKey: .`attachmentIds`)
        self.`replyToEntryId` = try c.decodeOptional(ID.self, forKey: .`replyToEntryId`)
        self.`mentions` = try c.decodeOptional([ID].self, forKey: .`mentions`)
        self.`everyone` = try c.decodeOptional(Bool.self, forKey: .`everyone`)
        self.`references` = try c.decodeOptional([Reference].self, forKey: .`references`)
        self.`mode` = try c.decodeOptional(String.self, forKey: .`mode`)
        self.`voiceSessionId` = try c.decodeOptional(ID.self, forKey: .`voiceSessionId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`text`, forKey: .`text`)
        try c.encodeIfPresent(`attachmentIds`, forKey: .`attachmentIds`)
        try c.encodeIfPresent(`replyToEntryId`, forKey: .`replyToEntryId`)
        try c.encodeIfPresent(`mentions`, forKey: .`mentions`)
        try c.encodeIfPresent(`everyone`, forKey: .`everyone`)
        try c.encodeIfPresent(`references`, forKey: .`references`)
        try c.encodeIfPresent(`mode`, forKey: .`mode`)
        try c.encodeIfPresent(`voiceSessionId`, forKey: .`voiceSessionId`)
    }
}

public struct Run: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `conversationId`: ID
    public var `botId`: ID
    public var `initiatorUserId`: ID
    public var `clientNonce`: String
    public var `status`: String
    public var `error`: RunError?
    public var `startedAtMs`: TimestampMs?
    public var `completedAtMs`: TimestampMs?
    public var `routineRunId`: ID?
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, conversationId: ID, botId: ID, initiatorUserId: ID, clientNonce: String, status: String, error: RunError? = nil, startedAtMs: TimestampMs? = nil, completedAtMs: TimestampMs? = nil, routineRunId: ID? = nil) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`conversationId` = conversationId
        self.`botId` = botId
        self.`initiatorUserId` = initiatorUserId
        self.`clientNonce` = clientNonce
        self.`status` = status
        self.`error` = error
        self.`startedAtMs` = startedAtMs
        self.`completedAtMs` = completedAtMs
        self.`routineRunId` = routineRunId
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `conversationId`, `botId`, `initiatorUserId`, `clientNonce`, `status`, `error`, `startedAtMs`, `completedAtMs`, `routineRunId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`conversationId` = try c.decode(ID.self, forKey: .`conversationId`)
        self.`botId` = try c.decode(ID.self, forKey: .`botId`)
        self.`initiatorUserId` = try c.decode(ID.self, forKey: .`initiatorUserId`)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`status` = try c.decode(String.self, forKey: .`status`)
        guard ["reserved", "queued", "running", "awaiting_input", "succeeded", "failed", "cancelled", "outcome_unknown"].contains(`status`) else { throw DecodingError.dataCorruptedError(forKey: .`status`, in: c, debugDescription: "Invalid Run.status") }
        self.`error` = try c.decode(RunError?.self, forKey: .`error`)
        self.`startedAtMs` = try c.decode(TimestampMs?.self, forKey: .`startedAtMs`)
        self.`completedAtMs` = try c.decode(TimestampMs?.self, forKey: .`completedAtMs`)
        self.`routineRunId` = try c.decode(ID?.self, forKey: .`routineRunId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`conversationId`, forKey: .`conversationId`)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`initiatorUserId`, forKey: .`initiatorUserId`)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`status`, forKey: .`status`)
        try c.encode(`error`, forKey: .`error`)
        try c.encode(`startedAtMs`, forKey: .`startedAtMs`)
        try c.encode(`completedAtMs`, forKey: .`completedAtMs`)
        try c.encode(`routineRunId`, forKey: .`routineRunId`)
    }
}

public struct MessageReceipt: Codable, Hashable {
    public var `entries`: [TranscriptEntry]
    public var `runs`: [Run]
    public var `clientNonce`: String
    public var `status`: String
    public var `delivery`: [MessageReceiptDelivery]
    public init(entries: [TranscriptEntry], runs: [Run], clientNonce: String, status: String, delivery: [MessageReceiptDelivery]) {
        self.`entries` = entries
        self.`runs` = runs
        self.`clientNonce` = clientNonce
        self.`status` = status
        self.`delivery` = delivery
    }
    enum CodingKeys: String, CodingKey { case `entries`, `runs`, `clientNonce`, `status`, `delivery` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`entries` = try c.decode([TranscriptEntry].self, forKey: .`entries`)
        self.`runs` = try c.decode([Run].self, forKey: .`runs`)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`status` = try c.decode(String.self, forKey: .`status`)
        guard ["accepted", "queued", "outcome_unknown"].contains(`status`) else { throw DecodingError.dataCorruptedError(forKey: .`status`, in: c, debugDescription: "Invalid MessageReceipt.status") }
        self.`delivery` = try c.decode([MessageReceiptDelivery].self, forKey: .`delivery`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`entries`, forKey: .`entries`)
        try c.encode(`runs`, forKey: .`runs`)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`status`, forKey: .`status`)
        try c.encode(`delivery`, forKey: .`delivery`)
    }
}

public struct RunCancel: Codable, Hashable {
    public var `clientNonce`: String
    public var `reason`: String?
    public init(clientNonce: String, reason: String? = nil) {
        self.`clientNonce` = clientNonce
        self.`reason` = reason
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `reason` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`reason` = try c.decodeOptional(String.self, forKey: .`reason`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encodeIfPresent(`reason`, forKey: .`reason`)
    }
}

public struct Reaction: Codable, Hashable {
    public var `emoji`: String
    public var `userIds`: [ID]
    public init(emoji: String, userIds: [ID]) {
        self.`emoji` = emoji
        self.`userIds` = userIds
    }
    enum CodingKeys: String, CodingKey { case `emoji`, `userIds` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`emoji` = try c.decode(String.self, forKey: .`emoji`)
        self.`userIds` = try c.decode([ID].self, forKey: .`userIds`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`emoji`, forKey: .`emoji`)
        try c.encode(`userIds`, forKey: .`userIds`)
    }
}

public struct EntryBase: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `conversationId`: ID
    public var `seq`: Int
    public var `timestampMs`: TimestampMs
    public var `actor`: Actor
    public var `clientNonce`: String?
    public var `batchId`: ID?
    public var `replyToEntryId`: ID?
    public var `runId`: ID?
    public var `targetedUserId`: ID?
    public var `reactions`: [Reaction]
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, conversationId: ID, seq: Int, timestampMs: TimestampMs, actor: Actor, clientNonce: String? = nil, batchId: ID? = nil, replyToEntryId: ID? = nil, runId: ID? = nil, targetedUserId: ID? = nil, reactions: [Reaction]) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`conversationId` = conversationId
        self.`seq` = seq
        self.`timestampMs` = timestampMs
        self.`actor` = actor
        self.`clientNonce` = clientNonce
        self.`batchId` = batchId
        self.`replyToEntryId` = replyToEntryId
        self.`runId` = runId
        self.`targetedUserId` = targetedUserId
        self.`reactions` = reactions
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `conversationId`, `seq`, `timestampMs`, `actor`, `clientNonce`, `batchId`, `replyToEntryId`, `runId`, `targetedUserId`, `reactions` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`conversationId` = try c.decode(ID.self, forKey: .`conversationId`)
        self.`seq` = try c.decode(Int.self, forKey: .`seq`)
        self.`timestampMs` = try c.decode(TimestampMs.self, forKey: .`timestampMs`)
        self.`actor` = try c.decode(Actor.self, forKey: .`actor`)
        self.`clientNonce` = try c.decode(String?.self, forKey: .`clientNonce`)
        self.`batchId` = try c.decode(ID?.self, forKey: .`batchId`)
        self.`replyToEntryId` = try c.decode(ID?.self, forKey: .`replyToEntryId`)
        self.`runId` = try c.decode(ID?.self, forKey: .`runId`)
        self.`targetedUserId` = try c.decode(ID?.self, forKey: .`targetedUserId`)
        self.`reactions` = try c.decode([Reaction].self, forKey: .`reactions`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`conversationId`, forKey: .`conversationId`)
        try c.encode(`seq`, forKey: .`seq`)
        try c.encode(`timestampMs`, forKey: .`timestampMs`)
        try c.encode(`actor`, forKey: .`actor`)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`batchId`, forKey: .`batchId`)
        try c.encode(`replyToEntryId`, forKey: .`replyToEntryId`)
        try c.encode(`runId`, forKey: .`runId`)
        try c.encode(`targetedUserId`, forKey: .`targetedUserId`)
        try c.encode(`reactions`, forKey: .`reactions`)
    }
}

public struct Gate: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `state`: ResolutionState
    public var `targetUserId`: ID
    public var `expiresAtMs`: TimestampMs
    public var `resolvedAtMs`: TimestampMs?
    public var `resolvedByUserId`: ID?
    public var `revision`: Int
    public init(id: ID, state: ResolutionState, targetUserId: ID, expiresAtMs: TimestampMs, resolvedAtMs: TimestampMs? = nil, resolvedByUserId: ID? = nil, revision: Int) {
        self.`id` = id
        self.`state` = state
        self.`targetUserId` = targetUserId
        self.`expiresAtMs` = expiresAtMs
        self.`resolvedAtMs` = resolvedAtMs
        self.`resolvedByUserId` = resolvedByUserId
        self.`revision` = revision
    }
    enum CodingKeys: String, CodingKey { case `id`, `state`, `targetUserId`, `expiresAtMs`, `resolvedAtMs`, `resolvedByUserId`, `revision` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`state` = try c.decode(ResolutionState.self, forKey: .`state`)
        self.`targetUserId` = try c.decode(ID.self, forKey: .`targetUserId`)
        self.`expiresAtMs` = try c.decode(TimestampMs.self, forKey: .`expiresAtMs`)
        self.`resolvedAtMs` = try c.decode(TimestampMs?.self, forKey: .`resolvedAtMs`)
        self.`resolvedByUserId` = try c.decode(ID?.self, forKey: .`resolvedByUserId`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`state`, forKey: .`state`)
        try c.encode(`targetUserId`, forKey: .`targetUserId`)
        try c.encode(`expiresAtMs`, forKey: .`expiresAtMs`)
        try c.encode(`resolvedAtMs`, forKey: .`resolvedAtMs`)
        try c.encode(`resolvedByUserId`, forKey: .`resolvedByUserId`)
        try c.encode(`revision`, forKey: .`revision`)
    }
}

public struct Approval: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `gate`: Gate
    public var `entryId`: ID
    public var `conversationId`: ID
    public var `botId`: ID
    public var `runId`: ID?
    public var `source`: String
    public var `category`: ActionCategory
    public var `title`: String
    public var `description`: String
    public var `target`: String
    public var `inputs`: JSONObject
    public var `policyMode`: String
    public var `review`: String
    public var `ruleId`: ID?
    public var `scope`: ReviewScope
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, gate: Gate, entryId: ID, conversationId: ID, botId: ID, runId: ID? = nil, source: String, category: ActionCategory, title: String, description: String, target: String, inputs: JSONObject, policyMode: String, review: String, ruleId: ID? = nil, scope: ReviewScope) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`gate` = gate
        self.`entryId` = entryId
        self.`conversationId` = conversationId
        self.`botId` = botId
        self.`runId` = runId
        self.`source` = source
        self.`category` = category
        self.`title` = title
        self.`description` = description
        self.`target` = target
        self.`inputs` = inputs
        self.`policyMode` = policyMode
        self.`review` = review
        self.`ruleId` = ruleId
        self.`scope` = scope
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `gate`, `entryId`, `conversationId`, `botId`, `runId`, `source`, `category`, `title`, `description`, `target`, `inputs`, `policyMode`, `review`, `ruleId`, `scope` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`gate` = try c.decode(Gate.self, forKey: .`gate`)
        self.`entryId` = try c.decode(ID.self, forKey: .`entryId`)
        self.`conversationId` = try c.decode(ID.self, forKey: .`conversationId`)
        self.`botId` = try c.decode(ID.self, forKey: .`botId`)
        self.`runId` = try c.decode(ID?.self, forKey: .`runId`)
        self.`source` = try c.decode(String.self, forKey: .`source`)
        guard ["lemon_exec", "product"].contains(`source`) else { throw DecodingError.dataCorruptedError(forKey: .`source`, in: c, debugDescription: "Invalid Approval.source") }
        self.`category` = try c.decode(ActionCategory.self, forKey: .`category`)
        self.`title` = try c.decode(String.self, forKey: .`title`)
        self.`description` = try c.decode(String.self, forKey: .`description`)
        self.`target` = try c.decode(String.self, forKey: .`target`)
        self.`inputs` = try c.decode(JSONObject.self, forKey: .`inputs`)
        self.`policyMode` = try c.decode(String.self, forKey: .`policyMode`)
        guard ["ask_first", "auto_review", "allow"].contains(`policyMode`) else { throw DecodingError.dataCorruptedError(forKey: .`policyMode`, in: c, debugDescription: "Invalid Approval.policyMode") }
        self.`review` = try c.decode(String.self, forKey: .`review`)
        guard ["not_run", "allow", "ask", "deny"].contains(`review`) else { throw DecodingError.dataCorruptedError(forKey: .`review`, in: c, debugDescription: "Invalid Approval.review") }
        self.`ruleId` = try c.decode(ID?.self, forKey: .`ruleId`)
        self.`scope` = try c.decode(ReviewScope.self, forKey: .`scope`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`gate`, forKey: .`gate`)
        try c.encode(`entryId`, forKey: .`entryId`)
        try c.encode(`conversationId`, forKey: .`conversationId`)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`runId`, forKey: .`runId`)
        try c.encode(`source`, forKey: .`source`)
        try c.encode(`category`, forKey: .`category`)
        try c.encode(`title`, forKey: .`title`)
        try c.encode(`description`, forKey: .`description`)
        try c.encode(`target`, forKey: .`target`)
        try c.encode(`inputs`, forKey: .`inputs`)
        try c.encode(`policyMode`, forKey: .`policyMode`)
        try c.encode(`review`, forKey: .`review`)
        try c.encode(`ruleId`, forKey: .`ruleId`)
        try c.encode(`scope`, forKey: .`scope`)
    }
}

public struct ApprovalResolve: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `decision`: String
    public init(clientNonce: String, revision: Int, decision: String) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`decision` = decision
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `decision` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`decision` = try c.decode(String.self, forKey: .`decision`)
        guard ["approve_once", "deny"].contains(`decision`) else { throw DecodingError.dataCorruptedError(forKey: .`decision`, in: c, debugDescription: "Invalid ApprovalResolve.decision") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`decision`, forKey: .`decision`)
    }
}

public struct Field: Codable, Hashable, Identifiable {
    public var `id`: String
    public var `label`: String
    public var `kind`: String
    public var `required`: Bool
    public var `options`: [FieldOptions]?
    public var `min`: Double?
    public var `max`: Double?
    public init(id: String, label: String, kind: String, required: Bool, options: [FieldOptions]? = nil, min: Double? = nil, max: Double? = nil) {
        self.`id` = id
        self.`label` = label
        self.`kind` = kind
        self.`required` = required
        self.`options` = options
        self.`min` = min
        self.`max` = max
    }
    enum CodingKeys: String, CodingKey { case `id`, `label`, `kind`, `required`, `options`, `min`, `max` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(String.self, forKey: .`id`)
        self.`label` = try c.decode(String.self, forKey: .`label`)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["text", "multiline", "number", "boolean", "single_select", "multi_select"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid Field.kind") }
        self.`required` = try c.decode(Bool.self, forKey: .`required`)
        self.`options` = try c.decodeOptional([FieldOptions].self, forKey: .`options`)
        self.`min` = try c.decodeOptional(Double.self, forKey: .`min`)
        self.`max` = try c.decodeOptional(Double.self, forKey: .`max`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`label`, forKey: .`label`)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`required`, forKey: .`required`)
        try c.encodeIfPresent(`options`, forKey: .`options`)
        try c.encodeIfPresent(`min`, forKey: .`min`)
        try c.encodeIfPresent(`max`, forKey: .`max`)
    }
}

public struct Question: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `gate`: Gate
    public var `entryId`: ID
    public var `conversationId`: ID
    public var `botId`: ID
    public var `title`: String
    public var `fields`: [Field]
    public var `answers`: [String: JSONValue]?
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, gate: Gate, entryId: ID, conversationId: ID, botId: ID, title: String, fields: [Field], answers: [String: JSONValue]? = nil) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`gate` = gate
        self.`entryId` = entryId
        self.`conversationId` = conversationId
        self.`botId` = botId
        self.`title` = title
        self.`fields` = fields
        self.`answers` = answers
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `gate`, `entryId`, `conversationId`, `botId`, `title`, `fields`, `answers` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`gate` = try c.decode(Gate.self, forKey: .`gate`)
        self.`entryId` = try c.decode(ID.self, forKey: .`entryId`)
        self.`conversationId` = try c.decode(ID.self, forKey: .`conversationId`)
        self.`botId` = try c.decode(ID.self, forKey: .`botId`)
        self.`title` = try c.decode(String.self, forKey: .`title`)
        self.`fields` = try c.decode([Field].self, forKey: .`fields`)
        self.`answers` = try c.decode([String: JSONValue]?.self, forKey: .`answers`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`gate`, forKey: .`gate`)
        try c.encode(`entryId`, forKey: .`entryId`)
        try c.encode(`conversationId`, forKey: .`conversationId`)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`title`, forKey: .`title`)
        try c.encode(`fields`, forKey: .`fields`)
        try c.encode(`answers`, forKey: .`answers`)
    }
}

public struct QuestionResolve: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `decision`: String
    public var `answers`: [String: JSONValue]?
    public init(clientNonce: String, revision: Int, decision: String, answers: [String: JSONValue]? = nil) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`decision` = decision
        self.`answers` = answers
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `decision`, `answers` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`decision` = try c.decode(String.self, forKey: .`decision`)
        guard ["answer", "decline"].contains(`decision`) else { throw DecodingError.dataCorruptedError(forKey: .`decision`, in: c, debugDescription: "Invalid QuestionResolve.decision") }
        self.`answers` = try c.decodeOptional([String: JSONValue].self, forKey: .`answers`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`decision`, forKey: .`decision`)
        try c.encodeIfPresent(`answers`, forKey: .`answers`)
    }
}

public struct HumanStep: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `gate`: Gate
    public var `entryId`: ID
    public var `botId`: ID
    public var `conversationId`: ID
    public var `machineId`: ID
    public var `title`: String
    public var `instructions`: String
    public var `reason`: String
    public var `externalUrl`: String?
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, gate: Gate, entryId: ID, botId: ID, conversationId: ID, machineId: ID, title: String, instructions: String, reason: String, externalUrl: String? = nil) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`gate` = gate
        self.`entryId` = entryId
        self.`botId` = botId
        self.`conversationId` = conversationId
        self.`machineId` = machineId
        self.`title` = title
        self.`instructions` = instructions
        self.`reason` = reason
        self.`externalUrl` = externalUrl
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `gate`, `entryId`, `botId`, `conversationId`, `machineId`, `title`, `instructions`, `reason`, `externalUrl` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`gate` = try c.decode(Gate.self, forKey: .`gate`)
        self.`entryId` = try c.decode(ID.self, forKey: .`entryId`)
        self.`botId` = try c.decode(ID.self, forKey: .`botId`)
        self.`conversationId` = try c.decode(ID.self, forKey: .`conversationId`)
        self.`machineId` = try c.decode(ID.self, forKey: .`machineId`)
        self.`title` = try c.decode(String.self, forKey: .`title`)
        self.`instructions` = try c.decode(String.self, forKey: .`instructions`)
        self.`reason` = try c.decode(String.self, forKey: .`reason`)
        guard ["login", "mfa", "captcha", "payment", "identity", "other"].contains(`reason`) else { throw DecodingError.dataCorruptedError(forKey: .`reason`, in: c, debugDescription: "Invalid HumanStep.reason") }
        self.`externalUrl` = try c.decode(String?.self, forKey: .`externalUrl`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`gate`, forKey: .`gate`)
        try c.encode(`entryId`, forKey: .`entryId`)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`conversationId`, forKey: .`conversationId`)
        try c.encode(`machineId`, forKey: .`machineId`)
        try c.encode(`title`, forKey: .`title`)
        try c.encode(`instructions`, forKey: .`instructions`)
        try c.encode(`reason`, forKey: .`reason`)
        try c.encode(`externalUrl`, forKey: .`externalUrl`)
    }
}

public struct HumanStepResolve: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `decision`: String
    public init(clientNonce: String, revision: Int, decision: String) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`decision` = decision
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `decision` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`decision` = try c.decode(String.self, forKey: .`decision`)
        guard ["done", "skip"].contains(`decision`) else { throw DecodingError.dataCorruptedError(forKey: .`decision`, in: c, debugDescription: "Invalid HumanStepResolve.decision") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`decision`, forKey: .`decision`)
    }
}

public struct SecretRequest: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `gate`: Gate
    public var `entryId`: ID
    public var `machineId`: ID
    public var `botId`: ID
    public var `name`: String
    public var `description`: String
    public var `scope`: String
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, gate: Gate, entryId: ID, machineId: ID, botId: ID, name: String, description: String, scope: String) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`gate` = gate
        self.`entryId` = entryId
        self.`machineId` = machineId
        self.`botId` = botId
        self.`name` = name
        self.`description` = description
        self.`scope` = scope
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `gate`, `entryId`, `machineId`, `botId`, `name`, `description`, `scope` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`gate` = try c.decode(Gate.self, forKey: .`gate`)
        self.`entryId` = try c.decode(ID.self, forKey: .`entryId`)
        self.`machineId` = try c.decode(ID.self, forKey: .`machineId`)
        self.`botId` = try c.decode(ID.self, forKey: .`botId`)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`description` = try c.decode(String.self, forKey: .`description`)
        self.`scope` = try c.decode(String.self, forKey: .`scope`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`gate`, forKey: .`gate`)
        try c.encode(`entryId`, forKey: .`entryId`)
        try c.encode(`machineId`, forKey: .`machineId`)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`description`, forKey: .`description`)
        try c.encode(`scope`, forKey: .`scope`)
    }
}

public struct SecretRequestResolve: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `decision`: String
    public var `value`: String?
    public init(clientNonce: String, revision: Int, decision: String, value: String? = nil) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`decision` = decision
        self.`value` = value
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `decision`, `value` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`decision` = try c.decode(String.self, forKey: .`decision`)
        guard ["save", "decline"].contains(`decision`) else { throw DecodingError.dataCorruptedError(forKey: .`decision`, in: c, debugDescription: "Invalid SecretRequestResolve.decision") }
        self.`value` = try c.decodeOptional(String.self, forKey: .`value`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`decision`, forKey: .`decision`)
        try c.encodeIfPresent(`value`, forKey: .`value`)
    }
}

public struct Draft: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `entryId`: ID
    public var `conversationId`: ID
    public var `botId`: ID
    public var `ownerUserId`: ID
    public var `content`: DraftContent
    public var `state`: String
    public var `sendRunId`: ID?
    public var `providerMessageId`: String?
    public var `error`: String?
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, entryId: ID, conversationId: ID, botId: ID, ownerUserId: ID, content: DraftContent, state: String, sendRunId: ID? = nil, providerMessageId: String? = nil, error: String? = nil) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`entryId` = entryId
        self.`conversationId` = conversationId
        self.`botId` = botId
        self.`ownerUserId` = ownerUserId
        self.`content` = content
        self.`state` = state
        self.`sendRunId` = sendRunId
        self.`providerMessageId` = providerMessageId
        self.`error` = error
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `entryId`, `conversationId`, `botId`, `ownerUserId`, `content`, `state`, `sendRunId`, `providerMessageId`, `error` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`entryId` = try c.decode(ID.self, forKey: .`entryId`)
        self.`conversationId` = try c.decode(ID.self, forKey: .`conversationId`)
        self.`botId` = try c.decode(ID.self, forKey: .`botId`)
        self.`ownerUserId` = try c.decode(ID.self, forKey: .`ownerUserId`)
        self.`content` = try c.decode(DraftContent.self, forKey: .`content`)
        self.`state` = try c.decode(String.self, forKey: .`state`)
        guard ["editable", "sending", "sent", "discarded", "failed", "outcome_unknown"].contains(`state`) else { throw DecodingError.dataCorruptedError(forKey: .`state`, in: c, debugDescription: "Invalid Draft.state") }
        self.`sendRunId` = try c.decode(ID?.self, forKey: .`sendRunId`)
        self.`providerMessageId` = try c.decode(String?.self, forKey: .`providerMessageId`)
        self.`error` = try c.decode(String?.self, forKey: .`error`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`entryId`, forKey: .`entryId`)
        try c.encode(`conversationId`, forKey: .`conversationId`)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`ownerUserId`, forKey: .`ownerUserId`)
        try c.encode(`content`, forKey: .`content`)
        try c.encode(`state`, forKey: .`state`)
        try c.encode(`sendRunId`, forKey: .`sendRunId`)
        try c.encode(`providerMessageId`, forKey: .`providerMessageId`)
        try c.encode(`error`, forKey: .`error`)
    }
}

public struct DraftUpdate: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `content`: DraftContent
    public init(clientNonce: String, revision: Int, content: DraftContent) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`content` = content
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `content` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`content` = try c.decode(DraftContent.self, forKey: .`content`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`content`, forKey: .`content`)
    }
}

public struct DraftSend: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `content`: DraftContent
    public init(clientNonce: String, revision: Int, content: DraftContent) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`content` = content
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `content` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`content` = try c.decode(DraftContent.self, forKey: .`content`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`content`, forKey: .`content`)
    }
}

public struct Feedback: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `entryId`: ID
    public var `userId`: ID
    public var `sentiment`: String
    public var `reasons`: [String]
    public var `comment`: String
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, entryId: ID, userId: ID, sentiment: String, reasons: [String], comment: String) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`entryId` = entryId
        self.`userId` = userId
        self.`sentiment` = sentiment
        self.`reasons` = reasons
        self.`comment` = comment
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `entryId`, `userId`, `sentiment`, `reasons`, `comment` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`entryId` = try c.decode(ID.self, forKey: .`entryId`)
        self.`userId` = try c.decode(ID.self, forKey: .`userId`)
        self.`sentiment` = try c.decode(String.self, forKey: .`sentiment`)
        guard ["good", "bad"].contains(`sentiment`) else { throw DecodingError.dataCorruptedError(forKey: .`sentiment`, in: c, debugDescription: "Invalid Feedback.sentiment") }
        self.`reasons` = try c.decode([String].self, forKey: .`reasons`)
        guard reasons.allSatisfy({ FeedbackReasonValue(rawValue: $0) != nil }) else { throw DecodingError.dataCorruptedError(forKey: .`reasons`, in: c, debugDescription: "Invalid Feedback.reasons") }
        self.`comment` = try c.decode(String.self, forKey: .`comment`)
    }
    public func encode(to encoder: Encoder) throws {
        guard reasons.allSatisfy({ FeedbackReasonValue(rawValue: $0) != nil }) else { throw EncodingError.invalidValue(reasons, .init(codingPath: encoder.codingPath + [CodingKeys.reasons], debugDescription: "Invalid Feedback.reasons")) }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`entryId`, forKey: .`entryId`)
        try c.encode(`userId`, forKey: .`userId`)
        try c.encode(`sentiment`, forKey: .`sentiment`)
        try c.encode(`reasons`, forKey: .`reasons`)
        try c.encode(`comment`, forKey: .`comment`)
    }
}

public struct FeedbackCreate: Codable, Hashable {
    public var `clientNonce`: String
    public var `sentiment`: String
    public var `reasons`: [String]?
    public var `comment`: String?
    public init(clientNonce: String, sentiment: String, reasons: [String]? = nil, comment: String? = nil) {
        self.`clientNonce` = clientNonce
        self.`sentiment` = sentiment
        self.`reasons` = reasons
        self.`comment` = comment
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `sentiment`, `reasons`, `comment` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`sentiment` = try c.decode(String.self, forKey: .`sentiment`)
        guard ["good", "bad"].contains(`sentiment`) else { throw DecodingError.dataCorruptedError(forKey: .`sentiment`, in: c, debugDescription: "Invalid FeedbackCreate.sentiment") }
        self.`reasons` = try c.decodeOptional([String].self, forKey: .`reasons`)
        if let reasons, !reasons.allSatisfy({ FeedbackReasonValue(rawValue: $0) != nil }) { throw DecodingError.dataCorruptedError(forKey: .`reasons`, in: c, debugDescription: "Invalid FeedbackCreate.reasons") }
        self.`comment` = try c.decodeOptional(String.self, forKey: .`comment`)
    }
    public func encode(to encoder: Encoder) throws {
        if let reasons, !reasons.allSatisfy({ FeedbackReasonValue(rawValue: $0) != nil }) { throw EncodingError.invalidValue(reasons, .init(codingPath: encoder.codingPath + [CodingKeys.reasons], debugDescription: "Invalid FeedbackCreate.reasons")) }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`sentiment`, forKey: .`sentiment`)
        try c.encodeIfPresent(`reasons`, forKey: .`reasons`)
        try c.encodeIfPresent(`comment`, forKey: .`comment`)
    }
}

public struct CalendarEvent: Codable, Hashable {
    public var `subject`: String
    public var `startAtMs`: TimestampMs
    public var `endAtMs`: TimestampMs
    public var `timezone`: String
    public var `allDay`: Bool
    public var `guests`: [String]
    public var `location`: String
    public var `sourceUrl`: String?
    public var `status`: String
    public init(subject: String, startAtMs: TimestampMs, endAtMs: TimestampMs, timezone: String, allDay: Bool, guests: [String], location: String, sourceUrl: String? = nil, status: String) {
        self.`subject` = subject
        self.`startAtMs` = startAtMs
        self.`endAtMs` = endAtMs
        self.`timezone` = timezone
        self.`allDay` = allDay
        self.`guests` = guests
        self.`location` = location
        self.`sourceUrl` = sourceUrl
        self.`status` = status
    }
    enum CodingKeys: String, CodingKey { case `subject`, `startAtMs`, `endAtMs`, `timezone`, `allDay`, `guests`, `location`, `sourceUrl`, `status` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`subject` = try c.decode(String.self, forKey: .`subject`)
        self.`startAtMs` = try c.decode(TimestampMs.self, forKey: .`startAtMs`)
        self.`endAtMs` = try c.decode(TimestampMs.self, forKey: .`endAtMs`)
        self.`timezone` = try c.decode(String.self, forKey: .`timezone`)
        self.`allDay` = try c.decode(Bool.self, forKey: .`allDay`)
        self.`guests` = try c.decode([String].self, forKey: .`guests`)
        self.`location` = try c.decode(String.self, forKey: .`location`)
        self.`sourceUrl` = try c.decode(String?.self, forKey: .`sourceUrl`)
        self.`status` = try c.decode(String.self, forKey: .`status`)
        guard ["proposed", "confirmed", "cancelled"].contains(`status`) else { throw DecodingError.dataCorruptedError(forKey: .`status`, in: c, debugDescription: "Invalid CalendarEvent.status") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`subject`, forKey: .`subject`)
        try c.encode(`startAtMs`, forKey: .`startAtMs`)
        try c.encode(`endAtMs`, forKey: .`endAtMs`)
        try c.encode(`timezone`, forKey: .`timezone`)
        try c.encode(`allDay`, forKey: .`allDay`)
        try c.encode(`guests`, forKey: .`guests`)
        try c.encode(`location`, forKey: .`location`)
        try c.encode(`sourceUrl`, forKey: .`sourceUrl`)
        try c.encode(`status`, forKey: .`status`)
    }
}

public struct ReactionRequest: Codable, Hashable {
    public var `clientNonce`: String
    public var `emoji`: String
    public init(clientNonce: String, emoji: String) {
        self.`clientNonce` = clientNonce
        self.`emoji` = emoji
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `emoji` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`emoji` = try c.decode(String.self, forKey: .`emoji`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`emoji`, forKey: .`emoji`)
    }
}

public struct Attachment: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `ownerUserId`: ID
    public var `conversationId`: ID?
    public var `botId`: ID?
    public var `filename`: String
    public var `mime`: String
    public var `size`: Int
    public var `sha256`: String
    public var `width`: Int?
    public var `height`: Int?
    public var `durationMs`: Int?
    public var `source`: String
    public var `state`: String
    public var `preview`: String
    public var `provenance`: DeliverableProvenance
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, ownerUserId: ID, conversationId: ID? = nil, botId: ID? = nil, filename: String, mime: String, size: Int, sha256: String, width: Int? = nil, height: Int? = nil, durationMs: Int? = nil, source: String, state: String, preview: String, provenance: DeliverableProvenance) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`ownerUserId` = ownerUserId
        self.`conversationId` = conversationId
        self.`botId` = botId
        self.`filename` = filename
        self.`mime` = mime
        self.`size` = size
        self.`sha256` = sha256
        self.`width` = width
        self.`height` = height
        self.`durationMs` = durationMs
        self.`source` = source
        self.`state` = state
        self.`preview` = preview
        self.`provenance` = provenance
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `ownerUserId`, `conversationId`, `botId`, `filename`, `mime`, `size`, `sha256`, `width`, `height`, `durationMs`, `source`, `state`, `preview`, `provenance` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`ownerUserId` = try c.decode(ID.self, forKey: .`ownerUserId`)
        self.`conversationId` = try c.decode(ID?.self, forKey: .`conversationId`)
        self.`botId` = try c.decode(ID?.self, forKey: .`botId`)
        self.`filename` = try c.decode(String.self, forKey: .`filename`)
        self.`mime` = try c.decode(String.self, forKey: .`mime`)
        self.`size` = try c.decode(Int.self, forKey: .`size`)
        self.`sha256` = try c.decode(String.self, forKey: .`sha256`)
        self.`width` = try c.decode(Int?.self, forKey: .`width`)
        self.`height` = try c.decode(Int?.self, forKey: .`height`)
        self.`durationMs` = try c.decode(Int?.self, forKey: .`durationMs`)
        self.`source` = try c.decode(String.self, forKey: .`source`)
        guard ["upload", "node", "tts", "generated"].contains(`source`) else { throw DecodingError.dataCorruptedError(forKey: .`source`, in: c, debugDescription: "Invalid Attachment.source") }
        self.`state` = try c.decode(String.self, forKey: .`state`)
        guard ["ready", "deleted"].contains(`state`) else { throw DecodingError.dataCorruptedError(forKey: .`state`, in: c, debugDescription: "Invalid Attachment.state") }
        self.`preview` = try c.decode(String.self, forKey: .`preview`)
        guard ["image", "video", "audio", "pdf", "text", "markdown", "html", "json", "table", "docx", "download"].contains(`preview`) else { throw DecodingError.dataCorruptedError(forKey: .`preview`, in: c, debugDescription: "Invalid Attachment.preview") }
        self.`provenance` = try c.decode(DeliverableProvenance.self, forKey: .`provenance`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`ownerUserId`, forKey: .`ownerUserId`)
        try c.encode(`conversationId`, forKey: .`conversationId`)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`filename`, forKey: .`filename`)
        try c.encode(`mime`, forKey: .`mime`)
        try c.encode(`size`, forKey: .`size`)
        try c.encode(`sha256`, forKey: .`sha256`)
        try c.encode(`width`, forKey: .`width`)
        try c.encode(`height`, forKey: .`height`)
        try c.encode(`durationMs`, forKey: .`durationMs`)
        try c.encode(`source`, forKey: .`source`)
        try c.encode(`state`, forKey: .`state`)
        try c.encode(`preview`, forKey: .`preview`)
        try c.encode(`provenance`, forKey: .`provenance`)
    }
}

public struct AttachmentUpload: Codable, Hashable {
    public var `clientNonce`: String
    public var `conversationId`: ID?
    public var `botId`: ID?
    public var `purpose`: String
    public init(clientNonce: String, conversationId: ID? = nil, botId: ID? = nil, purpose: String) {
        self.`clientNonce` = clientNonce
        self.`conversationId` = conversationId
        self.`botId` = botId
        self.`purpose` = purpose
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `conversationId`, `botId`, `purpose` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`conversationId` = try c.decodeOptional(ID.self, forKey: .`conversationId`)
        self.`botId` = try c.decodeOptional(ID.self, forKey: .`botId`)
        self.`purpose` = try c.decode(String.self, forKey: .`purpose`)
        guard ["message", "avatar", "reference", "audio"].contains(`purpose`) else { throw DecodingError.dataCorruptedError(forKey: .`purpose`, in: c, debugDescription: "Invalid AttachmentUpload.purpose") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encodeIfPresent(`conversationId`, forKey: .`conversationId`)
        try c.encodeIfPresent(`botId`, forKey: .`botId`)
        try c.encode(`purpose`, forKey: .`purpose`)
    }
}

public struct Download: Codable, Hashable {
    public var `url`: String
    public var `expiresAtMs`: TimestampMs
    public var `filename`: String
    public var `mime`: String
    public var `size`: Int
    public init(url: String, expiresAtMs: TimestampMs, filename: String, mime: String, size: Int) {
        self.`url` = url
        self.`expiresAtMs` = expiresAtMs
        self.`filename` = filename
        self.`mime` = mime
        self.`size` = size
    }
    enum CodingKeys: String, CodingKey { case `url`, `expiresAtMs`, `filename`, `mime`, `size` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`url` = try c.decode(String.self, forKey: .`url`)
        self.`expiresAtMs` = try c.decode(TimestampMs.self, forKey: .`expiresAtMs`)
        self.`filename` = try c.decode(String.self, forKey: .`filename`)
        self.`mime` = try c.decode(String.self, forKey: .`mime`)
        self.`size` = try c.decode(Int.self, forKey: .`size`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`url`, forKey: .`url`)
        try c.encode(`expiresAtMs`, forKey: .`expiresAtMs`)
        try c.encode(`filename`, forKey: .`filename`)
        try c.encode(`mime`, forKey: .`mime`)
        try c.encode(`size`, forKey: .`size`)
    }
}

public struct FileImport: Codable, Hashable {
    public var `clientNonce`: String
    public var `path`: String
    public var `conversationId`: ID?
    public var `botId`: ID?
    public init(clientNonce: String, path: String, conversationId: ID? = nil, botId: ID? = nil) {
        self.`clientNonce` = clientNonce
        self.`path` = path
        self.`conversationId` = conversationId
        self.`botId` = botId
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `path`, `conversationId`, `botId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`path` = try c.decode(String.self, forKey: .`path`)
        self.`conversationId` = try c.decodeOptional(ID.self, forKey: .`conversationId`)
        self.`botId` = try c.decodeOptional(ID.self, forKey: .`botId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`path`, forKey: .`path`)
        try c.encodeIfPresent(`conversationId`, forKey: .`conversationId`)
        try c.encodeIfPresent(`botId`, forKey: .`botId`)
    }
}

public struct Skill: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `ownerUserId`: ID
    public var `botId`: ID?
    public var `name`: String
    public var `description`: String
    public var `markdown`: String
    public var `enabled`: Bool
    public var `machineIds`: [ID]
    public var `provenance`: SkillProvenance
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, ownerUserId: ID, botId: ID? = nil, name: String, description: String, markdown: String, enabled: Bool, machineIds: [ID], provenance: SkillProvenance) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`ownerUserId` = ownerUserId
        self.`botId` = botId
        self.`name` = name
        self.`description` = description
        self.`markdown` = markdown
        self.`enabled` = enabled
        self.`machineIds` = machineIds
        self.`provenance` = provenance
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `ownerUserId`, `botId`, `name`, `description`, `markdown`, `enabled`, `machineIds`, `provenance` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`ownerUserId` = try c.decode(ID.self, forKey: .`ownerUserId`)
        self.`botId` = try c.decode(ID?.self, forKey: .`botId`)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`description` = try c.decode(String.self, forKey: .`description`)
        self.`markdown` = try c.decode(String.self, forKey: .`markdown`)
        self.`enabled` = try c.decode(Bool.self, forKey: .`enabled`)
        self.`machineIds` = try c.decode([ID].self, forKey: .`machineIds`)
        self.`provenance` = try c.decode(SkillProvenance.self, forKey: .`provenance`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`ownerUserId`, forKey: .`ownerUserId`)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`description`, forKey: .`description`)
        try c.encode(`markdown`, forKey: .`markdown`)
        try c.encode(`enabled`, forKey: .`enabled`)
        try c.encode(`machineIds`, forKey: .`machineIds`)
        try c.encode(`provenance`, forKey: .`provenance`)
    }
}

public struct SkillCreate: Codable, Hashable {
    public var `clientNonce`: String
    public var `name`: String
    public var `description`: String
    public var `markdown`: String
    public var `botId`: ID?
    public var `machineIds`: [ID]
    public init(clientNonce: String, name: String, description: String, markdown: String, botId: ID? = nil, machineIds: [ID]) {
        self.`clientNonce` = clientNonce
        self.`name` = name
        self.`description` = description
        self.`markdown` = markdown
        self.`botId` = botId
        self.`machineIds` = machineIds
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `name`, `description`, `markdown`, `botId`, `machineIds` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`description` = try c.decode(String.self, forKey: .`description`)
        self.`markdown` = try c.decode(String.self, forKey: .`markdown`)
        self.`botId` = try c.decodeOptional(ID.self, forKey: .`botId`)
        self.`machineIds` = try c.decode([ID].self, forKey: .`machineIds`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`description`, forKey: .`description`)
        try c.encode(`markdown`, forKey: .`markdown`)
        try c.encodeIfPresent(`botId`, forKey: .`botId`)
        try c.encode(`machineIds`, forKey: .`machineIds`)
    }
}

public struct SkillUpdate: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `name`: String?
    public var `description`: String?
    public var `markdown`: String?
    public var `enabled`: Bool?
    public var `machineIds`: [ID]?
    public init(clientNonce: String, revision: Int, name: String? = nil, description: String? = nil, markdown: String? = nil, enabled: Bool? = nil, machineIds: [ID]? = nil) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`name` = name
        self.`description` = description
        self.`markdown` = markdown
        self.`enabled` = enabled
        self.`machineIds` = machineIds
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `name`, `description`, `markdown`, `enabled`, `machineIds` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`name` = try c.decodeOptional(String.self, forKey: .`name`)
        self.`description` = try c.decodeOptional(String.self, forKey: .`description`)
        self.`markdown` = try c.decodeOptional(String.self, forKey: .`markdown`)
        self.`enabled` = try c.decodeOptional(Bool.self, forKey: .`enabled`)
        self.`machineIds` = try c.decodeOptional([ID].self, forKey: .`machineIds`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encodeIfPresent(`name`, forKey: .`name`)
        try c.encodeIfPresent(`description`, forKey: .`description`)
        try c.encodeIfPresent(`markdown`, forKey: .`markdown`)
        try c.encodeIfPresent(`enabled`, forKey: .`enabled`)
        try c.encodeIfPresent(`machineIds`, forKey: .`machineIds`)
    }
}

public struct RoutineSpec: Codable, Hashable {
    public var `name`: String
    public var `instruction`: String
    public var `trigger`: RoutineTrigger
    public var `enabled`: Bool
    public init(name: String, instruction: String, trigger: RoutineTrigger, enabled: Bool) {
        self.`name` = name
        self.`instruction` = instruction
        self.`trigger` = trigger
        self.`enabled` = enabled
    }
    enum CodingKeys: String, CodingKey { case `name`, `instruction`, `trigger`, `enabled` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`instruction` = try c.decode(String.self, forKey: .`instruction`)
        self.`trigger` = try c.decode(RoutineTrigger.self, forKey: .`trigger`)
        self.`enabled` = try c.decode(Bool.self, forKey: .`enabled`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`instruction`, forKey: .`instruction`)
        try c.encode(`trigger`, forKey: .`trigger`)
        try c.encode(`enabled`, forKey: .`enabled`)
    }
}

public struct Routine: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `name`: String
    public var `instruction`: String
    public var `trigger`: RoutineTrigger
    public var `enabled`: Bool
    public var `botId`: ID
    public var `ownerUserId`: ID
    public var `nextRunAtMs`: TimestampMs?
    public var `scheduleDescription`: String
    public var `lastRunId`: ID?
    public var `webhookUrl`: String?
    public var `cronJobId`: String?
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, name: String, instruction: String, trigger: RoutineTrigger, enabled: Bool, botId: ID, ownerUserId: ID, nextRunAtMs: TimestampMs? = nil, scheduleDescription: String, lastRunId: ID? = nil, webhookUrl: String? = nil, cronJobId: String? = nil) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`name` = name
        self.`instruction` = instruction
        self.`trigger` = trigger
        self.`enabled` = enabled
        self.`botId` = botId
        self.`ownerUserId` = ownerUserId
        self.`nextRunAtMs` = nextRunAtMs
        self.`scheduleDescription` = scheduleDescription
        self.`lastRunId` = lastRunId
        self.`webhookUrl` = webhookUrl
        self.`cronJobId` = cronJobId
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `name`, `instruction`, `trigger`, `enabled`, `botId`, `ownerUserId`, `nextRunAtMs`, `scheduleDescription`, `lastRunId`, `webhookUrl`, `cronJobId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`instruction` = try c.decode(String.self, forKey: .`instruction`)
        self.`trigger` = try c.decode(RoutineTrigger.self, forKey: .`trigger`)
        self.`enabled` = try c.decode(Bool.self, forKey: .`enabled`)
        self.`botId` = try c.decode(ID.self, forKey: .`botId`)
        self.`ownerUserId` = try c.decode(ID.self, forKey: .`ownerUserId`)
        self.`nextRunAtMs` = try c.decode(TimestampMs?.self, forKey: .`nextRunAtMs`)
        self.`scheduleDescription` = try c.decode(String.self, forKey: .`scheduleDescription`)
        self.`lastRunId` = try c.decode(ID?.self, forKey: .`lastRunId`)
        self.`webhookUrl` = try c.decode(String?.self, forKey: .`webhookUrl`)
        self.`cronJobId` = try c.decode(String?.self, forKey: .`cronJobId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`instruction`, forKey: .`instruction`)
        try c.encode(`trigger`, forKey: .`trigger`)
        try c.encode(`enabled`, forKey: .`enabled`)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`ownerUserId`, forKey: .`ownerUserId`)
        try c.encode(`nextRunAtMs`, forKey: .`nextRunAtMs`)
        try c.encode(`scheduleDescription`, forKey: .`scheduleDescription`)
        try c.encode(`lastRunId`, forKey: .`lastRunId`)
        try c.encode(`webhookUrl`, forKey: .`webhookUrl`)
        try c.encode(`cronJobId`, forKey: .`cronJobId`)
    }
}

public struct RoutineCreate: Codable, Hashable {
    public var `clientNonce`: String
    public var `name`: String
    public var `instruction`: String
    public var `trigger`: RoutineTrigger
    public var `enabled`: Bool
    public var `botId`: ID
    public init(clientNonce: String, name: String, instruction: String, trigger: RoutineTrigger, enabled: Bool, botId: ID) {
        self.`clientNonce` = clientNonce
        self.`name` = name
        self.`instruction` = instruction
        self.`trigger` = trigger
        self.`enabled` = enabled
        self.`botId` = botId
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `name`, `instruction`, `trigger`, `enabled`, `botId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`instruction` = try c.decode(String.self, forKey: .`instruction`)
        self.`trigger` = try c.decode(RoutineTrigger.self, forKey: .`trigger`)
        self.`enabled` = try c.decode(Bool.self, forKey: .`enabled`)
        self.`botId` = try c.decode(ID.self, forKey: .`botId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`instruction`, forKey: .`instruction`)
        try c.encode(`trigger`, forKey: .`trigger`)
        try c.encode(`enabled`, forKey: .`enabled`)
        try c.encode(`botId`, forKey: .`botId`)
    }
}

public struct RoutineUpdate: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `name`: String?
    public var `instruction`: String?
    public var `trigger`: RoutineTrigger?
    public var `enabled`: Bool?
    public init(clientNonce: String, revision: Int, name: String? = nil, instruction: String? = nil, trigger: RoutineTrigger? = nil, enabled: Bool? = nil) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`name` = name
        self.`instruction` = instruction
        self.`trigger` = trigger
        self.`enabled` = enabled
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `name`, `instruction`, `trigger`, `enabled` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`name` = try c.decodeOptional(String.self, forKey: .`name`)
        self.`instruction` = try c.decodeOptional(String.self, forKey: .`instruction`)
        self.`trigger` = try c.decodeOptional(RoutineTrigger.self, forKey: .`trigger`)
        self.`enabled` = try c.decodeOptional(Bool.self, forKey: .`enabled`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encodeIfPresent(`name`, forKey: .`name`)
        try c.encodeIfPresent(`instruction`, forKey: .`instruction`)
        try c.encodeIfPresent(`trigger`, forKey: .`trigger`)
        try c.encodeIfPresent(`enabled`, forKey: .`enabled`)
    }
}

public struct RoutineRun: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `routineId`: ID
    public var `runId`: ID?
    public var `conversationId`: ID
    public var `trigger`: String
    public var `status`: String
    public var `startedAtMs`: TimestampMs?
    public var `completedAtMs`: TimestampMs?
    public var `error`: String?
    public var `costUsd`: Double?
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, routineId: ID, runId: ID? = nil, conversationId: ID, trigger: String, status: String, startedAtMs: TimestampMs? = nil, completedAtMs: TimestampMs? = nil, error: String? = nil, costUsd: Double? = nil) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`routineId` = routineId
        self.`runId` = runId
        self.`conversationId` = conversationId
        self.`trigger` = trigger
        self.`status` = status
        self.`startedAtMs` = startedAtMs
        self.`completedAtMs` = completedAtMs
        self.`error` = error
        self.`costUsd` = costUsd
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `routineId`, `runId`, `conversationId`, `trigger`, `status`, `startedAtMs`, `completedAtMs`, `error`, `costUsd` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`routineId` = try c.decode(ID.self, forKey: .`routineId`)
        self.`runId` = try c.decode(ID?.self, forKey: .`runId`)
        self.`conversationId` = try c.decode(ID.self, forKey: .`conversationId`)
        self.`trigger` = try c.decode(String.self, forKey: .`trigger`)
        guard ["schedule", "webhook", "event", "test"].contains(`trigger`) else { throw DecodingError.dataCorruptedError(forKey: .`trigger`, in: c, debugDescription: "Invalid RoutineRun.trigger") }
        self.`status` = try c.decode(String.self, forKey: .`status`)
        self.`startedAtMs` = try c.decode(TimestampMs?.self, forKey: .`startedAtMs`)
        self.`completedAtMs` = try c.decode(TimestampMs?.self, forKey: .`completedAtMs`)
        self.`error` = try c.decode(String?.self, forKey: .`error`)
        self.`costUsd` = try c.decode(Double?.self, forKey: .`costUsd`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`routineId`, forKey: .`routineId`)
        try c.encode(`runId`, forKey: .`runId`)
        try c.encode(`conversationId`, forKey: .`conversationId`)
        try c.encode(`trigger`, forKey: .`trigger`)
        try c.encode(`status`, forKey: .`status`)
        try c.encode(`startedAtMs`, forKey: .`startedAtMs`)
        try c.encode(`completedAtMs`, forKey: .`completedAtMs`)
        try c.encode(`error`, forKey: .`error`)
        try c.encode(`costUsd`, forKey: .`costUsd`)
    }
}

public struct WebhookKey: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `routineId`: ID
    public var `key`: String
    public var `url`: String
    public var `header`: String
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, routineId: ID, key: String, url: String, header: String) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`routineId` = routineId
        self.`key` = key
        self.`url` = url
        self.`header` = header
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `routineId`, `key`, `url`, `header` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`routineId` = try c.decode(ID.self, forKey: .`routineId`)
        self.`key` = try c.decode(String.self, forKey: .`key`)
        self.`url` = try c.decode(String.self, forKey: .`url`)
        self.`header` = try c.decode(String.self, forKey: .`header`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`routineId`, forKey: .`routineId`)
        try c.encode(`key`, forKey: .`key`)
        try c.encode(`url`, forKey: .`url`)
        try c.encode(`header`, forKey: .`header`)
    }
}

public struct HookRequest: Codable, Hashable {
    public var `clientNonce`: String
    public var `payload`: JSONValue?
    public init(clientNonce: String, payload: JSONValue? = nil) {
        self.`clientNonce` = clientNonce
        self.`payload` = payload
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `payload` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`payload` = try c.decodeOptional(JSONValue.self, forKey: .`payload`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encodeIfPresent(`payload`, forKey: .`payload`)
    }
}

public struct HookReceipt: Codable, Hashable {
    public var `routineRun`: RoutineRun
    public var `accepted`: Bool
    public var `status`: String
    public init(routineRun: RoutineRun, accepted: Bool, status: String) {
        self.`routineRun` = routineRun
        self.`accepted` = accepted
        self.`status` = status
    }
    enum CodingKeys: String, CodingKey { case `routineRun`, `accepted`, `status` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`routineRun` = try c.decode(RoutineRun.self, forKey: .`routineRun`)
        self.`accepted` = try c.decode(Bool.self, forKey: .`accepted`)
        self.`status` = try c.decode(String.self, forKey: .`status`)
        guard ["accepted", "outcome_unknown"].contains(`status`) else { throw DecodingError.dataCorruptedError(forKey: .`status`, in: c, debugDescription: "Invalid HookReceipt.status") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`routineRun`, forKey: .`routineRun`)
        try c.encode(`accepted`, forKey: .`accepted`)
        try c.encode(`status`, forKey: .`status`)
    }
}

public struct Memory: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `botId`: ID
    public var `text`: String
    public var `kind`: String
    public var `sourceEntryId`: ID?
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, botId: ID, text: String, kind: String, sourceEntryId: ID? = nil) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`botId` = botId
        self.`text` = text
        self.`kind` = kind
        self.`sourceEntryId` = sourceEntryId
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `botId`, `text`, `kind`, `sourceEntryId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`botId` = try c.decode(ID.self, forKey: .`botId`)
        self.`text` = try c.decode(String.self, forKey: .`text`)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["fact", "preference", "instruction", "summary"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid Memory.kind") }
        self.`sourceEntryId` = try c.decode(ID?.self, forKey: .`sourceEntryId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`text`, forKey: .`text`)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`sourceEntryId`, forKey: .`sourceEntryId`)
    }
}

public struct MemoryCreate: Codable, Hashable {
    public var `clientNonce`: String
    public var `text`: String
    public var `kind`: String
    public var `sourceEntryId`: ID?
    public init(clientNonce: String, text: String, kind: String, sourceEntryId: ID? = nil) {
        self.`clientNonce` = clientNonce
        self.`text` = text
        self.`kind` = kind
        self.`sourceEntryId` = sourceEntryId
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `text`, `kind`, `sourceEntryId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`text` = try c.decode(String.self, forKey: .`text`)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        self.`sourceEntryId` = try c.decodeOptional(ID.self, forKey: .`sourceEntryId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`text`, forKey: .`text`)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encodeIfPresent(`sourceEntryId`, forKey: .`sourceEntryId`)
    }
}

public struct MemoryUpdate: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `text`: String
    public var `kind`: String?
    public init(clientNonce: String, revision: Int, text: String, kind: String? = nil) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`text` = text
        self.`kind` = kind
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `text`, `kind` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`text` = try c.decode(String.self, forKey: .`text`)
        self.`kind` = try c.decodeOptional(String.self, forKey: .`kind`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`text`, forKey: .`text`)
        try c.encodeIfPresent(`kind`, forKey: .`kind`)
    }
}

public struct MemoryImport: Codable, Hashable {
    public var `clientNonce`: String
    public var `previewId`: ID
    public var `confirmationToken`: String
    public var `selectedCandidateIds`: [ID]
    public var `revision`: Int
    public init(clientNonce: String, previewId: ID, confirmationToken: String, selectedCandidateIds: [ID], revision: Int) {
        self.`clientNonce` = clientNonce
        self.`previewId` = previewId
        self.`confirmationToken` = confirmationToken
        self.`selectedCandidateIds` = selectedCandidateIds
        self.`revision` = revision
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `previewId`, `confirmationToken`, `selectedCandidateIds`, `revision` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`previewId` = try c.decode(ID.self, forKey: .`previewId`)
        self.`confirmationToken` = try c.decode(String.self, forKey: .`confirmationToken`)
        self.`selectedCandidateIds` = try c.decode([ID].self, forKey: .`selectedCandidateIds`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`previewId`, forKey: .`previewId`)
        try c.encode(`confirmationToken`, forKey: .`confirmationToken`)
        try c.encode(`selectedCandidateIds`, forKey: .`selectedCandidateIds`)
        try c.encode(`revision`, forKey: .`revision`)
    }
}

public struct MemoryExport: Codable, Hashable {
    public var `botId`: ID
    public var `items`: [Memory]
    public var `exportedAtMs`: TimestampMs
    public init(botId: ID, items: [Memory], exportedAtMs: TimestampMs) {
        self.`botId` = botId
        self.`items` = items
        self.`exportedAtMs` = exportedAtMs
    }
    enum CodingKeys: String, CodingKey { case `botId`, `items`, `exportedAtMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`botId` = try c.decode(ID.self, forKey: .`botId`)
        self.`items` = try c.decode([Memory].self, forKey: .`items`)
        self.`exportedAtMs` = try c.decode(TimestampMs.self, forKey: .`exportedAtMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`items`, forKey: .`items`)
        try c.encode(`exportedAtMs`, forKey: .`exportedAtMs`)
    }
}

public struct Page<T: Codable & Hashable>: Codable, Hashable {
    public var `items`: [T]
    public var `nextCursor`: Cursor?
    public init(items: [T], nextCursor: Cursor? = nil) {
        self.`items` = items
        self.`nextCursor` = nextCursor
    }
    enum CodingKeys: String, CodingKey { case `items`, `nextCursor` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`items` = try c.decode([T].self, forKey: .`items`)
        self.`nextCursor` = try c.decode(Cursor?.self, forKey: .`nextCursor`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`items`, forKey: .`items`)
        try c.encode(`nextCursor`, forKey: .`nextCursor`)
    }
}

public struct SearchQuery: Codable, Hashable {
    public var `cursor`: Cursor?
    public var `limit`: Int?
    public var `q`: String
    public var `kinds`: [String]?
    public var `conversationId`: ID?
    public var `botId`: ID?
    public init(cursor: Cursor? = nil, limit: Int? = nil, q: String, kinds: [String]? = nil, conversationId: ID? = nil, botId: ID? = nil) {
        self.`cursor` = cursor
        self.`limit` = limit
        self.`q` = q
        self.`kinds` = kinds
        self.`conversationId` = conversationId
        self.`botId` = botId
    }
    enum CodingKeys: String, CodingKey { case `cursor`, `limit`, `q`, `kinds`, `conversationId`, `botId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`cursor` = try c.decodeOptional(Cursor.self, forKey: .`cursor`)
        self.`limit` = try c.decodeOptional(Int.self, forKey: .`limit`)
        self.`q` = try c.decode(String.self, forKey: .`q`)
        self.`kinds` = try c.decodeOptional([String].self, forKey: .`kinds`)
        self.`conversationId` = try c.decodeOptional(ID.self, forKey: .`conversationId`)
        self.`botId` = try c.decodeOptional(ID.self, forKey: .`botId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(`cursor`, forKey: .`cursor`)
        try c.encodeIfPresent(`limit`, forKey: .`limit`)
        try c.encode(`q`, forKey: .`q`)
        try c.encodeIfPresent(`kinds`, forKey: .`kinds`)
        try c.encodeIfPresent(`conversationId`, forKey: .`conversationId`)
        try c.encodeIfPresent(`botId`, forKey: .`botId`)
    }
}

public struct BotNotification: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `userId`: ID
    public var `conversationId`: ID?
    public var `botId`: ID?
    public var `entryId`: ID?
    public var `kind`: String
    public var `title`: String
    public var `body`: String
    public var `requestId`: String?
    public var `readAtMs`: TimestampMs?
    public var `dismissedAtMs`: TimestampMs?
    public var `target`: NotificationTarget
    public var `deepLink`: String
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, userId: ID, conversationId: ID? = nil, botId: ID? = nil, entryId: ID? = nil, kind: String, title: String, body: String, requestId: String? = nil, readAtMs: TimestampMs? = nil, dismissedAtMs: TimestampMs? = nil, target: NotificationTarget, deepLink: String) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`userId` = userId
        self.`conversationId` = conversationId
        self.`botId` = botId
        self.`entryId` = entryId
        self.`kind` = kind
        self.`title` = title
        self.`body` = body
        self.`requestId` = requestId
        self.`readAtMs` = readAtMs
        self.`dismissedAtMs` = dismissedAtMs
        self.`target` = target
        self.`deepLink` = deepLink
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `userId`, `conversationId`, `botId`, `entryId`, `kind`, `title`, `body`, `requestId`, `readAtMs`, `dismissedAtMs`, `target`, `deepLink` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`userId` = try c.decode(ID.self, forKey: .`userId`)
        self.`conversationId` = try c.decode(ID?.self, forKey: .`conversationId`)
        self.`botId` = try c.decode(ID?.self, forKey: .`botId`)
        self.`entryId` = try c.decode(ID?.self, forKey: .`entryId`)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["result", "approval", "question", "human_step", "error", "machine"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid Notification.kind") }
        self.`title` = try c.decode(String.self, forKey: .`title`)
        self.`body` = try c.decode(String.self, forKey: .`body`)
        self.`requestId` = try c.decode(String?.self, forKey: .`requestId`)
        self.`readAtMs` = try c.decode(TimestampMs?.self, forKey: .`readAtMs`)
        self.`dismissedAtMs` = try c.decode(TimestampMs?.self, forKey: .`dismissedAtMs`)
        self.`target` = try c.decode(NotificationTarget.self, forKey: .`target`)
        self.`deepLink` = try c.decode(String.self, forKey: .`deepLink`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`userId`, forKey: .`userId`)
        try c.encode(`conversationId`, forKey: .`conversationId`)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`entryId`, forKey: .`entryId`)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`title`, forKey: .`title`)
        try c.encode(`body`, forKey: .`body`)
        try c.encode(`requestId`, forKey: .`requestId`)
        try c.encode(`readAtMs`, forKey: .`readAtMs`)
        try c.encode(`dismissedAtMs`, forKey: .`dismissedAtMs`)
        try c.encode(`target`, forKey: .`target`)
        try c.encode(`deepLink`, forKey: .`deepLink`)
    }
}

public struct NotificationUpdate: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `read`: Bool?
    public var `dismissed`: Bool?
    public init(clientNonce: String, revision: Int, read: Bool? = nil, dismissed: Bool? = nil) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`read` = read
        self.`dismissed` = dismissed
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `read`, `dismissed` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`read` = try c.decodeOptional(Bool.self, forKey: .`read`)
        self.`dismissed` = try c.decodeOptional(Bool.self, forKey: .`dismissed`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encodeIfPresent(`read`, forKey: .`read`)
        try c.encodeIfPresent(`dismissed`, forKey: .`dismissed`)
    }
}

public struct NotificationReadAll: Codable, Hashable {
    public var `clientNonce`: String
    public var `throughAtMs`: TimestampMs
    public init(clientNonce: String, throughAtMs: TimestampMs) {
        self.`clientNonce` = clientNonce
        self.`throughAtMs` = throughAtMs
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `throughAtMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`throughAtMs` = try c.decode(TimestampMs.self, forKey: .`throughAtMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`throughAtMs`, forKey: .`throughAtMs`)
    }
}

public struct UsageQuery: Codable, Hashable {
    public var `fromAtMs`: TimestampMs
    public var `toAtMs`: TimestampMs
    public var `groupBy`: String?
    public var `botId`: ID?
    public var `routineId`: ID?
    public init(fromAtMs: TimestampMs, toAtMs: TimestampMs, groupBy: String? = nil, botId: ID? = nil, routineId: ID? = nil) {
        self.`fromAtMs` = fromAtMs
        self.`toAtMs` = toAtMs
        self.`groupBy` = groupBy
        self.`botId` = botId
        self.`routineId` = routineId
    }
    enum CodingKeys: String, CodingKey { case `fromAtMs`, `toAtMs`, `groupBy`, `botId`, `routineId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`fromAtMs` = try c.decode(TimestampMs.self, forKey: .`fromAtMs`)
        self.`toAtMs` = try c.decode(TimestampMs.self, forKey: .`toAtMs`)
        self.`groupBy` = try c.decodeOptional(String.self, forKey: .`groupBy`)
        self.`botId` = try c.decodeOptional(ID.self, forKey: .`botId`)
        self.`routineId` = try c.decodeOptional(ID.self, forKey: .`routineId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`fromAtMs`, forKey: .`fromAtMs`)
        try c.encode(`toAtMs`, forKey: .`toAtMs`)
        try c.encodeIfPresent(`groupBy`, forKey: .`groupBy`)
        try c.encodeIfPresent(`botId`, forKey: .`botId`)
        try c.encodeIfPresent(`routineId`, forKey: .`routineId`)
    }
}

public struct UsageBucket: Codable, Hashable {
    public var `key`: String
    public var `inputTokens`: Int
    public var `outputTokens`: Int
    public var `requests`: Int
    public var `costUsd`: Double?
    public init(key: String, inputTokens: Int, outputTokens: Int, requests: Int, costUsd: Double? = nil) {
        self.`key` = key
        self.`inputTokens` = inputTokens
        self.`outputTokens` = outputTokens
        self.`requests` = requests
        self.`costUsd` = costUsd
    }
    enum CodingKeys: String, CodingKey { case `key`, `inputTokens`, `outputTokens`, `requests`, `costUsd` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`key` = try c.decode(String.self, forKey: .`key`)
        self.`inputTokens` = try c.decode(Int.self, forKey: .`inputTokens`)
        self.`outputTokens` = try c.decode(Int.self, forKey: .`outputTokens`)
        self.`requests` = try c.decode(Int.self, forKey: .`requests`)
        self.`costUsd` = try c.decode(Double?.self, forKey: .`costUsd`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`key`, forKey: .`key`)
        try c.encode(`inputTokens`, forKey: .`inputTokens`)
        try c.encode(`outputTokens`, forKey: .`outputTokens`)
        try c.encode(`requests`, forKey: .`requests`)
        try c.encode(`costUsd`, forKey: .`costUsd`)
    }
}

public struct UsageReport: Codable, Hashable {
    public var `fromAtMs`: TimestampMs
    public var `toAtMs`: TimestampMs
    public var `totals`: UsageBucket
    public var `buckets`: [UsageBucket]
    public var `incomplete`: Bool
    public var `pricingSource`: String?
    public init(fromAtMs: TimestampMs, toAtMs: TimestampMs, totals: UsageBucket, buckets: [UsageBucket], incomplete: Bool, pricingSource: String? = nil) {
        self.`fromAtMs` = fromAtMs
        self.`toAtMs` = toAtMs
        self.`totals` = totals
        self.`buckets` = buckets
        self.`incomplete` = incomplete
        self.`pricingSource` = pricingSource
    }
    enum CodingKeys: String, CodingKey { case `fromAtMs`, `toAtMs`, `totals`, `buckets`, `incomplete`, `pricingSource` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`fromAtMs` = try c.decode(TimestampMs.self, forKey: .`fromAtMs`)
        self.`toAtMs` = try c.decode(TimestampMs.self, forKey: .`toAtMs`)
        self.`totals` = try c.decode(UsageBucket.self, forKey: .`totals`)
        self.`buckets` = try c.decode([UsageBucket].self, forKey: .`buckets`)
        self.`incomplete` = try c.decode(Bool.self, forKey: .`incomplete`)
        self.`pricingSource` = try c.decode(String?.self, forKey: .`pricingSource`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`fromAtMs`, forKey: .`fromAtMs`)
        try c.encode(`toAtMs`, forKey: .`toAtMs`)
        try c.encode(`totals`, forKey: .`totals`)
        try c.encode(`buckets`, forKey: .`buckets`)
        try c.encode(`incomplete`, forKey: .`incomplete`)
        try c.encode(`pricingSource`, forKey: .`pricingSource`)
    }
}

public struct AuditRecord: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `actor`: Actor
    public var `action`: String
    public var `resourceType`: String
    public var `resourceId`: ID
    public var `outcome`: String
    public var `requestId`: String
    public var `metadata`: JSONObject
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, actor: Actor, action: String, resourceType: String, resourceId: ID, outcome: String, requestId: String, metadata: JSONObject) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`actor` = actor
        self.`action` = action
        self.`resourceType` = resourceType
        self.`resourceId` = resourceId
        self.`outcome` = outcome
        self.`requestId` = requestId
        self.`metadata` = metadata
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `actor`, `action`, `resourceType`, `resourceId`, `outcome`, `requestId`, `metadata` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`actor` = try c.decode(Actor.self, forKey: .`actor`)
        self.`action` = try c.decode(String.self, forKey: .`action`)
        self.`resourceType` = try c.decode(String.self, forKey: .`resourceType`)
        self.`resourceId` = try c.decode(ID.self, forKey: .`resourceId`)
        self.`outcome` = try c.decode(String.self, forKey: .`outcome`)
        guard ["succeeded", "denied", "failed", "outcome_unknown"].contains(`outcome`) else { throw DecodingError.dataCorruptedError(forKey: .`outcome`, in: c, debugDescription: "Invalid AuditRecord.outcome") }
        self.`requestId` = try c.decode(String.self, forKey: .`requestId`)
        self.`metadata` = try c.decode(JSONObject.self, forKey: .`metadata`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`actor`, forKey: .`actor`)
        try c.encode(`action`, forKey: .`action`)
        try c.encode(`resourceType`, forKey: .`resourceType`)
        try c.encode(`resourceId`, forKey: .`resourceId`)
        try c.encode(`outcome`, forKey: .`outcome`)
        try c.encode(`requestId`, forKey: .`requestId`)
        try c.encode(`metadata`, forKey: .`metadata`)
    }
}

public struct PolicyRule: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `ownerUserId`: ID?
    public var `category`: ActionCategory
    public var `botId`: ID?
    public var `machineId`: ID?
    public var `mode`: String
    public var `description`: String
    public var `required`: Bool
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, ownerUserId: ID? = nil, category: ActionCategory, botId: ID? = nil, machineId: ID? = nil, mode: String, description: String, required: Bool) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`ownerUserId` = ownerUserId
        self.`category` = category
        self.`botId` = botId
        self.`machineId` = machineId
        self.`mode` = mode
        self.`description` = description
        self.`required` = required
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `ownerUserId`, `category`, `botId`, `machineId`, `mode`, `description`, `required` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`ownerUserId` = try c.decode(ID?.self, forKey: .`ownerUserId`)
        self.`category` = try c.decode(ActionCategory.self, forKey: .`category`)
        self.`botId` = try c.decode(ID?.self, forKey: .`botId`)
        self.`machineId` = try c.decode(ID?.self, forKey: .`machineId`)
        self.`mode` = try c.decode(String.self, forKey: .`mode`)
        guard ["ask_first", "auto_review", "allow"].contains(`mode`) else { throw DecodingError.dataCorruptedError(forKey: .`mode`, in: c, debugDescription: "Invalid PolicyRule.mode") }
        self.`description` = try c.decode(String.self, forKey: .`description`)
        self.`required` = try c.decode(Bool.self, forKey: .`required`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`ownerUserId`, forKey: .`ownerUserId`)
        try c.encode(`category`, forKey: .`category`)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`machineId`, forKey: .`machineId`)
        try c.encode(`mode`, forKey: .`mode`)
        try c.encode(`description`, forKey: .`description`)
        try c.encode(`required`, forKey: .`required`)
    }
}

public struct PolicyRuleCreate: Codable, Hashable {
    public var `clientNonce`: String
    public var `category`: ActionCategory
    public var `botId`: ID?
    public var `machineId`: ID?
    public var `mode`: String
    public var `description`: String
    public var `required`: Bool
    public init(clientNonce: String, category: ActionCategory, botId: ID? = nil, machineId: ID? = nil, mode: String, description: String, required: Bool) {
        self.`clientNonce` = clientNonce
        self.`category` = category
        self.`botId` = botId
        self.`machineId` = machineId
        self.`mode` = mode
        self.`description` = description
        self.`required` = required
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `category`, `botId`, `machineId`, `mode`, `description`, `required` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`category` = try c.decode(ActionCategory.self, forKey: .`category`)
        self.`botId` = try c.decodeOptional(ID.self, forKey: .`botId`)
        self.`machineId` = try c.decodeOptional(ID.self, forKey: .`machineId`)
        self.`mode` = try c.decode(String.self, forKey: .`mode`)
        self.`description` = try c.decode(String.self, forKey: .`description`)
        self.`required` = try c.decode(Bool.self, forKey: .`required`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`category`, forKey: .`category`)
        try c.encodeIfPresent(`botId`, forKey: .`botId`)
        try c.encodeIfPresent(`machineId`, forKey: .`machineId`)
        try c.encode(`mode`, forKey: .`mode`)
        try c.encode(`description`, forKey: .`description`)
        try c.encode(`required`, forKey: .`required`)
    }
}

public struct PolicyRuleUpdate: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `mode`: String?
    public var `description`: String?
    public init(clientNonce: String, revision: Int, mode: String? = nil, description: String? = nil) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`mode` = mode
        self.`description` = description
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `mode`, `description` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`mode` = try c.decodeOptional(String.self, forKey: .`mode`)
        self.`description` = try c.decodeOptional(String.self, forKey: .`description`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encodeIfPresent(`mode`, forKey: .`mode`)
        try c.encodeIfPresent(`description`, forKey: .`description`)
    }
}

public struct Policies: Codable, Hashable {
    public var `revision`: Int
    public var `publicTemplates`: Bool
    public var `allowedMcpOrigins`: [String]?
    public var `localExecutionCeiling`: String
    public var `actionRecording`: Bool
    public var `auditRetentionDays`: Int
    public var `rules`: [PolicyRule]
    public init(revision: Int, publicTemplates: Bool, allowedMcpOrigins: [String]? = nil, localExecutionCeiling: String, actionRecording: Bool, auditRetentionDays: Int, rules: [PolicyRule]) {
        self.`revision` = revision
        self.`publicTemplates` = publicTemplates
        self.`allowedMcpOrigins` = allowedMcpOrigins
        self.`localExecutionCeiling` = localExecutionCeiling
        self.`actionRecording` = actionRecording
        self.`auditRetentionDays` = auditRetentionDays
        self.`rules` = rules
    }
    enum CodingKeys: String, CodingKey { case `revision`, `publicTemplates`, `allowedMcpOrigins`, `localExecutionCeiling`, `actionRecording`, `auditRetentionDays`, `rules` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`publicTemplates` = try c.decode(Bool.self, forKey: .`publicTemplates`)
        self.`allowedMcpOrigins` = try c.decode([String]?.self, forKey: .`allowedMcpOrigins`)
        self.`localExecutionCeiling` = try c.decode(String.self, forKey: .`localExecutionCeiling`)
        guard ["ask", "allow", "deny"].contains(`localExecutionCeiling`) else { throw DecodingError.dataCorruptedError(forKey: .`localExecutionCeiling`, in: c, debugDescription: "Invalid Policies.localExecutionCeiling") }
        self.`actionRecording` = try c.decode(Bool.self, forKey: .`actionRecording`)
        self.`auditRetentionDays` = try c.decode(Int.self, forKey: .`auditRetentionDays`)
        self.`rules` = try c.decode([PolicyRule].self, forKey: .`rules`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`publicTemplates`, forKey: .`publicTemplates`)
        try c.encode(`allowedMcpOrigins`, forKey: .`allowedMcpOrigins`)
        try c.encode(`localExecutionCeiling`, forKey: .`localExecutionCeiling`)
        try c.encode(`actionRecording`, forKey: .`actionRecording`)
        try c.encode(`auditRetentionDays`, forKey: .`auditRetentionDays`)
        try c.encode(`rules`, forKey: .`rules`)
    }
}

public struct PoliciesUpdate: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `publicTemplates`: Bool?
    public var `allowedMcpOrigins`: [String]??
    public var `localExecutionCeiling`: String?
    public var `actionRecording`: Bool?
    public var `auditRetentionDays`: Int?
    public init(clientNonce: String, revision: Int, publicTemplates: Bool? = nil, allowedMcpOrigins: [String]?? = nil, localExecutionCeiling: String? = nil, actionRecording: Bool? = nil, auditRetentionDays: Int? = nil) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`publicTemplates` = publicTemplates
        self.`allowedMcpOrigins` = allowedMcpOrigins
        self.`localExecutionCeiling` = localExecutionCeiling
        self.`actionRecording` = actionRecording
        self.`auditRetentionDays` = auditRetentionDays
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `publicTemplates`, `allowedMcpOrigins`, `localExecutionCeiling`, `actionRecording`, `auditRetentionDays` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`publicTemplates` = try c.decodeOptional(Bool.self, forKey: .`publicTemplates`)
        self.`allowedMcpOrigins` = c.contains(.`allowedMcpOrigins`) ? .some(try c.decodeIfPresent([String].self, forKey: .`allowedMcpOrigins`)) : nil
        self.`localExecutionCeiling` = try c.decodeOptional(String.self, forKey: .`localExecutionCeiling`)
        self.`actionRecording` = try c.decodeOptional(Bool.self, forKey: .`actionRecording`)
        self.`auditRetentionDays` = try c.decodeOptional(Int.self, forKey: .`auditRetentionDays`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encodeIfPresent(`publicTemplates`, forKey: .`publicTemplates`)
        if let value = `allowedMcpOrigins` { try c.encode(value, forKey: .`allowedMcpOrigins`) }
        try c.encodeIfPresent(`localExecutionCeiling`, forKey: .`localExecutionCeiling`)
        try c.encodeIfPresent(`actionRecording`, forKey: .`actionRecording`)
        try c.encodeIfPresent(`auditRetentionDays`, forKey: .`auditRetentionDays`)
    }
}

public struct Connector: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `botId`: ID
    public var `ownerUserId`: ID
    public var `name`: String
    public var `url`: String
    public var `accountLabel`: String
    public var `authKind`: String
    public var `state`: String
    public var `tools`: [ConnectorTools]
    public var `secretHeaderNames`: [String]
    public var `lastError`: String?
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, botId: ID, ownerUserId: ID, name: String, url: String, accountLabel: String, authKind: String, state: String, tools: [ConnectorTools], secretHeaderNames: [String], lastError: String? = nil) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`botId` = botId
        self.`ownerUserId` = ownerUserId
        self.`name` = name
        self.`url` = url
        self.`accountLabel` = accountLabel
        self.`authKind` = authKind
        self.`state` = state
        self.`tools` = tools
        self.`secretHeaderNames` = secretHeaderNames
        self.`lastError` = lastError
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `botId`, `ownerUserId`, `name`, `url`, `accountLabel`, `authKind`, `state`, `tools`, `secretHeaderNames`, `lastError` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`botId` = try c.decode(ID.self, forKey: .`botId`)
        self.`ownerUserId` = try c.decode(ID.self, forKey: .`ownerUserId`)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`url` = try c.decode(String.self, forKey: .`url`)
        self.`accountLabel` = try c.decode(String.self, forKey: .`accountLabel`)
        self.`authKind` = try c.decode(String.self, forKey: .`authKind`)
        guard ["none", "secret_headers", "oauth"].contains(`authKind`) else { throw DecodingError.dataCorruptedError(forKey: .`authKind`, in: c, debugDescription: "Invalid Connector.authKind") }
        self.`state` = try c.decode(String.self, forKey: .`state`)
        guard ["added", "connected", "needs_auth", "disconnected", "blocked", "failed"].contains(`state`) else { throw DecodingError.dataCorruptedError(forKey: .`state`, in: c, debugDescription: "Invalid Connector.state") }
        self.`tools` = try c.decode([ConnectorTools].self, forKey: .`tools`)
        self.`secretHeaderNames` = try c.decode([String].self, forKey: .`secretHeaderNames`)
        self.`lastError` = try c.decode(String?.self, forKey: .`lastError`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`ownerUserId`, forKey: .`ownerUserId`)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`url`, forKey: .`url`)
        try c.encode(`accountLabel`, forKey: .`accountLabel`)
        try c.encode(`authKind`, forKey: .`authKind`)
        try c.encode(`state`, forKey: .`state`)
        try c.encode(`tools`, forKey: .`tools`)
        try c.encode(`secretHeaderNames`, forKey: .`secretHeaderNames`)
        try c.encode(`lastError`, forKey: .`lastError`)
    }
}

public struct ConnectorCreate: Codable, Hashable {
    public var `clientNonce`: String
    public var `name`: String
    public var `url`: String
    public var `accountLabel`: String
    public var `authKind`: String
    public var `secretBindings`: [ConnectorCreateSecretBindings]?
    public init(clientNonce: String, name: String, url: String, accountLabel: String, authKind: String, secretBindings: [ConnectorCreateSecretBindings]? = nil) {
        self.`clientNonce` = clientNonce
        self.`name` = name
        self.`url` = url
        self.`accountLabel` = accountLabel
        self.`authKind` = authKind
        self.`secretBindings` = secretBindings
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `name`, `url`, `accountLabel`, `authKind`, `secretBindings` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`url` = try c.decode(String.self, forKey: .`url`)
        self.`accountLabel` = try c.decode(String.self, forKey: .`accountLabel`)
        self.`authKind` = try c.decode(String.self, forKey: .`authKind`)
        self.`secretBindings` = try c.decodeOptional([ConnectorCreateSecretBindings].self, forKey: .`secretBindings`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`url`, forKey: .`url`)
        try c.encode(`accountLabel`, forKey: .`accountLabel`)
        try c.encode(`authKind`, forKey: .`authKind`)
        try c.encodeIfPresent(`secretBindings`, forKey: .`secretBindings`)
    }
}

public struct ConnectorUpdate: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `name`: String?
    public var `accountLabel`: String?
    public var `tools`: [ConnectorUpdateTools]?
    public var `secretBindings`: [ConnectorUpdateSecretBindings]?
    public init(clientNonce: String, revision: Int, name: String? = nil, accountLabel: String? = nil, tools: [ConnectorUpdateTools]? = nil, secretBindings: [ConnectorUpdateSecretBindings]? = nil) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`name` = name
        self.`accountLabel` = accountLabel
        self.`tools` = tools
        self.`secretBindings` = secretBindings
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `name`, `accountLabel`, `tools`, `secretBindings` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`name` = try c.decodeOptional(String.self, forKey: .`name`)
        self.`accountLabel` = try c.decodeOptional(String.self, forKey: .`accountLabel`)
        self.`tools` = try c.decodeOptional([ConnectorUpdateTools].self, forKey: .`tools`)
        self.`secretBindings` = try c.decodeOptional([ConnectorUpdateSecretBindings].self, forKey: .`secretBindings`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encodeIfPresent(`name`, forKey: .`name`)
        try c.encodeIfPresent(`accountLabel`, forKey: .`accountLabel`)
        try c.encodeIfPresent(`tools`, forKey: .`tools`)
        try c.encodeIfPresent(`secretBindings`, forKey: .`secretBindings`)
    }
}

public struct ConnectorAuth: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `connectorId`: ID
    public var `authorizationUrl`: String
    public var `expiresAtMs`: TimestampMs
    public var `state`: String
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, connectorId: ID, authorizationUrl: String, expiresAtMs: TimestampMs, state: String) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`connectorId` = connectorId
        self.`authorizationUrl` = authorizationUrl
        self.`expiresAtMs` = expiresAtMs
        self.`state` = state
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `connectorId`, `authorizationUrl`, `expiresAtMs`, `state` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`connectorId` = try c.decode(ID.self, forKey: .`connectorId`)
        self.`authorizationUrl` = try c.decode(String.self, forKey: .`authorizationUrl`)
        self.`expiresAtMs` = try c.decode(TimestampMs.self, forKey: .`expiresAtMs`)
        self.`state` = try c.decode(String.self, forKey: .`state`)
        guard ["pending", "connected", "denied", "expired", "failed"].contains(`state`) else { throw DecodingError.dataCorruptedError(forKey: .`state`, in: c, debugDescription: "Invalid ConnectorAuth.state") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`connectorId`, forKey: .`connectorId`)
        try c.encode(`authorizationUrl`, forKey: .`authorizationUrl`)
        try c.encode(`expiresAtMs`, forKey: .`expiresAtMs`)
        try c.encode(`state`, forKey: .`state`)
    }
}


public struct ChannelBinding: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `botId`: ID
    public var `ownerUserId`: ID
    public var `adapter`: String
    public var `accountId`: String
    public var `target`: String
    public var `enabled`: Bool
    public var `state`: String
    public var `capabilities`: ChannelBindingCapabilities
    public var `lastError`: String?
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, botId: ID, ownerUserId: ID, adapter: String, accountId: String, target: String, enabled: Bool, state: String, capabilities: ChannelBindingCapabilities, lastError: String? = nil) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`botId` = botId
        self.`ownerUserId` = ownerUserId
        self.`adapter` = adapter
        self.`accountId` = accountId
        self.`target` = target
        self.`enabled` = enabled
        self.`state` = state
        self.`capabilities` = capabilities
        self.`lastError` = lastError
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `botId`, `ownerUserId`, `adapter`, `accountId`, `target`, `enabled`, `state`, `capabilities`, `lastError` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`botId` = try c.decode(ID.self, forKey: .`botId`)
        self.`ownerUserId` = try c.decode(ID.self, forKey: .`ownerUserId`)
        self.`adapter` = try c.decode(String.self, forKey: .`adapter`)
        guard ["email", "slack", "telegram", "discord", "whatsapp"].contains(`adapter`) else { throw DecodingError.dataCorruptedError(forKey: .`adapter`, in: c, debugDescription: "Invalid ChannelBinding.adapter") }
        self.`accountId` = try c.decode(String.self, forKey: .`accountId`)
        self.`target` = try c.decode(String.self, forKey: .`target`)
        self.`enabled` = try c.decode(Bool.self, forKey: .`enabled`)
        self.`state` = try c.decode(String.self, forKey: .`state`)
        guard ["configured", "connected", "disconnected", "blocked", "failed"].contains(`state`) else { throw DecodingError.dataCorruptedError(forKey: .`state`, in: c, debugDescription: "Invalid ChannelBinding.state") }
        self.`capabilities` = try c.decode(ChannelBindingCapabilities.self, forKey: .`capabilities`)
        self.`lastError` = try c.decode(String?.self, forKey: .`lastError`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`ownerUserId`, forKey: .`ownerUserId`)
        try c.encode(`adapter`, forKey: .`adapter`)
        try c.encode(`accountId`, forKey: .`accountId`)
        try c.encode(`target`, forKey: .`target`)
        try c.encode(`enabled`, forKey: .`enabled`)
        try c.encode(`state`, forKey: .`state`)
        try c.encode(`capabilities`, forKey: .`capabilities`)
        try c.encode(`lastError`, forKey: .`lastError`)
    }
}

public struct ChannelCreate: Codable, Hashable {
    public var `clientNonce`: String
    public var `botId`: ID
    public var `adapter`: String
    public var `accountId`: String
    public var `target`: String
    public var `enabled`: Bool
    public init(clientNonce: String, botId: ID, adapter: String, accountId: String, target: String, enabled: Bool) {
        self.`clientNonce` = clientNonce
        self.`botId` = botId
        self.`adapter` = adapter
        self.`accountId` = accountId
        self.`target` = target
        self.`enabled` = enabled
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `botId`, `adapter`, `accountId`, `target`, `enabled` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`botId` = try c.decode(ID.self, forKey: .`botId`)
        self.`adapter` = try c.decode(String.self, forKey: .`adapter`)
        self.`accountId` = try c.decode(String.self, forKey: .`accountId`)
        self.`target` = try c.decode(String.self, forKey: .`target`)
        self.`enabled` = try c.decode(Bool.self, forKey: .`enabled`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`adapter`, forKey: .`adapter`)
        try c.encode(`accountId`, forKey: .`accountId`)
        try c.encode(`target`, forKey: .`target`)
        try c.encode(`enabled`, forKey: .`enabled`)
    }
}

public struct ChannelUpdate: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `target`: String?
    public var `enabled`: Bool?
    public init(clientNonce: String, revision: Int, target: String? = nil, enabled: Bool? = nil) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`target` = target
        self.`enabled` = enabled
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `target`, `enabled` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`target` = try c.decodeOptional(String.self, forKey: .`target`)
        self.`enabled` = try c.decodeOptional(Bool.self, forKey: .`enabled`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encodeIfPresent(`target`, forKey: .`target`)
        try c.encodeIfPresent(`enabled`, forKey: .`enabled`)
    }
}

public struct ExternalSource: Codable, Hashable {
    public var `source`: String
    public var `events`: [String]
    public var `configured`: Bool
    public init(source: String, events: [String], configured: Bool) {
        self.`source` = source
        self.`events` = events
        self.`configured` = configured
    }
    enum CodingKeys: String, CodingKey { case `source`, `events`, `configured` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`source` = try c.decode(String.self, forKey: .`source`)
        guard ["github", "linear", "sentry", "pagerduty"].contains(`source`) else { throw DecodingError.dataCorruptedError(forKey: .`source`, in: c, debugDescription: "Invalid ExternalSource.source") }
        self.`events` = try c.decode([String].self, forKey: .`events`)
        self.`configured` = try c.decode(Bool.self, forKey: .`configured`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`source`, forKey: .`source`)
        try c.encode(`events`, forKey: .`events`)
        try c.encode(`configured`, forKey: .`configured`)
    }
}

public struct VoiceSession: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `conversationId`: ID
    public var `userId`: ID
    public var `deviceId`: ID
    public var `settings`: VoiceSettings
    public var `state`: String
    public var `startedAtMs`: TimestampMs
    public var `endedAtMs`: TimestampMs?
    public var `durationMs`: Int
    public var `transcriptEntryIds`: [ID]
    public var `muted`: Bool
    public var `feedback`: String?
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, conversationId: ID, userId: ID, deviceId: ID, settings: VoiceSettings, state: String, startedAtMs: TimestampMs, endedAtMs: TimestampMs? = nil, durationMs: Int, transcriptEntryIds: [ID], muted: Bool, feedback: String? = nil) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`conversationId` = conversationId
        self.`userId` = userId
        self.`deviceId` = deviceId
        self.`settings` = settings
        self.`state` = state
        self.`startedAtMs` = startedAtMs
        self.`endedAtMs` = endedAtMs
        self.`durationMs` = durationMs
        self.`transcriptEntryIds` = transcriptEntryIds
        self.`muted` = muted
        self.`feedback` = feedback
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `conversationId`, `userId`, `deviceId`, `settings`, `state`, `startedAtMs`, `endedAtMs`, `durationMs`, `transcriptEntryIds`, `muted`, `feedback` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`conversationId` = try c.decode(ID.self, forKey: .`conversationId`)
        self.`userId` = try c.decode(ID.self, forKey: .`userId`)
        self.`deviceId` = try c.decode(ID.self, forKey: .`deviceId`)
        self.`settings` = try c.decode(VoiceSettings.self, forKey: .`settings`)
        self.`state` = try c.decode(String.self, forKey: .`state`)
        guard ["active", "ended", "failed"].contains(`state`) else { throw DecodingError.dataCorruptedError(forKey: .`state`, in: c, debugDescription: "Invalid VoiceSession.state") }
        self.`startedAtMs` = try c.decode(TimestampMs.self, forKey: .`startedAtMs`)
        self.`endedAtMs` = try c.decode(TimestampMs?.self, forKey: .`endedAtMs`)
        self.`durationMs` = try c.decode(Int.self, forKey: .`durationMs`)
        self.`transcriptEntryIds` = try c.decode([ID].self, forKey: .`transcriptEntryIds`)
        self.`muted` = try c.decode(Bool.self, forKey: .`muted`)
        self.`feedback` = try c.decode(String?.self, forKey: .`feedback`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`conversationId`, forKey: .`conversationId`)
        try c.encode(`userId`, forKey: .`userId`)
        try c.encode(`deviceId`, forKey: .`deviceId`)
        try c.encode(`settings`, forKey: .`settings`)
        try c.encode(`state`, forKey: .`state`)
        try c.encode(`startedAtMs`, forKey: .`startedAtMs`)
        try c.encode(`endedAtMs`, forKey: .`endedAtMs`)
        try c.encode(`durationMs`, forKey: .`durationMs`)
        try c.encode(`transcriptEntryIds`, forKey: .`transcriptEntryIds`)
        try c.encode(`muted`, forKey: .`muted`)
        try c.encode(`feedback`, forKey: .`feedback`)
    }
}

public struct VoiceStart: Codable, Hashable {
    public var `clientNonce`: String
    public var `conversationId`: ID
    public var `deviceId`: ID
    public var `settings`: VoiceSettings?
    public init(clientNonce: String, conversationId: ID, deviceId: ID, settings: VoiceSettings? = nil) {
        self.`clientNonce` = clientNonce
        self.`conversationId` = conversationId
        self.`deviceId` = deviceId
        self.`settings` = settings
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `conversationId`, `deviceId`, `settings` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`conversationId` = try c.decode(ID.self, forKey: .`conversationId`)
        self.`deviceId` = try c.decode(ID.self, forKey: .`deviceId`)
        self.`settings` = try c.decodeOptional(VoiceSettings.self, forKey: .`settings`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`conversationId`, forKey: .`conversationId`)
        try c.encode(`deviceId`, forKey: .`deviceId`)
        try c.encodeIfPresent(`settings`, forKey: .`settings`)
    }
}

public struct VoiceUpdate: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `muted`: Bool?
    public var `settings`: VoiceSettings?
    public var `feedback`: String?
    public init(clientNonce: String, revision: Int, muted: Bool? = nil, settings: VoiceSettings? = nil, feedback: String? = nil) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`muted` = muted
        self.`settings` = settings
        self.`feedback` = feedback
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `muted`, `settings`, `feedback` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`muted` = try c.decodeOptional(Bool.self, forKey: .`muted`)
        self.`settings` = try c.decodeOptional(VoiceSettings.self, forKey: .`settings`)
        self.`feedback` = try c.decodeOptional(String.self, forKey: .`feedback`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encodeIfPresent(`muted`, forKey: .`muted`)
        try c.encodeIfPresent(`settings`, forKey: .`settings`)
        try c.encodeIfPresent(`feedback`, forKey: .`feedback`)
    }
}

public struct TranscriptionRequest: Codable, Hashable {
    public var `clientNonce`: String
    public var `attachmentId`: ID
    public var `language`: String?
    public var `voiceSessionId`: ID?
    public init(clientNonce: String, attachmentId: ID, language: String? = nil, voiceSessionId: ID? = nil) {
        self.`clientNonce` = clientNonce
        self.`attachmentId` = attachmentId
        self.`language` = language
        self.`voiceSessionId` = voiceSessionId
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `attachmentId`, `language`, `voiceSessionId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`attachmentId` = try c.decode(ID.self, forKey: .`attachmentId`)
        self.`language` = try c.decodeOptional(String.self, forKey: .`language`)
        self.`voiceSessionId` = try c.decodeOptional(ID.self, forKey: .`voiceSessionId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`attachmentId`, forKey: .`attachmentId`)
        try c.encodeIfPresent(`language`, forKey: .`language`)
        try c.encodeIfPresent(`voiceSessionId`, forKey: .`voiceSessionId`)
    }
}

public struct Transcription: Codable, Hashable {
    public var `text`: String
    public var `language`: String?
    public var `durationMs`: Int
    public var `segments`: [TranscriptionSegments]
    public init(text: String, language: String? = nil, durationMs: Int, segments: [TranscriptionSegments]) {
        self.`text` = text
        self.`language` = language
        self.`durationMs` = durationMs
        self.`segments` = segments
    }
    enum CodingKeys: String, CodingKey { case `text`, `language`, `durationMs`, `segments` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`text` = try c.decode(String.self, forKey: .`text`)
        self.`language` = try c.decode(String?.self, forKey: .`language`)
        self.`durationMs` = try c.decode(Int.self, forKey: .`durationMs`)
        self.`segments` = try c.decode([TranscriptionSegments].self, forKey: .`segments`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`text`, forKey: .`text`)
        try c.encode(`language`, forKey: .`language`)
        try c.encode(`durationMs`, forKey: .`durationMs`)
        try c.encode(`segments`, forKey: .`segments`)
    }
}

public struct SpeechRequest: Codable, Hashable {
    public var `clientNonce`: String
    public var `text`: String
    public var `voice`: VoiceSettings
    public var `conversationId`: ID?
    public var `voiceSessionId`: ID?
    public init(clientNonce: String, text: String, voice: VoiceSettings, conversationId: ID? = nil, voiceSessionId: ID? = nil) {
        self.`clientNonce` = clientNonce
        self.`text` = text
        self.`voice` = voice
        self.`conversationId` = conversationId
        self.`voiceSessionId` = voiceSessionId
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `text`, `voice`, `conversationId`, `voiceSessionId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`text` = try c.decode(String.self, forKey: .`text`)
        self.`voice` = try c.decode(VoiceSettings.self, forKey: .`voice`)
        self.`conversationId` = try c.decodeOptional(ID.self, forKey: .`conversationId`)
        self.`voiceSessionId` = try c.decodeOptional(ID.self, forKey: .`voiceSessionId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`text`, forKey: .`text`)
        try c.encode(`voice`, forKey: .`voice`)
        try c.encodeIfPresent(`conversationId`, forKey: .`conversationId`)
        try c.encodeIfPresent(`voiceSessionId`, forKey: .`voiceSessionId`)
    }
}

public struct SpeechResult: Codable, Hashable {
    public var `attachment`: Attachment
    public var `download`: Download
    public init(attachment: Attachment, download: Download) {
        self.`attachment` = attachment
        self.`download` = download
    }
    enum CodingKeys: String, CodingKey { case `attachment`, `download` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`attachment` = try c.decode(Attachment.self, forKey: .`attachment`)
        self.`download` = try c.decode(Download.self, forKey: .`download`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`attachment`, forKey: .`attachment`)
        try c.encode(`download`, forKey: .`download`)
    }
}

public struct ScopeEffect: Codable, Hashable, Identifiable {
    public var `resourceType`: String
    public var `id`: ID
    public var `machineId`: ID?
    public var `operation`: String
    public var `explanation`: String
    public init(resourceType: String, id: ID, machineId: ID? = nil, operation: String, explanation: String) {
        self.`resourceType` = resourceType
        self.`id` = id
        self.`machineId` = machineId
        self.`operation` = operation
        self.`explanation` = explanation
    }
    enum CodingKeys: String, CodingKey { case `resourceType`, `id`, `machineId`, `operation`, `explanation` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`resourceType` = try c.decode(String.self, forKey: .`resourceType`)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`machineId` = try c.decode(ID?.self, forKey: .`machineId`)
        self.`operation` = try c.decode(String.self, forKey: .`operation`)
        guard ["delete", "revoke", "reset", "move", "retain"].contains(`operation`) else { throw DecodingError.dataCorruptedError(forKey: .`operation`, in: c, debugDescription: "Invalid ScopeEffect.operation") }
        self.`explanation` = try c.decode(String.self, forKey: .`explanation`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`resourceType`, forKey: .`resourceType`)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`machineId`, forKey: .`machineId`)
        try c.encode(`operation`, forKey: .`operation`)
        try c.encode(`explanation`, forKey: .`explanation`)
    }
}

public struct BotPresence: Codable, Hashable {
    public var `botId`: ID
    public var `status`: String
    public var `machineId`: ID
    public var `machineLabel`: String
    public var `machineStatus`: String
    public var `currentRunId`: ID?
    public var `taskConversationId`: ID?
    public var `summary`: String
    public var `evidenceEntryId`: ID?
    public var `measuredAtMs`: TimestampMs
    public var `stale`: Bool
    public init(botId: ID, status: String, machineId: ID, machineLabel: String, machineStatus: String, currentRunId: ID? = nil, taskConversationId: ID? = nil, summary: String, evidenceEntryId: ID? = nil, measuredAtMs: TimestampMs, stale: Bool) {
        self.`botId` = botId
        self.`status` = status
        self.`machineId` = machineId
        self.`machineLabel` = machineLabel
        self.`machineStatus` = machineStatus
        self.`currentRunId` = currentRunId
        self.`taskConversationId` = taskConversationId
        self.`summary` = summary
        self.`evidenceEntryId` = evidenceEntryId
        self.`measuredAtMs` = measuredAtMs
        self.`stale` = stale
    }
    enum CodingKeys: String, CodingKey { case `botId`, `status`, `machineId`, `machineLabel`, `machineStatus`, `currentRunId`, `taskConversationId`, `summary`, `evidenceEntryId`, `measuredAtMs`, `stale` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`botId` = try c.decode(ID.self, forKey: .`botId`)
        self.`status` = try c.decode(String.self, forKey: .`status`)
        guard ["idle", "working", "making", "needs_input", "offline"].contains(`status`) else { throw DecodingError.dataCorruptedError(forKey: .`status`, in: c, debugDescription: "Invalid BotPresence.status") }
        self.`machineId` = try c.decode(ID.self, forKey: .`machineId`)
        self.`machineLabel` = try c.decode(String.self, forKey: .`machineLabel`)
        self.`machineStatus` = try c.decode(String.self, forKey: .`machineStatus`)
        self.`currentRunId` = try c.decode(ID?.self, forKey: .`currentRunId`)
        self.`taskConversationId` = try c.decode(ID?.self, forKey: .`taskConversationId`)
        self.`summary` = try c.decode(String.self, forKey: .`summary`)
        self.`evidenceEntryId` = try c.decode(ID?.self, forKey: .`evidenceEntryId`)
        self.`measuredAtMs` = try c.decode(TimestampMs.self, forKey: .`measuredAtMs`)
        self.`stale` = try c.decode(Bool.self, forKey: .`stale`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`status`, forKey: .`status`)
        try c.encode(`machineId`, forKey: .`machineId`)
        try c.encode(`machineLabel`, forKey: .`machineLabel`)
        try c.encode(`machineStatus`, forKey: .`machineStatus`)
        try c.encode(`currentRunId`, forKey: .`currentRunId`)
        try c.encode(`taskConversationId`, forKey: .`taskConversationId`)
        try c.encode(`summary`, forKey: .`summary`)
        try c.encode(`evidenceEntryId`, forKey: .`evidenceEntryId`)
        try c.encode(`measuredAtMs`, forKey: .`measuredAtMs`)
        try c.encode(`stale`, forKey: .`stale`)
    }
}

public struct MachineCapability: Codable, Hashable, Identifiable {
    public var `id`: String
    public var `name`: String
    public var `category`: String
    public var `supported`: Bool
    public var `configuredLevel`: AccessLevel
    public var `osGrant`: String
    public var `tools`: [String]
    public var `reason`: String
    public var `measuredAtMs`: TimestampMs
    public var `stale`: Bool
    public init(id: String, name: String, category: String, supported: Bool, configuredLevel: AccessLevel, osGrant: String, tools: [String], reason: String, measuredAtMs: TimestampMs, stale: Bool) {
        self.`id` = id
        self.`name` = name
        self.`category` = category
        self.`supported` = supported
        self.`configuredLevel` = configuredLevel
        self.`osGrant` = osGrant
        self.`tools` = tools
        self.`reason` = reason
        self.`measuredAtMs` = measuredAtMs
        self.`stale` = stale
    }
    enum CodingKeys: String, CodingKey { case `id`, `name`, `category`, `supported`, `configuredLevel`, `osGrant`, `tools`, `reason`, `measuredAtMs`, `stale` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(String.self, forKey: .`id`)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`category` = try c.decode(String.self, forKey: .`category`)
        guard ["files", "shell", "browser", "connector", "os_app"].contains(`category`) else { throw DecodingError.dataCorruptedError(forKey: .`category`, in: c, debugDescription: "Invalid MachineCapability.category") }
        self.`supported` = try c.decode(Bool.self, forKey: .`supported`)
        self.`configuredLevel` = try c.decode(AccessLevel.self, forKey: .`configuredLevel`)
        self.`osGrant` = try c.decode(String.self, forKey: .`osGrant`)
        guard ["granted", "denied", "not_required", "unknown"].contains(`osGrant`) else { throw DecodingError.dataCorruptedError(forKey: .`osGrant`, in: c, debugDescription: "Invalid MachineCapability.osGrant") }
        self.`tools` = try c.decode([String].self, forKey: .`tools`)
        self.`reason` = try c.decode(String.self, forKey: .`reason`)
        self.`measuredAtMs` = try c.decode(TimestampMs.self, forKey: .`measuredAtMs`)
        self.`stale` = try c.decode(Bool.self, forKey: .`stale`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`category`, forKey: .`category`)
        try c.encode(`supported`, forKey: .`supported`)
        try c.encode(`configuredLevel`, forKey: .`configuredLevel`)
        try c.encode(`osGrant`, forKey: .`osGrant`)
        try c.encode(`tools`, forKey: .`tools`)
        try c.encode(`reason`, forKey: .`reason`)
        try c.encode(`measuredAtMs`, forKey: .`measuredAtMs`)
        try c.encode(`stale`, forKey: .`stale`)
    }
}

public struct MachineCapabilities: Codable, Hashable {
    public var `machineId`: ID
    public var `os`: String
    public var `measuredAtMs`: TimestampMs
    public var `stale`: Bool
    public var `items`: [MachineCapability]
    public init(machineId: ID, os: String, measuredAtMs: TimestampMs, stale: Bool, items: [MachineCapability]) {
        self.`machineId` = machineId
        self.`os` = os
        self.`measuredAtMs` = measuredAtMs
        self.`stale` = stale
        self.`items` = items
    }
    enum CodingKeys: String, CodingKey { case `machineId`, `os`, `measuredAtMs`, `stale`, `items` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`machineId` = try c.decode(ID.self, forKey: .`machineId`)
        self.`os` = try c.decode(String.self, forKey: .`os`)
        self.`measuredAtMs` = try c.decode(TimestampMs.self, forKey: .`measuredAtMs`)
        self.`stale` = try c.decode(Bool.self, forKey: .`stale`)
        self.`items` = try c.decode([MachineCapability].self, forKey: .`items`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`machineId`, forKey: .`machineId`)
        try c.encode(`os`, forKey: .`os`)
        try c.encode(`measuredAtMs`, forKey: .`measuredAtMs`)
        try c.encode(`stale`, forKey: .`stale`)
        try c.encode(`items`, forKey: .`items`)
    }
}

public struct BotGrant: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `botId`: ID
    public var `machineId`: ID
    public var `capabilityId`: String
    public var `requestedLevel`: AccessLevel
    public var `effectiveLevel`: AccessLevel
    public var `reasons`: [String]
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, botId: ID, machineId: ID, capabilityId: String, requestedLevel: AccessLevel, effectiveLevel: AccessLevel, reasons: [String]) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`botId` = botId
        self.`machineId` = machineId
        self.`capabilityId` = capabilityId
        self.`requestedLevel` = requestedLevel
        self.`effectiveLevel` = effectiveLevel
        self.`reasons` = reasons
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `botId`, `machineId`, `capabilityId`, `requestedLevel`, `effectiveLevel`, `reasons` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`botId` = try c.decode(ID.self, forKey: .`botId`)
        self.`machineId` = try c.decode(ID.self, forKey: .`machineId`)
        self.`capabilityId` = try c.decode(String.self, forKey: .`capabilityId`)
        self.`requestedLevel` = try c.decode(AccessLevel.self, forKey: .`requestedLevel`)
        self.`effectiveLevel` = try c.decode(AccessLevel.self, forKey: .`effectiveLevel`)
        self.`reasons` = try c.decode([String].self, forKey: .`reasons`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`machineId`, forKey: .`machineId`)
        try c.encode(`capabilityId`, forKey: .`capabilityId`)
        try c.encode(`requestedLevel`, forKey: .`requestedLevel`)
        try c.encode(`effectiveLevel`, forKey: .`effectiveLevel`)
        try c.encode(`reasons`, forKey: .`reasons`)
    }
}

public struct BotGrantUpdate: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `requestedLevel`: AccessLevel
    public init(clientNonce: String, revision: Int, requestedLevel: AccessLevel) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`requestedLevel` = requestedLevel
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `requestedLevel` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`requestedLevel` = try c.decode(AccessLevel.self, forKey: .`requestedLevel`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`requestedLevel`, forKey: .`requestedLevel`)
    }
}

public struct ActivityItem: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `botId`: ID
    public var `machineId`: ID
    public var `machineLabel`: String
    public var `conversationId`: ID?
    public var `taskConversationId`: ID?
    public var `runId`: ID?
    public var `approvalId`: ID?
    public var `entryId`: ID?
    public var `kind`: String
    public var `status`: String
    public var `title`: String
    public var `summary`: String
    public var `occurredAtMs`: TimestampMs
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, botId: ID, machineId: ID, machineLabel: String, conversationId: ID? = nil, taskConversationId: ID? = nil, runId: ID? = nil, approvalId: ID? = nil, entryId: ID? = nil, kind: String, status: String, title: String, summary: String, occurredAtMs: TimestampMs) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`botId` = botId
        self.`machineId` = machineId
        self.`machineLabel` = machineLabel
        self.`conversationId` = conversationId
        self.`taskConversationId` = taskConversationId
        self.`runId` = runId
        self.`approvalId` = approvalId
        self.`entryId` = entryId
        self.`kind` = kind
        self.`status` = status
        self.`title` = title
        self.`summary` = summary
        self.`occurredAtMs` = occurredAtMs
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `botId`, `machineId`, `machineLabel`, `conversationId`, `taskConversationId`, `runId`, `approvalId`, `entryId`, `kind`, `status`, `title`, `summary`, `occurredAtMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`botId` = try c.decode(ID.self, forKey: .`botId`)
        self.`machineId` = try c.decode(ID.self, forKey: .`machineId`)
        self.`machineLabel` = try c.decode(String.self, forKey: .`machineLabel`)
        self.`conversationId` = try c.decode(ID?.self, forKey: .`conversationId`)
        self.`taskConversationId` = try c.decode(ID?.self, forKey: .`taskConversationId`)
        self.`runId` = try c.decode(ID?.self, forKey: .`runId`)
        self.`approvalId` = try c.decode(ID?.self, forKey: .`approvalId`)
        self.`entryId` = try c.decode(ID?.self, forKey: .`entryId`)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["run", "tool", "approval", "memory", "preference", "artifact", "enrollment"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid ActivityItem.kind") }
        self.`status` = try c.decode(String.self, forKey: .`status`)
        guard ["pending", "working", "making", "succeeded", "failed", "denied", "cancelled", "outcome_unknown"].contains(`status`) else { throw DecodingError.dataCorruptedError(forKey: .`status`, in: c, debugDescription: "Invalid ActivityItem.status") }
        self.`title` = try c.decode(String.self, forKey: .`title`)
        self.`summary` = try c.decode(String.self, forKey: .`summary`)
        self.`occurredAtMs` = try c.decode(TimestampMs.self, forKey: .`occurredAtMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`machineId`, forKey: .`machineId`)
        try c.encode(`machineLabel`, forKey: .`machineLabel`)
        try c.encode(`conversationId`, forKey: .`conversationId`)
        try c.encode(`taskConversationId`, forKey: .`taskConversationId`)
        try c.encode(`runId`, forKey: .`runId`)
        try c.encode(`approvalId`, forKey: .`approvalId`)
        try c.encode(`entryId`, forKey: .`entryId`)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`status`, forKey: .`status`)
        try c.encode(`title`, forKey: .`title`)
        try c.encode(`summary`, forKey: .`summary`)
        try c.encode(`occurredAtMs`, forKey: .`occurredAtMs`)
    }
}

public struct ActivityQuery: Codable, Hashable {
    public var `cursor`: Cursor?
    public var `limit`: Int?
    public var `botId`: ID?
    public var `machineId`: ID?
    public var `fromAtMs`: TimestampMs?
    public var `toAtMs`: TimestampMs?
    public init(cursor: Cursor? = nil, limit: Int? = nil, botId: ID? = nil, machineId: ID? = nil, fromAtMs: TimestampMs? = nil, toAtMs: TimestampMs? = nil) {
        self.`cursor` = cursor
        self.`limit` = limit
        self.`botId` = botId
        self.`machineId` = machineId
        self.`fromAtMs` = fromAtMs
        self.`toAtMs` = toAtMs
    }
    enum CodingKeys: String, CodingKey { case `cursor`, `limit`, `botId`, `machineId`, `fromAtMs`, `toAtMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`cursor` = try c.decodeOptional(Cursor.self, forKey: .`cursor`)
        self.`limit` = try c.decodeOptional(Int.self, forKey: .`limit`)
        self.`botId` = try c.decodeOptional(ID.self, forKey: .`botId`)
        self.`machineId` = try c.decodeOptional(ID.self, forKey: .`machineId`)
        self.`fromAtMs` = try c.decodeOptional(TimestampMs.self, forKey: .`fromAtMs`)
        self.`toAtMs` = try c.decodeOptional(TimestampMs.self, forKey: .`toAtMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(`cursor`, forKey: .`cursor`)
        try c.encodeIfPresent(`limit`, forKey: .`limit`)
        try c.encodeIfPresent(`botId`, forKey: .`botId`)
        try c.encodeIfPresent(`machineId`, forKey: .`machineId`)
        try c.encodeIfPresent(`fromAtMs`, forKey: .`fromAtMs`)
        try c.encodeIfPresent(`toAtMs`, forKey: .`toAtMs`)
    }
}

public struct UpcomingItem: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `kind`: String
    public var `botId`: ID
    public var `machineId`: ID
    public var `machineLabel`: String
    public var `machineStatus`: String
    public var `title`: String
    public var `dueAtMs`: TimestampMs
    public var `timezone`: String
    public var `routineId`: ID?
    public var `reminderId`: ID?
    public var `lastRunId`: ID?
    public var `lastRunStatus`: String?
    public var `blockedReason`: String?
    public init(id: ID, kind: String, botId: ID, machineId: ID, machineLabel: String, machineStatus: String, title: String, dueAtMs: TimestampMs, timezone: String, routineId: ID? = nil, reminderId: ID? = nil, lastRunId: ID? = nil, lastRunStatus: String? = nil, blockedReason: String? = nil) {
        self.`id` = id
        self.`kind` = kind
        self.`botId` = botId
        self.`machineId` = machineId
        self.`machineLabel` = machineLabel
        self.`machineStatus` = machineStatus
        self.`title` = title
        self.`dueAtMs` = dueAtMs
        self.`timezone` = timezone
        self.`routineId` = routineId
        self.`reminderId` = reminderId
        self.`lastRunId` = lastRunId
        self.`lastRunStatus` = lastRunStatus
        self.`blockedReason` = blockedReason
    }
    enum CodingKeys: String, CodingKey { case `id`, `kind`, `botId`, `machineId`, `machineLabel`, `machineStatus`, `title`, `dueAtMs`, `timezone`, `routineId`, `reminderId`, `lastRunId`, `lastRunStatus`, `blockedReason` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["routine", "reminder"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid UpcomingItem.kind") }
        self.`botId` = try c.decode(ID.self, forKey: .`botId`)
        self.`machineId` = try c.decode(ID.self, forKey: .`machineId`)
        self.`machineLabel` = try c.decode(String.self, forKey: .`machineLabel`)
        self.`machineStatus` = try c.decode(String.self, forKey: .`machineStatus`)
        self.`title` = try c.decode(String.self, forKey: .`title`)
        self.`dueAtMs` = try c.decode(TimestampMs.self, forKey: .`dueAtMs`)
        self.`timezone` = try c.decode(String.self, forKey: .`timezone`)
        self.`routineId` = try c.decode(ID?.self, forKey: .`routineId`)
        self.`reminderId` = try c.decode(ID?.self, forKey: .`reminderId`)
        self.`lastRunId` = try c.decode(ID?.self, forKey: .`lastRunId`)
        self.`lastRunStatus` = try c.decode(String?.self, forKey: .`lastRunStatus`)
        self.`blockedReason` = try c.decode(String?.self, forKey: .`blockedReason`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`machineId`, forKey: .`machineId`)
        try c.encode(`machineLabel`, forKey: .`machineLabel`)
        try c.encode(`machineStatus`, forKey: .`machineStatus`)
        try c.encode(`title`, forKey: .`title`)
        try c.encode(`dueAtMs`, forKey: .`dueAtMs`)
        try c.encode(`timezone`, forKey: .`timezone`)
        try c.encode(`routineId`, forKey: .`routineId`)
        try c.encode(`reminderId`, forKey: .`reminderId`)
        try c.encode(`lastRunId`, forKey: .`lastRunId`)
        try c.encode(`lastRunStatus`, forKey: .`lastRunStatus`)
        try c.encode(`blockedReason`, forKey: .`blockedReason`)
    }
}

public struct UpcomingQuery: Codable, Hashable {
    public var `cursor`: Cursor?
    public var `limit`: Int?
    public var `botId`: ID?
    public var `machineId`: ID?
    public var `fromAtMs`: TimestampMs?
    public var `toAtMs`: TimestampMs?
    public init(cursor: Cursor? = nil, limit: Int? = nil, botId: ID? = nil, machineId: ID? = nil, fromAtMs: TimestampMs? = nil, toAtMs: TimestampMs? = nil) {
        self.`cursor` = cursor
        self.`limit` = limit
        self.`botId` = botId
        self.`machineId` = machineId
        self.`fromAtMs` = fromAtMs
        self.`toAtMs` = toAtMs
    }
    enum CodingKeys: String, CodingKey { case `cursor`, `limit`, `botId`, `machineId`, `fromAtMs`, `toAtMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`cursor` = try c.decodeOptional(Cursor.self, forKey: .`cursor`)
        self.`limit` = try c.decodeOptional(Int.self, forKey: .`limit`)
        self.`botId` = try c.decodeOptional(ID.self, forKey: .`botId`)
        self.`machineId` = try c.decodeOptional(ID.self, forKey: .`machineId`)
        self.`fromAtMs` = try c.decodeOptional(TimestampMs.self, forKey: .`fromAtMs`)
        self.`toAtMs` = try c.decodeOptional(TimestampMs.self, forKey: .`toAtMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(`cursor`, forKey: .`cursor`)
        try c.encodeIfPresent(`limit`, forKey: .`limit`)
        try c.encodeIfPresent(`botId`, forKey: .`botId`)
        try c.encodeIfPresent(`machineId`, forKey: .`machineId`)
        try c.encodeIfPresent(`fromAtMs`, forKey: .`fromAtMs`)
        try c.encodeIfPresent(`toAtMs`, forKey: .`toAtMs`)
    }
}

public struct Reminder: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `botId`: ID
    public var `userId`: ID
    public var `conversationId`: ID
    public var `text`: String
    public var `dueAtMs`: TimestampMs
    public var `timezone`: String
    public var `state`: String
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, botId: ID, userId: ID, conversationId: ID, text: String, dueAtMs: TimestampMs, timezone: String, state: String) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`botId` = botId
        self.`userId` = userId
        self.`conversationId` = conversationId
        self.`text` = text
        self.`dueAtMs` = dueAtMs
        self.`timezone` = timezone
        self.`state` = state
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `botId`, `userId`, `conversationId`, `text`, `dueAtMs`, `timezone`, `state` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`botId` = try c.decode(ID.self, forKey: .`botId`)
        self.`userId` = try c.decode(ID.self, forKey: .`userId`)
        self.`conversationId` = try c.decode(ID.self, forKey: .`conversationId`)
        self.`text` = try c.decode(String.self, forKey: .`text`)
        self.`dueAtMs` = try c.decode(TimestampMs.self, forKey: .`dueAtMs`)
        self.`timezone` = try c.decode(String.self, forKey: .`timezone`)
        self.`state` = try c.decode(String.self, forKey: .`state`)
        guard ["scheduled", "delivered", "cancelled"].contains(`state`) else { throw DecodingError.dataCorruptedError(forKey: .`state`, in: c, debugDescription: "Invalid Reminder.state") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`userId`, forKey: .`userId`)
        try c.encode(`conversationId`, forKey: .`conversationId`)
        try c.encode(`text`, forKey: .`text`)
        try c.encode(`dueAtMs`, forKey: .`dueAtMs`)
        try c.encode(`timezone`, forKey: .`timezone`)
        try c.encode(`state`, forKey: .`state`)
    }
}

public struct ReminderCreate: Codable, Hashable {
    public var `clientNonce`: String
    public var `botId`: ID
    public var `conversationId`: ID
    public var `text`: String
    public var `dueAtMs`: TimestampMs
    public var `timezone`: String
    public init(clientNonce: String, botId: ID, conversationId: ID, text: String, dueAtMs: TimestampMs, timezone: String) {
        self.`clientNonce` = clientNonce
        self.`botId` = botId
        self.`conversationId` = conversationId
        self.`text` = text
        self.`dueAtMs` = dueAtMs
        self.`timezone` = timezone
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `botId`, `conversationId`, `text`, `dueAtMs`, `timezone` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`botId` = try c.decode(ID.self, forKey: .`botId`)
        self.`conversationId` = try c.decode(ID.self, forKey: .`conversationId`)
        self.`text` = try c.decode(String.self, forKey: .`text`)
        self.`dueAtMs` = try c.decode(TimestampMs.self, forKey: .`dueAtMs`)
        self.`timezone` = try c.decode(String.self, forKey: .`timezone`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`conversationId`, forKey: .`conversationId`)
        try c.encode(`text`, forKey: .`text`)
        try c.encode(`dueAtMs`, forKey: .`dueAtMs`)
        try c.encode(`timezone`, forKey: .`timezone`)
    }
}

public struct BotOverview: Codable, Hashable {
    public var `bot`: Bot
    public var `presence`: BotPresence
    public var `machine`: Machine
    public var `grants`: [BotGrant]
    public var `activity`: Page<ActivityItem>
    public var `upcoming`: Page<UpcomingItem>
    public init(bot: Bot, presence: BotPresence, machine: Machine, grants: [BotGrant], activity: Page<ActivityItem>, upcoming: Page<UpcomingItem>) {
        self.`bot` = bot
        self.`presence` = presence
        self.`machine` = machine
        self.`grants` = grants
        self.`activity` = activity
        self.`upcoming` = upcoming
    }
    enum CodingKeys: String, CodingKey { case `bot`, `presence`, `machine`, `grants`, `activity`, `upcoming` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`bot` = try c.decode(Bot.self, forKey: .`bot`)
        self.`presence` = try c.decode(BotPresence.self, forKey: .`presence`)
        self.`machine` = try c.decode(Machine.self, forKey: .`machine`)
        self.`grants` = try c.decode([BotGrant].self, forKey: .`grants`)
        self.`activity` = try c.decode(Page<ActivityItem>.self, forKey: .`activity`)
        self.`upcoming` = try c.decode(Page<UpcomingItem>.self, forKey: .`upcoming`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`bot`, forKey: .`bot`)
        try c.encode(`presence`, forKey: .`presence`)
        try c.encode(`machine`, forKey: .`machine`)
        try c.encode(`grants`, forKey: .`grants`)
        try c.encode(`activity`, forKey: .`activity`)
        try c.encode(`upcoming`, forKey: .`upcoming`)
    }
}

public struct JobPreferencePatch: Codable, Hashable {
    public var `job`: String?
    public var `instructions`: String?
    public var `voice`: VoiceSettings?
    public var `language`: String??
    public init(job: String? = nil, instructions: String? = nil, voice: VoiceSettings? = nil, language: String?? = nil) {
        self.`job` = job
        self.`instructions` = instructions
        self.`voice` = voice
        self.`language` = language
    }
    enum CodingKeys: String, CodingKey { case `job`, `instructions`, `voice`, `language` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`job` = try c.decodeOptional(String.self, forKey: .`job`)
        self.`instructions` = try c.decodeOptional(String.self, forKey: .`instructions`)
        self.`voice` = try c.decodeOptional(VoiceSettings.self, forKey: .`voice`)
        self.`language` = c.contains(.`language`) ? .some(try c.decodeIfPresent(String.self, forKey: .`language`)) : nil
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(`job`, forKey: .`job`)
        try c.encodeIfPresent(`instructions`, forKey: .`instructions`)
        try c.encodeIfPresent(`voice`, forKey: .`voice`)
        if let value = `language` { try c.encode(value, forKey: .`language`) }
    }
}

public struct PreferenceChange: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `botId`: ID
    public var `machineId`: ID
    public var `userId`: ID
    public var `sourceEntryId`: ID?
    public var `scope`: String
    public var `before`: JobPreferencePatch
    public var `after`: JobPreferencePatch
    public var `reason`: String
    public var `resultingBotRevision`: Int
    public var `state`: String
    public var `undoneAtMs`: TimestampMs?
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, botId: ID, machineId: ID, userId: ID, sourceEntryId: ID? = nil, scope: String, before: JobPreferencePatch, after: JobPreferencePatch, reason: String, resultingBotRevision: Int, state: String, undoneAtMs: TimestampMs? = nil) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`botId` = botId
        self.`machineId` = machineId
        self.`userId` = userId
        self.`sourceEntryId` = sourceEntryId
        self.`scope` = scope
        self.`before` = before
        self.`after` = after
        self.`reason` = reason
        self.`resultingBotRevision` = resultingBotRevision
        self.`state` = state
        self.`undoneAtMs` = undoneAtMs
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `botId`, `machineId`, `userId`, `sourceEntryId`, `scope`, `before`, `after`, `reason`, `resultingBotRevision`, `state`, `undoneAtMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`botId` = try c.decode(ID.self, forKey: .`botId`)
        self.`machineId` = try c.decode(ID.self, forKey: .`machineId`)
        self.`userId` = try c.decode(ID.self, forKey: .`userId`)
        self.`sourceEntryId` = try c.decode(ID?.self, forKey: .`sourceEntryId`)
        self.`scope` = try c.decode(String.self, forKey: .`scope`)
        guard ["job", "voice", "language"].contains(`scope`) else { throw DecodingError.dataCorruptedError(forKey: .`scope`, in: c, debugDescription: "Invalid PreferenceChange.scope") }
        self.`before` = try c.decode(JobPreferencePatch.self, forKey: .`before`)
        self.`after` = try c.decode(JobPreferencePatch.self, forKey: .`after`)
        self.`reason` = try c.decode(String.self, forKey: .`reason`)
        self.`resultingBotRevision` = try c.decode(Int.self, forKey: .`resultingBotRevision`)
        self.`state` = try c.decode(String.self, forKey: .`state`)
        guard ["applied", "undone"].contains(`state`) else { throw DecodingError.dataCorruptedError(forKey: .`state`, in: c, debugDescription: "Invalid PreferenceChange.state") }
        self.`undoneAtMs` = try c.decode(TimestampMs?.self, forKey: .`undoneAtMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`machineId`, forKey: .`machineId`)
        try c.encode(`userId`, forKey: .`userId`)
        try c.encode(`sourceEntryId`, forKey: .`sourceEntryId`)
        try c.encode(`scope`, forKey: .`scope`)
        try c.encode(`before`, forKey: .`before`)
        try c.encode(`after`, forKey: .`after`)
        try c.encode(`reason`, forKey: .`reason`)
        try c.encode(`resultingBotRevision`, forKey: .`resultingBotRevision`)
        try c.encode(`state`, forKey: .`state`)
        try c.encode(`undoneAtMs`, forKey: .`undoneAtMs`)
    }
}

public struct PreferenceChangeCreate: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `changes`: JobPreferencePatch
    public var `reason`: String
    public var `sourceEntryId`: ID?
    public init(clientNonce: String, revision: Int, changes: JobPreferencePatch, reason: String, sourceEntryId: ID? = nil) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`changes` = changes
        self.`reason` = reason
        self.`sourceEntryId` = sourceEntryId
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `changes`, `reason`, `sourceEntryId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`changes` = try c.decode(JobPreferencePatch.self, forKey: .`changes`)
        self.`reason` = try c.decode(String.self, forKey: .`reason`)
        self.`sourceEntryId` = try c.decodeOptional(ID.self, forKey: .`sourceEntryId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`changes`, forKey: .`changes`)
        try c.encode(`reason`, forKey: .`reason`)
        try c.encodeIfPresent(`sourceEntryId`, forKey: .`sourceEntryId`)
    }
}

public struct PreferenceUndo: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `botRevision`: Int
    public init(clientNonce: String, revision: Int, botRevision: Int) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`botRevision` = botRevision
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `botRevision` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`botRevision` = try c.decode(Int.self, forKey: .`botRevision`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`botRevision`, forKey: .`botRevision`)
    }
}

public struct BotReset: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `confirmationToken`: String
    public var `confirmName`: String
    public var `resetScopes`: [BotResetScope]
    public init(clientNonce: String, revision: Int, confirmationToken: String, confirmName: String, resetScopes: [BotResetScope]) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`confirmationToken` = confirmationToken
        self.`confirmName` = confirmName
        self.`resetScopes` = resetScopes
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `confirmationToken`, `confirmName`, `resetScopes` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`confirmationToken` = try c.decode(String.self, forKey: .`confirmationToken`)
        self.`confirmName` = try c.decode(String.self, forKey: .`confirmName`)
        self.`resetScopes` = try c.decode([BotResetScope].self, forKey: .`resetScopes`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`confirmationToken`, forKey: .`confirmationToken`)
        try c.encode(`confirmName`, forKey: .`confirmName`)
        try c.encode(`resetScopes`, forKey: .`resetScopes`)
    }
}

public struct BotResetResult: Codable, Hashable {
    public var `bot`: Bot
    public var `removedIds`: [ID]
    public var `retainedScopes`: [BotResetScope]
    public var `status`: String
    public init(bot: Bot, removedIds: [ID], retainedScopes: [BotResetScope], status: String) {
        self.`bot` = bot
        self.`removedIds` = removedIds
        self.`retainedScopes` = retainedScopes
        self.`status` = status
    }
    enum CodingKeys: String, CodingKey { case `bot`, `removedIds`, `retainedScopes`, `status` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`bot` = try c.decode(Bot.self, forKey: .`bot`)
        self.`removedIds` = try c.decode([ID].self, forKey: .`removedIds`)
        self.`retainedScopes` = try c.decode([BotResetScope].self, forKey: .`retainedScopes`)
        self.`status` = try c.decode(String.self, forKey: .`status`)
        guard ["completed", "outcome_unknown"].contains(`status`) else { throw DecodingError.dataCorruptedError(forKey: .`status`, in: c, debugDescription: "Invalid BotResetResult.status") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`bot`, forKey: .`bot`)
        try c.encode(`removedIds`, forKey: .`removedIds`)
        try c.encode(`retainedScopes`, forKey: .`retainedScopes`)
        try c.encode(`status`, forKey: .`status`)
    }
}

public struct MemoryImportPreviewRequest: Codable, Hashable {
    public var `clientNonce`: String
    public var `text`: String?
    public var `attachmentId`: ID?
    public var `format`: String
    public init(clientNonce: String, text: String? = nil, attachmentId: ID? = nil, format: String) {
        self.`clientNonce` = clientNonce
        self.`text` = text
        self.`attachmentId` = attachmentId
        self.`format` = format
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `text`, `attachmentId`, `format` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`text` = try c.decodeOptional(String.self, forKey: .`text`)
        self.`attachmentId` = try c.decodeOptional(ID.self, forKey: .`attachmentId`)
        self.`format` = try c.decode(String.self, forKey: .`format`)
        guard ["facts_text", "lemon_memory_json", "chat_export_zip"].contains(`format`) else { throw DecodingError.dataCorruptedError(forKey: .`format`, in: c, debugDescription: "Invalid MemoryImportPreviewRequest.format") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encodeIfPresent(`text`, forKey: .`text`)
        try c.encodeIfPresent(`attachmentId`, forKey: .`attachmentId`)
        try c.encode(`format`, forKey: .`format`)
    }
}

public struct MemoryImportCandidate: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `text`: String
    public var `kind`: String
    public var `source`: MemoryImportCandidateSource
    public var `selectedByDefault`: Bool
    public init(id: ID, text: String, kind: String, source: MemoryImportCandidateSource, selectedByDefault: Bool) {
        self.`id` = id
        self.`text` = text
        self.`kind` = kind
        self.`source` = source
        self.`selectedByDefault` = selectedByDefault
    }
    enum CodingKeys: String, CodingKey { case `id`, `text`, `kind`, `source`, `selectedByDefault` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`text` = try c.decode(String.self, forKey: .`text`)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        self.`source` = try c.decode(MemoryImportCandidateSource.self, forKey: .`source`)
        self.`selectedByDefault` = try c.decode(Bool.self, forKey: .`selectedByDefault`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`text`, forKey: .`text`)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`source`, forKey: .`source`)
        try c.encode(`selectedByDefault`, forKey: .`selectedByDefault`)
    }
}

public struct MemoryImportPreview: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `botId`: ID
    public var `machineId`: ID
    public var `userId`: ID
    public var `sourceSha256`: String
    public var `candidates`: [MemoryImportCandidate]
    public var `exclusions`: [MemoryImportPreviewExclusions]
    public var `confirmationToken`: String
    public var `expiresAtMs`: TimestampMs
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, botId: ID, machineId: ID, userId: ID, sourceSha256: String, candidates: [MemoryImportCandidate], exclusions: [MemoryImportPreviewExclusions], confirmationToken: String, expiresAtMs: TimestampMs) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`botId` = botId
        self.`machineId` = machineId
        self.`userId` = userId
        self.`sourceSha256` = sourceSha256
        self.`candidates` = candidates
        self.`exclusions` = exclusions
        self.`confirmationToken` = confirmationToken
        self.`expiresAtMs` = expiresAtMs
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `botId`, `machineId`, `userId`, `sourceSha256`, `candidates`, `exclusions`, `confirmationToken`, `expiresAtMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`botId` = try c.decode(ID.self, forKey: .`botId`)
        self.`machineId` = try c.decode(ID.self, forKey: .`machineId`)
        self.`userId` = try c.decode(ID.self, forKey: .`userId`)
        self.`sourceSha256` = try c.decode(String.self, forKey: .`sourceSha256`)
        self.`candidates` = try c.decode([MemoryImportCandidate].self, forKey: .`candidates`)
        self.`exclusions` = try c.decode([MemoryImportPreviewExclusions].self, forKey: .`exclusions`)
        self.`confirmationToken` = try c.decode(String.self, forKey: .`confirmationToken`)
        self.`expiresAtMs` = try c.decode(TimestampMs.self, forKey: .`expiresAtMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`machineId`, forKey: .`machineId`)
        try c.encode(`userId`, forKey: .`userId`)
        try c.encode(`sourceSha256`, forKey: .`sourceSha256`)
        try c.encode(`candidates`, forKey: .`candidates`)
        try c.encode(`exclusions`, forKey: .`exclusions`)
        try c.encode(`confirmationToken`, forKey: .`confirmationToken`)
        try c.encode(`expiresAtMs`, forKey: .`expiresAtMs`)
    }
}

public struct MemoryImportResult: Codable, Hashable {
    public var `previewId`: ID
    public var `items`: [Memory]
    public var `status`: String
    public var `failedCandidateIds`: [ID]
    public init(previewId: ID, items: [Memory], status: String, failedCandidateIds: [ID]) {
        self.`previewId` = previewId
        self.`items` = items
        self.`status` = status
        self.`failedCandidateIds` = failedCandidateIds
    }
    enum CodingKeys: String, CodingKey { case `previewId`, `items`, `status`, `failedCandidateIds` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`previewId` = try c.decode(ID.self, forKey: .`previewId`)
        self.`items` = try c.decode([Memory].self, forKey: .`items`)
        self.`status` = try c.decode(String.self, forKey: .`status`)
        guard ["completed", "outcome_unknown"].contains(`status`) else { throw DecodingError.dataCorruptedError(forKey: .`status`, in: c, debugDescription: "Invalid MemoryImportResult.status") }
        self.`failedCandidateIds` = try c.decode([ID].self, forKey: .`failedCandidateIds`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`previewId`, forKey: .`previewId`)
        try c.encode(`items`, forKey: .`items`)
        try c.encode(`status`, forKey: .`status`)
        try c.encode(`failedCandidateIds`, forKey: .`failedCandidateIds`)
    }
}

public struct BotIdea: Codable, Hashable, Identifiable {
    public var `id`: String
    public var `botId`: ID
    public var `title`: String
    public var `prompt`: String
    public var `expectedOutput`: String
    public var `requiredSkillIds`: [ID]
    public var `requiredConnectorIds`: [ID]
    public var `requiredCapabilityIds`: [String]
    public var `ready`: Bool
    public var `blockedReasons`: [String]
    public init(id: String, botId: ID, title: String, prompt: String, expectedOutput: String, requiredSkillIds: [ID], requiredConnectorIds: [ID], requiredCapabilityIds: [String], ready: Bool, blockedReasons: [String]) {
        self.`id` = id
        self.`botId` = botId
        self.`title` = title
        self.`prompt` = prompt
        self.`expectedOutput` = expectedOutput
        self.`requiredSkillIds` = requiredSkillIds
        self.`requiredConnectorIds` = requiredConnectorIds
        self.`requiredCapabilityIds` = requiredCapabilityIds
        self.`ready` = ready
        self.`blockedReasons` = blockedReasons
    }
    enum CodingKeys: String, CodingKey { case `id`, `botId`, `title`, `prompt`, `expectedOutput`, `requiredSkillIds`, `requiredConnectorIds`, `requiredCapabilityIds`, `ready`, `blockedReasons` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(String.self, forKey: .`id`)
        self.`botId` = try c.decode(ID.self, forKey: .`botId`)
        self.`title` = try c.decode(String.self, forKey: .`title`)
        self.`prompt` = try c.decode(String.self, forKey: .`prompt`)
        self.`expectedOutput` = try c.decode(String.self, forKey: .`expectedOutput`)
        self.`requiredSkillIds` = try c.decode([ID].self, forKey: .`requiredSkillIds`)
        self.`requiredConnectorIds` = try c.decode([ID].self, forKey: .`requiredConnectorIds`)
        self.`requiredCapabilityIds` = try c.decode([String].self, forKey: .`requiredCapabilityIds`)
        self.`ready` = try c.decode(Bool.self, forKey: .`ready`)
        self.`blockedReasons` = try c.decode([String].self, forKey: .`blockedReasons`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`title`, forKey: .`title`)
        try c.encode(`prompt`, forKey: .`prompt`)
        try c.encode(`expectedOutput`, forKey: .`expectedOutput`)
        try c.encode(`requiredSkillIds`, forKey: .`requiredSkillIds`)
        try c.encode(`requiredConnectorIds`, forKey: .`requiredConnectorIds`)
        try c.encode(`requiredCapabilityIds`, forKey: .`requiredCapabilityIds`)
        try c.encode(`ready`, forKey: .`ready`)
        try c.encode(`blockedReasons`, forKey: .`blockedReasons`)
    }
}

public struct DeliverableProvenance: Codable, Hashable {
    public var `botId`: ID?
    public var `runId`: ID?
    public var `machineId`: ID?
    public var `sourceEntryId`: ID?
    public var `generatedAtMs`: TimestampMs?
    public init(botId: ID? = nil, runId: ID? = nil, machineId: ID? = nil, sourceEntryId: ID? = nil, generatedAtMs: TimestampMs? = nil) {
        self.`botId` = botId
        self.`runId` = runId
        self.`machineId` = machineId
        self.`sourceEntryId` = sourceEntryId
        self.`generatedAtMs` = generatedAtMs
    }
    enum CodingKeys: String, CodingKey { case `botId`, `runId`, `machineId`, `sourceEntryId`, `generatedAtMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`botId` = try c.decode(ID?.self, forKey: .`botId`)
        self.`runId` = try c.decode(ID?.self, forKey: .`runId`)
        self.`machineId` = try c.decode(ID?.self, forKey: .`machineId`)
        self.`sourceEntryId` = try c.decode(ID?.self, forKey: .`sourceEntryId`)
        self.`generatedAtMs` = try c.decode(TimestampMs?.self, forKey: .`generatedAtMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`runId`, forKey: .`runId`)
        try c.encode(`machineId`, forKey: .`machineId`)
        try c.encode(`sourceEntryId`, forKey: .`sourceEntryId`)
        try c.encode(`generatedAtMs`, forKey: .`generatedAtMs`)
    }
}

public struct ReviewScope: Codable, Hashable {
    public var `kind`: String
    public var `label`: String
    public var `machineId`: ID
    public var `machineLabel`: String
    public var `botId`: ID
    public var `runId`: ID?
    public var `origin`: String?
    public var `connectorId`: ID?
    public var `consequences`: [String]
    public var `expiresAtMs`: TimestampMs
    public init(kind: String, label: String, machineId: ID, machineLabel: String, botId: ID, runId: ID? = nil, origin: String? = nil, connectorId: ID? = nil, consequences: [String], expiresAtMs: TimestampMs) {
        self.`kind` = kind
        self.`label` = label
        self.`machineId` = machineId
        self.`machineLabel` = machineLabel
        self.`botId` = botId
        self.`runId` = runId
        self.`origin` = origin
        self.`connectorId` = connectorId
        self.`consequences` = consequences
        self.`expiresAtMs` = expiresAtMs
    }
    enum CodingKeys: String, CodingKey { case `kind`, `label`, `machineId`, `machineLabel`, `botId`, `runId`, `origin`, `connectorId`, `consequences`, `expiresAtMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["once", "run", "site", "connector"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid ReviewScope.kind") }
        self.`label` = try c.decode(String.self, forKey: .`label`)
        self.`machineId` = try c.decode(ID.self, forKey: .`machineId`)
        self.`machineLabel` = try c.decode(String.self, forKey: .`machineLabel`)
        self.`botId` = try c.decode(ID.self, forKey: .`botId`)
        self.`runId` = try c.decode(ID?.self, forKey: .`runId`)
        self.`origin` = try c.decode(String?.self, forKey: .`origin`)
        self.`connectorId` = try c.decode(ID?.self, forKey: .`connectorId`)
        self.`consequences` = try c.decode([String].self, forKey: .`consequences`)
        self.`expiresAtMs` = try c.decode(TimestampMs.self, forKey: .`expiresAtMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`label`, forKey: .`label`)
        try c.encode(`machineId`, forKey: .`machineId`)
        try c.encode(`machineLabel`, forKey: .`machineLabel`)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`runId`, forKey: .`runId`)
        try c.encode(`origin`, forKey: .`origin`)
        try c.encode(`connectorId`, forKey: .`connectorId`)
        try c.encode(`consequences`, forKey: .`consequences`)
        try c.encode(`expiresAtMs`, forKey: .`expiresAtMs`)
    }
}

public struct Milestone: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `botId`: ID
    public var `userId`: ID
    public var `kind`: String
    public var `evidenceId`: ID
    public var `earnedAtMs`: TimestampMs
    public var `acknowledgedAtMs`: TimestampMs?
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, botId: ID, userId: ID, kind: String, evidenceId: ID, earnedAtMs: TimestampMs, acknowledgedAtMs: TimestampMs? = nil) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`botId` = botId
        self.`userId` = userId
        self.`kind` = kind
        self.`evidenceId` = evidenceId
        self.`earnedAtMs` = earnedAtMs
        self.`acknowledgedAtMs` = acknowledgedAtMs
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `botId`, `userId`, `kind`, `evidenceId`, `earnedAtMs`, `acknowledgedAtMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`botId` = try c.decode(ID.self, forKey: .`botId`)
        self.`userId` = try c.decode(ID.self, forKey: .`userId`)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["machine_attached", "first_routine_success", "first_approved_task_completed"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid Milestone.kind") }
        self.`evidenceId` = try c.decode(ID.self, forKey: .`evidenceId`)
        self.`earnedAtMs` = try c.decode(TimestampMs.self, forKey: .`earnedAtMs`)
        self.`acknowledgedAtMs` = try c.decode(TimestampMs?.self, forKey: .`acknowledgedAtMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`userId`, forKey: .`userId`)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`evidenceId`, forKey: .`evidenceId`)
        try c.encode(`earnedAtMs`, forKey: .`earnedAtMs`)
        try c.encode(`acknowledgedAtMs`, forKey: .`acknowledgedAtMs`)
    }
}

public struct VoicePreviewRequest: Codable, Hashable {
    public var `clientNonce`: String
    public var `voice`: VoiceSettings?
    public init(clientNonce: String, voice: VoiceSettings? = nil) {
        self.`clientNonce` = clientNonce
        self.`voice` = voice
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `voice` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`voice` = try c.decodeOptional(VoiceSettings.self, forKey: .`voice`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encodeIfPresent(`voice`, forKey: .`voice`)
    }
}

public struct ClientLocalSettings: Codable, Hashable {
    public var `summonShortcut`: String?
    public var `pushToTalkShortcut`: String?
    public var `micCuesEnabled`: Bool
    public var `selectedBotId`: ID?
    public var `compactCompanionEnabled`: Bool
    public var `reducedMotion`: String
    public init(summonShortcut: String? = nil, pushToTalkShortcut: String? = nil, micCuesEnabled: Bool, selectedBotId: ID? = nil, compactCompanionEnabled: Bool, reducedMotion: String) {
        self.`summonShortcut` = summonShortcut
        self.`pushToTalkShortcut` = pushToTalkShortcut
        self.`micCuesEnabled` = micCuesEnabled
        self.`selectedBotId` = selectedBotId
        self.`compactCompanionEnabled` = compactCompanionEnabled
        self.`reducedMotion` = reducedMotion
    }
    enum CodingKeys: String, CodingKey { case `summonShortcut`, `pushToTalkShortcut`, `micCuesEnabled`, `selectedBotId`, `compactCompanionEnabled`, `reducedMotion` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`summonShortcut` = try c.decode(String?.self, forKey: .`summonShortcut`)
        self.`pushToTalkShortcut` = try c.decode(String?.self, forKey: .`pushToTalkShortcut`)
        self.`micCuesEnabled` = try c.decode(Bool.self, forKey: .`micCuesEnabled`)
        self.`selectedBotId` = try c.decode(ID?.self, forKey: .`selectedBotId`)
        self.`compactCompanionEnabled` = try c.decode(Bool.self, forKey: .`compactCompanionEnabled`)
        self.`reducedMotion` = try c.decode(String.self, forKey: .`reducedMotion`)
        guard ["system", "on", "off"].contains(`reducedMotion`) else { throw DecodingError.dataCorruptedError(forKey: .`reducedMotion`, in: c, debugDescription: "Invalid ClientLocalSettings.reducedMotion") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`summonShortcut`, forKey: .`summonShortcut`)
        try c.encode(`pushToTalkShortcut`, forKey: .`pushToTalkShortcut`)
        try c.encode(`micCuesEnabled`, forKey: .`micCuesEnabled`)
        try c.encode(`selectedBotId`, forKey: .`selectedBotId`)
        try c.encode(`compactCompanionEnabled`, forKey: .`compactCompanionEnabled`)
        try c.encode(`reducedMotion`, forKey: .`reducedMotion`)
    }
}

public struct ConnectorSetupRequest: Codable, Hashable {
    public var `clientNonce`: String
    public var `machineId`: ID
    public var `name`: String
    public var `url`: String
    public var `accountLabel`: String
    public var `authKind`: String
    public var `secretBindings`: [ConnectorSetupRequestSecretBindings]
    public var `requestedLevel`: AccessLevel
    public init(clientNonce: String, machineId: ID, name: String, url: String, accountLabel: String, authKind: String, secretBindings: [ConnectorSetupRequestSecretBindings], requestedLevel: AccessLevel) {
        self.`clientNonce` = clientNonce
        self.`machineId` = machineId
        self.`name` = name
        self.`url` = url
        self.`accountLabel` = accountLabel
        self.`authKind` = authKind
        self.`secretBindings` = secretBindings
        self.`requestedLevel` = requestedLevel
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `machineId`, `name`, `url`, `accountLabel`, `authKind`, `secretBindings`, `requestedLevel` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`machineId` = try c.decode(ID.self, forKey: .`machineId`)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`url` = try c.decode(String.self, forKey: .`url`)
        self.`accountLabel` = try c.decode(String.self, forKey: .`accountLabel`)
        self.`authKind` = try c.decode(String.self, forKey: .`authKind`)
        self.`secretBindings` = try c.decode([ConnectorSetupRequestSecretBindings].self, forKey: .`secretBindings`)
        self.`requestedLevel` = try c.decode(AccessLevel.self, forKey: .`requestedLevel`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`machineId`, forKey: .`machineId`)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`url`, forKey: .`url`)
        try c.encode(`accountLabel`, forKey: .`accountLabel`)
        try c.encode(`authKind`, forKey: .`authKind`)
        try c.encode(`secretBindings`, forKey: .`secretBindings`)
        try c.encode(`requestedLevel`, forKey: .`requestedLevel`)
    }
}

public struct ConnectorSetupResult: Codable, Hashable {
    public var `connector`: Connector
    public var `machineId`: ID
    public var `secretNames`: [String]
    public var `grants`: [BotGrant]
    public init(connector: Connector, machineId: ID, secretNames: [String], grants: [BotGrant]) {
        self.`connector` = connector
        self.`machineId` = machineId
        self.`secretNames` = secretNames
        self.`grants` = grants
    }
    enum CodingKeys: String, CodingKey { case `connector`, `machineId`, `secretNames`, `grants` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`connector` = try c.decode(Connector.self, forKey: .`connector`)
        self.`machineId` = try c.decode(ID.self, forKey: .`machineId`)
        self.`secretNames` = try c.decode([String].self, forKey: .`secretNames`)
        self.`grants` = try c.decode([BotGrant].self, forKey: .`grants`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`connector`, forKey: .`connector`)
        try c.encode(`machineId`, forKey: .`machineId`)
        try c.encode(`secretNames`, forKey: .`secretNames`)
        try c.encode(`grants`, forKey: .`grants`)
    }
}

public struct Snapshot: Codable, Hashable {
    public var `cursor`: Cursor
    public var `user`: User
    public var `workspace`: Workspace
    public var `member`: Member
    public var `capabilities`: Capabilities
    public var `bots`: [Bot]
    public var `machines`: [Machine]
    public var `conversations`: [Conversation]
    public var `sections`: [Section]
    public var `notifications`: [BotNotification]
    public var `activeRuns`: [Run]
    public var `hasMore`: SnapshotHasMore
    public init(cursor: Cursor, user: User, workspace: Workspace, member: Member, capabilities: Capabilities, bots: [Bot], machines: [Machine], conversations: [Conversation], sections: [Section], notifications: [BotNotification], activeRuns: [Run], hasMore: SnapshotHasMore) {
        self.`cursor` = cursor
        self.`user` = user
        self.`workspace` = workspace
        self.`member` = member
        self.`capabilities` = capabilities
        self.`bots` = bots
        self.`machines` = machines
        self.`conversations` = conversations
        self.`sections` = sections
        self.`notifications` = notifications
        self.`activeRuns` = activeRuns
        self.`hasMore` = hasMore
    }
    enum CodingKeys: String, CodingKey { case `cursor`, `user`, `workspace`, `member`, `capabilities`, `bots`, `machines`, `conversations`, `sections`, `notifications`, `activeRuns`, `hasMore` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`cursor` = try c.decode(Cursor.self, forKey: .`cursor`)
        self.`user` = try c.decode(User.self, forKey: .`user`)
        self.`workspace` = try c.decode(Workspace.self, forKey: .`workspace`)
        self.`member` = try c.decode(Member.self, forKey: .`member`)
        self.`capabilities` = try c.decode(Capabilities.self, forKey: .`capabilities`)
        self.`bots` = try c.decode([Bot].self, forKey: .`bots`)
        self.`machines` = try c.decode([Machine].self, forKey: .`machines`)
        self.`conversations` = try c.decode([Conversation].self, forKey: .`conversations`)
        self.`sections` = try c.decode([Section].self, forKey: .`sections`)
        self.`notifications` = try c.decode([BotNotification].self, forKey: .`notifications`)
        self.`activeRuns` = try c.decode([Run].self, forKey: .`activeRuns`)
        self.`hasMore` = try c.decode(SnapshotHasMore.self, forKey: .`hasMore`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`cursor`, forKey: .`cursor`)
        try c.encode(`user`, forKey: .`user`)
        try c.encode(`workspace`, forKey: .`workspace`)
        try c.encode(`member`, forKey: .`member`)
        try c.encode(`capabilities`, forKey: .`capabilities`)
        try c.encode(`bots`, forKey: .`bots`)
        try c.encode(`machines`, forKey: .`machines`)
        try c.encode(`conversations`, forKey: .`conversations`)
        try c.encode(`sections`, forKey: .`sections`)
        try c.encode(`notifications`, forKey: .`notifications`)
        try c.encode(`activeRuns`, forKey: .`activeRuns`)
        try c.encode(`hasMore`, forKey: .`hasMore`)
    }
}

public struct PushPayload: Codable, Hashable {
    public var `version`: Int
    public var `notificationId`: ID
    public var `workspaceId`: ID
    public var `conversationId`: ID?
    public var `entryId`: ID?
    public var `title`: String
    public var `body`: String
    public var `target`: NotificationTarget
    public var `deepLink`: String
    public init(version: Int, notificationId: ID, workspaceId: ID, conversationId: ID? = nil, entryId: ID? = nil, title: String, body: String, target: NotificationTarget, deepLink: String) {
        self.`version` = version
        self.`notificationId` = notificationId
        self.`workspaceId` = workspaceId
        self.`conversationId` = conversationId
        self.`entryId` = entryId
        self.`title` = title
        self.`body` = body
        self.`target` = target
        self.`deepLink` = deepLink
    }
    enum CodingKeys: String, CodingKey { case `version`, `notificationId`, `workspaceId`, `conversationId`, `entryId`, `title`, `body`, `target`, `deepLink` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`version` = try c.decode(Int.self, forKey: .`version`)
        guard `version` == 1 else { throw DecodingError.dataCorruptedError(forKey: .`version`, in: c, debugDescription: "Invalid literal PushPayload.version") }
        self.`notificationId` = try c.decode(ID.self, forKey: .`notificationId`)
        self.`workspaceId` = try c.decode(ID.self, forKey: .`workspaceId`)
        self.`conversationId` = try c.decode(ID?.self, forKey: .`conversationId`)
        self.`entryId` = try c.decode(ID?.self, forKey: .`entryId`)
        self.`title` = try c.decode(String.self, forKey: .`title`)
        self.`body` = try c.decode(String.self, forKey: .`body`)
        self.`target` = try c.decode(NotificationTarget.self, forKey: .`target`)
        self.`deepLink` = try c.decode(String.self, forKey: .`deepLink`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`version`, forKey: .`version`)
        try c.encode(`notificationId`, forKey: .`notificationId`)
        try c.encode(`workspaceId`, forKey: .`workspaceId`)
        try c.encode(`conversationId`, forKey: .`conversationId`)
        try c.encode(`entryId`, forKey: .`entryId`)
        try c.encode(`title`, forKey: .`title`)
        try c.encode(`body`, forKey: .`body`)
        try c.encode(`target`, forKey: .`target`)
        try c.encode(`deepLink`, forKey: .`deepLink`)
    }
}

public struct ToolContextInput: Codable, Hashable {
    public var `clientNonce`: String
    public var `conversationId`: ID?
    public init(clientNonce: String, conversationId: ID? = nil) {
        self.`clientNonce` = clientNonce
        self.`conversationId` = conversationId
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `conversationId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`conversationId` = try c.decodeOptional(ID.self, forKey: .`conversationId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encodeIfPresent(`conversationId`, forKey: .`conversationId`)
    }
}

public struct MessageBotInput: Codable, Hashable {
    public var `clientNonce`: String
    public var `conversationId`: ID?
    public var `targetBotId`: ID
    public var `text`: String
    public var `attachmentIds`: [ID]?
    public var `replyConversationId`: ID?
    public init(clientNonce: String, conversationId: ID? = nil, targetBotId: ID, text: String, attachmentIds: [ID]? = nil, replyConversationId: ID? = nil) {
        self.`clientNonce` = clientNonce
        self.`conversationId` = conversationId
        self.`targetBotId` = targetBotId
        self.`text` = text
        self.`attachmentIds` = attachmentIds
        self.`replyConversationId` = replyConversationId
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `conversationId`, `targetBotId`, `text`, `attachmentIds`, `replyConversationId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`conversationId` = try c.decodeOptional(ID.self, forKey: .`conversationId`)
        self.`targetBotId` = try c.decode(ID.self, forKey: .`targetBotId`)
        self.`text` = try c.decode(String.self, forKey: .`text`)
        self.`attachmentIds` = try c.decodeOptional([ID].self, forKey: .`attachmentIds`)
        self.`replyConversationId` = try c.decodeOptional(ID.self, forKey: .`replyConversationId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encodeIfPresent(`conversationId`, forKey: .`conversationId`)
        try c.encode(`targetBotId`, forKey: .`targetBotId`)
        try c.encode(`text`, forKey: .`text`)
        try c.encodeIfPresent(`attachmentIds`, forKey: .`attachmentIds`)
        try c.encodeIfPresent(`replyConversationId`, forKey: .`replyConversationId`)
    }
}

public struct HandoffInput: Codable, Hashable {
    public var `clientNonce`: String
    public var `conversationId`: ID?
    public var `targetBotId`: ID
    public var `text`: String
    public var `attachmentIds`: [ID]?
    public var `replyConversationId`: ID?
    public var `task`: String
    public init(clientNonce: String, conversationId: ID? = nil, targetBotId: ID, text: String, attachmentIds: [ID]? = nil, replyConversationId: ID? = nil, task: String) {
        self.`clientNonce` = clientNonce
        self.`conversationId` = conversationId
        self.`targetBotId` = targetBotId
        self.`text` = text
        self.`attachmentIds` = attachmentIds
        self.`replyConversationId` = replyConversationId
        self.`task` = task
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `conversationId`, `targetBotId`, `text`, `attachmentIds`, `replyConversationId`, `task` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`conversationId` = try c.decodeOptional(ID.self, forKey: .`conversationId`)
        self.`targetBotId` = try c.decode(ID.self, forKey: .`targetBotId`)
        self.`text` = try c.decode(String.self, forKey: .`text`)
        self.`attachmentIds` = try c.decodeOptional([ID].self, forKey: .`attachmentIds`)
        self.`replyConversationId` = try c.decodeOptional(ID.self, forKey: .`replyConversationId`)
        self.`task` = try c.decode(String.self, forKey: .`task`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encodeIfPresent(`conversationId`, forKey: .`conversationId`)
        try c.encode(`targetBotId`, forKey: .`targetBotId`)
        try c.encode(`text`, forKey: .`text`)
        try c.encodeIfPresent(`attachmentIds`, forKey: .`attachmentIds`)
        try c.encodeIfPresent(`replyConversationId`, forKey: .`replyConversationId`)
        try c.encode(`task`, forKey: .`task`)
    }
}

public struct DraftToolInput: Codable, Hashable {
    public var `clientNonce`: String
    public var `conversationId`: ID?
    public var `content`: DraftContent
    public init(clientNonce: String, conversationId: ID? = nil, content: DraftContent) {
        self.`clientNonce` = clientNonce
        self.`conversationId` = conversationId
        self.`content` = content
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `conversationId`, `content` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`conversationId` = try c.decodeOptional(ID.self, forKey: .`conversationId`)
        self.`content` = try c.decode(DraftContent.self, forKey: .`content`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encodeIfPresent(`conversationId`, forKey: .`conversationId`)
        try c.encode(`content`, forKey: .`content`)
    }
}

public struct AskUserInput: Codable, Hashable {
    public var `clientNonce`: String
    public var `conversationId`: ID?
    public var `title`: String
    public var `fields`: [Field]
    public var `expiresInMs`: Int?
    public init(clientNonce: String, conversationId: ID? = nil, title: String, fields: [Field], expiresInMs: Int? = nil) {
        self.`clientNonce` = clientNonce
        self.`conversationId` = conversationId
        self.`title` = title
        self.`fields` = fields
        self.`expiresInMs` = expiresInMs
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `conversationId`, `title`, `fields`, `expiresInMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`conversationId` = try c.decodeOptional(ID.self, forKey: .`conversationId`)
        self.`title` = try c.decode(String.self, forKey: .`title`)
        self.`fields` = try c.decode([Field].self, forKey: .`fields`)
        self.`expiresInMs` = try c.decodeOptional(Int.self, forKey: .`expiresInMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encodeIfPresent(`conversationId`, forKey: .`conversationId`)
        try c.encode(`title`, forKey: .`title`)
        try c.encode(`fields`, forKey: .`fields`)
        try c.encodeIfPresent(`expiresInMs`, forKey: .`expiresInMs`)
    }
}

public struct ApprovalToolInput: Codable, Hashable {
    public var `clientNonce`: String
    public var `conversationId`: ID?
    public var `category`: ActionCategory
    public var `title`: String
    public var `description`: String
    public var `target`: String
    public var `inputs`: JSONObject
    public var `expiresInMs`: Int?
    public init(clientNonce: String, conversationId: ID? = nil, category: ActionCategory, title: String, description: String, target: String, inputs: JSONObject, expiresInMs: Int? = nil) {
        self.`clientNonce` = clientNonce
        self.`conversationId` = conversationId
        self.`category` = category
        self.`title` = title
        self.`description` = description
        self.`target` = target
        self.`inputs` = inputs
        self.`expiresInMs` = expiresInMs
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `conversationId`, `category`, `title`, `description`, `target`, `inputs`, `expiresInMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`conversationId` = try c.decodeOptional(ID.self, forKey: .`conversationId`)
        self.`category` = try c.decode(ActionCategory.self, forKey: .`category`)
        self.`title` = try c.decode(String.self, forKey: .`title`)
        self.`description` = try c.decode(String.self, forKey: .`description`)
        self.`target` = try c.decode(String.self, forKey: .`target`)
        self.`inputs` = try c.decode(JSONObject.self, forKey: .`inputs`)
        self.`expiresInMs` = try c.decodeOptional(Int.self, forKey: .`expiresInMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encodeIfPresent(`conversationId`, forKey: .`conversationId`)
        try c.encode(`category`, forKey: .`category`)
        try c.encode(`title`, forKey: .`title`)
        try c.encode(`description`, forKey: .`description`)
        try c.encode(`target`, forKey: .`target`)
        try c.encode(`inputs`, forKey: .`inputs`)
        try c.encodeIfPresent(`expiresInMs`, forKey: .`expiresInMs`)
    }
}

public struct HumanStepInput: Codable, Hashable {
    public var `clientNonce`: String
    public var `conversationId`: ID?
    public var `title`: String
    public var `instructions`: String
    public var `reason`: String
    public var `externalUrl`: String?
    public var `expiresInMs`: Int?
    public init(clientNonce: String, conversationId: ID? = nil, title: String, instructions: String, reason: String, externalUrl: String? = nil, expiresInMs: Int? = nil) {
        self.`clientNonce` = clientNonce
        self.`conversationId` = conversationId
        self.`title` = title
        self.`instructions` = instructions
        self.`reason` = reason
        self.`externalUrl` = externalUrl
        self.`expiresInMs` = expiresInMs
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `conversationId`, `title`, `instructions`, `reason`, `externalUrl`, `expiresInMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`conversationId` = try c.decodeOptional(ID.self, forKey: .`conversationId`)
        self.`title` = try c.decode(String.self, forKey: .`title`)
        self.`instructions` = try c.decode(String.self, forKey: .`instructions`)
        self.`reason` = try c.decode(String.self, forKey: .`reason`)
        self.`externalUrl` = try c.decodeOptional(String.self, forKey: .`externalUrl`)
        self.`expiresInMs` = try c.decodeOptional(Int.self, forKey: .`expiresInMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encodeIfPresent(`conversationId`, forKey: .`conversationId`)
        try c.encode(`title`, forKey: .`title`)
        try c.encode(`instructions`, forKey: .`instructions`)
        try c.encode(`reason`, forKey: .`reason`)
        try c.encodeIfPresent(`externalUrl`, forKey: .`externalUrl`)
        try c.encodeIfPresent(`expiresInMs`, forKey: .`expiresInMs`)
    }
}

public struct SecretToolInput: Codable, Hashable {
    public var `clientNonce`: String
    public var `conversationId`: ID?
    public var `name`: String
    public var `description`: String
    public var `scope`: String
    public var `expiresInMs`: Int?
    public init(clientNonce: String, conversationId: ID? = nil, name: String, description: String, scope: String, expiresInMs: Int? = nil) {
        self.`clientNonce` = clientNonce
        self.`conversationId` = conversationId
        self.`name` = name
        self.`description` = description
        self.`scope` = scope
        self.`expiresInMs` = expiresInMs
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `conversationId`, `name`, `description`, `scope`, `expiresInMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`conversationId` = try c.decodeOptional(ID.self, forKey: .`conversationId`)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`description` = try c.decode(String.self, forKey: .`description`)
        self.`scope` = try c.decode(String.self, forKey: .`scope`)
        self.`expiresInMs` = try c.decodeOptional(Int.self, forKey: .`expiresInMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encodeIfPresent(`conversationId`, forKey: .`conversationId`)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`description`, forKey: .`description`)
        try c.encode(`scope`, forKey: .`scope`)
        try c.encodeIfPresent(`expiresInMs`, forKey: .`expiresInMs`)
    }
}

public struct VoiceMemoInput: Codable, Hashable {
    public var `clientNonce`: String
    public var `conversationId`: ID?
    public var `text`: String
    public var `voice`: VoiceSettings?
    public init(clientNonce: String, conversationId: ID? = nil, text: String, voice: VoiceSettings? = nil) {
        self.`clientNonce` = clientNonce
        self.`conversationId` = conversationId
        self.`text` = text
        self.`voice` = voice
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `conversationId`, `text`, `voice` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`conversationId` = try c.decodeOptional(ID.self, forKey: .`conversationId`)
        self.`text` = try c.decode(String.self, forKey: .`text`)
        self.`voice` = try c.decodeOptional(VoiceSettings.self, forKey: .`voice`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encodeIfPresent(`conversationId`, forKey: .`conversationId`)
        try c.encode(`text`, forKey: .`text`)
        try c.encodeIfPresent(`voice`, forKey: .`voice`)
    }
}

public struct ShareFileInput: Codable, Hashable {
    public var `clientNonce`: String
    public var `conversationId`: ID?
    public var `path`: String
    public var `filename`: String?
    public var `caption`: String?
    public init(clientNonce: String, conversationId: ID? = nil, path: String, filename: String? = nil, caption: String? = nil) {
        self.`clientNonce` = clientNonce
        self.`conversationId` = conversationId
        self.`path` = path
        self.`filename` = filename
        self.`caption` = caption
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `conversationId`, `path`, `filename`, `caption` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`conversationId` = try c.decodeOptional(ID.self, forKey: .`conversationId`)
        self.`path` = try c.decode(String.self, forKey: .`path`)
        self.`filename` = try c.decodeOptional(String.self, forKey: .`filename`)
        self.`caption` = try c.decodeOptional(String.self, forKey: .`caption`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encodeIfPresent(`conversationId`, forKey: .`conversationId`)
        try c.encode(`path`, forKey: .`path`)
        try c.encodeIfPresent(`filename`, forKey: .`filename`)
        try c.encodeIfPresent(`caption`, forKey: .`caption`)
    }
}

public struct PostGroupInput: Codable, Hashable {
    public var `clientNonce`: String
    public var `groupConversationId`: ID
    public var `text`: String
    public var `attachmentIds`: [ID]?
    public var `mentions`: [ID]?
    public init(clientNonce: String, groupConversationId: ID, text: String, attachmentIds: [ID]? = nil, mentions: [ID]? = nil) {
        self.`clientNonce` = clientNonce
        self.`groupConversationId` = groupConversationId
        self.`text` = text
        self.`attachmentIds` = attachmentIds
        self.`mentions` = mentions
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `groupConversationId`, `text`, `attachmentIds`, `mentions` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`groupConversationId` = try c.decode(ID.self, forKey: .`groupConversationId`)
        self.`text` = try c.decode(String.self, forKey: .`text`)
        self.`attachmentIds` = try c.decodeOptional([ID].self, forKey: .`attachmentIds`)
        self.`mentions` = try c.decodeOptional([ID].self, forKey: .`mentions`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`groupConversationId`, forKey: .`groupConversationId`)
        try c.encode(`text`, forKey: .`text`)
        try c.encodeIfPresent(`attachmentIds`, forKey: .`attachmentIds`)
        try c.encodeIfPresent(`mentions`, forKey: .`mentions`)
    }
}

public struct BotListInput: Codable, Hashable {
    public var `query`: String?
    public var `limit`: Int?
    public var `cursor`: Cursor?
    public init(query: String? = nil, limit: Int? = nil, cursor: Cursor? = nil) {
        self.`query` = query
        self.`limit` = limit
        self.`cursor` = cursor
    }
    enum CodingKeys: String, CodingKey { case `query`, `limit`, `cursor` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`query` = try c.decodeOptional(String.self, forKey: .`query`)
        self.`limit` = try c.decodeOptional(Int.self, forKey: .`limit`)
        self.`cursor` = try c.decodeOptional(Cursor.self, forKey: .`cursor`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(`query`, forKey: .`query`)
        try c.encodeIfPresent(`limit`, forKey: .`limit`)
        try c.encodeIfPresent(`cursor`, forKey: .`cursor`)
    }
}

public struct RememberInput: Codable, Hashable {
    public var `clientNonce`: String
    public var `conversationId`: ID?
    public var `text`: String
    public var `kind`: String
    public init(clientNonce: String, conversationId: ID? = nil, text: String, kind: String) {
        self.`clientNonce` = clientNonce
        self.`conversationId` = conversationId
        self.`text` = text
        self.`kind` = kind
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `conversationId`, `text`, `kind` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`conversationId` = try c.decodeOptional(ID.self, forKey: .`conversationId`)
        self.`text` = try c.decode(String.self, forKey: .`text`)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encodeIfPresent(`conversationId`, forKey: .`conversationId`)
        try c.encode(`text`, forKey: .`text`)
        try c.encode(`kind`, forKey: .`kind`)
    }
}

public struct PreferenceToolInput: Codable, Hashable {
    public var `clientNonce`: String
    public var `conversationId`: ID?
    public var `revision`: Int
    public var `changes`: JobPreferencePatch
    public var `reason`: String
    public var `sourceEntryId`: ID
    public init(clientNonce: String, conversationId: ID? = nil, revision: Int, changes: JobPreferencePatch, reason: String, sourceEntryId: ID) {
        self.`clientNonce` = clientNonce
        self.`conversationId` = conversationId
        self.`revision` = revision
        self.`changes` = changes
        self.`reason` = reason
        self.`sourceEntryId` = sourceEntryId
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `conversationId`, `revision`, `changes`, `reason`, `sourceEntryId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`conversationId` = try c.decodeOptional(ID.self, forKey: .`conversationId`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`changes` = try c.decode(JobPreferencePatch.self, forKey: .`changes`)
        self.`reason` = try c.decode(String.self, forKey: .`reason`)
        self.`sourceEntryId` = try c.decode(ID.self, forKey: .`sourceEntryId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encodeIfPresent(`conversationId`, forKey: .`conversationId`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`changes`, forKey: .`changes`)
        try c.encode(`reason`, forKey: .`reason`)
        try c.encode(`sourceEntryId`, forKey: .`sourceEntryId`)
    }
}

public struct ReminderToolInput: Codable, Hashable {
    public var `clientNonce`: String
    public var `conversationId`: ID?
    public var `text`: String
    public var `dueAtMs`: TimestampMs
    public var `timezone`: String
    public init(clientNonce: String, conversationId: ID? = nil, text: String, dueAtMs: TimestampMs, timezone: String) {
        self.`clientNonce` = clientNonce
        self.`conversationId` = conversationId
        self.`text` = text
        self.`dueAtMs` = dueAtMs
        self.`timezone` = timezone
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `conversationId`, `text`, `dueAtMs`, `timezone` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`conversationId` = try c.decodeOptional(ID.self, forKey: .`conversationId`)
        self.`text` = try c.decode(String.self, forKey: .`text`)
        self.`dueAtMs` = try c.decode(TimestampMs.self, forKey: .`dueAtMs`)
        self.`timezone` = try c.decode(String.self, forKey: .`timezone`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encodeIfPresent(`conversationId`, forKey: .`conversationId`)
        try c.encode(`text`, forKey: .`text`)
        try c.encode(`dueAtMs`, forKey: .`dueAtMs`)
        try c.encode(`timezone`, forKey: .`timezone`)
    }
}

public struct ToolEntryResult: Codable, Hashable {
    public var `entry`: TranscriptEntry
    public init(entry: TranscriptEntry) {
        self.`entry` = entry
    }
    enum CodingKeys: String, CodingKey { case `entry` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`entry` = try c.decode(TranscriptEntry.self, forKey: .`entry`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`entry`, forKey: .`entry`)
    }
}

public struct MessageBotResult: Codable, Hashable {
    public var `receipt`: MessageReceipt
    public var `conversationId`: ID
    public init(receipt: MessageReceipt, conversationId: ID) {
        self.`receipt` = receipt
        self.`conversationId` = conversationId
    }
    enum CodingKeys: String, CodingKey { case `receipt`, `conversationId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`receipt` = try c.decode(MessageReceipt.self, forKey: .`receipt`)
        self.`conversationId` = try c.decode(ID.self, forKey: .`conversationId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`receipt`, forKey: .`receipt`)
        try c.encode(`conversationId`, forKey: .`conversationId`)
    }
}

public struct QuestionToolResult: Codable, Hashable {
    public var `question`: Question
    public var `state`: ResolutionState
    public var `answers`: [String: JSONValue]?
    public init(question: Question, state: ResolutionState, answers: [String: JSONValue]? = nil) {
        self.`question` = question
        self.`state` = state
        self.`answers` = answers
    }
    enum CodingKeys: String, CodingKey { case `question`, `state`, `answers` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`question` = try c.decode(Question.self, forKey: .`question`)
        self.`state` = try c.decode(ResolutionState.self, forKey: .`state`)
        self.`answers` = try c.decode([String: JSONValue]?.self, forKey: .`answers`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`question`, forKey: .`question`)
        try c.encode(`state`, forKey: .`state`)
        try c.encode(`answers`, forKey: .`answers`)
    }
}

public struct ApprovalToolResult: Codable, Hashable {
    public var `approval`: Approval
    public var `decision`: String
    public init(approval: Approval, decision: String) {
        self.`approval` = approval
        self.`decision` = decision
    }
    enum CodingKeys: String, CodingKey { case `approval`, `decision` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`approval` = try c.decode(Approval.self, forKey: .`approval`)
        self.`decision` = try c.decode(String.self, forKey: .`decision`)
        guard ["approved", "denied", "expired", "cancelled"].contains(`decision`) else { throw DecodingError.dataCorruptedError(forKey: .`decision`, in: c, debugDescription: "Invalid ApprovalToolResult.decision") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`approval`, forKey: .`approval`)
        try c.encode(`decision`, forKey: .`decision`)
    }
}

public struct HumanStepToolResult: Codable, Hashable {
    public var `step`: HumanStep
    public var `decision`: String
    public init(step: HumanStep, decision: String) {
        self.`step` = step
        self.`decision` = decision
    }
    enum CodingKeys: String, CodingKey { case `step`, `decision` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`step` = try c.decode(HumanStep.self, forKey: .`step`)
        self.`decision` = try c.decode(String.self, forKey: .`decision`)
        guard ["done", "skipped", "expired", "cancelled"].contains(`decision`) else { throw DecodingError.dataCorruptedError(forKey: .`decision`, in: c, debugDescription: "Invalid HumanStepToolResult.decision") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`step`, forKey: .`step`)
        try c.encode(`decision`, forKey: .`decision`)
    }
}

public struct SecretToolResult: Codable, Hashable {
    public var `request`: SecretRequest
    public var `saved`: Bool
    public var `name`: String
    public init(request: SecretRequest, saved: Bool, name: String) {
        self.`request` = request
        self.`saved` = saved
        self.`name` = name
    }
    enum CodingKeys: String, CodingKey { case `request`, `saved`, `name` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`request` = try c.decode(SecretRequest.self, forKey: .`request`)
        self.`saved` = try c.decode(Bool.self, forKey: .`saved`)
        self.`name` = try c.decode(String.self, forKey: .`name`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`request`, forKey: .`request`)
        try c.encode(`saved`, forKey: .`saved`)
        try c.encode(`name`, forKey: .`name`)
    }
}

public struct MCPCallResult<T: Codable & Hashable>: Codable, Hashable {
    public var `content`: [MCPCallResultContent]
    public var `structuredContent`: T
    public var `isError`: Bool?
    public init(content: [MCPCallResultContent], structuredContent: T, isError: Bool? = nil) {
        self.`content` = content
        self.`structuredContent` = structuredContent
        self.`isError` = isError
    }
    enum CodingKeys: String, CodingKey { case `content`, `structuredContent`, `isError` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`content` = try c.decode([MCPCallResultContent].self, forKey: .`content`)
        self.`structuredContent` = try c.decode(T.self, forKey: .`structuredContent`)
        self.`isError` = try c.decodeOptional(Bool.self, forKey: .`isError`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`content`, forKey: .`content`)
        try c.encode(`structuredContent`, forKey: .`structuredContent`)
        try c.encodeIfPresent(`isError`, forKey: .`isError`)
    }
}

public struct OIDCProvider: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `name`: String
    public var `issuer`: String
    public var `clientId`: String
    public var `scopes`: [String]
    public var `allowedEmailDomains`: [String]
    public var `enabled`: Bool
    public var `requireSSO`: Bool
    public var `groupClaim`: String?
    public var `clientSecretRef`: String
    public var `endSessionEndpoint`: String?
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, name: String, issuer: String, clientId: String, scopes: [String], allowedEmailDomains: [String], enabled: Bool, requireSSO: Bool, groupClaim: String? = nil, clientSecretRef: String, endSessionEndpoint: String? = nil) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`name` = name
        self.`issuer` = issuer
        self.`clientId` = clientId
        self.`scopes` = scopes
        self.`allowedEmailDomains` = allowedEmailDomains
        self.`enabled` = enabled
        self.`requireSSO` = requireSSO
        self.`groupClaim` = groupClaim
        self.`clientSecretRef` = clientSecretRef
        self.`endSessionEndpoint` = endSessionEndpoint
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `name`, `issuer`, `clientId`, `scopes`, `allowedEmailDomains`, `enabled`, `requireSSO`, `groupClaim`, `clientSecretRef`, `endSessionEndpoint` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`issuer` = try c.decode(String.self, forKey: .`issuer`)
        self.`clientId` = try c.decode(String.self, forKey: .`clientId`)
        self.`scopes` = try c.decode([String].self, forKey: .`scopes`)
        self.`allowedEmailDomains` = try c.decode([String].self, forKey: .`allowedEmailDomains`)
        self.`enabled` = try c.decode(Bool.self, forKey: .`enabled`)
        self.`requireSSO` = try c.decode(Bool.self, forKey: .`requireSSO`)
        self.`groupClaim` = try c.decode(String?.self, forKey: .`groupClaim`)
        self.`clientSecretRef` = try c.decode(String.self, forKey: .`clientSecretRef`)
        self.`endSessionEndpoint` = try c.decode(String?.self, forKey: .`endSessionEndpoint`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`issuer`, forKey: .`issuer`)
        try c.encode(`clientId`, forKey: .`clientId`)
        try c.encode(`scopes`, forKey: .`scopes`)
        try c.encode(`allowedEmailDomains`, forKey: .`allowedEmailDomains`)
        try c.encode(`enabled`, forKey: .`enabled`)
        try c.encode(`requireSSO`, forKey: .`requireSSO`)
        try c.encode(`groupClaim`, forKey: .`groupClaim`)
        try c.encode(`clientSecretRef`, forKey: .`clientSecretRef`)
        try c.encode(`endSessionEndpoint`, forKey: .`endSessionEndpoint`)
    }
}

public struct OIDCProviderCreate: Codable, Hashable {
    public var `clientNonce`: String
    public var `name`: String
    public var `issuer`: String
    public var `clientId`: String
    public var `scopes`: [String]
    public var `allowedEmailDomains`: [String]
    public var `clientSecretRef`: String
    public var `groupClaim`: String?
    public var `requireSSO`: Bool
    public init(clientNonce: String, name: String, issuer: String, clientId: String, scopes: [String], allowedEmailDomains: [String], clientSecretRef: String, groupClaim: String? = nil, requireSSO: Bool) {
        self.`clientNonce` = clientNonce
        self.`name` = name
        self.`issuer` = issuer
        self.`clientId` = clientId
        self.`scopes` = scopes
        self.`allowedEmailDomains` = allowedEmailDomains
        self.`clientSecretRef` = clientSecretRef
        self.`groupClaim` = groupClaim
        self.`requireSSO` = requireSSO
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `name`, `issuer`, `clientId`, `scopes`, `allowedEmailDomains`, `clientSecretRef`, `groupClaim`, `requireSSO` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`issuer` = try c.decode(String.self, forKey: .`issuer`)
        self.`clientId` = try c.decode(String.self, forKey: .`clientId`)
        self.`scopes` = try c.decode([String].self, forKey: .`scopes`)
        self.`allowedEmailDomains` = try c.decode([String].self, forKey: .`allowedEmailDomains`)
        self.`clientSecretRef` = try c.decode(String.self, forKey: .`clientSecretRef`)
        self.`groupClaim` = try c.decodeOptional(String.self, forKey: .`groupClaim`)
        self.`requireSSO` = try c.decode(Bool.self, forKey: .`requireSSO`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`issuer`, forKey: .`issuer`)
        try c.encode(`clientId`, forKey: .`clientId`)
        try c.encode(`scopes`, forKey: .`scopes`)
        try c.encode(`allowedEmailDomains`, forKey: .`allowedEmailDomains`)
        try c.encode(`clientSecretRef`, forKey: .`clientSecretRef`)
        try c.encodeIfPresent(`groupClaim`, forKey: .`groupClaim`)
        try c.encode(`requireSSO`, forKey: .`requireSSO`)
    }
}

public struct OIDCProviderUpdate: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `enabled`: Bool?
    public var `requireSSO`: Bool?
    public var `allowedEmailDomains`: [String]?
    public var `scopes`: [String]?
    public init(clientNonce: String, revision: Int, enabled: Bool? = nil, requireSSO: Bool? = nil, allowedEmailDomains: [String]? = nil, scopes: [String]? = nil) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`enabled` = enabled
        self.`requireSSO` = requireSSO
        self.`allowedEmailDomains` = allowedEmailDomains
        self.`scopes` = scopes
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `enabled`, `requireSSO`, `allowedEmailDomains`, `scopes` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`enabled` = try c.decodeOptional(Bool.self, forKey: .`enabled`)
        self.`requireSSO` = try c.decodeOptional(Bool.self, forKey: .`requireSSO`)
        self.`allowedEmailDomains` = try c.decodeOptional([String].self, forKey: .`allowedEmailDomains`)
        self.`scopes` = try c.decodeOptional([String].self, forKey: .`scopes`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encodeIfPresent(`enabled`, forKey: .`enabled`)
        try c.encodeIfPresent(`requireSSO`, forKey: .`requireSSO`)
        try c.encodeIfPresent(`allowedEmailDomains`, forKey: .`allowedEmailDomains`)
        try c.encodeIfPresent(`scopes`, forKey: .`scopes`)
    }
}

public struct OIDCStart: Codable, Hashable {
    public var `clientNonce`: String
    public var `providerId`: ID
    public var `redirectUri`: String
    public var `codeChallenge`: String
    public var `purpose`: String
    public var `deviceId`: ID?
    public init(clientNonce: String, providerId: ID, redirectUri: String, codeChallenge: String, purpose: String, deviceId: ID? = nil) {
        self.`clientNonce` = clientNonce
        self.`providerId` = providerId
        self.`redirectUri` = redirectUri
        self.`codeChallenge` = codeChallenge
        self.`purpose` = purpose
        self.`deviceId` = deviceId
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `providerId`, `redirectUri`, `codeChallenge`, `purpose`, `deviceId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`providerId` = try c.decode(ID.self, forKey: .`providerId`)
        self.`redirectUri` = try c.decode(String.self, forKey: .`redirectUri`)
        self.`codeChallenge` = try c.decode(String.self, forKey: .`codeChallenge`)
        self.`purpose` = try c.decode(String.self, forKey: .`purpose`)
        guard ["login", "reauth", "link"].contains(`purpose`) else { throw DecodingError.dataCorruptedError(forKey: .`purpose`, in: c, debugDescription: "Invalid OIDCStart.purpose") }
        self.`deviceId` = try c.decodeOptional(ID.self, forKey: .`deviceId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`providerId`, forKey: .`providerId`)
        try c.encode(`redirectUri`, forKey: .`redirectUri`)
        try c.encode(`codeChallenge`, forKey: .`codeChallenge`)
        try c.encode(`purpose`, forKey: .`purpose`)
        try c.encodeIfPresent(`deviceId`, forKey: .`deviceId`)
    }
}

public struct OIDCFlow: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `authorizationUrl`: String
    public var `expiresAtMs`: TimestampMs
    public init(id: ID, authorizationUrl: String, expiresAtMs: TimestampMs) {
        self.`id` = id
        self.`authorizationUrl` = authorizationUrl
        self.`expiresAtMs` = expiresAtMs
    }
    enum CodingKeys: String, CodingKey { case `id`, `authorizationUrl`, `expiresAtMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`authorizationUrl` = try c.decode(String.self, forKey: .`authorizationUrl`)
        self.`expiresAtMs` = try c.decode(TimestampMs.self, forKey: .`expiresAtMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`authorizationUrl`, forKey: .`authorizationUrl`)
        try c.encode(`expiresAtMs`, forKey: .`expiresAtMs`)
    }
}

public struct OIDCComplete: Codable, Hashable {
    public var `clientNonce`: String
    public var `flowId`: ID
    public var `completionCode`: String
    public var `codeVerifier`: String
    public var `deviceId`: ID?
    public init(clientNonce: String, flowId: ID, completionCode: String, codeVerifier: String, deviceId: ID? = nil) {
        self.`clientNonce` = clientNonce
        self.`flowId` = flowId
        self.`completionCode` = completionCode
        self.`codeVerifier` = codeVerifier
        self.`deviceId` = deviceId
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `flowId`, `completionCode`, `codeVerifier`, `deviceId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`flowId` = try c.decode(ID.self, forKey: .`flowId`)
        self.`completionCode` = try c.decode(String.self, forKey: .`completionCode`)
        self.`codeVerifier` = try c.decode(String.self, forKey: .`codeVerifier`)
        self.`deviceId` = try c.decodeOptional(ID.self, forKey: .`deviceId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`flowId`, forKey: .`flowId`)
        try c.encode(`completionCode`, forKey: .`completionCode`)
        try c.encode(`codeVerifier`, forKey: .`codeVerifier`)
        try c.encodeIfPresent(`deviceId`, forKey: .`deviceId`)
    }
}

public struct IdentityLink: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `userId`: ID
    public var `providerId`: ID
    public var `issuer`: String
    public var `subject`: String
    public var `lastUsedAtMs`: TimestampMs?
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, userId: ID, providerId: ID, issuer: String, subject: String, lastUsedAtMs: TimestampMs? = nil) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`userId` = userId
        self.`providerId` = providerId
        self.`issuer` = issuer
        self.`subject` = subject
        self.`lastUsedAtMs` = lastUsedAtMs
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `userId`, `providerId`, `issuer`, `subject`, `lastUsedAtMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`userId` = try c.decode(ID.self, forKey: .`userId`)
        self.`providerId` = try c.decode(ID.self, forKey: .`providerId`)
        self.`issuer` = try c.decode(String.self, forKey: .`issuer`)
        self.`subject` = try c.decode(String.self, forKey: .`subject`)
        self.`lastUsedAtMs` = try c.decode(TimestampMs?.self, forKey: .`lastUsedAtMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`userId`, forKey: .`userId`)
        try c.encode(`providerId`, forKey: .`providerId`)
        try c.encode(`issuer`, forKey: .`issuer`)
        try c.encode(`subject`, forKey: .`subject`)
        try c.encode(`lastUsedAtMs`, forKey: .`lastUsedAtMs`)
    }
}

public struct OIDCLinkRequest: Codable, Hashable {
    public var `clientNonce`: String
    public var `flowId`: ID
    public var `completionCode`: String
    public var `codeVerifier`: String
    public var `deviceId`: ID?
    public var `reauthToken`: String
    public init(clientNonce: String, flowId: ID, completionCode: String, codeVerifier: String, deviceId: ID? = nil, reauthToken: String) {
        self.`clientNonce` = clientNonce
        self.`flowId` = flowId
        self.`completionCode` = completionCode
        self.`codeVerifier` = codeVerifier
        self.`deviceId` = deviceId
        self.`reauthToken` = reauthToken
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `flowId`, `completionCode`, `codeVerifier`, `deviceId`, `reauthToken` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`flowId` = try c.decode(ID.self, forKey: .`flowId`)
        self.`completionCode` = try c.decode(String.self, forKey: .`completionCode`)
        self.`codeVerifier` = try c.decode(String.self, forKey: .`codeVerifier`)
        self.`deviceId` = try c.decodeOptional(ID.self, forKey: .`deviceId`)
        self.`reauthToken` = try c.decode(String.self, forKey: .`reauthToken`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`flowId`, forKey: .`flowId`)
        try c.encode(`completionCode`, forKey: .`completionCode`)
        try c.encode(`codeVerifier`, forKey: .`codeVerifier`)
        try c.encodeIfPresent(`deviceId`, forKey: .`deviceId`)
        try c.encode(`reauthToken`, forKey: .`reauthToken`)
    }
}

public struct IdentityUnlink: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `reauthToken`: String
    public init(clientNonce: String, revision: Int, reauthToken: String) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`reauthToken` = reauthToken
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `reauthToken` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`reauthToken` = try c.decode(String.self, forKey: .`reauthToken`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`reauthToken`, forKey: .`reauthToken`)
    }
}

public struct RedirectResponse: Codable, Hashable {
    public var `status`: Int
    public var `location`: String
    public init(status: Int, location: String) {
        self.`status` = status
        self.`location` = location
    }
    enum CodingKeys: String, CodingKey { case `status`, `location` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`status` = try c.decode(Int.self, forKey: .`status`)
        guard `status` == 302 else { throw DecodingError.dataCorruptedError(forKey: .`status`, in: c, debugDescription: "Invalid literal RedirectResponse.status") }
        self.`location` = try c.decode(String.self, forKey: .`location`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`status`, forKey: .`status`)
        try c.encode(`location`, forKey: .`location`)
    }
}

public struct DirectoryGroup: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `name`: String
    public var `externalId`: String?
    public var `source`: String
    public var `memberUserIds`: [ID]
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, name: String, externalId: String? = nil, source: String, memberUserIds: [ID]) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`name` = name
        self.`externalId` = externalId
        self.`source` = source
        self.`memberUserIds` = memberUserIds
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `name`, `externalId`, `source`, `memberUserIds` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`externalId` = try c.decode(String?.self, forKey: .`externalId`)
        self.`source` = try c.decode(String.self, forKey: .`source`)
        guard ["local", "oidc", "scim"].contains(`source`) else { throw DecodingError.dataCorruptedError(forKey: .`source`, in: c, debugDescription: "Invalid DirectoryGroup.source") }
        self.`memberUserIds` = try c.decode([ID].self, forKey: .`memberUserIds`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`externalId`, forKey: .`externalId`)
        try c.encode(`source`, forKey: .`source`)
        try c.encode(`memberUserIds`, forKey: .`memberUserIds`)
    }
}

public struct DirectoryGroupCreate: Codable, Hashable {
    public var `clientNonce`: String
    public var `name`: String
    public var `memberUserIds`: [ID]
    public init(clientNonce: String, name: String, memberUserIds: [ID]) {
        self.`clientNonce` = clientNonce
        self.`name` = name
        self.`memberUserIds` = memberUserIds
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `name`, `memberUserIds` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`memberUserIds` = try c.decode([ID].self, forKey: .`memberUserIds`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`memberUserIds`, forKey: .`memberUserIds`)
    }
}

public struct DirectoryGroupUpdate: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `name`: String?
    public var `memberUserIds`: [ID]?
    public init(clientNonce: String, revision: Int, name: String? = nil, memberUserIds: [ID]? = nil) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`name` = name
        self.`memberUserIds` = memberUserIds
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `name`, `memberUserIds` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`name` = try c.decodeOptional(String.self, forKey: .`name`)
        self.`memberUserIds` = try c.decodeOptional([ID].self, forKey: .`memberUserIds`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encodeIfPresent(`name`, forKey: .`name`)
        try c.encodeIfPresent(`memberUserIds`, forKey: .`memberUserIds`)
    }
}

public struct GroupPolicy: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `directoryGroupId`: ID
    public var `productAccess`: Bool
    public var `capabilityModes`: [String: String]
    public var `requiredRuleIds`: [ID]
    public var `localExecutionCeiling`: String
    public var `allowEgress`: Bool
    public var `allowSudo`: Bool
    public var `networkPolicyId`: ID?
    public var `reviewExempt`: Bool
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, directoryGroupId: ID, productAccess: Bool, capabilityModes: [String: String], requiredRuleIds: [ID], localExecutionCeiling: String, allowEgress: Bool, allowSudo: Bool, networkPolicyId: ID? = nil, reviewExempt: Bool) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`directoryGroupId` = directoryGroupId
        self.`productAccess` = productAccess
        self.`capabilityModes` = capabilityModes
        self.`requiredRuleIds` = requiredRuleIds
        self.`localExecutionCeiling` = localExecutionCeiling
        self.`allowEgress` = allowEgress
        self.`allowSudo` = allowSudo
        self.`networkPolicyId` = networkPolicyId
        self.`reviewExempt` = reviewExempt
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `directoryGroupId`, `productAccess`, `capabilityModes`, `requiredRuleIds`, `localExecutionCeiling`, `allowEgress`, `allowSudo`, `networkPolicyId`, `reviewExempt` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`directoryGroupId` = try c.decode(ID.self, forKey: .`directoryGroupId`)
        self.`productAccess` = try c.decode(Bool.self, forKey: .`productAccess`)
        self.`capabilityModes` = try c.decode([String: String].self, forKey: .`capabilityModes`)
        self.`requiredRuleIds` = try c.decode([ID].self, forKey: .`requiredRuleIds`)
        self.`localExecutionCeiling` = try c.decode(String.self, forKey: .`localExecutionCeiling`)
        guard ["deny", "ask", "allow"].contains(`localExecutionCeiling`) else { throw DecodingError.dataCorruptedError(forKey: .`localExecutionCeiling`, in: c, debugDescription: "Invalid GroupPolicy.localExecutionCeiling") }
        self.`allowEgress` = try c.decode(Bool.self, forKey: .`allowEgress`)
        self.`allowSudo` = try c.decode(Bool.self, forKey: .`allowSudo`)
        self.`networkPolicyId` = try c.decode(ID?.self, forKey: .`networkPolicyId`)
        self.`reviewExempt` = try c.decode(Bool.self, forKey: .`reviewExempt`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`directoryGroupId`, forKey: .`directoryGroupId`)
        try c.encode(`productAccess`, forKey: .`productAccess`)
        try c.encode(`capabilityModes`, forKey: .`capabilityModes`)
        try c.encode(`requiredRuleIds`, forKey: .`requiredRuleIds`)
        try c.encode(`localExecutionCeiling`, forKey: .`localExecutionCeiling`)
        try c.encode(`allowEgress`, forKey: .`allowEgress`)
        try c.encode(`allowSudo`, forKey: .`allowSudo`)
        try c.encode(`networkPolicyId`, forKey: .`networkPolicyId`)
        try c.encode(`reviewExempt`, forKey: .`reviewExempt`)
    }
}

public struct GroupPolicyUpdate: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `productAccess`: Bool?
    public var `capabilityModes`: [String: String]?
    public var `requiredRuleIds`: [ID]?
    public var `localExecutionCeiling`: String?
    public var `allowEgress`: Bool?
    public var `allowSudo`: Bool?
    public var `networkPolicyId`: ID??
    public var `reviewExempt`: Bool?
    public init(clientNonce: String, revision: Int, productAccess: Bool? = nil, capabilityModes: [String: String]? = nil, requiredRuleIds: [ID]? = nil, localExecutionCeiling: String? = nil, allowEgress: Bool? = nil, allowSudo: Bool? = nil, networkPolicyId: ID?? = nil, reviewExempt: Bool? = nil) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`productAccess` = productAccess
        self.`capabilityModes` = capabilityModes
        self.`requiredRuleIds` = requiredRuleIds
        self.`localExecutionCeiling` = localExecutionCeiling
        self.`allowEgress` = allowEgress
        self.`allowSudo` = allowSudo
        self.`networkPolicyId` = networkPolicyId
        self.`reviewExempt` = reviewExempt
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `productAccess`, `capabilityModes`, `requiredRuleIds`, `localExecutionCeiling`, `allowEgress`, `allowSudo`, `networkPolicyId`, `reviewExempt` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`productAccess` = try c.decodeOptional(Bool.self, forKey: .`productAccess`)
        self.`capabilityModes` = try c.decodeOptional([String: String].self, forKey: .`capabilityModes`)
        self.`requiredRuleIds` = try c.decodeOptional([ID].self, forKey: .`requiredRuleIds`)
        self.`localExecutionCeiling` = try c.decodeOptional(String.self, forKey: .`localExecutionCeiling`)
        self.`allowEgress` = try c.decodeOptional(Bool.self, forKey: .`allowEgress`)
        self.`allowSudo` = try c.decodeOptional(Bool.self, forKey: .`allowSudo`)
        self.`networkPolicyId` = c.contains(.`networkPolicyId`) ? .some(try c.decodeIfPresent(ID.self, forKey: .`networkPolicyId`)) : nil
        self.`reviewExempt` = try c.decodeOptional(Bool.self, forKey: .`reviewExempt`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encodeIfPresent(`productAccess`, forKey: .`productAccess`)
        try c.encodeIfPresent(`capabilityModes`, forKey: .`capabilityModes`)
        try c.encodeIfPresent(`requiredRuleIds`, forKey: .`requiredRuleIds`)
        try c.encodeIfPresent(`localExecutionCeiling`, forKey: .`localExecutionCeiling`)
        try c.encodeIfPresent(`allowEgress`, forKey: .`allowEgress`)
        try c.encodeIfPresent(`allowSudo`, forKey: .`allowSudo`)
        if let value = `networkPolicyId` { try c.encode(value, forKey: .`networkPolicyId`) }
        try c.encodeIfPresent(`reviewExempt`, forKey: .`reviewExempt`)
    }
}

public struct Governance: Codable, Hashable {
    public var `revision`: Int
    public var `groupAccess`: String
    public var `allowedDirectoryGroupIds`: [ID]
    public var `allowSudo`: Bool
    public var `allowEgress`: Bool
    public var `lockNetworkForGroups`: Bool
    public var `requireReview`: Bool
    public var `allowedChannelAdapters`: [String]
    public var `xMentionsEnabled`: Bool
    public var `emailEnabled`: Bool
    public var `contentExportEnabled`: Bool
    public var `inactiveHostPolicy`: GovernanceInactiveHostPolicy
    public init(revision: Int, groupAccess: String, allowedDirectoryGroupIds: [ID], allowSudo: Bool, allowEgress: Bool, lockNetworkForGroups: Bool, requireReview: Bool, allowedChannelAdapters: [String], xMentionsEnabled: Bool, emailEnabled: Bool, contentExportEnabled: Bool, inactiveHostPolicy: GovernanceInactiveHostPolicy) {
        self.`revision` = revision
        self.`groupAccess` = groupAccess
        self.`allowedDirectoryGroupIds` = allowedDirectoryGroupIds
        self.`allowSudo` = allowSudo
        self.`allowEgress` = allowEgress
        self.`lockNetworkForGroups` = lockNetworkForGroups
        self.`requireReview` = requireReview
        self.`allowedChannelAdapters` = allowedChannelAdapters
        self.`xMentionsEnabled` = xMentionsEnabled
        self.`emailEnabled` = emailEnabled
        self.`contentExportEnabled` = contentExportEnabled
        self.`inactiveHostPolicy` = inactiveHostPolicy
    }
    enum CodingKeys: String, CodingKey { case `revision`, `groupAccess`, `allowedDirectoryGroupIds`, `allowSudo`, `allowEgress`, `lockNetworkForGroups`, `requireReview`, `allowedChannelAdapters`, `xMentionsEnabled`, `emailEnabled`, `contentExportEnabled`, `inactiveHostPolicy` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`groupAccess` = try c.decode(String.self, forKey: .`groupAccess`)
        guard ["all", "selected"].contains(`groupAccess`) else { throw DecodingError.dataCorruptedError(forKey: .`groupAccess`, in: c, debugDescription: "Invalid Governance.groupAccess") }
        self.`allowedDirectoryGroupIds` = try c.decode([ID].self, forKey: .`allowedDirectoryGroupIds`)
        self.`allowSudo` = try c.decode(Bool.self, forKey: .`allowSudo`)
        self.`allowEgress` = try c.decode(Bool.self, forKey: .`allowEgress`)
        self.`lockNetworkForGroups` = try c.decode(Bool.self, forKey: .`lockNetworkForGroups`)
        self.`requireReview` = try c.decode(Bool.self, forKey: .`requireReview`)
        self.`allowedChannelAdapters` = try c.decode([String].self, forKey: .`allowedChannelAdapters`)
        self.`xMentionsEnabled` = try c.decode(Bool.self, forKey: .`xMentionsEnabled`)
        self.`emailEnabled` = try c.decode(Bool.self, forKey: .`emailEnabled`)
        self.`contentExportEnabled` = try c.decode(Bool.self, forKey: .`contentExportEnabled`)
        self.`inactiveHostPolicy` = try c.decode(GovernanceInactiveHostPolicy.self, forKey: .`inactiveHostPolicy`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`groupAccess`, forKey: .`groupAccess`)
        try c.encode(`allowedDirectoryGroupIds`, forKey: .`allowedDirectoryGroupIds`)
        try c.encode(`allowSudo`, forKey: .`allowSudo`)
        try c.encode(`allowEgress`, forKey: .`allowEgress`)
        try c.encode(`lockNetworkForGroups`, forKey: .`lockNetworkForGroups`)
        try c.encode(`requireReview`, forKey: .`requireReview`)
        try c.encode(`allowedChannelAdapters`, forKey: .`allowedChannelAdapters`)
        try c.encode(`xMentionsEnabled`, forKey: .`xMentionsEnabled`)
        try c.encode(`emailEnabled`, forKey: .`emailEnabled`)
        try c.encode(`contentExportEnabled`, forKey: .`contentExportEnabled`)
        try c.encode(`inactiveHostPolicy`, forKey: .`inactiveHostPolicy`)
    }
}

public struct GovernanceUpdate: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `groupAccess`: String?
    public var `allowedDirectoryGroupIds`: [ID]?
    public var `allowSudo`: Bool?
    public var `allowEgress`: Bool?
    public var `lockNetworkForGroups`: Bool?
    public var `requireReview`: Bool?
    public var `allowedChannelAdapters`: [String]?
    public var `xMentionsEnabled`: Bool?
    public var `emailEnabled`: Bool?
    public var `contentExportEnabled`: Bool?
    public var `inactiveHostPolicy`: GovernanceUpdateInactiveHostPolicy?
    public init(clientNonce: String, revision: Int, groupAccess: String? = nil, allowedDirectoryGroupIds: [ID]? = nil, allowSudo: Bool? = nil, allowEgress: Bool? = nil, lockNetworkForGroups: Bool? = nil, requireReview: Bool? = nil, allowedChannelAdapters: [String]? = nil, xMentionsEnabled: Bool? = nil, emailEnabled: Bool? = nil, contentExportEnabled: Bool? = nil, inactiveHostPolicy: GovernanceUpdateInactiveHostPolicy? = nil) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`groupAccess` = groupAccess
        self.`allowedDirectoryGroupIds` = allowedDirectoryGroupIds
        self.`allowSudo` = allowSudo
        self.`allowEgress` = allowEgress
        self.`lockNetworkForGroups` = lockNetworkForGroups
        self.`requireReview` = requireReview
        self.`allowedChannelAdapters` = allowedChannelAdapters
        self.`xMentionsEnabled` = xMentionsEnabled
        self.`emailEnabled` = emailEnabled
        self.`contentExportEnabled` = contentExportEnabled
        self.`inactiveHostPolicy` = inactiveHostPolicy
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `groupAccess`, `allowedDirectoryGroupIds`, `allowSudo`, `allowEgress`, `lockNetworkForGroups`, `requireReview`, `allowedChannelAdapters`, `xMentionsEnabled`, `emailEnabled`, `contentExportEnabled`, `inactiveHostPolicy` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`groupAccess` = try c.decodeOptional(String.self, forKey: .`groupAccess`)
        self.`allowedDirectoryGroupIds` = try c.decodeOptional([ID].self, forKey: .`allowedDirectoryGroupIds`)
        self.`allowSudo` = try c.decodeOptional(Bool.self, forKey: .`allowSudo`)
        self.`allowEgress` = try c.decodeOptional(Bool.self, forKey: .`allowEgress`)
        self.`lockNetworkForGroups` = try c.decodeOptional(Bool.self, forKey: .`lockNetworkForGroups`)
        self.`requireReview` = try c.decodeOptional(Bool.self, forKey: .`requireReview`)
        self.`allowedChannelAdapters` = try c.decodeOptional([String].self, forKey: .`allowedChannelAdapters`)
        self.`xMentionsEnabled` = try c.decodeOptional(Bool.self, forKey: .`xMentionsEnabled`)
        self.`emailEnabled` = try c.decodeOptional(Bool.self, forKey: .`emailEnabled`)
        self.`contentExportEnabled` = try c.decodeOptional(Bool.self, forKey: .`contentExportEnabled`)
        self.`inactiveHostPolicy` = try c.decodeOptional(GovernanceUpdateInactiveHostPolicy.self, forKey: .`inactiveHostPolicy`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encodeIfPresent(`groupAccess`, forKey: .`groupAccess`)
        try c.encodeIfPresent(`allowedDirectoryGroupIds`, forKey: .`allowedDirectoryGroupIds`)
        try c.encodeIfPresent(`allowSudo`, forKey: .`allowSudo`)
        try c.encodeIfPresent(`allowEgress`, forKey: .`allowEgress`)
        try c.encodeIfPresent(`lockNetworkForGroups`, forKey: .`lockNetworkForGroups`)
        try c.encodeIfPresent(`requireReview`, forKey: .`requireReview`)
        try c.encodeIfPresent(`allowedChannelAdapters`, forKey: .`allowedChannelAdapters`)
        try c.encodeIfPresent(`xMentionsEnabled`, forKey: .`xMentionsEnabled`)
        try c.encodeIfPresent(`emailEnabled`, forKey: .`emailEnabled`)
        try c.encodeIfPresent(`contentExportEnabled`, forKey: .`contentExportEnabled`)
        try c.encodeIfPresent(`inactiveHostPolicy`, forKey: .`inactiveHostPolicy`)
    }
}

public struct NetworkRule: Codable, Hashable {
    public var `kind`: String
    public var `value`: String
    public var `ports`: [Int]
    public var `protocol`: String
    public init(kind: String, value: String, ports: [Int], protocol transportProtocol: String) {
        self.`kind` = kind
        self.`value` = value
        self.`ports` = ports
        self.`protocol` = transportProtocol
    }
    enum CodingKeys: String, CodingKey { case `kind`, `value`, `ports`, `protocol` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["domain", "ip_cidr"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid NetworkRule.kind") }
        self.`value` = try c.decode(String.self, forKey: .`value`)
        self.`ports` = try c.decode([Int].self, forKey: .`ports`)
        self.`protocol` = try c.decode(String.self, forKey: .`protocol`)
        guard ["tcp", "udp", "both"].contains(`protocol`) else { throw DecodingError.dataCorruptedError(forKey: .`protocol`, in: c, debugDescription: "Invalid NetworkRule.protocol") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`value`, forKey: .`value`)
        try c.encode(`ports`, forKey: .`ports`)
        try c.encode(`protocol`, forKey: .`protocol`)
    }
}

public struct NetworkPolicy: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `scope`: String
    public var `directoryGroupId`: ID?
    public var `mode`: String
    public var `rules`: [NetworkRule]
    public var `requiredRuntimeDestinations`: [NetworkRule]
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, scope: String, directoryGroupId: ID? = nil, mode: String, rules: [NetworkRule], requiredRuntimeDestinations: [NetworkRule]) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`scope` = scope
        self.`directoryGroupId` = directoryGroupId
        self.`mode` = mode
        self.`rules` = rules
        self.`requiredRuntimeDestinations` = requiredRuntimeDestinations
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `scope`, `directoryGroupId`, `mode`, `rules`, `requiredRuntimeDestinations` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`scope` = try c.decode(String.self, forKey: .`scope`)
        guard ["workspace", "directory_group"].contains(`scope`) else { throw DecodingError.dataCorruptedError(forKey: .`scope`, in: c, debugDescription: "Invalid NetworkPolicy.scope") }
        self.`directoryGroupId` = try c.decode(ID?.self, forKey: .`directoryGroupId`)
        self.`mode` = try c.decode(String.self, forKey: .`mode`)
        guard ["allow_all", "defaults_plus_allowlist", "allowlist_only"].contains(`mode`) else { throw DecodingError.dataCorruptedError(forKey: .`mode`, in: c, debugDescription: "Invalid NetworkPolicy.mode") }
        self.`rules` = try c.decode([NetworkRule].self, forKey: .`rules`)
        self.`requiredRuntimeDestinations` = try c.decode([NetworkRule].self, forKey: .`requiredRuntimeDestinations`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`scope`, forKey: .`scope`)
        try c.encode(`directoryGroupId`, forKey: .`directoryGroupId`)
        try c.encode(`mode`, forKey: .`mode`)
        try c.encode(`rules`, forKey: .`rules`)
        try c.encode(`requiredRuntimeDestinations`, forKey: .`requiredRuntimeDestinations`)
    }
}

public struct NetworkPolicyCreate: Codable, Hashable {
    public var `clientNonce`: String
    public var `scope`: String
    public var `directoryGroupId`: ID?
    public var `mode`: String
    public var `rules`: [NetworkRule]
    public init(clientNonce: String, scope: String, directoryGroupId: ID? = nil, mode: String, rules: [NetworkRule]) {
        self.`clientNonce` = clientNonce
        self.`scope` = scope
        self.`directoryGroupId` = directoryGroupId
        self.`mode` = mode
        self.`rules` = rules
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `scope`, `directoryGroupId`, `mode`, `rules` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`scope` = try c.decode(String.self, forKey: .`scope`)
        self.`directoryGroupId` = try c.decodeOptional(ID.self, forKey: .`directoryGroupId`)
        self.`mode` = try c.decode(String.self, forKey: .`mode`)
        self.`rules` = try c.decode([NetworkRule].self, forKey: .`rules`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`scope`, forKey: .`scope`)
        try c.encodeIfPresent(`directoryGroupId`, forKey: .`directoryGroupId`)
        try c.encode(`mode`, forKey: .`mode`)
        try c.encode(`rules`, forKey: .`rules`)
    }
}

public struct NetworkPolicyUpdate: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `mode`: String?
    public var `rules`: [NetworkRule]?
    public init(clientNonce: String, revision: Int, mode: String? = nil, rules: [NetworkRule]? = nil) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`mode` = mode
        self.`rules` = rules
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `mode`, `rules` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`mode` = try c.decodeOptional(String.self, forKey: .`mode`)
        self.`rules` = try c.decodeOptional([NetworkRule].self, forKey: .`rules`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encodeIfPresent(`mode`, forKey: .`mode`)
        try c.encodeIfPresent(`rules`, forKey: .`rules`)
    }
}

public struct PolicyApplication: Codable, Hashable {
    public var `machineId`: ID
    public var `desiredRevision`: Int
    public var `appliedRevision`: Int?
    public var `state`: String
    public var `error`: String?
    public var `measuredAtMs`: TimestampMs
    public init(machineId: ID, desiredRevision: Int, appliedRevision: Int? = nil, state: String, error: String? = nil, measuredAtMs: TimestampMs) {
        self.`machineId` = machineId
        self.`desiredRevision` = desiredRevision
        self.`appliedRevision` = appliedRevision
        self.`state` = state
        self.`error` = error
        self.`measuredAtMs` = measuredAtMs
    }
    enum CodingKeys: String, CodingKey { case `machineId`, `desiredRevision`, `appliedRevision`, `state`, `error`, `measuredAtMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`machineId` = try c.decode(ID.self, forKey: .`machineId`)
        self.`desiredRevision` = try c.decode(Int.self, forKey: .`desiredRevision`)
        self.`appliedRevision` = try c.decode(Int?.self, forKey: .`appliedRevision`)
        self.`state` = try c.decode(String.self, forKey: .`state`)
        guard ["pending", "applied", "failed", "offline", "unsupported"].contains(`state`) else { throw DecodingError.dataCorruptedError(forKey: .`state`, in: c, debugDescription: "Invalid PolicyApplication.state") }
        self.`error` = try c.decode(String?.self, forKey: .`error`)
        self.`measuredAtMs` = try c.decode(TimestampMs.self, forKey: .`measuredAtMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`machineId`, forKey: .`machineId`)
        try c.encode(`desiredRevision`, forKey: .`desiredRevision`)
        try c.encode(`appliedRevision`, forKey: .`appliedRevision`)
        try c.encode(`state`, forKey: .`state`)
        try c.encode(`error`, forKey: .`error`)
        try c.encode(`measuredAtMs`, forKey: .`measuredAtMs`)
    }
}

public struct EffectivePolicy: Codable, Hashable {
    public var `userId`: ID
    public var `botId`: ID?
    public var `directoryGroupIds`: [ID]
    public var `productAccess`: Bool
    public var `localExecutionCeiling`: String
    public var `allowSudo`: Bool
    public var `allowEgress`: Bool
    public var `rules`: [PolicyRule]
    public var `networkPolicies`: [NetworkPolicy]
    public var `explanations`: [String]
    public init(userId: ID, botId: ID? = nil, directoryGroupIds: [ID], productAccess: Bool, localExecutionCeiling: String, allowSudo: Bool, allowEgress: Bool, rules: [PolicyRule], networkPolicies: [NetworkPolicy], explanations: [String]) {
        self.`userId` = userId
        self.`botId` = botId
        self.`directoryGroupIds` = directoryGroupIds
        self.`productAccess` = productAccess
        self.`localExecutionCeiling` = localExecutionCeiling
        self.`allowSudo` = allowSudo
        self.`allowEgress` = allowEgress
        self.`rules` = rules
        self.`networkPolicies` = networkPolicies
        self.`explanations` = explanations
    }
    enum CodingKeys: String, CodingKey { case `userId`, `botId`, `directoryGroupIds`, `productAccess`, `localExecutionCeiling`, `allowSudo`, `allowEgress`, `rules`, `networkPolicies`, `explanations` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`userId` = try c.decode(ID.self, forKey: .`userId`)
        self.`botId` = try c.decode(ID?.self, forKey: .`botId`)
        self.`directoryGroupIds` = try c.decode([ID].self, forKey: .`directoryGroupIds`)
        self.`productAccess` = try c.decode(Bool.self, forKey: .`productAccess`)
        self.`localExecutionCeiling` = try c.decode(String.self, forKey: .`localExecutionCeiling`)
        self.`allowSudo` = try c.decode(Bool.self, forKey: .`allowSudo`)
        self.`allowEgress` = try c.decode(Bool.self, forKey: .`allowEgress`)
        self.`rules` = try c.decode([PolicyRule].self, forKey: .`rules`)
        self.`networkPolicies` = try c.decode([NetworkPolicy].self, forKey: .`networkPolicies`)
        self.`explanations` = try c.decode([String].self, forKey: .`explanations`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`userId`, forKey: .`userId`)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`directoryGroupIds`, forKey: .`directoryGroupIds`)
        try c.encode(`productAccess`, forKey: .`productAccess`)
        try c.encode(`localExecutionCeiling`, forKey: .`localExecutionCeiling`)
        try c.encode(`allowSudo`, forKey: .`allowSudo`)
        try c.encode(`allowEgress`, forKey: .`allowEgress`)
        try c.encode(`rules`, forKey: .`rules`)
        try c.encode(`networkPolicies`, forKey: .`networkPolicies`)
        try c.encode(`explanations`, forKey: .`explanations`)
    }
}

public struct EgressRoute: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `machineId`: ID
    public var `ownerUserId`: ID
    public var `throughMachineId`: ID
    public var `state`: String
    public var `enabled`: Bool
    public var `rememberedPreference`: Bool
    public var `error`: String?
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, machineId: ID, ownerUserId: ID, throughMachineId: ID, state: String, enabled: Bool, rememberedPreference: Bool, error: String? = nil) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`machineId` = machineId
        self.`ownerUserId` = ownerUserId
        self.`throughMachineId` = throughMachineId
        self.`state` = state
        self.`enabled` = enabled
        self.`rememberedPreference` = rememberedPreference
        self.`error` = error
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `machineId`, `ownerUserId`, `throughMachineId`, `state`, `enabled`, `rememberedPreference`, `error` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`machineId` = try c.decode(ID.self, forKey: .`machineId`)
        self.`ownerUserId` = try c.decode(ID.self, forKey: .`ownerUserId`)
        self.`throughMachineId` = try c.decode(ID.self, forKey: .`throughMachineId`)
        self.`state` = try c.decode(String.self, forKey: .`state`)
        guard ["connecting", "active", "disabled", "failed"].contains(`state`) else { throw DecodingError.dataCorruptedError(forKey: .`state`, in: c, debugDescription: "Invalid EgressRoute.state") }
        self.`enabled` = try c.decode(Bool.self, forKey: .`enabled`)
        self.`rememberedPreference` = try c.decode(Bool.self, forKey: .`rememberedPreference`)
        self.`error` = try c.decode(String?.self, forKey: .`error`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`machineId`, forKey: .`machineId`)
        try c.encode(`ownerUserId`, forKey: .`ownerUserId`)
        try c.encode(`throughMachineId`, forKey: .`throughMachineId`)
        try c.encode(`state`, forKey: .`state`)
        try c.encode(`enabled`, forKey: .`enabled`)
        try c.encode(`rememberedPreference`, forKey: .`rememberedPreference`)
        try c.encode(`error`, forKey: .`error`)
    }
}

public struct EgressRouteCreate: Codable, Hashable {
    public var `clientNonce`: String
    public var `machineId`: ID
    public var `throughMachineId`: ID
    public var `enabled`: Bool
    public init(clientNonce: String, machineId: ID, throughMachineId: ID, enabled: Bool) {
        self.`clientNonce` = clientNonce
        self.`machineId` = machineId
        self.`throughMachineId` = throughMachineId
        self.`enabled` = enabled
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `machineId`, `throughMachineId`, `enabled` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`machineId` = try c.decode(ID.self, forKey: .`machineId`)
        self.`throughMachineId` = try c.decode(ID.self, forKey: .`throughMachineId`)
        self.`enabled` = try c.decode(Bool.self, forKey: .`enabled`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`machineId`, forKey: .`machineId`)
        try c.encode(`throughMachineId`, forKey: .`throughMachineId`)
        try c.encode(`enabled`, forKey: .`enabled`)
    }
}

public struct EgressRouteUpdate: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `enabled`: Bool
    public init(clientNonce: String, revision: Int, enabled: Bool) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`enabled` = enabled
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `enabled` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`enabled` = try c.decode(Bool.self, forKey: .`enabled`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`enabled`, forKey: .`enabled`)
    }
}

public struct SetupManifest: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `name`: String
    public var `directoryGroupId`: ID?
    public var `machineIds`: [ID]
    public var `entries`: [SetupManifestEntries]
    public var `enabled`: Bool
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, name: String, directoryGroupId: ID? = nil, machineIds: [ID], entries: [SetupManifestEntries], enabled: Bool) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`name` = name
        self.`directoryGroupId` = directoryGroupId
        self.`machineIds` = machineIds
        self.`entries` = entries
        self.`enabled` = enabled
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `name`, `directoryGroupId`, `machineIds`, `entries`, `enabled` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`directoryGroupId` = try c.decode(ID?.self, forKey: .`directoryGroupId`)
        self.`machineIds` = try c.decode([ID].self, forKey: .`machineIds`)
        self.`entries` = try c.decode([SetupManifestEntries].self, forKey: .`entries`)
        self.`enabled` = try c.decode(Bool.self, forKey: .`enabled`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`directoryGroupId`, forKey: .`directoryGroupId`)
        try c.encode(`machineIds`, forKey: .`machineIds`)
        try c.encode(`entries`, forKey: .`entries`)
        try c.encode(`enabled`, forKey: .`enabled`)
    }
}

public struct SetupManifestCreate: Codable, Hashable {
    public var `clientNonce`: String
    public var `name`: String
    public var `directoryGroupId`: ID?
    public var `machineIds`: [ID]
    public var `entries`: [SetupManifestCreateEntries]
    public var `enabled`: Bool
    public init(clientNonce: String, name: String, directoryGroupId: ID? = nil, machineIds: [ID], entries: [SetupManifestCreateEntries], enabled: Bool) {
        self.`clientNonce` = clientNonce
        self.`name` = name
        self.`directoryGroupId` = directoryGroupId
        self.`machineIds` = machineIds
        self.`entries` = entries
        self.`enabled` = enabled
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `name`, `directoryGroupId`, `machineIds`, `entries`, `enabled` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`directoryGroupId` = try c.decodeOptional(ID.self, forKey: .`directoryGroupId`)
        self.`machineIds` = try c.decode([ID].self, forKey: .`machineIds`)
        self.`entries` = try c.decode([SetupManifestCreateEntries].self, forKey: .`entries`)
        self.`enabled` = try c.decode(Bool.self, forKey: .`enabled`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`name`, forKey: .`name`)
        try c.encodeIfPresent(`directoryGroupId`, forKey: .`directoryGroupId`)
        try c.encode(`machineIds`, forKey: .`machineIds`)
        try c.encode(`entries`, forKey: .`entries`)
        try c.encode(`enabled`, forKey: .`enabled`)
    }
}

public struct SetupManifestUpdate: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `entries`: [SetupManifestUpdateEntries]?
    public var `enabled`: Bool?
    public var `machineIds`: [ID]?
    public init(clientNonce: String, revision: Int, entries: [SetupManifestUpdateEntries]? = nil, enabled: Bool? = nil, machineIds: [ID]? = nil) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`entries` = entries
        self.`enabled` = enabled
        self.`machineIds` = machineIds
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `entries`, `enabled`, `machineIds` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`entries` = try c.decodeOptional([SetupManifestUpdateEntries].self, forKey: .`entries`)
        self.`enabled` = try c.decodeOptional(Bool.self, forKey: .`enabled`)
        self.`machineIds` = try c.decodeOptional([ID].self, forKey: .`machineIds`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encodeIfPresent(`entries`, forKey: .`entries`)
        try c.encodeIfPresent(`enabled`, forKey: .`enabled`)
        try c.encodeIfPresent(`machineIds`, forKey: .`machineIds`)
    }
}

public struct SetupRun: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `manifestId`: ID
    public var `machineId`: ID
    public var `state`: String
    public var `entryResults`: [SetupRunEntryResults]
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, manifestId: ID, machineId: ID, state: String, entryResults: [SetupRunEntryResults]) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`manifestId` = manifestId
        self.`machineId` = machineId
        self.`state` = state
        self.`entryResults` = entryResults
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `manifestId`, `machineId`, `state`, `entryResults` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`manifestId` = try c.decode(ID.self, forKey: .`manifestId`)
        self.`machineId` = try c.decode(ID.self, forKey: .`machineId`)
        self.`state` = try c.decode(String.self, forKey: .`state`)
        guard ["queued", "running", "succeeded", "failed", "skipped", "outcome_unknown"].contains(`state`) else { throw DecodingError.dataCorruptedError(forKey: .`state`, in: c, debugDescription: "Invalid SetupRun.state") }
        self.`entryResults` = try c.decode([SetupRunEntryResults].self, forKey: .`entryResults`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`manifestId`, forKey: .`manifestId`)
        try c.encode(`machineId`, forKey: .`machineId`)
        try c.encode(`state`, forKey: .`state`)
        try c.encode(`entryResults`, forKey: .`entryResults`)
    }
}

public struct HostOperationPreview: Codable, Hashable {
    public var `clientNonce`: String
    public var `machineIds`: [ID]
    public var `action`: HostAction
    public init(clientNonce: String, machineIds: [ID], action: HostAction) {
        self.`clientNonce` = clientNonce
        self.`machineIds` = machineIds
        self.`action` = action
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `machineIds`, `action` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`machineIds` = try c.decode([ID].self, forKey: .`machineIds`)
        self.`action` = try c.decode(HostAction.self, forKey: .`action`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`machineIds`, forKey: .`machineIds`)
        try c.encode(`action`, forKey: .`action`)
    }
}

public struct HostOperationCreate: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `confirmationToken`: String
    public var `confirmName`: String
    public var `machineIds`: [ID]
    public var `action`: HostAction
    public init(clientNonce: String, revision: Int, confirmationToken: String, confirmName: String, machineIds: [ID], action: HostAction) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`confirmationToken` = confirmationToken
        self.`confirmName` = confirmName
        self.`machineIds` = machineIds
        self.`action` = action
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `confirmationToken`, `confirmName`, `machineIds`, `action` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`confirmationToken` = try c.decode(String.self, forKey: .`confirmationToken`)
        self.`confirmName` = try c.decode(String.self, forKey: .`confirmName`)
        self.`machineIds` = try c.decode([ID].self, forKey: .`machineIds`)
        self.`action` = try c.decode(HostAction.self, forKey: .`action`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`confirmationToken`, forKey: .`confirmationToken`)
        try c.encode(`confirmName`, forKey: .`confirmName`)
        try c.encode(`machineIds`, forKey: .`machineIds`)
        try c.encode(`action`, forKey: .`action`)
    }
}

public struct HostOperation: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `action`: HostAction
    public var `ownerUserId`: ID
    public var `state`: String
    public var `results`: [HostOperationResults]
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, action: HostAction, ownerUserId: ID, state: String, results: [HostOperationResults]) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`action` = action
        self.`ownerUserId` = ownerUserId
        self.`state` = state
        self.`results` = results
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `action`, `ownerUserId`, `state`, `results` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`action` = try c.decode(HostAction.self, forKey: .`action`)
        self.`ownerUserId` = try c.decode(ID.self, forKey: .`ownerUserId`)
        self.`state` = try c.decode(String.self, forKey: .`state`)
        guard ["queued", "running", "completed", "failed", "outcome_unknown"].contains(`state`) else { throw DecodingError.dataCorruptedError(forKey: .`state`, in: c, debugDescription: "Invalid HostOperation.state") }
        self.`results` = try c.decode([HostOperationResults].self, forKey: .`results`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`action`, forKey: .`action`)
        try c.encode(`ownerUserId`, forKey: .`ownerUserId`)
        try c.encode(`state`, forKey: .`state`)
        try c.encode(`results`, forKey: .`results`)
    }
}

public struct HostManagement: Codable, Hashable {
    public var `machineId`: ID
    public var `supportedActions`: [HostAction]
    public var `provider`: String
    public var `supportsNetworkPolicy`: Bool
    public var `supportsEgress`: Bool
    public var `supportsSetup`: Bool
    public var `lastBackupAtMs`: TimestampMs?
    public var `environmentRoot`: String?
    public init(machineId: ID, supportedActions: [HostAction], provider: String, supportsNetworkPolicy: Bool, supportsEgress: Bool, supportsSetup: Bool, lastBackupAtMs: TimestampMs? = nil, environmentRoot: String? = nil) {
        self.`machineId` = machineId
        self.`supportedActions` = supportedActions
        self.`provider` = provider
        self.`supportsNetworkPolicy` = supportsNetworkPolicy
        self.`supportsEgress` = supportsEgress
        self.`supportsSetup` = supportsSetup
        self.`lastBackupAtMs` = lastBackupAtMs
        self.`environmentRoot` = environmentRoot
    }
    enum CodingKeys: String, CodingKey { case `machineId`, `supportedActions`, `provider`, `supportsNetworkPolicy`, `supportsEgress`, `supportsSetup`, `lastBackupAtMs`, `environmentRoot` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`machineId` = try c.decode(ID.self, forKey: .`machineId`)
        self.`supportedActions` = try c.decode([HostAction].self, forKey: .`supportedActions`)
        self.`provider` = try c.decode(String.self, forKey: .`provider`)
        guard ["systemd", "launchd", "container", "custom"].contains(`provider`) else { throw DecodingError.dataCorruptedError(forKey: .`provider`, in: c, debugDescription: "Invalid HostManagement.provider") }
        self.`supportsNetworkPolicy` = try c.decode(Bool.self, forKey: .`supportsNetworkPolicy`)
        self.`supportsEgress` = try c.decode(Bool.self, forKey: .`supportsEgress`)
        self.`supportsSetup` = try c.decode(Bool.self, forKey: .`supportsSetup`)
        self.`lastBackupAtMs` = try c.decode(TimestampMs?.self, forKey: .`lastBackupAtMs`)
        self.`environmentRoot` = try c.decode(String?.self, forKey: .`environmentRoot`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`machineId`, forKey: .`machineId`)
        try c.encode(`supportedActions`, forKey: .`supportedActions`)
        try c.encode(`provider`, forKey: .`provider`)
        try c.encode(`supportsNetworkPolicy`, forKey: .`supportsNetworkPolicy`)
        try c.encode(`supportsEgress`, forKey: .`supportsEgress`)
        try c.encode(`supportsSetup`, forKey: .`supportsSetup`)
        try c.encode(`lastBackupAtMs`, forKey: .`lastBackupAtMs`)
        try c.encode(`environmentRoot`, forKey: .`environmentRoot`)
    }
}

public struct SpendLimit: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `scope`: String
    public var `subjectId`: ID?
    public var `period`: String
    public var `limitUsd`: Double
    public var `warningPercent`: Int
    public var `enabled`: Bool
    public var `enforcement`: String
    public var `providerAccount`: String?
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, scope: String, subjectId: ID? = nil, period: String, limitUsd: Double, warningPercent: Int, enabled: Bool, enforcement: String, providerAccount: String? = nil) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`scope` = scope
        self.`subjectId` = subjectId
        self.`period` = period
        self.`limitUsd` = limitUsd
        self.`warningPercent` = warningPercent
        self.`enabled` = enabled
        self.`enforcement` = enforcement
        self.`providerAccount` = providerAccount
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `scope`, `subjectId`, `period`, `limitUsd`, `warningPercent`, `enabled`, `enforcement`, `providerAccount` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`scope` = try c.decode(String.self, forKey: .`scope`)
        guard ["workspace", "user", "bot", "routine"].contains(`scope`) else { throw DecodingError.dataCorruptedError(forKey: .`scope`, in: c, debugDescription: "Invalid SpendLimit.scope") }
        self.`subjectId` = try c.decode(ID?.self, forKey: .`subjectId`)
        self.`period` = try c.decode(String.self, forKey: .`period`)
        guard ["day", "week", "month"].contains(`period`) else { throw DecodingError.dataCorruptedError(forKey: .`period`, in: c, debugDescription: "Invalid SpendLimit.period") }
        self.`limitUsd` = try c.decode(Double.self, forKey: .`limitUsd`)
        self.`warningPercent` = try c.decode(Int.self, forKey: .`warningPercent`)
        self.`enabled` = try c.decode(Bool.self, forKey: .`enabled`)
        self.`enforcement` = try c.decode(String.self, forKey: .`enforcement`)
        guard ["block_new_runs"].contains(`enforcement`) else { throw DecodingError.dataCorruptedError(forKey: .`enforcement`, in: c, debugDescription: "Invalid SpendLimit.enforcement") }
        self.`providerAccount` = try c.decode(String?.self, forKey: .`providerAccount`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`scope`, forKey: .`scope`)
        try c.encode(`subjectId`, forKey: .`subjectId`)
        try c.encode(`period`, forKey: .`period`)
        try c.encode(`limitUsd`, forKey: .`limitUsd`)
        try c.encode(`warningPercent`, forKey: .`warningPercent`)
        try c.encode(`enabled`, forKey: .`enabled`)
        try c.encode(`enforcement`, forKey: .`enforcement`)
        try c.encode(`providerAccount`, forKey: .`providerAccount`)
    }
}

public struct SpendLimitCreate: Codable, Hashable {
    public var `clientNonce`: String
    public var `scope`: String
    public var `subjectId`: ID?
    public var `period`: String
    public var `limitUsd`: Double
    public var `warningPercent`: Int
    public var `providerAccount`: String?
    public init(clientNonce: String, scope: String, subjectId: ID? = nil, period: String, limitUsd: Double, warningPercent: Int, providerAccount: String? = nil) {
        self.`clientNonce` = clientNonce
        self.`scope` = scope
        self.`subjectId` = subjectId
        self.`period` = period
        self.`limitUsd` = limitUsd
        self.`warningPercent` = warningPercent
        self.`providerAccount` = providerAccount
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `scope`, `subjectId`, `period`, `limitUsd`, `warningPercent`, `providerAccount` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`scope` = try c.decode(String.self, forKey: .`scope`)
        self.`subjectId` = try c.decodeOptional(ID.self, forKey: .`subjectId`)
        self.`period` = try c.decode(String.self, forKey: .`period`)
        self.`limitUsd` = try c.decode(Double.self, forKey: .`limitUsd`)
        self.`warningPercent` = try c.decode(Int.self, forKey: .`warningPercent`)
        self.`providerAccount` = try c.decodeOptional(String.self, forKey: .`providerAccount`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`scope`, forKey: .`scope`)
        try c.encodeIfPresent(`subjectId`, forKey: .`subjectId`)
        try c.encode(`period`, forKey: .`period`)
        try c.encode(`limitUsd`, forKey: .`limitUsd`)
        try c.encode(`warningPercent`, forKey: .`warningPercent`)
        try c.encodeIfPresent(`providerAccount`, forKey: .`providerAccount`)
    }
}

public struct SpendLimitUpdate: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `limitUsd`: Double?
    public var `warningPercent`: Int?
    public var `enabled`: Bool?
    public init(clientNonce: String, revision: Int, limitUsd: Double? = nil, warningPercent: Int? = nil, enabled: Bool? = nil) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`limitUsd` = limitUsd
        self.`warningPercent` = warningPercent
        self.`enabled` = enabled
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `limitUsd`, `warningPercent`, `enabled` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`limitUsd` = try c.decodeOptional(Double.self, forKey: .`limitUsd`)
        self.`warningPercent` = try c.decodeOptional(Int.self, forKey: .`warningPercent`)
        self.`enabled` = try c.decodeOptional(Bool.self, forKey: .`enabled`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encodeIfPresent(`limitUsd`, forKey: .`limitUsd`)
        try c.encodeIfPresent(`warningPercent`, forKey: .`warningPercent`)
        try c.encodeIfPresent(`enabled`, forKey: .`enabled`)
    }
}

public struct SpendStatus: Codable, Hashable {
    public var `limit`: SpendLimit
    public var `spentUsd`: Double?
    public var `remainingUsd`: Double?
    public var `resetsAtMs`: TimestampMs
    public var `state`: String
    public init(limit: SpendLimit, spentUsd: Double? = nil, remainingUsd: Double? = nil, resetsAtMs: TimestampMs, state: String) {
        self.`limit` = limit
        self.`spentUsd` = spentUsd
        self.`remainingUsd` = remainingUsd
        self.`resetsAtMs` = resetsAtMs
        self.`state` = state
    }
    enum CodingKeys: String, CodingKey { case `limit`, `spentUsd`, `remainingUsd`, `resetsAtMs`, `state` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`limit` = try c.decode(SpendLimit.self, forKey: .`limit`)
        self.`spentUsd` = try c.decode(Double?.self, forKey: .`spentUsd`)
        self.`remainingUsd` = try c.decode(Double?.self, forKey: .`remainingUsd`)
        self.`resetsAtMs` = try c.decode(TimestampMs.self, forKey: .`resetsAtMs`)
        self.`state` = try c.decode(String.self, forKey: .`state`)
        guard ["ok", "warning", "exhausted", "unknown"].contains(`state`) else { throw DecodingError.dataCorruptedError(forKey: .`state`, in: c, debugDescription: "Invalid SpendStatus.state") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`limit`, forKey: .`limit`)
        try c.encode(`spentUsd`, forKey: .`spentUsd`)
        try c.encode(`remainingUsd`, forKey: .`remainingUsd`)
        try c.encode(`resetsAtMs`, forKey: .`resetsAtMs`)
        try c.encode(`state`, forKey: .`state`)
    }
}

public struct ExportDestination: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `name`: String
    public var `url`: String
    public var `protocol`: String
    public var `secretRef`: String?
    public var `streams`: [String]
    public var `enabled`: Bool
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, name: String, url: String, protocol transportProtocol: String, secretRef: String? = nil, streams: [String], enabled: Bool) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`name` = name
        self.`url` = url
        self.`protocol` = transportProtocol
        self.`secretRef` = secretRef
        self.`streams` = streams
        self.`enabled` = enabled
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `name`, `url`, `protocol`, `secretRef`, `streams`, `enabled` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`url` = try c.decode(String.self, forKey: .`url`)
        self.`protocol` = try c.decode(String.self, forKey: .`protocol`)
        guard ["otlp_http", "ndjson_webhook"].contains(`protocol`) else { throw DecodingError.dataCorruptedError(forKey: .`protocol`, in: c, debugDescription: "Invalid ExportDestination.protocol") }
        self.`secretRef` = try c.decode(String?.self, forKey: .`secretRef`)
        self.`streams` = try c.decode([String].self, forKey: .`streams`)
        guard streams.allSatisfy({ ExportStreamValue(rawValue: $0) != nil }) else { throw DecodingError.dataCorruptedError(forKey: .`streams`, in: c, debugDescription: "Invalid ExportDestination.streams") }
        self.`enabled` = try c.decode(Bool.self, forKey: .`enabled`)
    }
    public func encode(to encoder: Encoder) throws {
        guard streams.allSatisfy({ ExportStreamValue(rawValue: $0) != nil }) else { throw EncodingError.invalidValue(streams, .init(codingPath: encoder.codingPath + [CodingKeys.streams], debugDescription: "Invalid ExportDestination.streams")) }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`url`, forKey: .`url`)
        try c.encode(`protocol`, forKey: .`protocol`)
        try c.encode(`secretRef`, forKey: .`secretRef`)
        try c.encode(`streams`, forKey: .`streams`)
        try c.encode(`enabled`, forKey: .`enabled`)
    }
}

public struct ExportDestinationCreate: Codable, Hashable {
    public var `clientNonce`: String
    public var `name`: String
    public var `url`: String
    public var `protocol`: String
    public var `secretRef`: String?
    public var `streams`: [String]
    public var `enabled`: Bool
    public init(clientNonce: String, name: String, url: String, protocol transportProtocol: String, secretRef: String? = nil, streams: [String], enabled: Bool) {
        self.`clientNonce` = clientNonce
        self.`name` = name
        self.`url` = url
        self.`protocol` = transportProtocol
        self.`secretRef` = secretRef
        self.`streams` = streams
        self.`enabled` = enabled
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `name`, `url`, `protocol`, `secretRef`, `streams`, `enabled` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`url` = try c.decode(String.self, forKey: .`url`)
        self.`protocol` = try c.decode(String.self, forKey: .`protocol`)
        self.`secretRef` = try c.decodeOptional(String.self, forKey: .`secretRef`)
        guard ["otlp_http", "ndjson_webhook"].contains(`protocol`) else { throw DecodingError.dataCorruptedError(forKey: .`protocol`, in: c, debugDescription: "Invalid ExportDestinationCreate.protocol") }
        self.`streams` = try c.decode([String].self, forKey: .`streams`)
        guard streams.allSatisfy({ ExportStreamValue(rawValue: $0) != nil }) else { throw DecodingError.dataCorruptedError(forKey: .`streams`, in: c, debugDescription: "Invalid ExportDestinationCreate.streams") }
        self.`enabled` = try c.decode(Bool.self, forKey: .`enabled`)
    }
    public func encode(to encoder: Encoder) throws {
        guard streams.allSatisfy({ ExportStreamValue(rawValue: $0) != nil }) else { throw EncodingError.invalidValue(streams, .init(codingPath: encoder.codingPath + [CodingKeys.streams], debugDescription: "Invalid ExportDestinationCreate.streams")) }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`url`, forKey: .`url`)
        try c.encode(`protocol`, forKey: .`protocol`)
        try c.encodeIfPresent(`secretRef`, forKey: .`secretRef`)
        try c.encode(`streams`, forKey: .`streams`)
        try c.encode(`enabled`, forKey: .`enabled`)
    }
}

public struct ExportDestinationUpdate: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `enabled`: Bool?
    public var `streams`: [String]?
    public init(clientNonce: String, revision: Int, enabled: Bool? = nil, streams: [String]? = nil) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`enabled` = enabled
        self.`streams` = streams
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `enabled`, `streams` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`enabled` = try c.decodeOptional(Bool.self, forKey: .`enabled`)
        self.`streams` = try c.decodeOptional([String].self, forKey: .`streams`)
        if let streams, !streams.allSatisfy({ ExportStreamValue(rawValue: $0) != nil }) { throw DecodingError.dataCorruptedError(forKey: .`streams`, in: c, debugDescription: "Invalid ExportDestinationUpdate.streams") }
    }
    public func encode(to encoder: Encoder) throws {
        if let streams, !streams.allSatisfy({ ExportStreamValue(rawValue: $0) != nil }) { throw EncodingError.invalidValue(streams, .init(codingPath: encoder.codingPath + [CodingKeys.streams], debugDescription: "Invalid ExportDestinationUpdate.streams")) }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encodeIfPresent(`enabled`, forKey: .`enabled`)
        try c.encodeIfPresent(`streams`, forKey: .`streams`)
    }
}

public struct AuditExportCreate: Codable, Hashable {
    public var `clientNonce`: String
    public var `fromAtMs`: TimestampMs
    public var `toAtMs`: TimestampMs
    public var `kind`: String
    public var `conversationIds`: [ID]?
    public init(clientNonce: String, fromAtMs: TimestampMs, toAtMs: TimestampMs, kind: String, conversationIds: [ID]? = nil) {
        self.`clientNonce` = clientNonce
        self.`fromAtMs` = fromAtMs
        self.`toAtMs` = toAtMs
        self.`kind` = kind
        self.`conversationIds` = conversationIds
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `fromAtMs`, `toAtMs`, `kind`, `conversationIds` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`fromAtMs` = try c.decode(TimestampMs.self, forKey: .`fromAtMs`)
        self.`toAtMs` = try c.decode(TimestampMs.self, forKey: .`toAtMs`)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["audit", "action", "usage", "conversation_content"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid AuditExportCreate.kind") }
        self.`conversationIds` = try c.decodeOptional([ID].self, forKey: .`conversationIds`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`fromAtMs`, forKey: .`fromAtMs`)
        try c.encode(`toAtMs`, forKey: .`toAtMs`)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encodeIfPresent(`conversationIds`, forKey: .`conversationIds`)
    }
}

public struct ExportRecord: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `destinationId`: ID?
    public var `fromAtMs`: TimestampMs
    public var `toAtMs`: TimestampMs
    public var `kind`: String
    public var `state`: String
    public var `attachmentId`: ID?
    public var `lastDeliveredCursor`: Cursor?
    public var `error`: String?
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, destinationId: ID? = nil, fromAtMs: TimestampMs, toAtMs: TimestampMs, kind: String, state: String, attachmentId: ID? = nil, lastDeliveredCursor: Cursor? = nil, error: String? = nil) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`destinationId` = destinationId
        self.`fromAtMs` = fromAtMs
        self.`toAtMs` = toAtMs
        self.`kind` = kind
        self.`state` = state
        self.`attachmentId` = attachmentId
        self.`lastDeliveredCursor` = lastDeliveredCursor
        self.`error` = error
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `destinationId`, `fromAtMs`, `toAtMs`, `kind`, `state`, `attachmentId`, `lastDeliveredCursor`, `error` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`destinationId` = try c.decode(ID?.self, forKey: .`destinationId`)
        self.`fromAtMs` = try c.decode(TimestampMs.self, forKey: .`fromAtMs`)
        self.`toAtMs` = try c.decode(TimestampMs.self, forKey: .`toAtMs`)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        self.`state` = try c.decode(String.self, forKey: .`state`)
        guard ["queued", "running", "completed", "failed"].contains(`state`) else { throw DecodingError.dataCorruptedError(forKey: .`state`, in: c, debugDescription: "Invalid ExportRecord.state") }
        self.`attachmentId` = try c.decode(ID?.self, forKey: .`attachmentId`)
        self.`lastDeliveredCursor` = try c.decode(Cursor?.self, forKey: .`lastDeliveredCursor`)
        self.`error` = try c.decode(String?.self, forKey: .`error`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`destinationId`, forKey: .`destinationId`)
        try c.encode(`fromAtMs`, forKey: .`fromAtMs`)
        try c.encode(`toAtMs`, forKey: .`toAtMs`)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`state`, forKey: .`state`)
        try c.encode(`attachmentId`, forKey: .`attachmentId`)
        try c.encode(`lastDeliveredCursor`, forKey: .`lastDeliveredCursor`)
        try c.encode(`error`, forKey: .`error`)
    }
}

public struct ChannelSetup: Codable, Hashable {
    public var `clientNonce`: String
    public var `botId`: ID
    public var `adapter`: String
    public var `providerId`: String
    public var `accountLabel`: String
    public var `redirectUri`: String
    public init(clientNonce: String, botId: ID, adapter: String, providerId: String, accountLabel: String, redirectUri: String) {
        self.`clientNonce` = clientNonce
        self.`botId` = botId
        self.`adapter` = adapter
        self.`providerId` = providerId
        self.`accountLabel` = accountLabel
        self.`redirectUri` = redirectUri
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `botId`, `adapter`, `providerId`, `accountLabel`, `redirectUri` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`botId` = try c.decode(ID.self, forKey: .`botId`)
        self.`adapter` = try c.decode(String.self, forKey: .`adapter`)
        self.`providerId` = try c.decode(String.self, forKey: .`providerId`)
        self.`accountLabel` = try c.decode(String.self, forKey: .`accountLabel`)
        self.`redirectUri` = try c.decode(String.self, forKey: .`redirectUri`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`adapter`, forKey: .`adapter`)
        try c.encode(`providerId`, forKey: .`providerId`)
        try c.encode(`accountLabel`, forKey: .`accountLabel`)
        try c.encode(`redirectUri`, forKey: .`redirectUri`)
    }
}

public struct ChannelSetupFlow: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `botId`: ID
    public var `adapter`: String
    public var `authorizationUrl`: String?
    public var `state`: String
    public var `channelBindingId`: ID?
    public var `error`: String?
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, botId: ID, adapter: String, authorizationUrl: String? = nil, state: String, channelBindingId: ID? = nil, error: String? = nil) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`botId` = botId
        self.`adapter` = adapter
        self.`authorizationUrl` = authorizationUrl
        self.`state` = state
        self.`channelBindingId` = channelBindingId
        self.`error` = error
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `botId`, `adapter`, `authorizationUrl`, `state`, `channelBindingId`, `error` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`botId` = try c.decode(ID.self, forKey: .`botId`)
        self.`adapter` = try c.decode(String.self, forKey: .`adapter`)
        self.`authorizationUrl` = try c.decode(String?.self, forKey: .`authorizationUrl`)
        self.`state` = try c.decode(String.self, forKey: .`state`)
        guard ["pending", "awaiting_admin", "connected", "denied", "failed"].contains(`state`) else { throw DecodingError.dataCorruptedError(forKey: .`state`, in: c, debugDescription: "Invalid ChannelSetupFlow.state") }
        self.`channelBindingId` = try c.decode(ID?.self, forKey: .`channelBindingId`)
        self.`error` = try c.decode(String?.self, forKey: .`error`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`adapter`, forKey: .`adapter`)
        try c.encode(`authorizationUrl`, forKey: .`authorizationUrl`)
        try c.encode(`state`, forKey: .`state`)
        try c.encode(`channelBindingId`, forKey: .`channelBindingId`)
        try c.encode(`error`, forKey: .`error`)
    }
}

public struct ChannelPrincipalLink: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `channelBindingId`: ID
    public var `externalUserId`: String
    public var `userId`: ID
    public var `verified`: Bool
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, channelBindingId: ID, externalUserId: String, userId: ID, verified: Bool) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`channelBindingId` = channelBindingId
        self.`externalUserId` = externalUserId
        self.`userId` = userId
        self.`verified` = verified
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `channelBindingId`, `externalUserId`, `userId`, `verified` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`channelBindingId` = try c.decode(ID.self, forKey: .`channelBindingId`)
        self.`externalUserId` = try c.decode(String.self, forKey: .`externalUserId`)
        self.`userId` = try c.decode(ID.self, forKey: .`userId`)
        self.`verified` = try c.decode(Bool.self, forKey: .`verified`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`channelBindingId`, forKey: .`channelBindingId`)
        try c.encode(`externalUserId`, forKey: .`externalUserId`)
        try c.encode(`userId`, forKey: .`userId`)
        try c.encode(`verified`, forKey: .`verified`)
    }
}

public struct ChannelLinkCreate: Codable, Hashable {
    public var `clientNonce`: String
    public var `channelBindingId`: ID
    public var `externalUserId`: String
    public var `verificationCode`: String
    public init(clientNonce: String, channelBindingId: ID, externalUserId: String, verificationCode: String) {
        self.`clientNonce` = clientNonce
        self.`channelBindingId` = channelBindingId
        self.`externalUserId` = externalUserId
        self.`verificationCode` = verificationCode
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `channelBindingId`, `externalUserId`, `verificationCode` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`channelBindingId` = try c.decode(ID.self, forKey: .`channelBindingId`)
        self.`externalUserId` = try c.decode(String.self, forKey: .`externalUserId`)
        self.`verificationCode` = try c.decode(String.self, forKey: .`verificationCode`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`channelBindingId`, forKey: .`channelBindingId`)
        try c.encode(`externalUserId`, forKey: .`externalUserId`)
        try c.encode(`verificationCode`, forKey: .`verificationCode`)
    }
}

public struct EmailAccount: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `userId`: ID
    public var `provider`: String
    public var `address`: String
    public var `immutableAddress`: Bool
    public var `state`: String
    public var `channelBindingId`: ID?
    public var `indexingDelayed`: Bool??
    public var `indexingMeasuredAtMs`: TimestampMs??
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, userId: ID, provider: String, address: String, immutableAddress: Bool, state: String, channelBindingId: ID? = nil, indexingDelayed: Bool?? = nil, indexingMeasuredAtMs: TimestampMs?? = nil) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`userId` = userId
        self.`provider` = provider
        self.`address` = address
        self.`immutableAddress` = immutableAddress
        self.`state` = state
        self.`channelBindingId` = channelBindingId
        self.`indexingDelayed` = indexingDelayed
        self.`indexingMeasuredAtMs` = indexingMeasuredAtMs
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `userId`, `provider`, `address`, `immutableAddress`, `state`, `channelBindingId`, `indexingDelayed`, `indexingMeasuredAtMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`userId` = try c.decode(ID.self, forKey: .`userId`)
        self.`provider` = try c.decode(String.self, forKey: .`provider`)
        self.`address` = try c.decode(String.self, forKey: .`address`)
        self.`immutableAddress` = try c.decode(Bool.self, forKey: .`immutableAddress`)
        self.`state` = try c.decode(String.self, forKey: .`state`)
        guard ["pending", "active", "disabled", "retired"].contains(`state`) else { throw DecodingError.dataCorruptedError(forKey: .`state`, in: c, debugDescription: "Invalid EmailAccount.state") }
        self.`channelBindingId` = try c.decode(ID?.self, forKey: .`channelBindingId`)
        self.`indexingDelayed` = c.contains(.`indexingDelayed`) ? .some(try c.decodeIfPresent(Bool.self, forKey: .`indexingDelayed`)) : nil
        self.`indexingMeasuredAtMs` = c.contains(.`indexingMeasuredAtMs`) ? .some(try c.decodeIfPresent(TimestampMs.self, forKey: .`indexingMeasuredAtMs`)) : nil
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`userId`, forKey: .`userId`)
        try c.encode(`provider`, forKey: .`provider`)
        try c.encode(`address`, forKey: .`address`)
        try c.encode(`immutableAddress`, forKey: .`immutableAddress`)
        try c.encode(`state`, forKey: .`state`)
        try c.encode(`channelBindingId`, forKey: .`channelBindingId`)
        if let value = `indexingDelayed` { try c.encode(value, forKey: .`indexingDelayed`) }
        if let value = `indexingMeasuredAtMs` { try c.encode(value, forKey: .`indexingMeasuredAtMs`) }
    }
}

public struct EmailAddressCheck: Codable, Hashable {
    public var `clientNonce`: String
    public var `providerId`: String
    public var `localPart`: String
    public init(clientNonce: String, providerId: String, localPart: String) {
        self.`clientNonce` = clientNonce
        self.`providerId` = providerId
        self.`localPart` = localPart
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `providerId`, `localPart` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`providerId` = try c.decode(String.self, forKey: .`providerId`)
        self.`localPart` = try c.decode(String.self, forKey: .`localPart`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`providerId`, forKey: .`providerId`)
        try c.encode(`localPart`, forKey: .`localPart`)
    }
}

public struct EmailAddressAvailability: Codable, Hashable {
    public var `providerId`: String
    public var `address`: String
    public var `available`: Bool
    public var `reason`: String?
    public var `immutable`: Bool
    public init(providerId: String, address: String, available: Bool, reason: String? = nil, immutable: Bool) {
        self.`providerId` = providerId
        self.`address` = address
        self.`available` = available
        self.`reason` = reason
        self.`immutable` = immutable
    }
    enum CodingKeys: String, CodingKey { case `providerId`, `address`, `available`, `reason`, `immutable` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`providerId` = try c.decode(String.self, forKey: .`providerId`)
        self.`address` = try c.decode(String.self, forKey: .`address`)
        self.`available` = try c.decode(Bool.self, forKey: .`available`)
        self.`reason` = try c.decode(String?.self, forKey: .`reason`)
        self.`immutable` = try c.decode(Bool.self, forKey: .`immutable`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`providerId`, forKey: .`providerId`)
        try c.encode(`address`, forKey: .`address`)
        try c.encode(`available`, forKey: .`available`)
        try c.encode(`reason`, forKey: .`reason`)
        try c.encode(`immutable`, forKey: .`immutable`)
    }
}

public struct EmailAddressClaim: Codable, Hashable {
    public var `clientNonce`: String
    public var `providerId`: String
    public var `localPart`: String
    public var `approvalId`: ID
    public init(clientNonce: String, providerId: String, localPart: String, approvalId: ID) {
        self.`clientNonce` = clientNonce
        self.`providerId` = providerId
        self.`localPart` = localPart
        self.`approvalId` = approvalId
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `providerId`, `localPart`, `approvalId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`providerId` = try c.decode(String.self, forKey: .`providerId`)
        self.`localPart` = try c.decode(String.self, forKey: .`localPart`)
        self.`approvalId` = try c.decode(ID.self, forKey: .`approvalId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`providerId`, forKey: .`providerId`)
        try c.encode(`localPart`, forKey: .`localPart`)
        try c.encode(`approvalId`, forKey: .`approvalId`)
    }
}

public struct EmailAddressProposal: Codable, Hashable {
    public var `clientNonce`: String
    public var `providerId`: String
    public var `localPart`: String
    public var `botId`: ID
    public init(clientNonce: String, providerId: String, localPart: String, botId: ID) {
        self.`clientNonce` = clientNonce
        self.`providerId` = providerId
        self.`localPart` = localPart
        self.`botId` = botId
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `providerId`, `localPart`, `botId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`providerId` = try c.decode(String.self, forKey: .`providerId`)
        self.`localPart` = try c.decode(String.self, forKey: .`localPart`)
        self.`botId` = try c.decode(ID.self, forKey: .`botId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`providerId`, forKey: .`providerId`)
        try c.encode(`localPart`, forKey: .`localPart`)
        try c.encode(`botId`, forKey: .`botId`)
    }
}

public struct ContentExportConsent: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `conversationId`: ID
    public var `userId`: ID
    public var `enabled`: Bool
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, conversationId: ID, userId: ID, enabled: Bool) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`conversationId` = conversationId
        self.`userId` = userId
        self.`enabled` = enabled
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `conversationId`, `userId`, `enabled` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`conversationId` = try c.decode(ID.self, forKey: .`conversationId`)
        self.`userId` = try c.decode(ID.self, forKey: .`userId`)
        self.`enabled` = try c.decode(Bool.self, forKey: .`enabled`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`conversationId`, forKey: .`conversationId`)
        try c.encode(`userId`, forKey: .`userId`)
        try c.encode(`enabled`, forKey: .`enabled`)
    }
}

public struct ContentExportConsentUpdate: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `enabled`: Bool
    public init(clientNonce: String, revision: Int, enabled: Bool) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`enabled` = enabled
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `enabled` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`enabled` = try c.decode(Bool.self, forKey: .`enabled`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`enabled`, forKey: .`enabled`)
    }
}

public struct EmailMessage: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `accountId`: ID
    public var `from`: String
    public var `to`: [String]
    public var `subject`: String
    public var `receivedAtMs`: TimestampMs
    public var `authentication`: String
    public var `scan`: String
    public var `text`: String?
    public var `attachmentIds`: [ID]
    public var `skippedAttachmentNames`: [String]
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, accountId: ID, from: String, to: [String], subject: String, receivedAtMs: TimestampMs, authentication: String, scan: String, text: String? = nil, attachmentIds: [ID], skippedAttachmentNames: [String]) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`accountId` = accountId
        self.`from` = from
        self.`to` = to
        self.`subject` = subject
        self.`receivedAtMs` = receivedAtMs
        self.`authentication` = authentication
        self.`scan` = scan
        self.`text` = text
        self.`attachmentIds` = attachmentIds
        self.`skippedAttachmentNames` = skippedAttachmentNames
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `accountId`, `from`, `to`, `subject`, `receivedAtMs`, `authentication`, `scan`, `text`, `attachmentIds`, `skippedAttachmentNames` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`accountId` = try c.decode(ID.self, forKey: .`accountId`)
        self.`from` = try c.decode(String.self, forKey: .`from`)
        self.`to` = try c.decode([String].self, forKey: .`to`)
        self.`subject` = try c.decode(String.self, forKey: .`subject`)
        self.`receivedAtMs` = try c.decode(TimestampMs.self, forKey: .`receivedAtMs`)
        self.`authentication` = try c.decode(String.self, forKey: .`authentication`)
        guard ["passed", "failed", "unknown"].contains(`authentication`) else { throw DecodingError.dataCorruptedError(forKey: .`authentication`, in: c, debugDescription: "Invalid EmailMessage.authentication") }
        self.`scan` = try c.decode(String.self, forKey: .`scan`)
        guard ["passed", "spam", "virus", "pending"].contains(`scan`) else { throw DecodingError.dataCorruptedError(forKey: .`scan`, in: c, debugDescription: "Invalid EmailMessage.scan") }
        self.`text` = try c.decode(String?.self, forKey: .`text`)
        self.`attachmentIds` = try c.decode([ID].self, forKey: .`attachmentIds`)
        self.`skippedAttachmentNames` = try c.decode([String].self, forKey: .`skippedAttachmentNames`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`accountId`, forKey: .`accountId`)
        try c.encode(`from`, forKey: .`from`)
        try c.encode(`to`, forKey: .`to`)
        try c.encode(`subject`, forKey: .`subject`)
        try c.encode(`receivedAtMs`, forKey: .`receivedAtMs`)
        try c.encode(`authentication`, forKey: .`authentication`)
        try c.encode(`scan`, forKey: .`scan`)
        try c.encode(`text`, forKey: .`text`)
        try c.encode(`attachmentIds`, forKey: .`attachmentIds`)
        try c.encode(`skippedAttachmentNames`, forKey: .`skippedAttachmentNames`)
    }
}

public struct XConnection: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `userId`: ID
    public var `externalAccountId`: ID?
    public var `username`: String?
    public var `mainBotId`: ID
    public var `enabled`: Bool
    public var `state`: String
    public var `lastError`: String?
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, userId: ID, externalAccountId: ID? = nil, username: String? = nil, mainBotId: ID, enabled: Bool, state: String, lastError: String? = nil) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`userId` = userId
        self.`externalAccountId` = externalAccountId
        self.`username` = username
        self.`mainBotId` = mainBotId
        self.`enabled` = enabled
        self.`state` = state
        self.`lastError` = lastError
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `userId`, `externalAccountId`, `username`, `mainBotId`, `enabled`, `state`, `lastError` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`userId` = try c.decode(ID.self, forKey: .`userId`)
        self.`externalAccountId` = try c.decode(ID?.self, forKey: .`externalAccountId`)
        self.`username` = try c.decode(String?.self, forKey: .`username`)
        self.`mainBotId` = try c.decode(ID.self, forKey: .`mainBotId`)
        self.`enabled` = try c.decode(Bool.self, forKey: .`enabled`)
        self.`state` = try c.decode(String.self, forKey: .`state`)
        guard ["pending", "connected", "needs_auth", "blocked", "failed"].contains(`state`) else { throw DecodingError.dataCorruptedError(forKey: .`state`, in: c, debugDescription: "Invalid XConnection.state") }
        self.`lastError` = try c.decode(String?.self, forKey: .`lastError`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`userId`, forKey: .`userId`)
        try c.encode(`externalAccountId`, forKey: .`externalAccountId`)
        try c.encode(`username`, forKey: .`username`)
        try c.encode(`mainBotId`, forKey: .`mainBotId`)
        try c.encode(`enabled`, forKey: .`enabled`)
        try c.encode(`state`, forKey: .`state`)
        try c.encode(`lastError`, forKey: .`lastError`)
    }
}

public struct XConnect: Codable, Hashable {
    public var `clientNonce`: String
    public var `mainBotId`: ID
    public var `redirectUri`: String
    public init(clientNonce: String, mainBotId: ID, redirectUri: String) {
        self.`clientNonce` = clientNonce
        self.`mainBotId` = mainBotId
        self.`redirectUri` = redirectUri
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `mainBotId`, `redirectUri` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`mainBotId` = try c.decode(ID.self, forKey: .`mainBotId`)
        self.`redirectUri` = try c.decode(String.self, forKey: .`redirectUri`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`mainBotId`, forKey: .`mainBotId`)
        try c.encode(`redirectUri`, forKey: .`redirectUri`)
    }
}

public struct XConnectResult: Codable, Hashable {
    public var `connection`: XConnection
    public var `authorizationUrl`: String
    public init(connection: XConnection, authorizationUrl: String) {
        self.`connection` = connection
        self.`authorizationUrl` = authorizationUrl
    }
    enum CodingKeys: String, CodingKey { case `connection`, `authorizationUrl` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`connection` = try c.decode(XConnection.self, forKey: .`connection`)
        self.`authorizationUrl` = try c.decode(String.self, forKey: .`authorizationUrl`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`connection`, forKey: .`connection`)
        try c.encode(`authorizationUrl`, forKey: .`authorizationUrl`)
    }
}

public struct XConnectionUpdate: Codable, Hashable {
    public var `clientNonce`: String
    public var `revision`: Int
    public var `mainBotId`: ID?
    public var `enabled`: Bool?
    public init(clientNonce: String, revision: Int, mainBotId: ID? = nil, enabled: Bool? = nil) {
        self.`clientNonce` = clientNonce
        self.`revision` = revision
        self.`mainBotId` = mainBotId
        self.`enabled` = enabled
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `revision`, `mainBotId`, `enabled` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`mainBotId` = try c.decodeOptional(ID.self, forKey: .`mainBotId`)
        self.`enabled` = try c.decodeOptional(Bool.self, forKey: .`enabled`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encodeIfPresent(`mainBotId`, forKey: .`mainBotId`)
        try c.encodeIfPresent(`enabled`, forKey: .`enabled`)
    }
}

public struct XIngress: Codable, Hashable {
    public var `deliveryId`: String
    public var `externalAccountId`: String
    public var `mentionPostId`: String
    public var `mentionedHandle`: String
    public var `text`: String
    public var `repliedPost`: JSONObject?
    public var `quotedPosts`: [JSONObject]?
    public var `mediaAttachmentIds`: [ID]?
    public init(deliveryId: String, externalAccountId: String, mentionPostId: String, mentionedHandle: String, text: String, repliedPost: JSONObject? = nil, quotedPosts: [JSONObject]? = nil, mediaAttachmentIds: [ID]? = nil) {
        self.`deliveryId` = deliveryId
        self.`externalAccountId` = externalAccountId
        self.`mentionPostId` = mentionPostId
        self.`mentionedHandle` = mentionedHandle
        self.`text` = text
        self.`repliedPost` = repliedPost
        self.`quotedPosts` = quotedPosts
        self.`mediaAttachmentIds` = mediaAttachmentIds
    }
    enum CodingKeys: String, CodingKey { case `deliveryId`, `externalAccountId`, `mentionPostId`, `mentionedHandle`, `text`, `repliedPost`, `quotedPosts`, `mediaAttachmentIds` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`deliveryId` = try c.decode(String.self, forKey: .`deliveryId`)
        self.`externalAccountId` = try c.decode(String.self, forKey: .`externalAccountId`)
        self.`mentionPostId` = try c.decode(String.self, forKey: .`mentionPostId`)
        self.`mentionedHandle` = try c.decode(String.self, forKey: .`mentionedHandle`)
        self.`text` = try c.decode(String.self, forKey: .`text`)
        self.`repliedPost` = try c.decodeOptional(JSONObject.self, forKey: .`repliedPost`)
        self.`quotedPosts` = try c.decodeOptional([JSONObject].self, forKey: .`quotedPosts`)
        self.`mediaAttachmentIds` = try c.decodeOptional([ID].self, forKey: .`mediaAttachmentIds`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`deliveryId`, forKey: .`deliveryId`)
        try c.encode(`externalAccountId`, forKey: .`externalAccountId`)
        try c.encode(`mentionPostId`, forKey: .`mentionPostId`)
        try c.encode(`mentionedHandle`, forKey: .`mentionedHandle`)
        try c.encode(`text`, forKey: .`text`)
        try c.encodeIfPresent(`repliedPost`, forKey: .`repliedPost`)
        try c.encodeIfPresent(`quotedPosts`, forKey: .`quotedPosts`)
        try c.encodeIfPresent(`mediaAttachmentIds`, forKey: .`mediaAttachmentIds`)
    }
}

public struct IntegrationIngressReceipt: Codable, Hashable {
    public var `accepted`: Bool
    public var `status`: String
    public var `reason`: String?
    public var `runId`: ID?
    public var `conversationId`: ID?
    public init(accepted: Bool, status: String, reason: String? = nil, runId: ID? = nil, conversationId: ID? = nil) {
        self.`accepted` = accepted
        self.`status` = status
        self.`reason` = reason
        self.`runId` = runId
        self.`conversationId` = conversationId
    }
    enum CodingKeys: String, CodingKey { case `accepted`, `status`, `reason`, `runId`, `conversationId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`accepted` = try c.decode(Bool.self, forKey: .`accepted`)
        self.`status` = try c.decode(String.self, forKey: .`status`)
        guard ["accepted", "ignored", "outcome_unknown"].contains(`status`) else { throw DecodingError.dataCorruptedError(forKey: .`status`, in: c, debugDescription: "Invalid IntegrationIngressReceipt.status") }
        self.`reason` = try c.decode(String?.self, forKey: .`reason`)
        self.`runId` = try c.decode(ID?.self, forKey: .`runId`)
        self.`conversationId` = try c.decode(ID?.self, forKey: .`conversationId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`accepted`, forKey: .`accepted`)
        try c.encode(`status`, forKey: .`status`)
        try c.encode(`reason`, forKey: .`reason`)
        try c.encode(`runId`, forKey: .`runId`)
        try c.encode(`conversationId`, forKey: .`conversationId`)
    }
}

public struct IntegrationWebhook: Codable, Hashable {
    public var `deliveryId`: String
    public var `event`: String
    public var `payload`: JSONObject
    public init(deliveryId: String, event: String, payload: JSONObject) {
        self.`deliveryId` = deliveryId
        self.`event` = event
        self.`payload` = payload
    }
    enum CodingKeys: String, CodingKey { case `deliveryId`, `event`, `payload` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`deliveryId` = try c.decode(String.self, forKey: .`deliveryId`)
        self.`event` = try c.decode(String.self, forKey: .`event`)
        self.`payload` = try c.decode(JSONObject.self, forKey: .`payload`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`deliveryId`, forKey: .`deliveryId`)
        try c.encode(`event`, forKey: .`event`)
        try c.encode(`payload`, forKey: .`payload`)
    }
}

public struct IntegrationToken: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `name`: String
    public var `kind`: String
    public var `scopes`: [String]
    public var `expiresAtMs`: TimestampMs?
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, name: String, kind: String, scopes: [String], expiresAtMs: TimestampMs? = nil) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`name` = name
        self.`kind` = kind
        self.`scopes` = scopes
        self.`expiresAtMs` = expiresAtMs
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `name`, `kind`, `scopes`, `expiresAtMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["scim", "event_ingress", "audit_export"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid IntegrationToken.kind") }
        self.`scopes` = try c.decode([String].self, forKey: .`scopes`)
        self.`expiresAtMs` = try c.decode(TimestampMs?.self, forKey: .`expiresAtMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`scopes`, forKey: .`scopes`)
        try c.encode(`expiresAtMs`, forKey: .`expiresAtMs`)
    }
}

public struct IntegrationTokenCreate: Codable, Hashable {
    public var `clientNonce`: String
    public var `name`: String
    public var `kind`: String
    public var `scopes`: [String]
    public var `expiresInMs`: Int?
    public init(clientNonce: String, name: String, kind: String, scopes: [String], expiresInMs: Int? = nil) {
        self.`clientNonce` = clientNonce
        self.`name` = name
        self.`kind` = kind
        self.`scopes` = scopes
        self.`expiresInMs` = expiresInMs
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `name`, `kind`, `scopes`, `expiresInMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        self.`scopes` = try c.decode([String].self, forKey: .`scopes`)
        self.`expiresInMs` = try c.decodeOptional(Int.self, forKey: .`expiresInMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`scopes`, forKey: .`scopes`)
        try c.encodeIfPresent(`expiresInMs`, forKey: .`expiresInMs`)
    }
}

public struct IntegrationTokenIssued: Codable, Hashable {
    public var `integration`: IntegrationToken
    public var `token`: String
    public init(integration: IntegrationToken, token: String) {
        self.`integration` = integration
        self.`token` = token
    }
    enum CodingKeys: String, CodingKey { case `integration`, `token` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`integration` = try c.decode(IntegrationToken.self, forKey: .`integration`)
        self.`token` = try c.decode(String.self, forKey: .`token`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`integration`, forKey: .`integration`)
        try c.encode(`token`, forKey: .`token`)
    }
}

public struct SCIMMeta: Codable, Hashable {
    public var `resourceType`: String
    public var `created`: String
    public var `lastModified`: String
    public var `location`: String
    public var `version`: String
    public init(resourceType: String, created: String, lastModified: String, location: String, version: String) {
        self.`resourceType` = resourceType
        self.`created` = created
        self.`lastModified` = lastModified
        self.`location` = location
        self.`version` = version
    }
    enum CodingKeys: String, CodingKey { case `resourceType`, `created`, `lastModified`, `location`, `version` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`resourceType` = try c.decode(String.self, forKey: .`resourceType`)
        guard ["User", "Group"].contains(`resourceType`) else { throw DecodingError.dataCorruptedError(forKey: .`resourceType`, in: c, debugDescription: "Invalid SCIMMeta.resourceType") }
        self.`created` = try c.decode(String.self, forKey: .`created`)
        self.`lastModified` = try c.decode(String.self, forKey: .`lastModified`)
        self.`location` = try c.decode(String.self, forKey: .`location`)
        self.`version` = try c.decode(String.self, forKey: .`version`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`resourceType`, forKey: .`resourceType`)
        try c.encode(`created`, forKey: .`created`)
        try c.encode(`lastModified`, forKey: .`lastModified`)
        try c.encode(`location`, forKey: .`location`)
        try c.encode(`version`, forKey: .`version`)
    }
}

public struct SCIMUser: Codable, Hashable, Identifiable {
    public var `schemas`: [String]
    public var `id`: ID
    public var `externalId`: String?
    public var `userName`: String
    public var `name`: SCIMUserName?
    public var `displayName`: String?
    public var `active`: Bool
    public var `emails`: [SCIMUserEmails]?
    public var `groups`: [SCIMUserGroups]?
    public var `meta`: SCIMMeta
    public init(schemas: [String], id: ID, externalId: String? = nil, userName: String, name: SCIMUserName? = nil, displayName: String? = nil, active: Bool, emails: [SCIMUserEmails]? = nil, groups: [SCIMUserGroups]? = nil, meta: SCIMMeta) {
        self.`schemas` = schemas
        self.`id` = id
        self.`externalId` = externalId
        self.`userName` = userName
        self.`name` = name
        self.`displayName` = displayName
        self.`active` = active
        self.`emails` = emails
        self.`groups` = groups
        self.`meta` = meta
    }
    enum CodingKeys: String, CodingKey { case `schemas`, `id`, `externalId`, `userName`, `name`, `displayName`, `active`, `emails`, `groups`, `meta` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`schemas` = try c.decode([String].self, forKey: .`schemas`)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`externalId` = try c.decodeOptional(String.self, forKey: .`externalId`)
        self.`userName` = try c.decode(String.self, forKey: .`userName`)
        self.`name` = try c.decodeOptional(SCIMUserName.self, forKey: .`name`)
        self.`displayName` = try c.decodeOptional(String.self, forKey: .`displayName`)
        self.`active` = try c.decode(Bool.self, forKey: .`active`)
        self.`emails` = try c.decodeOptional([SCIMUserEmails].self, forKey: .`emails`)
        self.`groups` = try c.decodeOptional([SCIMUserGroups].self, forKey: .`groups`)
        self.`meta` = try c.decode(SCIMMeta.self, forKey: .`meta`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`schemas`, forKey: .`schemas`)
        try c.encode(`id`, forKey: .`id`)
        try c.encodeIfPresent(`externalId`, forKey: .`externalId`)
        try c.encode(`userName`, forKey: .`userName`)
        try c.encodeIfPresent(`name`, forKey: .`name`)
        try c.encodeIfPresent(`displayName`, forKey: .`displayName`)
        try c.encode(`active`, forKey: .`active`)
        try c.encodeIfPresent(`emails`, forKey: .`emails`)
        try c.encodeIfPresent(`groups`, forKey: .`groups`)
        try c.encode(`meta`, forKey: .`meta`)
    }
}

public struct SCIMGroup: Codable, Hashable, Identifiable {
    public var `schemas`: [String]
    public var `id`: ID
    public var `externalId`: String?
    public var `displayName`: String
    public var `members`: [SCIMGroupMembers]
    public var `meta`: SCIMMeta
    public init(schemas: [String], id: ID, externalId: String? = nil, displayName: String, members: [SCIMGroupMembers], meta: SCIMMeta) {
        self.`schemas` = schemas
        self.`id` = id
        self.`externalId` = externalId
        self.`displayName` = displayName
        self.`members` = members
        self.`meta` = meta
    }
    enum CodingKeys: String, CodingKey { case `schemas`, `id`, `externalId`, `displayName`, `members`, `meta` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`schemas` = try c.decode([String].self, forKey: .`schemas`)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`externalId` = try c.decodeOptional(String.self, forKey: .`externalId`)
        self.`displayName` = try c.decode(String.self, forKey: .`displayName`)
        self.`members` = try c.decode([SCIMGroupMembers].self, forKey: .`members`)
        self.`meta` = try c.decode(SCIMMeta.self, forKey: .`meta`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`schemas`, forKey: .`schemas`)
        try c.encode(`id`, forKey: .`id`)
        try c.encodeIfPresent(`externalId`, forKey: .`externalId`)
        try c.encode(`displayName`, forKey: .`displayName`)
        try c.encode(`members`, forKey: .`members`)
        try c.encode(`meta`, forKey: .`meta`)
    }
}

public struct SCIMPatch: Codable, Hashable {
    public var `schemas`: [String]
    public var `Operations`: [SCIMPatchOperations]
    public init(schemas: [String], Operations: [SCIMPatchOperations]) {
        self.`schemas` = schemas
        self.`Operations` = Operations
    }
    enum CodingKeys: String, CodingKey { case `schemas`, `Operations` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`schemas` = try c.decode([String].self, forKey: .`schemas`)
        self.`Operations` = try c.decode([SCIMPatchOperations].self, forKey: .`Operations`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`schemas`, forKey: .`schemas`)
        try c.encode(`Operations`, forKey: .`Operations`)
    }
}

public struct SCIMQuery: Codable, Hashable {
    public var `startIndex`: Int?
    public var `count`: Int?
    public var `filter`: String?
    public var `attributes`: String?
    public var `excludedAttributes`: String?
    public init(startIndex: Int? = nil, count: Int? = nil, filter: String? = nil, attributes: String? = nil, excludedAttributes: String? = nil) {
        self.`startIndex` = startIndex
        self.`count` = count
        self.`filter` = filter
        self.`attributes` = attributes
        self.`excludedAttributes` = excludedAttributes
    }
    enum CodingKeys: String, CodingKey { case `startIndex`, `count`, `filter`, `attributes`, `excludedAttributes` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`startIndex` = try c.decodeOptional(Int.self, forKey: .`startIndex`)
        self.`count` = try c.decodeOptional(Int.self, forKey: .`count`)
        self.`filter` = try c.decodeOptional(String.self, forKey: .`filter`)
        self.`attributes` = try c.decodeOptional(String.self, forKey: .`attributes`)
        self.`excludedAttributes` = try c.decodeOptional(String.self, forKey: .`excludedAttributes`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(`startIndex`, forKey: .`startIndex`)
        try c.encodeIfPresent(`count`, forKey: .`count`)
        try c.encodeIfPresent(`filter`, forKey: .`filter`)
        try c.encodeIfPresent(`attributes`, forKey: .`attributes`)
        try c.encodeIfPresent(`excludedAttributes`, forKey: .`excludedAttributes`)
    }
}

public struct SCIMList<T: Codable & Hashable>: Codable, Hashable {
    public var `schemas`: [String]
    public var `totalResults`: Int
    public var `startIndex`: Int
    public var `itemsPerPage`: Int
    public var `Resources`: [T]
    public init(schemas: [String], totalResults: Int, startIndex: Int, itemsPerPage: Int, Resources: [T]) {
        self.`schemas` = schemas
        self.`totalResults` = totalResults
        self.`startIndex` = startIndex
        self.`itemsPerPage` = itemsPerPage
        self.`Resources` = Resources
    }
    enum CodingKeys: String, CodingKey { case `schemas`, `totalResults`, `startIndex`, `itemsPerPage`, `Resources` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`schemas` = try c.decode([String].self, forKey: .`schemas`)
        self.`totalResults` = try c.decode(Int.self, forKey: .`totalResults`)
        self.`startIndex` = try c.decode(Int.self, forKey: .`startIndex`)
        self.`itemsPerPage` = try c.decode(Int.self, forKey: .`itemsPerPage`)
        self.`Resources` = try c.decode([T].self, forKey: .`Resources`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`schemas`, forKey: .`schemas`)
        try c.encode(`totalResults`, forKey: .`totalResults`)
        try c.encode(`startIndex`, forKey: .`startIndex`)
        try c.encode(`itemsPerPage`, forKey: .`itemsPerPage`)
        try c.encode(`Resources`, forKey: .`Resources`)
    }
}

public struct SCIMError: Codable, Hashable {
    public var `schemas`: [String]
    public var `status`: String
    public var `scimType`: String?
    public var `detail`: String
    public init(schemas: [String], status: String, scimType: String? = nil, detail: String) {
        self.`schemas` = schemas
        self.`status` = status
        self.`scimType` = scimType
        self.`detail` = detail
    }
    enum CodingKeys: String, CodingKey { case `schemas`, `status`, `scimType`, `detail` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`schemas` = try c.decode([String].self, forKey: .`schemas`)
        self.`status` = try c.decode(String.self, forKey: .`status`)
        self.`scimType` = try c.decodeOptional(String.self, forKey: .`scimType`)
        self.`detail` = try c.decode(String.self, forKey: .`detail`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`schemas`, forKey: .`schemas`)
        try c.encode(`status`, forKey: .`status`)
        try c.encodeIfPresent(`scimType`, forKey: .`scimType`)
        try c.encode(`detail`, forKey: .`detail`)
    }
}

public struct SCIMServiceProviderConfig: Codable, Hashable {
    public var `schemas`: [String]
    public var `patch`: SCIMServiceProviderConfigPatch
    public var `bulk`: SCIMServiceProviderConfigBulk
    public var `filter`: SCIMServiceProviderConfigFilter
    public var `changePassword`: SCIMServiceProviderConfigChangePassword
    public var `sort`: SCIMServiceProviderConfigSort
    public var `etag`: SCIMServiceProviderConfigEtag
    public var `authenticationSchemes`: [SCIMServiceProviderConfigAuthenticationSchemes]
    public init(schemas: [String], patch: SCIMServiceProviderConfigPatch, bulk: SCIMServiceProviderConfigBulk, filter: SCIMServiceProviderConfigFilter, changePassword: SCIMServiceProviderConfigChangePassword, sort: SCIMServiceProviderConfigSort, etag: SCIMServiceProviderConfigEtag, authenticationSchemes: [SCIMServiceProviderConfigAuthenticationSchemes]) {
        self.`schemas` = schemas
        self.`patch` = patch
        self.`bulk` = bulk
        self.`filter` = filter
        self.`changePassword` = changePassword
        self.`sort` = sort
        self.`etag` = etag
        self.`authenticationSchemes` = authenticationSchemes
    }
    enum CodingKeys: String, CodingKey { case `schemas`, `patch`, `bulk`, `filter`, `changePassword`, `sort`, `etag`, `authenticationSchemes` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`schemas` = try c.decode([String].self, forKey: .`schemas`)
        self.`patch` = try c.decode(SCIMServiceProviderConfigPatch.self, forKey: .`patch`)
        self.`bulk` = try c.decode(SCIMServiceProviderConfigBulk.self, forKey: .`bulk`)
        self.`filter` = try c.decode(SCIMServiceProviderConfigFilter.self, forKey: .`filter`)
        self.`changePassword` = try c.decode(SCIMServiceProviderConfigChangePassword.self, forKey: .`changePassword`)
        self.`sort` = try c.decode(SCIMServiceProviderConfigSort.self, forKey: .`sort`)
        self.`etag` = try c.decode(SCIMServiceProviderConfigEtag.self, forKey: .`etag`)
        self.`authenticationSchemes` = try c.decode([SCIMServiceProviderConfigAuthenticationSchemes].self, forKey: .`authenticationSchemes`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`schemas`, forKey: .`schemas`)
        try c.encode(`patch`, forKey: .`patch`)
        try c.encode(`bulk`, forKey: .`bulk`)
        try c.encode(`filter`, forKey: .`filter`)
        try c.encode(`changePassword`, forKey: .`changePassword`)
        try c.encode(`sort`, forKey: .`sort`)
        try c.encode(`etag`, forKey: .`etag`)
        try c.encode(`authenticationSchemes`, forKey: .`authenticationSchemes`)
    }
}

public struct SCIMResourceType: Codable, Hashable, Identifiable {
    public var `schemas`: [String]
    public var `id`: String
    public var `name`: String
    public var `endpoint`: String
    public var `schema`: String
    public init(schemas: [String], id: String, name: String, endpoint: String, schema: String) {
        self.`schemas` = schemas
        self.`id` = id
        self.`name` = name
        self.`endpoint` = endpoint
        self.`schema` = schema
    }
    enum CodingKeys: String, CodingKey { case `schemas`, `id`, `name`, `endpoint`, `schema` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`schemas` = try c.decode([String].self, forKey: .`schemas`)
        self.`id` = try c.decode(String.self, forKey: .`id`)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`endpoint` = try c.decode(String.self, forKey: .`endpoint`)
        self.`schema` = try c.decode(String.self, forKey: .`schema`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`schemas`, forKey: .`schemas`)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`endpoint`, forKey: .`endpoint`)
        try c.encode(`schema`, forKey: .`schema`)
    }
}

public struct SCIMSchema: Codable, Hashable, Identifiable {
    public var `schemas`: [String]
    public var `id`: String
    public var `name`: String
    public var `description`: String
    public var `attributes`: [JSONObject]
    public init(schemas: [String], id: String, name: String, description: String, attributes: [JSONObject]) {
        self.`schemas` = schemas
        self.`id` = id
        self.`name` = name
        self.`description` = description
        self.`attributes` = attributes
    }
    enum CodingKeys: String, CodingKey { case `schemas`, `id`, `name`, `description`, `attributes` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`schemas` = try c.decode([String].self, forKey: .`schemas`)
        self.`id` = try c.decode(String.self, forKey: .`id`)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`description` = try c.decode(String.self, forKey: .`description`)
        self.`attributes` = try c.decode([JSONObject].self, forKey: .`attributes`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`schemas`, forKey: .`schemas`)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`description`, forKey: .`description`)
        try c.encode(`attributes`, forKey: .`attributes`)
    }
}

public struct OAuthProviderConfig: Codable, Hashable, Identifiable {
    public var `id`: String
    public var `clientId`: String
    public var `clientSecretRef`: String
    public var `authorizeUrl`: String
    public var `tokenUrl`: String
    public var `scopes`: [String]
    public var `redirectUris`: [String]
    public var `allowedOrigins`: [String]
    public init(id: String, clientId: String, clientSecretRef: String, authorizeUrl: String, tokenUrl: String, scopes: [String], redirectUris: [String], allowedOrigins: [String]) {
        self.`id` = id
        self.`clientId` = clientId
        self.`clientSecretRef` = clientSecretRef
        self.`authorizeUrl` = authorizeUrl
        self.`tokenUrl` = tokenUrl
        self.`scopes` = scopes
        self.`redirectUris` = redirectUris
        self.`allowedOrigins` = allowedOrigins
    }
    enum CodingKeys: String, CodingKey { case `id`, `clientId`, `clientSecretRef`, `authorizeUrl`, `tokenUrl`, `scopes`, `redirectUris`, `allowedOrigins` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(String.self, forKey: .`id`)
        self.`clientId` = try c.decode(String.self, forKey: .`clientId`)
        self.`clientSecretRef` = try c.decode(String.self, forKey: .`clientSecretRef`)
        self.`authorizeUrl` = try c.decode(String.self, forKey: .`authorizeUrl`)
        self.`tokenUrl` = try c.decode(String.self, forKey: .`tokenUrl`)
        self.`scopes` = try c.decode([String].self, forKey: .`scopes`)
        self.`redirectUris` = try c.decode([String].self, forKey: .`redirectUris`)
        self.`allowedOrigins` = try c.decode([String].self, forKey: .`allowedOrigins`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`clientId`, forKey: .`clientId`)
        try c.encode(`clientSecretRef`, forKey: .`clientSecretRef`)
        try c.encode(`authorizeUrl`, forKey: .`authorizeUrl`)
        try c.encode(`tokenUrl`, forKey: .`tokenUrl`)
        try c.encode(`scopes`, forKey: .`scopes`)
        try c.encode(`redirectUris`, forKey: .`redirectUris`)
        try c.encode(`allowedOrigins`, forKey: .`allowedOrigins`)
    }
}

public struct ChannelProviderConfig: Codable, Hashable, Identifiable {
    public var `id`: String
    public var `adapter`: String
    public var `oauth`: OAuthProviderConfig?
    public var `signingSecretRef`: String?
    public var `apiBaseUrl`: String
    public var `accountSecretRef`: String?
    public var `capabilities`: ChannelProviderConfigCapabilities
    public var `supportsBotAppInstall`: Bool
    public init(id: String, adapter: String, oauth: OAuthProviderConfig? = nil, signingSecretRef: String? = nil, apiBaseUrl: String, accountSecretRef: String? = nil, capabilities: ChannelProviderConfigCapabilities, supportsBotAppInstall: Bool) {
        self.`id` = id
        self.`adapter` = adapter
        self.`oauth` = oauth
        self.`signingSecretRef` = signingSecretRef
        self.`apiBaseUrl` = apiBaseUrl
        self.`accountSecretRef` = accountSecretRef
        self.`capabilities` = capabilities
        self.`supportsBotAppInstall` = supportsBotAppInstall
    }
    enum CodingKeys: String, CodingKey { case `id`, `adapter`, `oauth`, `signingSecretRef`, `apiBaseUrl`, `accountSecretRef`, `capabilities`, `supportsBotAppInstall` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(String.self, forKey: .`id`)
        self.`adapter` = try c.decode(String.self, forKey: .`adapter`)
        self.`oauth` = try c.decode(OAuthProviderConfig?.self, forKey: .`oauth`)
        self.`signingSecretRef` = try c.decode(String?.self, forKey: .`signingSecretRef`)
        self.`apiBaseUrl` = try c.decode(String.self, forKey: .`apiBaseUrl`)
        self.`accountSecretRef` = try c.decode(String?.self, forKey: .`accountSecretRef`)
        self.`capabilities` = try c.decode(ChannelProviderConfigCapabilities.self, forKey: .`capabilities`)
        self.`supportsBotAppInstall` = try c.decode(Bool.self, forKey: .`supportsBotAppInstall`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`adapter`, forKey: .`adapter`)
        try c.encode(`oauth`, forKey: .`oauth`)
        try c.encode(`signingSecretRef`, forKey: .`signingSecretRef`)
        try c.encode(`apiBaseUrl`, forKey: .`apiBaseUrl`)
        try c.encode(`accountSecretRef`, forKey: .`accountSecretRef`)
        try c.encode(`capabilities`, forKey: .`capabilities`)
        try c.encode(`supportsBotAppInstall`, forKey: .`supportsBotAppInstall`)
    }
}

public struct EmailProviderConfig: Codable, Hashable, Identifiable {
    public var `id`: String
    public var `domain`: String
    public var `provisioningBaseUrl`: String
    public var `provisioningSecretRef`: String
    public var `immutableAddresses`: Bool
    public var `reservedNames`: [String]
    public var `smtp`: EmailProviderConfigSmtp
    public var `imap`: EmailProviderConfigImap
    public var `signingSecretRef`: String
    public var `supportsUnsubscribe`: Bool
    public init(id: String, domain: String, provisioningBaseUrl: String, provisioningSecretRef: String, immutableAddresses: Bool, reservedNames: [String], smtp: EmailProviderConfigSmtp, imap: EmailProviderConfigImap, signingSecretRef: String, supportsUnsubscribe: Bool) {
        self.`id` = id
        self.`domain` = domain
        self.`provisioningBaseUrl` = provisioningBaseUrl
        self.`provisioningSecretRef` = provisioningSecretRef
        self.`immutableAddresses` = immutableAddresses
        self.`reservedNames` = reservedNames
        self.`smtp` = smtp
        self.`imap` = imap
        self.`signingSecretRef` = signingSecretRef
        self.`supportsUnsubscribe` = supportsUnsubscribe
    }
    enum CodingKeys: String, CodingKey { case `id`, `domain`, `provisioningBaseUrl`, `provisioningSecretRef`, `immutableAddresses`, `reservedNames`, `smtp`, `imap`, `signingSecretRef`, `supportsUnsubscribe` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(String.self, forKey: .`id`)
        self.`domain` = try c.decode(String.self, forKey: .`domain`)
        self.`provisioningBaseUrl` = try c.decode(String.self, forKey: .`provisioningBaseUrl`)
        self.`provisioningSecretRef` = try c.decode(String.self, forKey: .`provisioningSecretRef`)
        self.`immutableAddresses` = try c.decode(Bool.self, forKey: .`immutableAddresses`)
        self.`reservedNames` = try c.decode([String].self, forKey: .`reservedNames`)
        self.`smtp` = try c.decode(EmailProviderConfigSmtp.self, forKey: .`smtp`)
        self.`imap` = try c.decode(EmailProviderConfigImap.self, forKey: .`imap`)
        self.`signingSecretRef` = try c.decode(String.self, forKey: .`signingSecretRef`)
        self.`supportsUnsubscribe` = try c.decode(Bool.self, forKey: .`supportsUnsubscribe`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`domain`, forKey: .`domain`)
        try c.encode(`provisioningBaseUrl`, forKey: .`provisioningBaseUrl`)
        try c.encode(`provisioningSecretRef`, forKey: .`provisioningSecretRef`)
        try c.encode(`immutableAddresses`, forKey: .`immutableAddresses`)
        try c.encode(`reservedNames`, forKey: .`reservedNames`)
        try c.encode(`smtp`, forKey: .`smtp`)
        try c.encode(`imap`, forKey: .`imap`)
        try c.encode(`signingSecretRef`, forKey: .`signingSecretRef`)
        try c.encode(`supportsUnsubscribe`, forKey: .`supportsUnsubscribe`)
    }
}

public struct EventProviderConfig: Codable, Hashable, Identifiable {
    public var `id`: String
    public var `source`: String
    public var `signingSecretRef`: String
    public var `eventNames`: [String]
    public var `routineIds`: [ID]
    public var `principalUserId`: ID
    public var `maxAgeMs`: Int
    public var `eventDefinitions`: [EventDefinition]?
    public init(id: String, source: String, signingSecretRef: String, eventNames: [String], routineIds: [ID], principalUserId: ID, maxAgeMs: Int, eventDefinitions: [EventDefinition]? = nil) {
        self.`id` = id
        self.`source` = source
        self.`signingSecretRef` = signingSecretRef
        self.`eventNames` = eventNames
        self.`routineIds` = routineIds
        self.`principalUserId` = principalUserId
        self.`maxAgeMs` = maxAgeMs
        self.`eventDefinitions` = eventDefinitions
    }
    enum CodingKeys: String, CodingKey { case `id`, `source`, `signingSecretRef`, `eventNames`, `routineIds`, `principalUserId`, `maxAgeMs`, `eventDefinitions` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(String.self, forKey: .`id`)
        self.`source` = try c.decode(String.self, forKey: .`source`)
        self.`signingSecretRef` = try c.decode(String.self, forKey: .`signingSecretRef`)
        self.`eventNames` = try c.decode([String].self, forKey: .`eventNames`)
        self.`routineIds` = try c.decode([ID].self, forKey: .`routineIds`)
        self.`principalUserId` = try c.decode(ID.self, forKey: .`principalUserId`)
        self.`maxAgeMs` = try c.decode(Int.self, forKey: .`maxAgeMs`)
        self.`eventDefinitions` = try c.decodeOptional([EventDefinition].self, forKey: .`eventDefinitions`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`source`, forKey: .`source`)
        try c.encode(`signingSecretRef`, forKey: .`signingSecretRef`)
        try c.encode(`eventNames`, forKey: .`eventNames`)
        try c.encode(`routineIds`, forKey: .`routineIds`)
        try c.encode(`principalUserId`, forKey: .`principalUserId`)
        try c.encode(`maxAgeMs`, forKey: .`maxAgeMs`)
        try c.encodeIfPresent(`eventDefinitions`, forKey: .`eventDefinitions`)
    }
}

public struct HostDriverCommand: Codable, Hashable {
    public var `argv`: [String]
    public var `cwd`: String
    public var `timeoutMs`: Int
    public var `probeArgv`: [String]
    public init(argv: [String], cwd: String, timeoutMs: Int, probeArgv: [String]) {
        self.`argv` = argv
        self.`cwd` = cwd
        self.`timeoutMs` = timeoutMs
        self.`probeArgv` = probeArgv
    }
    enum CodingKeys: String, CodingKey { case `argv`, `cwd`, `timeoutMs`, `probeArgv` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`argv` = try c.decode([String].self, forKey: .`argv`)
        self.`cwd` = try c.decode(String.self, forKey: .`cwd`)
        self.`timeoutMs` = try c.decode(Int.self, forKey: .`timeoutMs`)
        self.`probeArgv` = try c.decode([String].self, forKey: .`probeArgv`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`argv`, forKey: .`argv`)
        try c.encode(`cwd`, forKey: .`cwd`)
        try c.encode(`timeoutMs`, forKey: .`timeoutMs`)
        try c.encode(`probeArgv`, forKey: .`probeArgv`)
    }
}

public struct HostDriverConfig: Codable, Hashable {
    public var `machineId`: ID
    public var `provider`: String
    public var `environmentRoot`: String?
    public var `actions`: [String: HostDriverCommand]
    public var `networkApply`: HostDriverCommand?
    public var `egressApply`: HostDriverCommand?
    public var `setupRun`: HostDriverCommand?
    public var `runtimeDestinations`: [NetworkRule]
    public init(machineId: ID, provider: String, environmentRoot: String? = nil, actions: [String: HostDriverCommand], networkApply: HostDriverCommand? = nil, egressApply: HostDriverCommand? = nil, setupRun: HostDriverCommand? = nil, runtimeDestinations: [NetworkRule]) {
        self.`machineId` = machineId
        self.`provider` = provider
        self.`environmentRoot` = environmentRoot
        self.`actions` = actions
        self.`networkApply` = networkApply
        self.`egressApply` = egressApply
        self.`setupRun` = setupRun
        self.`runtimeDestinations` = runtimeDestinations
    }
    enum CodingKeys: String, CodingKey { case `machineId`, `provider`, `environmentRoot`, `actions`, `networkApply`, `egressApply`, `setupRun`, `runtimeDestinations` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`machineId` = try c.decode(ID.self, forKey: .`machineId`)
        self.`provider` = try c.decode(String.self, forKey: .`provider`)
        self.`environmentRoot` = try c.decode(String?.self, forKey: .`environmentRoot`)
        self.`actions` = try c.decode([String: HostDriverCommand].self, forKey: .`actions`)
        self.`networkApply` = try c.decode(HostDriverCommand?.self, forKey: .`networkApply`)
        self.`egressApply` = try c.decode(HostDriverCommand?.self, forKey: .`egressApply`)
        self.`setupRun` = try c.decode(HostDriverCommand?.self, forKey: .`setupRun`)
        self.`runtimeDestinations` = try c.decode([NetworkRule].self, forKey: .`runtimeDestinations`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`machineId`, forKey: .`machineId`)
        try c.encode(`provider`, forKey: .`provider`)
        try c.encode(`environmentRoot`, forKey: .`environmentRoot`)
        try c.encode(`actions`, forKey: .`actions`)
        try c.encode(`networkApply`, forKey: .`networkApply`)
        try c.encode(`egressApply`, forKey: .`egressApply`)
        try c.encode(`setupRun`, forKey: .`setupRun`)
        try c.encode(`runtimeDestinations`, forKey: .`runtimeDestinations`)
    }
}

public struct OperatorConfiguration: Codable, Hashable {
    public var `version`: Int
    public var `trustedFrontendOrigins`: [String]
    public var `oauthRedirectUris`: [String]
    public var `serverSecrets`: [String: ServerSecretSource]
    public var `channelProviders`: [ChannelProviderConfig]
    public var `emailProviders`: [EmailProviderConfig]
    public var `eventProviders`: [EventProviderConfig]
    public var `hostDrivers`: [HostDriverConfig]
    public var `xProvider`: OperatorConfigurationXProvider?
    public var `exportAllowedOrigins`: [String]
    public var `requiredRuntimeDestinations`: [NetworkRule]
    public var `breakGlassOwnerUserId`: ID?
    public var `connectorProviders`: [ConnectorProviderConfig]?
    public var `approvedPrivateMcpOrigins`: [String]?
    public var `reviewedSetupManifests`: [ReviewedSetupManifest]?
    public init(version: Int, trustedFrontendOrigins: [String], oauthRedirectUris: [String], serverSecrets: [String: ServerSecretSource], channelProviders: [ChannelProviderConfig], emailProviders: [EmailProviderConfig], eventProviders: [EventProviderConfig], hostDrivers: [HostDriverConfig], xProvider: OperatorConfigurationXProvider? = nil, exportAllowedOrigins: [String], requiredRuntimeDestinations: [NetworkRule], breakGlassOwnerUserId: ID? = nil, connectorProviders: [ConnectorProviderConfig]? = nil, approvedPrivateMcpOrigins: [String]? = nil, reviewedSetupManifests: [ReviewedSetupManifest]? = nil) {
        self.`version` = version
        self.`trustedFrontendOrigins` = trustedFrontendOrigins
        self.`oauthRedirectUris` = oauthRedirectUris
        self.`serverSecrets` = serverSecrets
        self.`channelProviders` = channelProviders
        self.`emailProviders` = emailProviders
        self.`eventProviders` = eventProviders
        self.`hostDrivers` = hostDrivers
        self.`xProvider` = xProvider
        self.`exportAllowedOrigins` = exportAllowedOrigins
        self.`requiredRuntimeDestinations` = requiredRuntimeDestinations
        self.`breakGlassOwnerUserId` = breakGlassOwnerUserId
        self.`connectorProviders` = connectorProviders
        self.`approvedPrivateMcpOrigins` = approvedPrivateMcpOrigins
        self.`reviewedSetupManifests` = reviewedSetupManifests
    }
    enum CodingKeys: String, CodingKey { case `version`, `trustedFrontendOrigins`, `oauthRedirectUris`, `serverSecrets`, `channelProviders`, `emailProviders`, `eventProviders`, `hostDrivers`, `xProvider`, `exportAllowedOrigins`, `requiredRuntimeDestinations`, `breakGlassOwnerUserId`, `connectorProviders`, `approvedPrivateMcpOrigins`, `reviewedSetupManifests` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`version` = try c.decode(Int.self, forKey: .`version`)
        guard `version` == 1 else { throw DecodingError.dataCorruptedError(forKey: .`version`, in: c, debugDescription: "Invalid literal OperatorConfiguration.version") }
        self.`trustedFrontendOrigins` = try c.decode([String].self, forKey: .`trustedFrontendOrigins`)
        self.`oauthRedirectUris` = try c.decode([String].self, forKey: .`oauthRedirectUris`)
        self.`serverSecrets` = try c.decode([String: ServerSecretSource].self, forKey: .`serverSecrets`)
        self.`channelProviders` = try c.decode([ChannelProviderConfig].self, forKey: .`channelProviders`)
        self.`emailProviders` = try c.decode([EmailProviderConfig].self, forKey: .`emailProviders`)
        self.`eventProviders` = try c.decode([EventProviderConfig].self, forKey: .`eventProviders`)
        self.`hostDrivers` = try c.decode([HostDriverConfig].self, forKey: .`hostDrivers`)
        self.`xProvider` = try c.decode(OperatorConfigurationXProvider?.self, forKey: .`xProvider`)
        self.`exportAllowedOrigins` = try c.decode([String].self, forKey: .`exportAllowedOrigins`)
        self.`requiredRuntimeDestinations` = try c.decode([NetworkRule].self, forKey: .`requiredRuntimeDestinations`)
        self.`breakGlassOwnerUserId` = try c.decode(ID?.self, forKey: .`breakGlassOwnerUserId`)
        self.`connectorProviders` = try c.decodeOptional([ConnectorProviderConfig].self, forKey: .`connectorProviders`)
        self.`approvedPrivateMcpOrigins` = try c.decodeOptional([String].self, forKey: .`approvedPrivateMcpOrigins`)
        self.`reviewedSetupManifests` = try c.decodeOptional([ReviewedSetupManifest].self, forKey: .`reviewedSetupManifests`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`version`, forKey: .`version`)
        try c.encode(`trustedFrontendOrigins`, forKey: .`trustedFrontendOrigins`)
        try c.encode(`oauthRedirectUris`, forKey: .`oauthRedirectUris`)
        try c.encode(`serverSecrets`, forKey: .`serverSecrets`)
        try c.encode(`channelProviders`, forKey: .`channelProviders`)
        try c.encode(`emailProviders`, forKey: .`emailProviders`)
        try c.encode(`eventProviders`, forKey: .`eventProviders`)
        try c.encode(`hostDrivers`, forKey: .`hostDrivers`)
        try c.encode(`xProvider`, forKey: .`xProvider`)
        try c.encode(`exportAllowedOrigins`, forKey: .`exportAllowedOrigins`)
        try c.encode(`requiredRuntimeDestinations`, forKey: .`requiredRuntimeDestinations`)
        try c.encode(`breakGlassOwnerUserId`, forKey: .`breakGlassOwnerUserId`)
        try c.encodeIfPresent(`connectorProviders`, forKey: .`connectorProviders`)
        try c.encodeIfPresent(`approvedPrivateMcpOrigins`, forKey: .`approvedPrivateMcpOrigins`)
        try c.encodeIfPresent(`reviewedSetupManifests`, forKey: .`reviewedSetupManifests`)
    }
}

public typealias Role = String

public typealias ErrorCode = String

public typealias ConversationKind = String

public struct Reference: Codable, Hashable, Identifiable {
    public var `kind`: String
    public var `id`: ID
    public init(kind: String, id: ID) {
        self.`kind` = kind
        self.`id` = id
    }
    enum CodingKeys: String, CodingKey { case `kind`, `id` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["bot", "routine", "skill", "connector", "group"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid Reference.kind") }
        self.`id` = try c.decode(ID.self, forKey: .`id`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`id`, forKey: .`id`)
    }
}

public struct Actor: Codable, Hashable, Identifiable {
    public var `kind`: String
    public var `id`: String?
    public var `displayName`: String
    public init(kind: String, id: String? = nil, displayName: String) {
        self.`kind` = kind
        self.`id` = id
        self.`displayName` = displayName
    }
    enum CodingKeys: String, CodingKey { case `kind`, `id`, `displayName` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["user", "bot", "system"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid Actor.kind") }
        self.`id` = try c.decode(String?.self, forKey: .`id`)
        self.`displayName` = try c.decode(String.self, forKey: .`displayName`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`displayName`, forKey: .`displayName`)
    }
}

public typealias ResolutionState = String

public typealias ActionCategory = String

public typealias AccessLevel = String

public typealias BotResetScope = String

public typealias HostAction = String

public struct SCIMUserInput: Codable, Hashable {
    public var `schemas`: [String]
    public var `externalId`: String?
    public var `userName`: String
    public var `name`: SCIMUserInputName?
    public var `displayName`: String?
    public var `active`: Bool
    public var `emails`: [SCIMUserInputEmails]?
    public init(schemas: [String], externalId: String? = nil, userName: String, name: SCIMUserInputName? = nil, displayName: String? = nil, active: Bool, emails: [SCIMUserInputEmails]? = nil) {
        self.`schemas` = schemas
        self.`externalId` = externalId
        self.`userName` = userName
        self.`name` = name
        self.`displayName` = displayName
        self.`active` = active
        self.`emails` = emails
    }
    enum CodingKeys: String, CodingKey { case `schemas`, `externalId`, `userName`, `name`, `displayName`, `active`, `emails` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`schemas` = try c.decode([String].self, forKey: .`schemas`)
        self.`externalId` = try c.decodeOptional(String.self, forKey: .`externalId`)
        self.`userName` = try c.decode(String.self, forKey: .`userName`)
        self.`name` = try c.decodeOptional(SCIMUserInputName.self, forKey: .`name`)
        self.`displayName` = try c.decodeOptional(String.self, forKey: .`displayName`)
        self.`active` = try c.decode(Bool.self, forKey: .`active`)
        self.`emails` = try c.decodeOptional([SCIMUserInputEmails].self, forKey: .`emails`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`schemas`, forKey: .`schemas`)
        try c.encodeIfPresent(`externalId`, forKey: .`externalId`)
        try c.encode(`userName`, forKey: .`userName`)
        try c.encodeIfPresent(`name`, forKey: .`name`)
        try c.encodeIfPresent(`displayName`, forKey: .`displayName`)
        try c.encode(`active`, forKey: .`active`)
        try c.encodeIfPresent(`emails`, forKey: .`emails`)
    }
}

public struct SCIMGroupInput: Codable, Hashable {
    public var `schemas`: [String]
    public var `externalId`: String?
    public var `displayName`: String
    public var `members`: [SCIMGroupInputMembers]
    public init(schemas: [String], externalId: String? = nil, displayName: String, members: [SCIMGroupInputMembers]) {
        self.`schemas` = schemas
        self.`externalId` = externalId
        self.`displayName` = displayName
        self.`members` = members
    }
    enum CodingKeys: String, CodingKey { case `schemas`, `externalId`, `displayName`, `members` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`schemas` = try c.decode([String].self, forKey: .`schemas`)
        self.`externalId` = try c.decodeOptional(String.self, forKey: .`externalId`)
        self.`displayName` = try c.decode(String.self, forKey: .`displayName`)
        self.`members` = try c.decode([SCIMGroupInputMembers].self, forKey: .`members`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`schemas`, forKey: .`schemas`)
        try c.encodeIfPresent(`externalId`, forKey: .`externalId`)
        try c.encode(`displayName`, forKey: .`displayName`)
        try c.encode(`members`, forKey: .`members`)
    }
}

public struct TranscriptEventNameChanged: Codable, Hashable {
    public var `type`: String
    public var `name`: String
    public init(name: String) {
        self.`type` = "name_changed"
        self.`name` = name
    }
    enum CodingKeys: String, CodingKey { case `type`, `name` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["name_changed"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid TranscriptEventNameChanged.type") }
        self.`name` = try c.decode(String.self, forKey: .`name`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`name`, forKey: .`name`)
    }
}

public struct TranscriptEventChannelConnected: Codable, Hashable {
    public var `type`: String
    public var `channelBindingId`: ID
    public init(channelBindingId: ID) {
        self.`type` = "channel_connected"
        self.`channelBindingId` = channelBindingId
    }
    enum CodingKeys: String, CodingKey { case `type`, `channelBindingId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["channel_connected"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid TranscriptEventChannelConnected.type") }
        self.`channelBindingId` = try c.decode(ID.self, forKey: .`channelBindingId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`channelBindingId`, forKey: .`channelBindingId`)
    }
}

public struct TranscriptEventChannelDisconnected: Codable, Hashable {
    public var `type`: String
    public var `channelBindingId`: ID
    public init(channelBindingId: ID) {
        self.`type` = "channel_disconnected"
        self.`channelBindingId` = channelBindingId
    }
    enum CodingKeys: String, CodingKey { case `type`, `channelBindingId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["channel_disconnected"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid TranscriptEventChannelDisconnected.type") }
        self.`channelBindingId` = try c.decode(ID.self, forKey: .`channelBindingId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`channelBindingId`, forKey: .`channelBindingId`)
    }
}

public struct TranscriptEventRoutineChanged: Codable, Hashable {
    public var `type`: String
    public var `routineId`: ID
    public var `action`: String
    public init(routineId: ID, action: String) {
        self.`type` = "routine_changed"
        self.`routineId` = routineId
        self.`action` = action
    }
    enum CodingKeys: String, CodingKey { case `type`, `routineId`, `action` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["routine_changed"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid TranscriptEventRoutineChanged.type") }
        self.`routineId` = try c.decode(ID.self, forKey: .`routineId`)
        self.`action` = try c.decode(String.self, forKey: .`action`)
        guard ["created", "updated", "paused", "resumed", "deleted"].contains(`action`) else { throw DecodingError.dataCorruptedError(forKey: .`action`, in: c, debugDescription: "Invalid TranscriptEventRoutineChanged.action") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`routineId`, forKey: .`routineId`)
        try c.encode(`action`, forKey: .`action`)
    }
}

public struct TranscriptEventTaskChanged: Codable, Hashable {
    public var `type`: String
    public var `conversationId`: ID
    public var `status`: String
    public init(conversationId: ID, status: String) {
        self.`type` = "task_changed"
        self.`conversationId` = conversationId
        self.`status` = status
    }
    enum CodingKeys: String, CodingKey { case `type`, `conversationId`, `status` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["task_changed"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid TranscriptEventTaskChanged.type") }
        self.`conversationId` = try c.decode(ID.self, forKey: .`conversationId`)
        self.`status` = try c.decode(String.self, forKey: .`status`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`conversationId`, forKey: .`conversationId`)
        try c.encode(`status`, forKey: .`status`)
    }
}


public struct TranscriptEventBotAdded: Codable, Hashable {
    public var `type`: String
    public var `botId`: ID
    public init(botId: ID) {
        self.`type` = "bot_added"
        self.`botId` = botId
    }
    enum CodingKeys: String, CodingKey { case `type`, `botId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["bot_added"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid TranscriptEventBotAdded.type") }
        self.`botId` = try c.decode(ID.self, forKey: .`botId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`botId`, forKey: .`botId`)
    }
}

public struct TranscriptEventBotRemoved: Codable, Hashable {
    public var `type`: String
    public var `botId`: ID
    public init(botId: ID) {
        self.`type` = "bot_removed"
        self.`botId` = botId
    }
    enum CodingKeys: String, CodingKey { case `type`, `botId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["bot_removed"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid TranscriptEventBotRemoved.type") }
        self.`botId` = try c.decode(ID.self, forKey: .`botId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`botId`, forKey: .`botId`)
    }
}

public struct TranscriptEventHandoff: Codable, Hashable {
    public var `type`: String
    public var `sourceBotId`: ID
    public var `targetBotId`: ID
    public var `targetConversationId`: ID
    public var `text`: String
    public init(sourceBotId: ID, targetBotId: ID, targetConversationId: ID, text: String) {
        self.`type` = "handoff"
        self.`sourceBotId` = sourceBotId
        self.`targetBotId` = targetBotId
        self.`targetConversationId` = targetConversationId
        self.`text` = text
    }
    enum CodingKeys: String, CodingKey { case `type`, `sourceBotId`, `targetBotId`, `targetConversationId`, `text` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["handoff"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid TranscriptEventHandoff.type") }
        self.`sourceBotId` = try c.decode(ID.self, forKey: .`sourceBotId`)
        self.`targetBotId` = try c.decode(ID.self, forKey: .`targetBotId`)
        self.`targetConversationId` = try c.decode(ID.self, forKey: .`targetConversationId`)
        self.`text` = try c.decode(String.self, forKey: .`text`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`sourceBotId`, forKey: .`sourceBotId`)
        try c.encode(`targetBotId`, forKey: .`targetBotId`)
        try c.encode(`targetConversationId`, forKey: .`targetConversationId`)
        try c.encode(`text`, forKey: .`text`)
    }
}

public struct TranscriptEventMachineMoved: Codable, Hashable {
    public var `type`: String
    public var `botId`: ID
    public var `sourceMachineId`: ID
    public var `targetMachineId`: ID
    public init(botId: ID, sourceMachineId: ID, targetMachineId: ID) {
        self.`type` = "machine_moved"
        self.`botId` = botId
        self.`sourceMachineId` = sourceMachineId
        self.`targetMachineId` = targetMachineId
    }
    enum CodingKeys: String, CodingKey { case `type`, `botId`, `sourceMachineId`, `targetMachineId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["machine_moved"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid TranscriptEventMachineMoved.type") }
        self.`botId` = try c.decode(ID.self, forKey: .`botId`)
        self.`sourceMachineId` = try c.decode(ID.self, forKey: .`sourceMachineId`)
        self.`targetMachineId` = try c.decode(ID.self, forKey: .`targetMachineId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`sourceMachineId`, forKey: .`sourceMachineId`)
        try c.encode(`targetMachineId`, forKey: .`targetMachineId`)
    }
}

public enum TranscriptEvent: Codable, Hashable {
    case `nameChanged`(TranscriptEventNameChanged)
    case `channelConnected`(TranscriptEventChannelConnected)
    case `channelDisconnected`(TranscriptEventChannelDisconnected)
    case `routineChanged`(TranscriptEventRoutineChanged)
    case `taskChanged`(TranscriptEventTaskChanged)
    case `botAdded`(TranscriptEventBotAdded)
    case `botRemoved`(TranscriptEventBotRemoved)
    case `handoff`(TranscriptEventHandoff)
    case `machineMoved`(TranscriptEventMachineMoved)
    private enum CodingKeys: String, CodingKey { case type }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let value = try c.decode(String.self, forKey: .type)
        switch value {
        case "name_changed": self = .`nameChanged`(try TranscriptEventNameChanged(from: decoder))
        case "channel_connected": self = .`channelConnected`(try TranscriptEventChannelConnected(from: decoder))
        case "channel_disconnected": self = .`channelDisconnected`(try TranscriptEventChannelDisconnected(from: decoder))
        case "routine_changed": self = .`routineChanged`(try TranscriptEventRoutineChanged(from: decoder))
        case "task_changed": self = .`taskChanged`(try TranscriptEventTaskChanged(from: decoder))
        case "bot_added": self = .`botAdded`(try TranscriptEventBotAdded(from: decoder))
        case "bot_removed": self = .`botRemoved`(try TranscriptEventBotRemoved(from: decoder))
        case "handoff": self = .`handoff`(try TranscriptEventHandoff(from: decoder))
        case "machine_moved": self = .`machineMoved`(try TranscriptEventMachineMoved(from: decoder))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unsupported TranscriptEvent discriminator: \(value)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .`nameChanged`(let v): try v.encode(to: encoder)
        case .`channelConnected`(let v): try v.encode(to: encoder)
        case .`channelDisconnected`(let v): try v.encode(to: encoder)
        case .`routineChanged`(let v): try v.encode(to: encoder)
        case .`taskChanged`(let v): try v.encode(to: encoder)
        case .`botAdded`(let v): try v.encode(to: encoder)
        case .`botRemoved`(let v): try v.encode(to: encoder)
        case .`handoff`(let v): try v.encode(to: encoder)
        case .`machineMoved`(let v): try v.encode(to: encoder)
        }
    }
    public var type: String {
        switch self {
        case .`nameChanged`: return "name_changed"
        case .`channelConnected`: return "channel_connected"
        case .`channelDisconnected`: return "channel_disconnected"
        case .`routineChanged`: return "routine_changed"
        case .`taskChanged`: return "task_changed"
        case .`botAdded`: return "bot_added"
        case .`botRemoved`: return "bot_removed"
        case .`handoff`: return "handoff"
        case .`machineMoved`: return "machine_moved"
        }
    }
}

public struct DraftContentEmail: Codable, Hashable {
    public var `kind`: String
    public var `connectorId`: ID
    public var `from`: String
    public var `to`: [String]
    public var `cc`: [String]
    public var `bcc`: [String]
    public var `subject`: String
    public var `body`: String
    public var `attachmentIds`: [ID]
    public init(connectorId: ID, from: String, to: [String], cc: [String], bcc: [String], subject: String, body: String, attachmentIds: [ID]) {
        self.`kind` = "email"
        self.`connectorId` = connectorId
        self.`from` = from
        self.`to` = to
        self.`cc` = cc
        self.`bcc` = bcc
        self.`subject` = subject
        self.`body` = body
        self.`attachmentIds` = attachmentIds
    }
    enum CodingKeys: String, CodingKey { case `kind`, `connectorId`, `from`, `to`, `cc`, `bcc`, `subject`, `body`, `attachmentIds` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["email"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid DraftContentEmail.kind") }
        self.`connectorId` = try c.decode(ID.self, forKey: .`connectorId`)
        self.`from` = try c.decode(String.self, forKey: .`from`)
        self.`to` = try c.decode([String].self, forKey: .`to`)
        self.`cc` = try c.decode([String].self, forKey: .`cc`)
        self.`bcc` = try c.decode([String].self, forKey: .`bcc`)
        self.`subject` = try c.decode(String.self, forKey: .`subject`)
        self.`body` = try c.decode(String.self, forKey: .`body`)
        self.`attachmentIds` = try c.decode([ID].self, forKey: .`attachmentIds`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`connectorId`, forKey: .`connectorId`)
        try c.encode(`from`, forKey: .`from`)
        try c.encode(`to`, forKey: .`to`)
        try c.encode(`cc`, forKey: .`cc`)
        try c.encode(`bcc`, forKey: .`bcc`)
        try c.encode(`subject`, forKey: .`subject`)
        try c.encode(`body`, forKey: .`body`)
        try c.encode(`attachmentIds`, forKey: .`attachmentIds`)
    }
}

public struct DraftContentSlack: Codable, Hashable {
    public var `kind`: String
    public var `connectorId`: ID
    public var `workspace`: String
    public var `target`: String
    public var `thread`: String?
    public var `body`: String
    public var `attachmentIds`: [ID]
    public init(connectorId: ID, workspace: String, target: String, thread: String? = nil, body: String, attachmentIds: [ID]) {
        self.`kind` = "slack"
        self.`connectorId` = connectorId
        self.`workspace` = workspace
        self.`target` = target
        self.`thread` = thread
        self.`body` = body
        self.`attachmentIds` = attachmentIds
    }
    enum CodingKeys: String, CodingKey { case `kind`, `connectorId`, `workspace`, `target`, `thread`, `body`, `attachmentIds` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["slack"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid DraftContentSlack.kind") }
        self.`connectorId` = try c.decode(ID.self, forKey: .`connectorId`)
        self.`workspace` = try c.decode(String.self, forKey: .`workspace`)
        self.`target` = try c.decode(String.self, forKey: .`target`)
        self.`thread` = try c.decode(String?.self, forKey: .`thread`)
        self.`body` = try c.decode(String.self, forKey: .`body`)
        self.`attachmentIds` = try c.decode([ID].self, forKey: .`attachmentIds`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`connectorId`, forKey: .`connectorId`)
        try c.encode(`workspace`, forKey: .`workspace`)
        try c.encode(`target`, forKey: .`target`)
        try c.encode(`thread`, forKey: .`thread`)
        try c.encode(`body`, forKey: .`body`)
        try c.encode(`attachmentIds`, forKey: .`attachmentIds`)
    }
}

public struct DraftContentMessage: Codable, Hashable {
    public var `kind`: String
    public var `channelBindingId`: ID
    public var `target`: String
    public var `thread`: String?
    public var `body`: String
    public var `attachmentIds`: [ID]
    public init(channelBindingId: ID, target: String, thread: String? = nil, body: String, attachmentIds: [ID]) {
        self.`kind` = "message"
        self.`channelBindingId` = channelBindingId
        self.`target` = target
        self.`thread` = thread
        self.`body` = body
        self.`attachmentIds` = attachmentIds
    }
    enum CodingKeys: String, CodingKey { case `kind`, `channelBindingId`, `target`, `thread`, `body`, `attachmentIds` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["message"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid DraftContentMessage.kind") }
        self.`channelBindingId` = try c.decode(ID.self, forKey: .`channelBindingId`)
        self.`target` = try c.decode(String.self, forKey: .`target`)
        self.`thread` = try c.decode(String?.self, forKey: .`thread`)
        self.`body` = try c.decode(String.self, forKey: .`body`)
        self.`attachmentIds` = try c.decode([ID].self, forKey: .`attachmentIds`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`channelBindingId`, forKey: .`channelBindingId`)
        try c.encode(`target`, forKey: .`target`)
        try c.encode(`thread`, forKey: .`thread`)
        try c.encode(`body`, forKey: .`body`)
        try c.encode(`attachmentIds`, forKey: .`attachmentIds`)
    }
}

public enum DraftContent: Codable, Hashable {
    case `email`(DraftContentEmail)
    case `slack`(DraftContentSlack)
    case `message`(DraftContentMessage)
    private enum CodingKeys: String, CodingKey { case kind }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let value = try c.decode(String.self, forKey: .kind)
        switch value {
        case "email": self = .`email`(try DraftContentEmail(from: decoder))
        case "slack": self = .`slack`(try DraftContentSlack(from: decoder))
        case "message": self = .`message`(try DraftContentMessage(from: decoder))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unsupported DraftContent discriminator: \(value)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .`email`(let v): try v.encode(to: encoder)
        case .`slack`(let v): try v.encode(to: encoder)
        case .`message`(let v): try v.encode(to: encoder)
        }
    }
    public var kind: String {
        switch self {
        case .`email`: return "email"
        case .`slack`: return "slack"
        case .`message`: return "message"
        }
    }
}

public struct CardText: Codable, Hashable {
    public var `type`: String
    public var `text`: String
    public init(text: String) {
        self.`type` = "text"
        self.`text` = text
    }
    enum CodingKeys: String, CodingKey { case `type`, `text` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["text"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid CardText.type") }
        self.`text` = try c.decode(String.self, forKey: .`text`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`text`, forKey: .`text`)
    }
}

public struct CardAttachment: Codable, Hashable {
    public var `type`: String
    public var `attachmentId`: ID
    public var `caption`: String
    public init(attachmentId: ID, caption: String) {
        self.`type` = "attachment"
        self.`attachmentId` = attachmentId
        self.`caption` = caption
    }
    enum CodingKeys: String, CodingKey { case `type`, `attachmentId`, `caption` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["attachment"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid CardAttachment.type") }
        self.`attachmentId` = try c.decode(ID.self, forKey: .`attachmentId`)
        self.`caption` = try c.decode(String.self, forKey: .`caption`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`attachmentId`, forKey: .`attachmentId`)
        try c.encode(`caption`, forKey: .`caption`)
    }
}

public struct CardLink: Codable, Hashable {
    public var `type`: String
    public var `url`: String
    public var `title`: String
    public var `description`: String
    public init(url: String, title: String, description: String) {
        self.`type` = "link"
        self.`url` = url
        self.`title` = title
        self.`description` = description
    }
    enum CodingKeys: String, CodingKey { case `type`, `url`, `title`, `description` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["link"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid CardLink.type") }
        self.`url` = try c.decode(String.self, forKey: .`url`)
        self.`title` = try c.decode(String.self, forKey: .`title`)
        self.`description` = try c.decode(String.self, forKey: .`description`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`url`, forKey: .`url`)
        try c.encode(`title`, forKey: .`title`)
        try c.encode(`description`, forKey: .`description`)
    }
}

public struct CardWidget: Codable, Hashable {
    public var `type`: String
    public var `questionId`: ID
    public var `prompt`: String
    public var `options`: [CardWidgetOptions]
    public var `multiSelect`: Bool
    public var `gate`: Gate
    public init(questionId: ID, prompt: String, options: [CardWidgetOptions], multiSelect: Bool, gate: Gate) {
        self.`type` = "widget"
        self.`questionId` = questionId
        self.`prompt` = prompt
        self.`options` = options
        self.`multiSelect` = multiSelect
        self.`gate` = gate
    }
    enum CodingKeys: String, CodingKey { case `type`, `questionId`, `prompt`, `options`, `multiSelect`, `gate` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["widget"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid CardWidget.type") }
        self.`questionId` = try c.decode(ID.self, forKey: .`questionId`)
        self.`prompt` = try c.decode(String.self, forKey: .`prompt`)
        self.`options` = try c.decode([CardWidgetOptions].self, forKey: .`options`)
        self.`multiSelect` = try c.decode(Bool.self, forKey: .`multiSelect`)
        self.`gate` = try c.decode(Gate.self, forKey: .`gate`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`questionId`, forKey: .`questionId`)
        try c.encode(`prompt`, forKey: .`prompt`)
        try c.encode(`options`, forKey: .`options`)
        try c.encode(`multiSelect`, forKey: .`multiSelect`)
        try c.encode(`gate`, forKey: .`gate`)
    }
}

public struct CardSecretRequest: Codable, Hashable {
    public var `type`: String
    public var `request`: SecretRequest
    public init(request: SecretRequest) {
        self.`type` = "secret_request"
        self.`request` = request
    }
    enum CodingKeys: String, CodingKey { case `type`, `request` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["secret_request"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid CardSecretRequest.type") }
        self.`request` = try c.decode(SecretRequest.self, forKey: .`request`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`request`, forKey: .`request`)
    }
}

public struct CardHumanStep: Codable, Hashable {
    public var `type`: String
    public var `step`: HumanStep
    public init(step: HumanStep) {
        self.`type` = "human_step"
        self.`step` = step
    }
    enum CodingKeys: String, CodingKey { case `type`, `step` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["human_step"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid CardHumanStep.type") }
        self.`step` = try c.decode(HumanStep.self, forKey: .`step`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`step`, forKey: .`step`)
    }
}

public struct CardUserForm: Codable, Hashable {
    public var `type`: String
    public var `question`: Question
    public init(question: Question) {
        self.`type` = "user_form"
        self.`question` = question
    }
    enum CodingKeys: String, CodingKey { case `type`, `question` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["user_form"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid CardUserForm.type") }
        self.`question` = try c.decode(Question.self, forKey: .`question`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`question`, forKey: .`question`)
    }
}

public struct CardEmailDraft: Codable, Hashable {
    public var `type`: String
    public var `draft`: Draft
    public init(draft: Draft) {
        self.`type` = "email_draft"
        self.`draft` = draft
    }
    enum CodingKeys: String, CodingKey { case `type`, `draft` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["email_draft"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid CardEmailDraft.type") }
        self.`draft` = try c.decode(Draft.self, forKey: .`draft`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`draft`, forKey: .`draft`)
    }
}

public struct CardSlackDraft: Codable, Hashable {
    public var `type`: String
    public var `draft`: Draft
    public init(draft: Draft) {
        self.`type` = "slack_draft"
        self.`draft` = draft
    }
    enum CodingKeys: String, CodingKey { case `type`, `draft` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["slack_draft"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid CardSlackDraft.type") }
        self.`draft` = try c.decode(Draft.self, forKey: .`draft`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`draft`, forKey: .`draft`)
    }
}

public struct CardMessageDraft: Codable, Hashable {
    public var `type`: String
    public var `draft`: Draft
    public init(draft: Draft) {
        self.`type` = "message_draft"
        self.`draft` = draft
    }
    enum CodingKeys: String, CodingKey { case `type`, `draft` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["message_draft"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid CardMessageDraft.type") }
        self.`draft` = try c.decode(Draft.self, forKey: .`draft`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`draft`, forKey: .`draft`)
    }
}

public struct CardCalendarEvent: Codable, Hashable {
    public var `type`: String
    public var `event`: CalendarEvent
    public init(event: CalendarEvent) {
        self.`type` = "calendar_event"
        self.`event` = event
    }
    enum CodingKeys: String, CodingKey { case `type`, `event` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["calendar_event"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid CardCalendarEvent.type") }
        self.`event` = try c.decode(CalendarEvent.self, forKey: .`event`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`event`, forKey: .`event`)
    }
}

public struct CardPermissionRequest: Codable, Hashable {
    public var `type`: String
    public var `approval`: Approval
    public init(approval: Approval) {
        self.`type` = "permission_request"
        self.`approval` = approval
    }
    enum CodingKeys: String, CodingKey { case `type`, `approval` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["permission_request"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid CardPermissionRequest.type") }
        self.`approval` = try c.decode(Approval.self, forKey: .`approval`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`approval`, forKey: .`approval`)
    }
}

public struct CardAutoReviewApproval: Codable, Hashable {
    public var `type`: String
    public var `approval`: Approval
    public init(approval: Approval) {
        self.`type` = "auto_review_approval"
        self.`approval` = approval
    }
    enum CodingKeys: String, CodingKey { case `type`, `approval` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["auto_review_approval"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid CardAutoReviewApproval.type") }
        self.`approval` = try c.decode(Approval.self, forKey: .`approval`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`approval`, forKey: .`approval`)
    }
}

public struct CardLocalToolPermission: Codable, Hashable {
    public var `type`: String
    public var `approval`: Approval
    public init(approval: Approval) {
        self.`type` = "local_tool_permission"
        self.`approval` = approval
    }
    enum CodingKeys: String, CodingKey { case `type`, `approval` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["local_tool_permission"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid CardLocalToolPermission.type") }
        self.`approval` = try c.decode(Approval.self, forKey: .`approval`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`approval`, forKey: .`approval`)
    }
}

public struct CardPublishApproval: Codable, Hashable {
    public var `type`: String
    public var `approval`: Approval
    public init(approval: Approval) {
        self.`type` = "publish_approval"
        self.`approval` = approval
    }
    enum CodingKeys: String, CodingKey { case `type`, `approval` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["publish_approval"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid CardPublishApproval.type") }
        self.`approval` = try c.decode(Approval.self, forKey: .`approval`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`approval`, forKey: .`approval`)
    }
}

public struct CardConnector: Codable, Hashable {
    public var `type`: String
    public var `connector`: Connector
    public init(connector: Connector) {
        self.`type` = "connector"
        self.`connector` = connector
    }
    enum CodingKeys: String, CodingKey { case `type`, `connector` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["connector"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid CardConnector.type") }
        self.`connector` = try c.decode(Connector.self, forKey: .`connector`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`connector`, forKey: .`connector`)
    }
}

public struct CardConnectors: Codable, Hashable {
    public var `type`: String
    public var `connectors`: [Connector]
    public init(connectors: [Connector]) {
        self.`type` = "connectors"
        self.`connectors` = connectors
    }
    enum CodingKeys: String, CodingKey { case `type`, `connectors` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["connectors"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid CardConnectors.type") }
        self.`connectors` = try c.decode([Connector].self, forKey: .`connectors`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`connectors`, forKey: .`connectors`)
    }
}

public struct CardListenerConnect: Codable, Hashable {
    public var `type`: String
    public var `channelBinding`: ChannelBinding
    public init(channelBinding: ChannelBinding) {
        self.`type` = "listener_connect"
        self.`channelBinding` = channelBinding
    }
    enum CodingKeys: String, CodingKey { case `type`, `channelBinding` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["listener_connect"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid CardListenerConnect.type") }
        self.`channelBinding` = try c.decode(ChannelBinding.self, forKey: .`channelBinding`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`channelBinding`, forKey: .`channelBinding`)
    }
}

public struct CardSlackConnect: Codable, Hashable {
    public var `type`: String
    public var `channelBinding`: ChannelBinding
    public init(channelBinding: ChannelBinding) {
        self.`type` = "slack_connect"
        self.`channelBinding` = channelBinding
    }
    enum CodingKeys: String, CodingKey { case `type`, `channelBinding` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["slack_connect"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid CardSlackConnect.type") }
        self.`channelBinding` = try c.decode(ChannelBinding.self, forKey: .`channelBinding`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`channelBinding`, forKey: .`channelBinding`)
    }
}

public struct CardScmConnect: Codable, Hashable {
    public var `type`: String
    public var `connectorId`: ID
    public var `provider`: String
    public var `reason`: String
    public init(connectorId: ID, provider: String, reason: String) {
        self.`type` = "scm_connect"
        self.`connectorId` = connectorId
        self.`provider` = provider
        self.`reason` = reason
    }
    enum CodingKeys: String, CodingKey { case `type`, `connectorId`, `provider`, `reason` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["scm_connect"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid CardScmConnect.type") }
        self.`connectorId` = try c.decode(ID.self, forKey: .`connectorId`)
        self.`provider` = try c.decode(String.self, forKey: .`provider`)
        self.`reason` = try c.decode(String.self, forKey: .`reason`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`connectorId`, forKey: .`connectorId`)
        try c.encode(`provider`, forKey: .`provider`)
        try c.encode(`reason`, forKey: .`reason`)
    }
}


public struct CardBotTemplateShare: Codable, Hashable {
    public var `type`: String
    public var `templateId`: ID
    public var `name`: String
    public var `shareUrl`: String
    public var `state`: String
    public init(templateId: ID, name: String, shareUrl: String, state: String) {
        self.`type` = "bot_template_share"
        self.`templateId` = templateId
        self.`name` = name
        self.`shareUrl` = shareUrl
        self.`state` = state
    }
    enum CodingKeys: String, CodingKey { case `type`, `templateId`, `name`, `shareUrl`, `state` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["bot_template_share"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid CardBotTemplateShare.type") }
        self.`templateId` = try c.decode(ID.self, forKey: .`templateId`)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`shareUrl` = try c.decode(String.self, forKey: .`shareUrl`)
        self.`state` = try c.decode(String.self, forKey: .`state`)
        guard ["available", "deleted", "policy_blocked"].contains(`state`) else { throw DecodingError.dataCorruptedError(forKey: .`state`, in: c, debugDescription: "Invalid CardBotTemplateShare.state") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`templateId`, forKey: .`templateId`)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`shareUrl`, forKey: .`shareUrl`)
        try c.encode(`state`, forKey: .`state`)
    }
}


public struct CardVoiceMemo: Codable, Hashable {
    public var `type`: String
    public var `attachmentId`: ID
    public var `transcript`: String
    public var `durationMs`: Int
    public var `peaks`: [Double]
    public init(attachmentId: ID, transcript: String, durationMs: Int, peaks: [Double]) {
        self.`type` = "voice_memo"
        self.`attachmentId` = attachmentId
        self.`transcript` = transcript
        self.`durationMs` = durationMs
        self.`peaks` = peaks
    }
    enum CodingKeys: String, CodingKey { case `type`, `attachmentId`, `transcript`, `durationMs`, `peaks` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["voice_memo"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid CardVoiceMemo.type") }
        self.`attachmentId` = try c.decode(ID.self, forKey: .`attachmentId`)
        self.`transcript` = try c.decode(String.self, forKey: .`transcript`)
        self.`durationMs` = try c.decode(Int.self, forKey: .`durationMs`)
        self.`peaks` = try c.decode([Double].self, forKey: .`peaks`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`attachmentId`, forKey: .`attachmentId`)
        try c.encode(`transcript`, forKey: .`transcript`)
        try c.encode(`durationMs`, forKey: .`durationMs`)
        try c.encode(`peaks`, forKey: .`peaks`)
    }
}

public struct CardHandoff: Codable, Hashable {
    public var `type`: String
    public var `targetBotId`: ID
    public var `targetConversationId`: ID
    public var `text`: String
    public var `state`: String
    public init(targetBotId: ID, targetConversationId: ID, text: String, state: String) {
        self.`type` = "handoff"
        self.`targetBotId` = targetBotId
        self.`targetConversationId` = targetConversationId
        self.`text` = text
        self.`state` = state
    }
    enum CodingKeys: String, CodingKey { case `type`, `targetBotId`, `targetConversationId`, `text`, `state` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["handoff"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid CardHandoff.type") }
        self.`targetBotId` = try c.decode(ID.self, forKey: .`targetBotId`)
        self.`targetConversationId` = try c.decode(ID.self, forKey: .`targetConversationId`)
        self.`text` = try c.decode(String.self, forKey: .`text`)
        self.`state` = try c.decode(String.self, forKey: .`state`)
        guard ["queued", "working", "completed", "failed"].contains(`state`) else { throw DecodingError.dataCorruptedError(forKey: .`state`, in: c, debugDescription: "Invalid CardHandoff.state") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`targetBotId`, forKey: .`targetBotId`)
        try c.encode(`targetConversationId`, forKey: .`targetConversationId`)
        try c.encode(`text`, forKey: .`text`)
        try c.encode(`state`, forKey: .`state`)
    }
}

public enum Card: Codable, Hashable {
    case unsupported(UnsupportedCard)
    case `text`(CardText)
    case `attachment`(CardAttachment)
    case `link`(CardLink)
    case `widget`(CardWidget)
    case `secretRequest`(CardSecretRequest)
    case `humanStep`(CardHumanStep)
    case `userForm`(CardUserForm)
    case `emailDraft`(CardEmailDraft)
    case `slackDraft`(CardSlackDraft)
    case `messageDraft`(CardMessageDraft)
    case `calendarEvent`(CardCalendarEvent)
    case `permissionRequest`(CardPermissionRequest)
    case `autoReviewApproval`(CardAutoReviewApproval)
    case `localToolPermission`(CardLocalToolPermission)
    case `publishApproval`(CardPublishApproval)
    case `connector`(CardConnector)
    case `connectors`(CardConnectors)
    case `listenerConnect`(CardListenerConnect)
    case `slackConnect`(CardSlackConnect)
    case `scmConnect`(CardScmConnect)
    case `botTemplateShare`(CardBotTemplateShare)
    case `voiceMemo`(CardVoiceMemo)
    case `handoff`(CardHandoff)
    private enum CodingKeys: String, CodingKey { case type }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let value = try c.decode(String.self, forKey: .type)
        switch value {
        case "text": self = .`text`(try CardText(from: decoder))
        case "attachment": self = .`attachment`(try CardAttachment(from: decoder))
        case "link": self = .`link`(try CardLink(from: decoder))
        case "widget": self = .`widget`(try CardWidget(from: decoder))
        case "secret_request": self = .`secretRequest`(try CardSecretRequest(from: decoder))
        case "human_step": self = .`humanStep`(try CardHumanStep(from: decoder))
        case "user_form": self = .`userForm`(try CardUserForm(from: decoder))
        case "email_draft": self = .`emailDraft`(try CardEmailDraft(from: decoder))
        case "slack_draft": self = .`slackDraft`(try CardSlackDraft(from: decoder))
        case "message_draft": self = .`messageDraft`(try CardMessageDraft(from: decoder))
        case "calendar_event": self = .`calendarEvent`(try CardCalendarEvent(from: decoder))
        case "permission_request": self = .`permissionRequest`(try CardPermissionRequest(from: decoder))
        case "auto_review_approval": self = .`autoReviewApproval`(try CardAutoReviewApproval(from: decoder))
        case "local_tool_permission": self = .`localToolPermission`(try CardLocalToolPermission(from: decoder))
        case "publish_approval": self = .`publishApproval`(try CardPublishApproval(from: decoder))
        case "connector": self = .`connector`(try CardConnector(from: decoder))
        case "connectors": self = .`connectors`(try CardConnectors(from: decoder))
        case "listener_connect": self = .`listenerConnect`(try CardListenerConnect(from: decoder))
        case "slack_connect": self = .`slackConnect`(try CardSlackConnect(from: decoder))
        case "scm_connect": self = .`scmConnect`(try CardScmConnect(from: decoder))
        case "bot_template_share": self = .`botTemplateShare`(try CardBotTemplateShare(from: decoder))
        case "voice_memo": self = .`voiceMemo`(try CardVoiceMemo(from: decoder))
        case "handoff": self = .`handoff`(try CardHandoff(from: decoder))
        default: self = .unsupported(try UnsupportedCard(from: decoder))
        }
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .unsupported(let v): try v.encode(to: encoder)
        case .`text`(let v): try v.encode(to: encoder)
        case .`attachment`(let v): try v.encode(to: encoder)
        case .`link`(let v): try v.encode(to: encoder)
        case .`widget`(let v): try v.encode(to: encoder)
        case .`secretRequest`(let v): try v.encode(to: encoder)
        case .`humanStep`(let v): try v.encode(to: encoder)
        case .`userForm`(let v): try v.encode(to: encoder)
        case .`emailDraft`(let v): try v.encode(to: encoder)
        case .`slackDraft`(let v): try v.encode(to: encoder)
        case .`messageDraft`(let v): try v.encode(to: encoder)
        case .`calendarEvent`(let v): try v.encode(to: encoder)
        case .`permissionRequest`(let v): try v.encode(to: encoder)
        case .`autoReviewApproval`(let v): try v.encode(to: encoder)
        case .`localToolPermission`(let v): try v.encode(to: encoder)
        case .`publishApproval`(let v): try v.encode(to: encoder)
        case .`connector`(let v): try v.encode(to: encoder)
        case .`connectors`(let v): try v.encode(to: encoder)
        case .`listenerConnect`(let v): try v.encode(to: encoder)
        case .`slackConnect`(let v): try v.encode(to: encoder)
        case .`scmConnect`(let v): try v.encode(to: encoder)
        case .`botTemplateShare`(let v): try v.encode(to: encoder)
        case .`voiceMemo`(let v): try v.encode(to: encoder)
        case .`handoff`(let v): try v.encode(to: encoder)
        }
    }
    public var type: String {
        switch self {
        case .unsupported(let v): return v.type
        case .`text`: return "text"
        case .`attachment`: return "attachment"
        case .`link`: return "link"
        case .`widget`: return "widget"
        case .`secretRequest`: return "secret_request"
        case .`humanStep`: return "human_step"
        case .`userForm`: return "user_form"
        case .`emailDraft`: return "email_draft"
        case .`slackDraft`: return "slack_draft"
        case .`messageDraft`: return "message_draft"
        case .`calendarEvent`: return "calendar_event"
        case .`permissionRequest`: return "permission_request"
        case .`autoReviewApproval`: return "auto_review_approval"
        case .`localToolPermission`: return "local_tool_permission"
        case .`publishApproval`: return "publish_approval"
        case .`connector`: return "connector"
        case .`connectors`: return "connectors"
        case .`listenerConnect`: return "listener_connect"
        case .`slackConnect`: return "slack_connect"
        case .`scmConnect`: return "scm_connect"
        case .`botTemplateShare`: return "bot_template_share"
        case .`voiceMemo`: return "voice_memo"
        case .`handoff`: return "handoff"
        }
    }
}

public struct RoutineTriggerSchedule: Codable, Hashable {
    public var `kind`: String
    public var `cron`: String
    public var `timezone`: String
    public init(cron: String, timezone: String) {
        self.`kind` = "schedule"
        self.`cron` = cron
        self.`timezone` = timezone
    }
    enum CodingKeys: String, CodingKey { case `kind`, `cron`, `timezone` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["schedule"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid RoutineTriggerSchedule.kind") }
        self.`cron` = try c.decode(String.self, forKey: .`cron`)
        self.`timezone` = try c.decode(String.self, forKey: .`timezone`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`cron`, forKey: .`cron`)
        try c.encode(`timezone`, forKey: .`timezone`)
    }
}

public struct RoutineTriggerWebhook: Codable, Hashable {
    public var `kind`: String
    public init() {
        self.`kind` = "webhook"
    }
    enum CodingKeys: String, CodingKey { case `kind` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["webhook"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid RoutineTriggerWebhook.kind") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`kind`, forKey: .`kind`)
    }
}

public struct RoutineTriggerChannelEvent: Codable, Hashable {
    public var `kind`: String
    public var `channelBindingId`: ID
    public var `event`: String
    public var `channel`: String?
    public var `phrase`: String?
    public var `reaction`: String?
    public var `senders`: [String]?
    public var `noisyListenerConsent`: Bool?
    public init(channelBindingId: ID, event: String, channel: String? = nil, phrase: String? = nil, reaction: String? = nil, senders: [String]? = nil, noisyListenerConsent: Bool? = nil) {
        self.`kind` = "channel_event"
        self.`channelBindingId` = channelBindingId
        self.`event` = event
        self.`channel` = channel
        self.`phrase` = phrase
        self.`reaction` = reaction
        self.`senders` = senders
        self.`noisyListenerConsent` = noisyListenerConsent
    }
    enum CodingKeys: String, CodingKey { case `kind`, `channelBindingId`, `event`, `channel`, `phrase`, `reaction`, `senders`, `noisyListenerConsent` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["channel_event"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid RoutineTriggerChannelEvent.kind") }
        self.`channelBindingId` = try c.decode(ID.self, forKey: .`channelBindingId`)
        self.`event` = try c.decode(String.self, forKey: .`event`)
        guard ["mention", "message", "reaction", "email_received"].contains(`event`) else { throw DecodingError.dataCorruptedError(forKey: .`event`, in: c, debugDescription: "Invalid RoutineTriggerChannelEvent.event") }
        self.`channel` = try c.decodeOptional(String.self, forKey: .`channel`)
        self.`phrase` = try c.decodeOptional(String.self, forKey: .`phrase`)
        self.`reaction` = try c.decodeOptional(String.self, forKey: .`reaction`)
        self.`senders` = try c.decodeOptional([String].self, forKey: .`senders`)
        self.`noisyListenerConsent` = try c.decodeOptional(Bool.self, forKey: .`noisyListenerConsent`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`channelBindingId`, forKey: .`channelBindingId`)
        try c.encode(`event`, forKey: .`event`)
        try c.encodeIfPresent(`channel`, forKey: .`channel`)
        try c.encodeIfPresent(`phrase`, forKey: .`phrase`)
        try c.encodeIfPresent(`reaction`, forKey: .`reaction`)
        try c.encodeIfPresent(`senders`, forKey: .`senders`)
        try c.encodeIfPresent(`noisyListenerConsent`, forKey: .`noisyListenerConsent`)
    }
}

public struct RoutineTriggerExternalEvent: Codable, Hashable {
    public var `kind`: String
    public var `source`: String
    public var `eventNames`: [String]
    public var `filters`: JSONObject
    public init(source: String, eventNames: [String], filters: JSONObject) {
        self.`kind` = "external_event"
        self.`source` = source
        self.`eventNames` = eventNames
        self.`filters` = filters
    }
    enum CodingKeys: String, CodingKey { case `kind`, `source`, `eventNames`, `filters` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["external_event"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid RoutineTriggerExternalEvent.kind") }
        self.`source` = try c.decode(String.self, forKey: .`source`)
        guard ["github", "linear", "sentry", "pagerduty"].contains(`source`) else { throw DecodingError.dataCorruptedError(forKey: .`source`, in: c, debugDescription: "Invalid RoutineTriggerExternalEvent.source") }
        self.`eventNames` = try c.decode([String].self, forKey: .`eventNames`)
        self.`filters` = try c.decode(JSONObject.self, forKey: .`filters`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`source`, forKey: .`source`)
        try c.encode(`eventNames`, forKey: .`eventNames`)
        try c.encode(`filters`, forKey: .`filters`)
    }
}

public enum RoutineTrigger: Codable, Hashable {
    case `schedule`(RoutineTriggerSchedule)
    case `webhook`(RoutineTriggerWebhook)
    case `channelEvent`(RoutineTriggerChannelEvent)
    case `externalEvent`(RoutineTriggerExternalEvent)
    private enum CodingKeys: String, CodingKey { case kind }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let value = try c.decode(String.self, forKey: .kind)
        switch value {
        case "schedule": self = .`schedule`(try RoutineTriggerSchedule(from: decoder))
        case "webhook": self = .`webhook`(try RoutineTriggerWebhook(from: decoder))
        case "channel_event": self = .`channelEvent`(try RoutineTriggerChannelEvent(from: decoder))
        case "external_event": self = .`externalEvent`(try RoutineTriggerExternalEvent(from: decoder))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unsupported RoutineTrigger discriminator: \(value)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .`schedule`(let v): try v.encode(to: encoder)
        case .`webhook`(let v): try v.encode(to: encoder)
        case .`channelEvent`(let v): try v.encode(to: encoder)
        case .`externalEvent`(let v): try v.encode(to: encoder)
        }
    }
    public var kind: String {
        switch self {
        case .`schedule`: return "schedule"
        case .`webhook`: return "webhook"
        case .`channelEvent`: return "channel_event"
        case .`externalEvent`: return "external_event"
        }
    }
}

public struct SearchHitBot: Codable, Hashable {
    public var `kind`: String
    public var `bot`: Bot
    public init(bot: Bot) {
        self.`kind` = "bot"
        self.`bot` = bot
    }
    enum CodingKeys: String, CodingKey { case `kind`, `bot` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["bot"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid SearchHitBot.kind") }
        self.`bot` = try c.decode(Bot.self, forKey: .`bot`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`bot`, forKey: .`bot`)
    }
}

public struct SearchHitGroup: Codable, Hashable {
    public var `kind`: String
    public var `conversation`: Conversation
    public init(conversation: Conversation) {
        self.`kind` = "group"
        self.`conversation` = conversation
    }
    enum CodingKeys: String, CodingKey { case `kind`, `conversation` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["group"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid SearchHitGroup.kind") }
        self.`conversation` = try c.decode(Conversation.self, forKey: .`conversation`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`conversation`, forKey: .`conversation`)
    }
}

public struct SearchHitMessage: Codable, Hashable {
    public var `kind`: String
    public var `entry`: TranscriptEntry
    public var `snippet`: String
    public init(entry: TranscriptEntry, snippet: String) {
        self.`kind` = "message"
        self.`entry` = entry
        self.`snippet` = snippet
    }
    enum CodingKeys: String, CodingKey { case `kind`, `entry`, `snippet` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["message"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid SearchHitMessage.kind") }
        self.`entry` = try c.decode(TranscriptEntry.self, forKey: .`entry`)
        self.`snippet` = try c.decode(String.self, forKey: .`snippet`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`entry`, forKey: .`entry`)
        try c.encode(`snippet`, forKey: .`snippet`)
    }
}

public struct SearchHitFile: Codable, Hashable {
    public var `kind`: String
    public var `attachment`: Attachment
    public init(attachment: Attachment) {
        self.`kind` = "file"
        self.`attachment` = attachment
    }
    enum CodingKeys: String, CodingKey { case `kind`, `attachment` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["file"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid SearchHitFile.kind") }
        self.`attachment` = try c.decode(Attachment.self, forKey: .`attachment`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`attachment`, forKey: .`attachment`)
    }
}

public struct SearchHitRoutine: Codable, Hashable {
    public var `kind`: String
    public var `routine`: Routine
    public init(routine: Routine) {
        self.`kind` = "routine"
        self.`routine` = routine
    }
    enum CodingKeys: String, CodingKey { case `kind`, `routine` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["routine"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid SearchHitRoutine.kind") }
        self.`routine` = try c.decode(Routine.self, forKey: .`routine`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`routine`, forKey: .`routine`)
    }
}

public struct SearchHitSkill: Codable, Hashable {
    public var `kind`: String
    public var `skill`: Skill
    public init(skill: Skill) {
        self.`kind` = "skill"
        self.`skill` = skill
    }
    enum CodingKeys: String, CodingKey { case `kind`, `skill` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["skill"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid SearchHitSkill.kind") }
        self.`skill` = try c.decode(Skill.self, forKey: .`skill`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`skill`, forKey: .`skill`)
    }
}

public struct SearchHitMemory: Codable, Hashable {
    public var `kind`: String
    public var `memory`: Memory
    public init(memory: Memory) {
        self.`kind` = "memory"
        self.`memory` = memory
    }
    enum CodingKeys: String, CodingKey { case `kind`, `memory` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["memory"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid SearchHitMemory.kind") }
        self.`memory` = try c.decode(Memory.self, forKey: .`memory`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`memory`, forKey: .`memory`)
    }
}

public enum SearchHit: Codable, Hashable {
    case `bot`(SearchHitBot)
    case `group`(SearchHitGroup)
    case `message`(SearchHitMessage)
    case `file`(SearchHitFile)
    case `routine`(SearchHitRoutine)
    case `skill`(SearchHitSkill)
    case `memory`(SearchHitMemory)
    private enum CodingKeys: String, CodingKey { case kind }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let value = try c.decode(String.self, forKey: .kind)
        switch value {
        case "bot": self = .`bot`(try SearchHitBot(from: decoder))
        case "group": self = .`group`(try SearchHitGroup(from: decoder))
        case "message": self = .`message`(try SearchHitMessage(from: decoder))
        case "file": self = .`file`(try SearchHitFile(from: decoder))
        case "routine": self = .`routine`(try SearchHitRoutine(from: decoder))
        case "skill": self = .`skill`(try SearchHitSkill(from: decoder))
        case "memory": self = .`memory`(try SearchHitMemory(from: decoder))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unsupported SearchHit discriminator: \(value)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .`bot`(let v): try v.encode(to: encoder)
        case .`group`(let v): try v.encode(to: encoder)
        case .`message`(let v): try v.encode(to: encoder)
        case .`file`(let v): try v.encode(to: encoder)
        case .`routine`(let v): try v.encode(to: encoder)
        case .`skill`(let v): try v.encode(to: encoder)
        case .`memory`(let v): try v.encode(to: encoder)
        }
    }
    public var kind: String {
        switch self {
        case .`bot`: return "bot"
        case .`group`: return "group"
        case .`message`: return "message"
        case .`file`: return "file"
        case .`routine`: return "routine"
        case .`skill`: return "skill"
        case .`memory`: return "memory"
        }
    }
}

public struct NotificationTargetEntry: Codable, Hashable {
    public var `kind`: String
    public var `botId`: ID
    public var `conversationId`: ID
    public var `taskConversationId`: ID?
    public var `entryId`: ID
    public init(botId: ID, conversationId: ID, taskConversationId: ID? = nil, entryId: ID) {
        self.`kind` = "entry"
        self.`botId` = botId
        self.`conversationId` = conversationId
        self.`taskConversationId` = taskConversationId
        self.`entryId` = entryId
    }
    enum CodingKeys: String, CodingKey { case `kind`, `botId`, `conversationId`, `taskConversationId`, `entryId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["entry"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid NotificationTargetEntry.kind") }
        self.`botId` = try c.decode(ID.self, forKey: .`botId`)
        self.`conversationId` = try c.decode(ID.self, forKey: .`conversationId`)
        self.`taskConversationId` = try c.decode(ID?.self, forKey: .`taskConversationId`)
        self.`entryId` = try c.decode(ID.self, forKey: .`entryId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`conversationId`, forKey: .`conversationId`)
        try c.encode(`taskConversationId`, forKey: .`taskConversationId`)
        try c.encode(`entryId`, forKey: .`entryId`)
    }
}

public struct NotificationTargetApproval: Codable, Hashable {
    public var `kind`: String
    public var `botId`: ID
    public var `conversationId`: ID
    public var `approvalId`: ID
    public var `entryId`: ID
    public init(botId: ID, conversationId: ID, approvalId: ID, entryId: ID) {
        self.`kind` = "approval"
        self.`botId` = botId
        self.`conversationId` = conversationId
        self.`approvalId` = approvalId
        self.`entryId` = entryId
    }
    enum CodingKeys: String, CodingKey { case `kind`, `botId`, `conversationId`, `approvalId`, `entryId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["approval"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid NotificationTargetApproval.kind") }
        self.`botId` = try c.decode(ID.self, forKey: .`botId`)
        self.`conversationId` = try c.decode(ID.self, forKey: .`conversationId`)
        self.`approvalId` = try c.decode(ID.self, forKey: .`approvalId`)
        self.`entryId` = try c.decode(ID.self, forKey: .`entryId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`conversationId`, forKey: .`conversationId`)
        try c.encode(`approvalId`, forKey: .`approvalId`)
        try c.encode(`entryId`, forKey: .`entryId`)
    }
}

public struct NotificationTargetMachine: Codable, Hashable {
    public var `kind`: String
    public var `machineId`: ID
    public var `botId`: ID?
    public init(machineId: ID, botId: ID? = nil) {
        self.`kind` = "machine"
        self.`machineId` = machineId
        self.`botId` = botId
    }
    enum CodingKeys: String, CodingKey { case `kind`, `machineId`, `botId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["machine"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid NotificationTargetMachine.kind") }
        self.`machineId` = try c.decode(ID.self, forKey: .`machineId`)
        self.`botId` = try c.decode(ID?.self, forKey: .`botId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`machineId`, forKey: .`machineId`)
        try c.encode(`botId`, forKey: .`botId`)
    }
}

public struct NotificationTargetRoutine: Codable, Hashable {
    public var `kind`: String
    public var `botId`: ID
    public var `routineId`: ID
    public var `routineRunId`: ID?
    public init(botId: ID, routineId: ID, routineRunId: ID? = nil) {
        self.`kind` = "routine"
        self.`botId` = botId
        self.`routineId` = routineId
        self.`routineRunId` = routineRunId
    }
    enum CodingKeys: String, CodingKey { case `kind`, `botId`, `routineId`, `routineRunId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["routine"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid NotificationTargetRoutine.kind") }
        self.`botId` = try c.decode(ID.self, forKey: .`botId`)
        self.`routineId` = try c.decode(ID.self, forKey: .`routineId`)
        self.`routineRunId` = try c.decode(ID?.self, forKey: .`routineRunId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`routineId`, forKey: .`routineId`)
        try c.encode(`routineRunId`, forKey: .`routineRunId`)
    }
}

public enum NotificationTarget: Codable, Hashable {
    case `entry`(NotificationTargetEntry)
    case `approval`(NotificationTargetApproval)
    case `machine`(NotificationTargetMachine)
    case `routine`(NotificationTargetRoutine)
    private enum CodingKeys: String, CodingKey { case kind }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let value = try c.decode(String.self, forKey: .kind)
        switch value {
        case "entry": self = .`entry`(try NotificationTargetEntry(from: decoder))
        case "approval": self = .`approval`(try NotificationTargetApproval(from: decoder))
        case "machine": self = .`machine`(try NotificationTargetMachine(from: decoder))
        case "routine": self = .`routine`(try NotificationTargetRoutine(from: decoder))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unsupported NotificationTarget discriminator: \(value)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .`entry`(let v): try v.encode(to: encoder)
        case .`approval`(let v): try v.encode(to: encoder)
        case .`machine`(let v): try v.encode(to: encoder)
        case .`routine`(let v): try v.encode(to: encoder)
        }
    }
    public var kind: String {
        switch self {
        case .`entry`: return "entry"
        case .`approval`: return "approval"
        case .`machine`: return "machine"
        case .`routine`: return "routine"
        }
    }
}

public struct PushRegistrationApns: Codable, Hashable {
    public var `kind`: String
    public var `token`: String
    public var `environment`: String
    public var `topic`: String
    public init(token: String, environment: String, topic: String) {
        self.`kind` = "apns"
        self.`token` = token
        self.`environment` = environment
        self.`topic` = topic
    }
    enum CodingKeys: String, CodingKey { case `kind`, `token`, `environment`, `topic` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["apns"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid PushRegistrationApns.kind") }
        self.`token` = try c.decode(String.self, forKey: .`token`)
        self.`environment` = try c.decode(String.self, forKey: .`environment`)
        guard ["sandbox", "production"].contains(`environment`) else { throw DecodingError.dataCorruptedError(forKey: .`environment`, in: c, debugDescription: "Invalid PushRegistrationApns.environment") }
        self.`topic` = try c.decode(String.self, forKey: .`topic`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`token`, forKey: .`token`)
        try c.encode(`environment`, forKey: .`environment`)
        try c.encode(`topic`, forKey: .`topic`)
    }
}

public struct PushRegistrationWebPush: Codable, Hashable {
    public var `kind`: String
    public var `endpoint`: String
    public var `keys`: PushRegistrationWebPushKeys
    public init(endpoint: String, keys: PushRegistrationWebPushKeys) {
        self.`kind` = "web_push"
        self.`endpoint` = endpoint
        self.`keys` = keys
    }
    enum CodingKeys: String, CodingKey { case `kind`, `endpoint`, `keys` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["web_push"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid PushRegistrationWebPush.kind") }
        self.`endpoint` = try c.decode(String.self, forKey: .`endpoint`)
        self.`keys` = try c.decode(PushRegistrationWebPushKeys.self, forKey: .`keys`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`endpoint`, forKey: .`endpoint`)
        try c.encode(`keys`, forKey: .`keys`)
    }
}

public enum PushRegistration: Codable, Hashable {
    case `apns`(PushRegistrationApns)
    case `webPush`(PushRegistrationWebPush)
    private enum CodingKeys: String, CodingKey { case kind }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let value = try c.decode(String.self, forKey: .kind)
        switch value {
        case "apns": self = .`apns`(try PushRegistrationApns(from: decoder))
        case "web_push": self = .`webPush`(try PushRegistrationWebPush(from: decoder))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unsupported PushRegistration discriminator: \(value)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .`apns`(let v): try v.encode(to: encoder)
        case .`webPush`(let v): try v.encode(to: encoder)
        }
    }
    public var kind: String {
        switch self {
        case .`apns`: return "apns"
        case .`webPush`: return "web_push"
        }
    }
}

public struct ServerSecretSourceEnv: Codable, Hashable {
    public var `kind`: String
    public var `name`: String
    public init(name: String) {
        self.`kind` = "env"
        self.`name` = name
    }
    enum CodingKeys: String, CodingKey { case `kind`, `name` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["env"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid ServerSecretSourceEnv.kind") }
        self.`name` = try c.decode(String.self, forKey: .`name`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`name`, forKey: .`name`)
    }
}

public struct ServerSecretSourceFile: Codable, Hashable {
    public var `kind`: String
    public var `path`: String
    public init(path: String) {
        self.`kind` = "file"
        self.`path` = path
    }
    enum CodingKeys: String, CodingKey { case `kind`, `path` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["file"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid ServerSecretSourceFile.kind") }
        self.`path` = try c.decode(String.self, forKey: .`path`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`path`, forKey: .`path`)
    }
}

public enum ServerSecretSource: Codable, Hashable {
    case `env`(ServerSecretSourceEnv)
    case `file`(ServerSecretSourceFile)
    private enum CodingKeys: String, CodingKey { case kind }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let value = try c.decode(String.self, forKey: .kind)
        switch value {
        case "env": self = .`env`(try ServerSecretSourceEnv(from: decoder))
        case "file": self = .`file`(try ServerSecretSourceFile(from: decoder))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unsupported ServerSecretSource discriminator: \(value)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .`env`(let v): try v.encode(to: encoder)
        case .`file`(let v): try v.encode(to: encoder)
        }
    }
    public var kind: String {
        switch self {
        case .`env`: return "env"
        case .`file`: return "file"
        }
    }
}

public struct CardActionAnswer: Codable, Hashable {
    public var `action`: String
    public var `questionId`: ID
    public var `request`: QuestionResolve
    public init(questionId: ID, request: QuestionResolve) {
        self.`action` = "answer"
        self.`questionId` = questionId
        self.`request` = request
    }
    enum CodingKeys: String, CodingKey { case `action`, `questionId`, `request` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`action` = try c.decode(String.self, forKey: .`action`)
        guard ["answer"].contains(`action`) else { throw DecodingError.dataCorruptedError(forKey: .`action`, in: c, debugDescription: "Invalid CardActionAnswer.action") }
        self.`questionId` = try c.decode(ID.self, forKey: .`questionId`)
        self.`request` = try c.decode(QuestionResolve.self, forKey: .`request`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`action`, forKey: .`action`)
        try c.encode(`questionId`, forKey: .`questionId`)
        try c.encode(`request`, forKey: .`request`)
    }
}

public struct CardActionApprove: Codable, Hashable {
    public var `action`: String
    public var `approvalId`: ID
    public var `request`: ApprovalResolve
    public init(approvalId: ID, request: ApprovalResolve) {
        self.`action` = "approve"
        self.`approvalId` = approvalId
        self.`request` = request
    }
    enum CodingKeys: String, CodingKey { case `action`, `approvalId`, `request` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`action` = try c.decode(String.self, forKey: .`action`)
        guard ["approve"].contains(`action`) else { throw DecodingError.dataCorruptedError(forKey: .`action`, in: c, debugDescription: "Invalid CardActionApprove.action") }
        self.`approvalId` = try c.decode(ID.self, forKey: .`approvalId`)
        self.`request` = try c.decode(ApprovalResolve.self, forKey: .`request`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`action`, forKey: .`action`)
        try c.encode(`approvalId`, forKey: .`approvalId`)
        try c.encode(`request`, forKey: .`request`)
    }
}

public struct CardActionDeny: Codable, Hashable {
    public var `action`: String
    public var `approvalId`: ID
    public var `request`: ApprovalResolve
    public init(approvalId: ID, request: ApprovalResolve) {
        self.`action` = "deny"
        self.`approvalId` = approvalId
        self.`request` = request
    }
    enum CodingKeys: String, CodingKey { case `action`, `approvalId`, `request` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`action` = try c.decode(String.self, forKey: .`action`)
        guard ["deny"].contains(`action`) else { throw DecodingError.dataCorruptedError(forKey: .`action`, in: c, debugDescription: "Invalid CardActionDeny.action") }
        self.`approvalId` = try c.decode(ID.self, forKey: .`approvalId`)
        self.`request` = try c.decode(ApprovalResolve.self, forKey: .`request`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`action`, forKey: .`action`)
        try c.encode(`approvalId`, forKey: .`approvalId`)
        try c.encode(`request`, forKey: .`request`)
    }
}

public struct CardActionHumanDone: Codable, Hashable {
    public var `action`: String
    public var `humanStepId`: ID
    public var `request`: HumanStepResolve
    public init(humanStepId: ID, request: HumanStepResolve) {
        self.`action` = "human_done"
        self.`humanStepId` = humanStepId
        self.`request` = request
    }
    enum CodingKeys: String, CodingKey { case `action`, `humanStepId`, `request` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`action` = try c.decode(String.self, forKey: .`action`)
        guard ["human_done"].contains(`action`) else { throw DecodingError.dataCorruptedError(forKey: .`action`, in: c, debugDescription: "Invalid CardActionHumanDone.action") }
        self.`humanStepId` = try c.decode(ID.self, forKey: .`humanStepId`)
        self.`request` = try c.decode(HumanStepResolve.self, forKey: .`request`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`action`, forKey: .`action`)
        try c.encode(`humanStepId`, forKey: .`humanStepId`)
        try c.encode(`request`, forKey: .`request`)
    }
}

public struct CardActionHumanSkip: Codable, Hashable {
    public var `action`: String
    public var `humanStepId`: ID
    public var `request`: HumanStepResolve
    public init(humanStepId: ID, request: HumanStepResolve) {
        self.`action` = "human_skip"
        self.`humanStepId` = humanStepId
        self.`request` = request
    }
    enum CodingKeys: String, CodingKey { case `action`, `humanStepId`, `request` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`action` = try c.decode(String.self, forKey: .`action`)
        guard ["human_skip"].contains(`action`) else { throw DecodingError.dataCorruptedError(forKey: .`action`, in: c, debugDescription: "Invalid CardActionHumanSkip.action") }
        self.`humanStepId` = try c.decode(ID.self, forKey: .`humanStepId`)
        self.`request` = try c.decode(HumanStepResolve.self, forKey: .`request`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`action`, forKey: .`action`)
        try c.encode(`humanStepId`, forKey: .`humanStepId`)
        try c.encode(`request`, forKey: .`request`)
    }
}

public struct CardActionSecretSave: Codable, Hashable {
    public var `action`: String
    public var `secretRequestId`: ID
    public var `request`: SecretRequestResolve
    public init(secretRequestId: ID, request: SecretRequestResolve) {
        self.`action` = "secret_save"
        self.`secretRequestId` = secretRequestId
        self.`request` = request
    }
    enum CodingKeys: String, CodingKey { case `action`, `secretRequestId`, `request` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`action` = try c.decode(String.self, forKey: .`action`)
        guard ["secret_save"].contains(`action`) else { throw DecodingError.dataCorruptedError(forKey: .`action`, in: c, debugDescription: "Invalid CardActionSecretSave.action") }
        self.`secretRequestId` = try c.decode(ID.self, forKey: .`secretRequestId`)
        self.`request` = try c.decode(SecretRequestResolve.self, forKey: .`request`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`action`, forKey: .`action`)
        try c.encode(`secretRequestId`, forKey: .`secretRequestId`)
        try c.encode(`request`, forKey: .`request`)
    }
}

public struct CardActionSecretDecline: Codable, Hashable {
    public var `action`: String
    public var `secretRequestId`: ID
    public var `request`: SecretRequestResolve
    public init(secretRequestId: ID, request: SecretRequestResolve) {
        self.`action` = "secret_decline"
        self.`secretRequestId` = secretRequestId
        self.`request` = request
    }
    enum CodingKeys: String, CodingKey { case `action`, `secretRequestId`, `request` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`action` = try c.decode(String.self, forKey: .`action`)
        guard ["secret_decline"].contains(`action`) else { throw DecodingError.dataCorruptedError(forKey: .`action`, in: c, debugDescription: "Invalid CardActionSecretDecline.action") }
        self.`secretRequestId` = try c.decode(ID.self, forKey: .`secretRequestId`)
        self.`request` = try c.decode(SecretRequestResolve.self, forKey: .`request`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`action`, forKey: .`action`)
        try c.encode(`secretRequestId`, forKey: .`secretRequestId`)
        try c.encode(`request`, forKey: .`request`)
    }
}

public struct CardActionDraftEdit: Codable, Hashable {
    public var `action`: String
    public var `draftId`: ID
    public var `request`: DraftUpdate
    public init(draftId: ID, request: DraftUpdate) {
        self.`action` = "draft_edit"
        self.`draftId` = draftId
        self.`request` = request
    }
    enum CodingKeys: String, CodingKey { case `action`, `draftId`, `request` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`action` = try c.decode(String.self, forKey: .`action`)
        guard ["draft_edit"].contains(`action`) else { throw DecodingError.dataCorruptedError(forKey: .`action`, in: c, debugDescription: "Invalid CardActionDraftEdit.action") }
        self.`draftId` = try c.decode(ID.self, forKey: .`draftId`)
        self.`request` = try c.decode(DraftUpdate.self, forKey: .`request`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`action`, forKey: .`action`)
        try c.encode(`draftId`, forKey: .`draftId`)
        try c.encode(`request`, forKey: .`request`)
    }
}

public struct CardActionDraftSend: Codable, Hashable {
    public var `action`: String
    public var `draftId`: ID
    public var `request`: DraftSend
    public init(draftId: ID, request: DraftSend) {
        self.`action` = "draft_send"
        self.`draftId` = draftId
        self.`request` = request
    }
    enum CodingKeys: String, CodingKey { case `action`, `draftId`, `request` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`action` = try c.decode(String.self, forKey: .`action`)
        guard ["draft_send"].contains(`action`) else { throw DecodingError.dataCorruptedError(forKey: .`action`, in: c, debugDescription: "Invalid CardActionDraftSend.action") }
        self.`draftId` = try c.decode(ID.self, forKey: .`draftId`)
        self.`request` = try c.decode(DraftSend.self, forKey: .`request`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`action`, forKey: .`action`)
        try c.encode(`draftId`, forKey: .`draftId`)
        try c.encode(`request`, forKey: .`request`)
    }
}

public struct CardActionDraftDiscard: Codable, Hashable {
    public var `action`: String
    public var `draftId`: ID
    public var `request`: Update
    public init(draftId: ID, request: Update) {
        self.`action` = "draft_discard"
        self.`draftId` = draftId
        self.`request` = request
    }
    enum CodingKeys: String, CodingKey { case `action`, `draftId`, `request` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`action` = try c.decode(String.self, forKey: .`action`)
        guard ["draft_discard"].contains(`action`) else { throw DecodingError.dataCorruptedError(forKey: .`action`, in: c, debugDescription: "Invalid CardActionDraftDiscard.action") }
        self.`draftId` = try c.decode(ID.self, forKey: .`draftId`)
        self.`request` = try c.decode(Update.self, forKey: .`request`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`action`, forKey: .`action`)
        try c.encode(`draftId`, forKey: .`draftId`)
        try c.encode(`request`, forKey: .`request`)
    }
}

public struct CardActionConnectorAuthorize: Codable, Hashable {
    public var `action`: String
    public var `connectorId`: ID
    public var `request`: Mutation
    public init(connectorId: ID, request: Mutation) {
        self.`action` = "connector_authorize"
        self.`connectorId` = connectorId
        self.`request` = request
    }
    enum CodingKeys: String, CodingKey { case `action`, `connectorId`, `request` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`action` = try c.decode(String.self, forKey: .`action`)
        guard ["connector_authorize"].contains(`action`) else { throw DecodingError.dataCorruptedError(forKey: .`action`, in: c, debugDescription: "Invalid CardActionConnectorAuthorize.action") }
        self.`connectorId` = try c.decode(ID.self, forKey: .`connectorId`)
        self.`request` = try c.decode(Mutation.self, forKey: .`request`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`action`, forKey: .`action`)
        try c.encode(`connectorId`, forKey: .`connectorId`)
        try c.encode(`request`, forKey: .`request`)
    }
}


public struct CardActionTemplateImport: Codable, Hashable {
    public var `action`: String
    public var `templateId`: ID
    public var `request`: TemplateImport
    public init(templateId: ID, request: TemplateImport) {
        self.`action` = "template_import"
        self.`templateId` = templateId
        self.`request` = request
    }
    enum CodingKeys: String, CodingKey { case `action`, `templateId`, `request` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`action` = try c.decode(String.self, forKey: .`action`)
        guard ["template_import"].contains(`action`) else { throw DecodingError.dataCorruptedError(forKey: .`action`, in: c, debugDescription: "Invalid CardActionTemplateImport.action") }
        self.`templateId` = try c.decode(ID.self, forKey: .`templateId`)
        self.`request` = try c.decode(TemplateImport.self, forKey: .`request`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`action`, forKey: .`action`)
        try c.encode(`templateId`, forKey: .`templateId`)
        try c.encode(`request`, forKey: .`request`)
    }
}


public enum CardAction: Codable, Hashable {
    case `answer`(CardActionAnswer)
    case `approve`(CardActionApprove)
    case `deny`(CardActionDeny)
    case `humanDone`(CardActionHumanDone)
    case `humanSkip`(CardActionHumanSkip)
    case `secretSave`(CardActionSecretSave)
    case `secretDecline`(CardActionSecretDecline)
    case `draftEdit`(CardActionDraftEdit)
    case `draftSend`(CardActionDraftSend)
    case `draftDiscard`(CardActionDraftDiscard)
    case `connectorAuthorize`(CardActionConnectorAuthorize)
    case `templateImport`(CardActionTemplateImport)
    private enum CodingKeys: String, CodingKey { case action }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let value = try c.decode(String.self, forKey: .action)
        switch value {
        case "answer": self = .`answer`(try CardActionAnswer(from: decoder))
        case "approve": self = .`approve`(try CardActionApprove(from: decoder))
        case "deny": self = .`deny`(try CardActionDeny(from: decoder))
        case "human_done": self = .`humanDone`(try CardActionHumanDone(from: decoder))
        case "human_skip": self = .`humanSkip`(try CardActionHumanSkip(from: decoder))
        case "secret_save": self = .`secretSave`(try CardActionSecretSave(from: decoder))
        case "secret_decline": self = .`secretDecline`(try CardActionSecretDecline(from: decoder))
        case "draft_edit": self = .`draftEdit`(try CardActionDraftEdit(from: decoder))
        case "draft_send": self = .`draftSend`(try CardActionDraftSend(from: decoder))
        case "draft_discard": self = .`draftDiscard`(try CardActionDraftDiscard(from: decoder))
        case "connector_authorize": self = .`connectorAuthorize`(try CardActionConnectorAuthorize(from: decoder))
        case "template_import": self = .`templateImport`(try CardActionTemplateImport(from: decoder))
        default: throw DecodingError.dataCorruptedError(forKey: .action, in: c, debugDescription: "Unsupported CardAction discriminator: \(value)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .`answer`(let v): try v.encode(to: encoder)
        case .`approve`(let v): try v.encode(to: encoder)
        case .`deny`(let v): try v.encode(to: encoder)
        case .`humanDone`(let v): try v.encode(to: encoder)
        case .`humanSkip`(let v): try v.encode(to: encoder)
        case .`secretSave`(let v): try v.encode(to: encoder)
        case .`secretDecline`(let v): try v.encode(to: encoder)
        case .`draftEdit`(let v): try v.encode(to: encoder)
        case .`draftSend`(let v): try v.encode(to: encoder)
        case .`draftDiscard`(let v): try v.encode(to: encoder)
        case .`connectorAuthorize`(let v): try v.encode(to: encoder)
        case .`templateImport`(let v): try v.encode(to: encoder)
        }
    }
    public var action: String {
        switch self {
        case .`answer`: return "answer"
        case .`approve`: return "approve"
        case .`deny`: return "deny"
        case .`humanDone`: return "human_done"
        case .`humanSkip`: return "human_skip"
        case .`secretSave`: return "secret_save"
        case .`secretDecline`: return "secret_decline"
        case .`draftEdit`: return "draft_edit"
        case .`draftSend`: return "draft_send"
        case .`draftDiscard`: return "draft_discard"
        case .`connectorAuthorize`: return "connector_authorize"
        case .`templateImport`: return "template_import"
        }
    }
}

public struct RealtimeClientFrameAuth: Codable, Hashable {
    public var `type`: String
    public var `token`: String
    public var `deviceId`: ID?
    public init(token: String, deviceId: ID? = nil) {
        self.`type` = "auth"
        self.`token` = token
        self.`deviceId` = deviceId
    }
    enum CodingKeys: String, CodingKey { case `type`, `token`, `deviceId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["auth"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid RealtimeClientFrameAuth.type") }
        self.`token` = try c.decode(String.self, forKey: .`token`)
        self.`deviceId` = try c.decodeOptional(ID.self, forKey: .`deviceId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`token`, forKey: .`token`)
        try c.encodeIfPresent(`deviceId`, forKey: .`deviceId`)
    }
}

public struct RealtimeClientFrameSubscribe: Codable, Hashable {
    public var `type`: String
    public var `requestId`: String
    public var `cursor`: Cursor?
    public var `conversationIds`: [ID]?
    public init(requestId: String, cursor: Cursor? = nil, conversationIds: [ID]? = nil) {
        self.`type` = "subscribe"
        self.`requestId` = requestId
        self.`cursor` = cursor
        self.`conversationIds` = conversationIds
    }
    enum CodingKeys: String, CodingKey { case `type`, `requestId`, `cursor`, `conversationIds` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["subscribe"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid RealtimeClientFrameSubscribe.type") }
        self.`requestId` = try c.decode(String.self, forKey: .`requestId`)
        self.`cursor` = try c.decodeOptional(Cursor.self, forKey: .`cursor`)
        self.`conversationIds` = try c.decodeOptional([ID].self, forKey: .`conversationIds`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`requestId`, forKey: .`requestId`)
        try c.encodeIfPresent(`cursor`, forKey: .`cursor`)
        try c.encodeIfPresent(`conversationIds`, forKey: .`conversationIds`)
    }
}

public struct RealtimeClientFrameAck: Codable, Hashable {
    public var `type`: String
    public var `cursor`: Cursor
    public init(cursor: Cursor) {
        self.`type` = "ack"
        self.`cursor` = cursor
    }
    enum CodingKeys: String, CodingKey { case `type`, `cursor` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["ack"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid RealtimeClientFrameAck.type") }
        self.`cursor` = try c.decode(Cursor.self, forKey: .`cursor`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`cursor`, forKey: .`cursor`)
    }
}

public struct RealtimeClientFramePing: Codable, Hashable {
    public var `type`: String
    public var `requestId`: String
    public init(requestId: String) {
        self.`type` = "ping"
        self.`requestId` = requestId
    }
    enum CodingKeys: String, CodingKey { case `type`, `requestId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["ping"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid RealtimeClientFramePing.type") }
        self.`requestId` = try c.decode(String.self, forKey: .`requestId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`requestId`, forKey: .`requestId`)
    }
}

public struct RealtimeClientFrameTyping: Codable, Hashable {
    public var `type`: String
    public var `conversationId`: ID
    public var `active`: Bool
    public init(conversationId: ID, active: Bool) {
        self.`type` = "typing"
        self.`conversationId` = conversationId
        self.`active` = active
    }
    enum CodingKeys: String, CodingKey { case `type`, `conversationId`, `active` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["typing"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid RealtimeClientFrameTyping.type") }
        self.`conversationId` = try c.decode(ID.self, forKey: .`conversationId`)
        self.`active` = try c.decode(Bool.self, forKey: .`active`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`conversationId`, forKey: .`conversationId`)
        try c.encode(`active`, forKey: .`active`)
    }
}

public struct RealtimeClientFramePresence: Codable, Hashable {
    public var `type`: String
    public var `foreground`: Bool
    public var `conversationId`: ID?
    public init(foreground: Bool, conversationId: ID? = nil) {
        self.`type` = "presence"
        self.`foreground` = foreground
        self.`conversationId` = conversationId
    }
    enum CodingKeys: String, CodingKey { case `type`, `foreground`, `conversationId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["presence"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid RealtimeClientFramePresence.type") }
        self.`foreground` = try c.decode(Bool.self, forKey: .`foreground`)
        self.`conversationId` = try c.decode(ID?.self, forKey: .`conversationId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`foreground`, forKey: .`foreground`)
        try c.encode(`conversationId`, forKey: .`conversationId`)
    }
}

public struct RealtimeClientFrameTerminalSubscribe: Codable, Hashable {
    public var `type`: String
    public var `terminalId`: ID
    public var `afterSeq`: Int?
    public init(terminalId: ID, afterSeq: Int? = nil) {
        self.`type` = "terminal_subscribe"
        self.`terminalId` = terminalId
        self.`afterSeq` = afterSeq
    }
    enum CodingKeys: String, CodingKey { case `type`, `terminalId`, `afterSeq` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["terminal_subscribe"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid RealtimeClientFrameTerminalSubscribe.type") }
        self.`terminalId` = try c.decode(ID.self, forKey: .`terminalId`)
        self.`afterSeq` = try c.decodeOptional(Int.self, forKey: .`afterSeq`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`terminalId`, forKey: .`terminalId`)
        try c.encodeIfPresent(`afterSeq`, forKey: .`afterSeq`)
    }
}

public struct RealtimeClientFrameVoice: Codable, Hashable {
    public var `type`: String
    public var `voiceSessionId`: ID
    public var `action`: String
    public init(voiceSessionId: ID, action: String) {
        self.`type` = "voice"
        self.`voiceSessionId` = voiceSessionId
        self.`action` = action
    }
    enum CodingKeys: String, CodingKey { case `type`, `voiceSessionId`, `action` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["voice"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid RealtimeClientFrameVoice.type") }
        self.`voiceSessionId` = try c.decode(ID.self, forKey: .`voiceSessionId`)
        self.`action` = try c.decode(String.self, forKey: .`action`)
        guard ["mute", "unmute", "end"].contains(`action`) else { throw DecodingError.dataCorruptedError(forKey: .`action`, in: c, debugDescription: "Invalid RealtimeClientFrameVoice.action") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`voiceSessionId`, forKey: .`voiceSessionId`)
        try c.encode(`action`, forKey: .`action`)
    }
}

public enum RealtimeClientFrame: Codable, Hashable {
    case `auth`(RealtimeClientFrameAuth)
    case `subscribe`(RealtimeClientFrameSubscribe)
    case `ack`(RealtimeClientFrameAck)
    case `ping`(RealtimeClientFramePing)
    case `typing`(RealtimeClientFrameTyping)
    case `presence`(RealtimeClientFramePresence)
    case `terminalSubscribe`(RealtimeClientFrameTerminalSubscribe)
    case `voice`(RealtimeClientFrameVoice)
    private enum CodingKeys: String, CodingKey { case type }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let value = try c.decode(String.self, forKey: .type)
        switch value {
        case "auth": self = .`auth`(try RealtimeClientFrameAuth(from: decoder))
        case "subscribe": self = .`subscribe`(try RealtimeClientFrameSubscribe(from: decoder))
        case "ack": self = .`ack`(try RealtimeClientFrameAck(from: decoder))
        case "ping": self = .`ping`(try RealtimeClientFramePing(from: decoder))
        case "typing": self = .`typing`(try RealtimeClientFrameTyping(from: decoder))
        case "presence": self = .`presence`(try RealtimeClientFramePresence(from: decoder))
        case "terminal_subscribe": self = .`terminalSubscribe`(try RealtimeClientFrameTerminalSubscribe(from: decoder))
        case "voice": self = .`voice`(try RealtimeClientFrameVoice(from: decoder))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unsupported RealtimeClientFrame discriminator: \(value)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .`auth`(let v): try v.encode(to: encoder)
        case .`subscribe`(let v): try v.encode(to: encoder)
        case .`ack`(let v): try v.encode(to: encoder)
        case .`ping`(let v): try v.encode(to: encoder)
        case .`typing`(let v): try v.encode(to: encoder)
        case .`presence`(let v): try v.encode(to: encoder)
        case .`terminalSubscribe`(let v): try v.encode(to: encoder)
        case .`voice`(let v): try v.encode(to: encoder)
        }
    }
    public var type: String {
        switch self {
        case .`auth`: return "auth"
        case .`subscribe`: return "subscribe"
        case .`ack`: return "ack"
        case .`ping`: return "ping"
        case .`typing`: return "typing"
        case .`presence`: return "presence"
        case .`terminalSubscribe`: return "terminal_subscribe"
        case .`voice`: return "voice"
        }
    }
}

public struct RealtimeReady: Codable, Hashable {
    public var `type`: String
    public var `userId`: ID
    public var `workspaceId`: ID
    public var `cursor`: Cursor
    public var `earliestCursor`: Cursor
    public var `heartbeatMs`: Int
    public init(userId: ID, workspaceId: ID, cursor: Cursor, earliestCursor: Cursor, heartbeatMs: Int) {
        self.`type` = "ready"
        self.`userId` = userId
        self.`workspaceId` = workspaceId
        self.`cursor` = cursor
        self.`earliestCursor` = earliestCursor
        self.`heartbeatMs` = heartbeatMs
    }
    enum CodingKeys: String, CodingKey { case `type`, `userId`, `workspaceId`, `cursor`, `earliestCursor`, `heartbeatMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["ready"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid RealtimeReady.type") }
        self.`userId` = try c.decode(ID.self, forKey: .`userId`)
        self.`workspaceId` = try c.decode(ID.self, forKey: .`workspaceId`)
        self.`cursor` = try c.decode(Cursor.self, forKey: .`cursor`)
        self.`earliestCursor` = try c.decode(Cursor.self, forKey: .`earliestCursor`)
        self.`heartbeatMs` = try c.decode(Int.self, forKey: .`heartbeatMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`userId`, forKey: .`userId`)
        try c.encode(`workspaceId`, forKey: .`workspaceId`)
        try c.encode(`cursor`, forKey: .`cursor`)
        try c.encode(`earliestCursor`, forKey: .`earliestCursor`)
        try c.encode(`heartbeatMs`, forKey: .`heartbeatMs`)
    }
}

public struct RealtimeSubscribed: Codable, Hashable {
    public var `type`: String
    public var `requestId`: String
    public var `cursor`: Cursor
    public var `conversationIds`: [ID]
    public init(requestId: String, cursor: Cursor, conversationIds: [ID]) {
        self.`type` = "subscribed"
        self.`requestId` = requestId
        self.`cursor` = cursor
        self.`conversationIds` = conversationIds
    }
    enum CodingKeys: String, CodingKey { case `type`, `requestId`, `cursor`, `conversationIds` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["subscribed"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid RealtimeSubscribed.type") }
        self.`requestId` = try c.decode(String.self, forKey: .`requestId`)
        self.`cursor` = try c.decode(Cursor.self, forKey: .`cursor`)
        self.`conversationIds` = try c.decode([ID].self, forKey: .`conversationIds`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`requestId`, forKey: .`requestId`)
        try c.encode(`cursor`, forKey: .`cursor`)
        try c.encode(`conversationIds`, forKey: .`conversationIds`)
    }
}

public struct RealtimeCaughtUp: Codable, Hashable {
    public var `type`: String
    public var `cursor`: Cursor
    public init(cursor: Cursor) {
        self.`type` = "caught_up"
        self.`cursor` = cursor
    }
    enum CodingKeys: String, CodingKey { case `type`, `cursor` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["caught_up"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid RealtimeCaughtUp.type") }
        self.`cursor` = try c.decode(Cursor.self, forKey: .`cursor`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`cursor`, forKey: .`cursor`)
    }
}

public struct RealtimeWatermark: Codable, Hashable {
    public var `type`: String
    public var `cursor`: Cursor
    public init(cursor: Cursor) {
        self.`type` = "watermark"
        self.`cursor` = cursor
    }
    enum CodingKeys: String, CodingKey { case `type`, `cursor` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["watermark"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid RealtimeWatermark.type") }
        self.`cursor` = try c.decode(Cursor.self, forKey: .`cursor`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`cursor`, forKey: .`cursor`)
    }
}

public struct RealtimePong: Codable, Hashable {
    public var `type`: String
    public var `requestId`: String
    public init(requestId: String) {
        self.`type` = "pong"
        self.`requestId` = requestId
    }
    enum CodingKeys: String, CodingKey { case `type`, `requestId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["pong"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid RealtimePong.type") }
        self.`requestId` = try c.decode(String.self, forKey: .`requestId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`requestId`, forKey: .`requestId`)
    }
}

public struct RealtimeError: Codable, Hashable {
    public var `type`: String
    public var `requestId`: String?
    public var `error`: RealtimeErrorError
    public init(requestId: String? = nil, error: RealtimeErrorError) {
        self.`type` = "error"
        self.`requestId` = requestId
        self.`error` = error
    }
    enum CodingKeys: String, CodingKey { case `type`, `requestId`, `error` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["error"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid RealtimeError.type") }
        self.`requestId` = try c.decodeOptional(String.self, forKey: .`requestId`)
        self.`error` = try c.decode(RealtimeErrorError.self, forKey: .`error`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encodeIfPresent(`requestId`, forKey: .`requestId`)
        try c.encode(`error`, forKey: .`error`)
    }
}

public struct RealtimeTyping: Codable, Hashable {
    public var `type`: String
    public var `conversationId`: ID
    public var `userId`: ID
    public var `active`: Bool
    public var `expiresAtMs`: TimestampMs
    public init(conversationId: ID, userId: ID, active: Bool, expiresAtMs: TimestampMs) {
        self.`type` = "typing"
        self.`conversationId` = conversationId
        self.`userId` = userId
        self.`active` = active
        self.`expiresAtMs` = expiresAtMs
    }
    enum CodingKeys: String, CodingKey { case `type`, `conversationId`, `userId`, `active`, `expiresAtMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["typing"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid RealtimeTyping.type") }
        self.`conversationId` = try c.decode(ID.self, forKey: .`conversationId`)
        self.`userId` = try c.decode(ID.self, forKey: .`userId`)
        self.`active` = try c.decode(Bool.self, forKey: .`active`)
        self.`expiresAtMs` = try c.decode(TimestampMs.self, forKey: .`expiresAtMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`conversationId`, forKey: .`conversationId`)
        try c.encode(`userId`, forKey: .`userId`)
        try c.encode(`active`, forKey: .`active`)
        try c.encode(`expiresAtMs`, forKey: .`expiresAtMs`)
    }
}

public struct TerminalOutput: Codable, Hashable {
    public var `type`: String
    public var `terminalId`: ID
    public var `seq`: Int
    public var `dataBase64`: String
    public init(terminalId: ID, seq: Int, dataBase64: String) {
        self.`type` = "terminal_output"
        self.`terminalId` = terminalId
        self.`seq` = seq
        self.`dataBase64` = dataBase64
    }
    enum CodingKeys: String, CodingKey { case `type`, `terminalId`, `seq`, `dataBase64` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["terminal_output"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid TerminalOutput.type") }
        self.`terminalId` = try c.decode(ID.self, forKey: .`terminalId`)
        self.`seq` = try c.decode(Int.self, forKey: .`seq`)
        self.`dataBase64` = try c.decode(String.self, forKey: .`dataBase64`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`terminalId`, forKey: .`terminalId`)
        try c.encode(`seq`, forKey: .`seq`)
        try c.encode(`dataBase64`, forKey: .`dataBase64`)
    }
}

public struct TerminalExit: Codable, Hashable {
    public var `type`: String
    public var `terminalId`: ID
    public var `code`: Int?
    public init(terminalId: ID, code: Int? = nil) {
        self.`type` = "terminal_exit"
        self.`terminalId` = terminalId
        self.`code` = code
    }
    enum CodingKeys: String, CodingKey { case `type`, `terminalId`, `code` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["terminal_exit"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid TerminalExit.type") }
        self.`terminalId` = try c.decode(ID.self, forKey: .`terminalId`)
        self.`code` = try c.decode(Int?.self, forKey: .`code`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`terminalId`, forKey: .`terminalId`)
        try c.encode(`code`, forKey: .`code`)
    }
}

public struct TerminalGap: Codable, Hashable {
    public var `type`: String
    public var `terminalId`: ID
    public var `earliestSeq`: Int
    public var `latestSeq`: Int
    public init(terminalId: ID, earliestSeq: Int, latestSeq: Int) {
        self.`type` = "terminal_gap"
        self.`terminalId` = terminalId
        self.`earliestSeq` = earliestSeq
        self.`latestSeq` = latestSeq
    }
    enum CodingKeys: String, CodingKey { case `type`, `terminalId`, `earliestSeq`, `latestSeq` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["terminal_gap"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid TerminalGap.type") }
        self.`terminalId` = try c.decode(ID.self, forKey: .`terminalId`)
        self.`earliestSeq` = try c.decode(Int.self, forKey: .`earliestSeq`)
        self.`latestSeq` = try c.decode(Int.self, forKey: .`latestSeq`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`terminalId`, forKey: .`terminalId`)
        try c.encode(`earliestSeq`, forKey: .`earliestSeq`)
        try c.encode(`latestSeq`, forKey: .`latestSeq`)
    }
}

public enum RealtimeServerFrame: Codable, Hashable {
    case `event`(RealtimeEvent)
    case `ready`(RealtimeReady)
    case `subscribed`(RealtimeSubscribed)
    case `caughtUp`(RealtimeCaughtUp)
    case `watermark`(RealtimeWatermark)
    case `pong`(RealtimePong)
    case `error`(RealtimeError)
    case `typing`(RealtimeTyping)
    case `terminalOutput`(TerminalOutput)
    case `terminalExit`(TerminalExit)
    case `terminalGap`(TerminalGap)
    private enum CodingKeys: String, CodingKey { case type }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let value = try c.decode(String.self, forKey: .type)
        switch value {
        case "event": self = .`event`(try RealtimeEvent(from: decoder))
        case "ready": self = .`ready`(try RealtimeReady(from: decoder))
        case "subscribed": self = .`subscribed`(try RealtimeSubscribed(from: decoder))
        case "caught_up": self = .`caughtUp`(try RealtimeCaughtUp(from: decoder))
        case "watermark": self = .`watermark`(try RealtimeWatermark(from: decoder))
        case "pong": self = .`pong`(try RealtimePong(from: decoder))
        case "error": self = .`error`(try RealtimeError(from: decoder))
        case "typing": self = .`typing`(try RealtimeTyping(from: decoder))
        case "terminal_output": self = .`terminalOutput`(try TerminalOutput(from: decoder))
        case "terminal_exit": self = .`terminalExit`(try TerminalExit(from: decoder))
        case "terminal_gap": self = .`terminalGap`(try TerminalGap(from: decoder))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unsupported RealtimeServerFrame discriminator: \(value)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .`event`(let v): try v.encode(to: encoder)
        case .`ready`(let v): try v.encode(to: encoder)
        case .`subscribed`(let v): try v.encode(to: encoder)
        case .`caughtUp`(let v): try v.encode(to: encoder)
        case .`watermark`(let v): try v.encode(to: encoder)
        case .`pong`(let v): try v.encode(to: encoder)
        case .`error`(let v): try v.encode(to: encoder)
        case .`typing`(let v): try v.encode(to: encoder)
        case .`terminalOutput`(let v): try v.encode(to: encoder)
        case .`terminalExit`(let v): try v.encode(to: encoder)
        case .`terminalGap`(let v): try v.encode(to: encoder)
        }
    }
    public var type: String {
        switch self {
        case .`event`: return "event"
        case .`ready`: return "ready"
        case .`subscribed`: return "subscribed"
        case .`caughtUp`: return "caught_up"
        case .`watermark`: return "watermark"
        case .`pong`: return "pong"
        case .`error`: return "error"
        case .`typing`: return "typing"
        case .`terminalOutput`: return "terminal_output"
        case .`terminalExit`: return "terminal_exit"
        case .`terminalGap`: return "terminal_gap"
        }
    }
}

public struct MessageEntry: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `conversationId`: ID
    public var `seq`: Int
    public var `timestampMs`: TimestampMs
    public var `actor`: Actor
    public var `clientNonce`: String?
    public var `batchId`: ID?
    public var `replyToEntryId`: ID?
    public var `runId`: ID?
    public var `targetedUserId`: ID?
    public var `reactions`: [Reaction]
    public var `kind`: String
    public var `role`: String
    public var `text`: String
    public var `streaming`: Bool
    public var `attachmentIds`: [ID]
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, conversationId: ID, seq: Int, timestampMs: TimestampMs, actor: Actor, clientNonce: String? = nil, batchId: ID? = nil, replyToEntryId: ID? = nil, runId: ID? = nil, targetedUserId: ID? = nil, reactions: [Reaction], role: String, text: String, streaming: Bool, attachmentIds: [ID]) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`conversationId` = conversationId
        self.`seq` = seq
        self.`timestampMs` = timestampMs
        self.`actor` = actor
        self.`clientNonce` = clientNonce
        self.`batchId` = batchId
        self.`replyToEntryId` = replyToEntryId
        self.`runId` = runId
        self.`targetedUserId` = targetedUserId
        self.`reactions` = reactions
        self.`kind` = "message"
        self.`role` = role
        self.`text` = text
        self.`streaming` = streaming
        self.`attachmentIds` = attachmentIds
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `conversationId`, `seq`, `timestampMs`, `actor`, `clientNonce`, `batchId`, `replyToEntryId`, `runId`, `targetedUserId`, `reactions`, `kind`, `role`, `text`, `streaming`, `attachmentIds` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`conversationId` = try c.decode(ID.self, forKey: .`conversationId`)
        self.`seq` = try c.decode(Int.self, forKey: .`seq`)
        self.`timestampMs` = try c.decode(TimestampMs.self, forKey: .`timestampMs`)
        self.`actor` = try c.decode(Actor.self, forKey: .`actor`)
        self.`clientNonce` = try c.decode(String?.self, forKey: .`clientNonce`)
        self.`batchId` = try c.decode(ID?.self, forKey: .`batchId`)
        self.`replyToEntryId` = try c.decode(ID?.self, forKey: .`replyToEntryId`)
        self.`runId` = try c.decode(ID?.self, forKey: .`runId`)
        self.`targetedUserId` = try c.decode(ID?.self, forKey: .`targetedUserId`)
        self.`reactions` = try c.decode([Reaction].self, forKey: .`reactions`)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["message"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid MessageEntry.kind") }
        self.`role` = try c.decode(String.self, forKey: .`role`)
        guard ["user", "assistant"].contains(`role`) else { throw DecodingError.dataCorruptedError(forKey: .`role`, in: c, debugDescription: "Invalid MessageEntry.role") }
        self.`text` = try c.decode(String.self, forKey: .`text`)
        self.`streaming` = try c.decode(Bool.self, forKey: .`streaming`)
        self.`attachmentIds` = try c.decode([ID].self, forKey: .`attachmentIds`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`conversationId`, forKey: .`conversationId`)
        try c.encode(`seq`, forKey: .`seq`)
        try c.encode(`timestampMs`, forKey: .`timestampMs`)
        try c.encode(`actor`, forKey: .`actor`)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`batchId`, forKey: .`batchId`)
        try c.encode(`replyToEntryId`, forKey: .`replyToEntryId`)
        try c.encode(`runId`, forKey: .`runId`)
        try c.encode(`targetedUserId`, forKey: .`targetedUserId`)
        try c.encode(`reactions`, forKey: .`reactions`)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`role`, forKey: .`role`)
        try c.encode(`text`, forKey: .`text`)
        try c.encode(`streaming`, forKey: .`streaming`)
        try c.encode(`attachmentIds`, forKey: .`attachmentIds`)
    }
}

public struct CardEntry: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `conversationId`: ID
    public var `seq`: Int
    public var `timestampMs`: TimestampMs
    public var `actor`: Actor
    public var `clientNonce`: String?
    public var `batchId`: ID?
    public var `replyToEntryId`: ID?
    public var `runId`: ID?
    public var `targetedUserId`: ID?
    public var `reactions`: [Reaction]
    public var `kind`: String
    public var `card`: Card
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, conversationId: ID, seq: Int, timestampMs: TimestampMs, actor: Actor, clientNonce: String? = nil, batchId: ID? = nil, replyToEntryId: ID? = nil, runId: ID? = nil, targetedUserId: ID? = nil, reactions: [Reaction], card: Card) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`conversationId` = conversationId
        self.`seq` = seq
        self.`timestampMs` = timestampMs
        self.`actor` = actor
        self.`clientNonce` = clientNonce
        self.`batchId` = batchId
        self.`replyToEntryId` = replyToEntryId
        self.`runId` = runId
        self.`targetedUserId` = targetedUserId
        self.`reactions` = reactions
        self.`kind` = "card"
        self.`card` = card
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `conversationId`, `seq`, `timestampMs`, `actor`, `clientNonce`, `batchId`, `replyToEntryId`, `runId`, `targetedUserId`, `reactions`, `kind`, `card` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`conversationId` = try c.decode(ID.self, forKey: .`conversationId`)
        self.`seq` = try c.decode(Int.self, forKey: .`seq`)
        self.`timestampMs` = try c.decode(TimestampMs.self, forKey: .`timestampMs`)
        self.`actor` = try c.decode(Actor.self, forKey: .`actor`)
        self.`clientNonce` = try c.decode(String?.self, forKey: .`clientNonce`)
        self.`batchId` = try c.decode(ID?.self, forKey: .`batchId`)
        self.`replyToEntryId` = try c.decode(ID?.self, forKey: .`replyToEntryId`)
        self.`runId` = try c.decode(ID?.self, forKey: .`runId`)
        self.`targetedUserId` = try c.decode(ID?.self, forKey: .`targetedUserId`)
        self.`reactions` = try c.decode([Reaction].self, forKey: .`reactions`)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["card"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid CardEntry.kind") }
        self.`card` = try c.decode(Card.self, forKey: .`card`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`conversationId`, forKey: .`conversationId`)
        try c.encode(`seq`, forKey: .`seq`)
        try c.encode(`timestampMs`, forKey: .`timestampMs`)
        try c.encode(`actor`, forKey: .`actor`)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`batchId`, forKey: .`batchId`)
        try c.encode(`replyToEntryId`, forKey: .`replyToEntryId`)
        try c.encode(`runId`, forKey: .`runId`)
        try c.encode(`targetedUserId`, forKey: .`targetedUserId`)
        try c.encode(`reactions`, forKey: .`reactions`)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`card`, forKey: .`card`)
    }
}

public struct UserAttachmentEntry: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `conversationId`: ID
    public var `seq`: Int
    public var `timestampMs`: TimestampMs
    public var `actor`: Actor
    public var `clientNonce`: String?
    public var `batchId`: ID?
    public var `replyToEntryId`: ID?
    public var `runId`: ID?
    public var `targetedUserId`: ID?
    public var `reactions`: [Reaction]
    public var `kind`: String
    public var `attachmentId`: ID
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, conversationId: ID, seq: Int, timestampMs: TimestampMs, actor: Actor, clientNonce: String? = nil, batchId: ID? = nil, replyToEntryId: ID? = nil, runId: ID? = nil, targetedUserId: ID? = nil, reactions: [Reaction], attachmentId: ID) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`conversationId` = conversationId
        self.`seq` = seq
        self.`timestampMs` = timestampMs
        self.`actor` = actor
        self.`clientNonce` = clientNonce
        self.`batchId` = batchId
        self.`replyToEntryId` = replyToEntryId
        self.`runId` = runId
        self.`targetedUserId` = targetedUserId
        self.`reactions` = reactions
        self.`kind` = "user_attachment"
        self.`attachmentId` = attachmentId
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `conversationId`, `seq`, `timestampMs`, `actor`, `clientNonce`, `batchId`, `replyToEntryId`, `runId`, `targetedUserId`, `reactions`, `kind`, `attachmentId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`conversationId` = try c.decode(ID.self, forKey: .`conversationId`)
        self.`seq` = try c.decode(Int.self, forKey: .`seq`)
        self.`timestampMs` = try c.decode(TimestampMs.self, forKey: .`timestampMs`)
        self.`actor` = try c.decode(Actor.self, forKey: .`actor`)
        self.`clientNonce` = try c.decode(String?.self, forKey: .`clientNonce`)
        self.`batchId` = try c.decode(ID?.self, forKey: .`batchId`)
        self.`replyToEntryId` = try c.decode(ID?.self, forKey: .`replyToEntryId`)
        self.`runId` = try c.decode(ID?.self, forKey: .`runId`)
        self.`targetedUserId` = try c.decode(ID?.self, forKey: .`targetedUserId`)
        self.`reactions` = try c.decode([Reaction].self, forKey: .`reactions`)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["user_attachment"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid UserAttachmentEntry.kind") }
        self.`attachmentId` = try c.decode(ID.self, forKey: .`attachmentId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`conversationId`, forKey: .`conversationId`)
        try c.encode(`seq`, forKey: .`seq`)
        try c.encode(`timestampMs`, forKey: .`timestampMs`)
        try c.encode(`actor`, forKey: .`actor`)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`batchId`, forKey: .`batchId`)
        try c.encode(`replyToEntryId`, forKey: .`replyToEntryId`)
        try c.encode(`runId`, forKey: .`runId`)
        try c.encode(`targetedUserId`, forKey: .`targetedUserId`)
        try c.encode(`reactions`, forKey: .`reactions`)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`attachmentId`, forKey: .`attachmentId`)
    }
}

public struct ToolCallEntry: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `conversationId`: ID
    public var `seq`: Int
    public var `timestampMs`: TimestampMs
    public var `actor`: Actor
    public var `clientNonce`: String?
    public var `batchId`: ID?
    public var `replyToEntryId`: ID?
    public var `runId`: ID?
    public var `targetedUserId`: ID?
    public var `reactions`: [Reaction]
    public var `kind`: String
    public var `tool`: String
    public var `title`: String
    public var `status`: String
    public var `detail`: String?
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, conversationId: ID, seq: Int, timestampMs: TimestampMs, actor: Actor, clientNonce: String? = nil, batchId: ID? = nil, replyToEntryId: ID? = nil, runId: ID? = nil, targetedUserId: ID? = nil, reactions: [Reaction], tool: String, title: String, status: String, detail: String? = nil) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`conversationId` = conversationId
        self.`seq` = seq
        self.`timestampMs` = timestampMs
        self.`actor` = actor
        self.`clientNonce` = clientNonce
        self.`batchId` = batchId
        self.`replyToEntryId` = replyToEntryId
        self.`runId` = runId
        self.`targetedUserId` = targetedUserId
        self.`reactions` = reactions
        self.`kind` = "tool_call"
        self.`tool` = tool
        self.`title` = title
        self.`status` = status
        self.`detail` = detail
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `conversationId`, `seq`, `timestampMs`, `actor`, `clientNonce`, `batchId`, `replyToEntryId`, `runId`, `targetedUserId`, `reactions`, `kind`, `tool`, `title`, `status`, `detail` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`conversationId` = try c.decode(ID.self, forKey: .`conversationId`)
        self.`seq` = try c.decode(Int.self, forKey: .`seq`)
        self.`timestampMs` = try c.decode(TimestampMs.self, forKey: .`timestampMs`)
        self.`actor` = try c.decode(Actor.self, forKey: .`actor`)
        self.`clientNonce` = try c.decode(String?.self, forKey: .`clientNonce`)
        self.`batchId` = try c.decode(ID?.self, forKey: .`batchId`)
        self.`replyToEntryId` = try c.decode(ID?.self, forKey: .`replyToEntryId`)
        self.`runId` = try c.decode(ID?.self, forKey: .`runId`)
        self.`targetedUserId` = try c.decode(ID?.self, forKey: .`targetedUserId`)
        self.`reactions` = try c.decode([Reaction].self, forKey: .`reactions`)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["tool_call"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid ToolCallEntry.kind") }
        self.`tool` = try c.decode(String.self, forKey: .`tool`)
        self.`title` = try c.decode(String.self, forKey: .`title`)
        self.`status` = try c.decode(String.self, forKey: .`status`)
        guard ["started", "completed", "failed"].contains(`status`) else { throw DecodingError.dataCorruptedError(forKey: .`status`, in: c, debugDescription: "Invalid ToolCallEntry.status") }
        self.`detail` = try c.decode(String?.self, forKey: .`detail`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`conversationId`, forKey: .`conversationId`)
        try c.encode(`seq`, forKey: .`seq`)
        try c.encode(`timestampMs`, forKey: .`timestampMs`)
        try c.encode(`actor`, forKey: .`actor`)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`batchId`, forKey: .`batchId`)
        try c.encode(`replyToEntryId`, forKey: .`replyToEntryId`)
        try c.encode(`runId`, forKey: .`runId`)
        try c.encode(`targetedUserId`, forKey: .`targetedUserId`)
        try c.encode(`reactions`, forKey: .`reactions`)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`tool`, forKey: .`tool`)
        try c.encode(`title`, forKey: .`title`)
        try c.encode(`status`, forKey: .`status`)
        try c.encode(`detail`, forKey: .`detail`)
    }
}

public struct MCPAppEntry: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `conversationId`: ID
    public var `seq`: Int
    public var `timestampMs`: TimestampMs
    public var `actor`: Actor
    public var `clientNonce`: String?
    public var `batchId`: ID?
    public var `replyToEntryId`: ID?
    public var `runId`: ID?
    public var `targetedUserId`: ID?
    public var `reactions`: [Reaction]
    public var `kind`: String
    public var `connectorId`: ID
    public var `resourceUri`: String
    public var `snapshotAttachmentId`: ID?
    public var `state`: String
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, conversationId: ID, seq: Int, timestampMs: TimestampMs, actor: Actor, clientNonce: String? = nil, batchId: ID? = nil, replyToEntryId: ID? = nil, runId: ID? = nil, targetedUserId: ID? = nil, reactions: [Reaction], connectorId: ID, resourceUri: String, snapshotAttachmentId: ID? = nil, state: String) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`conversationId` = conversationId
        self.`seq` = seq
        self.`timestampMs` = timestampMs
        self.`actor` = actor
        self.`clientNonce` = clientNonce
        self.`batchId` = batchId
        self.`replyToEntryId` = replyToEntryId
        self.`runId` = runId
        self.`targetedUserId` = targetedUserId
        self.`reactions` = reactions
        self.`kind` = "mcp_app"
        self.`connectorId` = connectorId
        self.`resourceUri` = resourceUri
        self.`snapshotAttachmentId` = snapshotAttachmentId
        self.`state` = state
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `conversationId`, `seq`, `timestampMs`, `actor`, `clientNonce`, `batchId`, `replyToEntryId`, `runId`, `targetedUserId`, `reactions`, `kind`, `connectorId`, `resourceUri`, `snapshotAttachmentId`, `state` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`conversationId` = try c.decode(ID.self, forKey: .`conversationId`)
        self.`seq` = try c.decode(Int.self, forKey: .`seq`)
        self.`timestampMs` = try c.decode(TimestampMs.self, forKey: .`timestampMs`)
        self.`actor` = try c.decode(Actor.self, forKey: .`actor`)
        self.`clientNonce` = try c.decode(String?.self, forKey: .`clientNonce`)
        self.`batchId` = try c.decode(ID?.self, forKey: .`batchId`)
        self.`replyToEntryId` = try c.decode(ID?.self, forKey: .`replyToEntryId`)
        self.`runId` = try c.decode(ID?.self, forKey: .`runId`)
        self.`targetedUserId` = try c.decode(ID?.self, forKey: .`targetedUserId`)
        self.`reactions` = try c.decode([Reaction].self, forKey: .`reactions`)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["mcp_app"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid MCPAppEntry.kind") }
        self.`connectorId` = try c.decode(ID.self, forKey: .`connectorId`)
        self.`resourceUri` = try c.decode(String.self, forKey: .`resourceUri`)
        self.`snapshotAttachmentId` = try c.decode(ID?.self, forKey: .`snapshotAttachmentId`)
        self.`state` = try c.decode(String.self, forKey: .`state`)
        guard ["available", "unavailable", "expired"].contains(`state`) else { throw DecodingError.dataCorruptedError(forKey: .`state`, in: c, debugDescription: "Invalid MCPAppEntry.state") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`conversationId`, forKey: .`conversationId`)
        try c.encode(`seq`, forKey: .`seq`)
        try c.encode(`timestampMs`, forKey: .`timestampMs`)
        try c.encode(`actor`, forKey: .`actor`)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`batchId`, forKey: .`batchId`)
        try c.encode(`replyToEntryId`, forKey: .`replyToEntryId`)
        try c.encode(`runId`, forKey: .`runId`)
        try c.encode(`targetedUserId`, forKey: .`targetedUserId`)
        try c.encode(`reactions`, forKey: .`reactions`)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`connectorId`, forKey: .`connectorId`)
        try c.encode(`resourceUri`, forKey: .`resourceUri`)
        try c.encode(`snapshotAttachmentId`, forKey: .`snapshotAttachmentId`)
        try c.encode(`state`, forKey: .`state`)
    }
}

public struct NoticeEntry: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `conversationId`: ID
    public var `seq`: Int
    public var `timestampMs`: TimestampMs
    public var `actor`: Actor
    public var `clientNonce`: String?
    public var `batchId`: ID?
    public var `replyToEntryId`: ID?
    public var `runId`: ID?
    public var `targetedUserId`: ID?
    public var `reactions`: [Reaction]
    public var `kind`: String
    public var `severity`: String
    public var `text`: String
    public var `requestId`: String?
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, conversationId: ID, seq: Int, timestampMs: TimestampMs, actor: Actor, clientNonce: String? = nil, batchId: ID? = nil, replyToEntryId: ID? = nil, runId: ID? = nil, targetedUserId: ID? = nil, reactions: [Reaction], severity: String, text: String, requestId: String? = nil) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`conversationId` = conversationId
        self.`seq` = seq
        self.`timestampMs` = timestampMs
        self.`actor` = actor
        self.`clientNonce` = clientNonce
        self.`batchId` = batchId
        self.`replyToEntryId` = replyToEntryId
        self.`runId` = runId
        self.`targetedUserId` = targetedUserId
        self.`reactions` = reactions
        self.`kind` = "notice"
        self.`severity` = severity
        self.`text` = text
        self.`requestId` = requestId
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `conversationId`, `seq`, `timestampMs`, `actor`, `clientNonce`, `batchId`, `replyToEntryId`, `runId`, `targetedUserId`, `reactions`, `kind`, `severity`, `text`, `requestId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`conversationId` = try c.decode(ID.self, forKey: .`conversationId`)
        self.`seq` = try c.decode(Int.self, forKey: .`seq`)
        self.`timestampMs` = try c.decode(TimestampMs.self, forKey: .`timestampMs`)
        self.`actor` = try c.decode(Actor.self, forKey: .`actor`)
        self.`clientNonce` = try c.decode(String?.self, forKey: .`clientNonce`)
        self.`batchId` = try c.decode(ID?.self, forKey: .`batchId`)
        self.`replyToEntryId` = try c.decode(ID?.self, forKey: .`replyToEntryId`)
        self.`runId` = try c.decode(ID?.self, forKey: .`runId`)
        self.`targetedUserId` = try c.decode(ID?.self, forKey: .`targetedUserId`)
        self.`reactions` = try c.decode([Reaction].self, forKey: .`reactions`)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["notice"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid NoticeEntry.kind") }
        self.`severity` = try c.decode(String.self, forKey: .`severity`)
        guard ["info", "warning", "error"].contains(`severity`) else { throw DecodingError.dataCorruptedError(forKey: .`severity`, in: c, debugDescription: "Invalid NoticeEntry.severity") }
        self.`text` = try c.decode(String.self, forKey: .`text`)
        self.`requestId` = try c.decode(String?.self, forKey: .`requestId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`conversationId`, forKey: .`conversationId`)
        try c.encode(`seq`, forKey: .`seq`)
        try c.encode(`timestampMs`, forKey: .`timestampMs`)
        try c.encode(`actor`, forKey: .`actor`)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`batchId`, forKey: .`batchId`)
        try c.encode(`replyToEntryId`, forKey: .`replyToEntryId`)
        try c.encode(`runId`, forKey: .`runId`)
        try c.encode(`targetedUserId`, forKey: .`targetedUserId`)
        try c.encode(`reactions`, forKey: .`reactions`)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`severity`, forKey: .`severity`)
        try c.encode(`text`, forKey: .`text`)
        try c.encode(`requestId`, forKey: .`requestId`)
    }
}

public struct EventEntry: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `conversationId`: ID
    public var `seq`: Int
    public var `timestampMs`: TimestampMs
    public var `actor`: Actor
    public var `clientNonce`: String?
    public var `batchId`: ID?
    public var `replyToEntryId`: ID?
    public var `runId`: ID?
    public var `targetedUserId`: ID?
    public var `reactions`: [Reaction]
    public var `kind`: String
    public var `event`: TranscriptEvent
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, conversationId: ID, seq: Int, timestampMs: TimestampMs, actor: Actor, clientNonce: String? = nil, batchId: ID? = nil, replyToEntryId: ID? = nil, runId: ID? = nil, targetedUserId: ID? = nil, reactions: [Reaction], event: TranscriptEvent) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`conversationId` = conversationId
        self.`seq` = seq
        self.`timestampMs` = timestampMs
        self.`actor` = actor
        self.`clientNonce` = clientNonce
        self.`batchId` = batchId
        self.`replyToEntryId` = replyToEntryId
        self.`runId` = runId
        self.`targetedUserId` = targetedUserId
        self.`reactions` = reactions
        self.`kind` = "event"
        self.`event` = event
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `conversationId`, `seq`, `timestampMs`, `actor`, `clientNonce`, `batchId`, `replyToEntryId`, `runId`, `targetedUserId`, `reactions`, `kind`, `event` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`conversationId` = try c.decode(ID.self, forKey: .`conversationId`)
        self.`seq` = try c.decode(Int.self, forKey: .`seq`)
        self.`timestampMs` = try c.decode(TimestampMs.self, forKey: .`timestampMs`)
        self.`actor` = try c.decode(Actor.self, forKey: .`actor`)
        self.`clientNonce` = try c.decode(String?.self, forKey: .`clientNonce`)
        self.`batchId` = try c.decode(ID?.self, forKey: .`batchId`)
        self.`replyToEntryId` = try c.decode(ID?.self, forKey: .`replyToEntryId`)
        self.`runId` = try c.decode(ID?.self, forKey: .`runId`)
        self.`targetedUserId` = try c.decode(ID?.self, forKey: .`targetedUserId`)
        self.`reactions` = try c.decode([Reaction].self, forKey: .`reactions`)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["event"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid EventEntry.kind") }
        self.`event` = try c.decode(TranscriptEvent.self, forKey: .`event`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`conversationId`, forKey: .`conversationId`)
        try c.encode(`seq`, forKey: .`seq`)
        try c.encode(`timestampMs`, forKey: .`timestampMs`)
        try c.encode(`actor`, forKey: .`actor`)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`batchId`, forKey: .`batchId`)
        try c.encode(`replyToEntryId`, forKey: .`replyToEntryId`)
        try c.encode(`runId`, forKey: .`runId`)
        try c.encode(`targetedUserId`, forKey: .`targetedUserId`)
        try c.encode(`reactions`, forKey: .`reactions`)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`event`, forKey: .`event`)
    }
}

public struct FeedbackEntry: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `conversationId`: ID
    public var `seq`: Int
    public var `timestampMs`: TimestampMs
    public var `actor`: Actor
    public var `clientNonce`: String?
    public var `batchId`: ID?
    public var `replyToEntryId`: ID?
    public var `runId`: ID?
    public var `targetedUserId`: ID?
    public var `reactions`: [Reaction]
    public var `kind`: String
    public var `feedback`: Feedback
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, conversationId: ID, seq: Int, timestampMs: TimestampMs, actor: Actor, clientNonce: String? = nil, batchId: ID? = nil, replyToEntryId: ID? = nil, runId: ID? = nil, targetedUserId: ID? = nil, reactions: [Reaction], feedback: Feedback) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`conversationId` = conversationId
        self.`seq` = seq
        self.`timestampMs` = timestampMs
        self.`actor` = actor
        self.`clientNonce` = clientNonce
        self.`batchId` = batchId
        self.`replyToEntryId` = replyToEntryId
        self.`runId` = runId
        self.`targetedUserId` = targetedUserId
        self.`reactions` = reactions
        self.`kind` = "feedback"
        self.`feedback` = feedback
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `conversationId`, `seq`, `timestampMs`, `actor`, `clientNonce`, `batchId`, `replyToEntryId`, `runId`, `targetedUserId`, `reactions`, `kind`, `feedback` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`conversationId` = try c.decode(ID.self, forKey: .`conversationId`)
        self.`seq` = try c.decode(Int.self, forKey: .`seq`)
        self.`timestampMs` = try c.decode(TimestampMs.self, forKey: .`timestampMs`)
        self.`actor` = try c.decode(Actor.self, forKey: .`actor`)
        self.`clientNonce` = try c.decode(String?.self, forKey: .`clientNonce`)
        self.`batchId` = try c.decode(ID?.self, forKey: .`batchId`)
        self.`replyToEntryId` = try c.decode(ID?.self, forKey: .`replyToEntryId`)
        self.`runId` = try c.decode(ID?.self, forKey: .`runId`)
        self.`targetedUserId` = try c.decode(ID?.self, forKey: .`targetedUserId`)
        self.`reactions` = try c.decode([Reaction].self, forKey: .`reactions`)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["feedback"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid FeedbackEntry.kind") }
        self.`feedback` = try c.decode(Feedback.self, forKey: .`feedback`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`conversationId`, forKey: .`conversationId`)
        try c.encode(`seq`, forKey: .`seq`)
        try c.encode(`timestampMs`, forKey: .`timestampMs`)
        try c.encode(`actor`, forKey: .`actor`)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`batchId`, forKey: .`batchId`)
        try c.encode(`replyToEntryId`, forKey: .`replyToEntryId`)
        try c.encode(`runId`, forKey: .`runId`)
        try c.encode(`targetedUserId`, forKey: .`targetedUserId`)
        try c.encode(`reactions`, forKey: .`reactions`)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`feedback`, forKey: .`feedback`)
    }
}

public struct VoiceCallEntry: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `conversationId`: ID
    public var `seq`: Int
    public var `timestampMs`: TimestampMs
    public var `actor`: Actor
    public var `clientNonce`: String?
    public var `batchId`: ID?
    public var `replyToEntryId`: ID?
    public var `runId`: ID?
    public var `targetedUserId`: ID?
    public var `reactions`: [Reaction]
    public var `kind`: String
    public var `voiceSession`: VoiceSession
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, conversationId: ID, seq: Int, timestampMs: TimestampMs, actor: Actor, clientNonce: String? = nil, batchId: ID? = nil, replyToEntryId: ID? = nil, runId: ID? = nil, targetedUserId: ID? = nil, reactions: [Reaction], voiceSession: VoiceSession) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`conversationId` = conversationId
        self.`seq` = seq
        self.`timestampMs` = timestampMs
        self.`actor` = actor
        self.`clientNonce` = clientNonce
        self.`batchId` = batchId
        self.`replyToEntryId` = replyToEntryId
        self.`runId` = runId
        self.`targetedUserId` = targetedUserId
        self.`reactions` = reactions
        self.`kind` = "voice_call"
        self.`voiceSession` = voiceSession
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `conversationId`, `seq`, `timestampMs`, `actor`, `clientNonce`, `batchId`, `replyToEntryId`, `runId`, `targetedUserId`, `reactions`, `kind`, `voiceSession` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`conversationId` = try c.decode(ID.self, forKey: .`conversationId`)
        self.`seq` = try c.decode(Int.self, forKey: .`seq`)
        self.`timestampMs` = try c.decode(TimestampMs.self, forKey: .`timestampMs`)
        self.`actor` = try c.decode(Actor.self, forKey: .`actor`)
        self.`clientNonce` = try c.decode(String?.self, forKey: .`clientNonce`)
        self.`batchId` = try c.decode(ID?.self, forKey: .`batchId`)
        self.`replyToEntryId` = try c.decode(ID?.self, forKey: .`replyToEntryId`)
        self.`runId` = try c.decode(ID?.self, forKey: .`runId`)
        self.`targetedUserId` = try c.decode(ID?.self, forKey: .`targetedUserId`)
        self.`reactions` = try c.decode([Reaction].self, forKey: .`reactions`)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["voice_call"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid VoiceCallEntry.kind") }
        self.`voiceSession` = try c.decode(VoiceSession.self, forKey: .`voiceSession`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`conversationId`, forKey: .`conversationId`)
        try c.encode(`seq`, forKey: .`seq`)
        try c.encode(`timestampMs`, forKey: .`timestampMs`)
        try c.encode(`actor`, forKey: .`actor`)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`batchId`, forKey: .`batchId`)
        try c.encode(`replyToEntryId`, forKey: .`replyToEntryId`)
        try c.encode(`runId`, forKey: .`runId`)
        try c.encode(`targetedUserId`, forKey: .`targetedUserId`)
        try c.encode(`reactions`, forKey: .`reactions`)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`voiceSession`, forKey: .`voiceSession`)
    }
}

public enum TranscriptEntry: Codable, Hashable {
    case unsupported(UnsupportedEntry)
    case `message`(MessageEntry)
    case `card`(CardEntry)
    case `userAttachment`(UserAttachmentEntry)
    case `toolCall`(ToolCallEntry)
    case `mcpApp`(MCPAppEntry)
    case `notice`(NoticeEntry)
    case `event`(EventEntry)
    case `feedback`(FeedbackEntry)
    case `voiceCall`(VoiceCallEntry)
    private enum CodingKeys: String, CodingKey { case kind }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let value = try c.decode(String.self, forKey: .kind)
        switch value {
        case "message": self = .`message`(try MessageEntry(from: decoder))
        case "card": self = .`card`(try CardEntry(from: decoder))
        case "user_attachment": self = .`userAttachment`(try UserAttachmentEntry(from: decoder))
        case "tool_call": self = .`toolCall`(try ToolCallEntry(from: decoder))
        case "mcp_app": self = .`mcpApp`(try MCPAppEntry(from: decoder))
        case "notice": self = .`notice`(try NoticeEntry(from: decoder))
        case "event": self = .`event`(try EventEntry(from: decoder))
        case "feedback": self = .`feedback`(try FeedbackEntry(from: decoder))
        case "voice_call": self = .`voiceCall`(try VoiceCallEntry(from: decoder))
        default: self = .unsupported(try UnsupportedEntry(from: decoder))
        }
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .unsupported(let v): try v.encode(to: encoder)
        case .`message`(let v): try v.encode(to: encoder)
        case .`card`(let v): try v.encode(to: encoder)
        case .`userAttachment`(let v): try v.encode(to: encoder)
        case .`toolCall`(let v): try v.encode(to: encoder)
        case .`mcpApp`(let v): try v.encode(to: encoder)
        case .`notice`(let v): try v.encode(to: encoder)
        case .`event`(let v): try v.encode(to: encoder)
        case .`feedback`(let v): try v.encode(to: encoder)
        case .`voiceCall`(let v): try v.encode(to: encoder)
        }
    }
    public var kind: String {
        switch self {
        case .unsupported(let v): return v.kind
        case .`message`: return "message"
        case .`card`: return "card"
        case .`userAttachment`: return "user_attachment"
        case .`toolCall`: return "tool_call"
        case .`mcpApp`: return "mcp_app"
        case .`notice`: return "notice"
        case .`event`: return "event"
        case .`feedback`: return "feedback"
        case .`voiceCall`: return "voice_call"
        }
    }
}

public enum RealtimePayload: Codable, Hashable {
    case userUpdated(User)
    case workspaceUpdated(Workspace)
    case memberUpserted(Member)
    case memberDeleted(Deleted)
    case inviteUpserted(MemberInvite)
    case deviceUpserted(Device)
    case deviceDeleted(Deleted)
    case machineUpserted(Machine)
    case machineDeleted(Deleted)
    case machineInviteUpserted(MachineInvite)
    case botUpserted(Bot)
    case botDeleted(Deleted)
    case sectionUpserted(Section)
    case sectionDeleted(Deleted)
    case templateUpserted(BotTemplate)
    case templateDeleted(Deleted)
    case conversationUpserted(Conversation)
    case conversationDeleted(Deleted)
    case conversationRead(RealtimeConversationRead)
    case composerUpdated(ComposerDraft)
    case entryUpserted(TranscriptEntry)
    case entryDeleted(RealtimeEntryDeleted)
    case entryDelta(RealtimeEntryDelta)
    case runUpserted(Run)
    case attachmentUpserted(Attachment)
    case attachmentDeleted(Deleted)
    case approvalUpserted(Approval)
    case questionUpserted(Question)
    case humanStepUpserted(HumanStep)
    case secretRequestUpserted(SecretRequest)
    case draftUpserted(Draft)
    case skillUpserted(Skill)
    case skillDeleted(Deleted)
    case routineUpserted(Routine)
    case routineDeleted(Deleted)
    case routineRunUpserted(RoutineRun)
    case memoryUpserted(Memory)
    case memoryDeleted(RealtimeMemoryDeleted)
    case pairingUpserted(Pairing)
    case notificationUpserted(BotNotification)
    case notificationDeleted(Deleted)
    case policiesUpdated(Policies)
    case connectorUpserted(Connector)
    case connectorDeleted(Deleted)
    case connectorAuthUpserted(ConnectorAuth)
    case channelUpserted(ChannelBinding)
    case channelDeleted(Deleted)
    case voiceUpserted(VoiceSession)
    case botPresence(BotPresence)
    case grantUpserted(BotGrant)
    case activityUpserted(ActivityItem)
    case reminderUpserted(Reminder)
    case reminderDeleted(Deleted)
    case preferenceChangeUpserted(PreferenceChange)
    case milestoneUpserted(Milestone)
    case directoryGroupUpserted(DirectoryGroup)
    case directoryGroupDeleted(Deleted)
    case groupPolicyUpserted(GroupPolicy)
    case governanceUpdated(Governance)
    case networkPolicyUpserted(NetworkPolicy)
    case networkPolicyDeleted(Deleted)
    case policyApplicationUpserted(PolicyApplication)
    case egressUpserted(EgressRoute)
    case setupManifestUpserted(SetupManifest)
    case setupRunUpserted(SetupRun)
    case hostOperationUpserted(HostOperation)
    case spendLimitUpserted(SpendLimit)
    case exportUpserted(ExportRecord)
    case channelSetupUpserted(ChannelSetupFlow)
    case emailAccountUpserted(EmailAccount)
    case xConnectionUpserted(XConnection)
    public init(from decoder: Decoder) throws { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "RealtimePayload requires the event envelope")) }
    public func encode(to encoder: Encoder) throws { switch self {
    case .userUpdated(let value): try value.encode(to: encoder)
    case .workspaceUpdated(let value): try value.encode(to: encoder)
    case .memberUpserted(let value): try value.encode(to: encoder)
    case .memberDeleted(let value): try value.encode(to: encoder)
    case .inviteUpserted(let value): try value.encode(to: encoder)
    case .deviceUpserted(let value): try value.encode(to: encoder)
    case .deviceDeleted(let value): try value.encode(to: encoder)
    case .machineUpserted(let value): try value.encode(to: encoder)
    case .machineDeleted(let value): try value.encode(to: encoder)
    case .machineInviteUpserted(let value): try value.encode(to: encoder)
    case .botUpserted(let value): try value.encode(to: encoder)
    case .botDeleted(let value): try value.encode(to: encoder)
    case .sectionUpserted(let value): try value.encode(to: encoder)
    case .sectionDeleted(let value): try value.encode(to: encoder)
    case .templateUpserted(let value): try value.encode(to: encoder)
    case .templateDeleted(let value): try value.encode(to: encoder)
    case .conversationUpserted(let value): try value.encode(to: encoder)
    case .conversationDeleted(let value): try value.encode(to: encoder)
    case .conversationRead(let value): try value.encode(to: encoder)
    case .composerUpdated(let value): try value.encode(to: encoder)
    case .entryUpserted(let value): try value.encode(to: encoder)
    case .entryDeleted(let value): try value.encode(to: encoder)
    case .entryDelta(let value): try value.encode(to: encoder)
    case .runUpserted(let value): try value.encode(to: encoder)
    case .attachmentUpserted(let value): try value.encode(to: encoder)
    case .attachmentDeleted(let value): try value.encode(to: encoder)
    case .approvalUpserted(let value): try value.encode(to: encoder)
    case .questionUpserted(let value): try value.encode(to: encoder)
    case .humanStepUpserted(let value): try value.encode(to: encoder)
    case .secretRequestUpserted(let value): try value.encode(to: encoder)
    case .draftUpserted(let value): try value.encode(to: encoder)
    case .skillUpserted(let value): try value.encode(to: encoder)
    case .skillDeleted(let value): try value.encode(to: encoder)
    case .routineUpserted(let value): try value.encode(to: encoder)
    case .routineDeleted(let value): try value.encode(to: encoder)
    case .routineRunUpserted(let value): try value.encode(to: encoder)
    case .memoryUpserted(let value): try value.encode(to: encoder)
    case .memoryDeleted(let value): try value.encode(to: encoder)
    case .pairingUpserted(let value): try value.encode(to: encoder)
    case .notificationUpserted(let value): try value.encode(to: encoder)
    case .notificationDeleted(let value): try value.encode(to: encoder)
    case .policiesUpdated(let value): try value.encode(to: encoder)
    case .connectorUpserted(let value): try value.encode(to: encoder)
    case .connectorDeleted(let value): try value.encode(to: encoder)
    case .connectorAuthUpserted(let value): try value.encode(to: encoder)
    case .channelUpserted(let value): try value.encode(to: encoder)
    case .channelDeleted(let value): try value.encode(to: encoder)
    case .voiceUpserted(let value): try value.encode(to: encoder)
    case .botPresence(let value): try value.encode(to: encoder)
    case .grantUpserted(let value): try value.encode(to: encoder)
    case .activityUpserted(let value): try value.encode(to: encoder)
    case .reminderUpserted(let value): try value.encode(to: encoder)
    case .reminderDeleted(let value): try value.encode(to: encoder)
    case .preferenceChangeUpserted(let value): try value.encode(to: encoder)
    case .milestoneUpserted(let value): try value.encode(to: encoder)
    case .directoryGroupUpserted(let value): try value.encode(to: encoder)
    case .directoryGroupDeleted(let value): try value.encode(to: encoder)
    case .groupPolicyUpserted(let value): try value.encode(to: encoder)
    case .governanceUpdated(let value): try value.encode(to: encoder)
    case .networkPolicyUpserted(let value): try value.encode(to: encoder)
    case .networkPolicyDeleted(let value): try value.encode(to: encoder)
    case .policyApplicationUpserted(let value): try value.encode(to: encoder)
    case .egressUpserted(let value): try value.encode(to: encoder)
    case .setupManifestUpserted(let value): try value.encode(to: encoder)
    case .setupRunUpserted(let value): try value.encode(to: encoder)
    case .hostOperationUpserted(let value): try value.encode(to: encoder)
    case .spendLimitUpserted(let value): try value.encode(to: encoder)
    case .exportUpserted(let value): try value.encode(to: encoder)
    case .channelSetupUpserted(let value): try value.encode(to: encoder)
    case .emailAccountUpserted(let value): try value.encode(to: encoder)
    case .xConnectionUpserted(let value): try value.encode(to: encoder)
    } }
}

public struct RealtimeEvent: Codable, Hashable {
    public var seq: Cursor
    public var payload: RealtimePayload
    public var timestampMs: TimestampMs
    public var type: String { "event" }
    public var event: String { switch payload {
    case .userUpdated: return "user.updated"
    case .workspaceUpdated: return "workspace.updated"
    case .memberUpserted: return "member.upserted"
    case .memberDeleted: return "member.deleted"
    case .inviteUpserted: return "invite.upserted"
    case .deviceUpserted: return "device.upserted"
    case .deviceDeleted: return "device.deleted"
    case .machineUpserted: return "machine.upserted"
    case .machineDeleted: return "machine.deleted"
    case .machineInviteUpserted: return "machine_invite.upserted"
    case .botUpserted: return "bot.upserted"
    case .botDeleted: return "bot.deleted"
    case .sectionUpserted: return "section.upserted"
    case .sectionDeleted: return "section.deleted"
    case .templateUpserted: return "template.upserted"
    case .templateDeleted: return "template.deleted"
    case .conversationUpserted: return "conversation.upserted"
    case .conversationDeleted: return "conversation.deleted"
    case .conversationRead: return "conversation.read"
    case .composerUpdated: return "composer.updated"
    case .entryUpserted: return "entry.upserted"
    case .entryDeleted: return "entry.deleted"
    case .entryDelta: return "entry.delta"
    case .runUpserted: return "run.upserted"
    case .attachmentUpserted: return "attachment.upserted"
    case .attachmentDeleted: return "attachment.deleted"
    case .approvalUpserted: return "approval.upserted"
    case .questionUpserted: return "question.upserted"
    case .humanStepUpserted: return "human_step.upserted"
    case .secretRequestUpserted: return "secret_request.upserted"
    case .draftUpserted: return "draft.upserted"
    case .skillUpserted: return "skill.upserted"
    case .skillDeleted: return "skill.deleted"
    case .routineUpserted: return "routine.upserted"
    case .routineDeleted: return "routine.deleted"
    case .routineRunUpserted: return "routine_run.upserted"
    case .memoryUpserted: return "memory.upserted"
    case .memoryDeleted: return "memory.deleted"
    case .pairingUpserted: return "pairing.upserted"
    case .notificationUpserted: return "notification.upserted"
    case .notificationDeleted: return "notification.deleted"
    case .policiesUpdated: return "policies.updated"
    case .connectorUpserted: return "connector.upserted"
    case .connectorDeleted: return "connector.deleted"
    case .connectorAuthUpserted: return "connector_auth.upserted"
    case .channelUpserted: return "channel.upserted"
    case .channelDeleted: return "channel.deleted"
    case .voiceUpserted: return "voice.upserted"
    case .botPresence: return "bot.presence"
    case .grantUpserted: return "grant.upserted"
    case .activityUpserted: return "activity.upserted"
    case .reminderUpserted: return "reminder.upserted"
    case .reminderDeleted: return "reminder.deleted"
    case .preferenceChangeUpserted: return "preference_change.upserted"
    case .milestoneUpserted: return "milestone.upserted"
    case .directoryGroupUpserted: return "directory_group.upserted"
    case .directoryGroupDeleted: return "directory_group.deleted"
    case .groupPolicyUpserted: return "group_policy.upserted"
    case .governanceUpdated: return "governance.updated"
    case .networkPolicyUpserted: return "network_policy.upserted"
    case .networkPolicyDeleted: return "network_policy.deleted"
    case .policyApplicationUpserted: return "policy_application.upserted"
    case .egressUpserted: return "egress.upserted"
    case .setupManifestUpserted: return "setup_manifest.upserted"
    case .setupRunUpserted: return "setup_run.upserted"
    case .hostOperationUpserted: return "host_operation.upserted"
    case .spendLimitUpserted: return "spend_limit.upserted"
    case .exportUpserted: return "export.upserted"
    case .channelSetupUpserted: return "channel_setup.upserted"
    case .emailAccountUpserted: return "email_account.upserted"
    case .xConnectionUpserted: return "x_connection.upserted"
    } }
    public init(seq: Cursor, payload: RealtimePayload, timestampMs: TimestampMs) { self.seq = seq; self.payload = payload; self.timestampMs = timestampMs }
    enum CodingKeys: String, CodingKey { case type, seq, event, payload, timestampMs }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(String.self, forKey: .type) == "event" else { throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Expected event") }
        seq = try c.decode(Cursor.self, forKey: .seq)
        timestampMs = try c.decode(TimestampMs.self, forKey: .timestampMs)
        let name = try c.decode(String.self, forKey: .event)
        switch name {
        case "user.updated": payload = .userUpdated(try c.decode(User.self, forKey: .payload))
        case "workspace.updated": payload = .workspaceUpdated(try c.decode(Workspace.self, forKey: .payload))
        case "member.upserted": payload = .memberUpserted(try c.decode(Member.self, forKey: .payload))
        case "member.deleted": payload = .memberDeleted(try c.decode(Deleted.self, forKey: .payload))
        case "invite.upserted": payload = .inviteUpserted(try c.decode(MemberInvite.self, forKey: .payload))
        case "device.upserted": payload = .deviceUpserted(try c.decode(Device.self, forKey: .payload))
        case "device.deleted": payload = .deviceDeleted(try c.decode(Deleted.self, forKey: .payload))
        case "machine.upserted": payload = .machineUpserted(try c.decode(Machine.self, forKey: .payload))
        case "machine.deleted": payload = .machineDeleted(try c.decode(Deleted.self, forKey: .payload))
        case "machine_invite.upserted": payload = .machineInviteUpserted(try c.decode(MachineInvite.self, forKey: .payload))
        case "bot.upserted": payload = .botUpserted(try c.decode(Bot.self, forKey: .payload))
        case "bot.deleted": payload = .botDeleted(try c.decode(Deleted.self, forKey: .payload))
        case "section.upserted": payload = .sectionUpserted(try c.decode(Section.self, forKey: .payload))
        case "section.deleted": payload = .sectionDeleted(try c.decode(Deleted.self, forKey: .payload))
        case "template.upserted": payload = .templateUpserted(try c.decode(BotTemplate.self, forKey: .payload))
        case "template.deleted": payload = .templateDeleted(try c.decode(Deleted.self, forKey: .payload))
        case "conversation.upserted": payload = .conversationUpserted(try c.decode(Conversation.self, forKey: .payload))
        case "conversation.deleted": payload = .conversationDeleted(try c.decode(Deleted.self, forKey: .payload))
        case "conversation.read": payload = .conversationRead(try c.decode(RealtimeConversationRead.self, forKey: .payload))
        case "composer.updated": payload = .composerUpdated(try c.decode(ComposerDraft.self, forKey: .payload))
        case "entry.upserted": payload = .entryUpserted(try c.decode(TranscriptEntry.self, forKey: .payload))
        case "entry.deleted": payload = .entryDeleted(try c.decode(RealtimeEntryDeleted.self, forKey: .payload))
        case "entry.delta": payload = .entryDelta(try c.decode(RealtimeEntryDelta.self, forKey: .payload))
        case "run.upserted": payload = .runUpserted(try c.decode(Run.self, forKey: .payload))
        case "attachment.upserted": payload = .attachmentUpserted(try c.decode(Attachment.self, forKey: .payload))
        case "attachment.deleted": payload = .attachmentDeleted(try c.decode(Deleted.self, forKey: .payload))
        case "approval.upserted": payload = .approvalUpserted(try c.decode(Approval.self, forKey: .payload))
        case "question.upserted": payload = .questionUpserted(try c.decode(Question.self, forKey: .payload))
        case "human_step.upserted": payload = .humanStepUpserted(try c.decode(HumanStep.self, forKey: .payload))
        case "secret_request.upserted": payload = .secretRequestUpserted(try c.decode(SecretRequest.self, forKey: .payload))
        case "draft.upserted": payload = .draftUpserted(try c.decode(Draft.self, forKey: .payload))
        case "skill.upserted": payload = .skillUpserted(try c.decode(Skill.self, forKey: .payload))
        case "skill.deleted": payload = .skillDeleted(try c.decode(Deleted.self, forKey: .payload))
        case "routine.upserted": payload = .routineUpserted(try c.decode(Routine.self, forKey: .payload))
        case "routine.deleted": payload = .routineDeleted(try c.decode(Deleted.self, forKey: .payload))
        case "routine_run.upserted": payload = .routineRunUpserted(try c.decode(RoutineRun.self, forKey: .payload))
        case "memory.upserted": payload = .memoryUpserted(try c.decode(Memory.self, forKey: .payload))
        case "memory.deleted": payload = .memoryDeleted(try c.decode(RealtimeMemoryDeleted.self, forKey: .payload))
        case "pairing.upserted": payload = .pairingUpserted(try c.decode(Pairing.self, forKey: .payload))
        case "notification.upserted": payload = .notificationUpserted(try c.decode(BotNotification.self, forKey: .payload))
        case "notification.deleted": payload = .notificationDeleted(try c.decode(Deleted.self, forKey: .payload))
        case "policies.updated": payload = .policiesUpdated(try c.decode(Policies.self, forKey: .payload))
        case "connector.upserted": payload = .connectorUpserted(try c.decode(Connector.self, forKey: .payload))
        case "connector.deleted": payload = .connectorDeleted(try c.decode(Deleted.self, forKey: .payload))
        case "connector_auth.upserted": payload = .connectorAuthUpserted(try c.decode(ConnectorAuth.self, forKey: .payload))
        case "channel.upserted": payload = .channelUpserted(try c.decode(ChannelBinding.self, forKey: .payload))
        case "channel.deleted": payload = .channelDeleted(try c.decode(Deleted.self, forKey: .payload))
        case "voice.upserted": payload = .voiceUpserted(try c.decode(VoiceSession.self, forKey: .payload))
        case "bot.presence": payload = .botPresence(try c.decode(BotPresence.self, forKey: .payload))
        case "grant.upserted": payload = .grantUpserted(try c.decode(BotGrant.self, forKey: .payload))
        case "activity.upserted": payload = .activityUpserted(try c.decode(ActivityItem.self, forKey: .payload))
        case "reminder.upserted": payload = .reminderUpserted(try c.decode(Reminder.self, forKey: .payload))
        case "reminder.deleted": payload = .reminderDeleted(try c.decode(Deleted.self, forKey: .payload))
        case "preference_change.upserted": payload = .preferenceChangeUpserted(try c.decode(PreferenceChange.self, forKey: .payload))
        case "milestone.upserted": payload = .milestoneUpserted(try c.decode(Milestone.self, forKey: .payload))
        case "directory_group.upserted": payload = .directoryGroupUpserted(try c.decode(DirectoryGroup.self, forKey: .payload))
        case "directory_group.deleted": payload = .directoryGroupDeleted(try c.decode(Deleted.self, forKey: .payload))
        case "group_policy.upserted": payload = .groupPolicyUpserted(try c.decode(GroupPolicy.self, forKey: .payload))
        case "governance.updated": payload = .governanceUpdated(try c.decode(Governance.self, forKey: .payload))
        case "network_policy.upserted": payload = .networkPolicyUpserted(try c.decode(NetworkPolicy.self, forKey: .payload))
        case "network_policy.deleted": payload = .networkPolicyDeleted(try c.decode(Deleted.self, forKey: .payload))
        case "policy_application.upserted": payload = .policyApplicationUpserted(try c.decode(PolicyApplication.self, forKey: .payload))
        case "egress.upserted": payload = .egressUpserted(try c.decode(EgressRoute.self, forKey: .payload))
        case "setup_manifest.upserted": payload = .setupManifestUpserted(try c.decode(SetupManifest.self, forKey: .payload))
        case "setup_run.upserted": payload = .setupRunUpserted(try c.decode(SetupRun.self, forKey: .payload))
        case "host_operation.upserted": payload = .hostOperationUpserted(try c.decode(HostOperation.self, forKey: .payload))
        case "spend_limit.upserted": payload = .spendLimitUpserted(try c.decode(SpendLimit.self, forKey: .payload))
        case "export.upserted": payload = .exportUpserted(try c.decode(ExportRecord.self, forKey: .payload))
        case "channel_setup.upserted": payload = .channelSetupUpserted(try c.decode(ChannelSetupFlow.self, forKey: .payload))
        case "email_account.upserted": payload = .emailAccountUpserted(try c.decode(EmailAccount.self, forKey: .payload))
        case "x_connection.upserted": payload = .xConnectionUpserted(try c.decode(XConnection.self, forKey: .payload))
        default: throw DecodingError.dataCorruptedError(forKey: .event, in: c, debugDescription: "Unsupported realtime event: \(name)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type); try c.encode(seq, forKey: .seq); try c.encode(event, forKey: .event); try c.encode(timestampMs, forKey: .timestampMs)
        try payload.encode(to: c.superEncoder(forKey: .payload))
    }
}

public struct RealtimeMemoryDeleted: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `botId`: ID
    public init(id: ID, botId: ID) {
        self.`id` = id
        self.`botId` = botId
    }
    enum CodingKeys: String, CodingKey { case `id`, `botId` }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`botId`, forKey: .`botId`)
    }
}

public struct RealtimeEntryDelta: Codable, Hashable {
    public var `conversationId`: ID
    public var `entryId`: ID
    public var `runId`: ID
    public var `offset`: Int
    public var `text`: String
    public init(conversationId: ID, entryId: ID, runId: ID, offset: Int, text: String) {
        self.`conversationId` = conversationId
        self.`entryId` = entryId
        self.`runId` = runId
        self.`offset` = offset
        self.`text` = text
    }
    enum CodingKeys: String, CodingKey { case `conversationId`, `entryId`, `runId`, `offset`, `text` }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`conversationId`, forKey: .`conversationId`)
        try c.encode(`entryId`, forKey: .`entryId`)
        try c.encode(`runId`, forKey: .`runId`)
        try c.encode(`offset`, forKey: .`offset`)
        try c.encode(`text`, forKey: .`text`)
    }
}

public struct RealtimeEntryDeleted: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `conversationId`: ID
    public init(id: ID, conversationId: ID) {
        self.`id` = id
        self.`conversationId` = conversationId
    }
    enum CodingKeys: String, CodingKey { case `id`, `conversationId` }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`conversationId`, forKey: .`conversationId`)
    }
}

public struct RealtimeConversationRead: Codable, Hashable {
    public var `conversationId`: ID
    public var `userId`: ID
    public var `throughSeq`: Int
    public var `unread`: Bool
    public init(conversationId: ID, userId: ID, throughSeq: Int, unread: Bool) {
        self.`conversationId` = conversationId
        self.`userId` = userId
        self.`throughSeq` = throughSeq
        self.`unread` = unread
    }
    enum CodingKeys: String, CodingKey { case `conversationId`, `userId`, `throughSeq`, `unread` }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`conversationId`, forKey: .`conversationId`)
        try c.encode(`userId`, forKey: .`userId`)
        try c.encode(`throughSeq`, forKey: .`throughSeq`)
        try c.encode(`unread`, forKey: .`unread`)
    }
}

public struct RealtimeErrorError: Codable, Hashable {
    public var `code`: ErrorCode
    public var `message`: String
    public var `requestId`: String
    public var `retrySafe`: Bool
    public var `details`: JSONObject?
    public init(code: ErrorCode, message: String, requestId: String, retrySafe: Bool, details: JSONObject? = nil) {
        self.`code` = code
        self.`message` = message
        self.`requestId` = requestId
        self.`retrySafe` = retrySafe
        self.`details` = details
    }
    enum CodingKeys: String, CodingKey { case `code`, `message`, `requestId`, `retrySafe`, `details` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`code` = try c.decode(ErrorCode.self, forKey: .`code`)
        self.`message` = try c.decode(String.self, forKey: .`message`)
        self.`requestId` = try c.decode(String.self, forKey: .`requestId`)
        self.`retrySafe` = try c.decode(Bool.self, forKey: .`retrySafe`)
        self.`details` = try c.decodeOptional(JSONObject.self, forKey: .`details`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`code`, forKey: .`code`)
        try c.encode(`message`, forKey: .`message`)
        try c.encode(`requestId`, forKey: .`requestId`)
        try c.encode(`retrySafe`, forKey: .`retrySafe`)
        try c.encodeIfPresent(`details`, forKey: .`details`)
    }
}

public struct PushRegistrationWebPushKeys: Codable, Hashable {
    public var `p256dh`: String
    public var `auth`: String
    public init(p256dh: String, auth: String) {
        self.`p256dh` = p256dh
        self.`auth` = auth
    }
    enum CodingKeys: String, CodingKey { case `p256dh`, `auth` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`p256dh` = try c.decode(String.self, forKey: .`p256dh`)
        self.`auth` = try c.decode(String.self, forKey: .`auth`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`p256dh`, forKey: .`p256dh`)
        try c.encode(`auth`, forKey: .`auth`)
    }
}

public struct CardWidgetOptions: Codable, Hashable {
    public var `value`: String
    public var `label`: String
    public init(value: String, label: String) {
        self.`value` = value
        self.`label` = label
    }
    enum CodingKeys: String, CodingKey { case `value`, `label` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`value` = try c.decode(String.self, forKey: .`value`)
        self.`label` = try c.decode(String.self, forKey: .`label`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`value`, forKey: .`value`)
        try c.encode(`label`, forKey: .`label`)
    }
}

public struct SCIMGroupInputMembers: Codable, Hashable {
    public var `value`: ID
    public var `display`: String?
    public init(value: ID, display: String? = nil) {
        self.`value` = value
        self.`display` = display
    }
    enum CodingKeys: String, CodingKey { case `value`, `display` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`value` = try c.decode(ID.self, forKey: .`value`)
        self.`display` = try c.decodeOptional(String.self, forKey: .`display`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`value`, forKey: .`value`)
        try c.encodeIfPresent(`display`, forKey: .`display`)
    }
}

public struct SCIMUserInputEmails: Codable, Hashable {
    public var `value`: String
    public var `primary`: Bool?
    public var `type`: String?
    public init(value: String, primary: Bool? = nil, type: String? = nil) {
        self.`value` = value
        self.`primary` = primary
        self.`type` = type
    }
    enum CodingKeys: String, CodingKey { case `value`, `primary`, `type` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`value` = try c.decode(String.self, forKey: .`value`)
        self.`primary` = try c.decodeOptional(Bool.self, forKey: .`primary`)
        self.`type` = try c.decodeOptional(String.self, forKey: .`type`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`value`, forKey: .`value`)
        try c.encodeIfPresent(`primary`, forKey: .`primary`)
        try c.encodeIfPresent(`type`, forKey: .`type`)
    }
}

public struct SCIMUserInputName: Codable, Hashable {
    public var `givenName`: String?
    public var `familyName`: String?
    public var `formatted`: String?
    public init(givenName: String? = nil, familyName: String? = nil, formatted: String? = nil) {
        self.`givenName` = givenName
        self.`familyName` = familyName
        self.`formatted` = formatted
    }
    enum CodingKeys: String, CodingKey { case `givenName`, `familyName`, `formatted` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`givenName` = try c.decodeOptional(String.self, forKey: .`givenName`)
        self.`familyName` = try c.decodeOptional(String.self, forKey: .`familyName`)
        self.`formatted` = try c.decodeOptional(String.self, forKey: .`formatted`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(`givenName`, forKey: .`givenName`)
        try c.encodeIfPresent(`familyName`, forKey: .`familyName`)
        try c.encodeIfPresent(`formatted`, forKey: .`formatted`)
    }
}

public struct OperatorConfigurationXProvider: Codable, Hashable {
    public var `oauth`: OAuthProviderConfig
    public var `publicHandle`: String
    public var `signingSecretRef`: String
    public var `apiBaseUrl`: String
    public var `deniedCountries`: [String]
    public var `allowedMedia`: [String]
    public init(oauth: OAuthProviderConfig, publicHandle: String, signingSecretRef: String, apiBaseUrl: String, deniedCountries: [String], allowedMedia: [String]) {
        self.`oauth` = oauth
        self.`publicHandle` = publicHandle
        self.`signingSecretRef` = signingSecretRef
        self.`apiBaseUrl` = apiBaseUrl
        self.`deniedCountries` = deniedCountries
        self.`allowedMedia` = allowedMedia
    }
    enum CodingKeys: String, CodingKey { case `oauth`, `publicHandle`, `signingSecretRef`, `apiBaseUrl`, `deniedCountries`, `allowedMedia` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`oauth` = try c.decode(OAuthProviderConfig.self, forKey: .`oauth`)
        self.`publicHandle` = try c.decode(String.self, forKey: .`publicHandle`)
        self.`signingSecretRef` = try c.decode(String.self, forKey: .`signingSecretRef`)
        self.`apiBaseUrl` = try c.decode(String.self, forKey: .`apiBaseUrl`)
        self.`deniedCountries` = try c.decode([String].self, forKey: .`deniedCountries`)
        self.`allowedMedia` = try c.decode([String].self, forKey: .`allowedMedia`)
        guard allowedMedia.allSatisfy({ XMediaValue(rawValue: $0) != nil }) else { throw DecodingError.dataCorruptedError(forKey: .`allowedMedia`, in: c, debugDescription: "Invalid OperatorConfigurationXProvider.allowedMedia") }
    }
    public func encode(to encoder: Encoder) throws {
        guard allowedMedia.allSatisfy({ XMediaValue(rawValue: $0) != nil }) else { throw EncodingError.invalidValue(allowedMedia, .init(codingPath: encoder.codingPath + [CodingKeys.allowedMedia], debugDescription: "Invalid OperatorConfigurationXProvider.allowedMedia")) }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`oauth`, forKey: .`oauth`)
        try c.encode(`publicHandle`, forKey: .`publicHandle`)
        try c.encode(`signingSecretRef`, forKey: .`signingSecretRef`)
        try c.encode(`apiBaseUrl`, forKey: .`apiBaseUrl`)
        try c.encode(`deniedCountries`, forKey: .`deniedCountries`)
        try c.encode(`allowedMedia`, forKey: .`allowedMedia`)
    }
}

public struct EmailProviderConfigImap: Codable, Hashable {
    public var `host`: String
    public var `port`: Int
    public var `tls`: Bool
    public var `secretRef`: String
    public init(host: String, port: Int, tls: Bool, secretRef: String) {
        self.`host` = host
        self.`port` = port
        self.`tls` = tls
        self.`secretRef` = secretRef
    }
    enum CodingKeys: String, CodingKey { case `host`, `port`, `tls`, `secretRef` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`host` = try c.decode(String.self, forKey: .`host`)
        self.`port` = try c.decode(Int.self, forKey: .`port`)
        self.`tls` = try c.decode(Bool.self, forKey: .`tls`)
        guard `tls` == true else { throw DecodingError.dataCorruptedError(forKey: .`tls`, in: c, debugDescription: "Invalid literal EmailProviderConfigImap.tls") }
        self.`secretRef` = try c.decode(String.self, forKey: .`secretRef`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`host`, forKey: .`host`)
        try c.encode(`port`, forKey: .`port`)
        try c.encode(`tls`, forKey: .`tls`)
        try c.encode(`secretRef`, forKey: .`secretRef`)
    }
}

public struct EmailProviderConfigSmtp: Codable, Hashable {
    public var `host`: String
    public var `port`: Int
    public var `tls`: Bool
    public var `secretRef`: String
    public init(host: String, port: Int, tls: Bool, secretRef: String) {
        self.`host` = host
        self.`port` = port
        self.`tls` = tls
        self.`secretRef` = secretRef
    }
    enum CodingKeys: String, CodingKey { case `host`, `port`, `tls`, `secretRef` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`host` = try c.decode(String.self, forKey: .`host`)
        self.`port` = try c.decode(Int.self, forKey: .`port`)
        self.`tls` = try c.decode(Bool.self, forKey: .`tls`)
        guard `tls` == true else { throw DecodingError.dataCorruptedError(forKey: .`tls`, in: c, debugDescription: "Invalid literal EmailProviderConfigSmtp.tls") }
        self.`secretRef` = try c.decode(String.self, forKey: .`secretRef`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`host`, forKey: .`host`)
        try c.encode(`port`, forKey: .`port`)
        try c.encode(`tls`, forKey: .`tls`)
        try c.encode(`secretRef`, forKey: .`secretRef`)
    }
}

public struct ChannelProviderConfigCapabilities: Codable, Hashable {
    public var `events`: [String]
    public var `inbound`: Bool
    public var `outbound`: Bool
    public init(events: [String], inbound: Bool, outbound: Bool) {
        self.`events` = events
        self.`inbound` = inbound
        self.`outbound` = outbound
    }
    enum CodingKeys: String, CodingKey { case `events`, `inbound`, `outbound` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`events` = try c.decode([String].self, forKey: .`events`)
        self.`inbound` = try c.decode(Bool.self, forKey: .`inbound`)
        self.`outbound` = try c.decode(Bool.self, forKey: .`outbound`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`events`, forKey: .`events`)
        try c.encode(`inbound`, forKey: .`inbound`)
        try c.encode(`outbound`, forKey: .`outbound`)
    }
}

public struct SCIMServiceProviderConfigAuthenticationSchemes: Codable, Hashable {
    public var `type`: String
    public var `name`: String
    public var `description`: String
    public var `primary`: Bool
    public init(type: String, name: String, description: String, primary: Bool) {
        self.`type` = type
        self.`name` = name
        self.`description` = description
        self.`primary` = primary
    }
    enum CodingKeys: String, CodingKey { case `type`, `name`, `description`, `primary` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["oauthbearertoken"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid SCIMServiceProviderConfigAuthenticationSchemes.type") }
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`description` = try c.decode(String.self, forKey: .`description`)
        self.`primary` = try c.decode(Bool.self, forKey: .`primary`)
        guard `primary` == true else { throw DecodingError.dataCorruptedError(forKey: .`primary`, in: c, debugDescription: "Invalid literal SCIMServiceProviderConfigAuthenticationSchemes.primary") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`description`, forKey: .`description`)
        try c.encode(`primary`, forKey: .`primary`)
    }
}

public struct SCIMServiceProviderConfigEtag: Codable, Hashable {
    public var `supported`: Bool
    public init(supported: Bool) {
        self.`supported` = supported
    }
    enum CodingKeys: String, CodingKey { case `supported` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`supported` = try c.decode(Bool.self, forKey: .`supported`)
        guard `supported` == true else { throw DecodingError.dataCorruptedError(forKey: .`supported`, in: c, debugDescription: "Invalid literal SCIMServiceProviderConfigEtag.supported") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`supported`, forKey: .`supported`)
    }
}

public struct SCIMServiceProviderConfigSort: Codable, Hashable {
    public var `supported`: Bool
    public init(supported: Bool) {
        self.`supported` = supported
    }
    enum CodingKeys: String, CodingKey { case `supported` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`supported` = try c.decode(Bool.self, forKey: .`supported`)
        guard `supported` == false else { throw DecodingError.dataCorruptedError(forKey: .`supported`, in: c, debugDescription: "Invalid literal SCIMServiceProviderConfigSort.supported") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`supported`, forKey: .`supported`)
    }
}

public struct SCIMServiceProviderConfigChangePassword: Codable, Hashable {
    public var `supported`: Bool
    public init(supported: Bool) {
        self.`supported` = supported
    }
    enum CodingKeys: String, CodingKey { case `supported` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`supported` = try c.decode(Bool.self, forKey: .`supported`)
        guard `supported` == false else { throw DecodingError.dataCorruptedError(forKey: .`supported`, in: c, debugDescription: "Invalid literal SCIMServiceProviderConfigChangePassword.supported") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`supported`, forKey: .`supported`)
    }
}

public struct SCIMServiceProviderConfigFilter: Codable, Hashable {
    public var `supported`: Bool
    public var `maxResults`: Int
    public init(supported: Bool, maxResults: Int) {
        self.`supported` = supported
        self.`maxResults` = maxResults
    }
    enum CodingKeys: String, CodingKey { case `supported`, `maxResults` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`supported` = try c.decode(Bool.self, forKey: .`supported`)
        guard `supported` == true else { throw DecodingError.dataCorruptedError(forKey: .`supported`, in: c, debugDescription: "Invalid literal SCIMServiceProviderConfigFilter.supported") }
        self.`maxResults` = try c.decode(Int.self, forKey: .`maxResults`)
        guard `maxResults` == 200 else { throw DecodingError.dataCorruptedError(forKey: .`maxResults`, in: c, debugDescription: "Invalid literal SCIMServiceProviderConfigFilter.maxResults") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`supported`, forKey: .`supported`)
        try c.encode(`maxResults`, forKey: .`maxResults`)
    }
}

public struct SCIMServiceProviderConfigBulk: Codable, Hashable {
    public var `supported`: Bool
    public var `maxOperations`: Int
    public var `maxPayloadSize`: Int
    public init(supported: Bool, maxOperations: Int, maxPayloadSize: Int) {
        self.`supported` = supported
        self.`maxOperations` = maxOperations
        self.`maxPayloadSize` = maxPayloadSize
    }
    enum CodingKeys: String, CodingKey { case `supported`, `maxOperations`, `maxPayloadSize` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`supported` = try c.decode(Bool.self, forKey: .`supported`)
        guard `supported` == false else { throw DecodingError.dataCorruptedError(forKey: .`supported`, in: c, debugDescription: "Invalid literal SCIMServiceProviderConfigBulk.supported") }
        self.`maxOperations` = try c.decode(Int.self, forKey: .`maxOperations`)
        guard `maxOperations` == 0 else { throw DecodingError.dataCorruptedError(forKey: .`maxOperations`, in: c, debugDescription: "Invalid literal SCIMServiceProviderConfigBulk.maxOperations") }
        self.`maxPayloadSize` = try c.decode(Int.self, forKey: .`maxPayloadSize`)
        guard `maxPayloadSize` == 0 else { throw DecodingError.dataCorruptedError(forKey: .`maxPayloadSize`, in: c, debugDescription: "Invalid literal SCIMServiceProviderConfigBulk.maxPayloadSize") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`supported`, forKey: .`supported`)
        try c.encode(`maxOperations`, forKey: .`maxOperations`)
        try c.encode(`maxPayloadSize`, forKey: .`maxPayloadSize`)
    }
}

public struct SCIMServiceProviderConfigPatch: Codable, Hashable {
    public var `supported`: Bool
    public init(supported: Bool) {
        self.`supported` = supported
    }
    enum CodingKeys: String, CodingKey { case `supported` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`supported` = try c.decode(Bool.self, forKey: .`supported`)
        guard `supported` == true else { throw DecodingError.dataCorruptedError(forKey: .`supported`, in: c, debugDescription: "Invalid literal SCIMServiceProviderConfigPatch.supported") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`supported`, forKey: .`supported`)
    }
}

public struct SCIMPatchOperations: Codable, Hashable {
    public var `op`: String
    public var `path`: String?
    public var `value`: JSONValue?
    public init(op: String, path: String? = nil, value: JSONValue? = nil) {
        self.`op` = op
        self.`path` = path
        self.`value` = value
    }
    enum CodingKeys: String, CodingKey { case `op`, `path`, `value` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`op` = try c.decode(String.self, forKey: .`op`)
        guard ["add", "remove", "replace"].contains(`op`) else { throw DecodingError.dataCorruptedError(forKey: .`op`, in: c, debugDescription: "Invalid SCIMPatchOperations.op") }
        self.`path` = try c.decodeOptional(String.self, forKey: .`path`)
        self.`value` = try c.decodeOptional(JSONValue.self, forKey: .`value`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`op`, forKey: .`op`)
        try c.encodeIfPresent(`path`, forKey: .`path`)
        try c.encodeIfPresent(`value`, forKey: .`value`)
    }
}

public struct SCIMGroupMembers: Codable, Hashable {
    public var `value`: ID
    public var `display`: String?
    public init(value: ID, display: String? = nil) {
        self.`value` = value
        self.`display` = display
    }
    enum CodingKeys: String, CodingKey { case `value`, `display` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`value` = try c.decode(ID.self, forKey: .`value`)
        self.`display` = try c.decodeOptional(String.self, forKey: .`display`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`value`, forKey: .`value`)
        try c.encodeIfPresent(`display`, forKey: .`display`)
    }
}

public struct SCIMUserGroups: Codable, Hashable {
    public var `value`: ID
    public var `display`: String?
    public init(value: ID, display: String? = nil) {
        self.`value` = value
        self.`display` = display
    }
    enum CodingKeys: String, CodingKey { case `value`, `display` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`value` = try c.decode(ID.self, forKey: .`value`)
        self.`display` = try c.decodeOptional(String.self, forKey: .`display`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`value`, forKey: .`value`)
        try c.encodeIfPresent(`display`, forKey: .`display`)
    }
}

public struct SCIMUserEmails: Codable, Hashable {
    public var `value`: String
    public var `primary`: Bool?
    public var `type`: String?
    public init(value: String, primary: Bool? = nil, type: String? = nil) {
        self.`value` = value
        self.`primary` = primary
        self.`type` = type
    }
    enum CodingKeys: String, CodingKey { case `value`, `primary`, `type` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`value` = try c.decode(String.self, forKey: .`value`)
        self.`primary` = try c.decodeOptional(Bool.self, forKey: .`primary`)
        self.`type` = try c.decodeOptional(String.self, forKey: .`type`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`value`, forKey: .`value`)
        try c.encodeIfPresent(`primary`, forKey: .`primary`)
        try c.encodeIfPresent(`type`, forKey: .`type`)
    }
}

public struct SCIMUserName: Codable, Hashable {
    public var `givenName`: String?
    public var `familyName`: String?
    public var `formatted`: String?
    public init(givenName: String? = nil, familyName: String? = nil, formatted: String? = nil) {
        self.`givenName` = givenName
        self.`familyName` = familyName
        self.`formatted` = formatted
    }
    enum CodingKeys: String, CodingKey { case `givenName`, `familyName`, `formatted` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`givenName` = try c.decodeOptional(String.self, forKey: .`givenName`)
        self.`familyName` = try c.decodeOptional(String.self, forKey: .`familyName`)
        self.`formatted` = try c.decodeOptional(String.self, forKey: .`formatted`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(`givenName`, forKey: .`givenName`)
        try c.encodeIfPresent(`familyName`, forKey: .`familyName`)
        try c.encodeIfPresent(`formatted`, forKey: .`formatted`)
    }
}

public struct HostOperationResults: Codable, Hashable {
    public var `machineId`: ID
    public var `state`: String
    public var `reason`: String?
    public init(machineId: ID, state: String, reason: String? = nil) {
        self.`machineId` = machineId
        self.`state` = state
        self.`reason` = reason
    }
    enum CodingKeys: String, CodingKey { case `machineId`, `state`, `reason` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`machineId` = try c.decode(ID.self, forKey: .`machineId`)
        self.`state` = try c.decode(String.self, forKey: .`state`)
        guard ["queued", "running", "succeeded", "skipped", "failed", "outcome_unknown"].contains(`state`) else { throw DecodingError.dataCorruptedError(forKey: .`state`, in: c, debugDescription: "Invalid HostOperationResults.state") }
        self.`reason` = try c.decode(String?.self, forKey: .`reason`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`machineId`, forKey: .`machineId`)
        try c.encode(`state`, forKey: .`state`)
        try c.encode(`reason`, forKey: .`reason`)
    }
}

public struct SetupRunEntryResults: Codable, Hashable {
    public var `entryId`: String
    public var `state`: String
    public var `exitCode`: Int?
    public var `summary`: String
    public init(entryId: String, state: String, exitCode: Int? = nil, summary: String) {
        self.`entryId` = entryId
        self.`state` = state
        self.`exitCode` = exitCode
        self.`summary` = summary
    }
    enum CodingKeys: String, CodingKey { case `entryId`, `state`, `exitCode`, `summary` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`entryId` = try c.decode(String.self, forKey: .`entryId`)
        self.`state` = try c.decode(String.self, forKey: .`state`)
        guard ["pending", "skipped", "succeeded", "failed"].contains(`state`) else { throw DecodingError.dataCorruptedError(forKey: .`state`, in: c, debugDescription: "Invalid SetupRunEntryResults.state") }
        self.`exitCode` = try c.decode(Int?.self, forKey: .`exitCode`)
        self.`summary` = try c.decode(String.self, forKey: .`summary`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`entryId`, forKey: .`entryId`)
        try c.encode(`state`, forKey: .`state`)
        try c.encode(`exitCode`, forKey: .`exitCode`)
        try c.encode(`summary`, forKey: .`summary`)
    }
}

public struct SetupManifestUpdateEntries: Codable, Hashable, Identifiable {
    public var `id`: String
    public var `setupScript`: String
    public var `checkScript`: String?
    public var `secretNames`: [String]
    public var `timeoutMs`: Int
    public init(id: String, setupScript: String, checkScript: String? = nil, secretNames: [String], timeoutMs: Int) {
        self.`id` = id
        self.`setupScript` = setupScript
        self.`checkScript` = checkScript
        self.`secretNames` = secretNames
        self.`timeoutMs` = timeoutMs
    }
    enum CodingKeys: String, CodingKey { case `id`, `setupScript`, `checkScript`, `secretNames`, `timeoutMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(String.self, forKey: .`id`)
        self.`setupScript` = try c.decode(String.self, forKey: .`setupScript`)
        self.`checkScript` = try c.decode(String?.self, forKey: .`checkScript`)
        self.`secretNames` = try c.decode([String].self, forKey: .`secretNames`)
        self.`timeoutMs` = try c.decode(Int.self, forKey: .`timeoutMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`setupScript`, forKey: .`setupScript`)
        try c.encode(`checkScript`, forKey: .`checkScript`)
        try c.encode(`secretNames`, forKey: .`secretNames`)
        try c.encode(`timeoutMs`, forKey: .`timeoutMs`)
    }
}

public struct SetupManifestCreateEntries: Codable, Hashable, Identifiable {
    public var `id`: String
    public var `setupScript`: String
    public var `checkScript`: String?
    public var `secretNames`: [String]
    public var `timeoutMs`: Int
    public init(id: String, setupScript: String, checkScript: String? = nil, secretNames: [String], timeoutMs: Int) {
        self.`id` = id
        self.`setupScript` = setupScript
        self.`checkScript` = checkScript
        self.`secretNames` = secretNames
        self.`timeoutMs` = timeoutMs
    }
    enum CodingKeys: String, CodingKey { case `id`, `setupScript`, `checkScript`, `secretNames`, `timeoutMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(String.self, forKey: .`id`)
        self.`setupScript` = try c.decode(String.self, forKey: .`setupScript`)
        self.`checkScript` = try c.decode(String?.self, forKey: .`checkScript`)
        self.`secretNames` = try c.decode([String].self, forKey: .`secretNames`)
        self.`timeoutMs` = try c.decode(Int.self, forKey: .`timeoutMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`setupScript`, forKey: .`setupScript`)
        try c.encode(`checkScript`, forKey: .`checkScript`)
        try c.encode(`secretNames`, forKey: .`secretNames`)
        try c.encode(`timeoutMs`, forKey: .`timeoutMs`)
    }
}

public struct SetupManifestEntries: Codable, Hashable, Identifiable {
    public var `id`: String
    public var `setupScript`: String
    public var `checkScript`: String?
    public var `secretNames`: [String]
    public var `timeoutMs`: Int
    public init(id: String, setupScript: String, checkScript: String? = nil, secretNames: [String], timeoutMs: Int) {
        self.`id` = id
        self.`setupScript` = setupScript
        self.`checkScript` = checkScript
        self.`secretNames` = secretNames
        self.`timeoutMs` = timeoutMs
    }
    enum CodingKeys: String, CodingKey { case `id`, `setupScript`, `checkScript`, `secretNames`, `timeoutMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(String.self, forKey: .`id`)
        self.`setupScript` = try c.decode(String.self, forKey: .`setupScript`)
        self.`checkScript` = try c.decode(String?.self, forKey: .`checkScript`)
        self.`secretNames` = try c.decode([String].self, forKey: .`secretNames`)
        self.`timeoutMs` = try c.decode(Int.self, forKey: .`timeoutMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`setupScript`, forKey: .`setupScript`)
        try c.encode(`checkScript`, forKey: .`checkScript`)
        try c.encode(`secretNames`, forKey: .`secretNames`)
        try c.encode(`timeoutMs`, forKey: .`timeoutMs`)
    }
}

public struct GovernanceUpdateInactiveHostPolicy: Codable, Hashable {
    public var `enabled`: Bool
    public var `afterDays`: Int
    public var `action`: String
    public init(enabled: Bool, afterDays: Int, action: String) {
        self.`enabled` = enabled
        self.`afterDays` = afterDays
        self.`action` = action
    }
    enum CodingKeys: String, CodingKey { case `enabled`, `afterDays`, `action` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`enabled` = try c.decode(Bool.self, forKey: .`enabled`)
        self.`afterDays` = try c.decode(Int.self, forKey: .`afterDays`)
        self.`action` = try c.decode(String.self, forKey: .`action`)
        guard ["suspend", "stop_worker"].contains(`action`) else { throw DecodingError.dataCorruptedError(forKey: .`action`, in: c, debugDescription: "Invalid GovernanceUpdateInactiveHostPolicy.action") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`enabled`, forKey: .`enabled`)
        try c.encode(`afterDays`, forKey: .`afterDays`)
        try c.encode(`action`, forKey: .`action`)
    }
}

public struct GovernanceInactiveHostPolicy: Codable, Hashable {
    public var `enabled`: Bool
    public var `afterDays`: Int
    public var `action`: String
    public init(enabled: Bool, afterDays: Int, action: String) {
        self.`enabled` = enabled
        self.`afterDays` = afterDays
        self.`action` = action
    }
    enum CodingKeys: String, CodingKey { case `enabled`, `afterDays`, `action` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`enabled` = try c.decode(Bool.self, forKey: .`enabled`)
        self.`afterDays` = try c.decode(Int.self, forKey: .`afterDays`)
        self.`action` = try c.decode(String.self, forKey: .`action`)
        guard ["suspend", "stop_worker"].contains(`action`) else { throw DecodingError.dataCorruptedError(forKey: .`action`, in: c, debugDescription: "Invalid GovernanceInactiveHostPolicy.action") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`enabled`, forKey: .`enabled`)
        try c.encode(`afterDays`, forKey: .`afterDays`)
        try c.encode(`action`, forKey: .`action`)
    }
}

public struct MCPCallResultContent: Codable, Hashable {
    public var `type`: String
    public var `text`: String
    public init(type: String, text: String) {
        self.`type` = type
        self.`text` = text
    }
    enum CodingKeys: String, CodingKey { case `type`, `text` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        guard ["text"].contains(`type`) else { throw DecodingError.dataCorruptedError(forKey: .`type`, in: c, debugDescription: "Invalid MCPCallResultContent.type") }
        self.`text` = try c.decode(String.self, forKey: .`text`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encode(`text`, forKey: .`text`)
    }
}

public struct SnapshotHasMore: Codable, Hashable {
    public var `bots`: Bool
    public var `machines`: Bool
    public var `conversations`: Bool
    public var `notifications`: Bool
    public init(bots: Bool, machines: Bool, conversations: Bool, notifications: Bool) {
        self.`bots` = bots
        self.`machines` = machines
        self.`conversations` = conversations
        self.`notifications` = notifications
    }
    enum CodingKeys: String, CodingKey { case `bots`, `machines`, `conversations`, `notifications` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`bots` = try c.decode(Bool.self, forKey: .`bots`)
        self.`machines` = try c.decode(Bool.self, forKey: .`machines`)
        self.`conversations` = try c.decode(Bool.self, forKey: .`conversations`)
        self.`notifications` = try c.decode(Bool.self, forKey: .`notifications`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`bots`, forKey: .`bots`)
        try c.encode(`machines`, forKey: .`machines`)
        try c.encode(`conversations`, forKey: .`conversations`)
        try c.encode(`notifications`, forKey: .`notifications`)
    }
}

public struct ConnectorSetupRequestSecretBindings: Codable, Hashable {
    public var `header`: String
    public var `secretName`: String
    public init(header: String, secretName: String) {
        self.`header` = header
        self.`secretName` = secretName
    }
    enum CodingKeys: String, CodingKey { case `header`, `secretName` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`header` = try c.decode(String.self, forKey: .`header`)
        self.`secretName` = try c.decode(String.self, forKey: .`secretName`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`header`, forKey: .`header`)
        try c.encode(`secretName`, forKey: .`secretName`)
    }
}

public struct MemoryImportPreviewExclusions: Codable, Hashable {
    public var `locator`: String
    public var `reason`: String
    public var `summary`: String
    public init(locator: String, reason: String, summary: String) {
        self.`locator` = locator
        self.`reason` = reason
        self.`summary` = summary
    }
    enum CodingKeys: String, CodingKey { case `locator`, `reason`, `summary` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`locator` = try c.decode(String.self, forKey: .`locator`)
        self.`reason` = try c.decode(String.self, forKey: .`reason`)
        guard ["credential", "private_profile", "unsupported", "duplicate", "not_durable"].contains(`reason`) else { throw DecodingError.dataCorruptedError(forKey: .`reason`, in: c, debugDescription: "Invalid MemoryImportPreviewExclusions.reason") }
        self.`summary` = try c.decode(String.self, forKey: .`summary`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`locator`, forKey: .`locator`)
        try c.encode(`reason`, forKey: .`reason`)
        try c.encode(`summary`, forKey: .`summary`)
    }
}

public struct MemoryImportCandidateSource: Codable, Hashable {
    public var `filename`: String?
    public var `locator`: String
    public var `excerpt`: String
    public init(filename: String? = nil, locator: String, excerpt: String) {
        self.`filename` = filename
        self.`locator` = locator
        self.`excerpt` = excerpt
    }
    enum CodingKeys: String, CodingKey { case `filename`, `locator`, `excerpt` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`filename` = try c.decode(String?.self, forKey: .`filename`)
        self.`locator` = try c.decode(String.self, forKey: .`locator`)
        self.`excerpt` = try c.decode(String.self, forKey: .`excerpt`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`filename`, forKey: .`filename`)
        try c.encode(`locator`, forKey: .`locator`)
        try c.encode(`excerpt`, forKey: .`excerpt`)
    }
}

public struct TranscriptionSegments: Codable, Hashable {
    public var `text`: String
    public var `startMs`: Int
    public var `endMs`: Int
    public init(text: String, startMs: Int, endMs: Int) {
        self.`text` = text
        self.`startMs` = startMs
        self.`endMs` = endMs
    }
    enum CodingKeys: String, CodingKey { case `text`, `startMs`, `endMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`text` = try c.decode(String.self, forKey: .`text`)
        self.`startMs` = try c.decode(Int.self, forKey: .`startMs`)
        self.`endMs` = try c.decode(Int.self, forKey: .`endMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`text`, forKey: .`text`)
        try c.encode(`startMs`, forKey: .`startMs`)
        try c.encode(`endMs`, forKey: .`endMs`)
    }
}

public struct ChannelBindingCapabilities: Codable, Hashable {
    public var `events`: [String]
    public var `inbound`: Bool
    public var `outbound`: Bool
    public init(events: [String], inbound: Bool, outbound: Bool) {
        self.`events` = events
        self.`inbound` = inbound
        self.`outbound` = outbound
    }
    enum CodingKeys: String, CodingKey { case `events`, `inbound`, `outbound` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`events` = try c.decode([String].self, forKey: .`events`)
        self.`inbound` = try c.decode(Bool.self, forKey: .`inbound`)
        self.`outbound` = try c.decode(Bool.self, forKey: .`outbound`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`events`, forKey: .`events`)
        try c.encode(`inbound`, forKey: .`inbound`)
        try c.encode(`outbound`, forKey: .`outbound`)
    }
}

public struct ConnectorUpdateSecretBindings: Codable, Hashable {
    public var `header`: String
    public var `secretName`: String
    public init(header: String, secretName: String) {
        self.`header` = header
        self.`secretName` = secretName
    }
    enum CodingKeys: String, CodingKey { case `header`, `secretName` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`header` = try c.decode(String.self, forKey: .`header`)
        self.`secretName` = try c.decode(String.self, forKey: .`secretName`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`header`, forKey: .`header`)
        try c.encode(`secretName`, forKey: .`secretName`)
    }
}

public struct ConnectorUpdateTools: Codable, Hashable {
    public var `name`: String
    public var `enabled`: Bool
    public init(name: String, enabled: Bool) {
        self.`name` = name
        self.`enabled` = enabled
    }
    enum CodingKeys: String, CodingKey { case `name`, `enabled` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`enabled` = try c.decode(Bool.self, forKey: .`enabled`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`enabled`, forKey: .`enabled`)
    }
}

public struct ConnectorCreateSecretBindings: Codable, Hashable {
    public var `header`: String
    public var `secretName`: String
    public init(header: String, secretName: String) {
        self.`header` = header
        self.`secretName` = secretName
    }
    enum CodingKeys: String, CodingKey { case `header`, `secretName` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`header` = try c.decode(String.self, forKey: .`header`)
        self.`secretName` = try c.decode(String.self, forKey: .`secretName`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`header`, forKey: .`header`)
        try c.encode(`secretName`, forKey: .`secretName`)
    }
}

public struct ConnectorTools: Codable, Hashable {
    public var `name`: String
    public var `enabled`: Bool
    public init(name: String, enabled: Bool) {
        self.`name` = name
        self.`enabled` = enabled
    }
    enum CodingKeys: String, CodingKey { case `name`, `enabled` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`enabled` = try c.decode(Bool.self, forKey: .`enabled`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`enabled`, forKey: .`enabled`)
    }
}

public struct SkillProvenance: Codable, Hashable {
    public var `sourceUrl`: String?
    public var `publisher`: String
    public var `trusted`: Bool
    public init(sourceUrl: String? = nil, publisher: String, trusted: Bool) {
        self.`sourceUrl` = sourceUrl
        self.`publisher` = publisher
        self.`trusted` = trusted
    }
    enum CodingKeys: String, CodingKey { case `sourceUrl`, `publisher`, `trusted` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`sourceUrl` = try c.decode(String?.self, forKey: .`sourceUrl`)
        self.`publisher` = try c.decode(String.self, forKey: .`publisher`)
        self.`trusted` = try c.decode(Bool.self, forKey: .`trusted`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`sourceUrl`, forKey: .`sourceUrl`)
        try c.encode(`publisher`, forKey: .`publisher`)
        try c.encode(`trusted`, forKey: .`trusted`)
    }
}

public struct FieldOptions: Codable, Hashable {
    public var `value`: String
    public var `label`: String
    public init(value: String, label: String) {
        self.`value` = value
        self.`label` = label
    }
    enum CodingKeys: String, CodingKey { case `value`, `label` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`value` = try c.decode(String.self, forKey: .`value`)
        self.`label` = try c.decode(String.self, forKey: .`label`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`value`, forKey: .`value`)
        try c.encode(`label`, forKey: .`label`)
    }
}

public struct MessageReceiptDelivery: Codable, Hashable {
    public var `botId`: ID
    public var `requestedMode`: String
    public var `effectiveMode`: String
    public var `targetRunId`: ID?
    public var `runId`: ID
    public init(botId: ID, requestedMode: String, effectiveMode: String, targetRunId: ID? = nil, runId: ID) {
        self.`botId` = botId
        self.`requestedMode` = requestedMode
        self.`effectiveMode` = effectiveMode
        self.`targetRunId` = targetRunId
        self.`runId` = runId
    }
    enum CodingKeys: String, CodingKey { case `botId`, `requestedMode`, `effectiveMode`, `targetRunId`, `runId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`botId` = try c.decode(ID.self, forKey: .`botId`)
        self.`requestedMode` = try c.decode(String.self, forKey: .`requestedMode`)
        guard ["followup", "steer", "interrupt"].contains(`requestedMode`) else { throw DecodingError.dataCorruptedError(forKey: .`requestedMode`, in: c, debugDescription: "Invalid MessageReceiptDelivery.requestedMode") }
        self.`effectiveMode` = try c.decode(String.self, forKey: .`effectiveMode`)
        guard ["queued", "steering", "interrupting", "started", "rejected", "outcome_unknown"].contains(`effectiveMode`) else { throw DecodingError.dataCorruptedError(forKey: .`effectiveMode`, in: c, debugDescription: "Invalid MessageReceiptDelivery.effectiveMode") }
        self.`targetRunId` = try c.decode(ID?.self, forKey: .`targetRunId`)
        self.`runId` = try c.decode(ID.self, forKey: .`runId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`requestedMode`, forKey: .`requestedMode`)
        try c.encode(`effectiveMode`, forKey: .`effectiveMode`)
        try c.encode(`targetRunId`, forKey: .`targetRunId`)
        try c.encode(`runId`, forKey: .`runId`)
    }
}

public struct RunError: Codable, Hashable {
    public var `code`: ErrorCode
    public var `message`: String
    public var `requestId`: String
    public var `retrySafe`: Bool
    public var `details`: JSONObject?
    public init(code: ErrorCode, message: String, requestId: String, retrySafe: Bool, details: JSONObject? = nil) {
        self.`code` = code
        self.`message` = message
        self.`requestId` = requestId
        self.`retrySafe` = retrySafe
        self.`details` = details
    }
    enum CodingKeys: String, CodingKey { case `code`, `message`, `requestId`, `retrySafe`, `details` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`code` = try c.decode(ErrorCode.self, forKey: .`code`)
        self.`message` = try c.decode(String.self, forKey: .`message`)
        self.`requestId` = try c.decode(String.self, forKey: .`requestId`)
        self.`retrySafe` = try c.decode(Bool.self, forKey: .`retrySafe`)
        self.`details` = try c.decodeOptional(JSONObject.self, forKey: .`details`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`code`, forKey: .`code`)
        try c.encode(`message`, forKey: .`message`)
        try c.encode(`requestId`, forKey: .`requestId`)
        try c.encode(`retrySafe`, forKey: .`retrySafe`)
        try c.encodeIfPresent(`details`, forKey: .`details`)
    }
}

public struct ConversationActivity: Codable, Hashable {
    public var `botId`: ID
    public var `phase`: String
    public init(botId: ID, phase: String) {
        self.`botId` = botId
        self.`phase` = phase
    }
    enum CodingKeys: String, CodingKey { case `botId`, `phase` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`botId` = try c.decode(ID.self, forKey: .`botId`)
        self.`phase` = try c.decode(String.self, forKey: .`phase`)
        guard ["reading", "working", "typing"].contains(`phase`) else { throw DecodingError.dataCorruptedError(forKey: .`phase`, in: c, debugDescription: "Invalid ConversationActivity.phase") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`botId`, forKey: .`botId`)
        try c.encode(`phase`, forKey: .`phase`)
    }
}

public struct BotTemplateProvenance: Codable, Hashable {
    public var `publisher`: String
    public var `sourceUrl`: String?
    public var `termsUrl`: String?
    public var `thirdParty`: Bool
    public init(publisher: String, sourceUrl: String? = nil, termsUrl: String? = nil, thirdParty: Bool) {
        self.`publisher` = publisher
        self.`sourceUrl` = sourceUrl
        self.`termsUrl` = termsUrl
        self.`thirdParty` = thirdParty
    }
    enum CodingKeys: String, CodingKey { case `publisher`, `sourceUrl`, `termsUrl`, `thirdParty` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`publisher` = try c.decode(String.self, forKey: .`publisher`)
        self.`sourceUrl` = try c.decode(String?.self, forKey: .`sourceUrl`)
        self.`termsUrl` = try c.decode(String?.self, forKey: .`termsUrl`)
        self.`thirdParty` = try c.decode(Bool.self, forKey: .`thirdParty`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`publisher`, forKey: .`publisher`)
        try c.encode(`sourceUrl`, forKey: .`sourceUrl`)
        try c.encode(`termsUrl`, forKey: .`termsUrl`)
        try c.encode(`thirdParty`, forKey: .`thirdParty`)
    }
}

public struct TemplateContentSkills: Codable, Hashable {
    public var `name`: String
    public var `description`: String
    public var `markdown`: String
    public init(name: String, description: String, markdown: String) {
        self.`name` = name
        self.`description` = description
        self.`markdown` = markdown
    }
    enum CodingKeys: String, CodingKey { case `name`, `description`, `markdown` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`description` = try c.decode(String.self, forKey: .`description`)
        self.`markdown` = try c.decode(String.self, forKey: .`markdown`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`description`, forKey: .`description`)
        try c.encode(`markdown`, forKey: .`markdown`)
    }
}

public struct CapabilitiesMinClientVersions: Codable, Hashable {
    public var `web`: String
    public var `macos`: String
    public var `ios`: String
    public init(web: String, macos: String, ios: String) {
        self.`web` = web
        self.`macos` = macos
        self.`ios` = ios
    }
    enum CodingKeys: String, CodingKey { case `web`, `macos`, `ios` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`web` = try c.decode(String.self, forKey: .`web`)
        self.`macos` = try c.decode(String.self, forKey: .`macos`)
        self.`ios` = try c.decode(String.self, forKey: .`ios`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`web`, forKey: .`web`)
        try c.encode(`macos`, forKey: .`macos`)
        try c.encode(`ios`, forKey: .`ios`)
    }
}

public struct ErrorEnvelopeError: Codable, Hashable {
    public var `code`: ErrorCode
    public var `message`: String
    public var `requestId`: String
    public var `retrySafe`: Bool
    public var `details`: JSONObject?
    public init(code: ErrorCode, message: String, requestId: String, retrySafe: Bool, details: JSONObject? = nil) {
        self.`code` = code
        self.`message` = message
        self.`requestId` = requestId
        self.`retrySafe` = retrySafe
        self.`details` = details
    }
    enum CodingKeys: String, CodingKey { case `code`, `message`, `requestId`, `retrySafe`, `details` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`code` = try c.decode(ErrorCode.self, forKey: .`code`)
        self.`message` = try c.decode(String.self, forKey: .`message`)
        self.`requestId` = try c.decode(String.self, forKey: .`requestId`)
        self.`retrySafe` = try c.decode(Bool.self, forKey: .`retrySafe`)
        self.`details` = try c.decodeOptional(JSONObject.self, forKey: .`details`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`code`, forKey: .`code`)
        try c.encode(`message`, forKey: .`message`)
        try c.encode(`requestId`, forKey: .`requestId`)
        try c.encode(`retrySafe`, forKey: .`retrySafe`)
        try c.encodeIfPresent(`details`, forKey: .`details`)
    }
}

public typealias ID = String

public typealias Cursor = String

public typealias TimestampMs = Double

public typealias BinaryBody = Data

extension TranscriptEntry: Identifiable {
    public var `id`: ID { switch self {
        case .unsupported(let v): return v.`id`
        case .`message`(let v): return v.`id`
        case .`card`(let v): return v.`id`
        case .`userAttachment`(let v): return v.`id`
        case .`toolCall`(let v): return v.`id`
        case .`mcpApp`(let v): return v.`id`
        case .`notice`(let v): return v.`id`
        case .`event`(let v): return v.`id`
        case .`feedback`(let v): return v.`id`
        case .`voiceCall`(let v): return v.`id`
    } }
    public var `revision`: Int { switch self {
        case .unsupported(let v): return v.`revision`
        case .`message`(let v): return v.`revision`
        case .`card`(let v): return v.`revision`
        case .`userAttachment`(let v): return v.`revision`
        case .`toolCall`(let v): return v.`revision`
        case .`mcpApp`(let v): return v.`revision`
        case .`notice`(let v): return v.`revision`
        case .`event`(let v): return v.`revision`
        case .`feedback`(let v): return v.`revision`
        case .`voiceCall`(let v): return v.`revision`
    } }
    public var `createdAtMs`: TimestampMs { switch self {
        case .unsupported(let v): return v.`createdAtMs`
        case .`message`(let v): return v.`createdAtMs`
        case .`card`(let v): return v.`createdAtMs`
        case .`userAttachment`(let v): return v.`createdAtMs`
        case .`toolCall`(let v): return v.`createdAtMs`
        case .`mcpApp`(let v): return v.`createdAtMs`
        case .`notice`(let v): return v.`createdAtMs`
        case .`event`(let v): return v.`createdAtMs`
        case .`feedback`(let v): return v.`createdAtMs`
        case .`voiceCall`(let v): return v.`createdAtMs`
    } }
    public var `updatedAtMs`: TimestampMs { switch self {
        case .unsupported(let v): return v.`updatedAtMs`
        case .`message`(let v): return v.`updatedAtMs`
        case .`card`(let v): return v.`updatedAtMs`
        case .`userAttachment`(let v): return v.`updatedAtMs`
        case .`toolCall`(let v): return v.`updatedAtMs`
        case .`mcpApp`(let v): return v.`updatedAtMs`
        case .`notice`(let v): return v.`updatedAtMs`
        case .`event`(let v): return v.`updatedAtMs`
        case .`feedback`(let v): return v.`updatedAtMs`
        case .`voiceCall`(let v): return v.`updatedAtMs`
    } }
    public var `conversationId`: ID { switch self {
        case .unsupported(let v): return v.`conversationId`
        case .`message`(let v): return v.`conversationId`
        case .`card`(let v): return v.`conversationId`
        case .`userAttachment`(let v): return v.`conversationId`
        case .`toolCall`(let v): return v.`conversationId`
        case .`mcpApp`(let v): return v.`conversationId`
        case .`notice`(let v): return v.`conversationId`
        case .`event`(let v): return v.`conversationId`
        case .`feedback`(let v): return v.`conversationId`
        case .`voiceCall`(let v): return v.`conversationId`
    } }
    public var `seq`: Int { switch self {
        case .unsupported(let v): return v.`seq`
        case .`message`(let v): return v.`seq`
        case .`card`(let v): return v.`seq`
        case .`userAttachment`(let v): return v.`seq`
        case .`toolCall`(let v): return v.`seq`
        case .`mcpApp`(let v): return v.`seq`
        case .`notice`(let v): return v.`seq`
        case .`event`(let v): return v.`seq`
        case .`feedback`(let v): return v.`seq`
        case .`voiceCall`(let v): return v.`seq`
    } }
    public var `timestampMs`: TimestampMs { switch self {
        case .unsupported(let v): return v.`timestampMs`
        case .`message`(let v): return v.`timestampMs`
        case .`card`(let v): return v.`timestampMs`
        case .`userAttachment`(let v): return v.`timestampMs`
        case .`toolCall`(let v): return v.`timestampMs`
        case .`mcpApp`(let v): return v.`timestampMs`
        case .`notice`(let v): return v.`timestampMs`
        case .`event`(let v): return v.`timestampMs`
        case .`feedback`(let v): return v.`timestampMs`
        case .`voiceCall`(let v): return v.`timestampMs`
    } }
    public var `actor`: Actor { switch self {
        case .unsupported(let v): return v.`actor`
        case .`message`(let v): return v.`actor`
        case .`card`(let v): return v.`actor`
        case .`userAttachment`(let v): return v.`actor`
        case .`toolCall`(let v): return v.`actor`
        case .`mcpApp`(let v): return v.`actor`
        case .`notice`(let v): return v.`actor`
        case .`event`(let v): return v.`actor`
        case .`feedback`(let v): return v.`actor`
        case .`voiceCall`(let v): return v.`actor`
    } }
    public var `clientNonce`: String? { switch self {
        case .unsupported(let v): return v.`clientNonce`
        case .`message`(let v): return v.`clientNonce`
        case .`card`(let v): return v.`clientNonce`
        case .`userAttachment`(let v): return v.`clientNonce`
        case .`toolCall`(let v): return v.`clientNonce`
        case .`mcpApp`(let v): return v.`clientNonce`
        case .`notice`(let v): return v.`clientNonce`
        case .`event`(let v): return v.`clientNonce`
        case .`feedback`(let v): return v.`clientNonce`
        case .`voiceCall`(let v): return v.`clientNonce`
    } }
    public var `batchId`: ID? { switch self {
        case .unsupported(let v): return v.`batchId`
        case .`message`(let v): return v.`batchId`
        case .`card`(let v): return v.`batchId`
        case .`userAttachment`(let v): return v.`batchId`
        case .`toolCall`(let v): return v.`batchId`
        case .`mcpApp`(let v): return v.`batchId`
        case .`notice`(let v): return v.`batchId`
        case .`event`(let v): return v.`batchId`
        case .`feedback`(let v): return v.`batchId`
        case .`voiceCall`(let v): return v.`batchId`
    } }
    public var `replyToEntryId`: ID? { switch self {
        case .unsupported(let v): return v.`replyToEntryId`
        case .`message`(let v): return v.`replyToEntryId`
        case .`card`(let v): return v.`replyToEntryId`
        case .`userAttachment`(let v): return v.`replyToEntryId`
        case .`toolCall`(let v): return v.`replyToEntryId`
        case .`mcpApp`(let v): return v.`replyToEntryId`
        case .`notice`(let v): return v.`replyToEntryId`
        case .`event`(let v): return v.`replyToEntryId`
        case .`feedback`(let v): return v.`replyToEntryId`
        case .`voiceCall`(let v): return v.`replyToEntryId`
    } }
    public var `runId`: ID? { switch self {
        case .unsupported(let v): return v.`runId`
        case .`message`(let v): return v.`runId`
        case .`card`(let v): return v.`runId`
        case .`userAttachment`(let v): return v.`runId`
        case .`toolCall`(let v): return v.`runId`
        case .`mcpApp`(let v): return v.`runId`
        case .`notice`(let v): return v.`runId`
        case .`event`(let v): return v.`runId`
        case .`feedback`(let v): return v.`runId`
        case .`voiceCall`(let v): return v.`runId`
    } }
    public var `targetedUserId`: ID? { switch self {
        case .unsupported(let v): return v.`targetedUserId`
        case .`message`(let v): return v.`targetedUserId`
        case .`card`(let v): return v.`targetedUserId`
        case .`userAttachment`(let v): return v.`targetedUserId`
        case .`toolCall`(let v): return v.`targetedUserId`
        case .`mcpApp`(let v): return v.`targetedUserId`
        case .`notice`(let v): return v.`targetedUserId`
        case .`event`(let v): return v.`targetedUserId`
        case .`feedback`(let v): return v.`targetedUserId`
        case .`voiceCall`(let v): return v.`targetedUserId`
    } }
    public var `reactions`: [Reaction] { switch self {
        case .unsupported(let v): return v.`reactions`
        case .`message`(let v): return v.`reactions`
        case .`card`(let v): return v.`reactions`
        case .`userAttachment`(let v): return v.`reactions`
        case .`toolCall`(let v): return v.`reactions`
        case .`mcpApp`(let v): return v.`reactions`
        case .`notice`(let v): return v.`reactions`
        case .`event`(let v): return v.`reactions`
        case .`feedback`(let v): return v.`reactions`
        case .`voiceCall`(let v): return v.`reactions`
    } }
    public var text: String? { if case .unsupported(let v) = self { return v.text }; if case .message(let v) = self { return v.text }; if case .notice(let v) = self { return v.text }; return nil }
    public var role: String? { if case .message(let v) = self { return v.role }; return nil }
    public var streaming: Bool { if case .message(let v) = self { return v.streaming }; return false }
}

public struct ChannelLinkStart: Codable, Hashable {
    public var `clientNonce`: String
    public var `channelBindingId`: ID
    public init(clientNonce: String, channelBindingId: ID) {
        self.`clientNonce` = clientNonce
        self.`channelBindingId` = channelBindingId
    }
    enum CodingKeys: String, CodingKey { case `clientNonce`, `channelBindingId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`clientNonce` = try c.decode(String.self, forKey: .`clientNonce`)
        self.`channelBindingId` = try c.decode(ID.self, forKey: .`channelBindingId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`channelBindingId`, forKey: .`channelBindingId`)
    }
}

public struct ChannelLinkFlow: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `userId`: ID
    public var `channelBindingId`: ID
    public var `state`: String
    public var `linkCode`: String?
    public var `instructions`: String
    public var `externalUserId`: String?
    public var `externalDisplayName`: String?
    public var `verificationCode`: String?
    public var `expiresAtMs`: TimestampMs
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, userId: ID, channelBindingId: ID, state: String, linkCode: String? = nil, instructions: String, externalUserId: String? = nil, externalDisplayName: String? = nil, verificationCode: String? = nil, expiresAtMs: TimestampMs) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`userId` = userId
        self.`channelBindingId` = channelBindingId
        self.`state` = state
        self.`linkCode` = linkCode
        self.`instructions` = instructions
        self.`externalUserId` = externalUserId
        self.`externalDisplayName` = externalDisplayName
        self.`verificationCode` = verificationCode
        self.`expiresAtMs` = expiresAtMs
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `userId`, `channelBindingId`, `state`, `linkCode`, `instructions`, `externalUserId`, `externalDisplayName`, `verificationCode`, `expiresAtMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`userId` = try c.decode(ID.self, forKey: .`userId`)
        self.`channelBindingId` = try c.decode(ID.self, forKey: .`channelBindingId`)
        self.`state` = try c.decode(String.self, forKey: .`state`)
        guard ["issued", "awaiting_external", "verified", "completed", "expired", "cancelled"].contains(`state`) else { throw DecodingError.dataCorruptedError(forKey: .`state`, in: c, debugDescription: "Invalid ChannelLinkFlow.state") }
        self.`linkCode` = try c.decode(String?.self, forKey: .`linkCode`)
        self.`instructions` = try c.decode(String.self, forKey: .`instructions`)
        self.`externalUserId` = try c.decode(String?.self, forKey: .`externalUserId`)
        self.`externalDisplayName` = try c.decode(String?.self, forKey: .`externalDisplayName`)
        self.`verificationCode` = try c.decode(String?.self, forKey: .`verificationCode`)
        self.`expiresAtMs` = try c.decode(TimestampMs.self, forKey: .`expiresAtMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`userId`, forKey: .`userId`)
        try c.encode(`channelBindingId`, forKey: .`channelBindingId`)
        try c.encode(`state`, forKey: .`state`)
        try c.encode(`linkCode`, forKey: .`linkCode`)
        try c.encode(`instructions`, forKey: .`instructions`)
        try c.encode(`externalUserId`, forKey: .`externalUserId`)
        try c.encode(`externalDisplayName`, forKey: .`externalDisplayName`)
        try c.encode(`verificationCode`, forKey: .`verificationCode`)
        try c.encode(`expiresAtMs`, forKey: .`expiresAtMs`)
    }
}

public struct ConnectorProviderConfig: Codable, Hashable, Identifiable {
    public var `id`: String
    public var `origins`: [String]
    public var `oauth`: OAuthProviderConfig?
    public var `sharedServiceAccount`: Bool
    public init(id: String, origins: [String], oauth: OAuthProviderConfig? = nil, sharedServiceAccount: Bool) {
        self.`id` = id
        self.`origins` = origins
        self.`oauth` = oauth
        self.`sharedServiceAccount` = sharedServiceAccount
    }
    enum CodingKeys: String, CodingKey { case `id`, `origins`, `oauth`, `sharedServiceAccount` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(String.self, forKey: .`id`)
        self.`origins` = try c.decode([String].self, forKey: .`origins`)
        self.`oauth` = try c.decode(OAuthProviderConfig?.self, forKey: .`oauth`)
        self.`sharedServiceAccount` = try c.decode(Bool.self, forKey: .`sharedServiceAccount`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`origins`, forKey: .`origins`)
        try c.encode(`oauth`, forKey: .`oauth`)
        try c.encode(`sharedServiceAccount`, forKey: .`sharedServiceAccount`)
    }
}

public struct ReviewedSetupManifest: Codable, Hashable {
    public var `name`: String
    public var `directoryGroupId`: ID?
    public var `machineIds`: [ID]
    public var `entries`: [ReviewedSetupManifestEntries]
    public init(name: String, directoryGroupId: ID? = nil, machineIds: [ID], entries: [ReviewedSetupManifestEntries]) {
        self.`name` = name
        self.`directoryGroupId` = directoryGroupId
        self.`machineIds` = machineIds
        self.`entries` = entries
    }
    enum CodingKeys: String, CodingKey { case `name`, `directoryGroupId`, `machineIds`, `entries` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`directoryGroupId` = try c.decode(ID?.self, forKey: .`directoryGroupId`)
        self.`machineIds` = try c.decode([ID].self, forKey: .`machineIds`)
        self.`entries` = try c.decode([ReviewedSetupManifestEntries].self, forKey: .`entries`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`directoryGroupId`, forKey: .`directoryGroupId`)
        try c.encode(`machineIds`, forKey: .`machineIds`)
        try c.encode(`entries`, forKey: .`entries`)
    }
}

public struct IntegrationProvider: Codable, Hashable, Identifiable {
    public var `id`: String
    public var `kind`: String
    public var `label`: String
    public var `configured`: Bool
    public var `prerequisites`: [String]
    public var `capabilities`: [String]
    public init(id: String, kind: String, label: String, configured: Bool, prerequisites: [String], capabilities: [String]) {
        self.`id` = id
        self.`kind` = kind
        self.`label` = label
        self.`configured` = configured
        self.`prerequisites` = prerequisites
        self.`capabilities` = capabilities
    }
    enum CodingKeys: String, CodingKey { case `id`, `kind`, `label`, `configured`, `prerequisites`, `capabilities` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(String.self, forKey: .`id`)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["connector", "channel", "email", "x", "event", "identity", "export", "host"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid IntegrationProvider.kind") }
        self.`label` = try c.decode(String.self, forKey: .`label`)
        self.`configured` = try c.decode(Bool.self, forKey: .`configured`)
        self.`prerequisites` = try c.decode([String].self, forKey: .`prerequisites`)
        self.`capabilities` = try c.decode([String].self, forKey: .`capabilities`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`label`, forKey: .`label`)
        try c.encode(`configured`, forKey: .`configured`)
        try c.encode(`prerequisites`, forKey: .`prerequisites`)
        try c.encode(`capabilities`, forKey: .`capabilities`)
    }
}

public struct ChannelProviderInfo: Codable, Hashable, Identifiable {
    public var `id`: String
    public var `kind`: String
    public var `label`: String
    public var `configured`: Bool
    public var `prerequisites`: [String]
    public var `capabilities`: [String]
    public var `adapter`: String
    public var `supportsBotAppInstall`: Bool
    public init(id: String, kind: String, label: String, configured: Bool, prerequisites: [String], capabilities: [String], adapter: String, supportsBotAppInstall: Bool) {
        self.`id` = id
        self.`kind` = kind
        self.`label` = label
        self.`configured` = configured
        self.`prerequisites` = prerequisites
        self.`capabilities` = capabilities
        self.`adapter` = adapter
        self.`supportsBotAppInstall` = supportsBotAppInstall
    }
    enum CodingKeys: String, CodingKey { case `id`, `kind`, `label`, `configured`, `prerequisites`, `capabilities`, `adapter`, `supportsBotAppInstall` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(String.self, forKey: .`id`)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["channel"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid ChannelProviderInfo.kind") }
        self.`label` = try c.decode(String.self, forKey: .`label`)
        self.`configured` = try c.decode(Bool.self, forKey: .`configured`)
        self.`prerequisites` = try c.decode([String].self, forKey: .`prerequisites`)
        self.`capabilities` = try c.decode([String].self, forKey: .`capabilities`)
        self.`adapter` = try c.decode(String.self, forKey: .`adapter`)
        self.`supportsBotAppInstall` = try c.decode(Bool.self, forKey: .`supportsBotAppInstall`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`label`, forKey: .`label`)
        try c.encode(`configured`, forKey: .`configured`)
        try c.encode(`prerequisites`, forKey: .`prerequisites`)
        try c.encode(`capabilities`, forKey: .`capabilities`)
        try c.encode(`adapter`, forKey: .`adapter`)
        try c.encode(`supportsBotAppInstall`, forKey: .`supportsBotAppInstall`)
    }
}

public struct EmailProviderInfo: Codable, Hashable, Identifiable {
    public var `id`: String
    public var `kind`: String
    public var `label`: String
    public var `configured`: Bool
    public var `prerequisites`: [String]
    public var `capabilities`: [String]
    public var `domain`: String
    public var `immutableAddresses`: Bool
    public var `supportsProvisioning`: Bool
    public var `supportsUnsubscribe`: Bool
    public init(id: String, kind: String, label: String, configured: Bool, prerequisites: [String], capabilities: [String], domain: String, immutableAddresses: Bool, supportsProvisioning: Bool, supportsUnsubscribe: Bool) {
        self.`id` = id
        self.`kind` = kind
        self.`label` = label
        self.`configured` = configured
        self.`prerequisites` = prerequisites
        self.`capabilities` = capabilities
        self.`domain` = domain
        self.`immutableAddresses` = immutableAddresses
        self.`supportsProvisioning` = supportsProvisioning
        self.`supportsUnsubscribe` = supportsUnsubscribe
    }
    enum CodingKeys: String, CodingKey { case `id`, `kind`, `label`, `configured`, `prerequisites`, `capabilities`, `domain`, `immutableAddresses`, `supportsProvisioning`, `supportsUnsubscribe` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(String.self, forKey: .`id`)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["email"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid EmailProviderInfo.kind") }
        self.`label` = try c.decode(String.self, forKey: .`label`)
        self.`configured` = try c.decode(Bool.self, forKey: .`configured`)
        self.`prerequisites` = try c.decode([String].self, forKey: .`prerequisites`)
        self.`capabilities` = try c.decode([String].self, forKey: .`capabilities`)
        self.`domain` = try c.decode(String.self, forKey: .`domain`)
        self.`immutableAddresses` = try c.decode(Bool.self, forKey: .`immutableAddresses`)
        self.`supportsProvisioning` = try c.decode(Bool.self, forKey: .`supportsProvisioning`)
        self.`supportsUnsubscribe` = try c.decode(Bool.self, forKey: .`supportsUnsubscribe`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`label`, forKey: .`label`)
        try c.encode(`configured`, forKey: .`configured`)
        try c.encode(`prerequisites`, forKey: .`prerequisites`)
        try c.encode(`capabilities`, forKey: .`capabilities`)
        try c.encode(`domain`, forKey: .`domain`)
        try c.encode(`immutableAddresses`, forKey: .`immutableAddresses`)
        try c.encode(`supportsProvisioning`, forKey: .`supportsProvisioning`)
        try c.encode(`supportsUnsubscribe`, forKey: .`supportsUnsubscribe`)
    }
}

public struct XProviderInfo: Codable, Hashable, Identifiable {
    public var `id`: String
    public var `kind`: String
    public var `label`: String
    public var `configured`: Bool
    public var `prerequisites`: [String]
    public var `capabilities`: [String]
    public var `publicHandle`: String
    public var `oauthScopes`: [String]
    public var `allowedMedia`: [String]
    public var `deniedCountries`: [String]
    public init(id: String, kind: String, label: String, configured: Bool, prerequisites: [String], capabilities: [String], publicHandle: String, oauthScopes: [String], allowedMedia: [String], deniedCountries: [String]) {
        self.`id` = id
        self.`kind` = kind
        self.`label` = label
        self.`configured` = configured
        self.`prerequisites` = prerequisites
        self.`capabilities` = capabilities
        self.`publicHandle` = publicHandle
        self.`oauthScopes` = oauthScopes
        self.`allowedMedia` = allowedMedia
        self.`deniedCountries` = deniedCountries
    }
    enum CodingKeys: String, CodingKey { case `id`, `kind`, `label`, `configured`, `prerequisites`, `capabilities`, `publicHandle`, `oauthScopes`, `allowedMedia`, `deniedCountries` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(String.self, forKey: .`id`)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["x"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid XProviderInfo.kind") }
        self.`label` = try c.decode(String.self, forKey: .`label`)
        self.`configured` = try c.decode(Bool.self, forKey: .`configured`)
        self.`prerequisites` = try c.decode([String].self, forKey: .`prerequisites`)
        self.`capabilities` = try c.decode([String].self, forKey: .`capabilities`)
        self.`publicHandle` = try c.decode(String.self, forKey: .`publicHandle`)
        self.`oauthScopes` = try c.decode([String].self, forKey: .`oauthScopes`)
        self.`allowedMedia` = try c.decode([String].self, forKey: .`allowedMedia`)
        guard allowedMedia.allSatisfy({ XMediaValue(rawValue: $0) != nil }) else { throw DecodingError.dataCorruptedError(forKey: .`allowedMedia`, in: c, debugDescription: "Invalid XProviderInfo.allowedMedia") }
        self.`deniedCountries` = try c.decode([String].self, forKey: .`deniedCountries`)
    }
    public func encode(to encoder: Encoder) throws {
        guard allowedMedia.allSatisfy({ XMediaValue(rawValue: $0) != nil }) else { throw EncodingError.invalidValue(allowedMedia, .init(codingPath: encoder.codingPath + [CodingKeys.allowedMedia], debugDescription: "Invalid XProviderInfo.allowedMedia")) }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`label`, forKey: .`label`)
        try c.encode(`configured`, forKey: .`configured`)
        try c.encode(`prerequisites`, forKey: .`prerequisites`)
        try c.encode(`capabilities`, forKey: .`capabilities`)
        try c.encode(`publicHandle`, forKey: .`publicHandle`)
        try c.encode(`oauthScopes`, forKey: .`oauthScopes`)
        try c.encode(`allowedMedia`, forKey: .`allowedMedia`)
        try c.encode(`deniedCountries`, forKey: .`deniedCountries`)
    }
}

public struct EventDefinition: Codable, Hashable {
    public var `name`: String
    public var `label`: String
    public var `description`: String
    public var `filterSchema`: JSONObject
    public init(name: String, label: String, description: String, filterSchema: JSONObject) {
        self.`name` = name
        self.`label` = label
        self.`description` = description
        self.`filterSchema` = filterSchema
    }
    enum CodingKeys: String, CodingKey { case `name`, `label`, `description`, `filterSchema` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`name` = try c.decode(String.self, forKey: .`name`)
        self.`label` = try c.decode(String.self, forKey: .`label`)
        self.`description` = try c.decode(String.self, forKey: .`description`)
        self.`filterSchema` = try c.decode(JSONObject.self, forKey: .`filterSchema`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`name`, forKey: .`name`)
        try c.encode(`label`, forKey: .`label`)
        try c.encode(`description`, forKey: .`description`)
        try c.encode(`filterSchema`, forKey: .`filterSchema`)
    }
}

public struct ExternalSourceDefinition: Codable, Hashable {
    public var `source`: String
    public var `configured`: Bool
    public var `events`: [EventDefinition]
    public init(source: String, configured: Bool, events: [EventDefinition]) {
        self.`source` = source
        self.`configured` = configured
        self.`events` = events
    }
    enum CodingKeys: String, CodingKey { case `source`, `configured`, `events` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`source` = try c.decode(String.self, forKey: .`source`)
        self.`configured` = try c.decode(Bool.self, forKey: .`configured`)
        self.`events` = try c.decode([EventDefinition].self, forKey: .`events`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`source`, forKey: .`source`)
        try c.encode(`configured`, forKey: .`configured`)
        try c.encode(`events`, forKey: .`events`)
    }
}

public struct UnsupportedCard: Codable, Hashable {
    public var `type`: String
    public var `text`: String?
    public var `attachmentId`: ID?
    public init(type: String, text: String? = nil, attachmentId: ID? = nil) {
        self.`type` = type
        self.`text` = text
        self.`attachmentId` = attachmentId
    }
    enum CodingKeys: String, CodingKey { case `type`, `text`, `attachmentId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`type` = try c.decode(String.self, forKey: .`type`)
        self.`text` = try c.decodeIfPresent(String.self, forKey: .`text`)
        self.text = self.text.map { String($0.prefix(4096)) }
        self.`attachmentId` = try c.decodeIfPresent(ID.self, forKey: .`attachmentId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`type`, forKey: .`type`)
        try c.encodeIfPresent(`text`, forKey: .`text`)
        try c.encodeIfPresent(`attachmentId`, forKey: .`attachmentId`)
    }
}

public struct UnsupportedEntry: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `conversationId`: ID
    public var `seq`: Int
    public var `timestampMs`: TimestampMs
    public var `actor`: Actor
    public var `clientNonce`: String?
    public var `batchId`: ID?
    public var `replyToEntryId`: ID?
    public var `runId`: ID?
    public var `targetedUserId`: ID?
    public var `reactions`: [Reaction]
    public var `kind`: String
    public var `text`: String?
    public var `attachmentId`: ID?
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, conversationId: ID, seq: Int, timestampMs: TimestampMs, actor: Actor, clientNonce: String? = nil, batchId: ID? = nil, replyToEntryId: ID? = nil, runId: ID? = nil, targetedUserId: ID? = nil, reactions: [Reaction], kind: String, text: String? = nil, attachmentId: ID? = nil) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`conversationId` = conversationId
        self.`seq` = seq
        self.`timestampMs` = timestampMs
        self.`actor` = actor
        self.`clientNonce` = clientNonce
        self.`batchId` = batchId
        self.`replyToEntryId` = replyToEntryId
        self.`runId` = runId
        self.`targetedUserId` = targetedUserId
        self.`reactions` = reactions
        self.`kind` = kind
        self.`text` = text
        self.`attachmentId` = attachmentId
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `conversationId`, `seq`, `timestampMs`, `actor`, `clientNonce`, `batchId`, `replyToEntryId`, `runId`, `targetedUserId`, `reactions`, `kind`, `text`, `attachmentId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`conversationId` = try c.decode(ID.self, forKey: .`conversationId`)
        self.`seq` = try c.decode(Int.self, forKey: .`seq`)
        self.`timestampMs` = try c.decode(TimestampMs.self, forKey: .`timestampMs`)
        self.`actor` = try c.decode(Actor.self, forKey: .`actor`)
        self.`clientNonce` = try c.decode(String?.self, forKey: .`clientNonce`)
        self.`batchId` = try c.decode(ID?.self, forKey: .`batchId`)
        self.`replyToEntryId` = try c.decode(ID?.self, forKey: .`replyToEntryId`)
        self.`runId` = try c.decode(ID?.self, forKey: .`runId`)
        self.`targetedUserId` = try c.decode(ID?.self, forKey: .`targetedUserId`)
        self.`reactions` = try c.decode([Reaction].self, forKey: .`reactions`)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        self.`text` = try c.decodeIfPresent(String.self, forKey: .`text`)
        self.text = self.text.map { String($0.prefix(4096)) }
        self.`attachmentId` = try c.decodeIfPresent(ID.self, forKey: .`attachmentId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`conversationId`, forKey: .`conversationId`)
        try c.encode(`seq`, forKey: .`seq`)
        try c.encode(`timestampMs`, forKey: .`timestampMs`)
        try c.encode(`actor`, forKey: .`actor`)
        try c.encode(`clientNonce`, forKey: .`clientNonce`)
        try c.encode(`batchId`, forKey: .`batchId`)
        try c.encode(`replyToEntryId`, forKey: .`replyToEntryId`)
        try c.encode(`runId`, forKey: .`runId`)
        try c.encode(`targetedUserId`, forKey: .`targetedUserId`)
        try c.encode(`reactions`, forKey: .`reactions`)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encodeIfPresent(`text`, forKey: .`text`)
        try c.encodeIfPresent(`attachmentId`, forKey: .`attachmentId`)
    }
}

public struct ReviewedSetupManifestEntries: Codable, Hashable, Identifiable {
    public var `id`: String
    public var `setupScript`: String
    public var `checkScript`: String?
    public var `secretNames`: [String]
    public var `timeoutMs`: Int
    public init(id: String, setupScript: String, checkScript: String? = nil, secretNames: [String], timeoutMs: Int) {
        self.`id` = id
        self.`setupScript` = setupScript
        self.`checkScript` = checkScript
        self.`secretNames` = secretNames
        self.`timeoutMs` = timeoutMs
    }
    enum CodingKeys: String, CodingKey { case `id`, `setupScript`, `checkScript`, `secretNames`, `timeoutMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(String.self, forKey: .`id`)
        self.`setupScript` = try c.decode(String.self, forKey: .`setupScript`)
        self.`checkScript` = try c.decode(String?.self, forKey: .`checkScript`)
        self.`secretNames` = try c.decode([String].self, forKey: .`secretNames`)
        self.`timeoutMs` = try c.decode(Int.self, forKey: .`timeoutMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`setupScript`, forKey: .`setupScript`)
        try c.encode(`checkScript`, forKey: .`checkScript`)
        try c.encode(`secretNames`, forKey: .`secretNames`)
        try c.encode(`timeoutMs`, forKey: .`timeoutMs`)
    }
}


public typealias AccountCleanupState = String

public struct AccountCleanupResult: Codable, Hashable {
    public var `state`: AccountCleanupState
    public var `updatedAtMs`: TimestampMs
    public var `errorCode`: ErrorCode?
    public init(state: AccountCleanupState, updatedAtMs: TimestampMs, errorCode: ErrorCode? = nil) {
        self.`state` = state
        self.`updatedAtMs` = updatedAtMs
        self.`errorCode` = errorCode
    }
    enum CodingKeys: String, CodingKey { case `state`, `updatedAtMs`, `errorCode` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`state` = try c.decode(AccountCleanupState.self, forKey: .`state`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`errorCode` = try c.decode(ErrorCode?.self, forKey: .`errorCode`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`state`, forKey: .`state`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`errorCode`, forKey: .`errorCode`)
    }
}

public struct ProviderCleanupResult: Codable, Hashable {
    public var `state`: AccountCleanupState
    public var `updatedAtMs`: TimestampMs
    public var `errorCode`: ErrorCode?
    public var `providerId`: String
    public var `kind`: String
    public var `receiptId`: ID?
    public init(state: AccountCleanupState, updatedAtMs: TimestampMs, errorCode: ErrorCode? = nil, providerId: String, kind: String, receiptId: ID? = nil) {
        self.`state` = state
        self.`updatedAtMs` = updatedAtMs
        self.`errorCode` = errorCode
        self.`providerId` = providerId
        self.`kind` = kind
        self.`receiptId` = receiptId
    }
    enum CodingKeys: String, CodingKey { case `state`, `updatedAtMs`, `errorCode`, `providerId`, `kind`, `receiptId` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`state` = try c.decode(AccountCleanupState.self, forKey: .`state`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`errorCode` = try c.decode(ErrorCode?.self, forKey: .`errorCode`)
        self.`providerId` = try c.decode(String.self, forKey: .`providerId`)
        self.`kind` = try c.decode(String.self, forKey: .`kind`)
        guard ["email", "oidc", "connector", "channel", "x"].contains(`kind`) else { throw DecodingError.dataCorruptedError(forKey: .`kind`, in: c, debugDescription: "Invalid ProviderCleanupResult.kind") }
        self.`receiptId` = try c.decode(ID?.self, forKey: .`receiptId`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`state`, forKey: .`state`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`errorCode`, forKey: .`errorCode`)
        try c.encode(`providerId`, forKey: .`providerId`)
        try c.encode(`kind`, forKey: .`kind`)
        try c.encode(`receiptId`, forKey: .`receiptId`)
    }
}

public struct AccountTeardown: Codable, Hashable, Identifiable {
    public var `id`: ID
    public var `revision`: Int
    public var `createdAtMs`: TimestampMs
    public var `updatedAtMs`: TimestampMs
    public var `operation`: String
    public var `userId`: ID
    public var `workspaceId`: ID
    public var `state`: String
    public var `productCleanup`: AccountCleanupResult
    public var `providerCleanup`: [ProviderCleanupResult]
    public var `requestId`: String
    public var `startedAtMs`: TimestampMs?
    public var `completedAtMs`: TimestampMs?
    public init(id: ID, revision: Int, createdAtMs: TimestampMs, updatedAtMs: TimestampMs, operation: String, userId: ID, workspaceId: ID, state: String, productCleanup: AccountCleanupResult, providerCleanup: [ProviderCleanupResult], requestId: String, startedAtMs: TimestampMs? = nil, completedAtMs: TimestampMs? = nil) {
        self.`id` = id
        self.`revision` = revision
        self.`createdAtMs` = createdAtMs
        self.`updatedAtMs` = updatedAtMs
        self.`operation` = operation
        self.`userId` = userId
        self.`workspaceId` = workspaceId
        self.`state` = state
        self.`productCleanup` = productCleanup
        self.`providerCleanup` = providerCleanup
        self.`requestId` = requestId
        self.`startedAtMs` = startedAtMs
        self.`completedAtMs` = completedAtMs
    }
    enum CodingKeys: String, CodingKey { case `id`, `revision`, `createdAtMs`, `updatedAtMs`, `operation`, `userId`, `workspaceId`, `state`, `productCleanup`, `providerCleanup`, `requestId`, `startedAtMs`, `completedAtMs` }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`id` = try c.decode(ID.self, forKey: .`id`)
        self.`revision` = try c.decode(Int.self, forKey: .`revision`)
        self.`createdAtMs` = try c.decode(TimestampMs.self, forKey: .`createdAtMs`)
        self.`updatedAtMs` = try c.decode(TimestampMs.self, forKey: .`updatedAtMs`)
        self.`operation` = try c.decode(String.self, forKey: .`operation`)
        guard ["delete_account"].contains(`operation`) else { throw DecodingError.dataCorruptedError(forKey: .`operation`, in: c, debugDescription: "Invalid AccountTeardown.operation") }
        self.`userId` = try c.decode(ID.self, forKey: .`userId`)
        self.`workspaceId` = try c.decode(ID.self, forKey: .`workspaceId`)
        self.`state` = try c.decode(String.self, forKey: .`state`)
        guard ["pending", "running", "completed", "failed", "outcome_unknown"].contains(`state`) else { throw DecodingError.dataCorruptedError(forKey: .`state`, in: c, debugDescription: "Invalid AccountTeardown.state") }
        self.`productCleanup` = try c.decode(AccountCleanupResult.self, forKey: .`productCleanup`)
        self.`providerCleanup` = try c.decode([ProviderCleanupResult].self, forKey: .`providerCleanup`)
        self.`requestId` = try c.decode(String.self, forKey: .`requestId`)
        self.`startedAtMs` = try c.decode(TimestampMs?.self, forKey: .`startedAtMs`)
        self.`completedAtMs` = try c.decode(TimestampMs?.self, forKey: .`completedAtMs`)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`id`, forKey: .`id`)
        try c.encode(`revision`, forKey: .`revision`)
        try c.encode(`createdAtMs`, forKey: .`createdAtMs`)
        try c.encode(`updatedAtMs`, forKey: .`updatedAtMs`)
        try c.encode(`operation`, forKey: .`operation`)
        try c.encode(`userId`, forKey: .`userId`)
        try c.encode(`workspaceId`, forKey: .`workspaceId`)
        try c.encode(`state`, forKey: .`state`)
        try c.encode(`productCleanup`, forKey: .`productCleanup`)
        try c.encode(`providerCleanup`, forKey: .`providerCleanup`)
        try c.encode(`requestId`, forKey: .`requestId`)
        try c.encode(`startedAtMs`, forKey: .`startedAtMs`)
        try c.encode(`completedAtMs`, forKey: .`completedAtMs`)
    }
}
