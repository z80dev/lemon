import SwiftUI
import LemonBotKit
import UniformTypeIdentifiers

public struct LibraryHubView: View {
    let store: LemonBotStore
    public init(store: LemonBotStore) { self.store = store }
    public var body: some View {
        List {
            NavigationLink("Skills · reusable instructions") { SkillLibraryView(store: store) }
            NavigationLink("Routines · schedules and events") { RoutineLibraryView(store: store) }
            Section("Bot profile memory") {
                ForEach(store.bots) { bot in NavigationLink(bot.name) { MemoryHubView(store: store, botID: bot.id) } }
            }
            NavigationLink("Reviewed templates") { TemplateHubView(store: store) }
        }.navigationTitle("Library")
    }
}
struct SkillLibraryView: View {
    let store: LemonBotStore
    @State private var skills: [Skill] = []
    @State private var cursor: String?
    @State private var query = ""
    @State private var botID = ""
    @State private var create = false
    @State private var action = HubAction()
    var body: some View {
        List {
            HubError(action: action, store: store)
            TextField("Search skills", text: $query).onSubmit { Task { await load() } }
            HubBotPicker(store: store, selection: $botID).onChange(of: botID) { Task { await load() } }
            ForEach(skills) { skill in NavigationLink { SkillEditorView(store: store, initial: skill) } label: {
                VStack(alignment: .leading) {
                    Text(skill.name).font(.headline)
                    Text("\(skill.enabled ? "Enabled" : "Disabled") · Installed on \(skill.machineIds.count) machines")
                    Text(skill.description)
                    Text("Publisher: \(skill.provenance.publisher) · \(skill.provenance.trusted ? "Trusted source" : "Untrusted instructions")").font(LBFont.meta)
                }
            } }
            if cursor != nil { Button("More skills") { Task { await load(more: true) } } }
        }.navigationTitle("Skills").toolbar { Button("New skill") { create = true }; Button("Search / refresh") { Task { await load() } } }
            .sheet(isPresented: $create) { NavigationStack { SkillEditorView(store: store, initial: nil) } }
            .task { await load() }
    }
    private func load(more: Bool = false) async { await action.perform(readOnly: true) {
        var filters: [String: String] = [:]; if !query.isEmpty { filters["query"] = query }; if !botID.isEmpty { filters["botId"] = botID }; if more, let cursor { filters["cursor"] = cursor }
        let page: HubPage<Skill> = try await store.read("/skills", query: filters); skills = hubMerged(skills, page.items, append: more, id: \.id); cursor = page.nextCursor
    } }
}
struct SkillEditorView: View {
    let store: LemonBotStore
    let initial: Skill?
    @Environment(\.dismiss) private var dismiss
    @State private var saved: Skill?
    @State private var name = ""
    @State private var description = ""
    @State private var markdown = ""
    @State private var enabled = true
    @State private var botID = ""
    @State private var targetBotID = ""
    @State private var machines: Set<ID> = []
    @State private var acknowledged = false
    @State private var importFile = false
    @State private var deletePresented = false
    @State private var action = HubAction()
    var body: some View {
        Form {
            HubError(action: action, store: store)
            if acknowledged { Text(machines.isEmpty ? "Saved in the library. No machines were selected for installation." : "Saved and installed on the selected machines. Installing doesn't run the skill.").foregroundStyle(LB.success) }
            TextField("Name", text: $name)
            TextField("Description", text: $description)
            Text("Specify inputs, steps, decisions, validation, output and required human approvals. Third-party skill text is untrusted, not authorization.")
            TextEditor(text: $markdown).frame(minHeight: 250).font(LBFont.code)
            Button("Load text from file…") { importFile = true }
            if saved == nil { HubBotPicker(store: store, selection: $botID) }
            else { Toggle("Enabled", isOn: $enabled) }
            Section("Install on machines") {
                ForEach(store.machines) { machine in Toggle("\(machine.name) · \(machine.status)", isOn: Binding(get: { machines.contains(machine.id) }, set: { if $0 { machines.insert(machine.id) } else { machines.remove(machine.id) }; acknowledged = false })) }
            }
            Button(machines.isEmpty ? "Save to library" : "Save and install on selected machines") { Task { await action.perform {
                var body: JSONObject = ["name": .string(name), "description": .string(description), "markdown": .string(markdown), "machineIds": .array(machines.sorted().map(JSONValue.string))]
                if let saved { body["revision"] = .number(Double(saved.revision)); body["enabled"] = .bool(enabled); self.saved = try await store.mutate("PATCH", "/skills/\(hubID(saved.id))", body: body) }
                else { if !botID.isEmpty { body["botId"] = .string(botID) }; self.saved = try await store.mutate("POST", "/skills", body: body) }
                acknowledged = true
            } } }.disabled(name.isEmpty || description.isEmpty || markdown.isEmpty || action.busy || action.uncertain || store.connectionState != "online")
            if let saved {
                Section("Provenance") {
                    Text("Publisher: \(saved.provenance.publisher)")
                    if let source = saved.provenance.sourceUrl, let url = URL(string: source), ["https", "http"].contains(url.scheme ?? "") { Link("Source", destination: url) }
                    Text(saved.provenance.trusted ? "Trusted source" : "Untrusted third-party text")
                }
                HubBotPicker(store: store, selection: $targetBotID)
                Button("Add this enabled skill to selected Bot") { Task { await action.perform {
                    let bot: Bot = try await store.read("/bots/\(hubID(targetBotID))")
                    guard saved.machineIds.contains(bot.machineId) else { throw SkillHostError.notProvisioned }
                    let ids = Array(Set(bot.skillIds + [saved.id])).sorted()
                    let _: Bot = try await store.mutate("PATCH", "/bots/\(hubID(bot.id))", body: ["revision": .number(Double(bot.revision)), "skillIds": .array(ids.map(JSONValue.string))])
                } } }.disabled(!saved.enabled || targetBotID.isEmpty || action.busy || action.uncertain || store.connectionState != "online")
                Button("Delete skill and its installed files", role: .destructive) { deletePresented = true }
            }
        }.formStyle(.grouped).navigationTitle(saved?.name ?? "New skill").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { if let initial { saved = initial; name = initial.name; description = initial.description; markdown = initial.markdown; enabled = initial.enabled; botID = initial.botId ?? ""; machines = Set(initial.machineIds) } }
            .fileImporter(isPresented: $importFile, allowedContentTypes: [.plainText, .text]) { result in
                do {
                    let url = try result.get(); let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url); guard data.count <= 262_144, let text = String(data: data, encoding: .utf8) else { throw SkillImportError.invalidText }; markdown = text
                } catch { action.error = humanErrorText(error) }
            }
            .confirmationDialog("Delete this skill and its installed files? Other files and history are kept.", isPresented: $deletePresented) {
                Button("Delete skill", role: .destructive) { guard let saved else { return }; Task { await action.perform { let _: HubDeleted = try await store.mutate("DELETE", "/skills/\(hubID(saved.id))", body: ["revision": .number(Double(saved.revision))]); dismiss() } } }.disabled(action.busy || action.uncertain || store.connectionState != "online")
            }
    }
}
private enum SkillHostError: LocalizedError { case notProvisioned; var errorDescription: String? { "Install this skill on the Bot's machine before adding it to the Bot." } }
private enum SkillImportError: LocalizedError {
    case invalidText
    var errorDescription: String? { "Skill text must be UTF-8 text no larger than 256 KB." }
}
