import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import PeekabooApp
@testable import PeekabooCore
@testable import PeekabooRender

/// The image on screen is edited in another app (atomic save): the new version must replace the old pixels.
final class ReplacedFileTests: ViewerTestCase {
    private func replaceWhileShown(type: UTType, ext: String, size: (Int, Int), newSize: (Int, Int), zoom: Bool) throws {
        let viewer = try makeViewer()
        let a = writeImage(folder.appendingPathComponent("a.\(ext)"), width: size.0, height: size.1, gray: 0.2, type: type)
        writeImage(folder.appendingPathComponent("b.\(ext)"), width: size.0, height: size.1, gray: 0.8, type: type)
        openAndWait(viewer, [a])
        if zoom {
            viewer.perform(.zoomSet(2))
            XCTAssertTrue(spin(10) { viewer.shownTierForTests == .full }, "full resolution was not shown")
        }
        spin(0.6)  // the user looks at it (dwell: a speculative full-resolution decode may land)
        let before = try XCTUnwrap(renderer(viewer).image)

        atomicallyReplace(a, width: newSize.0, height: newSize.1, gray: 0.9, type: type)
        let current = try XCTUnwrap(viewer.pipeline.currentFile)
        // The rescan runs on a utility queue: slow to get a core on a loaded CI machine.
        let redecoded = spin(30) { viewer.pipeline.best(for: current)?.fullWidth == newSize.0 }
        XCTAssertTrue(redecoded, "the pipeline did not decode the new version")
        let shownNew = spin(3) { self.renderer(viewer).image?.fullWidth == newSize.0 }

        let shown = try XCTUnwrap(renderer(viewer).image)
        XCTAssertTrue(shownNew, "still showing the old \(before.fullWidth)×\(before.fullHeight) version")
        XCTAssertEqual(shown.fullHeight, newSize.1)
        XCTAssertFalse(shown.pixels === before.pixels)
        XCTAssertEqual(viewer.displayedFile?.name, "a.\(ext)")
    }

    func testPNGReplacedAtFitShowsTheNewVersion() throws {
        try replaceWhileShown(type: .png, ext: "png", size: (1600, 1200), newSize: (1200, 1600), zoom: false)
    }

    func testJPEGReplacedWhileZoomedShowsTheNewVersion() throws {
        // Large enough that the screen tier is subsampled and zooming in decodes `.full`.
        let side = 2 * ViewerWindowController.largestScreenLongSide() + 256
        try replaceWhileShown(type: .jpeg, ext: "jpg", size: (side, side * 2 / 3), newSize: (side * 2 / 3, side), zoom: true)
    }

    /// A broken re-save of the shown image reports the error instead of keeping the old pixels.
    func testShownImageReplacedByABrokenFileShowsTheError() throws {
        let viewer = try makeViewer()
        let a = writeImage(folder.appendingPathComponent("a.png"), width: 800, height: 600, gray: 0.2, type: .png)
        writeImage(folder.appendingPathComponent("b.png"), width: 800, height: 600, gray: 0.8, type: .png)
        openAndWait(viewer, [a])
        let temporary = folder.appendingPathComponent(".saving-a.png")
        try Data("<html>not an image</html>".utf8).write(to: temporary)
        XCTAssertEqual(rename(temporary.path, a.path), 0)
        let reported = spin(30) { self.hudMessage(viewer)?.contains("Cannot open “a.png”") == true }
        XCTAssertTrue(reported, "no error for the broken new version")
        XCTAssertNil(renderer(viewer).image, "the old version is still on screen")
    }
}
