import XCTest
import SwiftUI
import UIKit

@MainActor final class ShareReviewTests: XCTestCase {
    func testUnavailableCopyOffersInAppAlternativeWithoutSigningDetails() {
        let text = CaptureError.sharingUnavailable.localizedDescription
        XCTAssertEqual(text, "Sharing isn't available in this build. Open Lemon Bot and add the item from Camera, Photos or Files there.")
        XCTAssertFalse(text.contains(ShareInbox.groupID))
        XCTAssertFalse(text.contains("App Group"))
    }

    func testRenderUnavailableShareReview() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LB_SHARE_SNAPSHOT_DIR"] ?? "/tmp/lb3-voice-shots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for (name, style) in [("light", UIUserInterfaceStyle.light), ("dark", UIUserInterfaceStyle.dark)] {
            let model = ShareReviewModel()
            model.sharingUnavailable = true
            model.error = CaptureError.sharingUnavailable.localizedDescription
            let host = UIHostingController(rootView: ShareReviewView(model: model))
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
            window.overrideUserInterfaceStyle = style
            window.rootViewController = host
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            try await Task.sleep(for: .seconds(2))
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let data = try XCTUnwrap(image.pngData())
            try data.write(to: directory.appendingPathComponent("ios-share-unavailable-\(name).png"))
            let attachment = XCTAttachment(image: image)
            attachment.name = "Share unavailable · \(name)"; attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertNil(model.capture)
            window.isHidden = true
        }
    }
}
