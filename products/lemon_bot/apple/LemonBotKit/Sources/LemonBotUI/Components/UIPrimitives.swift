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
    var errorNonce: String?
    var receipt: String?
    func perform(_ action: () async throws -> Void) async {
        guard !running else { return }
        running = true
        error = nil; errorNonce = nil
        defer { running = false }
        do { try await action() } catch {
            // A view task cancelled by teardown or a reload is not a user-facing failure.
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            self.error = humanErrorText(error)
            if case ClientError.outcomeUnknown(let nonce) = error {
                uncertain = true
                uncertainNonce = nonce
                errorNonce = nonce
            } else if case ClientError.unresolvedMutation(let intent) = error {
                uncertain = true
                uncertainNonce = intent.clientNonce
                uncertainRunID = intent.runID
                errorNonce = intent.clientNonce
            } else if let backend = error as? BackendError {
                let runIDs = backend.failure.details?["runIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
                let entryIDs = backend.failure.details?["entryIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
                if backend.failure.code == "outcome_unknown" || (backend.failure.details?["clientNonce"]?.stringValue != nil && !runIDs.isEmpty && !entryIDs.isEmpty) {
                    uncertain = true
                    uncertainNonce = backend.failure.details?["clientNonce"]?.stringValue
                    errorNonce = uncertainNonce
                    uncertainRunID = backend.failure.details?["runId"]?.stringValue ?? backend.failure.details?["runIds"]?.arrayValue?.first?.stringValue
                }
            }
        }
    }
    func resolveUncertainty(_ nonce: String) {
        if uncertainNonce == nonce { uncertain = false; uncertainNonce = nil; uncertainRunID = nil }
        if errorNonce == nonce { error = nil; errorNonce = nil }
    }
}

struct ActionErrorView: View {
    let message: String?
    private static let diagnosticMarkers = ["\nDetails: ", "\nRequest: ", "\nExact runs: ", "\nRecorded entries: "]
    private func detailsStart(in text: String) -> String.Index? {
        var first: String.Index?
        for marker in Self.diagnosticMarkers {
            if let index = text.range(of: marker)?.lowerBound, first == nil || index < first! { first = index }
        }
        return first
    }
    var body: some View {
        if let message {
            let diagnosticStart = detailsStart(in: message)
            VStack(alignment: .leading, spacing: 8) {
                Label(diagnosticStart.map { String(message[..<$0]) } ?? message, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(LB.danger).textSelection(.enabled)
                if let diagnosticStart {
                    DisclosureGroup("Details") {
                        Text(String(message[diagnosticStart...]).trimmingCharacters(in: .whitespacesAndNewlines)).textSelection(.enabled)
                        Button("Copy") { copyText(message) }.buttonStyle(.pill(.quiet, compact: true))
                    }
                } else {
                    Button("Copy") { copyText(message) }.buttonStyle(.pill(.quiet, compact: true))
                }
            }.font(LBFont.rowSubtitle).padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: LBMetric.rowRadius, style: .continuous).fill(LB.danger.opacity(0.09)))
                .accessibilityElement(children: .contain)
        }
    }
}
struct BotIdentityAnchor: View {
    let store: LemonBotStore
    let bot: Bot
    var body: some View {
        HStack(spacing: 10) {
            BotBadgedAvatar(store: store, bot: bot, size: 36, presence: AvatarPresence(activity: bot.activity, online: store.isOnline), ring: LB.canvas)
            VStack(alignment: .leading, spacing: 1) {
                Text(bot.name).font(LBFont.rowTitle).foregroundStyle(LB.ink)
                Text(store.machine(for: bot)?.name ?? "Unknown machine").font(LBFont.meta).foregroundStyle(LB.muted)
            }
            Spacer(minLength: 8)
            StatusBadge(text: store.isOnline ? bot.activity : "last known: \(bot.activity)")
        }.accessibilityElement(children: .combine)
    }
}
/// Calm centered state when nothing is selected.
struct EmptySelectionView: View {
    var title = "Message a Bot"
    var message = "Pick a Bot on the left to pick up where you left off. Bots keep working on their machines while the app is closed."
    var body: some View {
        VStack(spacing: 14) {
            LemonMark(size: 76)
            Text(title).font(LBFont.title).foregroundStyle(LB.ink)
            Text(message).font(LBFont.body).foregroundStyle(LB.muted).multilineTextAlignment(.center).frame(maxWidth: 340)
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity).background(LB.canvas)
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
                SwiftUI.Section("Review what will change") {
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
                    Text("Type \(confirmation.confirmName) to confirm. This preview expires \(timestamp(Double(confirmation.expiresAtMs)), style: .relative).")
                    TextField(confirmation.confirmName, text: $name)
                    Text("No operation is queued while offline. Host files, backups and provider sessions remain unless this preview explicitly says otherwise.").font(.caption)
                }
                ActionErrorView(message: action.error)
                if action.uncertain { Text("We couldn't confirm this finished. Close this sheet and check the item before trying again. Nothing was resent automatically.").foregroundStyle(LB.warning) }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                if Double(confirmation.expiresAtMs) <= context.date.timeIntervalSince1970 * 1000 {
                    Text("This preview expired. Close this sheet and preview again.").foregroundStyle(LB.warning)
                }
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
