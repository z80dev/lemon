import SwiftUI
import LemonBotKit

/// Reads only the server's curated catalog; selecting a voice never plays or saves it.
public struct ProviderVoicePicker: View {
    private let store: LemonBotStore
    @Binding private var voiceID: String
    @Binding private var language: String
    @State private var catalog: VoiceCatalog?
    @State private var loading = false
    @State private var error: String?

    public init(store: LemonBotStore, voiceID: Binding<String>, language: Binding<String>) {
        self.store = store; _voiceID = voiceID; _language = language
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Voice", selection: $voiceID) {
                if let catalog {
                    ForEach(catalog.voices) { voice in Text(voice.name).tag(voice.id) }
                }
                if catalog?.voices.contains(where: { $0.id == voiceID }) != true {
                    Text(voiceID == "default" ? "Provider default" : "Saved custom voice").tag(voiceID)
                }
            }
            .disabled(catalog == nil || store.connectionState != "online")
            .onChange(of: voiceID) { _, id in
                if let locale = catalog?.voices.first(where: { $0.id == id })?.languages.first { language = locale }
            }
            if loading { ProgressView("Loading voices…").font(LBFont.meta) }
            if let catalog {
                Text(catalog.provider.map { "\(providerName($0)) · Built-in voices" } ?? "No speech provider selected on the server.")
                    .font(LBFont.meta).foregroundStyle(LB.muted)
                if !catalog.configured {
                    Text("Spoken replies aren't enabled. Ask the server operator to configure a speech provider.").font(LBFont.meta).foregroundStyle(LB.warning)
                }
                Text("Choosing a voice doesn't play audio or save changes. Saved custom voices are kept even when they aren't listed.").font(LBFont.meta).foregroundStyle(LB.muted)
            }
            if let error {
                ActionErrorView(message: error)
                Button("Load voices again") { Task { await load() } }.disabled(loading || store.connectionState != "online")
            } else if store.connectionState != "online" {
                Text("Reconnect to load voices. Your saved voice is unchanged.").font(LBFont.meta).foregroundStyle(LB.muted)
            }
        }
        .task(id: "\(store.account?.id ?? ""):\(store.connectionState)") { await load() }
    }
    private func providerName(_ provider: String) -> String {
        switch provider {
        case "openai": return "OpenAI"
        case "elevenlabs": return "ElevenLabs"
        case "google": return "Google"
        default: return provider
        }
    }
    @MainActor private func load() async {
        catalog = nil; error = nil
        guard store.connectionState == "online" else { return }
        loading = true
        defer { loading = false }
        do {
            let result: VoiceCatalog = try await store.read("/audio/voices")
            guard !Task.isCancelled else { return }
            catalog = result
        } catch {
            guard !Task.isCancelled else { return }
            self.error = humanErrorText(error)
        }
    }
}
