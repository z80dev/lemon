import SwiftUI
import LemonBotKit
import AVKit
import QuickLook
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct AttachmentView: View {
    let store: LemonBotStore
    let attachmentID: ID
    init(store: LemonBotStore, attachmentID: ID) { self.store = store; self.attachmentID = attachmentID }
    @State private var attachment: Attachment?
    @State private var localURL: URL?
    @State private var previewURL: URL?
    @State private var textPreview: String?
    @State private var action = UIActionState()
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let attachment {
                Label(attachment.filename, systemImage: attachment.preview == "audio" ? "waveform" : "doc")
                Text("\(attachment.mime) · \(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                if let bot = attachment.provenance.botId {
                    Text("Source: \(store.bots.first(where: { $0.id == bot })?.name ?? bot) · machine \(attachment.provenance.machineId ?? "unknown") · run \(attachment.provenance.runId ?? "unknown")").font(.caption).textSelection(.enabled)
                } else { Text("Source: \(attachment.source) · no generating Bot attribution").font(.caption) }
                if let generated = attachment.provenance.generatedAtMs { Text("Generated \(timestamp(Double(generated)).formatted())").font(.caption) }
                HStack {
                    Button("Preview") { Task { await loadFile(preview: true) } }.disabled(action.busy)
                    Button("Download original") { Task { await loadFile(preview: false) } }.disabled(action.busy)
                    if let localURL { ShareLink(item: localURL, label: { Label("Save or share", systemImage: "square.and.arrow.up") }) }
                }
                if attachment.preview == "html" { Text("HTML is shown as inert source, never executed with application credentials. Download the original for an external viewer.").font(.caption) }
            } else if action.inFlight { ProgressView("Loading attachment…") }
            ActionErrorView(message: action.error)
        }.padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            .task(id: attachmentID) { await action.perform { attachment = try await store.read(resourcePath("attachments", attachmentID)) } }
            .quickLookPreview($previewURL)
            .sheet(isPresented: Binding(get: { textPreview != nil }, set: { if !$0 { textPreview = nil } })) {
                NavigationStack {
                    ScrollView { Text(textPreview ?? "").font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
                        .navigationTitle(attachment?.filename ?? "File preview")
                        .toolbar { Button("Close") { textPreview = nil } }
                }.frame(minWidth: 340, minHeight: 400)
            }
    }
    private func loadFile(preview: Bool) async {
        await action.perform {
            let url = try await store.download(attachmentID: attachmentID)
            localURL = url
            if preview {
                if ["text", "markdown", "json", "html"].contains(attachment?.preview ?? "") {
                    guard (attachment?.size ?? 0) <= 1_048_576 else { throw AttachmentPreviewError.tooLarge }
                    let data = try Data(contentsOf: url)
                    guard let text = String(data: data, encoding: .utf8) else { throw AttachmentPreviewError.decodingFailed }
                    textPreview = text
                } else { previewURL = url }
            }
        }
    }
}
private enum AttachmentPreviewError: LocalizedError {
    case tooLarge, decodingFailed
    var errorDescription: String? {
        switch self {
        case .tooLarge: return "This text preview exceeds 1 MiB. The authorized original is downloaded; use Save or share to inspect it externally."
        case .decodingFailed: return "UTF-8 preview decoding failed. The original download remains available."
        }
    }
}

struct VoiceMemoView: View {
    let store: LemonBotStore
    let attachmentID: ID
    let transcript: String
    let durationMs: Double?
    let peaks: [Double]
    init(store: LemonBotStore, attachmentID: ID, transcript: String, durationMs: Double?, peaks: [Double]) {
        self.store = store; self.attachmentID = attachmentID; self.transcript = transcript; self.durationMs = durationMs; self.peaks = peaks
    }
    @State private var player: AVPlayer?
    @State private var expanded = false
    @State private var playing = false
    @State private var position: Double = 0
    @State private var rate: Float = 1
    @State private var action = UIActionState()
    @State private var measuredDuration: Double?
    @State private var playbackState = "Audio not yet downloaded"
    private var duration: Double? { durationMs.map { $0 / 1000 } ?? measuredDuration }
    private let ticker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(duration.map { "Voice memo · \(Int($0)) seconds" } ?? "Voice memo · duration unavailable", systemImage: "waveform")
            HStack(spacing: 2) {
                ForEach(Array(peaks.prefix(128).enumerated()), id: \.offset) { _, peak in
                    Capsule().fill(.secondary).frame(width: 2, height: max(2, min(32, abs(peak) * 32)))
                }
            }.frame(height: 32).accessibilityLabel("Audio waveform")
            HStack {
                Button(playing ? "Pause" : "Play") { Task { await toggle() } }.disabled(action.busy)
                Slider(value: $position, in: 0...max(1, duration ?? 1), onEditingChanged: { editing in
                    if !editing { player?.seek(to: CMTime(seconds: position, preferredTimescale: 600)) }
                }).disabled(player == nil || duration == nil).accessibilityLabel("Playback position")
                Picker("Speed", selection: $rate) { Text("1×").tag(Float(1)); Text("1.5×").tag(Float(1.5)); Text("2×").tag(Float(2)) }.frame(width: 90)
                    .onChange(of: rate) { _, rate in if playing { player?.rate = rate } }
            }
            Text(action.inFlight ? "Preparing actual audio…" : playbackState).font(.caption)
            DisclosureGroup("Transcript", isExpanded: $expanded) { Text(transcript).textSelection(.enabled) }
            AttachmentView(store: store, attachmentID: attachmentID)
            ActionErrorView(message: action.error)
        }.onReceive(ticker) { _ in
            guard let player else { return }
            let current = player.currentTime().seconds
            if current.isFinite { position = current }
            let measured = player.currentItem?.duration.seconds
            if let measured, measured.isFinite, measured > 0, measuredDuration != measured { measuredDuration = measured }
            if player.currentItem?.status == .failed || player.status == .failed {
                playing = false
                if playbackState != "Playback failed" {
                    playbackState = "Playback failed"
                    action.error = player.currentItem?.error?.localizedDescription ?? player.error?.localizedDescription ?? "This device could not decode the audio. The original download remains available."
                }
            } else {
                let state = player.timeControlStatus == .playing ? "Playing" : player.timeControlStatus == .waitingToPlayAtSpecifiedRate ? "Preparing actual audio…" : "Paused"
                if state != playbackState { playbackState = state }
                if playing, let duration, player.timeControlStatus == .paused, position >= duration - 0.2 { playing = false }
            }
        }.onDisappear { player?.pause(); playing = false; if player != nil { playbackState = "Paused" } }
    }
    private func toggle() async {
        if playing { player?.pause(); playing = false; playbackState = "Paused"; return }
        await action.perform {
            if player == nil { player = AVPlayer(url: try await store.download(attachmentID: attachmentID)) }
            if let duration, position >= duration - 0.2 { player?.seek(to: .zero) }
            player?.playImmediately(atRate: rate)
            playing = true
            playbackState = player?.timeControlStatus == .playing ? "Playing" : "Preparing actual audio…"
        }
    }
}
