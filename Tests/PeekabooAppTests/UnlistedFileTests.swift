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
        // Bytes no decoder (ImageIO or QuickLook) can read: a valid SVG would get a QuickLook preview, so the error
        // path would depend on the machine's QuickLook generators.
        let svg = folder.appendingPathComponent("logo.svg")
        try Data([0x00, 0xFF, 0x13, 0x37, 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03]).write(to: svg)

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
        XCTAssertTrue(spin(30) { self.names(viewer).contains("a3.jpg") }, "no rescan (utility queue)")
        XCTAssertEqual(viewer.pipeline.currentFile?.name, "logo.svg")
        viewer.perform(.previous)
        XCTAssertEqual(viewer.pipeline.currentFile?.name, "a3.jpg")
    }

    /// A path typed in Terminal is NFC while the folder lists the name as stored (NFD): the opened file is the
    /// listed one, not a second, unlisted entry (nor the folder's first image).
    func testOpeningAPathInAnotherUnicodeNormalizationUsesTheListedFile() throws {
        let viewer = try makeViewer()
        writeImage(folder.appendingPathComponent("a1.jpg"), width: 900, height: 600, gray: 0.3)
        writeImage(folder.appendingPathComponent("cafe\u{301}.jpg"), width: 900, height: 600, gray: 0.6)
        let stored = try XCTUnwrap(FolderScanner.scan(folder).first { $0.name.hasPrefix("caf") }?.name)
        let typed = "caf\u{E9}.jpg"
        guard Array(stored.unicodeScalars) != Array(typed.unicodeScalars) else {
            throw XCTSkip("the file system stored the name as typed")
        }
        openAndWait(viewer, [folder.appendingPathComponent(typed)])
        spin(0.2)
        XCTAssertEqual(names(viewer).count, 2, "the opened file was listed twice: \(names(viewer))")
        XCTAssertEqual(viewer.pipeline.currentFile?.name, typed)
        XCTAssertTrue(viewer.pipeline.currentFile?.name.unicodeScalars.elementsEqual(stored.unicodeScalars) == true)
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
