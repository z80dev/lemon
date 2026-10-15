import SwiftUI
import LemonBotKit
import UniformTypeIdentifiers

struct HubJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
public struct MemoryHubView: View {
    let store: LemonBotStore
    let botID: ID
    let initialMemoryID: ID?
    @State private var memories: [Memory] = []
    @State private var cursor: String?
    @State private var query = ""
    @State private var text = ""
    @State private var kind = "fact"
    @State private var editing: Memory?
    @State private var forgetting: Memory?
    @State private var confirmation: HubConfirmation?
    @State private var importPresented = false
    @State private var exportPresented = false
    @State private var exportDocument: HubJSONDocument?
    @State private var action = HubAction()
    public init(store: LemonBotStore, botID: ID, memoryID: ID? = nil) { self.store = store; self.botID = botID; initialMemoryID = memoryID }
    public var body: some View {
        Form {
            HubError(action: action, store: store)
            Text("Memory is durable context in this Bot's profile, not current truth. Recheck authoritative live sources before consequential decisions. Identity and Job are separate.")
            Section("Search") {
                TextField("Search memory", text: $query).onSubmit { Task { await load() } }
                Button("Search / refresh") { Task { await load() } }
            }
            Section("Saved facts") {
                ForEach(memories) { memory in
                    VStack(alignment: .leading) {
                        Text(memory.text).textSelection(.enabled)
                        Text("\(memory.kind) · source \(memory.sourceEntryId ?? "explicit manual entry")").font(.caption)
                        HStack {
                            Button("Correct") { editing = memory; text = memory.text; kind = memory.kind }
                            Button("Preview forget", role: .destructive) { Task { await action.perform { forgetting = memory; confirmation = try await store.mutate("POST", "/memory/\(hubID(memory.id))/preview", body: ["action": .string("forget")]) } } }
                                .disabled(action.busy || action.uncertain || store.connectionState != "online")
                        }
                    }
                }
                if cursor != nil { Button("More memory") { Task { await load(more: true) } } }
            }
            if let confirmation, let forgetting { HubConfirmationForm(store: store, preview: confirmation, action: action) { name in await action.perform {
                let _: HubDeleted = try await store.mutate("DELETE", "/memory/\(hubID(forgetting.id))", body: confirmation.body(name: name)); self.confirmation = nil; self.forgetting = nil; try await refresh()
            } } }
            Section(editing == nil ? "Add explicit memory" : "Correct selected memory") {
                TextEditor(text: $text).frame(minHeight: 120)
                Picker("Kind", selection: $kind) { ForEach(["fact", "preference", "instruction", "summary"], id: \.self) { Text($0).tag($0) } }
                Button("Save acknowledged memory") { Task { await action.perform {
                    let body: JSONObject = ["text": .string(text), "kind": .string(kind)]
                    if let editing {
                        var update = body; update["revision"] = .number(Double(editing.revision)); let _: Memory = try await store.mutate("PATCH", "/memory/\(hubID(editing.id))", body: update)
                    } else {
                        let _: Memory = try await store.mutate("POST", "/bots/\(hubID(botID))/memory", body: body)
                    }
                    text = ""; editing = nil; try await refresh()
                } } }.disabled(text.isEmpty || action.busy || action.uncertain || store.connectionState != "online")
                if editing != nil { Button("Cancel correction") { editing = nil; text = "" } }
            }
            Section("Reviewed import / visible export") {
                Button("Review import candidates") { importPresented = true }
                Button("Export caller-visible memory") { Task { await action.perform {
                    let value: MemoryExport = try await store.read("/bots/\(hubID(botID))/memory/export")
                    exportDocument = HubJSONDocument(data: try JSONEncoder().encode(value)); exportPresented = true
                } } }
                Text("Export contains only authorized scope. Forgetting leaves independent transcripts and operator backups; the preview shows exact effects.").font(.caption)
            }
        }.navigationTitle("Memory")
            .task {
                if let initialMemoryID {
                    await action.perform(readOnly: true) {
                        let memory: Memory = try await store.read("/memory/\(hubID(initialMemoryID))")
                        guard memory.botId == botID else { throw RoutineFormError.invalid("Memory belongs to a different Bot.") }
                        editing = memory; text = memory.text; kind = memory.kind
                        try await refresh()
                    }
                } else { await load() }
            }
            .sheet(isPresented: $importPresented) { NavigationStack { MemoryImportView(store: store, botID: botID) } }
            .fileExporter(isPresented: $exportPresented, document: exportDocument, contentType: .json, defaultFilename: "lemon-memory") { if case .failure(let error) = $0 { action.error = String(describing: error) } }
    }
    private func refresh(more: Bool = false) async throws {
        var filters: [String: String] = [:]; if !query.isEmpty { filters["query"] = query }; if more, let cursor { filters["cursor"] = cursor }
        let requestedQuery = query
        let page: HubPage<Memory> = try await store.read("/bots/\(hubID(botID))/memory", query: filters)
        guard query == requestedQuery else { return }
        memories = hubMerged(memories, page.items, append: more, id: \.id); cursor = page.nextCursor
    }
    private func load(more: Bool = false) async { await action.perform(readOnly: true) { try await refresh(more: more) } }
}
struct MemoryImportView: View {
    let store: LemonBotStore
    let botID: ID
    @Environment(\.dismiss) private var dismiss
    @State private var format = "facts_text"
    @State private var text = ""
    @State private var attachment: Attachment?
    @State private var importFile = false
    @State private var preview: MemoryImportPreview?
    @State private var selected: Set<ID> = []
    @State private var reviewed = false
    @State private var result: MemoryImportResult?
    @State private var action = HubAction()
    var body: some View {
        Form {
            HubError(action: action, store: store)
            if let result {
                Section("Acknowledged import result") {
                    Text(result.status)
                    ForEach(result.items) { Text($0.text) }
                    if !result.failedCandidateIds.isEmpty { Text("Failed candidates: \(result.failedCandidateIds.joined(separator: ", "))").foregroundStyle(.red) }
                    Text("Only acknowledged facts above were saved. Uncertain results must be reconciled; never automatically repeat an import.")
                }
            } else if let preview {
                Section("Exact destination / source") {
                    Text("Bot \(preview.botId) · machine \(preview.machineId)")
                    Text("Source SHA256: \(preview.sourceSha256)").textSelection(.enabled)
                    Text("Expires \(hubDate(preview.expiresAtMs))")
                }
                Section("Candidate facts — explicitly select") {
                    ForEach(preview.candidates, id: \.id) { candidate in
                        VStack(alignment: .leading) {
                            Toggle(candidate.text, isOn: Binding(get: { selected.contains(candidate.id) }, set: { if $0 { selected.insert(candidate.id) } else { selected.remove(candidate.id) }; reviewed = false }))
                            Text("\(candidate.kind) · \(candidate.source.filename ?? "text") · \(candidate.source.locator)").font(.caption)
                            Text(candidate.source.excerpt).font(.caption).textSelection(.enabled)
                        }
                    }
                }
                Section("Excluded material") {
                    ForEach(Array(preview.exclusions.enumerated()), id: \.offset) { _, exclusion in Text("\(exclusion.locator) · \(exclusion.reason): \(exclusion.summary)") }
                }
                Toggle("I reviewed selected durable facts, provenance and exclusions; do not replay whole chats or credentials", isOn: $reviewed)
                Button("Confirm selected facts and write memory") { Task { await action.perform {
                    result = try await store.mutate("POST", "/bots/\(hubID(botID))/memory/import", body: ["previewId": .string(preview.id), "revision": .number(Double(preview.revision)), "confirmationToken": .string(preview.confirmationToken), "selectedCandidateIds": .array(selected.sorted().map(JSONValue.string))])
                } } }.disabled(!reviewed || selected.isEmpty || Date().timeIntervalSince1970 * 1000 >= preview.expiresAtMs || action.busy || action.uncertain || store.connectionState != "online")
                Button("Discard preview / change source") { self.preview = nil; selected = []; reviewed = false }
            } else {
                Picker("Source format", selection: $format) { Text("Explicit fact paragraphs").tag("facts_text"); Text("Lemon memory JSON").tag("lemon_memory_json"); Text("Supported chat export ZIP").tag("chat_export_zip") }
                if let attachment { Text("Selected upload: \(attachment.filename)"); Button("Remove source file") { self.attachment = nil } }
                else { TextEditor(text: $text).frame(minHeight: 180) }
                Button("Choose source file") { importFile = true }
                Text("Preview proposes explicit durable statements. It excludes credentials, private profiles, duplicates, unsupported and non-durable material. Nothing is saved before checked confirmation.")
                Button("Generate read-only candidate preview") { Task { await action.perform {
                    var body: JSONObject = ["format": .string(format)]
                    if let attachment { body["attachmentId"] = .string(attachment.id) } else { body["text"] = .string(text) }
                    let value: MemoryImportPreview = try await store.mutate("POST", "/bots/\(hubID(botID))/memory/import/preview", body: body)
                    preview = value; selected = Set(value.candidates.filter(\.selectedByDefault).map(\.id)); reviewed = false
                } } }.disabled((attachment == nil && text.isEmpty) || action.busy || action.uncertain || store.connectionState != "online")
            }
        }.navigationTitle("Reviewed memory import").toolbar { Button("Close") { dismiss() } }
            .fileImporter(isPresented: $importFile, allowedContentTypes: [.data, .json, .plainText, .zip]) { result in
                switch result {
                case .success(let url): Task { await action.perform {
                    let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    attachment = try await store.upload(fileURL: url, mime: format == "chat_export_zip" ? "application/zip" : (format == "lemon_memory_json" ? "application/json" : "text/plain"), metadata: ["purpose": .string("reference"), "botId": .string(botID)])
                } }
                case .failure(let error): action.error = String(describing: error)
                }
            }
    }
}
