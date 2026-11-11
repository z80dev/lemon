#if os(macOS)
import SwiftUI
import AppKit
import LemonBotKit

struct MacPermissionsView: View {
    let store: LemonBotStore
    let machineID: ID
    let nodeName: String
    let runtimeVersion: String?
    @State private var capabilities: MachineCapabilities?
    @State private var unit = WorkerHost.workerUnit()
    @State private var request: MacPermission?
    @State private var action = HubAction()
    private var canManage: Bool { WorkerHost.canManage(nodeName: nodeName, localNodeName: unit?.nodeName, role: store.member?.role) }

    var body: some View {
        Form {
            HubError(action: action, store: store)
            Section {
                if unit?.wrapped == true {
                    Text("macOS grants these to **Lemon Bot Worker**. Anything your Bots run on this Mac can use them.")
                } else {
                    Text("macOS grants these to “erlexec” inside Lemon \(runtimeVersion ?? "runtime") and forgets them when Lemon updates.")
                    Button("Use Lemon Bot Worker") { Task { await action.perform {
                        try await WorkerHost.useForWorker()
                        unit = WorkerHost.workerUnit()
                        try await refresh()
                    } } }.disabled(!canManage || action.busy || WorkerHost.executableURL() == nil)
                    if WorkerHost.executableURL() == nil { Text(WorkerHost.unavailableReason).foregroundStyle(.secondary) }
                }
                Text("This helper is not a sandbox. Only allow access you want Bots and anything they run to have.")
            }
            permissionRow("See your screen", ids: ["screen_recording"], service: .screenRecording, settings: "Privacy_ScreenCapture")
            permissionRow("Control apps, mouse and keyboard", ids: ["accessibility", "event_synthesizing"], service: .accessibility, settings: "Privacy_Accessibility")
            permissionRow("Full Disk Access", ids: ["full_disk_access"], service: nil, settings: "Privacy_AllFiles")
            Section("Desktop, Documents, Downloads") {
                Text(unit?.wrapped == true ? "macOS asks the first time a Bot opens these folders; the prompt names Lemon Bot Worker." : "macOS asks the first time a Bot opens these folders. Use Lemon Bot Worker above for the helper identity.")
                settingsLink("Privacy_FilesAndFolders")
            }
            Button("Check again") { Task { await measure() } }.disabled(action.busy)
        }
        .formStyle(.grouped).navigationTitle("macOS permissions")
        .task { await measure() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await measure() }
        }
        .sheet(item: $request) { service in
            VStack(alignment: .leading, spacing: 16) {
                Text(service == .screenRecording ? "Allow screen recording?" : "Allow Accessibility?").font(.headline)
                Text(service == .screenRecording ? "This lets Bots see your screen." : "This lets Bots control apps, the mouse and keyboard.")
                Text("Bots and anything they run on this Mac can use this access. Revoke it at any time in System Settings → Privacy & Security → \(service == .screenRecording ? "Screen Recording" : "Accessibility").")
                HStack {
                    Button("Cancel") { request = nil }
                    Button("Allow…") {
                        request = nil
                        Task { await action.perform {
                            guard canManage, unit?.wrapped == true else { return }
                            try await WorkerHost.request(service)
                            try await refresh()
                        } }
                    }.disabled(!canManage || action.busy)
                }
            }.padding(24).frame(width: 440)
        }
    }

    private func permissionRow(_ title: String, ids: [String], service: MacPermission?, settings: String) -> some View {
        let items = ids.compactMap { id in capabilities?.items.first { $0.id == id } }
        let grants = ids.map { id in items.first { $0.id == id }?.osGrant ?? "unknown" }
        let state = MacPermissionState.measure(grants: grants, stale: capabilities?.stale == true)
        return Section(title) {
            Text(state.rawValue)
            if items.contains(where: { $0.reason == "peekaboo_not_installed" }) {
                Text("Desktop control also needs Peekaboo on this Mac.")
            }
            if let service, state != .allowed {
                Button("Allow…") { request = service }
                    .disabled(!canManage || unit?.wrapped != true || WorkerHost.appURL() == nil || action.busy)
            }
            if service == nil { Text("Full Disk Access can only be changed in System Settings. It permits access to protected files; anything your Bots run can use it.") }
            settingsLink(settings)
        }
    }

    private func settingsLink(_ anchor: String) -> some View {
        Link("Open System Settings", destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
    private func refresh() async throws {
        unit = WorkerHost.workerUnit()
        capabilities = try await store.read("/machines/\(hubID(machineID))/capabilities")
    }
    private func measure() async { await action.perform(readOnly: true) { try await refresh() } }
}
#endif
