import AppKit
import XCTest
@testable import PeekabooApp
@testable import PeekabooCore
@testable import PeekabooRender

/// How results of file actions (move, undo, redo) change the browsing set and the image on screen.
final class FileOutcomeTests: ViewerTestCase {
    private func names(_ viewer: ViewerWindowController) -> [String] { viewer.pipeline.files.map(\.name) }

    /// Redo of a move of another file than the one on screen keeps the image being viewed.
    func testRedoOfAnotherFilesMoveKeepsTheCurrentImage() throws {
        let viewer = try makeViewer()
        let urls = writeSequence(10, prefix: "f")
        openAndWait(viewer, [urls[2]])
        viewer.perform(.move("./_keep"))
        XCTAssertEqual(viewer.pipeline.currentFile?.name, "f03.jpg")
        viewer.perform(.undo)
        XCTAssertEqual(viewer.pipeline.currentFile?.name, "f02.jpg")
        viewer.perform(.jump(5))
        XCTAssertEqual(viewer.pipeline.currentFile?.name, "f07.jpg")

        viewer.perform(.redo)
        XCTAssertFalse(names(viewer).contains("f02.jpg"), "redo did not move f02 again")
        XCTAssertEqual(viewer.pipeline.currentFile?.name, "f07.jpg", "the viewer jumped away from the image on screen")
    }

    /// Undo of a move made in another folder puts the file back on disk without injecting it into the folder now
    /// being browsed.
    func testUndoAfterOpeningAnotherFolderKeepsItsSet() throws {
        let viewer = try makeViewer()
        let a = writeSequence(3, in: folder.appendingPathComponent("a"), prefix: "a")
        let b = writeSequence(3, in: folder.appendingPathComponent("b"), prefix: "b")
        openAndWait(viewer, [a[1]])
        viewer.perform(.move("./_keep"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: a[1].path))
        openAndWait(viewer, [b[0]])
        XCTAssertEqual(names(viewer), ["b00.jpg", "b01.jpg", "b02.jpg"])

        viewer.perform(.undo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a[1].path), "undo did not restore a01")
        XCTAssertEqual(names(viewer), ["b00.jpg", "b01.jpg", "b02.jpg"], "a file of another folder was injected")
        XCTAssertEqual(viewer.pipeline.currentFile?.name, "b00.jpg")
    }
}
