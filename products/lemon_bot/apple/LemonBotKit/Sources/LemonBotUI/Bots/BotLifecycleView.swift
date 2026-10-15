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
    @State private var resetScopes: Set<String> = []
    @State private var confirmation: Confirmation?
    @State private var action = UIActionState()
    init(store: LemonBotStore, bot: Bot) {
        self.store = store; self.bot = bot
        _operation = State(initialValue: "duplicate")
    }
    private var owner: Bool { bot.ownerUserId == store.user?.id }
    var body: some View {
        NavigationStack {
            Form {
                SwiftUI.Section("Distinct operations") {
                    Picker("Operation", selection: $operation) {
                        if owner { Text("Duplicate").tag("duplicate"); Text("Move machine").tag("move") }
                        if owner { Text("Reset selected scopes").tag("reset") }
                        if owner { Text("Delete Bot").tag("delete") }
                    }
                    Text("Hide is reversible and only suppresses your own sidebar and notifications. It never stops work.")
                    Button("Hide instead") { Task { await action.perform { let _: Bot = try await store.mutate("PATCH", resourcePath("bots", bot.id, "/sidebar"), body: ["revision": .number(Double(bot.revision)), "hidden": .bool(true)]); try await store.refresh(); dismiss() } } }
                }
                if ["duplicate", "move"].contains(operation) {
                    SwiftUI.Section("Destination") {
                        if operation != "move" { TextField("New Bot name", text: $name) }
                        Picker("Online machine", selection: $machineID) { Text("Choose machine").tag(""); ForEach(store.machines.filter { $0.status == "online" && (operation != "move" || $0.id != bot.machineId) }) { machine in Text(machine.name).tag(machine.id) } }
                        if !store.machines.contains(where: { $0.status == "online" && (operation != "move" || $0.id != bot.machineId) }) {
                            Text(operation == "move" ? "No other machine is online to move to." : "No machine is online. Start one of your machines, then come back.").font(LBFont.meta).foregroundStyle(LB.warning)
                        }
                        Toggle("I accept shared host files, browser sessions and CLI credentials", isOn: $sharedHostConsent)
                    }
                }
                switch operation {
                case "duplicate":
                    SwiftUI.Section("Explicit duplicate scope") {
                        Toggle("Include installed skills", isOn: $includeSkills)
                        Toggle("Copy routines as paused", isOn: $includeRoutines)
                        Text("Settings are copied. No memory, chat, attachments, secrets, browser logins or connector tokens are copied.")
                        Button("Create separate duplicate") { Task { await copyBot() } }.disabled(name.isEmpty || machineID.isEmpty || !sharedHostConsent)
                    }
                case "move":
                    SwiftUI.Section("Placement cutover") {
                        Text("Move requires idle work and an online destination. Persona, enabled skills and profile memory are acknowledged before cutover. Product transcript stays; files, browser logins, credentials and terminals do not move automatically.")
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
                .toolbar {
                    Button("Close") { dismiss() }
                    if action.uncertain {
                        Button("Check current state") {
                            Task { await action.perform {
                                let _: Bot = try await store.read(resourcePath("bots", bot.id))
                                try await store.refresh()
                                action.uncertain = false
                                action.receipt = "Current Bot state loaded. Review it before resetting again."
                            } }
                        }.disabled(action.inFlight || store.connectionState != "online")
                    }
                }
                .sheet(isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
                    if let confirmation { ScopeConfirmationView(store: store, confirmation: confirmation, title: operation.capitalized + " Bot") { body in try await confirm(body) } }
                }
        }.frame(minWidth: 340, minHeight: 520)
    }
    private func selection(_ id: ID, set: Binding<Set<ID>>) -> Binding<Bool> { Binding(get: { set.wrappedValue.contains(id) }, set: { if $0 { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) } }) }
    private func copyBot() async {
        await action.perform {
            let body: JSONObject = ["name": .string(name), "machineId": .string(machineID), "includeSkills": .bool(includeSkills), "includeRoutines": .bool(includeRoutines)]
            let copy: Bot = try await store.mutate("POST", resourcePath("bots", bot.id, "/duplicate"), body: body)
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
            action.receipt = result.status == "outcome_unknown" ? "We couldn't confirm the reset finished. Don't retry yet. Check the Bot's current state." : "Reset finished. Kept: \(result.retainedScopes.map { $0 == "connectors" ? "Connected apps" : $0.capitalized }.joined(separator: ", "))."
            if result.status == "outcome_unknown" { action.uncertain = true }
        default:
            let _: Deleted = try await store.mutate("DELETE", resourcePath("bots", bot.id), body: body)
            store.selectedConversationID = nil
        }
        try await store.refresh()
        if operation != "reset" { dismiss() }
    }
}
