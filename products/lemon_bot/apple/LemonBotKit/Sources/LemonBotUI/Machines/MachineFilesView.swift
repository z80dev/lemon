import SwiftUI
import LemonBotKit
import UniformTypeIdentifiers
import QuickLook

public struct MachineFilesView: View {
    let store: LemonBotStore
    let machineID: ID
    @State private var path = ""
    @State private var files: [FileInfo] = []
    @State private var cursor: String?
    @State private var hidden = false
    @State private var selected: FileInfo?
    @State private var destination = ""
    @State private var newFolder = ""
    @State private var preview: HubConfirmation?
    @State private var previewURL: URL?
    @State private var exportURL: URL?
    @State private var exportPresented = false
    @State private var uploadPresented = false
    @State private var overwrite = false
    @State private var importBotID = ""
    @State private var importConversationID = ""
    @State private var imported: Attachment?
    @State private var transferProgress: String?
    @State private var action = HubAction()
    public init(store: LemonBotStore, machineID: ID) { self.store = store; self.machineID = machineID }
    public var body: some View {
        Form {
            HubError(action: action)
            if let transferProgress { Text(transferProgress).font(.caption) }
            Section("Destination-local path") {
                Text("Paths are on the selected host, confined by its allowed roots. Files/logins are shared by co-resident Bots. This is not your phone's filesystem.")
                TextField("Host directory", text: $path)
                HStack {
                    Button("Browse") { Task { await load() } }
                    Button("Parent") { path = (path as NSString).deletingLastPathComponent; Task { await load() } }
                    Toggle("Hidden files", isOn: $hidden).onChange(of: hidden) { Task { await load() } }
                }
                ScrollView(.horizontal) { HStack {
                    ForEach(Array(path.split(separator: "/").enumerated()), id: \.offset) { index, component in
                        Button(String(component)) { let root = path.hasPrefix("/") ? "/" : ""; path = root + path.split(separator: "/").prefix(index + 1).joined(separator: "/"); Task { await load() } }
                    }
                } }
            }
            Section("Files") {
                ForEach(files, id: \.path) { file in
                    Button { Task { await action.perform {
                        let stat: FileInfo = try await store.read("/machines/\(hubID(machineID))/files/stat", query: ["path": file.path]); selected = stat; destination = stat.path; preview = nil
                        if stat.kind == "directory" { path = stat.path; try await refresh() }
                    } } } label: {
                        HStack { Image(systemName: file.kind == "directory" ? "folder" : "doc"); VStack(alignment: .leading) { Text(file.name); Text("\(file.kind) · \(file.size) bytes · \(file.mime ?? "Unknown type")").font(.caption) } }
                    }
                }
                if cursor != nil { Button("More files") { Task { await load(more: true) } } }
            }
            if let file = selected {
                Section("Exact file stat") {
                    Text(file.path).textSelection(.enabled)
                    Text("Modified \(hubDate(file.modifiedAtMs)) · readable \(file.readable ? "yes" : "no") · writable \(file.writable ? "yes" : "no")")
                    if file.kind == "file" {
                        Button("Native preview") { Task { await action.perform { previewURL = try await fetch(file) } } }.disabled(!file.readable)
                        Button("Download / save original") { Task { await action.perform { exportURL = try await fetch(file); exportPresented = true } } }.disabled(!file.readable)
                        HubBotPicker(store: store, selection: $importBotID)
                        Picker("Conversation (optional)", selection: $importConversationID) { Text("None").tag(""); ForEach(store.conversations) { Text($0.name).tag($0.id) } }
                        Button("Import file as attachment") { Task { await action.perform {
                            var body: JSONObject = ["path": .string(file.path)]
                            if !importBotID.isEmpty { body["botId"] = .string(importBotID) }
                            if !importConversationID.isEmpty { body["conversationId"] = .string(importConversationID) }
                            imported = try await store.mutate("POST", "/machines/\(hubID(machineID))/files/import", body: body)
                        } } }.disabled(action.busy || action.uncertain || store.connectionState != "online")
                        if let imported { Text("Imported \(imported.filename) · attachment \(imported.id)"); Text("Provenance: Bot \(imported.provenance.botId ?? "none") / machine \(imported.provenance.machineId ?? "none") / run \(imported.provenance.runId ?? "none")").font(.caption) }
                    }
                    TextField("New absolute destination / rename", text: $destination)
                    Button("Move (never overwrites)") { Task { await action.perform {
                        let _: FileInfo = try await store.mutate("POST", "/machines/\(hubID(machineID))/files/move", body: ["path": .string(file.path), "destination": .string(destination), "expectedModifiedAtMs": .number(file.modifiedAtMs)]); selected = nil; try await refresh()
                    } } }.disabled(destination == file.path || action.busy || action.uncertain || store.connectionState != "online")
                    Button("Preview delete exact path", role: .destructive) { Task { await action.perform { preview = try await store.mutate("POST", "/machines/\(hubID(machineID))/files/preview", body: ["path": .string(file.path), "action": .string("delete")]) } } }.disabled(action.busy || action.uncertain || store.connectionState != "online")
                    if let preview { HubConfirmationForm(preview: preview, action: action) { name in await action.perform {
                        let _: HubDeleted = try await store.mutate("DELETE", "/machines/\(hubID(machineID))/files", body: ["path": .string(file.path), "confirmationToken": .string(preview.confirmationToken), "confirmName": .string(name)]); self.preview = nil; selected = nil; try await refresh()
                    } } }
                }
            }
            Section("Write to host") {
                TextField("New folder name", text: $newFolder)
                Button("Create folder") { Task { await action.perform {
                    let _: FileInfo = try await store.mutate("POST", "/machines/\(hubID(machineID))/files/mkdir", body: ["path": .string(join(newFolder))]); newFolder = ""; try await refresh()
                } } }.disabled(newFolder.isEmpty || action.busy || action.uncertain || store.connectionState != "online")
                Toggle("Overwrite selected file (explicit)", isOn: $overwrite)
                Button(overwrite ? "Choose upload to replace selected file" : "Choose upload into this directory") { uploadPresented = true }
                    .disabled(action.busy || action.uncertain || store.connectionState != "online" || (overwrite && selected?.kind != "file"))
            }
        }.navigationTitle("Host files")
            .task { await action.perform(readOnly: true) { let host: HostInfo = try await store.read("/machines/\(hubID(machineID))/host"); path = host.defaultCwd; try await refresh() } }
            .quickLookPreview($previewURL)
            .fileMover(isPresented: $exportPresented, file: exportURL) { result in if case .failure(let error) = result { action.error = String(describing: error) } }
            .fileImporter(isPresented: $uploadPresented, allowedContentTypes: [.data]) { result in
                switch result {
                case .success(let url): Task { await action.perform { try await upload(url); try await refresh() } }
                case .failure(let error): action.error = String(describing: error)
                }
            }
    }
    private func join(_ name: String) -> String { path.hasSuffix("/") ? path + name : path + "/" + name }
    private func refresh(more: Bool = false) async throws {
        var query = ["path": path, "showHidden": hidden ? "true" : "false"]
        if more, let cursor { query["cursor"] = cursor }
        let requestedPath = path, requestedHidden = hidden
        let page: HubPage<FileInfo> = try await store.read("/machines/\(hubID(machineID))/files", query: query)
        guard path == requestedPath, hidden == requestedHidden else { return }
        files = hubMerged(files, page.items, append: more, id: \.path); cursor = page.nextCursor
    }
    private func load(more: Bool = false) async { await action.perform(readOnly: true) { if !more { selected = nil; preview = nil }; try await refresh(more: more) } }
    private func fetch(_ file: FileInfo) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(file.name)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var offset = 0
        while true {
            try Task.checkCancellation()
            let chunk: FileChunk = try await store.read("/machines/\(hubID(machineID))/files/read", query: ["path": file.path, "offset": String(offset), "length": "1048576"])
            guard chunk.offset == offset, let data = Data(base64Encoded: chunk.dataBase64), data.count <= 1_048_576, !data.isEmpty || chunk.eof else { throw CocoaError(.fileReadCorruptFile) }
            try handle.write(contentsOf: data); offset += data.count
            transferProgress = "Downloaded \(offset) / \(chunk.size) source bytes"
            if chunk.eof {
                guard offset == chunk.size else { throw CocoaError(.fileReadCorruptFile) }
                break
            }
        }
        return url
    }
    private func upload(_ url: URL) async throws {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let target = overwrite ? selected!.path : join(url.lastPathComponent)
        var expected = overwrite ? selected?.modifiedAtMs : nil
        var offset = 0
        repeat {
            try Task.checkCancellation()
            guard store.connectionState == "online" else { throw ClientError.offline }
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty && offset > 0 { break }
            var body: JSONObject = ["path": .string(target), "dataBase64": .string(data.base64EncodedString()), "offset": .number(Double(offset)), "truncate": .bool(offset == 0), "mkdirs": .bool(false)]
            if let expected { body["expectedModifiedAtMs"] = .number(expected) }
            let written: FileInfo = try await store.mutate("PUT", "/machines/\(hubID(machineID))/files", body: body)
            expected = written.modifiedAtMs; offset += data.count
            transferProgress = "Uploaded \(offset) bytes to \(target); each acknowledged chunk is already written."
            if data.isEmpty { break }
        } while true
    }
}
