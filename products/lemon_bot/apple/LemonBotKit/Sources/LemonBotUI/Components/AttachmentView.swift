import SwiftUI
import LemonBotKit
import AVKit
import ImageIO
import QuickLook
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// An authorized attachment: images as chromeless rounded thumbnails, everything else as a compact file pill.
/// Bytes are only fetched through the authorized download ticket; HTML is only ever shown as inert source.
struct AttachmentView: View {
    let store: LemonBotStore
    let attachmentID: ID
    init(store: LemonBotStore, attachmentID: ID) { self.store = store; self.attachmentID = attachmentID }
    @State private var attachment: Attachment?
    @State private var localURL: URL?
    @State private var previewURL: URL?
    @State private var textPreview: String?
    @State private var thumbnail: Image?
    @State private var thumbnailFailed = false
    @State private var showDetails = false
    @State private var action = UIActionState()
    @Environment(\.lbReduceMotion) private var reduceMotion
    private static let maxThumbnailBytes = 15 * 1_048_576
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let attachment {
                if isInlineImage(attachment) && !thumbnailFailed { imageBody(attachment) } else { fileRow(attachment) }
                if showDetails { details(attachment) }
                if attachment.preview == "html" { CardNote(symbol: "shield", text: "HTML is shown as plain text and never run. Download the original to open it in another app.") }
            } else if action.inFlight { ProgressView("Loading attachment…").font(LBFont.meta).foregroundStyle(LB.muted) }
            ActionErrorView(message: action.error)
        }.task(id: attachmentID) {
            await action.perform { attachment = try await store.read(resourcePath("attachments", attachmentID)) }
            if let attachment, isInlineImage(attachment) { await loadThumbnail() }
        }
            .quickLookPreview($previewURL)
            .sheet(isPresented: Binding(get: { textPreview != nil }, set: { if !$0 { textPreview = nil } })) {
                NavigationStack {
                    ScrollView { Text(textPreview ?? "").font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
                        .navigationTitle(attachment?.filename ?? "File preview")
                        .toolbar { Button("Close") { textPreview = nil } }
                }.frame(minWidth: 340, minHeight: 400)
            }
    }
    private func isInlineImage(_ attachment: Attachment) -> Bool {
        let mime = attachment.mime.lowercased()
        return attachment.preview == "image" && mime.hasPrefix("image/") && !mime.contains("svg") && attachment.size <= Self.maxThumbnailBytes
    }
    private func imageBody(_ attachment: Attachment) -> some View {
        let ratio: CGFloat = {
            guard let width = attachment.width, let height = attachment.height, width > 0, height > 0 else { return 4.0 / 3.0 }
            return min(2.5, max(0.4, CGFloat(width) / CGFloat(height)))
        }()
        return Button { Task { if let localURL { previewURL = localURL } else { await loadFile(preview: true) } } } label: {
            Color.clear.aspectRatio(ratio, contentMode: .fit)
                .overlay {
                    if let thumbnail { thumbnail.resizable().scaledToFill() }
                    else { LB.fill.overlay { ProgressView().controlSize(.small) } }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(maxWidth: 320, maxHeight: 320)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }.buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Image \(attachment.filename)").help(attachment.filename)
            .contextMenu {
                Button("Preview") { Task { await loadFile(preview: true) } }
                Button("Download original") { Task { await loadFile(preview: false) } }
                if let localURL { ShareLink(item: localURL) { Label("Save or share", systemImage: "square.and.arrow.up") } }
                Button(showDetails ? "Hide details" : "Show details") { toggleDetails() }
            }
    }
    private func fileRow(_ attachment: Attachment) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol(for: attachment)).font(.system(size: 14)).foregroundStyle(LB.muted).frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(attachment.filename).font(LBFont.rowTitle).foregroundStyle(LB.ink).lineLimit(1).truncationMode(.middle)
                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file)).font(LBFont.meta).foregroundStyle(LB.muted)
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                if action.inFlight { ProgressView().controlSize(.small).frame(width: 28, height: 28) }
                Button { Task { await loadFile(preview: true) } } label: { Label("Preview", systemImage: "eye") }
                    .buttonStyle(GhostCircleButtonStyle(size: 28, filled: false)).disabled(action.busy).help("Preview")
                Button { Task { await loadFile(preview: false) } } label: { Label("Download original", systemImage: "arrow.down.circle") }
                    .buttonStyle(GhostCircleButtonStyle(size: 28, filled: false)).disabled(action.busy).help("Download original")
                if let localURL {
                    ShareLink(item: localURL) { Label("Save or share", systemImage: "square.and.arrow.up") }
                        .buttonStyle(GhostCircleButtonStyle(size: 28, filled: false)).help("Save or share")
                }
                Button { toggleDetails() } label: { Label(showDetails ? "Hide details" : "Show details", systemImage: "info.circle") }
                    .buttonStyle(GhostCircleButtonStyle(size: 28, filled: false)).help("Details")
            }
        }.padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
            .background(Capsule().fill(LB.fill))
            .frame(maxWidth: 440, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func details(_ attachment: Attachment) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(attachment.filename) · \(attachment.mime)")
            if let bot = attachment.provenance.botId {
                Text("Made by \(store.bots.first(where: { $0.id == bot })?.name ?? "a Bot")")
            } else { Text("Added to this conversation") }
            DisclosureGroup("Details") {
                let details = "Machine: \(attachment.provenance.machineId ?? "Not set")\nRun: \(attachment.provenance.runId ?? "Not set")"
                Text(details)
                Button("Copy") { copyText(details) }
            }
            if let generated = attachment.provenance.generatedAtMs { Text("Generated \(timestamp(Double(generated)).formatted())") }
        }.cardMeta().textSelection(.enabled).padding(.horizontal, 14)
    }
    private func symbol(for attachment: Attachment) -> String {
        switch attachment.preview {
        case "audio": return "waveform"
        case "video": return "film"
        case "image": return "photo"
        case "pdf": return "doc.richtext"
        case "text", "markdown", "json", "html", "table", "docx": return "doc.text"
        default: return "doc"
        }
    }
    private func toggleDetails() { lbWithAnimation(reduceMotion, LBMotion.snappy) { showDetails.toggle() } }
    private func loadThumbnail() async {
        do {
            let url = try await store.download(attachmentID: attachmentID)
            localURL = url
            if let image = Self.downsampled(url) { thumbnail = Image(decorative: image, scale: 2) } else { thumbnailFailed = true }
        } catch { thumbnailFailed = true }
    }
    private static func downsampled(_ url: URL, maxPixel: Int = 960) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
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
    @State private var playing = false
    @State private var position: Double = 0
    @State private var rate: Float = 1
    @State private var action = UIActionState()
    @State private var measuredDuration: Double?
    @State private var playbackState = "Audio not yet downloaded"
    private var duration: Double? { durationMs.map { $0 / 1000 } ?? measuredDuration }
    private let ticker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { Task { await toggle() } } label: { Label(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill") }
                    .buttonStyle(GhostCircleButtonStyle(size: 34)).disabled(action.busy)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 2) {
                        ForEach(Array(peaks.prefix(128).enumerated()), id: \.offset) { _, peak in
                            Capsule().fill(LB.faint).frame(width: 2, height: max(2, min(24, abs(peak) * 24)))
                        }
                    }.frame(height: peaks.isEmpty ? 0 : 24).accessibilityLabel("Audio waveform")
                    Text(duration.map { "Voice memo · \(Int($0)) seconds" } ?? "Voice memo · duration unavailable").cardMeta()
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Slider(value: $position, in: 0...max(1, duration ?? 1), onEditingChanged: { editing in
                    if !editing { player?.seek(to: CMTime(seconds: position, preferredTimescale: 600)) }
                }).disabled(player == nil || duration == nil).accessibilityLabel("Playback position").tint(LB.accent)
                Menu {
                    Button("1×") { rate = 1 }
                    Button("1.5×") { rate = 1.5 }
                    Button("2×") { rate = 2 }
                } label: {
                    Text(rate == 1 ? "1×" : rate == 1.5 ? "1.5×" : "2×").font(LBFont.metaEmphasis).foregroundStyle(LB.ink)
                        .padding(.horizontal, 10).padding(.vertical, 4).background(Capsule().fill(LB.fill)).contentShape(Capsule())
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Playback speed")
                    .onChange(of: rate) { _, rate in if playing { player?.rate = rate } }
            }
            Text(action.inFlight ? "Preparing actual audio…" : playbackState).cardMeta()
            CardDetails(title: "Transcript") { Text(transcript).textSelection(.enabled) }
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
                let state = player.timeControlStatus == .playing ? "Playing" : player.timeControlStatus == .waitingToPlayAtSpecifiedRate ? "Preparing audio…" : "Paused"
                if state != playbackState { playbackState = state }
                if playing, let duration, player.timeControlStatus == .paused, position >= duration - 0.2 { playing = false }
            }
        }.onDisappear { player?.pause(); playing = false; if player != nil { playbackState = "Paused" } }
    }
    private func toggle() async {
        if playing { player?.pause(); playing = false; playbackState = "Paused"; return }
        await action.perform {
            if player == nil { player = AVPlayer(url: try await store.download(attachmentID: attachmentID)) }
            if let duration, position >= duration - 0.2 { _ = await player?.seek(to: .zero) }
            player?.playImmediately(atRate: rate)
            playing = true
            playbackState = player?.timeControlStatus == .playing ? "Playing" : "Preparing actual audio…"
        }
    }
}
