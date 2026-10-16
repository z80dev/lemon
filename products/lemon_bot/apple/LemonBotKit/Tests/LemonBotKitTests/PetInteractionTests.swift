import CoreGraphics
import XCTest
@testable import LemonBotKit

final class PetInteractionTests: XCTestCase {
    // MARK: Click-through

    /// A 96x104-px image whose left half is opaque and right half transparent, drawn from the top.
    private func image(opaque: CGRect) -> CGImage {
        let context = CGContext(data: nil, width: 96, height: 104, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.clear(CGRect(x: 0, y: 0, width: 96, height: 104))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 0, alpha: 1))
        context.fill(opaque)
        return context.makeImage()!
    }

    func testAlphaMaskSeparatesOpaquePixelsFromTransparentOnes() {
        // CGContext origin is bottom-left, like the view coordinates the mask is queried in.
        let mask = PetAlphaMask(image(opaque: CGRect(x: 0, y: 0, width: 48, height: 52)))
        XCTAssertTrue(mask.opaque(x: 0.25, y: 0.25))
        XCTAssertFalse(mask.opaque(x: 0.75, y: 0.25), "transparent right half passes clicks through")
        XCTAssertFalse(mask.opaque(x: 0.25, y: 0.75), "transparent top passes clicks through")
        XCTAssertTrue(mask.opaque(x: -1, y: 0), "out-of-range fractions clamp to the edge pixel")
        XCTAssertEqual(mask.topFraction, 0.5, accuracy: 0.02, "artwork top sits halfway down the cell")
        XCTAssertEqual(PetAlphaMask(image(opaque: .zero)).topFraction, 1, "an empty frame anchors at the cell top")
    }

    func testFaintPixelsBelowThresholdAreTransparent() {
        let context = CGContext(data: nil, width: 96, height: 104, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 20.0 / 255))
        context.fill(CGRect(x: 0, y: 0, width: 96, height: 104))
        XCTAssertFalse(PetAlphaMask(context.makeImage()!).opaque(x: 0.5, y: 0.5))
    }

    func testSpriteAndBubbleHitTestingUseFramesAndMask() {
        let mask = PetAlphaMask(image(opaque: CGRect(x: 0, y: 0, width: 48, height: 104)))
        let sprite = CGRect(x: 50, y: 10, width: 96, height: 104)
        XCTAssertTrue(PetHitTesting.hitsSprite(CGPoint(x: 60, y: 60), spriteFrame: sprite, mask: mask))
        XCTAssertFalse(PetHitTesting.hitsSprite(CGPoint(x: 140, y: 60), spriteFrame: sprite, mask: mask), "transparent half of the sprite")
        XCTAssertFalse(PetHitTesting.hitsSprite(CGPoint(x: 10, y: 60), spriteFrame: sprite, mask: mask), "outside the sprite rect")
        XCTAssertFalse(PetHitTesting.hitsSprite(CGPoint(x: 60, y: 60), spriteFrame: sprite, mask: nil), "no decoded frame yet")
        let bubble = CGRect(x: 12, y: 120, width: 180, height: 40)
        XCTAssertTrue(PetHitTesting.hitsBubble(CGPoint(x: 20, y: 130), bubbleFrame: bubble, bubbleHidden: false))
        XCTAssertFalse(PetHitTesting.hitsBubble(CGPoint(x: 20, y: 130), bubbleFrame: bubble, bubbleHidden: true), "a hidden bubble never catches clicks")
        XCTAssertFalse(PetHitTesting.hitsBubble(CGPoint(x: 5, y: 130), bubbleFrame: bubble, bubbleHidden: false))
    }

    func testPanelIgnoresMouseUnlessOverVisiblePixelsOrDragging() {
        XCTAssertTrue(PetHitTesting.ignoresMouseEvents(dragging: false, overSprite: false, overBubble: false))
        XCTAssertFalse(PetHitTesting.ignoresMouseEvents(dragging: false, overSprite: true, overBubble: false))
        XCTAssertFalse(PetHitTesting.ignoresMouseEvents(dragging: false, overSprite: false, overBubble: true))
        XCTAssertFalse(PetHitTesting.ignoresMouseEvents(dragging: true, overSprite: false, overBubble: false), "the pointer may outrun the panel while dragging")
    }

    func testGazeFollowsOnlyAnIdleUnhoveredPetWithinRange() throws {
        XCTAssertNil(PetGaze.degrees(dx: 10, dy: 10), "too close")
        XCTAssertNil(PetGaze.degrees(dx: 300, dy: 0), "too far")
        XCTAssertEqual(try XCTUnwrap(PetGaze.degrees(dx: 0, dy: 100)), 0, accuracy: 0.001, "straight up")
        XCTAssertEqual(try XCTUnwrap(PetGaze.degrees(dx: 100, dy: 0)), 90, accuracy: 0.001, "right")
        XCTAssertEqual(try XCTUnwrap(PetGaze.degrees(dx: -100, dy: 0)), -90, accuracy: 0.001, "left")
        XCTAssertTrue(PetGaze.follows(reducedMotion: false, mood: .idle, hovered: false, oneShot: false))
        XCTAssertFalse(PetGaze.follows(reducedMotion: true, mood: .idle, hovered: false, oneShot: false))
        XCTAssertFalse(PetGaze.follows(reducedMotion: false, mood: .working, hovered: false, oneShot: false))
        XCTAssertFalse(PetGaze.follows(reducedMotion: false, mood: .idle, hovered: true, oneShot: false))
        XCTAssertFalse(PetGaze.follows(reducedMotion: false, mood: .idle, hovered: false, oneShot: true))
    }

    // MARK: Drag and click

    func testPressWithoutMovementIsAClick() {
        var tracker = PetDragTracker()
        tracker.begin(pointer: CGPoint(x: 100, y: 100), panelOrigin: CGPoint(x: 500, y: 500))
        XCTAssertNil(tracker.drag(to: CGPoint(x: 102, y: 101)), "within the 3-point threshold")
        XCTAssertFalse(tracker.isDragging)
        XCTAssertEqual(tracker.end(), .click)
        XCTAssertEqual(tracker.end(), .none, "a second release without a press does nothing")
    }

    func testDragMovesPanelWithPointerAndPicksRunDirection() throws {
        var tracker = PetDragTracker()
        tracker.begin(pointer: CGPoint(x: 100, y: 100), panelOrigin: CGPoint(x: 500, y: 500))
        let first = try XCTUnwrap(tracker.drag(to: CGPoint(x: 110, y: 90)))
        XCTAssertEqual(first.origin, CGPoint(x: 510, y: 490))
        XCTAssertEqual(first.direction, .runningRight)
        XCTAssertTrue(tracker.isDragging)
        let back = try XCTUnwrap(tracker.drag(to: CGPoint(x: 80, y: 90)))
        XCTAssertEqual(back.origin, CGPoint(x: 480, y: 490))
        XCTAssertEqual(back.direction, .runningLeft)
        let small = try XCTUnwrap(tracker.drag(to: CGPoint(x: 81, y: 90)), "once dragging, the threshold no longer applies")
        XCTAssertEqual(small.direction, .runningRight)
        XCTAssertEqual(tracker.end(), .dragEnded, "releasing after a drag never clicks")
        XCTAssertFalse(tracker.isDragging)
        XCTAssertNil(tracker.drag(to: CGPoint(x: 200, y: 200)), "movement without a press is ignored")
    }

    func testClickOnlyFiresOncePerPress() {
        var tracker = PetDragTracker()
        tracker.begin(pointer: .zero, panelOrigin: .zero)
        XCTAssertEqual(tracker.end(), .click)
        tracker.begin(pointer: .zero, panelOrigin: .zero)
        _ = tracker.drag(to: CGPoint(x: 10, y: 0))
        XCTAssertEqual(tracker.end(), .dragEnded)
        tracker.begin(pointer: .zero, panelOrigin: .zero)
        XCTAssertEqual(tracker.end(), .click, "a drag does not leak into the next press")
    }

    func testPlacementClampsDefaultsAndOffsets() {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 850)
        let size = CGSize(width: 204, height: 180)
        XCTAssertEqual(PetPlacement.defaultOrigin(panelWidth: 204, visible: visible), CGPoint(x: 1440 - 204 - 24, y: 25 + 24))
        XCTAssertEqual(PetPlacement.clamp(origin: CGPoint(x: 300, y: 300), size: size, visible: visible), CGPoint(x: 300, y: 300))
        XCTAssertEqual(PetPlacement.clamp(origin: CGPoint(x: -50, y: 0), size: size, visible: visible), CGPoint(x: 0, y: 25))
        XCTAssertEqual(PetPlacement.clamp(origin: CGPoint(x: 5000, y: 5000), size: size, visible: visible), CGPoint(x: 1440 - 204, y: 25 + 850 - 180))
        XCTAssertEqual(PetPlacement.clamp(origin: CGPoint(x: 9, y: 9), size: CGSize(width: 2000, height: 2000), visible: visible), CGPoint(x: 0, y: 25), "oversized panel pins to the corner")
        let secondary = CGRect(x: 1440, y: -200, width: 1920, height: 1080)
        let offset = PetPlacement.offset(of: CGPoint(x: 1500, y: -100), in: secondary)
        XCTAssertEqual(offset, CGPoint(x: 60, y: 100))
        XCTAssertEqual(PetPlacement.origin(forOffset: offset, in: secondary), CGPoint(x: 1500, y: -100))
        let shrunk = CGRect(x: 1440, y: -200, width: 1920, height: 1040)
        XCTAssertEqual(PetPlacement.origin(forOffset: offset, in: shrunk), CGPoint(x: 1500, y: -100), "saved offsets survive a usable-area change")
    }

    // MARK: Click-to-open

    func testClickOpensStatusDeepLinkOrWorkspace() throws {
        let link = try XCTUnwrap(URL(string: "lemonbot://workspace/w/bot/b?conversationId=c"))
        XCTAssertEqual(PetClickAction.resolve(PetStatus(mood: .needsInput, bubble: "Needs approval", deepLink: link)), .route(link))
        XCTAssertEqual(PetClickAction.resolve(PetStatus(mood: .idle)), .openWorkspace)
        XCTAssertEqual(PetClickAction.resolve(PetStatus(mood: .signedOut, bubble: "Sign in to Lemon Bot")), .openWorkspace)
    }

    // MARK: Live run events

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var ms: Double { now.timeIntervalSince1970 * 1000 }
    private func run(_ status: String, age: Double = 0) -> Run {
        Run(id: "run", revision: 1, createdAtMs: ms - age * 1000, updatedAtMs: ms, conversationId: "conversation", botId: "bot", initiatorUserId: "user", clientNonce: "nonce", status: status, completedAtMs: ["succeeded", "failed"].contains(status) ? ms - age * 1000 : nil)
    }
    private func tool(_ status: String) -> TranscriptEntry {
        .toolCall(ToolCallEntry(id: "tool", revision: 1, createdAtMs: ms, updatedAtMs: ms, conversationId: "conversation", seq: 1, timestampMs: ms, actor: Actor(kind: "bot", id: "bot", displayName: "Atlas"), runId: "run", reactions: [], tool: "bash", title: "Run command", status: status))
    }
    private func derive(connection: String = "online", runs: [Run], entries: [ID: [TranscriptEntry]] = [:], at: Date? = nil) -> PetStatus {
        PetActivity.status(signedIn: true, connectionState: connection, userID: "user", workspaceID: "workspace", bots: [], runs: runs, notifications: [], entries: entries, now: at ?? now)
    }

    /// The controller's reaction to each pushed status, replayed without a GUI.
    private struct Replay {
        var status = PetStatus(mood: .idle)
        var donePlayed = false
        var sounds: [String] = []
        var plays: [PetAnimation] = []
        mutating func apply(_ next: PetStatus) {
            guard let change = PetReaction.change(from: status, to: next) else { return }
            status = next
            guard change.moodChanged else { return }
            donePlayed = false
            if let sound = PetReaction.soundName(for: next.mood) { sounds.append(sound) }
            let plan = PetReaction.animation(for: next.mood, donePlayed: donePlayed)
            plays.append(plan.animation)
        }
    }

    func testRunEventsDriveMoodAnimationAndSoundCues() {
        var replay = Replay()
        replay.apply(derive(runs: [run("queued")]))
        replay.apply(derive(runs: [run("running")]))
        replay.apply(derive(runs: [run("running")], entries: ["conversation": [tool("started")]]))
        replay.apply(derive(runs: [run("running")], entries: ["conversation": [tool("started")]]))
        replay.apply(derive(runs: [run("awaiting_input")]))
        replay.apply(derive(runs: [run("succeeded")]))
        XCTAssertEqual(replay.status.mood, .done)
        XCTAssertEqual(replay.plays, [.review, .running, .waiting, .jumping], "queued to running and repeated tool deltas keep the same mood, so the animation is not restarted")
        XCTAssertEqual(replay.sounds, ["Tink", "Pop"], "only attention and completion cues sound; thinking and working are silent")
        replay.apply(derive(runs: [run("succeeded", age: 10)], at: now.addingTimeInterval(10)))
        XCTAssertEqual(replay.status.mood, .idle)
        replay.apply(derive(runs: [run("failed")]))
        XCTAssertEqual(replay.sounds, ["Tink", "Pop", "Basso"])
        replay.apply(derive(connection: "disconnected", runs: [run("failed")]))
        XCTAssertEqual(replay.status.mood, .offline)
        XCTAssertEqual(replay.sounds.count, 3, "going offline is silent")
    }

    func testStatusChangeDistinguishesDetailUpdatesFromMoodChanges() {
        let working = PetStatus(mood: .working, detail: "Atlas · Read file")
        XCTAssertNil(PetReaction.change(from: working, to: working))
        XCTAssertEqual(PetReaction.change(from: working, to: PetStatus(mood: .working, detail: "Atlas · Writing a reply")), .init(moodChanged: false), "a new step updates the bubble without restarting the animation")
        XCTAssertEqual(PetReaction.change(from: working, to: PetStatus(mood: .failed, bubble: "Run failed")), .init(moodChanged: true))
    }

    func testDoneJumpsOnceThenRests() {
        XCTAssertTrue(PetReaction.animation(for: .done, donePlayed: false) == (.jumping, true))
        XCTAssertTrue(PetReaction.animation(for: .done, donePlayed: true) == (.idle, false))
        XCTAssertTrue(PetReaction.animation(for: .working, donePlayed: true) == (.running, false))
        XCTAssertTrue(PetReaction.animation(for: .signedOut, donePlayed: false) == (.idle, false))
    }

    func testExpiryDelayTracksValidUntilWithFloor() {
        XCTAssertNil(PetReaction.expiryDelay(PetStatus(mood: .idle), now: now))
        XCTAssertEqual(PetReaction.expiryDelay(PetStatus(mood: .done, validUntil: now.addingTimeInterval(4)), now: now), 4)
        XCTAssertEqual(PetReaction.expiryDelay(PetStatus(mood: .done, validUntil: now.addingTimeInterval(-5)), now: now), 0.05, "an already-expired status refreshes promptly")
        let done = derive(runs: [run("succeeded", age: 2)])
        XCTAssertEqual(PetReaction.expiryDelay(done, now: now), 4, "the derived completion status asks for a refresh when it expires")
    }

    func testSoundCuesAreOnlyForAttentionCompletionAndFailure() {
        let cues = Dictionary(uniqueKeysWithValues: PetMood.allCases.map { ($0, PetReaction.soundName(for: $0)) })
        XCTAssertEqual(cues[.needsInput], "Tink"); XCTAssertEqual(cues[.done], "Pop"); XCTAssertEqual(cues[.failed], "Basso")
        for mood in [PetMood.idle, .thinking, .working, .offline, .signedOut] { XCTAssertNil(cues[mood] ?? nil) }
    }
}
