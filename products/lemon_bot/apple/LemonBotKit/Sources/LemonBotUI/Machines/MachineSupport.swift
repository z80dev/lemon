import SwiftUI
import LemonBotKit
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor @Observable final class HubAction {
    var busy = false
    var error: String?
    var uncertain = false
    var uncertainNonce: String?
    var uncertainResourceID: String?
    var pollingError: String?
    func poll(_ operation: @MainActor () async throws -> Void) async {
        guard !busy else { return }
        do { try await operation(); pollingError = nil }
        catch { if !(error is CancellationError) { pollingError = humanErrorText(error) } }
    }
    func checkStatus(_ store: LemonBotStore, reload: @MainActor () async throws -> Void) async {
        await perform(readOnly: true) {
            try await reload()
            if let uncertainNonce, try await store.reconcileMutation(uncertainNonce) {
                uncertain = false
                self.uncertainNonce = nil
                error = nil
            }
        }
    }
    func perform(readOnly: Bool = false, _ operation: @MainActor () async throws -> Void) async {
        guard !busy, readOnly || !uncertain else { return }
        busy = true
        if !uncertain { error = nil }
        defer { busy = false }
        do { try await operation() }
        catch {
            self.error = humanErrorText(error)
            if let backend = error as? BackendError, backend.failure.code == "outcome_unknown" {
                uncertain = true
                uncertainNonce = backend.failure.details?["clientNonce"]?.stringValue
            }
            if case ClientError.outcomeUnknown(let nonce) = error { uncertain = true; uncertainNonce = nonce }
            if case ClientError.unresolvedMutation(let intent) = error { uncertain = true; uncertainNonce = intent.clientNonce }
        }
    }
}
struct HubError: View {
    let action: HubAction
    let store: LemonBotStore
    var body: some View {
        if let error = action.error {
            VStack(alignment: .leading) {
                ActionErrorView(message: error)
                if action.uncertain { Text("We couldn't confirm this finished. Check the result before trying again. Nothing was resent.").font(LBFont.meta).foregroundStyle(LB.warning) }
                if action.uncertainNonce != nil {
                    Button("Check status") { Task { await action.checkStatus(store) { try await store.refresh() } } }
                        .disabled(action.busy || store.connectionState != "online")
                }
                if store.connectionState != "online" { Text("Reconnect to check this action.").font(LBFont.meta).foregroundStyle(LB.muted) }
            }
        }
        if action.error == nil { ActionErrorView(message: action.pollingError) }
        if action.busy { ProgressView() }
    }
}
func hubID(_ id: String) -> String {
    id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
}
func hubDate(_ ms: Double?) -> String {
    guard let ms else { return "Not reported" }
    return Date(timeIntervalSince1970: ms / 1000).formatted(date: .abbreviated, time: .shortened)
}
@MainActor func hubCopy(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
}
func hubBody<T: Encodable>(_ value: T) throws -> JSONObject {
    try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(value))
}
typealias HubOK = LemonBotKit.Empty
typealias HubDeleted = Deleted
typealias HubPage<T: Codable & Hashable> = Page<T>
typealias HubConfirmation = Confirmation
extension Confirmation {
    func body(name: String) -> JSONObject {
        ["revision": .number(Double(revision)), "confirmationToken": .string(confirmationToken), "confirmName": .string(name)]
    }
}
func hubMerged<T>(_ existing: [T], _ incoming: [T], append: Bool, id: KeyPath<T, String>) -> [T] {
    var result = append ? existing : []
    var indices = Dictionary(result.enumerated().map { ($0.element[keyPath: id], $0.offset) }, uniquingKeysWith: { first, _ in first })
    for item in incoming {
        let key = item[keyPath: id]
        if let index = indices[key] { result[index] = item }
        else { indices[key] = result.count; result.append(item) }
    }
    return result
}
struct HubConfirmationForm: View {
    let store: LemonBotStore
    let preview: HubConfirmation
    let action: HubAction
    let commit: (String) async -> Void
    @State private var typedName = ""
    var body: some View {
        Section("Review what will change") {
            ForEach(Array(preview.effects.enumerated()), id: \.offset) { _, effect in Text(effect) }
            ForEach(Array(preview.affected.enumerated()), id: \.offset) { _, effect in
                VStack(alignment: .leading) {
                    Text("\(effect.operation): \(effect.resourceType) \(effect.id)").font(.headline)
                    Text(effect.explanation)
                    if let machine = effect.machineId { Text("Machine: \(machine)").font(.caption) }
                }
            }
            Text("Expires \(hubDate(preview.expiresAtMs))")
            TextField("Type exactly: \(preview.confirmName)", text: $typedName)
            Button("\(preview.affected.first?.operation.capitalized ?? "Confirm") \(preview.confirmName)", role: .destructive) {
                guard store.connectionState == "online" else { action.error = "Reconnect before confirming. This destructive action was not queued."; return }
                Task { await commit(typedName) }
            }
                .disabled(store.connectionState != "online" || typedName != preview.confirmName || Date().timeIntervalSince1970 * 1000 >= preview.expiresAtMs || action.busy || action.uncertain)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if context.date.timeIntervalSince1970 * 1000 >= preview.expiresAtMs {
                    Text("This preview expired. Preview again to continue.").font(LBFont.meta).foregroundStyle(LB.warning)
                }
            }
        }
    }
}
struct HubBotPicker: View {
    let store: LemonBotStore
    @Binding var selection: String
    var body: some View { Picker("Bot", selection: $selection) { Text("Select a Bot").tag(""); ForEach(store.bots) { Text($0.name).tag($0.id) } } }
}
struct HubMachinePicker: View {
    let store: LemonBotStore
    @Binding var selection: String
    var body: some View { Picker("Machine", selection: $selection) { Text("Select a machine").tag(""); ForEach(store.machines) { Text("\($0.name) · \($0.status)").tag($0.id) } } }
}

func hubStatusLabel(_ state: String) -> String {
    switch state {
    case "outcome_unknown": return "Result not confirmed"
    case "queued", "reserved": return "Waiting to start"
    case "accepted": return "Started, not finished"
    default: return humanizedStatus(state)
    }
}
