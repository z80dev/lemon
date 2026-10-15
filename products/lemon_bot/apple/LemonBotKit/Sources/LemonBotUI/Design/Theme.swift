import SwiftUI
import LemonBotKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Lemon Bot design tokens. Warm olive/cream brand with lemon yellow used sparingly;
// dark mode uses warm near-black surfaces. Every color adapts to the system appearance.

extension Color {
    /// A color that resolves per appearance (light/dark) at render time.
    init(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) {
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark, alpha: darkAlpha) : NSColor(hex: light, alpha: lightAlpha)
        })
        #else
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark, alpha: darkAlpha) : UIColor(hex: light, alpha: lightAlpha)
        })
        #endif
    }
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}
#if os(macOS)
private extension NSColor {
    convenience init(hex: UInt32, alpha: Double) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
#else
private extension UIColor {
    convenience init(hex: UInt32, alpha: Double) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
#endif

/// Semantic surface and text colors.
public enum LB {
    /// Conversation canvas.
    static let canvas = Color(light: 0xF8F8F4, dark: 0x121311)
    /// Sidebar / inspector column.
    static let sidebar = Color(light: 0xF0F1E9, dark: 0x181916)
    /// Assistant bubble and quiet filled controls.
    static let bubble = Color(light: 0xEBECE3, dark: 0x22241F)
    /// Floating pills (header, composer), cards and popovers.
    static let raised = Color(light: 0xFFFFFF, dark: 0x252722)
    /// Soft fill for chips and secondary buttons.
    static let fill = Color(light: 0x2B312A, dark: 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.07)
    /// Hovered row.
    static let hover = Color(light: 0x2B312A, dark: 0xFFFFFF, lightAlpha: 0.045, darkAlpha: 0.045)
    /// Selected row.
    static let selected = Color(light: 0x2B312A, dark: 0xFFFFFF, lightAlpha: 0.085, darkAlpha: 0.085)
    /// Hairline separators; use only where structure needs it.
    static let separator = Color(light: 0x2B312A, dark: 0xFFFFFF, lightAlpha: 0.09, darkAlpha: 0.08)

    static let ink = Color(light: 0x2B312A, dark: 0xECEDE6)
    public static let muted = Color(light: 0x6E766B, dark: 0xA0A598)
    static let faint = Color(light: 0x949B8F, dark: 0x70756B)

    /// Brand olive, used for focus rings, links and selection accents.
    static let accent = Color(light: 0x3C6248, dark: 0xA3C9A9)
    /// Lemon yellow, the sparing brand accent.
    static let lemon = Color(hex: 0xE9D474)
    static let lemonInk = Color(hex: 0x3F4A33)
    static let unread = Color(light: 0x3B82F0, dark: 0x5B9BFF)
    static let success = Color(light: 0x4C8A58, dark: 0x8CCB98)
    public static let warning = Color(light: 0x93691C, dark: 0xE6BA5E)
    public static let danger = Color(light: 0xA6423D, dark: 0xEC8478)

    static let shadow = Color.black.opacity(0.10)
}

/// Shape and spacing metrics on a 4/8 grid.
enum LBMetric {
    static let bubbleRadius: CGFloat = 18
    static let rowRadius: CGFloat = 12
    static let cardRadius: CGFloat = 16
    /// Gap between consecutive grouped bubbles.
    static let groupGap: CGFloat = 4
    /// Gap between message groups.
    static let blockGap: CGFloat = 14
    static let transcriptMaxWidth: CGFloat = 760
    static let bubbleMaxWidth: CGFloat = 560
}

/// Typography: 15pt body on macOS; Dynamic-Type text styles on iOS.
public enum LBFont {
    #if os(macOS)
    static let body = Font.system(size: 15)
    static let bodyEmphasis = Font.system(size: 15, weight: .semibold)
    static let rowTitle = Font.system(size: 14, weight: .semibold)
    public static let rowSubtitle = Font.system(size: 13)
    public static let meta = Font.system(size: 12)
    static let metaEmphasis = Font.system(size: 12, weight: .medium)
    static let chip = Font.system(size: 11, weight: .medium)
    static let title = Font.system(size: 20, weight: .semibold)
    static let sectionTitle = Font.system(size: 13, weight: .semibold)
    static let code = Font.system(size: 13, design: .monospaced)
    #else
    static let body = Font.callout
    static let bodyEmphasis = Font.callout.weight(.semibold)
    static let rowTitle = Font.subheadline.weight(.semibold)
    public static let rowSubtitle = Font.subheadline
    public static let meta = Font.caption
    static let metaEmphasis = Font.caption.weight(.medium)
    static let chip = Font.caption2.weight(.medium)
    static let title = Font.title3.weight(.semibold)
    static let sectionTitle = Font.footnote.weight(.semibold)
    static let code = Font.footnote.monospaced()
    #endif
    /// Extra leading so body text reads at ~1.45 line height.
    static let bodyLineSpacing: CGFloat = 3
}

/// Per-Bot color identity. Palette keys match the web Avatar: yellow, green, blue, pink, purple, orange.
struct BotPalette: Equatable {
    /// Avatar body color.
    let avatar: Color
    /// User bubble, send button and header dot.
    let tint: Color
    /// Text/icon color on `tint`, chosen for contrast.
    let onTint: Color

    static func named(_ key: String?) -> BotPalette {
        switch key {
        case "green": return BotPalette(avatar: Color(hex: 0xA3CA98), tint: Color(hex: 0x4F7D55), onTint: .white)
        case "blue": return BotPalette(avatar: Color(hex: 0xA0C4EA), tint: Color(hex: 0x3F6FA3), onTint: .white)
        case "pink": return BotPalette(avatar: Color(hex: 0xE3AEC3), tint: Color(hex: 0xA2557A), onTint: .white)
        case "purple": return BotPalette(avatar: Color(hex: 0xBDB2E3), tint: Color(hex: 0x6A5CA8), onTint: .white)
        case "orange": return BotPalette(avatar: Color(hex: 0xEBB487), tint: Color(hex: 0xB0643A), onTint: .white)
        case "red": return BotPalette(avatar: Color(hex: 0xE6A79F), tint: Color(hex: 0xA7473F), onTint: .white)
        default: return BotPalette(avatar: Color(hex: 0xEDD56C), tint: Color(hex: 0xE6CC5A), onTint: Color(hex: 0x2E3420))
        }
    }
    static let keys = ["yellow", "green", "blue", "pink", "purple", "orange"]
}

extension Bot {
    var palette: BotPalette { BotPalette.named(avatar.color) }
}

/// Motion: springs that collapse to no animation when Reduce Motion is on
/// (system setting or the account's local `reducedMotion` preference).
enum LBMotion {
    static let spring = Animation.spring(response: 0.36, dampingFraction: 0.86)
    static let snappy = Animation.spring(response: 0.26, dampingFraction: 0.92)
    static let fade = Animation.easeOut(duration: 0.18)
}

private struct LBReduceMotionKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True when either the system or the account's local setting asks for reduced motion.
    var lbReduceMotion: Bool {
        get { self[LBReduceMotionKey.self] || accessibilityReduceMotion }
        set { self[LBReduceMotionKey.self] = newValue }
    }
}

private struct LBAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.lbReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V
    func body(content: Content) -> some View { content.animation(reduceMotion ? nil : animation, value: value) }
}
extension View {
    /// `.animation(_:value:)` that respects Reduce Motion.
    func lbAnimation<V: Equatable>(_ animation: Animation = LBMotion.spring, value: V) -> some View {
        modifier(LBAnimationModifier(animation: animation, value: value))
    }
}
/// `withAnimation` that respects Reduce Motion.
@MainActor func lbWithAnimation<Result>(_ reduceMotion: Bool, _ animation: Animation = LBMotion.spring, _ body: () throws -> Result) rethrows -> Result {
    if reduceMotion { return try body() }
    return try withAnimation(animation, body)
}

extension LemonBotStore {
    /// Account-level reduce-motion preference (in addition to the system setting).
    var prefersReducedMotion: Bool { ["reduce", "reduced", "on", "always"].contains(localSettings?.reducedMotion ?? "system") }
}
