import AppKit
import Carbon.HIToolbox
import XCTest
@testable import PeekabooApp
@testable import PeekabooCore
@testable import PeekabooRender

/// Key handling: auto-repeat and sequences.
final class KeyTests: ViewerTestCase {
    /// A held key repeats navigation, but not one-shot actions such as rotate (or trash, or Esc).
    func testAutoRepeatRepeatsNavigationOnly() throws {
        let viewer = try makeViewer()
        let urls = writeSequence(6)
        openAndWait(viewer, [urls[0]])

        XCTAssertTrue(viewer.handleKey(keyDown(viewer, keyCode: kVK_ANSI_R, characters: "r")))
        XCTAssertTrue(viewer.handleKey(keyDown(viewer, keyCode: kVK_ANSI_R, characters: "r", isRepeat: true)))
        XCTAssertTrue(viewer.handleKey(keyDown(viewer, keyCode: kVK_ANSI_R, characters: "r", isRepeat: true)))
        XCTAssertEqual(renderer(viewer).quarterTurns, 1, "auto-repeat ran view.rotate_cw again")

        let right = String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!)
        XCTAssertTrue(viewer.handleKey(keyDown(viewer, keyCode: kVK_RightArrow, characters: right)))
        XCTAssertTrue(viewer.handleKey(keyDown(viewer, keyCode: kVK_RightArrow, characters: right, isRepeat: true)))
        XCTAssertTrue(viewer.handleKey(keyDown(viewer, keyCode: kVK_RightArrow, characters: right, isRepeat: true)))
        XCTAssertEqual(viewer.pipeline.index, 3, "navigation must keep repeating")
    }

    /// A repeat of a sequence's first key does not complete the sequence.
    func testAutoRepeatNeverCompletesASequence() throws {
        let viewer = try makeViewer(toml: "[keys]\n\"j j\" = \"nav.last\"\n")
        let urls = writeSequence(6)
        openAndWait(viewer, [urls[0]])
        XCTAssertTrue(viewer.handleKey(keyDown(viewer, keyCode: kVK_ANSI_J, characters: "j")))
        XCTAssertTrue(viewer.handleKey(keyDown(viewer, keyCode: kVK_ANSI_J, characters: "j", isRepeat: true)))
        XCTAssertEqual(viewer.pipeline.index, 0, "holding j completed \"j j\"")
        XCTAssertTrue(viewer.handleKey(keyDown(viewer, keyCode: kVK_ANSI_J, characters: "j")))
        XCTAssertEqual(viewer.pipeline.index, 5)
    }
}
