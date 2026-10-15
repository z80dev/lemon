import SwiftUI
import LemonBotKit

// Shared building blocks for the messaging UI. Borderless, soft fills, full pills.

/// Round ghost icon button (sidebar search / new Bot, inspector close).
struct GhostCircleButtonStyle: ButtonStyle {
    var size: CGFloat = 32
    var filled = true
    var minimumTouchSize: CGFloat = 0
    func makeBody(configuration: Configuration) -> some View {
        GhostCircleBody(configuration: configuration, size: size, filled: filled, minimumTouchSize: minimumTouchSize)
    }
    private struct GhostCircleBody: View {
        let configuration: Configuration
        let size: CGFloat
        let filled: Bool
        let minimumTouchSize: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .labelStyle(.iconOnly)
                .font(.system(size: size * 0.44, weight: .medium))
                .foregroundStyle(LB.ink)
                .frame(width: size, height: size)
                .background(Circle().fill(configuration.isPressed ? LB.selected : hovering ? LB.selected : filled ? LB.fill : .clear))
                .frame(minWidth: minimumTouchSize, minHeight: minimumTouchSize)
                .contentShape(Circle())
                .opacity(enabled ? 1 : 0.4)
                .onHover { hovering = $0 }
        }
    }
}

/// Full-pill text button.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary(Color, Color), secondary, quiet, destructive }
    var kind: Kind = .secondary
    var compact = false
    var minimumTouchSize: CGFloat = 0
    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, kind: kind, compact: compact, minimumTouchSize: minimumTouchSize)
    }
    private struct PillBody: View {
        let configuration: Configuration
        let kind: Kind
        let compact: Bool
        let minimumTouchSize: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(compact ? LBFont.metaEmphasis : LBFont.sectionTitle)
                .lineLimit(1)
                .foregroundStyle(foreground)
                .padding(.horizontal, compact ? 11 : 14)
                .padding(.vertical, compact ? 5 : 7)
                .background(Capsule().fill(background))
                .overlay { if hovering || configuration.isPressed { Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06)) } }
                .frame(minWidth: minimumTouchSize, minHeight: minimumTouchSize)
                .contentShape(Capsule())
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovering = $0 }
        }
        private var foreground: Color {
            switch kind {
            case .primary(_, let on): return on
            case .secondary, .quiet: return LB.ink
            case .destructive: return LB.danger
            }
        }
        private var background: Color {
            switch kind {
            case .primary(let tint, _): return tint
            case .secondary, .destructive: return LB.fill
            case .quiet: return .clear
            }
        }
    }
}
extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static func pill(_ kind: PillButtonStyle.Kind, compact: Bool = false) -> PillButtonStyle { PillButtonStyle(kind: kind, compact: compact) }
    static var lemonPrimary: PillButtonStyle { PillButtonStyle(kind: .primary(LB.lemon, LB.lemonInk)) }
}

/// Small job/title chip beside a name.
struct LabelChip: View {
    let text: String
    var tint: Color? = nil
    var body: some View {
        Text(text)
            .font(LBFont.chip)
            .lineLimit(1)
            .foregroundStyle(tint ?? LB.muted)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill((tint ?? LB.ink).opacity(tint == nil ? 0.07 : 0.14)))
    }
}

struct UnreadDot: View {
    var size: CGFloat = 8
    var body: some View { Circle().fill(LB.unread).frame(width: size, height: size).accessibilityLabel("Unread") }
}

/// Muted section label used in sidebars, inspector and settings.
struct SectionLabel: View {
    let title: String
    var body: some View {
        Text(title).font(LBFont.metaEmphasis).foregroundStyle(LB.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Soft filled container with no border.
struct SoftCard<Content: View>: View {
    var fill: Color = LB.bubble
    var padding: CGFloat = 14
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: LBMetric.cardRadius, style: .continuous).fill(fill))
    }
}

/// Row hover/selection highlight with a subtle transition.
struct RowHighlight: ViewModifier {
    var selected: Bool
    var radius: CGFloat = LBMetric.rowRadius
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(selected ? LB.selected : hovering ? LB.hover : .clear))
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .onHover { hovering = $0 }
            .lbAnimation(LBMotion.fade, value: selected)
    }
}
extension View {
    func rowHighlight(selected: Bool, radius: CGFloat = LBMetric.rowRadius) -> some View { modifier(RowHighlight(selected: selected, radius: radius)) }
}

extension View {
    /// Reserve nonoverlapping iPhone touch space without enlarging the icon artwork.
    func composerTouchTarget() -> some View {
        frame(minWidth: LBMetric.composerHitSize, minHeight: LBMetric.composerHitSize).contentShape(Rectangle())
    }
}

/// Three bouncing dots: the Bot is preparing a reply.
struct TypingDots: View {
    var color: Color = LB.muted
    var dot: CGFloat = 6
    @Environment(\.lbReduceMotion) private var reduceMotion
    var body: some View {
        if reduceMotion {
            HStack(spacing: dot * 0.7) { ForEach(0..<3, id: \.self) { _ in Circle().fill(color).frame(width: dot, height: dot) } }
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                HStack(spacing: dot * 0.7) {
                    ForEach(0..<3, id: \.self) { index in
                        let phase = (t * 2.4 - Double(index) * 0.35).truncatingRemainder(dividingBy: 2.4)
                        let lift = phase < 1.2 ? sin(phase / 1.2 * .pi) : 0
                        Circle().fill(color).frame(width: dot, height: dot)
                            .opacity(0.45 + 0.55 * lift)
                            .offset(y: -dot * 0.5 * lift)
                    }
                }
            }
        }
    }
}

/// Status chip for resource states (machines, connectors, runs) in secondary surfaces.
struct StatusBadge: View {
    let text: String
    var body: some View {
        let tone = StatusTone(text)
        HStack(spacing: 5) {
            Circle().fill(tone.color).frame(width: 6, height: 6)
            Text(humanizedStatus(text)).lineLimit(1)
        }
        .font(LBFont.chip)
        .foregroundStyle(LB.ink.opacity(0.85))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(LB.fill))
        .accessibilityElement(children: .combine)
    }
}
enum StatusTone {
    case good, active, attention, bad, neutral
    init(_ status: String) {
        let s = status.lowercased().components(separatedBy: ": ").last ?? status.lowercased()
        if ["online", "connected", "succeeded", "completed", "approved", "active", "enabled", "idle", "available", "applied", "sent", "verified"].contains(s) { self = .good }
        else if ["working", "running", "making", "queued", "reserved", "started", "syncing", "pending", "scheduled", "in_flight"].contains(s) { self = .active }
        else if ["needs_input", "awaiting_input", "outcome_unknown", "expired", "stale", "reconnect_required", "unknown"].contains(s) { self = .attention }
        else if ["failed", "error", "denied", "declined", "offline", "disconnected", "revoked", "rejected", "cancelled"].contains(s) { self = .bad }
        else { self = .neutral }
    }
    var color: Color {
        switch self {
        case .good: return LB.success
        case .active: return LB.lemon
        case .attention: return LB.warning
        case .bad: return LB.danger
        case .neutral: return LB.faint
        }
    }
}
/// "outcome_unknown" → "Outcome unknown"; "last known: idle" stays readable.
func humanizedStatus(_ raw: String) -> String {
    let spaced = raw.replacingOccurrences(of: "_", with: " ")
    return spaced.prefix(1).uppercased() + spaced.dropFirst()
}
