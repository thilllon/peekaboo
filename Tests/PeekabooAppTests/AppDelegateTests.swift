import AppKit
import XCTest
@testable import PeekabooApp
@testable import PeekabooCore
@testable import PeekabooRender

/// The app delegate's launch and open-documents handling.
final class AppDelegateTests: ViewerTestCase {
    private var delegate: AppDelegate?

    override func tearDown() {
        if let viewer: ViewerWindowController = delegate.flatMap({ property($0, "viewer") }) {
            viewer.window?.close()
            spin(0.05)
        }
        delegate = nil
        super.tearDown()
    }

    /// Unknown keys in the config present at launch are toasted once the app has launched (`load()` runs before the
    /// toast callbacks are installed).
    func testConfigWarningsAtLaunchAreToasted() throws {
        let config = root.appendingPathComponent("launch.toml")
        try Data("[view]\nfit = \"contain\"\n".utf8).write(to: config)
        let previous = ProcessInfo.processInfo.environment["PEEKABOO_CONFIG"]
        setenv("PEEKABOO_CONFIG", config.path, 1)
        defer { if let previous { setenv("PEEKABOO_CONFIG", previous, 1) } else { unsetenv("PEEKABOO_CONFIG") } }
        guard ConfigStore.defaultURL.path == config.path else { throw XCTSkip("PEEKABOO_CONFIG is not read back") }
        let arguments = CommandLine.arguments
        CommandLine.arguments = [arguments.first ?? "Peekaboo"]
        defer { CommandLine.arguments = arguments }

        let delegate = AppDelegate()
        self.delegate = delegate
        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        spin(0.1)  // the drop hint of a launch without documents
        let viewer: ViewerWindowController = try XCTUnwrap(property(delegate, "viewer"))
        let toast = try XCTUnwrap(toastText(viewer), "no toast at launch")
        XCTAssertTrue(toast.contains("view.fit"), toast)
    }

    /// Opening the file that was just closed (Esc, then a double-click in Finder within 1.5 s) shows it again.
    func testReopeningTheSameFileRightAfterClosingShowsIt() throws {
        let delegate = AppDelegate()
        self.delegate = delegate
        let url = writeImage(folder.appendingPathComponent("a.jpg"), width: 900, height: 600, gray: 0.4)
        delegate.application(NSApp, open: [url])
        let viewer: ViewerWindowController = try XCTUnwrap(property(delegate, "viewer"))
        XCTAssertTrue(spin(5) { viewer.displayedFile?.name == "a.jpg" })
        viewer.window?.close()
        XCTAssertFalse(viewer.window?.isVisible == true)

        delegate.application(NSApp, open: [url])
        XCTAssertTrue(viewer.window?.isVisible == true, "the re-open was dropped as a duplicate")
    }
}
