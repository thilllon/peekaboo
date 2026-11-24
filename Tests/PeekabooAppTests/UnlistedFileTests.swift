import AppKit
import XCTest
@testable import PeekabooApp
@testable import PeekabooCore
@testable import PeekabooRender

/// Opening one file that its folder's listing does not include (Finder's Open With on an SVG, a dropped
/// document, a hidden image).
final class UnlistedFileTests: ViewerTestCase {
    private func names(_ viewer: ViewerWindowController) -> [String] { viewer.pipeline.files.map(\.name) }

    func testOpeningAnUnsupportedFileShowsItsErrorAmongItsFolder() throws {
        let viewer = try makeViewer()
        writeImage(folder.appendingPathComponent("a1.jpg"), width: 900, height: 600, gray: 0.3)
        writeImage(folder.appendingPathComponent("a2.jpg"), width: 900, height: 600, gray: 0.6)
        let svg = folder.appendingPathComponent("logo.svg")
        try Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>"#.utf8).write(to: svg)

        viewer.open([svg])
        XCTAssertTrue(spin(5) { !viewer.isListingPendingForTests && self.hudMessage(viewer) != nil })
        XCTAssertEqual(viewer.pipeline.currentFile?.name, "logo.svg", "another image of the folder is shown")
        XCTAssertEqual(names(viewer), ["a1.jpg", "a2.jpg", "logo.svg"])
        XCTAssertTrue(hudMessage(viewer)?.contains("Cannot open “logo.svg”") == true, hudMessage(viewer) ?? "nil")
        XCTAssertNil(renderer(viewer).image)
        let watcher: FolderWatcher? = property(viewer, "folderWatcher")
        XCTAssertEqual(watcher?.directory.standardizedFileURL.path, folder.standardizedFileURL.path,
                       "the folder watcher does not watch the folder")

        // A change in the folder keeps it in the set, on screen.
        writeImage(folder.appendingPathComponent("a3.jpg"), width: 900, height: 600, gray: 0.9)
        XCTAssertTrue(spin(5) { self.names(viewer).contains("a3.jpg") }, "no rescan")
        XCTAssertEqual(viewer.pipeline.currentFile?.name, "logo.svg")
        viewer.perform(.previous)
        XCTAssertEqual(viewer.pipeline.currentFile?.name, "a3.jpg")
    }

    func testOpeningAHiddenImageKeepsItOnScreen() throws {
        let viewer = try makeViewer()
        writeImage(folder.appendingPathComponent("a1.jpg"), width: 900, height: 600, gray: 0.3)
        writeImage(folder.appendingPathComponent("a2.jpg"), width: 900, height: 600, gray: 0.6)
        let hidden = writeImage(folder.appendingPathComponent(".x.jpg"), width: 900, height: 600, gray: 0.9)
        openAndWait(viewer, [hidden])
        spin(0.2)
        XCTAssertEqual(viewer.pipeline.currentFile?.name, ".x.jpg", "jumped to another image after the listing")
        XCTAssertEqual(viewer.displayedFile?.name, ".x.jpg")
        XCTAssertEqual(names(viewer), [".x.jpg", "a1.jpg", "a2.jpg"])
    }
}
