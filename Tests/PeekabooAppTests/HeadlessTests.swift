import AppKit
import CoreGraphics
import XCTest
@testable import PeekabooApp
@testable import PeekabooCore
@testable import PeekabooRender

/// A test run never shows a window or takes the keyboard focus: the process cannot activate, and a headless viewer is
/// ordered in (it renders, `isVisible` holds) but transparent and off every screen. Every viewer test checks this when
/// it ends; these go through each way the app puts a window on screen.
final class HeadlessTests: ViewerTestCase {
    /// Open, open a file of the browsed folder, instant and native full screen, close and Dock reopen, the drop hint.
    func testTheViewerNeverComesOnScreenNorTakesTheFocus() throws {
        let viewer = try makeViewer()
        let window = try XCTUnwrap(viewer.window)
        let urls = writeSequence(3)
        openAndWait(viewer, [urls[0]])
        XCTAssertTrue(window.isVisible, "a headless window is ordered in")
        assertNothingOnScreen()
        viewer.open([urls[2]])
        XCTAssertTrue(spin(5) { viewer.displayedFile?.name == "img02.jpg" })
        assertNothingOnScreen()

        let screen = try XCTUnwrap(window.screen ?? NSScreen.main)
        viewer.perform(.fullscreen)
        XCTAssertFalse(window.styleMask.contains(.titled), "not in instant full screen")
        XCTAssertEqual(window.frame.size, screen.frame.size, "instant full screen has the screen's size")
        assertNothingOnScreen()
        viewer.perform(.fullscreen)
        XCTAssertTrue(window.styleMask.contains(.titled))
        viewer.perform(.fullscreenNative)
        spin(0.3)
        XCTAssertFalse(window.styleMask.contains(.fullScreen), "native full screen takes a Space on a screen")
        assertNothingOnScreen()

        window.close()
        viewer.reopen()
        XCTAssertTrue(window.isVisible)
        viewer.showEmpty(nil)
        spin(0.2)
        assertNothingOnScreen()
        assertWindowServerShowsNothing()
    }

    /// The app delegate activates the app when it launches and while it presents the first frame: never headless.
    func testTheAppDelegateNeverActivatesTheApp() throws {
        let config = root.appendingPathComponent("launch.toml")
        try Data().write(to: config)
        let previous = ProcessInfo.processInfo.environment["PEEKABOO_CONFIG"]
        setenv("PEEKABOO_CONFIG", config.path, 1)
        defer { if let previous { setenv("PEEKABOO_CONFIG", previous, 1) } else { unsetenv("PEEKABOO_CONFIG") } }
        guard ConfigStore.defaultURL.path == config.path else { throw XCTSkip("PEEKABOO_CONFIG is not read back") }
        let arguments = CommandLine.arguments
        CommandLine.arguments = [arguments.first ?? "Peekaboo"]
        defer { CommandLine.arguments = arguments }

        let delegate = AppDelegate()
        delegate.presentation = .headless
        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        let viewer: ViewerWindowController = try XCTUnwrap(property(delegate, "viewer"))
        defer {
            viewer.window?.close()
            spin(0.05)
        }
        XCTAssertEqual(viewer.presentation, .headless)
        // An open-documents event during launch: the first frame is presented synchronously, in an active app.
        let url = writeImage(folder.appendingPathComponent("a.jpg"), width: 900, height: 600, gray: 0.4)
        delegate.application(NSApp, open: [url])
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        XCTAssertTrue(spin(5) { viewer.displayedFile?.name == "a.jpg" })
        assertNothingOnScreen()
        viewer.window?.close()
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        XCTAssertTrue(viewer.window?.isVisible == true, "a Dock click shows the window again")
        spin(0.2)
        assertNothingOnScreen()
        assertWindowServerShowsNothing()
    }

    /// Out of sight, a window still renders: its layer keeps vending drawables (a throttled layer would hold each
    /// `nextDrawable()` for a second, then return nil), and the viewer's frames are encoded and run on the GPU.
    func testAHeadlessWindowStillRenders() throws {
        let viewer = try makeViewer()
        let urls = writeSequence(2)
        openAndWait(viewer, [urls[0]])
        let renderer = renderer(viewer)
        XCTAssertNotEqual(renderer.lastPath, "background")
        XCTAssertTrue(spin(5) { renderer.lastFrameGPUms > 0 }, "no frame ran on the GPU")
        viewer.showEmpty(nil)
        XCTAssertEqual(renderer.lastPath, "background", "the frame of the drop hint was not encoded")
        openAndWait(viewer, [urls[1]])
        XCTAssertNotEqual(renderer.lastPath, "background", "the frame of the image was not encoded")

        // Four times the layer's drawables, as fast as the run loop turns.
        let view: ViewerView = try XCTUnwrap(property(viewer, "viewerView"))
        let started = Trace.now()
        var longestWait = 0.0
        for i in 0..<12 {
            let asked = Trace.now()
            let drawable = try XCTUnwrap(view.metalLayer.nextDrawable(), "no drawable \(i)")
            longestWait = max(longestWait, Trace.ms(since: asked))
            let commands = try XCTUnwrap(RenderContext.shared.queue.makeCommandBuffer())
            commands.present(drawable)
            commands.commit()
            spin(0.005)
        }
        let total = Trace.ms(since: started)
        print(String(format: "headless drawables: 12 in %.1f ms, longest nextDrawable wait %.1f ms", total, longestWait))
        XCTAssertLessThan(total, 5000, "the layer's drawables are throttled")
    }

    /// The window server agrees: every window of the process it has ordered in is transparent and off every display.
    private func assertWindowServerShowsNothing(file: StaticString = #filePath, line: UInt = #line) {
        let listed = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = listed.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == getpid() }
        XCTAssertFalse(windows.isEmpty, "the window server lists no window of the process", file: file, line: line)
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &displays, &count)
        for window in windows {
            let number = window[kCGWindowNumber as String] ?? "?"
            XCTAssertEqual((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, 0,
                           "window \(number) is not transparent", file: file, line: line)
            guard let dictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary) else { continue }
            for display in displays.prefix(Int(count)) where CGDisplayBounds(display).intersects(bounds) {
                XCTFail("window \(number) is on display \(display) at \(bounds)", file: file, line: line)
            }
        }
    }
}
