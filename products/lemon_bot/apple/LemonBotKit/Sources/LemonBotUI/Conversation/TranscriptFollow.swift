import SwiftUI

/// Whether the transcript keeps the latest message in view as content arrives.
///
/// The reader follows while pinned to the bottom: on open, after an intentional send, after
/// Jump to latest, or whenever the bottom comes back into view. Only scrolling toward older
/// content unpins it. A growing streamed reply, a new row, or the keyboard and composer shrinking
/// the viewport push the bottom out of view without moving the offset, so they are not mistaken
/// for reading history. Where the system reports scroll phase (iOS 18, macOS 15), nothing scrolls
/// programmatically while the reader drags or a fling decelerates.
struct TranscriptFollow: Equatable {
    /// Bottom distance, in points, still treated as being at the latest message.
    static let nearBottomTolerance: CGFloat = 40

    /// Scroll geometry reduced to what following needs, rounded so sub-point jitter is not a change.
    struct Edge: Equatable {
        /// Top of the scroll view's bounds in content coordinates; it decreases toward older content.
        var offset: CGFloat
        /// Content still below the visible region, past the bottom inset (keyboard, composer).
        var distance: CGFloat
        init(offset: CGFloat, contentHeight: CGFloat, bottomInset: CGFloat, containerHeight: CGFloat) {
            self.offset = offset.rounded()
            self.distance = (contentHeight + bottomInset - offset - containerHeight).rounded()
        }
        @available(iOS 18, macOS 15, *)
        init(_ geometry: ScrollGeometry) {
            self.init(offset: geometry.contentOffset.y, contentHeight: geometry.contentSize.height,
                      bottomInset: geometry.contentInsets.bottom, containerHeight: geometry.containerSize.height)
        }
        /// iOS 17 and macOS 14: the content's own size and the scroll view's bounds in its coordinates
        /// (`GeometryProxy.bounds(of: .scrollView)`), measured as the reader scrolls.
        init(contentHeight: CGFloat, scrollBounds: CGRect) {
            self.init(offset: scrollBounds.minY, contentHeight: contentHeight, bottomInset: 0, containerHeight: scrollBounds.height)
        }
        /// Applies the scroll view's bottom safe-area inset, which content-side measurement cannot see.
        func covered(byBottomInset inset: CGFloat) -> Edge {
            var edge = self
            edge.distance = (distance + inset).rounded()
            return edge
        }
    }

    /// The previous content-side edge (iOS 17, macOS 14), whose geometry action reports only the new value.
    /// A reference so recording every scroll frame does not invalidate the view that owns it.
    final class EdgeHistory {
        var edge: Edge?
    }

    private(set) var pinned = true
    private(set) var nearBottom = true
    private(set) var userScrolling = false

    var showsJumpToLatest: Bool { !pinned && !nearBottom }
    var shouldFollow: Bool { !userScrolling && (pinned || nearBottom) }

    /// Initial open, an intentional send, or Jump to latest.
    mutating func pin() { pinned = true }

    /// Explicit navigation to older content (Find, a linked entry, Load older). The bottom is treated
    /// as out of view until geometry reports otherwise, so a reply arriving before the navigation
    /// lands cannot pull the reader back.
    mutating func release() { pinned = false; nearBottom = false }

    /// Returning to the bottom pins; only an offset moving toward older content unpins.
    mutating func observe(from old: Edge, to new: Edge) {
        nearBottom = new.distance <= Self.nearBottomTolerance
        if nearBottom { pinned = true } else if new.offset < old.offset { pinned = false }
    }

    /// iOS 18 and macOS 15 scroll phase: the reader is touching, dragging or flinging the transcript.
    mutating func observeScrolling(_ scrolling: Bool) { userScrolling = scrolling }
}

@available(iOS 18, macOS 15, *)
extension ScrollPhase {
    /// Touch, drag or fling driven by the reader rather than a programmatic scroll.
    var isUserDriven: Bool { self == .tracking || self == .interacting || self == .decelerating }
}
