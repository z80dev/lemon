#if DEBUG
import AppKit
import ImageIO
import LemonBotKit
import SwiftUI
import XCTest
@testable import LemonBotUI

@MainActor
final class PetSnapshotTests: XCTestCase {
    func testPetMoods() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LB_SNAPSHOT_DIR"] ?? "/tmp/lb-ux/pet", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = PetLibrary(root: FileManager.default.temporaryDirectory.appendingPathComponent("LemonBotPetSnapshots-\(UUID().uuidString)"))
        let pet = try XCTUnwrap(library.installedPets().first { $0.id == "lemon" && $0.isBuiltIn })
        let sprite = try library.loadSprite(pet)
        let bubbles: [PetMood: String] = [.needsInput: "Needs approval", .done: "Done!", .failed: "Run failed", .offline: "Offline", .signedOut: "Sign in to Lemon Bot"]
        for mood in PetMood.allCases {
            let image = try XCTUnwrap(sprite.frames(for: mood.animation).first)
            try await render(frame: image, bubble: bubbles[mood], label: mood.rawValue, directory: directory)
        }
        let wave = try XCTUnwrap(sprite.frames(for: .waving).dropFirst().first ?? sprite.frames(for: .waving).first)
        try await render(frame: wave, bubble: "Atlas · Running shell command", label: "hover-detail", directory: directory)
    }

    private func render(frame: CGImage, bubble: String?, label: String, directory: URL) async throws {
        let size = NSSize(width: 240, height: 224)
        let hosting = NSHostingView(rootView: VStack(spacing: 4) {
            if let bubble { PetBubbleView(text: bubble) }
            else { Color.clear.frame(height: 38) }
            PetFigure(frame: frame)
        }.frame(width: size.width, height: size.height).background(LB.canvas).environment(\.colorScheme, .light))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 480, pixelsHigh: 448, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 480)
        XCTAssertEqual(decoded.height, 448)
        try png.write(to: directory.appendingPathComponent("pet-\(label).png"), options: .atomic)
    }
}
#endif
