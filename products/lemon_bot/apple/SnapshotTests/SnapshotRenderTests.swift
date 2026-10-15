#if DEBUG
import AppKit
import SwiftUI
import XCTest
import LemonBotKit
@testable import LemonBotUI

/// Renders the REAL macOS views over the fixture workspace to PNGs (light + dark) for design review.
/// Output: `$LB_SNAPSHOT_DIR` (default `/tmp/lb-ux/after`) as `apple-<scene-kebab>-<light|dark>.png`.
/// Pass env through xcodebuild as `TEST_RUNNER_LB_SNAPSHOT_SCENES=failed-run,settings` (comma-separated slugs) to render a subset.
@MainActor
final class SnapshotRenderTests: XCTestCase {
    private let scale: CGFloat = 2

    func testDisconnectedBadgeIsNotConnectedGreen() {
        if case .bad = StatusTone("disconnected") {} else { XCTFail("Disconnected must render as a failure") }
        if case .bad = StatusTone("Last known: disconnected") {} else { XCTFail("Prefixed disconnected must render as a failure") }
        if case .good = StatusTone("connected") {} else { XCTFail("Connected must keep its successful tone") }
    }
    func testInstanceUptimeUsesHumanUnits() {
        XCTAssertEqual(instanceUptime(12_000), "12s")
        XCTAssertEqual(instanceUptime(65_000), "1m 5s")
        XCTAssertEqual(instanceUptime(3_660_000), "1h 1m")
        XCTAssertEqual(instanceUptime(90_000_000), "1d 1h")
    }

    func testHumanErrorsSeparateDiagnosticsAndPreservePairingGuidance() {
        let text = humanErrorText(ClientError.outcomeUnknown("original-reference"))
        XCTAssertTrue(text.hasPrefix("We couldn't confirm"))
        XCTAssertFalse(text.components(separatedBy: "\nDetails: ")[0].contains("original-reference"))
        XCTAssertTrue(text.contains("original-reference"))
        XCTAssertEqual(humanErrorText(PairingClientError.pendingConnection), PairingClientError.pendingConnection.localizedDescription)
        XCTAssertTrue(humanErrorText(URLError(.notConnectedToInternet)).hasPrefix("You're offline."))
        XCTAssertEqual(pairingStatusLabel("pending_approval"), "Waiting for approval on your Mac")
        XCTAssertEqual(hubStatusLabel("outcome_unknown"), "Result not confirmed")
    }

    func testPollingKeepsActionFailureAndUnconfirmedFence() async {
        let action = HubAction()
        await action.perform { throw ClientError.outcomeUnknown("saved-action") }
        let original = action.error
        await action.poll {}
        XCTAssertEqual(action.error, original)
        XCTAssertTrue(action.uncertain)
        XCTAssertEqual(action.uncertainNonce, "saved-action")
        await action.poll { throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(action.error, original)
        XCTAssertNotNil(action.pollingError)
        XCTAssertFalse(action.busy)
    }


    func testRenderAllScenesInLightAndDark() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let output = outputDirectory()
        var produced: [String] = []
        let only = ProcessInfo.processInfo.environment["LB_SNAPSHOT_SCENES"].map { Set($0.split(separator: ",").map(String.init)) }
        let scenes = LemonBotSnapshotScene.allCases.filter { only?.contains($0.slug) ?? true }
        for scene in scenes {
            for (name, appearance, scheme) in [("light", NSAppearance.Name.aqua, ColorScheme.light), ("dark", NSAppearance.Name.darkAqua, ColorScheme.dark)] {
                let label = "apple-\(scene.slug)-\(name)"
                guard let png = await render(scene, appearance: appearance, scheme: scheme) else { XCTFail("\(label): no image produced"); continue }
                XCTAssertGreaterThan(png.count, 4_000, "\(label): PNG is implausibly small")
                if let output { try? png.write(to: output.appendingPathComponent(label + ".png"), options: .atomic) }
                produced.append(label)
            }
        }
        XCTAssertEqual(produced.count, scenes.count * 2, "Expected every scene in light and dark")
        if let output { print("LemonBot snapshots written to \(output.path): \(produced.joined(separator: ", "))") }
    }

    private func outputDirectory() -> URL? {
        let path = ProcessInfo.processInfo.environment["LB_SNAPSHOT_DIR"] ?? "/tmp/lb-ux/after"
        let url = URL(fileURLWithPath: path, isDirectory: true)
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url }
        catch { print("Snapshot directory \(path) is unwritable (\(error.localizedDescription)); images are checked but not saved."); return nil }
    }

    private func render(_ scene: LemonBotSnapshotScene, appearance: NSAppearance.Name, scheme: ColorScheme) async -> Data? {
        let store = await LemonBotFixtures.loadStore(scenario: scene.scenario)
        let size = scene.windowSize
        let rootView = LemonBotSnapshotScene.view(for: scene, store: store)
            .environment(\.colorScheme, scheme)
            .frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = hosting
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil; window.close() }

        await settle(seconds: 2.5)
        hosting.layoutSubtreeIfNeeded()
        let target = window.contentView?.superview ?? hosting
        let bounds = target.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = bounds.size
        target.cacheDisplay(in: bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// Lets SwiftUI `.task` loads, layout and animations finish while pumping both the run loop and the main actor.
    private func settle(seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
#endif
