import SwiftUI
import Foundation
import LemonBotKit

struct AuditLogSettingsView: View {
    let store: LemonBotStore
    @State private var control = AdminControl()
    @State private var records: [AuditRecord] = []
    @State private var actor = ""
    @State private var resource = ""
    @State private var from = Date().addingTimeInterval(-7 * 86_400)
    @State private var to = Date()
    var body: some View {
        Form {
            AdminStatus(control: control, store: store)
            Section("Sanitized management metadata — not private transcripts") {
                TextField("Actor ID (optional)", text: $actor); TextField("Resource ID (optional)", text: $resource)
                DatePicker("From", selection: $from); DatePicker("To", selection: $to)
                Button("Read audit range") { Task { await control.perform { try await load() } } }
            }
            Section("Recorded actual outcomes") {
                ForEach(records) { record in
                    VStack(alignment: .leading) {
                        Text("\(record.action) · \(record.outcome)").font(.headline)
                        Text("\(record.actor.displayName) · \(record.actor.kind) · \(record.resourceType) \(record.resourceId)")
                        Text("\(adminDate(Double(record.createdAtMs))) · request \(record.requestId)").textSelection(.enabled)
                    }
                }
            }
        }.navigationTitle("Audit metadata").task { await control.perform { try await load() } }
    }
    private func load() async throws {
        var query = ["fromAtMs": String(Int(from.timeIntervalSince1970 * 1000)), "toAtMs": String(Int(to.timeIntervalSince1970 * 1000))]
        if !actor.isEmpty { query["actorId"] = actor }; if !resource.isEmpty { query["resourceId"] = resource }
        records = try await adminReadAll(store, "/audit", query: query, as: AuditRecord.self)
    }
}
