import Foundation

/// A curated built-in voice, not a live inventory of provider-account voices.
public struct ProviderVoice: Codable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var languages: [String]
    public init(id: String, name: String, languages: [String]) {
        self.id = id; self.name = name; self.languages = languages
    }
}

public struct VoiceCatalog: Codable, Hashable {
    public var provider: String?
    public var configured: Bool
    public var voices: [ProviderVoice]
    public init(provider: String?, configured: Bool, voices: [ProviderVoice]) {
        self.provider = provider; self.configured = configured; self.voices = voices
    }
    enum CodingKeys: String, CodingKey { case provider, configured, voices }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(String?.self, forKey: .provider)
        configured = try c.decode(Bool.self, forKey: .configured)
        voices = try c.decode([ProviderVoice].self, forKey: .voices)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(provider, forKey: .provider)
        try c.encode(configured, forKey: .configured)
        try c.encode(voices, forKey: .voices)
    }
}
