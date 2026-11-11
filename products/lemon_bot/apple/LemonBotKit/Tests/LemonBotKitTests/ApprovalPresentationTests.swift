import XCTest
import LemonBotKit
@testable import LemonBotUI

final class ApprovalPresentationTests: XCTestCase {
    private func approval(command: String? = "pwd") throws -> Approval {
        let cards = try JSONDecoder().decode([Card].self, from: WireFixtures.cards)
        guard case .accessRequest(let card) = try XCTUnwrap(cards.first { $0.type == "access_request" }) else {
            throw NSError(domain: "ApprovalPresentationTests", code: 1)
        }
        var proposal = card.approval
        proposal.source = "lemon_exec"
        proposal.target = "Terminal"
        proposal.title = "Harmless-looking truncated title…"
        proposal.inputs = command.map { ["command": .string($0)] } ?? [:]
        return proposal
    }

    func testCompleteCommandIncludesDestructiveTailAndNeverChangesPayload() throws {
        let command = "printf '" + String(repeating: "safe", count: 60) + "'\nrm -rf ~/important"
        let proposal = try approval(command: command)
        let original = proposal
        let review = ApprovalReviewPresentation(proposal)
        XCTAssertEqual(review.text.text, command)
        XCTAssertTrue(review.text.text.hasSuffix("\nrm -rf ~/important"))
        XCTAssertFalse(review.text.preview.contains("rm -rf"))
        XCTAssertTrue(review.text.truncated)
        XCTAssertFalse(review.allowsApproval(expanded: nil))
        XCTAssertTrue(review.allowsApproval(expanded: review.identity))
        XCTAssertEqual(proposal, original)
        XCTAssertEqual(proposal.inputs["command"]?.stringValue, command)
    }

    func testNewlinesTabsAndLiteralMarkdownRemainIntact() {
        let command = "echo **literal**\n\tprintf '[link](https://example.test)'\n"
        let presentation = ApprovalTextPresentation(command)
        XCTAssertEqual(presentation.text, command)
        XCTAssertEqual(presentation.preview, command)
        XCTAssertFalse(presentation.hasControls)
        XCTAssertFalse(presentation.truncated)
        XCTAssertEqual(ApprovalTextPresentation.isolated("first\n\tsecond\n"), "\u{2066}first\u{2069}\n\u{2066}\tsecond\u{2069}\n\u{2066}\u{2069}")
    }

    func testControlEscapingIncludesAllC0AndC1ExceptLineFeedAndTab() {
        for code in UInt32(0)...0x9F where code < 0x20 || code >= 0x7F {
            let raw = String(Unicode.Scalar(code)!)
            let presentation = ApprovalTextPresentation(raw)
            if code == 0x09 || code == 0x0A {
                XCTAssertEqual(presentation.text, raw)
                XCTAssertFalse(presentation.hasControls)
            } else {
                XCTAssertEqual(presentation.text, "⟨U+\(String(format: "%04X", code))⟩")
                XCTAssertTrue(presentation.hasControls)
            }
        }
    }

    func testBidiFormatDefaultIgnorableAndParagraphControlsAreVisible() {
        let controls: [UInt32] = [
            0x00AD, 0x034F, 0x061C, 0x115F, 0x17B4, 0x180B, 0x200B, 0x200D,
            0x2028, 0x2029, 0x202E, 0x2066, 0x2069, 0xFE0F, 0xFEFF, 0xFFF0,
            0x1BCA0, 0x1D173, 0xE0001, 0xE0100
        ]
        for code in controls {
            let raw = "before" + String(Unicode.Scalar(code)!) + "after"
            let presentation = ApprovalTextPresentation(raw)
            XCTAssertEqual(presentation.text, "before⟨U+\(String(format: "%04X", code))⟩after")
            XCTAssertTrue(presentation.hasControls)
            XCTAssertTrue(raw.unicodeScalars.contains { $0.value == code })
        }
    }

    func testPreviewBoundaryCountsCodePointsNotGraphemesOrUTF16() {
        let boundary = String(repeating: "🙂", count: 160)
        XCTAssertFalse(ApprovalTextPresentation(boundary).truncated)
        XCTAssertEqual(ApprovalTextPresentation(boundary).preview, boundary)
        let longer = ApprovalTextPresentation(boundary + "x")
        XCTAssertTrue(longer.truncated)
        XCTAssertEqual(longer.preview, String(repeating: "🙂", count: 159) + "…")
        XCTAssertEqual(longer.preview.unicodeScalars.count, 160)
        let combining = ApprovalTextPresentation(String(repeating: "e\u{0301}", count: 81))
        XCTAssertTrue(combining.truncated)
        XCTAssertEqual(combining.preview.unicodeScalars.count, 160)
        let escaped = ApprovalTextPresentation(String(repeating: "\u{202E}", count: 21))
        XCTAssertTrue(escaped.truncated)
        XCTAssertEqual(escaped.preview.unicodeScalars.count, 160)
        XCTAssertEqual(escaped.text, String(repeating: "⟨U+202E⟩", count: 21))
    }

    func testChangedCommandRevisionOrApprovalRequiresExpansionAgain() throws {
        var proposal = try approval(command: String(repeating: "x", count: 161))
        let reviewed = ApprovalReviewPresentation(proposal)
        proposal.revision += 1
        XCTAssertFalse(ApprovalReviewPresentation(proposal).allowsApproval(expanded: reviewed.identity))
        proposal.revision -= 1
        proposal.inputs["command"] = .string(String(repeating: "x", count: 160) + "y")
        XCTAssertFalse(ApprovalReviewPresentation(proposal).allowsApproval(expanded: reviewed.identity))
        proposal.inputs["command"] = .string(reviewed.identity.value)
        proposal.id += "-new"
        XCTAssertFalse(ApprovalReviewPresentation(proposal).allowsApproval(expanded: reviewed.identity))
        XCTAssertFalse(reviewed.allowsApproval(expanded: nil))
    }

    func testReviewIdentityUsesExactScalarsRatherThanCanonicalStringEquality() throws {
        let prefix = String(repeating: "x", count: 161)
        let composed = ApprovalReviewPresentation(try approval(command: prefix + "é"))
        let decomposed = ApprovalReviewPresentation(try approval(command: prefix + "e\u{0301}"))
        XCTAssertNotEqual(composed.identity, decomposed.identity)
        XCTAssertFalse(decomposed.allowsApproval(expanded: composed.identity))
    }

    func testMissingTerminalCommandFailsClosedEvenWithExpandedTitle() throws {
        var proposal = try approval(command: nil)
        let missing = ApprovalReviewPresentation(proposal)
        XCTAssertEqual(missing.text.text, proposal.title)
        XCTAssertTrue(missing.missingCommand)
        XCTAssertFalse(missing.allowsApproval(expanded: missing.identity))
        proposal.inputs["command"] = .null
        XCTAssertFalse(ApprovalReviewPresentation(proposal).allowsApproval(expanded: nil))
        proposal.inputs["command"] = .string("")
        XCTAssertFalse(ApprovalReviewPresentation(proposal).allowsApproval(expanded: nil))
        proposal.target = "Files"
        XCTAssertTrue(ApprovalReviewPresentation(proposal).allowsApproval(expanded: nil))
    }

    func testShortCommandIsEligibleWithoutExpansionAndAccessRequestsStayUnchanged() throws {
        let short = ApprovalReviewPresentation(try approval())
        XCTAssertTrue(short.allowsApproval(expanded: nil))
        var access = try approval(command: nil)
        access.source = "access_request"
        access.title = String(repeating: "x", count: 200)
        let presentation = ApprovalReviewPresentation(access)
        XCTAssertTrue(presentation.allowsApproval(expanded: nil))
        XCTAssertFalse(presentation.missingCommand)
    }
}
