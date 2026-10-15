import SwiftUI
import LemonBotKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The Lemon mascot silhouette: a soft, slightly tilted lemon with small rounded tips.
/// Pure vector, so it stays crisp at every size.
struct LemonBlobShape: Shape {
    func path(in rect: CGRect) -> Path {
        var unit = Path()
        let p = { (x: CGFloat, y: CGFloat) in CGPoint(x: x, y: y) }
        unit.move(to: p(0.035, 0.50))
        unit.addCurve(to: p(0.13, 0.38), control1: p(0.05, 0.47), control2: p(0.09, 0.42))
        unit.addCurve(to: p(0.50, 0.07), control1: p(0.20, 0.17), control2: p(0.33, 0.07))
        unit.addCurve(to: p(0.87, 0.36), control1: p(0.68, 0.07), control2: p(0.81, 0.17))
        unit.addCurve(to: p(0.965, 0.49), control1: p(0.91, 0.40), control2: p(0.95, 0.45))
        unit.addCurve(to: p(0.875, 0.63), control1: p(0.955, 0.53), control2: p(0.91, 0.59))
        unit.addCurve(to: p(0.49, 0.93), control1: p(0.81, 0.84), control2: p(0.67, 0.93))
        unit.addCurve(to: p(0.12, 0.62), control1: p(0.31, 0.93), control2: p(0.18, 0.83))
        unit.addCurve(to: p(0.035, 0.50), control1: p(0.085, 0.58), control2: p(0.045, 0.54))
        unit.closeSubpath()
        return LemonBlobShape.fit(unit.applying(CGAffineTransform(translationX: -0.5, y: -0.5).concatenating(CGAffineTransform(rotationAngle: -0.42))), in: rect, inset: 0)
    }
    /// Scales a path (any origin) to fit `rect` while preserving its aspect ratio.
    static func fit(_ path: Path, in rect: CGRect, inset: CGFloat) -> Path {
        let bounds = path.boundingRect
        guard bounds.width > 0, bounds.height > 0 else { return path }
        let target = rect.insetBy(dx: rect.width * inset, dy: rect.height * inset)
        let scale = min(target.width / bounds.width, target.height / bounds.height)
        let transform = CGAffineTransform(translationX: -bounds.midX, y: -bounds.midY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: target.midX, y: target.midY))
        return path.applying(transform)
    }
}

/// The wonky face: two mismatched eyes glancing up-right and a lopsided little smile.
struct WonkyFaceShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let x = { (v: CGFloat) in rect.minX + v * w }
        let y = { (v: CGFloat) in rect.minY + v * h }
        var path = Path()
        // Left eye: slightly smaller, a touch lower, tilted.
        path.addPath(Path(ellipseIn: CGRect(x: -0.042 * w, y: -0.07 * h, width: 0.084 * w, height: 0.14 * h))
            .applying(CGAffineTransform(rotationAngle: 0.18).concatenating(CGAffineTransform(translationX: x(0.47), y: y(0.42)))))
        // Right eye: larger and higher.
        path.addPath(Path(ellipseIn: CGRect(x: -0.048 * w, y: -0.082 * h, width: 0.096 * w, height: 0.164 * h))
            .applying(CGAffineTransform(rotationAngle: 0.12).concatenating(CGAffineTransform(translationX: x(0.63), y: y(0.385)))))
        return path
    }
}
struct WonkySmileShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 0.49 * w, y: rect.minY + 0.585 * h))
        path.addQuadCurve(to: CGPoint(x: rect.minX + 0.665 * w, y: rect.minY + 0.555 * h), control: CGPoint(x: rect.minX + 0.585 * w, y: rect.minY + 0.66 * h))
        return path
    }
}

/// Brand mascot / default Bot avatar, recolored per Bot.
struct LemonAvatar: View {
    var color: Color = BotPalette.named("yellow").avatar
    var showsSmile = true
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                LemonBlobShape().fill(color)
                // Soft top-left highlight gives volume without a gradient look.
                LemonBlobShape().fill(
                    RadialGradient(colors: [.white.opacity(0.32), .white.opacity(0)], center: UnitPoint(x: 0.3, y: 0.22), startRadius: 0, endRadius: side * 0.55)
                )
                LemonBlobShape().stroke(Color.black.opacity(0.06), lineWidth: max(0.5, side * 0.012))
                WonkyFaceShape().fill(LemonFace.color)
                if showsSmile && side >= 18 {
                    WonkySmileShape().stroke(LemonFace.color, style: StrokeStyle(lineWidth: max(1, side * 0.045), lineCap: .round))
                }
            }.frame(width: side, height: side).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
enum LemonFace { static let color = Color(hex: 0x27301F, alpha: 0.88) }

/// Live state shown as a small dot on an avatar.
enum AvatarPresence: Equatable {
    case idle, working, needsInput, offline, none
    /// `activity` is the Bot's presence status (idle | working | making | needs_input | offline).
    /// While this client is disconnected the last-known status is not shown as live.
    init(activity: String, online: Bool) {
        guard online else { self = .none; return }
        switch activity {
        case "working", "making": self = .working
        case "needs_input": self = .needsInput
        case "offline": self = .offline
        default: self = .idle
        }
    }
    var color: Color {
        switch self {
        case .idle: return LB.success
        case .working: return LB.lemon
        case .needsInput: return LB.warning
        case .offline: return LB.faint
        case .none: return .clear
        }
    }
    var label: String {
        switch self {
        case .idle: return "Idle"
        case .working: return "Working"
        case .needsInput: return "Needs you"
        case .offline: return "Offline"
        case .none: return ""
        }
    }
}

/// A Bot avatar: uploaded image if the Bot has one, otherwise the lemon mascot in the Bot's color.
/// Size-agnostic; size it with `.frame`.
struct BotAvatarView: View {
    let store: LemonBotStore
    let bot: Bot
    init(store: LemonBotStore, bot: Bot) { self.store = store; self.bot = bot }
    @State private var image: Image?
    var body: some View {
        Group {
            if let image { image.resizable().scaledToFill().clipShape(LemonBlobShape()) }
            else { LemonAvatar(color: bot.palette.avatar) }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("\(bot.name) avatar")
        .task(id: bot.avatar.attachmentId) {
            image = nil
            guard bot.avatar.kind == "image" || bot.avatar.attachmentId != nil, let id = bot.avatar.attachmentId else { return }
            // A failed avatar download falls back to the mascot; it is decoration, not data.
            guard let url = try? await store.download(attachmentID: id) else { return }
            #if os(macOS)
            if let native = NSImage(contentsOf: url) { image = Image(nsImage: native) }
            #else
            if let native = UIImage(contentsOfFile: url.path) { image = Image(uiImage: native) }
            #endif
        }
    }
}

/// Avatar with optional presence and unread badges, at an explicit size.
struct BotBadgedAvatar: View {
    let store: LemonBotStore
    let bot: Bot
    var size: CGFloat
    var presence: AvatarPresence = .none
    var unread = false
    /// Background behind the badge ring (matches the surface the avatar sits on).
    var ring: Color = LB.sidebar
    @Environment(\.lbReduceMotion) private var reduceMotion
    var body: some View {
        BotAvatarView(store: store, bot: bot)
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                if presence != .none && presence != .idle {
                    let dot = max(8, size * 0.24)
                    Circle().fill(presence.color)
                        .frame(width: dot, height: dot)
                        .overlay { Circle().stroke(ring, lineWidth: max(2, size * 0.05)) }
                        .modifier(PulseModifier(active: presence == .working && !reduceMotion))
                        .offset(x: size * 0.02, y: size * 0.02)
                        .accessibilityLabel(presence.label)
                }
            }
            .overlay(alignment: .topTrailing) {
                if unread {
                    let dot = max(9, size * 0.2)
                    Circle().fill(LB.unread).frame(width: dot, height: dot)
                        .overlay { Circle().stroke(ring, lineWidth: max(2, size * 0.05)) }
                        .offset(x: size * 0.02, y: -size * 0.01)
                        .accessibilityLabel("Unread")
                }
            }
    }
}

private struct PulseModifier: ViewModifier {
    let active: Bool
    @State private var on = false
    func body(content: Content) -> some View {
        content.opacity(active && on ? 0.45 : 1)
            .onAppear { guard active else { return }; withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true } }
            .onChange(of: active) { _, value in
                if value { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true } } else { on = false }
            }
    }
}

/// The lemon brand mark used on empty and first-run screens.
struct LemonMark: View {
    var size: CGFloat = 72
    var body: some View {
        ZStack(alignment: .topTrailing) {
            LemonAvatar(color: LB.lemon)
            LeafShape().fill(Color(hex: 0x6E9A5B))
                .frame(width: size * 0.3, height: size * 0.18)
                .rotationEffect(.degrees(-28))
                .offset(x: -size * 0.02, y: size * 0.01)
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}
struct LeafShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY), control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.35))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.midY), control: CGPoint(x: rect.midX, y: rect.maxY + rect.height * 0.35))
        path.closeSubpath()
        return path
    }
}
