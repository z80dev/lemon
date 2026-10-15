import SwiftUI
import LemonBotKit

struct RoutineLibraryView: View {
    let store: LemonBotStore
    @State private var routines: [Routine] = []
    @State private var cursor: String?
    @State private var botID = ""
    @State private var enabledFilter = "all"
    @State private var creating = false
    @State private var action = HubAction()
    var body: some View {
        List {
            HubError(action: action, store: store)
            HubBotPicker(store: store, selection: $botID).onChange(of: botID) { Task { await load() } }
            Picker("State", selection: $enabledFilter) { Text("All").tag("all"); Text("Active").tag("true"); Text("Paused").tag("false") }.onChange(of: enabledFilter) { Task { await load() } }
            ForEach(routines) { routine in NavigationLink { RoutineEditorView(store: store, initial: routine) } label: {
                VStack(alignment: .leading) {
                    Text(routine.name).font(.headline)
                    Text("\(routine.enabled ? "Active" : "Paused") · \(routine.scheduleDescription)")
                    Text("Next: \(hubDate(routine.nextRunAtMs)) · Bot \(routine.botId)").font(LBFont.meta)
                }
            } }
            if cursor != nil { Button("More routines") { Task { await load(more: true) } } }
        }.navigationTitle("Routines").toolbar { Button("New routine") { creating = true }; Button("Refresh") { Task { await load() } } }
            .sheet(isPresented: $creating) { NavigationStack { RoutineEditorView(store: store, initial: nil) } }.task { await load() }
    }
    private func load(more: Bool = false) async { await action.perform(readOnly: true) {
        var query: [String: String] = [:]; if !botID.isEmpty { query["botId"] = botID }; if enabledFilter != "all" { query["enabled"] = enabledFilter }; if more, let cursor { query["cursor"] = cursor }
        let page: HubPage<Routine> = try await store.read("/routines", query: query); routines = hubMerged(routines, page.items, append: more, id: \.id); cursor = page.nextCursor
    } }
}
struct RoutineEditorView: View {
    let store: LemonBotStore
    let initial: Routine?
    @Environment(\.dismiss) private var dismiss
    @State private var saved: Routine?
    @State private var botID = ""
    @State private var name = ""
    @State private var instruction = ""
    @State private var enabled = true
    @State private var triggerKind = "schedule"
    @State private var cron = "0 9 * * 1-5"
    @State private var timezone = TimeZone.current.identifier
    @State private var channelID = ""
    @State private var channelEvent = "mention"
    @State private var channel = ""
    @State private var phrase = ""
    @State private var reaction = ""
    @State private var senders = ""
    @State private var noisyConsent = false
    @State private var source = ""
    @State private var selectedEventNames: Set<String> = []
    @State private var filters: JSONObject = [:]
    @State private var sources: [ExternalSource] = []
    @State private var definition: ExternalSourceDefinition?
    @State private var channels: [ChannelBinding] = []
    @State private var providerError: String?
    @State private var runs: [RoutineRun] = []
    @State private var runCursor: String?
    @State private var preview: HubConfirmation?
    @State private var webhookKey: WebhookKey?
    @State private var keyPresented = false
    @State private var testPresented = false
    @State private var rotatePresented = false
    @State private var revokePresented = false
    @State private var action = HubAction()
    var body: some View {
        observedEditorForm
            .confirmationDialog("A test performs real work on the assigned host and consumes usage. Continue?", isPresented: $testPresented) {
                Button("Run real test") { Task { await testSavedRoutine() } }
                    .disabled(action.busy || action.uncertain || store.connectionState != "online")
            }
            .confirmationDialog("Rotate the key? The prior key immediately stops working.", isPresented: $rotatePresented) {
                Button("Issue / rotate") { Task { await rotateWebhookKey() } }
                    .disabled(action.busy || action.uncertain || store.connectionState != "online")
            }
            .confirmationDialog("Revoke webhook key and future ingress? Existing runs remain.", isPresented: $revokePresented) {
                Button("Revoke key", role: .destructive) { Task { await revokeWebhookKey() } }
                    .disabled(action.busy || action.uncertain || store.connectionState != "online")
            }
    }

    private var observedEditorForm: some View {
        editorForm
            .navigationTitle(saved?.name ?? "New routine")
            .toolbar {
                Button("Close") { dismiss() }
                Button("Refresh history") { Task { await action.perform(readOnly: true) { try await loadRuns() } } }
            }
            .task { apply(initial); await loadProviders() }
            .task(id: saved?.id) { await observeRunHistory() }
            .onChange(of: source) { Task { await loadDefinition() } }
            .onChange(of: botID) { noisyConsent = false }
            .onChange(of: channelID) { noisyConsent = false }
            .onChange(of: channelEvent) { noisyConsent = false }
            .onChange(of: channel) { noisyConsent = false }
            .onChange(of: phrase) { noisyConsent = false }
            .onChange(of: enabled) { noisyConsent = false }
            .onChange(of: triggerKind) { noisyConsent = false }
            .sheet(isPresented: $keyPresented, onDismiss: { webhookKey = nil }) { webhookKeyReview }
    }

    private var editorForm: some View {
        Form {
            HubError(action: action, store: store)
            ActionErrorView(message: providerError)
            routineIdentityFields
            triggerFields
            Button("Save routine") { Task { await saveRoutine() } }
                .disabled(botID.isEmpty || name.isEmpty || instruction.isEmpty || action.busy || action.uncertain || store.connectionState != "online")
            savedRoutineFields
        }
    }

    @ViewBuilder private var routineIdentityFields: some View {
        if saved == nil { HubBotPicker(store: store, selection: $botID) }
        else { Text("Bot: \(botID)") }
        TextField("Routine name", text: $name)
        TextEditor(text: $instruction).frame(minHeight: 160)
        Toggle("Enabled (future triggers only)", isOn: $enabled)
        Text("Creation does not execute work. Pausing blocks future triggers, not active runs. Schedules use the destination Lemon scheduler; next run is the server-returned instant. Tests are real work and consume usage.")
        Picker("Trigger", selection: $triggerKind) {
            Text("Schedule").tag("schedule")
            Text("Channel / email event").tag("channel_event")
            Text("External event").tag("external_event")
            Text("Webhook").tag("webhook")
        }
    }

    @ViewBuilder private var webhookKeyReview: some View {
        if let key = webhookKey {
            NavigationStack {
                Form {
                    Text("Shown once. Keep this key out of chat, logs and URLs.")
                    Text(key.url).textSelection(.enabled)
                    SecureField("One-time key", text: .constant(key.key))
                    Text(key.header).textSelection(.enabled)
                    Button("Copy key") { hubCopy(key.key) }
                    Button("Copy exact header") { hubCopy(key.header) }
                    Button("Copy POST URL") { hubCopy(key.url) }
                }
                .navigationTitle("Webhook key")
                .toolbar { Button("Done / erase local buffer") { webhookKey = nil; keyPresented = false } }
            }
        }
    }

    private func observeRunHistory() async {
        guard saved != nil else { return }
        while !Task.isCancelled {
            await action.poll { try await loadRuns() }
            do { try await Task.sleep(for: .seconds(5)) } catch { break }
        }
    }

    private func saveRoutine() async {
        await action.perform {
            var body: JSONObject = ["name": .string(name), "instruction": .string(instruction), "enabled": .bool(enabled)]
            if !pausingExistingBroadScope { body["trigger"] = .object(try triggerBody()) }
            if let saved {
                body["revision"] = .number(Double(saved.revision))
                self.saved = try await store.mutate("PATCH", "/routines/\(hubID(saved.id))", body: body)
            } else {
                body["botId"] = .string(botID)
                self.saved = try await store.mutate("POST", "/routines", body: body)
            }
        }
    }

    private func testSavedRoutine() async {
        guard let saved else { return }
        await action.perform {
            let run: RoutineRun = try await store.mutate("POST", "/routines/\(hubID(saved.id))/test", body: [:])
            runs.insert(run, at: 0)
            if run.status == "outcome_unknown" {
                action.uncertain = true
                action.uncertainResourceID = run.id
                action.error = "We couldn't confirm whether this ran. Check its result below before trying again."
            }
        }
    }

    private func rotateWebhookKey() async {
        guard let saved else { return }
        await action.perform {
            webhookKey = try await store.mutate("POST", "/routines/\(hubID(saved.id))/webhook-key", body: [:])
            keyPresented = true
        }
    }

    private func revokeWebhookKey() async {
        guard let saved else { return }
        await action.perform {
            let _: HubOK = try await store.mutate("DELETE", "/routines/\(hubID(saved.id))/webhook-key", body: [:])
            webhookKey = nil
        }
    }
    @ViewBuilder private var savedRoutineFields: some View {
        if let saved {
            Section("Actual schedule and control") {
                Text(saved.scheduleDescription)
                Text("Next: \(hubDate(saved.nextRunAtMs)) · \(saved.enabled ? "Active" : "Paused")")
                Button("Edit with Bot (draft only)") { Task { await action.perform {
                    let bot: Bot = try await store.read("/bots/\(hubID(saved.botId))")
                    store.setLocalDraft(conversationID: bot.mainConversationId, text: "Help me edit routine \(saved.name) (\(saved.id)). Current instruction: \(saved.instruction)", attachmentIDs: [], replyTo: nil)
                    try await store.openConversation(bot.mainConversationId)
                } } }
                Button("Test as real work") { testPresented = true }.disabled(action.busy || action.uncertain || store.connectionState != "online")
                Button("Preview permanent deletion", role: .destructive) { Task { await action.perform { preview = try await store.mutate("POST", "/routines/\(hubID(saved.id))/preview", body: ["action": .string("delete")]) } } }.disabled(action.busy || action.uncertain || store.connectionState != "online")
            }
            if let preview { HubConfirmationForm(store: store, preview: preview, action: action) { name in await action.perform {
                let _: HubDeleted = try await store.mutate("DELETE", "/routines/\(hubID(saved.id))", body: preview.body(name: name)); dismiss()
            } } }
            if saved.webhookUrl != nil {
                Section("Authenticated webhook") {
                    Text(saved.webhookUrl ?? "").textSelection(.enabled)
                    Text("Send a POST with a JSON body containing a unique clientNonce (a new value for every request) and an optional payload. Send your key as Authorization: Bearer <key>. A started response means the routine began, not that it finished. Creating a new key disables the old one. Paused routines don't accept requests.")
                    Button("Create a new webhook key") { rotatePresented = true }
                    Button("Turn off webhook", role: .destructive) { revokePresented = true }
                }
            }
            runHistoryFields
        }
    }

    private var runHistoryFields: some View {
        Section("Actual run history / usage") {
            ForEach(runs) { run in routineRunRow(run) }
            if runCursor != nil { Button("Older runs") { Task { await action.perform(readOnly: true) { try await loadRuns(more: true) } } } }
        }
    }

    private func routineRunRow(_ run: RoutineRun) -> some View {
        VStack(alignment: .leading) {
            Text("\(humanizedStatus(run.trigger)) · \(hubStatusLabel(run.status))").font(LBFont.rowTitle)
            Text("\(hubDate(run.startedAtMs)) · cost \(run.costUsd.map { String(format: "$%.4f", $0) } ?? "unknown")")
            if let error = run.error { Text(error).foregroundStyle(LB.danger) }
            Button("Open result") { Task { await action.perform(readOnly: true) { try await store.openConversation(run.conversationId) } } }
            Button("Check status") { Task { await action.perform(readOnly: true) { let current: RoutineRun = try await store.read("/routine-runs/\(hubID(run.id))"); if let index = runs.firstIndex(where: { $0.id == current.id }) { runs[index] = current }; if action.uncertainResourceID == current.id, ["completed", "succeeded", "failed", "cancelled"].contains(current.status) { action.uncertain = false; action.uncertainResourceID = nil; action.error = nil } } } }
            if ["reserved", "queued", "running", "awaiting_input"].contains(run.status) {
                Button("Request cancellation", role: .destructive) { Task { await action.perform {
                    let current: RoutineRun = try await store.mutate("POST", "/routine-runs/\(hubID(run.id))/cancel", body: [:]); if let index = runs.firstIndex(where: { $0.id == current.id }) { runs[index] = current }
                } } }.disabled(action.busy || action.uncertain || store.connectionState != "online")
            }
        }
    }

    @ViewBuilder private var triggerFields: some View {
        switch triggerKind {
        case "schedule":
            TextField("Five-field cron (minimum cadence five minutes)", text: $cron)
            Picker("IANA timezone", selection: $timezone) { ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) } }
        case "channel_event":
            Picker("Actual binding", selection: $channelID) { Text("Select binding").tag(""); ForEach(channels) { Text("\($0.adapter) · \($0.accountId) · \($0.target) · \($0.state)").tag($0.id) } }
            Picker("Supported event", selection: $channelEvent) {
                ForEach(channels.first(where: { $0.id == channelID })?.capabilities.events.filter { ["mention", "message", "reaction", "email_received"].contains($0) } ?? [], id: \.self) { Text($0).tag($0) }
            }
            if channelEvent == "email_received" { TextField("Allowed sender emails / domains (comma separated)", text: $senders); Text("Mail alone never wakes the Bot. No subject filter is claimed.") }
            else { TextField("Channel filter (optional)", text: $channel); TextField("Phrase filter (optional)", text: $phrase); if channelEvent == "reaction" { TextField("Exact reaction", text: $reaction) } }
            if let error = channels.first(where: { $0.id == channelID })?.lastError { Text(error).foregroundStyle(LB.danger).textSelection(.enabled) }
            if channelEvent == "message", phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Every new message in this exact scope may start work and consume usage. A channel-only limit remains broad. This opt-in is not action approval and never carries over from a template or copy.").foregroundStyle(LB.warning)
                Text("Bot \(botID) · binding \(channelID) · channel \(channel.isEmpty ? "all authorized binding channels" : channel)")
                Toggle("I explicitly authorize this broad listener for the scope shown", isOn: $noisyConsent)
            }
        case "external_event":
            Picker("Registered source", selection: Binding(get: { source }, set: { source = $0; selectedEventNames = []; filters = [:]; definition = nil })) { Text("Select source").tag(""); ForEach(sources, id: \.source) { Text("\($0.source) · \($0.configured ? "Configured" : "Unconfigured")").tag($0.source) } }
            if let definition {
                Text(definition.configured ? "Configured verified ingress" : "Operator must configure verified ingress for this registered source.")
                ForEach(definition.events, id: \.name) { event in
                    Toggle(event.label, isOn: Binding(get: { selectedEventNames.contains(event.name) }, set: { if $0 { selectedEventNames.insert(event.name) } else { selectedEventNames.remove(event.name) } }))
                    if selectedEventNames.contains(event.name) {
                        DisclosureGroup("Registered filters for \(event.label)") { Text(event.description); RoutineSchemaFields(schema: event.filterSchema, values: $filters) }
                    }
                }
                Text("Filters must satisfy every selected event's registered schema. If schemas differ, explicitly select a compatible subset; existing events are never silently removed.")
                let unavailable = selectedEventNames.subtracting(Set(definition.events.map(\.name)))
                if !unavailable.isEmpty { Text("Previously selected events no longer advertised: \(unavailable.sorted().joined(separator: ", ")). Remove them explicitly before changing this trigger.").foregroundStyle(LB.warning) }
                ForEach(unavailable.sorted(), id: \.self) { name in Button("Explicitly remove unavailable event \(name)", role: .destructive) { selectedEventNames.remove(name) } }
            }
        default: Text("Webhook receives authenticated bounded JSON, with one-time key issuance after save. No event backfill or implicit authorization.")
        }
    }
    private func apply(_ routine: Routine?) {
        guard let routine else { return }; saved = routine; botID = routine.botId; name = routine.name; instruction = routine.instruction; enabled = routine.enabled
        switch routine.trigger {
        case .schedule(let value): triggerKind = "schedule"; cron = value.cron; timezone = value.timezone
        case .webhook: triggerKind = "webhook"
        case .channelEvent(let value): triggerKind = "channel_event"; channelID = value.channelBindingId; channelEvent = value.event; channel = value.channel ?? ""; phrase = value.phrase ?? ""; reaction = value.reaction ?? ""; senders = value.senders?.joined(separator: ",") ?? ""
        case .externalEvent(let value): triggerKind = "external_event"; source = value.source; selectedEventNames = Set(value.eventNames); filters = value.filters
        }
    }
    private var pausingExistingBroadScope: Bool {
        guard !enabled, triggerKind == "channel_event", channelEvent == "message",
              let saved, case .channelEvent(let original) = saved.trigger else { return false }
        return original.event == "message" && original.channelBindingId == channelID &&
            (original.channel ?? "") == channel &&
            (original.phrase ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private func triggerBody() throws -> JSONObject {
        switch triggerKind {
        case "schedule": return ["kind": .string("schedule"), "cron": .string(cron), "timezone": .string(timezone)]
        case "webhook": return ["kind": .string("webhook")]
        case "channel_event":
            guard let binding = channels.first(where: { $0.id == channelID }), binding.capabilities.events.contains(channelEvent), binding.capabilities.inbound else { throw RoutineFormError.invalid("Choose an authorized binding and one of its advertised inbound events.") }
            var trigger: JSONObject = ["kind": .string("channel_event"), "channelBindingId": .string(channelID), "event": .string(channelEvent)]
            if channelEvent == "email_received" { trigger["senders"] = .array(senders.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces)) }) }
            else { if !channel.isEmpty { trigger["channel"] = .string(channel) }; if !phrase.isEmpty { trigger["phrase"] = .string(phrase) }; if !reaction.isEmpty { trigger["reaction"] = .string(reaction) } }
            if channelEvent == "message", phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard noisyConsent else { throw RoutineFormError.invalid("Explicit human opt-in is required: every new message in the exact Bot/binding/channel scope may start work and consume usage. You can pause the existing unchanged scope without renewing permission.") }
                trigger["noisyListenerConsent"] = .bool(true)
            }
            return trigger
        default:
            guard let definition, definition.configured, !selectedEventNames.isEmpty else { throw RoutineFormError.invalid("Select an actual configured source and registered supported events.") }
            let events = definition.events.filter { selectedEventNames.contains($0.name) }
            guard events.count == selectedEventNames.count else { throw RoutineFormError.invalid("A selected event is no longer registered. Review and explicitly remove unavailable events before saving.") }
            for event in events { try RoutineSchemaFields.validate(filters, schema: event.filterSchema) }
            return ["kind": .string("external_event"), "source": .string(source), "eventNames": .array(selectedEventNames.sorted().map(JSONValue.string)), "filters": .object(filters)]
        }
    }
    private func loadProviders() async {
        do {
            sources = try await store.read("/event-sources")
            var pageCursor: String?; var bindings: [ChannelBinding] = []
            repeat { let page: HubPage<ChannelBinding> = try await store.read("/channels", query: pageCursor.map { ["cursor": $0] } ?? [:]); bindings = hubMerged(bindings, page.items, append: true, id: \.id); pageCursor = page.nextCursor } while pageCursor != nil
            channels = bindings; providerError = nil
            if !source.isEmpty { await loadDefinition() }
        } catch { providerError = humanErrorText(error) }
    }
    private func loadDefinition() async {
        guard !source.isEmpty else { definition = nil; return }
        let requestedSource = source
        do {
            let value: ExternalSourceDefinition = try await store.read("/event-sources/\(hubID(requestedSource))")
            guard source == requestedSource else { return }
            definition = value; providerError = nil
        } catch { if source == requestedSource { definition = nil; providerError = error.localizedDescription } }
    }
    private func loadRuns(more: Bool = false) async throws {
        guard let saved else { return }
        let page: HubPage<RoutineRun> = try await store.read("/routines/\(hubID(saved.id))/runs", query: more ? ["cursor": runCursor ?? ""] : [:]); runs = hubMerged(runs, page.items, append: more, id: \.id); runCursor = page.nextCursor
    }
}
enum RoutineFormError: LocalizedError { case invalid(String); var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil } }
