import AppKit
import XCTest
@testable import PeekabooApp
@testable import PeekabooCore
@testable import PeekabooRender

final class ZoomTests: ViewerTestCase {
    /// `zoom.set` accepts any positive finite factor: huge ones are clamped like zoom steps and labelled without
    /// trapping (help overlay, menu, HUD).
    func testHugeZoomFactorsAreClampedAndLabelled() throws {
        XCTAssertEqual(KeyLabels.title(.zoomSet(2)), "Zoom 200%")
        XCTAssertTrue(KeyLabels.title(.zoomSet(1e17)).hasPrefix("Zoom "))
        let viewer = try makeViewer(toml: "[keys]\n\"z\" = \"zoom.set:1e17\"\n")
        openAndWait(viewer, [writeImage(folder.appendingPathComponent("a.jpg"), width: 1200, height: 800, gray: 0.4)])
        viewer.perform(.help)
        viewer.perform(.zoomSet(1e17))
        XCTAssertEqual(renderer(viewer).effectiveScale, ViewerWindowController.maximumZoom)
        viewer.perform(.help)
    }

    /// A drag moves the window where it has nothing to pan (#72): an empty window, an image at fit, and always the
    /// title-bar strip; zoomed in, it pans the image; in full screen it never moves the window.
    func testDragMovesTheWindowWhereThereIsNothingToPan() throws {
        let viewer = try makeViewer()
        let view: ViewerView = try XCTUnwrap(property(viewer, "viewerView"))
        let middle = CGPoint(x: 400, y: 400), titleBar = CGPoint(x: 400, y: 5)
        XCTAssertTrue(viewer.viewer(view, dragMovesWindowAt: middle), "empty window")
        openAndWait(viewer, [writeImage(folder.appendingPathComponent("a.jpg"), width: 1200, height: 800, gray: 0.4)])
        XCTAssertTrue(viewer.viewer(view, dragMovesWindowAt: middle), "image at fit")
        viewer.perform(.zoomSet(4))
        XCTAssertTrue(renderer(viewer).isZoomedBeyondFit)
        XCTAssertFalse(viewer.viewer(view, dragMovesWindowAt: middle), "zoomed in: the drag pans")
        XCTAssertTrue(viewer.viewer(view, dragMovesWindowAt: titleBar), "the title-bar strip still moves the window")
        viewer.perform(.fullscreen)
        XCTAssertFalse(viewer.viewer(view, dragMovesWindowAt: titleBar), "full screen")
        XCTAssertFalse(viewer.viewer(view, dragMovesWindowAt: middle), "full screen")
        viewer.perform(.fullscreen)
    }
}
