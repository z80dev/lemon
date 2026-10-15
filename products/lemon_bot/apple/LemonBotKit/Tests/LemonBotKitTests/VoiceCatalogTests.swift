import Foundation
import XCTest
import LemonBotKit
@testable import LemonBotUI

final class VoiceCatalogTests: XCTestCase {
    func testCatalogRequiresNullableProviderAndRoundTrips() throws {
        let data = Data(#"{"provider":null,"configured":false,"voices":[{"id":"default","name":"Provider default","languages":[]}]}"#.utf8)
        let catalog = try JSONDecoder().decode(VoiceCatalog.self, from: data)
        XCTAssertNil(catalog.provider)
        XCTAssertFalse(catalog.configured)
        XCTAssertEqual(catalog.voices.first?.id, "default")
        XCTAssertEqual(try JSONDecoder().decode(VoiceCatalog.self, from: JSONEncoder().encode(catalog)), catalog)
        XCTAssertEqual(try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(catalog))["provider"], .null)
        XCTAssertThrowsError(try JSONDecoder().decode(VoiceCatalog.self, from: Data(#"{"configured":false,"voices":[]}"#.utf8)))
    }

    @MainActor func testReadsProviderCatalogWithoutMutation() async throws {
        let store = await LemonBotFixtures.loadStore()
        let catalog: VoiceCatalog = try await store.read("/audio/voices")
        XCTAssertEqual(catalog.provider, "openai")
        XCTAssertTrue(catalog.configured)
        XCTAssertEqual(catalog.voices.map(\.id), ["default", "alloy", "coral"])
        XCTAssertTrue(store.pendingIntents.isEmpty)
    }

    func testPastedFileSummaryCapsNamesAndPreservesLongFilenameExtension() {
        let urls = (1...6).map { URL(fileURLWithPath: "/selected/File \($0).pdf") }
        XCTAssertEqual(pastedFileSummary([]), "")
        XCTAssertEqual(pastedFileSummary(Array(urls.prefix(1))), "File 1.pdf")
        XCTAssertEqual(pastedFileSummary(Array(urls.prefix(3))), "File 1.pdf\nFile 2.pdf\nFile 3.pdf")
        XCTAssertEqual(pastedFileSummary(urls), "File 1.pdf\nFile 2.pdf\nFile 3.pdf\nand 3 more")
        let long = pastedFileSummary([URL(fileURLWithPath: "/selected/" + String(repeating: "🟢", count: 100) + ".pdf")])
        XCTAssertEqual(long.count, 80)
        XCTAssertTrue(long.contains("…")); XCTAssertTrue(long.hasSuffix(".pdf"))
    }
}
