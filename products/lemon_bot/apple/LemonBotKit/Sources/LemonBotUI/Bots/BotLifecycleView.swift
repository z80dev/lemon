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
    private var cannotSubmit: Bool {
        if action.busy || !store.isOnline { return true }
        switch operation {
        case "duplicate": return name.isEmpty || machineID.isEmpty || !sharedHostConsent
        case "move": return machineID.isEmpty || !sharedHostConsent || !bot.activeRunIds.isEmpty
        case "reset": return resetScopes.isEmpty
        default: return false
        }
    }
    var body: some View {
        NavigationStack {
            Form {
                SwiftUI.Section("What would you like to do?") {
                    Picker("Operation", selection: $operation) {
                        if owner { Text("Duplicate").tag("duplicate"); Text("Move machine").tag("move") }
                        if owner { Text("Reset selected scopes").tag("reset") }
                        if owner { Text("Delete Bot").tag("delete") }
                    }
                }
                SwiftUI.Section("Hide from my sidebar") {
                    Text("Hiding only affects your sidebar and notifications. Work keeps running.")
                    Button("Hide Bot") { Task { await action.perform { let _: Bot = try await store.mutate("PATCH", resourcePath("bots", bot.id, "/sidebar"), body: ["revision": .number(Double(bot.revision)), "hidden": .bool(true)]); try await store.refresh(); dismiss() } } }
                }
                if ["duplicate", "move"].contains(operation) {
                    SwiftUI.Section("Destination") {
                        if operation != "move" { TextField("New Bot name", text: $name) }
                        Picker("Online machine", selection: $machineID) { Text("Choose machine").tag(""); ForEach(store.machines.filter { $0.status == "online" && (operation != "move" || $0.id != bot.machineId) }) { machine in Text(machine.name).tag(machine.id) } }
                        if !store.machines.contains(where: { $0.status == "online" && (operation != "move" || $0.id != bot.machineId) }) {
                            Text(operation == "move" ? "No other machine is online to move to." : "No machine is online. Start one of your machines, then come back.").font(LBFont.meta).foregroundStyle(LB.warning)
                        }
                        Toggle("I understand Bots on this computer user share files and logins", isOn: $sharedHostConsent)
                    }
                }
                switch operation {
                case "duplicate":
                    SwiftUI.Section("What to copy") {
                        Toggle("Include installed skills", isOn: $includeSkills)
                        Toggle("Copy routines as paused", isOn: $includeRoutines)
                        Text("Settings are copied. No memory, chat, attachments, secrets, browser logins or connector tokens are copied.")
                    }
                case "move":
                    SwiftUI.Section("Move to another machine") {
                        Text("The Bot must be idle and its new machine online. Review what the preview will carry over before confirming. Chat history stays. Files, browser logins, credentials and terminals don't move automatically.")
                        if !bot.activeRunIds.isEmpty { Text("Active or unconfirmed runs block moving this Bot.").foregroundStyle(LB.warning) }
                    }
                case "reset":
                    SwiftUI.Section("Choose what to reset") {
                        ForEach(["conversations", "memory", "job", "routines", "connectors", "attachments"], id: \.self) { scope in Toggle(scope == "connectors" ? "Connected apps" : scope.capitalized, isOn: selection(scope, set: $resetScopes)) }
                        Text("The Bot's identity, owner and machine stay, along with anything you don't select. Machine files and outside logins aren't deleted unless the preview says so.")
                    }
                default:
                    SwiftUI.Section("Permanent deletion") {
                        Text("Deleting removes this Bot and the data listed in the preview. Files on the machine, OS accounts, browser logins, backups and provider logins aren't deleted unless the preview says they are.")
                    }
                }
                ActionErrorView(message: action.error)
                if let receipt = action.receipt { Text(receipt).font(LBFont.meta) }
            }.formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(LB.canvas)
                .disabled(action.busy || !store.isOnline)
                .navigationTitle("\(bot.name) · Manage Bot")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }.buttonStyle(.pill(.secondary, compact: true)).keyboardShortcut(.cancelAction)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if owner {
                            Button(operation == "duplicate" ? "Duplicate Bot" : "Review \(operation)", role: operation == "delete" ? .destructive : nil) {
                                Task { if operation == "duplicate" { await copyBot() } else { await preview() } }
                            }.buttonStyle(.pill(operation == "delete" ? .destructive : .primary(LB.lemon, LB.lemonInk), compact: true))
                                .keyboardShortcut(.defaultAction).disabled(cannotSubmit)
                        }
                    }
                    ToolbarItem(placement: .automatic) {
                        if action.uncertain {
                            Button("Check current state") {
                                Task { await action.perform {
                                    let _: Bot = try await store.read(resourcePath("bots", bot.id))
                                    try await store.refresh()
                                    action.uncertain = false
                                    action.receipt = "Current Bot state loaded. Review it before resetting again."
                                } }
                            }.disabled(action.inFlight || !store.isOnline)
                        }
                    }
                }
                .sheet(isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
                    if let confirmation { ScopeConfirmationView(store: store, confirmation: confirmation, title: operation.capitalized + " Bot") { body in try await confirm(body) } }
                }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 600)
        #else
        .frame(minWidth: 320, minHeight: 520)
        #endif
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
