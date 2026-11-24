import AppKit
import XCTest
@testable import PeekabooApp
@testable import PeekabooCore
@testable import PeekabooRender

/// Closing the window (the app stays resident) and opening again.
final class WindowLifecycleTests: ViewerTestCase {
    /// `app.close` (⌘W, `q`, File › Close Window) closes the window in instant full screen too, and restores the
    /// window's style for the next open.
    func testCloseInInstantFullScreenClosesTheWindow() throws {
        let viewer = try makeViewer()
        let window = try XCTUnwrap(viewer.window)
        let style = window.styleMask
        openAndWait(viewer, [writeImage(folder.appendingPathComponent("a.jpg"), width: 1200, height: 800, gray: 0.4)])
        viewer.perform(.fullscreen)
        XCTAssertFalse(window.styleMask.contains(.titled), "not in instant full screen")
        viewer.perform(.close)
        spin(0.2)
        XCTAssertFalse(window.isVisible, "the window stayed open")
        XCTAssertEqual(window.styleMask, style)
        XCTAssertEqual(NSApp.presentationOptions, [])
    }
}
