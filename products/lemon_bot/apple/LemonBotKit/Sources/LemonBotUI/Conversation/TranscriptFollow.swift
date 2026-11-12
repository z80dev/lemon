import SwiftUI

/// Whether the transcript keeps the latest message in view as content arrives.
///
/// The reader follows while pinned to the bottom: on open, after an intentional send, after
/// Jump to latest, or whenever the bottom comes back into view. Only the reader scrolling toward
/// older content unpins it. Layout changes the scroll limit instead: a growing streamed reply, a new
/// row, lazy rows measuring themselves, or the keyboard and composer resizing the viewport. When
/// layout pushes the bottom away from a pinned reader, the transcript returns there. Where the system
/// reports scroll phase (iOS 18, macOS 15), nothing scrolls programmatically while the reader drags
/// or a fling decelerates.
struct TranscriptFollow: Equatable {
    /// Bottom distance, in points, still treated as being at the latest message.
    static let nearBottomTolerance: CGFloat = 40

    /// Scroll geometry reduced to what following needs, rounded so sub-point jitter is not a change.
    struct Edge: Equatable {
        /// Top of the scroll view's bounds in content coordinates; it decreases toward older content.
        var offset: CGFloat
        /// Largest offset: content plus the bottom inset (keyboard, composer) minus the container.
        /// It changes with content and viewport layout, never with scrolling.
        var limit: CGFloat
        /// Content still below the visible region, past the bottom inset.
        var distance: CGFloat { limit - offset }
        init(offset: CGFloat, contentHeight: CGFloat, bottomInset: CGFloat, containerHeight: CGFloat) {
            self.offset = offset.rounded()
            self.limit = (contentHeight + bottomInset - containerHeight).rounded()
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
            edge.limit = (limit + inset).rounded()
            return edge
        }
    }

    /// iOS 17 and macOS 14: the content-side measurement and the scroll view's bottom inset arrive in
    /// separate single-value geometry actions; this keeps the previous edge to compare against.
    /// A reference so recording every scroll frame does not invalidate the view that owns it.
    final class EdgeHistory {
        private var measured: Edge?
        private var inset: CGFloat = 0

        /// Records a measurement or bottom inset; returns the previous and current edges once content was measured.
        func record(measured: Edge? = nil, inset: CGFloat? = nil) -> (old: Edge, new: Edge)? {
            let old = self.measured?.covered(byBottomInset: self.inset)
            if let measured { self.measured = measured }
            if let inset { self.inset = inset }
            guard let new = self.measured?.covered(byBottomInset: self.inset) else { return nil }
            return (old ?? new, new)
        }

        /// Forgets the previous transcript's measurement; the viewport inset still applies.
        func reset() { measured = nil }
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

    /// Returning to the bottom pins. Only the reader moving toward older content unpins: the offset
    /// decreases and the bottom gets farther away. Layout moving the offset with the limit (lazy rows
    /// measured above, clamping as content shrinks) or growing the limit (content, keyboard, composer)
    /// is not reading history.
    ///
    /// Returns whether layout pushed the bottom away from a pinned reader, who should be returned there.
    @discardableResult
    mutating func observe(from old: Edge, to new: Edge) -> Bool {
        nearBottom = new.distance <= Self.nearBottomTolerance
        if nearBottom { pinned = true }
        else if new.offset < old.offset && new.distance > old.distance { pinned = false }
        return new.limit != old.limit && pinned && !nearBottom && !userScrolling
    }

    /// iOS 18 and macOS 15 scroll phase: the reader is touching, dragging or flinging the transcript.
    mutating func observeScrolling(_ scrolling: Bool) { userScrolling = scrolling }
}

@available(iOS 18, macOS 15, *)
extension ScrollPhase {
    /// Touch, drag or fling driven by the reader rather than a programmatic scroll.
    var isUserDriven: Bool { self == .tracking || self == .interacting || self == .decelerating }
}
