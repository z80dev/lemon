import SwiftUI
import LemonBotKit
import UniformTypeIdentifiers

public struct TemplateHubView: View {
    let store: LemonBotStore
    @State private var templates: [BotTemplate] = []
    @State private var cursor: String?
    @State private var query = ""
    @State private var publishPresented = false
    @State private var action = HubAction()
    public init(store: LemonBotStore) { self.store = store }
    public var body: some View {
        List {
            HubError(action: action, store: store)
            TextField("Search reviewed templates", text: $query).onSubmit { Task { await load() } }
            Text("Templates are separate declarative copies. They do not grant access to the author's live Bot, learned memory, private history or credentials. Review instructions for confidential prose before publishing.")
            ForEach(templates) { template in
                NavigationLink { TemplateDetailView(store: store, templateID: template.id) } label: {
                    VStack(alignment: .leading) {
                        Text(template.content.name).font(.headline)
                        Text(template.content.title)
                        Text("\(template.audience) · \(template.provenance.publisher) · \(template.provenance.thirdParty ? "Third party" : "Workspace author")").font(.caption)
                    }
                }
            }
            if cursor != nil { Button("More templates") { Task { await load(more: true) } } }
        }.navigationTitle("Templates").toolbar { Button("Publish / export Bot") { publishPresented = true }; Button("Search / refresh") { Task { await load() } } }
            .task { await load() }.sheet(isPresented: $publishPresented) { NavigationStack { TemplatePublishView(store: store) } }
    }
    private func load(more: Bool = false) async { await action.perform(readOnly: true) {
        var filters: [String: String] = [:]; if !query.isEmpty { filters["query"] = query }; if more, let cursor { filters["cursor"] = cursor }
        let page: HubPage<BotTemplate> = try await store.read("/templates", query: filters); templates = hubMerged(templates, page.items, append: more, id: \.id); cursor = page.nextCursor
    } }
}
struct TemplateContentReview: View {
    let content: TemplateContent
    var body: some View {
        Section("Declarative content — review before use or sharing") {
            Text(content.name).font(.headline)
            Text(content.title)
            Text("Job").font(.headline); Text(content.job).textSelection(.enabled)
            Text("Instructions").font(.headline); Text(content.instructions).textSelection(.enabled)
            Text("Voice \(content.voice.voiceId) · \(content.voice.speed)× · \(content.voice.language ?? "default language")")
            Text("Character / avatar \(content.avatar.kind) · \(content.avatar.shape) · \(content.avatar.color)")
            ForEach(Array(content.skills.enumerated()), id: \.offset) { _, skill in
                DisclosureGroup("Skill: \(skill.name)") { Text(skill.description); Text(skill.markdown).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            }
            ForEach(Array(content.routines.enumerated()), id: \.offset) { _, routine in
                DisclosureGroup("Routine: \(routine.name)") { Text(routine.instruction); Text(routineTriggerDescription(routine.trigger)); Text("Imported routines start paused.") }
            }
            Text("Connector names (not credentials): \(content.connectorNames.joined(separator: ", "))")
            Text("No automatic memory/history/credentials copy. Instructions can contain sensitive prose; export is not a magical confidentiality scrubber.").foregroundStyle(.orange)
        }
    }
}
func routineTriggerDescription(_ trigger: RoutineTrigger) -> String {
    switch trigger {
    case .schedule(let value): return "Schedule \(value.cron) · \(value.timezone)"
    case .webhook: return "Authenticated webhook"
    case .channelEvent(let value): return "Channel event \(value.event) · binding \(value.channelBindingId)"
    case .externalEvent(let value): return "External \(value.source) · \(value.eventNames.joined(separator: ", "))"
    }
}
public struct TemplateDetailView: View {
    let store: LemonBotStore
    let templateID: ID
    @State private var template: BotTemplate?
    @State private var machineID = ""
    @State private var importName = ""
    @State private var acceptedTerms = false
    @State private var trustedHost = false
    @State private var reviewed = false
    @State private var audience = "workspace"
    @State private var name = ""
    @State private var title = ""
    @State private var job = ""
    @State private var instructions = ""
    @State private var deletePresented = false
    @State private var importedBot: Bot?
    @State private var exportDocument: HubJSONDocument?
    @State private var exportPresented = false
    @State private var action = HubAction()
    public init(store: LemonBotStore, templateID: ID) { self.store = store; self.templateID = templateID }
    public var body: some View {
        Form {
            HubError(action: action, store: store)
            if let template {
                Section("Provenance and terms") {
                    Text("Publisher: \(template.provenance.publisher) · \(template.provenance.thirdParty ? "Third-party instructions, not first-party trust" : "Workspace author")")
                    Text("Audience: \(template.audience) · owner \(template.ownerUserId)")
                    if let source = template.provenance.sourceUrl, let url = safeURL(source) { Link("Original source", destination: url) }
                    if let terms = template.provenance.termsUrl, let url = safeURL(terms) { Link("Read terms", destination: url) }
                    if let url = safeURL(template.shareUrl) { ShareLink("Share template link (not original Bot)", item: url) }
                }
                TemplateContentReview(content: template.content)
                Section("Import distinct owned Bot") {
                    TextField("New Bot name", text: $importName)
                    HubMachinePicker(store: store, selection: $machineID)
                    Toggle("I reviewed the instructions and accept applicable third-party terms", isOn: $acceptedTerms)
                    Toggle("I trust this host: co-resident Bots share its files and logins", isOn: $trustedHost)
                    Button("Import new owned Bot") { Task { await action.perform {
                        importedBot = try await store.mutate("POST", "/templates/\(hubID(template.id))/import", body: ["name": .string(importName), "machineId": .string(machineID), "acceptedTerms": .bool(acceptedTerms)])
                    } } }.disabled(importName.isEmpty || machineID.isEmpty || !acceptedTerms || !trustedHost || action.busy || action.uncertain || store.connectionState != "online")
                    if let importedBot { Text("Created distinct Bot \(importedBot.name) on \(importedBot.machineId)"); NavigationLink("Open imported Bot") { BotOverviewView(store: store, botID: importedBot.id) } }
                }
                Button("Export declarative template content") { do { exportDocument = HubJSONDocument(data: try JSONEncoder().encode(template.content)); exportPresented = true } catch { action.error = String(describing: error) } }
                if template.ownerUserId == store.user?.id {
                    Section("Owner edit / publishing review") {
                        TextField("Template name", text: $name)
                        TextField("Title", text: $title)
                        Text("Job"); TextEditor(text: $job).frame(minHeight: 100)
                        Text("Instructions"); TextEditor(text: $instructions).frame(minHeight: 160)
                        Picker("Audience", selection: $audience) { Text("Workspace").tag("workspace"); Text("Public").tag("public") }
                        Toggle("I reviewed declarative content and removed confidential prose / private credentials", isOn: $reviewed)
                        Button("Save reviewed template revision") { Task { await action.perform {
                            var content = template.content; content.name = name; content.title = title; content.job = job; content.instructions = instructions
                            self.template = try await store.mutate("PATCH", "/templates/\(hubID(template.id))", body: ["revision": .number(Double(template.revision)), "audience": .string(audience), "content": .object(try hubBody(content)), "reviewed": .bool(true)])
                            reviewed = false
                        } } }.disabled(!reviewed || name.isEmpty || action.busy || action.uncertain || store.connectionState != "online")
                        Button("Revoke template link / delete", role: .destructive) { deletePresented = true }
                    }
                }
            }
        }.navigationTitle(template?.content.name ?? "Template")
            .task { await action.perform(readOnly: true) { let value: BotTemplate = try await store.read("/templates/\(hubID(templateID))"); template = value; importName = value.content.name; name = value.content.name; title = value.content.title; job = value.content.job; instructions = value.content.instructions; audience = value.audience } }
            .fileExporter(isPresented: $exportPresented, document: exportDocument, contentType: .json, defaultFilename: "lemon-template") { if case .failure(let error) = $0 { action.error = String(describing: error) } }
            .confirmationDialog("Revoke this exact template link? Existing imported Bots remain independent.", isPresented: $deletePresented) {
                Button("Delete template", role: .destructive) { guard let template else { return }; Task { await action.perform { let _: HubDeleted = try await store.mutate("DELETE", "/templates/\(hubID(template.id))", body: ["revision": .number(Double(template.revision))]); self.template = nil; action.error = "Template link was revoked; existing copies remain." } } }.disabled(action.busy || action.uncertain || store.connectionState != "online")
            }
    }
    private func safeURL(_ string: String) -> URL? { guard let url = URL(string: string), ["https", "http"].contains(url.scheme ?? "") else { return nil }; return url }
}
struct TemplatePublishView: View {
    let store: LemonBotStore
    @Environment(\.dismiss) private var dismiss
    @State private var botID = ""
    @State private var content: TemplateContent?
    @State private var audience = "workspace"
    @State private var reviewed = false
    @State private var published: BotTemplate?
    @State private var exportDocument: HubJSONDocument?
    @State private var exportPresented = false
    @State private var action = HubAction()
    var body: some View {
        Form {
            HubError(action: action, store: store)
            HubBotPicker(store: store, selection: $botID).onChange(of: botID) { content = nil; reviewed = false; published = nil }
            Button("Load actual declarative export for review") { Task { await action.perform(readOnly: true) { content = try await store.read("/bots/\(hubID(botID))/export") } } }.disabled(botID.isEmpty)
            if let content {
                TemplateContentReview(content: content)
                Picker("Audience", selection: $audience) { Text("Workspace").tag("workspace"); Text("Public (policy dependent)").tag("public") }.onChange(of: audience) { reviewed = false }
                Toggle("I explicitly reviewed content and removed confidential prose and private credentials", isOn: $reviewed)
                Button("Publish reviewed declarative copy") { Task { await action.perform {
                    published = try await store.mutate("POST", "/templates", body: ["botId": .string(botID), "audience": .string(audience), "reviewed": .bool(true)])
                } } }.disabled(!reviewed || action.busy || action.uncertain || store.connectionState != "online")
                Button("Export JSON without publishing") { do { exportDocument = HubJSONDocument(data: try JSONEncoder().encode(content)); exportPresented = true } catch { action.error = String(describing: error) } }
                if let published { Text("Published \(published.audience) template \(published.content.name)"); NavigationLink("Inspect published template") { TemplateDetailView(store: store, templateID: published.id) } }
            }
        }.navigationTitle("Review publication").toolbar { Button("Close") { dismiss() } }
            .fileExporter(isPresented: $exportPresented, document: exportDocument, contentType: .json, defaultFilename: "lemon-template") { if case .failure(let error) = $0 { action.error = String(describing: error) } }
    }
}
