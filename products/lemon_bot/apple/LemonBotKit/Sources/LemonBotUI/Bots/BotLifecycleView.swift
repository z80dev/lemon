import SwiftUI
import LemonBotKit

struct BotLifecycleView: View {
    let store: LemonBotStore
    let bot: Bot
    @Environment(\.dismiss) private var dismiss
    @State private var operation = "duplicate"
    @State private var name = ""
    @State private var machineID = ""
    @State private var includeSkills = true
    @State private var includeRoutines = false
    @State private var sharedHostConsent = false
    @State private var memory: [Memory] = []
    @State private var skills: [Skill] = []
    @State private var routines: [Routine] = []
    @State private var connectors: [Connector] = []
    @State private var selectedMemory: Set<ID> = []
    @State private var selectedSkills: Set<ID> = []
    @State private var selectedFiles: Set<ID> = []
    @State private var selectedRoutines: Set<ID> = []
    @State private var selectedConnectors: Set<ID> = []
    @State private var resetScopes: Set<String> = []
    @State private var confirmation: Confirmation?
    @State private var action = UIActionState()
    init(store: LemonBotStore, bot: Bot) {
        self.store = store; self.bot = bot
        _operation = State(initialValue: bot.ownerUserId == store.user?.id || bot.managerUserIds.contains(store.user?.id ?? "") ? "duplicate" : "delete")
    }
    private var manages: Bool { owner || bot.managerUserIds.contains(store.user?.id ?? "") }
    private var owner: Bool { bot.ownerUserId == store.user?.id }
    private var mayDelete: Bool { owner || (bot.visibility == "team" && ["owner", "admin"].contains(store.member?.role ?? "")) }
    var body: some View {
        NavigationStack {
            Form {
                SwiftUI.Section("Distinct operations") {
                    Picker("Operation", selection: $operation) {
                        if manages { Text("Duplicate").tag("duplicate"); Text("Personal → Team copy").tag("team-copy"); Text("Move machine").tag("move") }
                        if owner { Text("Reset selected scopes").tag("reset") }
                        if mayDelete { Text("Delete Bot").tag("delete") }
                    }
                    Text("Hide is reversible and only suppresses your own sidebar and notifications. It never stops work.")
                    Button("Hide instead") { Task { await action.perform { let _: Bot = try await store.mutate("PATCH", resourcePath("bots", bot.id, "/sidebar"), body: ["revision": .number(Double(bot.revision)), "hidden": .bool(true)]); try await store.refresh(); dismiss() } } }.disabled(bot.required && !owner)
                }
                if ["duplicate", "team-copy", "move"].contains(operation) {
                    SwiftUI.Section("Destination") {
                        if operation != "move" { TextField("New Bot name", text: $name) }
                        Picker("Online machine", selection: $machineID) { Text("Choose machine").tag(""); ForEach(store.machines.filter { $0.status == "online" && (operation != "move" || $0.id != bot.machineId) }) { machine in Text(machine.name).tag(machine.id) } }
                        Toggle("I accept shared host files, browser sessions and CLI credentials", isOn: $sharedHostConsent)
                    }
                }
                switch operation {
                case "duplicate":
                    SwiftUI.Section("Explicit duplicate scope") {
                        Toggle("Include installed skills", isOn: $includeSkills)
                        Toggle("Copy routines as paused", isOn: $includeRoutines)
                        Text("Settings are copied. No memory, chat, attachments, secrets, browser logins or connector tokens are copied.")
                        Button("Create separate duplicate") { Task { await copyBot(team: false) } }.disabled(name.isEmpty || machineID.isEmpty || !sharedHostConsent)
                    }
                case "team-copy":
                    SwiftUI.Section("Select exactly what becomes shared") {
                        Text("The personal Bot stays unchanged. New Team Bot is unpublished. Only declarative connector configuration is copied; no credentials or private transcripts.")
                        ForEach(memory) { item in Toggle("Memory: \(item.text)", isOn: selection(item.id, set: $selectedMemory)) }
                        ForEach(skills.filter { bot.skillIds.contains($0.id) }) { item in Toggle("Skill: \(item.name)", isOn: selection(item.id, set: $selectedSkills)) }
                        ForEach(bot.referenceAttachmentIds, id: \.self) { id in Toggle("Reference file: \(id)", isOn: selection(id, set: $selectedFiles)); AttachmentView(store: store, attachmentID: id) }
                        ForEach(routines) { item in Toggle("Paused routine: \(item.name)", isOn: selection(item.id, set: $selectedRoutines)) }
                        ForEach(connectors) { item in Toggle("Declarative app: \(item.name) · \(item.accountLabel)", isOn: selection(item.id, set: $selectedConnectors)) }
                        Button("Create reviewed unpublished Team copy") { Task { await copyBot(team: true) } }.disabled(name.isEmpty || machineID.isEmpty || !sharedHostConsent)
                    }
                case "move":
                    SwiftUI.Section("Placement cutover") {
                        Text("Move requires idle work and an online destination. Persona, enabled skills and scoped memory are acknowledged before cutover. Product transcript stays; files, browser logins, credentials and terminals do not move automatically.")
                        if !bot.activeRunIds.isEmpty { Text("Active or unconfirmed runs block moving this Bot.").foregroundStyle(.orange) }
                        Button("Preview exact move") { Task { await preview() } }.disabled(machineID.isEmpty || !sharedHostConsent || !bot.activeRunIds.isEmpty)
                    }
                case "reset":
                    SwiftUI.Section("Select scopes to reset") {
                        ForEach(["conversations", "memory", "job", "routines", "connectors", "attachments"], id: \.self) { scope in Toggle(scope.capitalized, isOn: selection(scope, set: $resetScopes)) }
                        Text("Identity, owner, machine and unselected scopes stay. Host files, browser/CLI logins and external provider sessions are not implicitly erased. Preview lists exact deleted and retained IDs.")
                        Button("Preview selected reset") { Task { await preview() } }.disabled(resetScopes.isEmpty)
                    }
                default:
                    SwiftUI.Section("Permanent deletion") {
                        Text("Delete the product Bot and previewed related data. Files, machine OS accounts, browser sessions, backups and independently retained provider authorization remain unless the preview explicitly reports verified removal.")
                        Button("Preview permanent deletion", role: .destructive) { Task { await preview() } }
                    }
                }
                ActionErrorView(message: action.error)
                if let receipt = action.receipt { Text(receipt).font(.caption) }
            }.disabled(action.busy || store.connectionState != "online")
                .navigationTitle("\(bot.name) · lifecycle")
                .toolbar { Button("Close") { dismiss() } }
                .task { if manages { await loadSelectableResources() } }
                .sheet(isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
                    if let confirmation { ScopeConfirmationView(store: store, confirmation: confirmation, title: operation.capitalized + " Bot") { body in try await confirm(body) } }
                }
        }.frame(minWidth: 340, minHeight: 520)
    }
    private func selection(_ id: ID, set: Binding<Set<ID>>) -> Binding<Bool> { Binding(get: { set.wrappedValue.contains(id) }, set: { if $0 { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) } }) }
    private func loadSelectableResources() async {
        await action.perform {
            memory = try await allResources(store, resourcePath("bots", bot.id, "/memory"))
            skills = try await allResources(store, "/skills")
            routines = try await allResources(store, "/routines", query: ["botId": bot.id])
            connectors = try await allResources(store, resourcePath("bots", bot.id, "/connectors"))
        }
    }
    private func copyBot(team: Bool) async {
        await action.perform {
            var body: JSONObject = ["name": .string(name), "machineId": .string(machineID)]
            if team {
                body["memoryIds"] = strings(selectedMemory.sorted()); body["skillIds"] = strings(selectedSkills.sorted()); body["referenceAttachmentIds"] = strings(selectedFiles.sorted()); body["routineIds"] = strings(selectedRoutines.sorted()); body["connectorIds"] = strings(selectedConnectors.sorted())
            } else { body["includeSkills"] = .bool(includeSkills); body["includeRoutines"] = .bool(includeRoutines) }
            let copy: Bot = try await store.mutate("POST", resourcePath("bots", bot.id, team ? "/team-copy" : "/duplicate"), body: body)
            try await store.refresh(); store.selectedConversationID = copy.mainConversationId
            dismiss()
        }
    }
    private func preview() async {
        await action.perform {
            var body: JSONObject = ["action": .string(operation)]
            if operation == "move" { body["targetMachineId"] = .string(machineID) }
            if operation == "reset" { body["resetScopes"] = strings(resetScopes.sorted()) }
            confirmation = try await store.mutate("POST", resourcePath("bots", bot.id, "/preview"), body: body)
        }
    }
    private func confirm(_ confirmed: JSONObject) async throws {
        var body = confirmed
        switch operation {
        case "move": body["machineId"] = .string(machineID); let _: Bot = try await store.mutate("POST", resourcePath("bots", bot.id, "/move"), body: body)
        case "reset":
            body["resetScopes"] = strings(resetScopes.sorted())
            let result: BotResetResult = try await store.mutate("POST", resourcePath("bots", bot.id, "/reset"), body: body)
            action.receipt = "Reset \(result.status) · retained scopes: \(result.retainedScopes.joined(separator: ", "))"
            if result.status == "outcome_unknown" { action.uncertain = true }
        default:
            let _: Deleted = try await store.mutate("DELETE", resourcePath("bots", bot.id), body: body)
            store.selectedConversationID = nil
        }
        try await store.refresh()
        if operation != "reset" { dismiss() }
    }
}
