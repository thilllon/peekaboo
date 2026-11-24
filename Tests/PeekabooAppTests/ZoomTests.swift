import AppKit
import XCTest
@testable import PeekabooApp
@testable import PeekabooCore
@testable import PeekabooRender

final class ZoomTests: ViewerTestCase {
    /// `zoom.set` accepts any positive finite factor: huge ones are clamped like zoom steps and labelled without
    /// trapping (help overlay, menu, HUD).
    func testHugeZoomFactorsAreClampedAndLabelled() throws {
        XCTAssertEqual(KeyLabels.title(.zoomSet(2)), "Zoom 200 %")
        XCTAssertTrue(KeyLabels.title(.zoomSet(1e17)).hasPrefix("Zoom "))
        let viewer = try makeViewer(toml: "[keys]\n\"z\" = \"zoom.set:1e17\"\n")
        openAndWait(viewer, [writeImage(folder.appendingPathComponent("a.jpg"), width: 1200, height: 800, gray: 0.4)])
        viewer.perform(.help)
        viewer.perform(.zoomSet(1e17))
        XCTAssertEqual(renderer(viewer).effectiveScale, ViewerWindowController.maximumZoom)
        viewer.perform(.help)
    }
}
