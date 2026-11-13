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
        /// Top of the visible region (inside the navigation bar, composer and keyboard insets), measured
        /// from the top of the content; it decreases toward older content.
        var offset: CGFloat
        /// Largest offset: content height minus visible height. It changes with content and viewport
        /// layout, never with scrolling.
        var limit: CGFloat
        /// Content still below the visible region.
        var distance: CGFloat { limit - offset }
        init(offset: CGFloat, limit: CGFloat) {
            self.offset = offset.rounded()
            self.limit = limit.rounded()
        }
        /// SwiftUI reports `containerSize` inside the content insets and `contentOffset` from the outer
        /// edge (−top inset at the top). An iPhone trace showed it: the offset at the top was −116 (status
        /// and navigation bars); adding `contentInsets.bottom` to the limit left a settled bottom 224 points
        /// (both bars plus the composer) short, and the keyboard grew that limit by twice its height.
        @available(iOS 18, macOS 15, *)
        init(_ geometry: ScrollGeometry) {
            self.init(offset: geometry.contentOffset.y + geometry.contentInsets.top,
                      limit: geometry.contentSize.height - geometry.containerSize.height)
        }
        /// iOS 17 and macOS 14: the content's frame and the scroll view's frame inside its safe-area
        /// insets, both in one coordinate space, so no scroll-view inset convention is assumed.
        init(content: CGRect, visible: CGRect) {
            self.init(offset: visible.minY - content.minY, limit: content.height - visible.height)
        }
    }

    /// iOS 17 and macOS 14: the content frame and the visible region arrive in separate single-value
    /// geometry actions; this keeps both and the previous edge to compare against. A reference so
    /// recording every scroll frame does not invalidate the view that owns it.
    final class EdgeHistory {
        private var content: CGRect?
        private var visible: CGRect?
        private var last: Edge?

        /// Records a content frame or visible region; returns the previous and current edges once both were measured.
        func record(content: CGRect? = nil, visible: CGRect? = nil) -> (old: Edge, new: Edge)? {
            if let content { self.content = content }
            if let visible { self.visible = visible }
            guard let measuredContent = self.content, let measuredVisible = self.visible else { return nil }
            let new = Edge(content: measuredContent, visible: measuredVisible)
            defer { last = new }
            return (last ?? new, new)
        }

        /// Forgets the previous transcript's measurement; the visible region still applies.
        func reset() { content = nil; last = nil }
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
    /// decreases and the bottom gets farther away, either while the reader drives the scroll (iOS 18,
    /// macOS 15 scroll phase) or with the limit unchanged, which only scrolling produces. Layout that
    /// changes the limit is not reading history, even when it also lowers the offset: focusing the
    /// composer shifts the offset a few points in the same update as the keyboard inset grows.
    ///
    /// Returns whether layout pushed the bottom away from a pinned reader, who should be returned there.
    @discardableResult
    mutating func observe(from old: Edge, to new: Edge) -> Bool {
        let layoutChanged = new.limit != old.limit
        nearBottom = new.distance <= Self.nearBottomTolerance
        if nearBottom { pinned = true }
        else if new.offset < old.offset && new.distance > old.distance && (userScrolling || !layoutChanged) { pinned = false }
        return layoutChanged && pinned && !nearBottom && !userScrolling
    }

    /// iOS 18 and macOS 15 scroll phase: the reader is touching, dragging or flinging the transcript.
    mutating func observeScrolling(_ scrolling: Bool) { userScrolling = scrolling }
}

@available(iOS 18, macOS 15, *)
extension ScrollPhase {
    /// Touch, drag or fling driven by the reader rather than a programmatic scroll.
    var isUserDriven: Bool { self == .tracking || self == .interacting || self == .decelerating }
}
