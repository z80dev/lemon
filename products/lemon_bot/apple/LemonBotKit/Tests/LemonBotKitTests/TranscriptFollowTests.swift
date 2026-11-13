import XCTest
import SwiftUI
@testable import LemonBotUI

final class TranscriptFollowTests: XCTestCase {
    /// `visible` is the scroll view's height inside its navigation bar, composer and keyboard insets.
    private func edge(offset: CGFloat, content: CGFloat, visible: CGFloat = 600) -> TranscriptFollow.Edge {
        TranscriptFollow.Edge(offset: offset, limit: content - visible)
    }

    func testRecordedIPhoneScrollGeometryKeepsFollowingThroughComposerFocusAndKeyboard() throws {
        guard #available(iOS 18, macOS 15, *) else { throw XCTSkip("ScrollGeometry needs iOS 18 or macOS 15") }
        // Raw values traced on iPhone: the container already excludes the top and bottom insets.
        func geometry(offset: CGFloat, container: CGFloat, bottom: CGFloat) -> ScrollGeometry {
            ScrollGeometry(contentOffset: CGPoint(x: 0, y: offset), contentSize: CGSize(width: 402, height: 1734),
                           contentInsets: EdgeInsets(top: 116, leading: 0, bottom: bottom, trailing: 0), containerSize: CGSize(width: 402, height: container))
        }
        XCTAssertEqual(TranscriptFollow.Edge(geometry(offset: -116, container: 650, bottom: 108)).offset, 0, "The top of the content")
        let settled = TranscriptFollow.Edge(geometry(offset: 955.6667, container: 650, bottom: 108))
        XCTAssertEqual(settled.distance, 12, "The scroll view's bottom, above the stack's bottom padding")
        var follow = TranscriptFollow()
        XCTAssertFalse(follow.observe(from: settled, to: settled))
        XCTAssertTrue(follow.nearBottom)
        // Focusing the composer lowers the offset and the limit together, with nobody touching the transcript.
        let focused = TranscriptFollow.Edge(geometry(offset: 945.6667, container: 660, bottom: 98))
        XCTAssertFalse(follow.observe(from: settled, to: focused))
        XCTAssertTrue(follow.pinned)
        XCTAssertFalse(follow.showsJumpToLatest)
        // The keyboard hides the latest content; following returns there.
        let keyboard = TranscriptFollow.Edge(geometry(offset: 945.6667, container: 359, bottom: 399))
        XCTAssertEqual(keyboard.distance, 313)
        XCTAssertTrue(follow.observe(from: focused, to: keyboard))
        XCTAssertTrue(follow.pinned)
        XCTAssertFalse(follow.showsJumpToLatest)
    }

    func testLayoutThatPushesThePinnedBottomAwayReturnsThereWithoutUnpinning() {
        var follow = TranscriptFollow()
        // A streamed reply grows the content past the tolerance without moving the offset.
        XCTAssertTrue(follow.observe(from: edge(offset: 400, content: 1000), to: edge(offset: 400, content: 1200)))
        XCTAssertFalse(follow.nearBottom)
        XCTAssertTrue(follow.shouldFollow)
        XCTAssertFalse(follow.showsJumpToLatest)
        // Layout that lowers the offset while the limit grows is still not reading history.
        XCTAssertTrue(follow.observe(from: edge(offset: 600, content: 1200), to: edge(offset: 590, content: 1200, visible: 300)))
        XCTAssertTrue(follow.pinned)
        // Lazy rows measured above the viewport, and the keyboard closing, move the offset with the limit.
        XCTAssertFalse(follow.observe(from: edge(offset: 600, content: 1200), to: edge(offset: 560, content: 1160)))
        XCTAssertFalse(follow.observe(from: edge(offset: 900, content: 1200, visible: 300), to: edge(offset: 600, content: 1200)))
        XCTAssertTrue(follow.pinned)
        // A viewport change that keeps the bottom in view needs no scroll.
        XCTAssertFalse(follow.observe(from: edge(offset: 600, content: 1200), to: edge(offset: 600, content: 1200, visible: 580)))
    }

    func testScrollingTowardOlderContentStopsFollowingUntilTheBottomReturns() {
        var follow = TranscriptFollow()
        XCTAssertFalse(follow.observe(from: edge(offset: 400, content: 1000), to: edge(offset: 300, content: 1000)))
        XCTAssertFalse(follow.shouldFollow)
        XCTAssertTrue(follow.showsJumpToLatest)
        // Content arriving while reading history keeps the reader where they are.
        XCTAssertFalse(follow.observe(from: edge(offset: 300, content: 1000), to: edge(offset: 300, content: 1400)))
        XCTAssertFalse(follow.shouldFollow)
        // Returning to within the tolerance of the bottom resumes following.
        follow.observe(from: edge(offset: 300, content: 1400), to: edge(offset: 780, content: 1400))
        XCTAssertTrue(follow.nearBottom)
        XCTAssertTrue(follow.shouldFollow)
        XCTAssertFalse(follow.showsJumpToLatest)
        // Dragging up in the same update as a streamed token is still reading history.
        follow.observeScrolling(true)
        XCTAssertFalse(follow.observe(from: edge(offset: 780, content: 1400), to: edge(offset: 700, content: 1450)))
        follow.observeScrolling(false)
        XCTAssertFalse(follow.shouldFollow)
        XCTAssertTrue(follow.showsJumpToLatest)
    }

    func testSmallDragWithinToleranceStaysPinnedButNeverScrollsDuringTheDrag() {
        var follow = TranscriptFollow()
        follow.observeScrolling(true)
        follow.observe(from: edge(offset: 400, content: 1000), to: edge(offset: 370, content: 1000))
        XCTAssertTrue(follow.pinned)
        XCTAssertFalse(follow.shouldFollow)
        follow.observeScrolling(false)
        XCTAssertTrue(follow.shouldFollow)
    }

    func testExplicitNavigationReleasesAndSendOrJumpToLatestRepins() {
        var follow = TranscriptFollow()
        follow.release()
        XCTAssertFalse(follow.shouldFollow)
        XCTAssertTrue(follow.showsJumpToLatest)
        follow.pin()
        XCTAssertTrue(follow.shouldFollow)
        XCTAssertFalse(follow.showsJumpToLatest)
    }

    func testFallbackFramesKeepFollowingWhenTheKeyboardShrinksTheVisibleRegion() throws {
        // iOS 17 and macOS 14 compare global frames: the content, and the scroll view inside its safe-area insets.
        let history = TranscriptFollow.EdgeHistory()
        XCTAssertNil(history.record(visible: CGRect(x: 0, y: 116, width: 402, height: 650)), "No comparison before the content is measured")
        let first = try XCTUnwrap(history.record(content: CGRect(x: 0, y: -956, width: 402, height: 1734)))
        XCTAssertEqual(first.old, first.new)
        XCTAssertEqual(first.new.distance, 12)
        var follow = TranscriptFollow()
        // The keyboard shrinks the visible region; the content does not move.
        let keyboard = try XCTUnwrap(history.record(visible: CGRect(x: 0, y: 116, width: 402, height: 359)))
        XCTAssertEqual(keyboard.new.distance, 303)
        XCTAssertTrue(follow.observe(from: keyboard.old, to: keyboard.new))
        XCTAssertTrue(follow.pinned)
        // Scrolling moves the content frame down: reading history.
        let reading = try XCTUnwrap(history.record(content: CGRect(x: 0, y: -656, width: 402, height: 1734)))
        XCTAssertFalse(follow.observe(from: reading.old, to: reading.new))
        XCTAssertFalse(follow.shouldFollow)
        history.reset()
        XCTAssertNil(history.record(visible: CGRect(x: 0, y: 116, width: 402, height: 359)), "A reopened transcript is never compared with the previous one")
    }
}
