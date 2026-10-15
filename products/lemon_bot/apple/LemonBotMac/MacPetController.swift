import AppKit
import LemonBotKit
import LemonBotUI
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct MacPetPreferences: Codable {
    enum Size: String, CaseIterable, Codable {
        case small, medium, large
        var width: CGFloat { switch self { case .small: return 72; case .medium: return 96; case .large: return 128 } }
        var label: String { rawValue.capitalized }
    }
    struct Position: Codable { var x: Double; var y: Double }
    var enabled = false
    var petID = "lemon"
    var size = Size.medium
    var soundEnabled = false
    var display: String?
    var positions: [String: Position] = [:]
}

/// Launch-only design controls never read Keychain, the real pet library, or device preferences.
enum MacPetLaunch {
    static var fixtures: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-LBFixtures") || value("-LBPetPreview") != nil
        #else
        return false
        #endif
    }
    static func value(_ name: String) -> String? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
        #else
        return nil
        #endif
    }
    static var mood: PetMood? { value("-LBPetPreview").flatMap(PetMood.init(rawValue:)) }
    static var position: NSPoint? {
        guard let value = value("-LBPetPosition") else { return nil }
        let parts = value.split(separator: ",").compactMap { Double($0) }
        return parts.count == 2 ? NSPoint(x: parts[0], y: parts[1]) : nil
    }
    static func status(_ mood: PetMood) -> PetStatus {
        switch mood {
        case .idle: return PetStatus(mood: mood, detail: "Your Bots are ready")
        case .thinking: return PetStatus(mood: mood, detail: "Atlas · Thinking")
        case .working: return PetStatus(mood: mood, detail: "Atlas · Running shell command")
        case .needsInput: return PetStatus(mood: mood, bubble: "Needs approval", detail: "Atlas · Needs approval")
        case .done: return PetStatus(mood: mood, bubble: "Done!", detail: "Atlas · Finished")
        case .failed: return PetStatus(mood: mood, bubble: "Run failed", detail: "Atlas · Run failed")
        case .offline: return PetStatus(mood: mood, bubble: "Offline", detail: "Reconnect to Lemon Bot")
        case .signedOut: return PetStatus(mood: mood, bubble: "Sign in to Lemon Bot", detail: "Sign in to Lemon Bot")
        }
    }
}

@MainActor
@Observable
final class MacPetController: NSObject {
    private(set) var preferences: MacPetPreferences
    private(set) var pets: [InstalledPet] = []
    private(set) var thumbnails: [String: NSImage] = [:]
    private(set) var status = PetStatus(mood: .signedOut)
    var errorMessage: String?
    var importing = false
    var openWorkspace: (() -> Void)?
    var openSettings: (() -> Void)?

    @ObservationIgnored private let platform: MacPlatformController
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let library: PetLibrary?
    @ObservationIgnored private let preview: Bool
    @ObservationIgnored private var panel: MacPetPanel?
    @ObservationIgnored private var frameDurations: [Int] = []
    @ObservationIgnored private var content: MacPetContentView?
    @ObservationIgnored private var sprite: PetSprite?
    @ObservationIgnored private var masks: [ObjectIdentifier: MacPetAlphaMask] = [:]
    @ObservationIgnored private var currentImage: CGImage?
    @ObservationIgnored private var animation = PetAnimation.idle
    @ObservationIgnored private var frameIndex = 0
    @ObservationIgnored private var animationTimer: Timer?
    @ObservationIgnored private var statusTimer: Timer?
    @ObservationIgnored private var globalMonitor: Any?
    @ObservationIgnored private var localMonitor: Any?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var workspaceObserver: NSObjectProtocol?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var hovered = false
    @ObservationIgnored private var observationGeneration = 0
    /// Per animation, the fraction of the cell above its tallest frame's artwork; the balloon sits just above it.
    @ObservationIgnored private var artTops: [PetAnimation: CGFloat] = [:]
    @ObservationIgnored private var dragging = false
    @ObservationIgnored private var pointerDown: NSPoint?
    @ObservationIgnored private var dragOrigin = NSPoint.zero
    @ObservationIgnored private var previousDragX: CGFloat = 0
    @ObservationIgnored private var oneShot = false
    @ObservationIgnored private var donePlayed = false
    @ObservationIgnored private var reducedMotion = false
    @ObservationIgnored private var sound: NSSound?
    #if DEBUG
    @ObservationIgnored private var captureTimer: Timer?
    @ObservationIgnored private var capturedPreview = false
    #endif
    private static let preferencesKey = "lemonbot.pet.preferences"

    init(platform: MacPlatformController) {
        self.platform = platform
        preview = MacPetLaunch.fixtures
        if MacPetLaunch.fixtures {
            let suite = "lemonbot.pet.preview"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            self.defaults = defaults
            var preferences = MacPetPreferences()
            preferences.enabled = MacPetLaunch.mood != nil || (ProcessInfo.processInfo.arguments.contains("-LBFixtures") && MacPetLaunch.value("-LBPetCapture") != nil)
            self.preferences = preferences
            library = PetLibrary(root: FileManager.default.temporaryDirectory.appendingPathComponent("LemonBotPetPreview-\(UUID().uuidString)", isDirectory: true))
        } else {
            defaults = .standard
            preferences = defaults.data(forKey: Self.preferencesKey).flatMap { try? JSONDecoder().decode(MacPetPreferences.self, from: $0) } ?? MacPetPreferences()
            do { library = PetLibrary(root: try PetLibrary.defaultRoot()) }
            catch { library = nil; errorMessage = error.localizedDescription }
        }
        super.init()
    }

    func start() {
        guard !started else { return }
        started = true
        // Nothing is decoded or observed until the pet is shown; a hidden pet costs nothing.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenParametersChanged() }
        })
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.motionChanged() }
        }
        updateVisibility()
    }

    func stop() {
        animationTimer?.invalidate(); animationTimer = nil
        statusTimer?.invalidate(); statusTimer = nil
        #if DEBUG
        captureTimer?.invalidate(); captureTimer = nil
        #endif
        removeMonitors()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        workspaceObserver = nil
        panel?.orderOut(nil)
        started = false
    }

    func updatePreferences(_ update: (inout MacPetPreferences) -> Void) {
        let old = preferences
        update(&preferences)
        persist()
        if preferences.petID != old.petID { loadSelectedPet() }
        if preferences.size != old.size { layout(); clampAndSave() }
        updateVisibility()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        if preview { defaults.setVolatileDomain([Self.preferencesKey: data], forName: UserDefaults.argumentDomain) }
        else { defaults.set(data, forKey: Self.preferencesKey) }
    }

    /// Re-derives on store changes while the pet is shown. Bumping the generation ends a tracking chain.
    private func observeStatus() {
        guard started, preferences.enabled else { return }
        observationGeneration += 1
        let generation = observationGeneration
        let result = withObservationTracking {
            (platform.store.petStatus(now: Date()), platform.store.localSettings?.reducedMotion == "on")
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, generation == self.observationGeneration else { return }
                self.observeStatus()
            }
        }
        let motion = result.1 || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let motionChanged = reducedMotion != motion
        reducedMotion = motion
        applyStatus(MacPetLaunch.mood.map(MacPetLaunch.status) ?? result.0)
        if motionChanged { restartAnimation() }
    }

    private func refreshStatus() {
        applyStatus(MacPetLaunch.mood.map(MacPetLaunch.status) ?? platform.store.petStatus(now: Date()))
    }

    private func applyStatus(_ next: PetStatus) {
        if next != status {
            let previous = status.mood
            status = next
            if previous != next.mood {
                donePlayed = false
                playSound(for: next.mood)
                restartAnimation()
            }
            updateBubble()
        }
        scheduleStatusExpiry()
    }

    private var visible: Bool { preferences.enabled && panel?.isVisible == true && panel?.occlusionState.contains(.visible) == true }

    private func scheduleStatusExpiry() {
        statusTimer?.invalidate(); statusTimer = nil
        guard visible, MacPetLaunch.mood == nil, let until = status.validUntil else { return }
        statusTimer = timer(after: max(0.05, until.timeIntervalSinceNow)) { $0.refreshStatus() }
    }

    private func motionChanged() {
        reducedMotion = platform.store.localSettings?.reducedMotion == "on" || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        restartAnimation()
    }

    private func refreshLibrary() {
        pets = library?.installedPets() ?? []
        loadSelectedPet()
    }

    /// Settings-only: decoding every installed atlas for thumbnails is deferred until the picker is shown.
    func settingsAppeared() {
        pets = library?.installedPets() ?? []
        thumbnails = [:]
        for pet in pets {
            if let image = try? library?.loadSprite(pet).frames(for: .idle).first {
                // Native Picker menus use NSImage's intrinsic size, not a SwiftUI frame modifier.
                thumbnails[pet.id] = NSImage(cgImage: image, size: NSSize(width: 24, height: 26))
            }
        }
    }

    private func loadSelectedPet() {
        guard let library else { return }
        do {
            guard let pet = pets.first(where: { $0.id == preferences.petID }) else {
                throw NSError(domain: "LemonBotPet", code: 1, userInfo: [NSLocalizedDescriptionKey: "The selected pet is no longer installed. Choose another pet in Settings."])
            }
            sprite = try library.loadSprite(pet)
        } catch {
            errorMessage = error.localizedDescription
            sprite = pets.first(where: { $0.id == PetLibrary.defaultPetID && $0.isBuiltIn }).flatMap { try? library.loadSprite($0) }
            if sprite != nil { preferences.petID = PetLibrary.defaultPetID; persist() }
        }
        masks.removeAll()
        artTops.removeAll()
        if let sprite {
            for animation in PetAnimation.allCases {
                for image in sprite.frames(for: animation) {
                    let mask = MacPetAlphaMask(image)
                    masks[ObjectIdentifier(image)] = mask
                    artTops[animation] = min(artTops[animation] ?? 1, mask.topFraction)
                }
            }
            for image in sprite.lookFrames.compactMap({ $0 }) { masks[ObjectIdentifier(image)] = MacPetAlphaMask(image) }
        }
        updateBubble()
        restartAnimation()
    }

    private func makePanel() {
        let panel = MacPetPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier("lemonbot.pet")
        panel.title = "Lemon Bot desktop pet"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        let content = MacPetContentView()
        content.controller = self
        panel.contentView = content
        self.panel = panel
        self.content = content
        content.spriteView.layer?.contents = currentImage
        layout()
        restorePosition()
        if let position = MacPetLaunch.position { panel.setFrameOrigin(position) }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.occlusionChanged() }
        })
    }

    private func layout() {
        guard let panel, let content else { return }
        let width = preferences.size.width
        let height = width * 208 / 192
        let size = NSSize(width: 204, height: height + 72)
        panel.setContentSize(size)
        content.frame = NSRect(origin: .zero, size: size)
        content.spriteView.frame = NSRect(x: (size.width - width) / 2, y: 0, width: width, height: height)
        updateBubble()
    }

    private func updateVisibility() {
        guard started else { return }
        if preferences.enabled {
            let appearing = panel?.isVisible != true
            if sprite == nil { refreshLibrary() }
            if panel == nil { makePanel() }
            if appearing { observeStatus() }
            panel?.orderFrontRegardless()
            if let position = MacPetLaunch.position { panel?.setFrameOrigin(position) }
            installMonitors()
            if appearing { hovered = false; play(.waving, once: true) }
            scheduleStatusExpiry()
            pointerMoved()
            #if DEBUG
            schedulePreviewCapture()
            #endif
        } else {
            panel?.orderOut(nil)
            animationTimer?.invalidate(); animationTimer = nil
            statusTimer?.invalidate(); statusTimer = nil
            #if DEBUG
            captureTimer?.invalidate(); captureTimer = nil
            #endif
            removeMonitors()
            hovered = false
            observationGeneration += 1
        }
    }

    private func occlusionChanged() {
        if visible {
            refreshStatus()
            if animationTimer == nil { scheduleFrame() }
            #if DEBUG
            schedulePreviewCapture()
            #endif
        }
        else {
            animationTimer?.invalidate(); animationTimer = nil
            statusTimer?.invalidate(); statusTimer = nil
            #if DEBUG
            captureTimer?.invalidate(); captureTimer = nil
            #endif
        }
    }

    #if DEBUG
    private func schedulePreviewCapture() {
        guard ProcessInfo.processInfo.arguments.contains("-LBFixtures"), MacPetLaunch.value("-LBPetCapture") != nil,
              !capturedPreview, captureTimer == nil else { return }
        // Launch-to-visible takes about a second; wait for the greeting wave to finish so the mood row is captured.
        captureTimer = timer(after: 3) { controller in
            controller.captureTimer = nil
            if ProcessInfo.processInfo.arguments.contains("-LBPetHover") {
                controller.hovered = true
                controller.updateBubble()
                controller.play(.waving, once: true)
            }
            controller.capturePreview()
        }
    }

    private func capturePreview() {
        guard let path = MacPetLaunch.value("-LBPetCapture"), let content, panel?.isVisible == true else { return }
        content.layoutSubtreeIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        do {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
            capturedPreview = true
            print("Desktop pet capture: \(path); mood=\(status.mood.rawValue); frame=\(String(describing: panel?.frame))")
        } catch { errorMessage = "Couldn't save the pet preview: \(error.localizedDescription)"; print(errorMessage!) }
    }
    #endif

    private func restartAnimation() {
        guard started else { return }
        if dragging { return }
        play(status.mood == .done && donePlayed ? .idle : status.mood.animation, once: status.mood == .done && !donePlayed)
    }

    private func play(_ animation: PetAnimation, once: Bool = false) {
        animationTimer?.invalidate(); animationTimer = nil
        let previous = self.animation
        self.animation = reducedMotion ? status.mood.animation : animation
        if artTops[previous] != artTops[self.animation] { updateBubble() }
        oneShot = !reducedMotion && once
        frameIndex = 0
        frameDurations = self.animation.durations(frameCount: sprite?.frames(for: self.animation).count ?? 0)
        showFrame()
        scheduleFrame()
    }

    private func showFrame() {
        guard let frames = sprite?.frames(for: animation), frames.indices.contains(frameIndex) else { return }
        setImage(frames[frameIndex])
    }

    private func setImage(_ image: CGImage) {
        guard currentImage !== image else { return }
        currentImage = image
        CATransaction.begin(); CATransaction.setDisableActions(true)
        content?.spriteView.layer?.contents = image
        CATransaction.commit()
        updateHitTesting()
    }

    private func scheduleFrame() {
        guard visible, !reducedMotion, let frames = sprite?.frames(for: animation), !frames.isEmpty else { return }
        let duration = frameDurations[frameIndex]
        animationTimer = timer(after: Double(duration) / 1000) { $0.advanceFrame() }
    }

    private func advanceFrame() {
        guard let frames = sprite?.frames(for: animation), visible else { return }
        if frameIndex + 1 < frames.count {
            frameIndex += 1; showFrame(); scheduleFrame()
        } else if oneShot {
            if animation == .jumping { donePlayed = true }
            restartAnimation()
        } else if animation == .idle {
            frameIndex = 0; showFrame()
            animationTimer = timer(after: Double.random(in: 4...9)) { $0.scheduleFrame() }
        } else {
            frameIndex = 0; showFrame(); scheduleFrame()
        }
    }

    private func timer(after interval: TimeInterval, action: @escaping @MainActor (MacPetController) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func updateBubble() {
        guard let content else { return }
        let text = hovered ? status.detail ?? status.bubble : status.bubble
        content.bubble.rootView = MacPetBubble(text: text)
        content.bubble.isHidden = text == nil
        let height = min(66, content.bubble.fittingSize.height)
        // Anchor the balloon just above the current animation's artwork, not the empty top of the atlas cell.
        let artTop = content.spriteView.frame.minY + content.spriteView.frame.height * (1 - (artTops[animation] ?? 1))
        content.bubble.frame = NSRect(x: 12, y: artTop + 2, width: 180, height: height)
        content.setAccessibilityLabel("Lemon Bot pet. \(status.detail ?? status.bubble ?? status.mood.rawValue)")
        updateHitTesting()
    }

    private func installMonitors() {
        guard globalMonitor == nil else { return }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in self?.pointerMoved() }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in self?.pointerMoved(); return event }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil; localMonitor = nil
    }

    private func localPointer() -> NSPoint {
        guard let panel else { return .zero }
        return panel.convertPoint(fromScreen: NSEvent.mouseLocation)
    }

    func hitsSprite(_ point: NSPoint) -> Bool {
        guard let rect = content?.spriteView.frame, rect.contains(point), let image = currentImage,
              let mask = masks[ObjectIdentifier(image)] else { return false }
        return mask.opaque(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height)
    }

    func hitsBubble(_ point: NSPoint) -> Bool {
        guard let bubble = content?.bubble, !bubble.isHidden else { return false }
        return bubble.frame.contains(point)
    }

    private func updateHitTesting() {
        let point = localPointer()
        panel?.ignoresMouseEvents = !dragging && !hitsSprite(point) && !hitsBubble(point)
    }

    private func pointerMoved() {
        guard preferences.enabled, let panel, let content else { return }
        updateHitTesting()
        guard !dragging else { return }
        let point = localPointer()
        let over = hitsSprite(point) || hitsBubble(point)
        if over != hovered {
            hovered = over
            updateBubble()
            if over { play(.waving, once: true) }
        }
        guard !reducedMotion, status.mood == .idle, !hovered, !oneShot else { return }
        let center = panel.convertPoint(toScreen: NSPoint(x: content.spriteView.frame.midX, y: content.spriteView.frame.midY))
        let dx = NSEvent.mouseLocation.x - center.x, dy = NSEvent.mouseLocation.y - center.y
        let distance = hypot(dx, dy)
        if distance > 28, distance < 260, let image = sprite?.lookFrame(degrees: atan2(dx, dy) * 180 / .pi) {
            animationTimer?.invalidate(); animationTimer = nil
            setImage(image)
        } else if animationTimer == nil { showFrame(); scheduleFrame() }
    }

    func mouseDown() {
        pointerDown = NSEvent.mouseLocation
        dragOrigin = panel?.frame.origin ?? .zero
        previousDragX = NSEvent.mouseLocation.x
    }

    func mouseDragged() {
        guard let down = pointerDown, let panel else { return }
        let point = NSEvent.mouseLocation
        guard dragging || hypot(point.x - down.x, point.y - down.y) > 3 else { return }
        dragging = true
        panel.ignoresMouseEvents = false
        let direction: PetAnimation = point.x < previousDragX ? .runningLeft : .runningRight
        if animation != direction { play(direction) }
        previousDragX = point.x
        panel.setFrameOrigin(NSPoint(x: dragOrigin.x + point.x - down.x, y: dragOrigin.y + point.y - down.y))
    }

    func mouseUp() {
        guard pointerDown != nil else { return }
        pointerDown = nil
        if dragging { dragging = false; clampAndSave(); restartAnimation(); pointerMoved() }
        else { activate() }
    }

    func activate() {
        if let url = status.deepLink { Task { await platform.route(url); focusWorkspace() } }
        else { focusWorkspace() }
    }

    private func focusWorkspace() {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "lemonbot.main" }) { window.makeKeyAndOrderFront(nil) }
        else { openWorkspace?() }
        NSApp.activate(ignoringOtherApps: true)
    }

    func contextMenu(_ event: NSEvent) {
        guard let content else { return }
        let menu = NSMenu()
        for (title, action) in [("Open Lemon Bot", #selector(openFromMenu)), ("Pet Settings…", #selector(settingsFromMenu)), ("Hide Pet", #selector(hideFromMenu))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: content)
    }
    @objc private func openFromMenu() { focusWorkspace() }
    @objc private func settingsFromMenu() { openSettings?(); NSApp.activate(ignoringOtherApps: true) }
    @objc private func hideFromMenu() { updatePreferences { $0.enabled = false } }

    private func displayKey(_ screen: NSScreen) -> String {
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        return "\(id):\(screen.localizedName)"
    }

    private var mainScreen: NSScreen? { NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID() }) ?? NSScreen.main }

    private func restorePosition() {
        guard let panel else { return }
        if let screen = NSScreen.screens.first(where: { displayKey($0) == preferences.display }), let saved = preferences.positions[displayKey(screen)] {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + saved.x, y: screen.visibleFrame.minY + saved.y))
            clampAndSave()
        } else { resetPosition() }
    }

    func resetPosition() {
        if panel == nil { preferences.display = nil; persist(); return }
        guard let panel, let screen = mainScreen else { return }
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - panel.frame.width - 24, y: screen.visibleFrame.minY + 24))
        clampAndSave()
    }

    private func clampAndSave() {
        guard let panel else { return }
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? mainScreen else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(x: min(max(panel.frame.minX, visible.minX), max(visible.minX, visible.maxX - panel.frame.width)),
                             y: min(max(panel.frame.minY, visible.minY), max(visible.minY, visible.maxY - panel.frame.height)))
        panel.setFrameOrigin(origin)
        let key = displayKey(screen)
        preferences.display = key
        preferences.positions[key] = MacPetPreferences.Position(x: origin.x - visible.minX, y: origin.y - visible.minY)
        persist()
    }

    private func screenParametersChanged() {
        guard let panel else { return }
        if let position = MacPetLaunch.position { panel.setFrameOrigin(position); return }
        if !NSScreen.screens.contains(where: { displayKey($0) == preferences.display }) || !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) { resetPosition() }
        else { restorePosition() }
    }

    private func playSound(for mood: PetMood) {
        guard preferences.enabled, preferences.soundEnabled else { return }
        let name: String
        switch mood { case .needsInput: name = "Tink"; case .done: name = "Pop"; case .failed: name = "Basso"; default: return }
        sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound
        sound?.volume = 0.2
        sound?.play()
    }

    func importPet() {
        let panel = NSOpenPanel()
        panel.title = "Import desktop pet"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.folder, .zip, .json]
        let home = URL(fileURLWithPath: NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory(), isDirectory: true)
        // Let the picker resolve this location: a sandboxed existence check cannot see an ungranted folder.
        panel.directoryURL = home.appendingPathComponent(".codex/pets", isDirectory: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            if url.lastPathComponent == "pet.json" { self.authorizePetFolder(for: url) }
            else { self.importLocalPet(url) }
        }
    }

    private func authorizePetFolder(for manifest: URL) {
        // A sandbox grant for one JSON file does not grant access to its adjacent atlas.
        let panel = NSOpenPanel()
        panel.title = "Allow access to the pet folder"
        panel.message = "Choose the folder containing this pet.json so Lemon Bot can read its spritesheet too."
        panel.directoryURL = manifest.deletingLastPathComponent()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Import pet folder"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.importLocalPet(url)
        }
    }

    private func importLocalPet(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let imported = try library?.importPackage(at: url) ?? []
            errorMessage = nil
            settingsAppeared()
            if let first = imported.first { select(first.id) }
        } catch { errorMessage = error.localizedDescription }
    }

    func importURL(_ text: String) async {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.lowercased() == "https", url.host != nil else {
            errorMessage = "Enter an HTTPS link to a pet .zip or pet.json file."; return
        }
        importing = true
        defer { importing = false }
        do {
            guard let library else { return }
            let pet = try await library.importPackage(from: url)
            errorMessage = nil
            settingsAppeared()
            select(pet.id)
        } catch { errorMessage = error.localizedDescription }
    }

    func removeSelectedPet() {
        guard let pet = pets.first(where: { $0.id == preferences.petID }), !pet.isBuiltIn else { return }
        do {
            try library?.remove(pet)
            preferences.petID = PetLibrary.defaultPetID
            persist()
            errorMessage = nil
            settingsAppeared()
            loadSelectedPet()
        } catch { errorMessage = error.localizedDescription }
    }

    /// Selects an imported pet; re-importing the current pet reloads its replaced atlas.
    private func select(_ id: String) {
        if id == preferences.petID { loadSelectedPet() } else { updatePreferences { $0.petID = id } }
    }
}

private final class MacPetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Half-resolution alpha planes keep pointer tracking O(1), without reading the atlas on mouse moves.
private struct MacPetAlphaMask {
    private let width = 96
    private let height = 104
    private var pixels: [UInt8]
    init(_ image: CGImage) {
        pixels = [UInt8](repeating: 0, count: 96 * 104)
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 96, height: 104, bitsPerComponent: 8, bytesPerRow: 96,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: 96, height: 104))
        }
    }
    /// Fraction of the cell height above the topmost opaque row (1 when empty).
    var topFraction: CGFloat {
        guard let index = pixels.firstIndex(where: { $0 > 25 }) else { return 1 }
        return CGFloat(index / width) / CGFloat(height)
    }
    func opaque(x: CGFloat, y: CGFloat) -> Bool {
        let column = min(width - 1, max(0, Int(x * CGFloat(width))))
        let row = min(height - 1, max(0, Int((1 - y) * CGFloat(height))))
        return pixels[row * width + column] > 25
    }
}
