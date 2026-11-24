import AppKit
import XCTest
@testable import PeekabooApp
@testable import PeekabooCore
@testable import PeekabooRender

/// A file that cannot be decoded shows its error whenever it is reached, never the previous image under its name.
final class CorruptFileTests: ViewerTestCase {
    private func assertShowsError(_ viewer: ViewerWindowController, _ name: String, line: UInt = #line) {
        XCTAssertEqual(viewer.pipeline.currentFile?.name, name, line: line)
        let reported = spin(2) { self.hudMessage(viewer)?.contains("Cannot open “\(name)”") == true }
        XCTAssertTrue(reported, "no error message for \(name): \(hudMessage(viewer) ?? "nil")", line: line)
        XCTAssertNil(renderer(viewer).image, "another image's pixels are on screen under \(name)", line: line)
        XCTAssertEqual(viewer.displayedFile?.name, name, line: line)
        spin(0.3)  // past the 150 ms progress-line delay
        XCTAssertFalse(isLoading(viewer), "the progress line sweeps over a file that failed", line: line)
    }

    /// The broken file was a prefetch neighbour: its decode failed before the user reached it.
    private func corruptNeighbour(_ contents: Data) throws {
        let viewer = try makeViewer()
        let a = writeImage(folder.appendingPathComponent("a.jpg"), width: 1200, height: 800, gray: 0.3)
        try contents.write(to: folder.appendingPathComponent("b.jpg"))
        writeImage(folder.appendingPathComponent("c.jpg"), width: 1200, height: 800, gray: 0.6)
        openAndWait(viewer, [a])
        XCTAssertTrue(spin(5) { viewer.pipeline.stats.failures > 0 }, "b.jpg was not prefetched")
        viewer.perform(.next)
        assertShowsError(viewer, "b.jpg")
    }

    func testHTMLPageSavedAsJPEGReachedByArrowKeyShowsItsError() throws {
        try corruptNeighbour(Data("<html><body>404 Not Found</body></html>".utf8))
    }

    func testEmptyFileReachedByArrowKeyShowsItsError() throws {
        try corruptNeighbour(Data())
    }

    func testReturningToAFailedFileShowsItsErrorAgain() throws {
        let viewer = try makeViewer()
        writeImage(folder.appendingPathComponent("a.jpg"), width: 1200, height: 800, gray: 0.3)
        let b = folder.appendingPathComponent("b.jpg")
        try Data("<html>404</html>".utf8).write(to: b)
        writeImage(folder.appendingPathComponent("c.jpg"), width: 1200, height: 800, gray: 0.6)
        viewer.open([b])
        XCTAssertTrue(spin(5) { !viewer.isListingPendingForTests && self.hudMessage(viewer) != nil })
        assertShowsError(viewer, "b.jpg")

        viewer.perform(.next)
        XCTAssertTrue(spin(5) { viewer.displayedFile?.name == "c.jpg" && self.renderer(viewer).image != nil })
        XCTAssertNil(hudMessage(viewer))
        viewer.perform(.previous)
        assertShowsError(viewer, "b.jpg")
    }
}
