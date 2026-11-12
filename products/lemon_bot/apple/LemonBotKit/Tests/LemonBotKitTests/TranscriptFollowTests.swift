import XCTest
@testable import LemonBotUI

final class TranscriptFollowTests: XCTestCase {
    private func edge(offset: CGFloat, content: CGFloat, container: CGFloat = 600, inset: CGFloat = 0) -> TranscriptFollow.Edge {
        TranscriptFollow.Edge(offset: offset, contentHeight: content, bottomInset: inset, containerHeight: container)
    }

    func testStreamingGrowthAndKeyboardDoNotUnpinTheReaderAtTheBottom() {
        var follow = TranscriptFollow()
        let bottom = edge(offset: 400, content: 1000)
        // A streamed reply grows the content past the tolerance without moving the offset.
        follow.observe(from: bottom, to: edge(offset: 400, content: 1200))
        XCTAssertFalse(follow.nearBottom)
        XCTAssertTrue(follow.shouldFollow())
        XCTAssertFalse(follow.showsJumpToLatest)
        // The keyboard and composer add a bottom inset without moving the offset.
        follow.observe(from: edge(offset: 400, content: 1200), to: edge(offset: 400, content: 1200, container: 300, inset: 336))
        XCTAssertTrue(follow.shouldFollow())
    }

    func testScrollingTowardOlderContentStopsFollowingUntilTheBottomReturns() {
        var follow = TranscriptFollow()
        follow.observe(from: edge(offset: 400, content: 1000), to: edge(offset: 300, content: 1000))
        XCTAssertFalse(follow.shouldFollow())
        XCTAssertTrue(follow.showsJumpToLatest)
        // Content arriving while reading history keeps the reader where they are.
        follow.observe(from: edge(offset: 300, content: 1000), to: edge(offset: 300, content: 1400))
        XCTAssertFalse(follow.shouldFollow())
        // Returning to within the tolerance of the bottom resumes following.
        follow.observe(from: edge(offset: 300, content: 1400), to: edge(offset: 780, content: 1400))
        XCTAssertTrue(follow.nearBottom)
        XCTAssertTrue(follow.shouldFollow())
        XCTAssertFalse(follow.showsJumpToLatest)
    }

    func testSmallDragWithinToleranceStaysPinnedButNeverScrollsDuringTheDrag() {
        var follow = TranscriptFollow()
        follow.observeScrolling(true)
        follow.observe(from: edge(offset: 400, content: 1000), to: edge(offset: 370, content: 1000))
        XCTAssertTrue(follow.pinned)
        XCTAssertFalse(follow.shouldFollow())
        follow.observeScrolling(false)
        XCTAssertTrue(follow.shouldFollow())
    }

    func testExplicitNavigationReleasesAndSendOrJumpToLatestRepins() {
        var follow = TranscriptFollow()
        follow.release()
        XCTAssertFalse(follow.shouldFollow())
        XCTAssertTrue(follow.showsJumpToLatest)
        follow.pin()
        XCTAssertTrue(follow.shouldFollow())
        XCTAssertFalse(follow.showsJumpToLatest)
    }

    func testBottomMarkerFallbackFollowsBrieflyAfterGrowthHidesTheMarker() {
        var follow = TranscriptFollow()
        let hidden = Date(timeIntervalSince1970: 1_000)
        follow.observeBottomMarker(visible: false, now: hidden)
        XCTAssertTrue(follow.shouldFollow(now: hidden.addingTimeInterval(0.1)))
        XCTAssertFalse(follow.shouldFollow(now: hidden.addingTimeInterval(TranscriptFollow.markerGrace + 0.1)))
        XCTAssertTrue(follow.showsJumpToLatest)
        follow.observeBottomMarker(visible: true)
        XCTAssertTrue(follow.shouldFollow(now: hidden.addingTimeInterval(10)))
    }
}
