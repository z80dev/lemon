import CoreGraphics
import Foundation

// GUI-independent decisions behind the Mac desktop pet's overlay. LemonBotMac's controller feeds these real
// pointer/screen/status values and applies the answers to the panel; nothing here touches AppKit.

/// Half-resolution alpha plane keeps pointer tracking O(1), without reading the atlas on mouse moves.
public struct PetAlphaMask: Sendable {
    public static let width = 96
    public static let height = 104
    /// Pixels at or below this alpha (of 255) are transparent for click-through.
    public static let opaqueThreshold: UInt8 = 25
    private var pixels: [UInt8]

    public init(_ image: CGImage) {
        let width = Self.width, height = Self.height
        pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// Fraction of the cell height above the topmost opaque row (1 when empty).
    public var topFraction: CGFloat {
        guard let index = pixels.firstIndex(where: { $0 > Self.opaqueThreshold }) else { return 1 }
        return CGFloat(index / Self.width) / CGFloat(Self.height)
    }

    /// `x`/`y` are fractions of the sprite rect with a bottom-left origin (AppKit view coordinates).
    public func opaque(x: CGFloat, y: CGFloat) -> Bool {
        let column = min(Self.width - 1, max(0, Int(x * CGFloat(Self.width))))
        let row = min(Self.height - 1, max(0, Int((1 - y) * CGFloat(Self.height))))
        return pixels[row * Self.width + column] > Self.opaqueThreshold
    }
}

/// Click-through: which parts of the overlay receive the mouse.
public enum PetHitTesting {
    public static func hitsSprite(_ point: CGPoint, spriteFrame: CGRect, mask: PetAlphaMask?) -> Bool {
        guard spriteFrame.contains(point), let mask else { return false }
        return mask.opaque(x: (point.x - spriteFrame.minX) / spriteFrame.width, y: (point.y - spriteFrame.minY) / spriteFrame.height)
    }

    public static func hitsBubble(_ point: CGPoint, bubbleFrame: CGRect, bubbleHidden: Bool) -> Bool {
        !bubbleHidden && bubbleFrame.contains(point)
    }

    /// The panel ignores mouse events (the click goes to the window underneath) unless a drag is in
    /// progress or the pointer is over an opaque sprite pixel or the visible bubble.
    public static func ignoresMouseEvents(dragging: Bool, overSprite: Bool, overBubble: Bool) -> Bool {
        !dragging && !overSprite && !overBubble
    }
}

/// Pointer-look (Codex V2 gaze) decision for an idle pet.
public enum PetGaze {
    public static let minimumDistance: CGFloat = 28
    public static let maximumDistance: CGFloat = 260

    /// Degrees clockwise from straight up for a pointer offset from the sprite centre, or `nil` when the pointer is
    /// too close or too far to be looked at.
    public static func degrees(dx: CGFloat, dy: CGFloat) -> Double? {
        let distance = hypot(dx, dy)
        guard distance > minimumDistance, distance < maximumDistance else { return nil }
        return atan2(Double(dx), Double(dy)) * 180 / .pi
    }

    /// Gaze only follows the pointer while the pet is idle, not hovered and not in a one-shot animation.
    public static func follows(reducedMotion: Bool, mood: PetMood, hovered: Bool, oneShot: Bool) -> Bool {
        !reducedMotion && mood == .idle && !hovered && !oneShot
    }
}

/// Drag: threshold, run direction and the window origin that follows the pointer. A press that never exceeds the
/// threshold is a click.
public struct PetDragTracker: Sendable {
    public static let threshold: CGFloat = 3
    public struct Step: Equatable, Sendable {
        public var origin: CGPoint
        public var direction: PetAnimation
    }
    public enum Release: Equatable, Sendable { case none, click, dragEnded }

    public private(set) var isDragging = false
    private var down: CGPoint?
    private var origin = CGPoint.zero
    private var previousX: CGFloat = 0

    public init() {}

    public var isPressed: Bool { down != nil }

    public mutating func begin(pointer: CGPoint, panelOrigin: CGPoint) {
        down = pointer
        origin = panelOrigin
        previousX = pointer.x
    }

    /// `nil` until the pointer has moved past the threshold (or when no press is active).
    public mutating func drag(to point: CGPoint) -> Step? {
        guard let down else { return nil }
        guard isDragging || hypot(point.x - down.x, point.y - down.y) > Self.threshold else { return nil }
        isDragging = true
        let direction: PetAnimation = point.x < previousX ? .runningLeft : .runningRight
        previousX = point.x
        return Step(origin: CGPoint(x: origin.x + point.x - down.x, y: origin.y + point.y - down.y), direction: direction)
    }

    public mutating func end() -> Release {
        guard down != nil else { return .none }
        down = nil
        if isDragging { isDragging = false; return .dragEnded }
        return .click
    }
}

/// Where the pet sits within a display's usable (visible) area.
public enum PetPlacement {
    public static let margin: CGFloat = 24

    /// Bottom-right corner of the usable area, inset by `margin`.
    public static func defaultOrigin(panelWidth: CGFloat, visible: CGRect) -> CGPoint {
        CGPoint(x: visible.maxX - panelWidth - margin, y: visible.minY + margin)
    }

    /// Keeps the whole panel inside the usable area; a panel larger than the area pins to its minimum corner.
    public static func clamp(origin: CGPoint, size: CGSize, visible: CGRect) -> CGPoint {
        CGPoint(x: min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width)),
                y: min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height)))
    }

    /// Saved positions are offsets within the usable area, so they survive a Dock or menu-bar change.
    public static func offset(of origin: CGPoint, in visible: CGRect) -> CGPoint {
        CGPoint(x: origin.x - visible.minX, y: origin.y - visible.minY)
    }

    public static func origin(forOffset offset: CGPoint, in visible: CGRect) -> CGPoint {
        CGPoint(x: visible.minX + offset.x, y: visible.minY + offset.y)
    }
}

/// Click-to-open: a click on the sprite or bubble.
public enum PetClickAction: Equatable, Sendable {
    /// Route the validated deep link, then focus the workspace.
    case route(URL)
    /// No resource to open: just focus the workspace.
    case openWorkspace

    public static func resolve(_ status: PetStatus) -> PetClickAction {
        status.deepLink.map(PetClickAction.route) ?? .openWorkspace
    }
}

/// Reactions to live status changes pushed from run events.
public enum PetReaction {
    /// Seconds before an expiring status (recent completion/failure) is re-derived; never below 0.05.
    public static func expiryDelay(_ status: PetStatus, now: Date = Date()) -> TimeInterval? {
        status.validUntil.map { max(0.05, $0.timeIntervalSince(now)) }
    }

    /// The system sound cue for entering a mood; ordinary work, hover and dragging are silent.
    public static func soundName(for mood: PetMood) -> String? {
        switch mood {
        case .needsInput: return "Tink"
        case .done: return "Pop"
        case .failed: return "Basso"
        default: return nil
        }
    }

    /// Done jumps once, then rests as idle until the mood changes again.
    public static func animation(for mood: PetMood, donePlayed: Bool) -> (animation: PetAnimation, once: Bool) {
        mood == .done && donePlayed ? (.idle, false) : (mood.animation, mood == .done)
    }

    /// What a freshly derived status means for the pet; `nil` when nothing changed.
    public struct Change: Equatable, Sendable {
        /// The mood differs: reset the done-jump flag, play the cue and restart the animation.
        public var moodChanged: Bool
    }

    public static func change(from current: PetStatus, to next: PetStatus) -> Change? {
        next == current ? nil : Change(moodChanged: current.mood != next.mood)
    }
}
