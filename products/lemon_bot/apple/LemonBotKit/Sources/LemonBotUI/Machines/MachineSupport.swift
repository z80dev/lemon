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
    func perform(readOnly: Bool = false, _ operation: @MainActor () async throws -> Void) async {
        guard !busy, readOnly || !uncertain else { return }
        busy = true
        if !uncertain { error = nil }
        defer { busy = false }
        do { try await operation() }
        catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            if let backend = error as? BackendError, backend.failure.code == "outcome_unknown" { uncertain = true }
            if let client = error as? ClientError, case .outcomeUnknown = client { uncertain = true }
        }
    }
}
struct HubError: View {
    let action: HubAction
    var body: some View {
        if let error = action.error {
            VStack(alignment: .leading) {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                if action.uncertain { Text("Outcome not confirmed. Do not repeat this action; reconcile the affected resource before submitting a new intent.").font(.caption) }
            }
        }
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
        Section("Review exact scope") {
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
            Button("Confirm reviewed action", role: .destructive) {
                guard store.connectionState == "online" else { action.error = "Reconnect before confirming. This destructive action was not queued."; return }
                Task { await commit(typedName) }
            }
                .disabled(store.connectionState != "online" || typedName != preview.confirmName || Date().timeIntervalSince1970 * 1000 >= preview.expiresAtMs || action.busy || action.uncertain)
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
