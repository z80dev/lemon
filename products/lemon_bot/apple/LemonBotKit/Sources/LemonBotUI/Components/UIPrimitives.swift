import SwiftUI
import LemonBotKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

func resourcePath(_ family: String, _ id: ID, _ suffix: String = "") -> String {
    let encoded = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ""
    return "/\(family)/\(encoded)\(suffix)"
}
func wireObject<T: Encodable>(_ value: T) throws -> JSONObject {
    try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(value))
}
func strings(_ values: [String]) -> JSONValue { .array(values.map(JSONValue.string)) }
func timestamp(_ milliseconds: Double) -> Date { Date(timeIntervalSince1970: milliseconds / 1000) }
func zonedTimestamp(_ milliseconds: Double, timezone: String) -> String {
    guard let zone = TimeZone(identifier: timezone) else { return "\(Int(milliseconds)) ms · invalid timezone \(timezone)" }
    return timestamp(milliseconds).formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: zone))
}
func copyText(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
}
func safeExternalURL(_ text: String) -> URL? {
    guard let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
          url.host != nil, url.user == nil, url.password == nil else { return nil }
    return url
}

@MainActor func allResources<T: Codable & Hashable>(_ store: LemonBotStore, _ path: String, query: [String: String] = [:], as: T.Type = T.self) async throws -> [T] {
    var items: [T] = []
    var cursor: String?
    repeat {
        var pageQuery = query
        pageQuery["limit"] = "200"
        if let cursor { pageQuery["cursor"] = cursor }
        let page: Page<T> = try await store.read(path, query: pageQuery)
        items.append(contentsOf: page.items)
        cursor = page.nextCursor
    } while cursor != nil
    return items
}
@MainActor func visibleConnector(_ store: LemonBotStore, _ id: ID, botID: ID? = nil) async throws -> Connector {
    let bots = botID.map { [$0] } ?? store.bots.map(\.id)
    for bot in bots {
        let connectors: [Connector] = try await allResources(store, resourcePath("bots", bot, "/connectors"))
        if let connector = connectors.first(where: { $0.id == id }) { return connector }
    }
    throw UIResourceError.missingConnector
}
private enum UIResourceError: LocalizedError {
    case missingConnector
    var errorDescription: String? { "This connector is not present in your authorized Bot inventory. Reload setup or ask the owner; no authorization was inferred." }
}

@MainActor @Observable final class UIActionState {
    private var running = false
    var uncertain = false
    var uncertainNonce: String?
    var uncertainRunID: ID?
    var busy: Bool { running || uncertain }
    var inFlight: Bool { running }
    var error: String?
    var receipt: String?
    func perform(_ action: () async throws -> Void) async {
        guard !running else { return }
        running = true
        error = nil
        defer { running = false }
        do { try await action() } catch {
            self.error = error.localizedDescription
            if case ClientError.outcomeUnknown(let nonce) = error {
                uncertain = true
                uncertainNonce = nonce
            } else if case ClientError.unresolvedMutation(let intent) = error {
                uncertain = true
                uncertainNonce = intent.clientNonce
                uncertainRunID = intent.runID
            } else if let backend = error as? BackendError {
                let runIDs = backend.failure.details?["runIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
                let entryIDs = backend.failure.details?["entryIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
                if !runIDs.isEmpty { self.error = (self.error ?? "") + "\nExact runs: " + runIDs.joined(separator: ", ") }
                if !entryIDs.isEmpty { self.error = (self.error ?? "") + "\nRecorded entries: " + entryIDs.joined(separator: ", ") }
                if backend.failure.code == "outcome_unknown" || (backend.failure.details?["clientNonce"]?.stringValue != nil && !runIDs.isEmpty && !entryIDs.isEmpty) {
                    uncertain = true
                    uncertainNonce = backend.failure.details?["clientNonce"]?.stringValue
                    uncertainRunID = backend.failure.details?["runId"]?.stringValue ?? backend.failure.details?["runIds"]?.arrayValue?.first?.stringValue
                }
            }
        }
    }
}

struct ActionErrorView: View {
    let message: String?
    var body: some View {
        if let message {
            HStack(alignment: .top) {
                Image(systemName: "exclamationmark.triangle")
                Text(message).textSelection(.enabled)
                Button("Copy error") { copyText(message) }.buttonStyle(.borderless)
            }.font(.callout).foregroundStyle(.red).padding(8)
                .background(.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .contain)
        }
    }
}
struct StatusBadge: View {
    let text: String
    var body: some View {
        Text(text.replacingOccurrences(of: "_", with: " ").capitalized)
            .font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
    }
}
struct BotIdentityAnchor: View {
    let store: LemonBotStore
    let bot: Bot
    var body: some View {
        HStack {
            BotAvatarView(store: store, bot: bot).frame(width: 36, height: 36).accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text(bot.name).font(.headline)
                Text(store.machines.first(where: { $0.id == bot.machineId })?.name ?? bot.machineId)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            StatusBadge(text: store.connectionState == "online" ? bot.activity : "last known: \(bot.activity)")
        }.accessibilityElement(children: .combine)
    }
}
struct BotAvatarView: View {
    let store: LemonBotStore
    let bot: Bot
    init(store: LemonBotStore, bot: Bot) { self.store = store; self.bot = bot }
    @State private var image: Image?
    @State private var failed = false
    var body: some View {
        Group {
            if let image { image.resizable().scaledToFill().clipShape(Circle()) }
            else {
                Image(systemName: failed ? "exclamationmark.circle" : bot.avatar.shape == "star" ? "star.circle.fill" : bot.avatar.shape == "square" ? "person.crop.square.fill" : "face.smiling.fill")
                    .resizable().scaledToFit().foregroundStyle(characterColor)
            }
        }.task(id: bot.avatar.attachmentId) {
            image = nil; failed = false
            guard let id = bot.avatar.attachmentId else { return }
            do {
                let url = try await store.download(attachmentID: id)
                #if os(macOS)
                guard let native = NSImage(contentsOf: url) else { failed = true; return }
                image = Image(nsImage: native)
                #else
                guard let native = UIImage(contentsOfFile: url.path) else { failed = true; return }
                image = Image(uiImage: native)
                #endif
            } catch { failed = true }
        }
    }
    private var characterColor: Color {
        switch bot.avatar.color {
        case "blue": return .blue
        case "green": return .green
        case "purple": return .purple
        case "orange": return .orange
        case "red": return .red
        default: return .yellow
        }
    }
}
struct EmptySelectionView: View {
    var body: some View {
        ContentUnavailableView("Choose your assistant", systemImage: "sparkles", description: Text("Bots keep working on their assigned machine when you close the app. Choose a Bot or group of your Bots to see its work."))
    }
}

struct ScopeConfirmationView: View {
    let store: LemonBotStore
    let confirmation: Confirmation
    let title: String
    let onConfirm: (JSONObject) async throws -> Void
    init(store: LemonBotStore, confirmation: Confirmation, title: String, onConfirm: @escaping (JSONObject) async throws -> Void) {
        self.store = store; self.confirmation = confirmation; self.title = title; self.onConfirm = onConfirm
    }
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var action = UIActionState()
    var body: some View {
        NavigationStack {
            Form {
                SwiftUI.Section("Review exact effects") {
                    ForEach(Array(confirmation.effects.enumerated()), id: \.offset) { _, effect in Text(effect) }
                    ForEach(Array(confirmation.affected.enumerated()), id: \.offset) { _, effect in
                        VStack(alignment: .leading) {
                            Text("\(effect.operation.capitalized): \(effect.resourceType) \(effect.id)").font(.headline)
                            if let machine = effect.machineId { Text("Machine: \(machine)").font(.caption) }
                            Text(effect.explanation)
                        }
                    }
                }
                SwiftUI.Section("Confirm \(confirmation.confirmName)") {
                    Text("Type the exact name. This preview expires at \(timestamp(Double(confirmation.expiresAtMs)).formatted()).")
                    TextField(confirmation.confirmName, text: $name)
                    Text("No operation is queued while offline. Host files, backups and provider sessions remain unless this preview explicitly says otherwise.").font(.caption)
                }
                ActionErrorView(message: action.error)
                if action.uncertain { Text("Outcome not confirmed. This intent is fenced; inspect the exact target before another operation. No retry is automatic.").foregroundStyle(.orange) }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                Button(title, role: .destructive) {
                    Task { await action.perform {
                        try await onConfirm(["revision": .number(Double(confirmation.revision)), "confirmationToken": .string(confirmation.confirmationToken), "confirmName": .string(name)])
                        dismiss()
                    } }
                }.disabled(action.busy || name != confirmation.confirmName || store.connectionState != "online" || Double(confirmation.expiresAtMs) <= context.date.timeIntervalSince1970 * 1000)
                }
            }.navigationTitle(title)
                .toolbar { Button("Cancel") { dismiss() } }
        }.frame(minWidth: 320, minHeight: 420)
    }
}
