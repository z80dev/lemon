import Foundation
import Security
import CryptoKit

public struct StoredAccount: Codable, Hashable, Identifiable {
    public var id: String
    public var baseURL: URL
    public var email: String
    public var displayName: String
    public var token: String
    public var userID: String
    public var workspaceID: String
    public var deviceID: ID?
    public var sessionID: ID?
    public var sessionExpiresAtMs: TimestampMs?
    public var installationID: String?
    public init(id: String, baseURL: URL, email: String, displayName: String, token: String, userID: String, workspaceID: String, deviceID: ID? = nil, sessionID: ID? = nil, sessionExpiresAtMs: TimestampMs? = nil, installationID: String? = nil) {
        self.id = id; self.baseURL = baseURL; self.email = email; self.displayName = displayName; self.token = token; self.userID = userID; self.workspaceID = workspaceID
        self.deviceID = deviceID; self.sessionID = sessionID; self.sessionExpiresAtMs = sessionExpiresAtMs; self.installationID = installationID
    }
}

/// Session credentials have one secure production implementation. Injection keeps
/// lifecycle tests independent of the machine's Keychain without adding a fallback.
public protocol AccountCredentialStore: AnyObject {
    func load() throws -> [StoredAccount]
    func save(_ account: StoredAccount) throws
    func remove(_ id: String) throws
    func loadPendingPairing() throws -> PendingDevicePairing?
    func savePendingPairing(_ pairing: PendingDevicePairing) throws
    func removePendingPairing() throws
}

public final class AccountKeychain: AccountCredentialStore {
    private let service: String
    public init(service: String = "org.lemonbot.accounts.v1") { self.service = service }
    private func query(_ id: String? = nil) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrSynchronizable as String: false]
        #if os(macOS)
        // The local login Keychain uses code-signing ACLs, not iOS accessibility.
        // Select it for every operation; never fall back between Keychain stores.
        q[kSecUseDataProtectionKeychain as String] = false
        #endif
        if let id { q[kSecAttrAccount as String] = id }
        return q
    }
    public func load() throws -> [StoredAccount] {
        var q = query()
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw ClientError.keychain(status) }
        guard let values = result as? [Data] else { throw ClientError.keychain(errSecDecode) }
        return try values.map { try JSONDecoder().decode(StoredAccount.self, from: $0) }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
    public func save(_ account: StoredAccount) throws {
        let bytes = try JSONEncoder().encode(account)
        let status = SecItemUpdate(query(account.id) as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account.id)
            q[kSecValueData as String] = bytes
            #if !os(macOS)
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            #endif
            let inserted = SecItemAdd(q as CFDictionary, nil)
            guard inserted == errSecSuccess else { throw ClientError.keychain(inserted) }
        } else if status != errSecSuccess { throw ClientError.keychain(status) }
    }
    public func remove(_ id: String) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ClientError.keychain(status) }
    }
    private var pairingQuery: [String: Any] {
        var q = query("current")
        q[kSecAttrService as String] = service + ".pending-pairing"
        return q
    }
    public func loadPendingPairing() throws -> PendingDevicePairing? {
        var q = pairingQuery; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ClientError.keychain(status == errSecSuccess ? errSecDecode : status) }
        return try JSONDecoder().decode(PendingDevicePairing.self, from: data)
    }
    public func savePendingPairing(_ pairing: PendingDevicePairing) throws {
        let data = try JSONEncoder().encode(pairing)
        let status = SecItemUpdate(pairingQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = pairingQuery; q[kSecValueData as String] = data
            #if !os(macOS)
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            #endif
            let inserted = SecItemAdd(q as CFDictionary, nil)
            guard inserted == errSecSuccess else { throw ClientError.keychain(inserted) }
        } else if status != errSecSuccess { throw ClientError.keychain(status) }
    }
    public func removePendingPairing() throws {
        let status = SecItemDelete(pairingQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ClientError.keychain(status) }
    }
}

public struct LocalComposerDraft: Codable, Hashable {
    public var text: String
    public var attachmentIDs: [ID]
    public var replyToEntryID: ID?
    public var revision: Int
    /// Nonsecret user-selected files are retained locally until an explicit Attach/Send.
    public var fileURLs: [URL]
    public var references: [Reference]
    public var mentions: [ID]
    public var everyone: Bool
    public init(text: String = "", attachmentIDs: [ID] = [], replyToEntryID: ID? = nil, revision: Int = 1, fileURLs: [URL] = [], references: [Reference] = [], mentions: [ID] = [], everyone: Bool = false) {
        self.text = text; self.attachmentIDs = attachmentIDs; self.replyToEntryID = replyToEntryID; self.revision = revision; self.fileURLs = fileURLs
        self.references = references; self.mentions = mentions; self.everyone = everyone
    }
    enum CodingKeys: String, CodingKey { case text, attachmentIDs, replyToEntryID, revision, fileURLs, references, mentions, everyone }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        attachmentIDs = try c.decode([ID].self, forKey: .attachmentIDs)
        replyToEntryID = try c.decodeIfPresent(ID.self, forKey: .replyToEntryID)
        revision = try c.decode(Int.self, forKey: .revision)
        fileURLs = try c.decodeIfPresent([URL].self, forKey: .fileURLs) ?? []
        references = try c.decodeIfPresent([Reference].self, forKey: .references) ?? []
        mentions = try c.decodeIfPresent([ID].self, forKey: .mentions) ?? []
        everyone = try c.decodeIfPresent(Bool.self, forKey: .everyone) ?? false
    }
}

struct AccountCache: Codable {
    var accountID: String
    var snapshot: Snapshot
    var entries: [ID: [TranscriptEntry]]
    var cursor: Cursor
}

struct SavedClientSelection: Codable {
    var conversationID: ID?
    var botID: ID?
}
/// Cache files never contain sessions, secret gate input, confirmation tokens, or queued mutations.
public final class ClientPersistence {
    private let root: URL
    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LemonBot", isDirectory: true)
    }
    static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    func directory(_ accountID: String) -> URL { root.appendingPathComponent(Self.digest(accountID), isDirectory: true) }
    private func path(_ accountID: String, _ name: String) -> URL { directory(accountID).appendingPathComponent(name) }
    private func save<T: Encodable>(_ value: T, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
    func saveCache(_ cache: AccountCache) throws { try save(cache, at: path(cache.accountID, "cache.json")) }
    func loadCache(_ id: String) throws -> AccountCache? {
        let url = path(id, "cache.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(AccountCache.self, from: Data(contentsOf: url))
        guard value.accountID == id else { throw ClientError.accountChanged }
        return value
    }
    public func saveDraft(_ draft: LocalComposerDraft, conversationID: ID, accountID: String) throws { try save(draft, at: path(accountID, "drafts/" + Self.digest(conversationID) + ".json")) }
    public func loadDraft(conversationID: ID, accountID: String) throws -> LocalComposerDraft? {
        let url = path(accountID, "drafts/" + Self.digest(conversationID) + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(LocalComposerDraft.self, from: Data(contentsOf: url))
    }
    public func stageFile(_ source: URL, conversationID: ID, accountID: String) throws -> URL {
        let directory = path(accountID, "draft-files/" + Self.digest(conversationID))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }
    func removeStagedFile(_ url: URL, conversationID: ID, accountID: String) throws {
        let expected = path(accountID, "draft-files/" + Self.digest(conversationID)).standardizedFileURL.resolvingSymlinksInPath()
        guard url.isFileURL, url.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent() == expected else { return }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    public func clearDraft(conversationID: ID, accountID: String) throws {
        for url in [path(accountID, "drafts/" + Self.digest(conversationID) + ".json"),
                    path(accountID, "draft-files/" + Self.digest(conversationID))] {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
    public func saveSettings(_ settings: ClientLocalSettings, accountID: String) throws { try save(settings, at: path(accountID, "settings.json")) }
    public func loadSettings(accountID: String) throws -> ClientLocalSettings? {
        let url = path(accountID, "settings.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(ClientLocalSettings.self, from: Data(contentsOf: url))
    }
    func saveSelection(_ selection: SavedClientSelection, accountID: String) throws { try save(selection, at: path(accountID, "selection.json")) }
    func loadSelection(accountID: String) throws -> SavedClientSelection? {
        let url = path(accountID, "selection.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(SavedClientSelection.self, from: Data(contentsOf: url))
    }
    func saveLastAccountID(_ id: String?) throws { try save(id, at: root.appendingPathComponent("last-account.json")) }
    func loadLastAccountID() throws -> String? {
        let url = root.appendingPathComponent("last-account.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(String?.self, from: Data(contentsOf: url))
    }
    public func saveMutationIntents(_ intents: [MutationIntent], accountID: String) throws { try save(intents, at: path(accountID, "mutation-intents.json")) }
    public func loadMutationIntents(accountID: String) throws -> [MutationIntent] {
        let url = path(accountID, "mutation-intents.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([MutationIntent].self, from: Data(contentsOf: url))
    }
    func downloadURL(_ attachmentID: ID, filename: String, accountID: String) -> URL {
        path(accountID, "downloads/" + Self.digest(attachmentID) + "/" + URL(fileURLWithPath: filename).lastPathComponent)
    }
    public func clear(accountID: String) throws {
        let url = directory(accountID)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
