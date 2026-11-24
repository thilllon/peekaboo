import AppKit
import XCTest
@testable import PeekabooApp
@testable import PeekabooCore
@testable import PeekabooRender

/// The browsed folder changes on disk while it is shown (folder watcher → rescan).
final class FolderRescanTests: ViewerTestCase {
    /// Renaming the image on screen (in Finder) keeps it on screen under its new name.
    func testRenamingTheImageOnScreenKeepsIt() throws {
        let viewer = try makeViewer()
        let urls = ["a", "b", "c", "d"].map {
            writeImage(folder.appendingPathComponent("\($0).jpg"), width: 900, height: 600, gray: 0.5)
        }
        openAndWait(viewer, [urls[1]])
        try FileManager.default.moveItem(at: urls[1], to: folder.appendingPathComponent("z best.jpg"))
        // The rescan runs on a utility queue: slow to get a core on a loaded CI machine.
        XCTAssertTrue(spin(30) { viewer.pipeline.files.contains { $0.name == "z best.jpg" } }, "no rescan")
        XCTAssertEqual(viewer.pipeline.currentFile?.name, "z best.jpg")
        XCTAssertTrue(spin(5) { viewer.displayedFile?.name == "z best.jpg" })
    }

    /// A listing that started before a file action must not put the moved file back into the browsing set.
    func testFileMovedWhileTheFolderIsListedStaysOut() throws {
        let viewer = try makeViewer()
        // Enough entries that a listing takes a while: the window in which the move happens.
        for i in 0..<12_000 {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(String(format: "x%05d.jpg", i)).path, contents: nil)
        }
        let opened = writeImage(folder.appendingPathComponent("x06000.jpg"), width: 900, height: 600, gray: 0.5)
        openAndWait(viewer, [opened])
        let started = Trace.now()
        _ = try FolderScanner.scan(folder)
        let scanSeconds = Trace.ms(since: started) / 1000

        var reinserted: [String] = []
        for attempt in 0..<6 {
            let moved = try XCTUnwrap(viewer.pipeline.currentFile)
            // A change in the folder starts a (debounced) rescan, and the image is moved away while it lists.
            FileManager.default.createFile(atPath: folder.appendingPathComponent("new\(attempt).jpg").path, contents: nil)
            spin(0.05 + 0.4 * scanSeconds)
            viewer.perform(.move("./_keep"))
            XCTAssertFalse(viewer.pipeline.files.contains(moved), "the move did not remove \(moved.name)")
            // Until the rescans settle, the moved file must never be listed again.
            let deadline = Date().addingTimeInterval(max(0.8, 6 * scanSeconds))
            while Date() < deadline {
                if viewer.pipeline.files.contains(moved) {
                    reinserted.append(moved.name)
                    break
                }
                spin(0.003)
            }
        }
        XCTAssertEqual(reinserted, [], "moved files came back into the browsing set")
    }
}
