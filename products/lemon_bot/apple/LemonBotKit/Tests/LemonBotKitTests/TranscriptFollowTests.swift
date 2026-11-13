import XCTest
@testable import LemonBotUI

final class TranscriptFollowTests: XCTestCase {
    private func edge(offset: CGFloat, content: CGFloat, container: CGFloat = 600, inset: CGFloat = 0) -> TranscriptFollow.Edge {
        TranscriptFollow.Edge(offset: offset, contentHeight: content, bottomInset: inset, containerHeight: container)
    }

    func testLayoutThatPushesThePinnedBottomAwayReturnsThereWithoutUnpinning() {
        var follow = TranscriptFollow()
        let bottom = edge(offset: 400, content: 1000)
        // A streamed reply grows the content past the tolerance without moving the offset.
        XCTAssertTrue(follow.observe(from: bottom, to: edge(offset: 400, content: 1200)))
        XCTAssertFalse(follow.nearBottom)
        XCTAssertTrue(follow.shouldFollow)
        XCTAssertFalse(follow.showsJumpToLatest)
        // The keyboard and composer add a bottom inset and shrink the container.
        XCTAssertTrue(follow.observe(from: edge(offset: 600, content: 1200), to: edge(offset: 600, content: 1200, container: 300, inset: 336)))
        XCTAssertTrue(follow.shouldFollow)
        // Lazy rows measured above the viewport move the offset with the limit; clamping as the inset shrinks lowers both.
        XCTAssertFalse(follow.observe(from: edge(offset: 600, content: 1200), to: edge(offset: 560, content: 1160)))
        XCTAssertTrue(follow.observe(from: edge(offset: 936, content: 1200, container: 300, inset: 336), to: edge(offset: 880, content: 1200, container: 300, inset: 200)))
        XCTAssertTrue(follow.pinned)
        // An inset change that keeps the bottom in view needs no scroll.
        XCTAssertFalse(follow.observe(from: edge(offset: 600, content: 1200), to: edge(offset: 600, content: 1200, inset: 20)))
    }

    func testFocusingTheComposerLowersTheOffsetWithTheKeyboardInsetWithoutUnpinning() {
        // Recorded on iPhone: focusing the composer shifts the transcript down a few points in the
        // same update as the keyboard inset grows, while nobody touches the transcript.
        var follow = TranscriptFollow()
        let bottom = edge(offset: 490, content: 1000, inset: 90)
        XCTAssertEqual(bottom.distance, 0)
        XCTAssertTrue(follow.observe(from: bottom, to: edge(offset: 483, content: 1000, inset: 419)))
        XCTAssertTrue(follow.pinned)
        XCTAssertFalse(follow.showsJumpToLatest)
        XCTAssertTrue(follow.shouldFollow)
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

    func testContentSideMeasurementMatchesScrollGeometryIncludingTheBottomInset() {
        // iOS 17 and macOS 14 see the scroll view's full bounds from the content; the composer and keyboard inset is added separately.
        let atBottom = TranscriptFollow.Edge(contentHeight: 1000, scrollBounds: CGRect(x: 0, y: 500, width: 390, height: 600)).covered(byBottomInset: 100)
        XCTAssertEqual(atBottom, edge(offset: 500, content: 1000, inset: 100))
        XCTAssertEqual(atBottom.distance, 0)

        var follow = TranscriptFollow()
        // Reading 300 points up with the keyboard open is not "near the bottom" even though the inset region still shows content.
        let reading = TranscriptFollow.Edge(contentHeight: 1000, scrollBounds: CGRect(x: 0, y: 500, width: 390, height: 600)).covered(byBottomInset: 400)
        follow.observe(from: edge(offset: 800, content: 1000, inset: 400), to: reading)
        XCTAssertFalse(follow.nearBottom)
        XCTAssertFalse(follow.shouldFollow)
    }

    func testFallbackKeyboardInsetAloneReturnsAPinnedReaderToTheBottom() throws {
        let history = TranscriptFollow.EdgeHistory()
        XCTAssertNil(history.record(inset: 80), "No comparison before the content is measured")
        let measured = TranscriptFollow.Edge(contentHeight: 1000, scrollBounds: CGRect(x: 0, y: 480, width: 390, height: 600))
        let first = try XCTUnwrap(history.record(measured: measured))
        XCTAssertEqual(first.old, first.new)
        XCTAssertEqual(first.new.distance, 0)
        // The keyboard raises the inset; the content measurement does not change.
        let keyboard = try XCTUnwrap(history.record(inset: 380))
        var follow = TranscriptFollow()
        XCTAssertTrue(follow.observe(from: keyboard.old, to: keyboard.new))
        XCTAssertTrue(follow.pinned)
        history.reset()
        XCTAssertNil(history.record(inset: 380), "A reopened transcript is never compared with the previous one")
    }
}
