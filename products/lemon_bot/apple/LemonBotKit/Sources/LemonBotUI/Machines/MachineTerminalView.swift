import SwiftUI
import LemonBotKit
import SwiftTerm
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor @Observable final class NativePTYSession {
    let store: LemonBotStore
    var terminal: LemonBotKit.Terminal?
    var error: String?
    var title = "PTY"
    var fedSequence = 0
    var inputFenced = false
    private var pending: Task<Void, Never>?
    init(store: LemonBotStore) { self.store = store }
    func input(_ data: Data) {
        guard store.connectionState == "online", terminal?.state == "open", !inputFenced else { error = "Input not sent: terminal or realtime connection is unavailable."; return }
        let previous = pending
        pending = Task { @MainActor in
            await previous?.value
            guard !inputFenced, store.connectionState == "online", let terminal, terminal.state == "open" else { return }
            do {
                for offset in stride(from: 0, to: data.count, by: 65_536) {
                    guard !inputFenced, store.connectionState == "online" else { throw ClientError.offline }
                    let end = min(offset + 65_536, data.count)
                    let _: HubOK = try await store.mutate("POST", "/terminals/\(hubID(terminal.id))/input", body: ["dataBase64": .string(data.subdata(in: offset..<end).base64EncodedString())])
                }
            } catch { self.error = String(describing: error); inputFenced = true }
        }
    }
    func resize(cols: Int, rows: Int) {
        guard store.connectionState == "online", terminal?.state == "open", !inputFenced else { return }
        let columns = min(500, max(20, cols)), lines = min(300, max(5, rows))
        if terminal?.cols == columns && terminal?.rows == lines { return }
        let previous = pending
        pending = Task { @MainActor in
            await previous?.value
            guard !inputFenced, store.connectionState == "online", let terminal, terminal.state == "open" else { return }
            do { self.terminal = try await store.mutate("POST", "/terminals/\(hubID(terminal.id))/resize", body: ["cols": .number(Double(columns)), "rows": .number(Double(lines))]) }
            catch { self.error = String(describing: error); inputFenced = true }
        }
    }
    func subscribe() async throws {
        guard let terminal else { return }
        self.terminal = try await store.read("/terminals/\(hubID(terminal.id))")
        if self.terminal?.state == "open" { try await store.sendFrame(["type": .string("terminal_subscribe"), "terminalId": .string(terminal.id), "afterSeq": .number(Double(fedSequence))]) }
    }
    func prepareNewShell() async {
        inputFenced = true
        await pending?.value
        pending = nil; terminal = nil; fedSequence = 0; error = nil; title = "PTY"; inputFenced = false
    }
}
public struct MachineTerminalView: View {
    let store: LemonBotStore
    let machineID: ID
    @State private var session: NativePTYSession
    @State private var cwd = ""
    @State private var accepted = false
    @State private var cols = 80
    @State private var rows = 24
    @State private var action = HubAction()
    public init(store: LemonBotStore, machineID: ID) { self.store = store; self.machineID = machineID; _session = State(initialValue: NativePTYSession(store: store)) }
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HubError(action: action)
            if let error = session.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Text("\(session.title) · \(store.connectionState) · device-owned shell").font(.headline)
            if let terminal = session.terminal {
                Text("\(terminal.cwd) · \(terminal.cols)×\(terminal.rows) · \(terminal.state)").font(.caption)
                if store.connectionState != "online" { Text("Disconnected: no input is queued. The same device may reattach within the server's 60-second grace period.").foregroundStyle(.orange) }
                if let gap = store.terminalGaps[terminal.id] { Text("Output gap: retained sequences \(gap.earliestSeq)…\(gap.latestSeq). Earlier output was lost; this is not a complete transcript.").foregroundStyle(.orange) }
                if let exit = store.terminalExitFrames[terminal.id] { Text("Shell exited · code \(exit.code.map(String.init) ?? "not reported"). This does not stop Bot work.") }
                NativeTerminalSurface(session: session, frames: store.terminalFrames[terminal.id] ?? [], gap: store.terminalGaps[terminal.id])
                    .id(terminal.id).frame(minHeight: 300).disabled(terminal.state != "open" || session.inputFenced || store.connectionState != "online" || store.terminalExitFrames[terminal.id] != nil)
                HStack {
                    Button("Reattach / reconcile") { Task { await action.perform(readOnly: true) { try await session.subscribe() } } }
                    Button("Close shell", role: .destructive) { Task { await action.perform {
                        session.inputFenced = true
                        session.terminal = try await store.mutate("DELETE", "/terminals/\(hubID(terminal.id))", body: [:])
                    } } }.disabled(terminal.state != "open" || action.busy || action.uncertain || store.connectionState != "online")
                }
                if terminal.state == "closed" || store.terminalExitFrames[terminal.id] != nil {
                    Button("Review access for a new shell") { Task { await action.perform(readOnly: true) { await session.prepareNewShell(); accepted = false } } }
                }
            } else {
                Text("This opens a real interactive shell with full privileges of the destination OS user. Commands can change shared files, accounts and credentials.")
                TextField("Destination cwd (optional)", text: $cwd)
                Stepper("Columns \(cols)", value: $cols, in: 20...500)
                Stepper("Rows \(rows)", value: $rows, in: 5...300)
                Toggle("I confirm full host access", isOn: $accepted)
                Button("Open interactive PTY") { Task { await action.perform {
                    guard let device = store.deviceID else { throw NativeTerminalError.deviceRequired }
                    var body: JSONObject = ["deviceId": .string(device), "cols": .number(Double(cols)), "rows": .number(Double(rows))]
                    if !cwd.isEmpty { body["cwd"] = .string(cwd) }
                    session.terminal = try await store.mutate("POST", "/machines/\(hubID(machineID))/terminals", body: body)
                    try await session.subscribe()
                } } }.disabled(!accepted || action.busy || action.uncertain || store.connectionState != "online")
            }
        }.padding().navigationTitle("Interactive terminal")
            .onChange(of: store.connectionState) { _, state in if state == "online", session.terminal != nil { Task { await action.perform(readOnly: true) { try await session.subscribe() } } } }
    }
}
private enum NativeTerminalError: LocalizedError { case deviceRequired; var errorDescription: String? { "Register this installation as an owned device before opening a PTY." } }

@MainActor final class NativeTerminalCoordinator: NSObject, TerminalViewDelegate {
    let session: NativePTYSession
    private var fedSequence = 0
    init(session: NativePTYSession) { self.session = session }
    func update(_ view: SwiftTerm.TerminalView, frames: [TerminalOutput], gap: TerminalGap?) {
        if fedSequence == 0, let first = frames.first, first.seq > 1 {
            fedSequence = first.seq - 1
            Task { @MainActor in session.error = "This native view begins at retained sequence \(first.seq); earlier output is not present in its display." }
        }
        for frame in frames where frame.seq > fedSequence {
            if frame.seq != fedSequence + 1 {
                guard let gap, frame.seq >= gap.earliestSeq else {
                    Task { @MainActor in session.error = "Output sequence gap. Reattach to reconcile before trusting the display." }
                    return
                }
            }
            guard let data = Data(base64Encoded: frame.dataBase64) else {
                Task { @MainActor in session.error = "Invalid terminal output encoding." }
                return
            }
            view.feed(byteArray: Array(data)[...]); fedSequence = frame.seq
        }
        let delivered = fedSequence
        if delivered > session.fedSequence { Task { @MainActor in session.fedSequence = max(session.fedSequence, delivered) } }
    }
    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) { session.input(Data(data)) }
    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) { session.resize(cols: newCols, rows: newRows) }
    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) { Task { @MainActor in session.title = String(title.prefix(256)) } }
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) { }
    func scrolled(source: SwiftTerm.TerminalView, position: Double) { }
    func bell(source: SwiftTerm.TerminalView) { }
    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) { Task { @MainActor in session.error = "Remote clipboard request was blocked. Copy selected terminal text explicitly instead." } }
    func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) { }
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) { }
    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}
#if os(macOS)
struct NativeTerminalSurface: NSViewRepresentable {
    let session: NativePTYSession
    let frames: [TerminalOutput]
    let gap: TerminalGap?
    func makeCoordinator() -> NativeTerminalCoordinator { NativeTerminalCoordinator(session: session) }
    func makeNSView(context: Context) -> SwiftTerm.TerminalView {
        let view = SwiftTerm.TerminalView(frame: .zero); view.terminalDelegate = context.coordinator; view.configureNativeColors(); return view
    }
    func updateNSView(_ view: SwiftTerm.TerminalView, context: Context) { context.coordinator.update(view, frames: frames, gap: gap) }
}
#else
struct NativeTerminalSurface: UIViewRepresentable {
    let session: NativePTYSession
    let frames: [TerminalOutput]
    let gap: TerminalGap?
    func makeCoordinator() -> NativeTerminalCoordinator { NativeTerminalCoordinator(session: session) }
    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let view = SwiftTerm.TerminalView(frame: .zero); view.terminalDelegate = context.coordinator; view.configureNativeColors(); return view
    }
    func updateUIView(_ view: SwiftTerm.TerminalView, context: Context) { context.coordinator.update(view, frames: frames, gap: gap) }
}
#endif
