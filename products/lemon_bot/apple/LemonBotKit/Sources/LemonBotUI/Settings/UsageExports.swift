import SwiftUI
import LemonBotKit

struct UsageSettingsView: View {
    let store: LemonBotStore
    @State private var control = AdminControl()
    @State private var report: UsageReport?
    @State private var limits: [SpendStatus] = []
    @State private var from = Date().addingTimeInterval(-30 * 86_400)
    @State private var to = Date()
    @State private var grouping = "bot"
    @State private var bot = ""
    @State private var routine = ""
    @State private var scope = "user"
    @State private var subject = ""
    @State private var period = "month"
    @State private var dollars = ""
    @State private var warning = 80
    @State private var providerAccount = ""
    var body: some View {
        Form {
            AdminStatus(control: control, store: store)
            Section("Actual usage") {
                DatePicker("From (inclusive)", selection: $from); DatePicker("To (exclusive)", selection: $to)
                AdminChoice(label: "Group by", value: $grouping, options: ["bot", "routine", "user", "day", "source"])
                AdminBotPicker(store: store, value: $bot)
                TextField("Routine ID filter (optional)", text: $routine)
                Button("Read usage range") { Task { await control.perform { try await loadUsage() } } }
                if let report {
                    Text("Pricing source: \(report.pricingSource ?? "unknown") · \(report.incomplete ? "INCOMPLETE" : "complete measured data")")
                    UsageBucketRow(title: "Total", bucket: report.totals)
                    ForEach(Array(report.buckets.enumerated()), id: \.offset) { _, bucket in UsageBucketRow(title: bucket.key, bucket: bucket) }
                }
                Text("Routines/tests/group targets/handoffs count against the actual initiating principal. Unknown pricing is not zero spend. No Lemon subscription plans; provider billing and account cancellation are external.")
            }
            Section("Ceilings and observed status") {
                ForEach(Array(limits.enumerated()), id: \.offset) { _, status in
                    NavigationLink("\(status.limit.scope) · \(status.limit.subjectId ?? "workspace") · \(status.state)") { SpendLimitSettingsView(store: store, status: status) }
                    Text("Spent \(adminMoney(status.spentUsd)) · remaining \(adminMoney(status.remainingUsd)) · resets \(adminDate(Double(status.resetsAtMs)))")
                }
                Text("Enforced unknown/incomplete prices block NEW work; already admitted runs may finish above the limit. A narrower personal limit cannot bypass a workspace ceiling.")
            }
            Section("Create spend limit") {
                AdminChoice(label: "Scope", value: $scope, options: ["workspace", "user", "bot", "routine"])
                TextField("Subject ID (not used for workspace)", text: $subject)
                AdminChoice(label: "UTC period", value: $period, options: ["day", "week", "month"])
                TextField("Finite nonnegative USD ceiling", text: $dollars)
                Stepper("Warn at \(warning)%", value: $warning, in: 1...99)
                TextField("Configured provider account (optional)", text: $providerAccount)
                AdminAction(title: "Create enforced ceiling", store: store, control: control) {
                    guard let value = Double(dollars), value.isFinite, value >= 0 else { throw AdminFormError("Enter a finite nonnegative USD amount.") }
                    var body: JSONObject = ["scope": .string(scope), "period": .string(period), "limitUsd": .number(value), "warningPercent": .number(Double(warning))]
                    if scope != "workspace" { body["subjectId"] = .string(subject) }
                    if !providerAccount.isEmpty { body["providerAccount"] = .string(providerAccount) }
                    _ = try await store.mutate("POST", "/spend-limits", body: body, as: SpendLimit.self); try await loadLimits()
                }
            }
            Button("Refresh usage and limits") { Task { await control.perform { try await loadUsage(); try await loadLimits() } } }
        }.navigationTitle("Usage and spend").task { subject = store.user?.id ?? ""; await control.perform { try await loadUsage(); try await loadLimits() } }
    }
    private func loadUsage() async throws {
        var query = ["fromAtMs": String(Int(from.timeIntervalSince1970 * 1000)), "toAtMs": String(Int(to.timeIntervalSince1970 * 1000)), "groupBy": grouping]
        if !bot.isEmpty { query["botId"] = bot }; if !routine.isEmpty { query["routineId"] = routine }
        report = try await store.read("/usage", query: query, as: UsageReport.self)
    }
    private func loadLimits() async throws { limits = try await adminReadAll(store, "/spend-limits", as: SpendStatus.self) }
}
func adminMoney(_ value: Double?) -> String { value.map { String(format: "$%.4f", $0) } ?? "unknown" }
struct UsageBucketRow: View {
    let title: String
    let bucket: UsageBucket
    var body: some View {
        VStack(alignment: .leading) {
            Text("\(title) · \(adminMoney(bucket.costUsd))").font(.headline)
            Text("Input \(bucket.inputTokens) · output \(bucket.outputTokens) · requests \(bucket.requests)")
        }
    }
}
struct SpendLimitSettingsView: View {
    let store: LemonBotStore
    let status: SpendStatus
    @State private var control = AdminControl()
    @State private var current: SpendLimit?
    @State private var amount = ""
    @State private var warning = 80
    @State private var enabled = true
    var body: some View {
        Form {
            AdminStatus(control: control, store: store)
            Text("\(status.limit.scope) · \(status.limit.subjectId ?? "workspace") · \(status.limit.period) UTC · provider \(status.limit.providerAccount ?? "all")")
            Text("\(status.state) · measured \(adminMoney(status.spentUsd)) · remaining \(adminMoney(status.remainingUsd)) · resets \(adminDate(Double(status.resetsAtMs)))")
            TextField("USD limit", text: $amount); Stepper("Warning \(warning)%", value: $warning, in: 1...99); Toggle("Enabled", isOn: $enabled)
            AdminAction(title: "Save ceiling", store: store, control: control) {
                guard let value = Double(amount), value.isFinite, value >= 0 else { throw AdminFormError("Enter a finite nonnegative USD amount.") }
                current = try await store.mutate("PATCH", "/spend-limits/\(adminPath(status.limit.id))", body: ["revision": .number(Double((current ?? status.limit).revision)), "limitUsd": .number(value), "warningPercent": .number(Double(warning)), "enabled": .bool(enabled)], as: SpendLimit.self)
            }
            AdminAction(title: "Remove this ceiling", store: store, control: control, destructive: true) {
                _ = try await store.mutate("DELETE", "/spend-limits/\(adminPath(status.limit.id))", body: adminRevision((current ?? status.limit).revision), as: Deleted.self); control.notice = "Ceiling removed; workspace ceilings still apply."
            }
        }.navigationTitle("Spend ceiling").onAppear { amount = String(status.limit.limitUsd); warning = status.limit.warningPercent; enabled = status.limit.enabled }
    }
}

let adminExportStreams = ["audit", "action", "usage", "conversation_content"]
struct ExportSettingsView: View {
    let store: LemonBotStore
    @Environment(\.openURL) private var openURL
    @State private var control = AdminControl()
    @State private var destinations: [ExportDestination] = []
    @State private var records: [ExportRecord] = []
    @State private var conversations: [Conversation] = []
    @State private var name = ""
    @State private var url = ""
    @State private var transport = "ndjson_webhook"
    @State private var secret = ""
    @State private var streams: Set<String> = ["audit"]
    @State private var enabled = false
    @State private var from = Date().addingTimeInterval(-7 * 86_400)
    @State private var to = Date()
    @State private var kind = "audit"
    @State private var selected: Set<String> = []
    @State private var reviewed = false
    @State private var consentConversation = ""
    var body: some View {
        Form {
            AdminStatus(control: control, store: store)
            Section("Own participant content consent") {
                Text("Content consent is off by default. You can only set your own consent, never another participant's. Workspace content export AND every current human participant's explicit consent are required. Revoking stops new and undelivered queued content; already acknowledged collector copies and operator backups cannot be erased by this switch.")
                Picker("Conversation", selection: $consentConversation) { Text("Choose authorized conversation").tag(""); ForEach(conversations) { Text($0.name.isEmpty ? $0.id : $0.name).tag($0.id) } }
                if !consentConversation.isEmpty { ContentConsentSettingsView(store: store, conversationID: consentConversation).id(consentConversation) }
            }
            if store.member?.role == "owner" || store.member?.role == "admin" {
                Section("Delivery destinations") {
                    NavigationLink("Inspect sanitized audit lifecycle metadata") { AuditLogSettingsView(store: store) }
                    Text("Audit, action and usage metadata are separate from content. Enabling starts at the current watermark, no automatic backfill. Collector HTTPS origin and backend secret reference must be operator-approved; known secrets are scrubbed, but residual personal-data risk remains.")
                    ForEach(destinations) { value in NavigationLink("\(value.name) · \(value.protocol) · \(value.enabled ? "enabled" : "disabled")") { ExportDestinationSettingsView(store: store, destination: value) } }
                    TextField("Name", text: $name); TextField("Operator-approved HTTPS collector URL", text: $url)
                    AdminChoice(label: "Protocol", value: $transport, options: ["otlp_http", "ndjson_webhook"])
                    TextField("Server secret reference (not destination Bot secret)", text: $secret)
                    ExportStreamSelection(streams: $streams)
                    Toggle("Enable future deliveries", isOn: $enabled)
                    AdminAction(title: "Create destination", store: store, control: control) {
                        var body: JSONObject = ["name": .string(name), "url": .string(url), "protocol": .string(transport), "streams": adminArray(streams.sorted()), "enabled": .bool(enabled)]
                        if !secret.isEmpty { body["secretRef"] = .string(secret) }
                        _ = try await store.mutate("POST", "/export-destinations", body: body, as: ExportDestination.self); try await load()
                    }
                }
                Section("Explicit historical export") {
                    DatePicker("From", selection: $from); DatePicker("To", selection: $to)
                    AdminChoice(label: "Separate stream", value: $kind, options: adminExportStreams)
                    if kind == "conversation_content" {
                        ForEach(conversations) { conversation in
                            Toggle(conversation.name.isEmpty ? conversation.id : conversation.name, isOn: Binding(get: { selected.contains(conversation.id) }, set: { if $0 { selected.insert(conversation.id) } else { selected.remove(conversation.id) } }))
                        }
                    }
                    Toggle("Reviewed range, selected IDs, content ACL and residual privacy risk", isOn: $reviewed)
                    AdminAction(title: "Create historical export", store: store, control: control) {
                        var body: JSONObject = ["fromAtMs": .number((from.timeIntervalSince1970 * 1000).rounded(.down)), "toAtMs": .number((to.timeIntervalSince1970 * 1000).rounded(.down)), "kind": .string(kind)]
                        if kind == "conversation_content" { body["conversationIds"] = adminArray(selected.sorted()) }
                        _ = try await store.mutate("POST", "/exports", body: body, as: ExportRecord.self); reviewed = false; try await load()
                    }.disabled(!reviewed || (kind == "conversation_content" && selected.isEmpty))
                }
                Section("Authoritative export outcomes") {
                    ForEach(records) { record in
                        Text("\(record.kind) · \(record.state) · \(adminDate(Double(record.fromAtMs))) to \(adminDate(Double(record.toAtMs)))")
                        if let error = record.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                        Text("Last delivered cursor: \(record.lastDeliveredCursor ?? "none")")
                        Button("Refresh this export") { Task { await control.perform {
                            let value = try await store.read("/exports/\(adminPath(record.id))", as: ExportRecord.self)
                            if let index = records.firstIndex(where: { $0.id == value.id }) { records[index] = value }
                        } } }
                        if record.state == "completed", let id = record.attachmentId {
                            Button("Download authorized export") { Task { await control.perform { let url = try await store.download(attachmentID: id); openURL(url) } } }
                        }
                    }
                }
            }
            Button("Refresh destinations and export status") { Task { await control.perform { try await load() } } }
        }.navigationTitle("Exports").task { await control.perform { try await load() } }
    }
    private func load() async throws {
        conversations = try await adminReadAll(store, "/conversations", as: Conversation.self)
        if store.member?.role == "owner" || store.member?.role == "admin" { destinations = try await adminReadAll(store, "/export-destinations", as: ExportDestination.self); records = try await adminReadAll(store, "/exports", as: ExportRecord.self) }
    }
}
struct ExportStreamSelection: View {
    @Binding var streams: Set<String>
    var body: some View {
        ForEach(adminExportStreams, id: \.self) { stream in Toggle(stream.replacingOccurrences(of: "_", with: " "), isOn: Binding(get: { streams.contains(stream) }, set: { if $0 { streams.insert(stream) } else { streams.remove(stream) } })) }
    }
}
struct ExportDestinationSettingsView: View {
    let store: LemonBotStore
    let destination: ExportDestination
    @State private var control = AdminControl()
    @State private var current: ExportDestination?
    @State private var enabled = false
    @State private var streams: Set<String> = []
    var body: some View {
        Form {
            AdminStatus(control: control, store: store)
            Text(destination.url).textSelection(.enabled); Text(destination.protocol)
            Toggle("Enabled for future packets", isOn: $enabled); ExportStreamSelection(streams: $streams)
            AdminAction(title: "Save destination streams", store: store, control: control) {
                current = try await store.mutate("PATCH", "/export-destinations/\(adminPath(destination.id))", body: ["revision": .number(Double((current ?? destination).revision)), "enabled": .bool(enabled), "streams": adminArray(streams.sorted())], as: ExportDestination.self)
            }
            AdminAction(title: "Remove export destination", store: store, control: control, destructive: true) {
                _ = try await store.mutate("DELETE", "/export-destinations/\(adminPath(destination.id))", body: adminRevision((current ?? destination).revision), as: Deleted.self); control.notice = "Destination removed. External acknowledged copies remain."
            }
        }.navigationTitle(destination.name).onAppear { enabled = destination.enabled; streams = Set(destination.streams) }
    }
}
struct ContentConsentSettingsView: View {
    let store: LemonBotStore
    let conversationID: String
    @State private var control = AdminControl()
    @State private var consent: ContentExportConsent?
    @State private var enabled = false
    var body: some View {
        VStack(alignment: .leading) {
            Toggle("I explicitly consent to export my participant content", isOn: $enabled)
            AdminAction(title: "Save own participant consent", store: store, control: control) {
                guard let consent else { return }
                self.consent = try await store.mutate("PUT", "/conversations/\(adminPath(conversationID))/export-consent", body: ["revision": .number(Double(consent.revision)), "enabled": .bool(enabled)], as: ContentExportConsent.self)
            }.disabled(consent == nil)
            if let error = control.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }.task { await control.perform { let value = try await store.read("/conversations/\(adminPath(conversationID))/export-consent", as: ContentExportConsent.self); consent = value; enabled = value.enabled } }
    }
}
