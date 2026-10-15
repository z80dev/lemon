import SwiftUI
import LemonBotKit

struct InspectorDetailsTab: View {
    let store: LemonBotStore
    let bot: Bot
    let overview: BotOverview?
    let skills: [Skill]
    let manages: Bool
    let open: (InspectorDestination) -> Void
    @State private var action = UIActionState()
    @State private var grantsOpen = false

    private var botSkills: [String] { skills.filter { bot.skillIds.contains($0.id) }.map(\.name) }
    private var machine: Machine? { store.machine(for: bot) ?? overview?.machine }
    private var persona: String {
        [bot.job, bot.instructions].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    private var voice: String {
        let language = bot.language.flatMap { $0.isEmpty ? nil : $0 } ?? "automatic language"
        return "\(bot.voice.voiceId) · \(language)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            InspectorSection(title: "Job and instructions") {
                SoftCard {
                    Text(persona.isEmpty ? "No job set yet." : persona).font(LBFont.rowSubtitle)
                        .foregroundStyle(persona.isEmpty ? LB.faint : LB.ink).lineLimit(6)
                    if manages { Button("Edit") { open(.job) }.buttonStyle(.pill(.secondary, compact: true)) }
                }
            }
            InspectorSection(title: "Setup") {
                VStack(spacing: 4) {
                    InspectorRow(symbol: "sparkles", title: "Skills", meta: botSkills.isEmpty ? "None enabled" : botSkills.joined(separator: ", "), chevron: false)
                    InspectorRow(symbol: "cpu", title: "Model profile", meta: bot.profileId, chevron: false)
                    InspectorRow(symbol: "desktopcomputer", title: "Machine", meta: machine?.name ?? "Unknown machine") { open(.machine(bot.machineId)) }
                    InspectorRow(symbol: "waveform", title: "Voice and language", meta: voice, chevron: false)
                    notificationsRow
                }
            }
            if let overview, !overview.grants.isEmpty {
                DisclosureGroup(isExpanded: $grantsOpen) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Effective access is bounded by host configuration, measured OS grants and required policy. A requested level is not proof of authorization.")
                            .font(LBFont.meta).foregroundStyle(LB.muted)
                        ForEach(overview.grants) { BotGrantRow(store: store, grant: $0, manages: manages) }
                    }.padding(.top, 6)
                } label: { Text("Bot authorization").font(LBFont.rowTitle).foregroundStyle(LB.ink) }
                    .padding(12).background(RoundedRectangle(cornerRadius: LBMetric.rowRadius, style: .continuous).fill(LB.bubble))
            }
            InspectorSection(title: "More") {
                VStack(spacing: 4) {
                    InspectorRow(symbol: "clock.arrow.circlepath", title: "Preferences history", meta: "Durable changes to this Bot") { open(.overview) }
                    InspectorRow(symbol: "lightbulb", title: "Ideas", meta: "Useful outcomes to try") { open(.overview) }
                    InspectorRow(symbol: "puzzlepiece.extension", title: "Connected apps") { open(.apps) }
                }
            }
            if manages {
                InspectorSection(title: "Manage") {
                    VStack(spacing: 4) {
                        InspectorRow(symbol: "person.crop.circle", title: "Edit identity") { open(.editor) }
                        Button { open(.lifecycle) } label: {
                            Text("Duplicate, move, reset or delete…").font(LBFont.meta).foregroundStyle(LB.muted)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.top, 8)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var notificationsRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell").font(.system(size: 14, weight: .medium)).foregroundStyle(LB.muted).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("Notifications").font(LBFont.rowTitle).foregroundStyle(LB.ink)
                if let error = action.error { Text(error).font(LBFont.meta).foregroundStyle(LB.danger).lineLimit(2) }
            }
            Spacer()
            Toggle("Notifications", isOn: Binding(get: { bot.sidebar.notificationsEnabled }, set: { value in Task { await setNotifications(value) } }))
                .labelsHidden().toggleStyle(.switch).disabled(action.busy || !store.isOnline)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: LBMetric.rowRadius, style: .continuous).fill(LB.bubble))
    }

    private func setNotifications(_ value: Bool) async {
        await action.perform {
            let _: Bot = try await store.mutate("PATCH", resourcePath("bots", bot.id, "/sidebar"), body: ["revision": .number(Double(bot.revision)), "notificationsEnabled": .bool(value)])
            try await store.refresh()
        }
    }
}
