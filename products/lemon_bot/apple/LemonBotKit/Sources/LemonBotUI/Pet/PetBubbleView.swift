import CoreGraphics
import SwiftUI

/// A quiet, two-line status balloon shared by the desktop overlay and design snapshots.
public struct PetBubbleView: View {
    public let text: String

    public init(text: String) { self.text = text }

    public var body: some View {
        VStack(spacing: 0) {
            Text(text)
                .font(LBFont.meta)
                .foregroundStyle(LB.ink)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(LB.raised, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(LB.separator, lineWidth: 1))
            PetBubbleTail().fill(LB.raised).frame(width: 12, height: 6)
        }
        .frame(maxWidth: 180)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(text)
    }
}

private struct PetBubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.closeSubpath()
        }
    }
}

/// One atlas cell, intentionally rendered without smoothing or an animation clock.
public struct PetFigure: View {
    public let frame: CGImage
    public let width: CGFloat

    public init(frame: CGImage, width: CGFloat = 96) {
        self.frame = frame
        self.width = width
    }

    public var body: some View {
        Image(decorative: frame, scale: 1)
            .interpolation(.none)
            .resizable()
            .frame(width: width, height: width * 208 / 192)
            .accessibilityHidden(true)
    }
}
