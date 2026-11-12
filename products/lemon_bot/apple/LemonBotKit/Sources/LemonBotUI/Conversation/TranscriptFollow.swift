import SwiftUI

/// Whether the transcript keeps the latest message in view as content arrives.
///
/// The reader follows while pinned to the bottom: on open, after an intentional send, after
/// Jump to latest, or whenever the bottom comes back into view. Only scrolling toward older
/// content unpins it. A growing streamed reply, a new row, or the keyboard and composer shrinking
/// the viewport push the bottom out of view without moving the offset, so they are not mistaken
/// for reading history. While the reader drags or a fling decelerates nothing scrolls programmatically.
struct TranscriptFollow: Equatable {
    /// Bottom distance, in points, still treated as being at the latest message.
    static let nearBottomTolerance: CGFloat = 40
    /// iOS 17 and macOS 14 report only the lazy bottom marker's appearance, not scroll geometry or
    /// phase. A just-lost marker stays followable this long so growth pushing it out of view is
    /// not mistaken for scrolling away.
    static let markerGrace: TimeInterval = 0.2

    /// Scroll geometry reduced to what following needs, rounded so sub-point jitter is not a change.
    struct Edge: Equatable {
        var offset: CGFloat
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
    }

    static var tracksScrollGeometry: Bool {
        if #available(iOS 18, macOS 15, *) { return true }
        return false
    }

    private(set) var pinned = true
    private(set) var nearBottom = true
    private(set) var userScrolling = false
    private var leftBottomAt: Date?

    var showsJumpToLatest: Bool { !pinned && !nearBottom }

    func shouldFollow(now: Date = .now) -> Bool {
        guard !userScrolling else { return false }
        if pinned || nearBottom { return true }
        return leftBottomAt.map { now.timeIntervalSince($0) < Self.markerGrace } ?? false
    }

    /// Initial open, an intentional send, or Jump to latest.
    mutating func pin() { pinned = true; leftBottomAt = nil }

    /// Explicit navigation to older content (Find, a linked entry, Load older). The bottom is treated
    /// as out of view until geometry reports otherwise, so a reply arriving before the navigation
    /// lands cannot pull the reader back.
    mutating func release() { pinned = false; nearBottom = false; leftBottomAt = nil }

    /// iOS 18 and macOS 15 scroll geometry: returning to the bottom pins; only an offset moving
    /// toward older content unpins.
    mutating func observe(from old: Edge, to new: Edge) {
        nearBottom = new.distance <= Self.nearBottomTolerance
        if nearBottom { pin() } else if new.offset < old.offset { pinned = false }
    }

    /// iOS 18 and macOS 15 scroll phase: the reader is touching, dragging or flinging the transcript.
    mutating func observeScrolling(_ scrolling: Bool) { userScrolling = scrolling }

    /// iOS 17 and macOS 14 fallback: lazy bottom-marker visibility is the only signal.
    mutating func observeBottomMarker(visible: Bool, now: Date = .now) {
        nearBottom = visible
        if visible { pin() } else { pinned = false; leftBottomAt = now }
    }
}

@available(iOS 18, macOS 15, *)
extension ScrollPhase {
    /// Touch, drag or fling driven by the reader rather than a programmatic scroll.
    var isUserDriven: Bool { self == .tracking || self == .interacting || self == .decelerating }
}
