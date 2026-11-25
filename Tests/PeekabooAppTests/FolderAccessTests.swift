import AppKit
import XCTest
@testable import PeekabooApp
@testable import PeekabooCore

/// First launch: macOS asks for Desktop, Documents and Downloads right after installation (#74). No test reads those
/// folders: every request lists through an injected function, so a test run never shows a prompt.
final class FolderAccessTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suite = "peekaboo-folder-access-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// The request of the installed app's first launch (Peekaboo.app, not scripted, never asked), listing through
    /// `touch`.
    private func firstLaunch(touch: @escaping (URL) -> Bool) -> FolderAccessRequest {
        var request = FolderAccessRequest()
        request.defaults = defaults
        request.bundleURL = URL(fileURLWithPath: "/Applications/Peekaboo.app", isDirectory: true)
        request.scripted = false
        request.touch = touch
        return request
    }

    /// Polls `condition` (off the main run loop: the request runs on a utility queue) for up to `seconds`.
    private func wait(_ seconds: TimeInterval = 5, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() >= deadline { return false }
            usleep(2000)
        }
        return true
    }

    func testTheFoldersAreDesktopDocumentsAndDownloadsOfTheHomeFolder() {
        let folders = FolderAccessRequest().folders
        XCTAssertEqual(folders.map(\.lastPathComponent), ["Desktop", "Documents", "Downloads"])
        XCTAssertEqual(Set(folders.map { $0.deletingLastPathComponent().standardizedFileURL.path }),
                       [URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path])
    }

    /// Each folder is listed once, one after another and off the main thread: a prompt blocks the listing thread
    /// until it is answered, never the caller. Later launches list nothing.
    func testTheFirstLaunchListsEachFolderOnceOneAfterAnother() throws {
        let lock = NSLock()
        var touched: [String] = []
        var onMain = false
        var inFlight = 0
        var mostInFlight = 0
        let answer = DispatchSemaphore(value: 0)
        let request = firstLaunch { folder in
            lock.lock()
            touched.append(folder.lastPathComponent)
            onMain = onMain || Thread.isMainThread
            inFlight += 1
            mostInFlight = max(mostInFlight, inFlight)
            lock.unlock()
            // Desktop's prompt is up until the test answers it.
            if folder.lastPathComponent == "Desktop" { _ = answer.wait(timeout: .now() + 3) }
            lock.lock()
            inFlight -= 1
            lock.unlock()
            return true
        }
        _ = defaults.bool(forKey: FolderAccessRequest.doneKey)  // loaded, as the app's defaults are by then
        let started = Trace.now()
        XCTAssertTrue(request.start(presentation: .interactive, selfTest: false), "the first launch does not ask")
        let mainThreadMs = Trace.ms(since: started)
        print(String(format: "folder access: the first launch's start() took %.3f ms on the main thread", mainThreadMs))
        XCTAssertLessThan(mainThreadMs, 20, "the caller waited for the listing")

        let count = { () -> Int in
            lock.lock()
            defer { lock.unlock() }
            return touched.count
        }
        XCTAssertTrue(wait { count() > 0 }, "Desktop was not listed")
        usleep(200_000)
        lock.lock()
        XCTAssertEqual(touched, ["Desktop"], "the next folder did not wait for the open prompt")
        lock.unlock()
        XCTAssertFalse(defaults.bool(forKey: FolderAccessRequest.doneKey), "flagged before every folder was listed")
        answer.signal()
        XCTAssertTrue(wait { self.defaults.bool(forKey: FolderAccessRequest.doneKey) }, "the flag was not set")
        lock.lock()
        XCTAssertEqual(touched, ["Desktop", "Documents", "Downloads"])
        XCTAssertFalse(onMain, "a folder was listed on the main thread")
        XCTAssertEqual(mostInFlight, 1, "folders were listed at the same time")
        lock.unlock()

        let later = Trace.now()
        XCTAssertFalse(request.start(presentation: .interactive, selfTest: false), "a later launch asks again")
        let laterMs = Trace.ms(since: later)
        print(String(format: "folder access: a later launch's start() took %.4f ms on the main thread", laterMs))
        usleep(100_000)
        lock.lock()
        XCTAssertEqual(touched.count, 3, "a later launch listed again")
        lock.unlock()
    }

    /// Never in tests (headless), the self-test, a scripted run or outside an app bundle (`swift run`).
    func testNeverInTestsTheSelfTestScriptedRunsOrOutsideTheApp() {
        let lock = NSLock()
        var touched: [URL] = []
        let request = firstLaunch { folder in
            lock.lock()
            touched.append(folder)
            lock.unlock()
            return true
        }
        XCTAssertTrue(request.shouldRequest(presentation: .interactive, selfTest: false))
        XCTAssertFalse(request.start(presentation: .headless, selfTest: false), "tests")
        XCTAssertFalse(request.start(presentation: .interactive, selfTest: true), "--selftest")
        var scripted = request
        scripted.scripted = true
        XCTAssertFalse(scripted.start(presentation: .interactive, selfTest: false), "PEEKABOO_ACTIONS")
        var unbundled = request
        unbundled.bundleURL = URL(fileURLWithPath: "/tmp/peekaboo/.build/debug", isDirectory: true)
        XCTAssertFalse(unbundled.start(presentation: .interactive, selfTest: false), "swift run")
        usleep(100_000)
        lock.lock()
        XCTAssertEqual(touched, [])
        lock.unlock()
        XCTAssertFalse(defaults.bool(forKey: FolderAccessRequest.doneKey))
    }

    /// A test run never asks: past the second after launch when it is due, the app delegate's request (here one that
    /// would ask, Peekaboo.app at its first launch) has listed nothing, because the delegate is headless.
    func testTheAppDelegateNeverAsksHeadless() {
        let lock = NSLock()
        var touched: [URL] = []
        let delegate = AppDelegate()
        delegate.presentation = .headless
        delegate.folderAccess = firstLaunch { folder in
            lock.lock()
            touched.append(folder)
            lock.unlock()
            return true
        }
        XCTAssertTrue(delegate.folderAccess.shouldRequest(presentation: .interactive, selfTest: false))
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let due = expectation(description: "past the second after launch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { due.fulfill() }
        wait(for: [due], timeout: 5)
        lock.lock()
        XCTAssertEqual(touched, [], "a headless launch listed protected folders")
        lock.unlock()
        XCTAssertFalse(defaults.bool(forKey: FolderAccessRequest.doneKey))
    }

    /// `PEEKABOO_ACTIONS` in the environment makes a scripted run even when it is empty.
    func testAnyActionListIsAScriptedRun() {
        let previous = getenv("PEEKABOO_ACTIONS").map { String(cString: $0) }
        defer { if let previous { setenv("PEEKABOO_ACTIONS", previous, 1) } else { unsetenv("PEEKABOO_ACTIONS") } }
        unsetenv("PEEKABOO_ACTIONS")
        XCTAssertFalse(FolderAccessRequest().scripted)
        setenv("PEEKABOO_ACTIONS", "", 1)
        XCTAssertTrue(FolderAccessRequest().scripted)
        setenv("PEEKABOO_ACTIONS", "nav.next", 1)
        XCTAssertTrue(FolderAccessRequest().scripted)
    }

    /// The default listing reads a folder's names (temporary folders here, never a protected one).
    func testTheListingReadsTheFolder() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-access-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertTrue(FolderAccessRequest.list(folder))
        XCTAssertFalse(FolderAccessRequest.list(folder.appendingPathComponent("missing")))
    }

    /// macOS privacy protection refuses a folder with EPERM: the toast names the System Settings pane that allows it.
    /// File permissions refuse with EACCES; any other error has no toast.
    func testTheToastOfARefusedFolderSaysHowToAllowIt() {
        let downloads = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads", isDirectory: true)
        let privacy = "Peekaboo cannot read “Downloads”\n"
            + "Allow it in System Settings › Privacy & Security › Files and Folders"
        XCTAssertEqual(ViewerWindowController.accessDeniedToast(POSIXError(.EPERM), folder: downloads), privacy)
        let refused = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoPermission.rawValue,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        XCTAssertEqual(ViewerWindowController.accessDeniedToast(refused, folder: downloads), privacy)
        let permissions = ViewerWindowController.accessDeniedToast(POSIXError(.EACCES), folder: downloads)
        XCTAssertTrue(permissions?.hasPrefix("Peekaboo cannot read “Downloads”\n") == true, permissions ?? "nil")
        XCTAssertFalse(permissions?.contains("Privacy") == true, permissions ?? "nil")
        XCTAssertNil(ViewerWindowController.accessDeniedToast(POSIXError(.ENOENT), folder: downloads))
        XCTAssertNil(ViewerWindowController.accessDeniedToast(CocoaError(.fileReadUnknown), folder: downloads))
    }
}

/// A folder Peekaboo may not list: the opened image shows on its own, and one toast says why and how to allow it.
final class UnreadableFolderTests: ViewerTestCase {
    func testAFolderThatCannotBeListedSaysSoInOneToast() throws {
        let viewer = try makeViewer()
        let urls = writeSequence(2)
        // -wx--x--x: the images open by name, the folder does not list (EACCES; macOS privacy protection: EPERM).
        XCTAssertEqual(chmod(folder.path, 0o311), 0)
        defer { chmod(folder.path, 0o755) }
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY)
        if fd >= 0 { close(fd) }
        guard fd < 0 else { throw XCTSkip("permissions are not enforced for this user") }
        let expected = try XCTUnwrap(ViewerWindowController.accessDeniedToast(POSIXError(.EACCES), folder: folder))

        openAndWait(viewer, [urls[0]])
        XCTAssertEqual(viewer.pipeline.files.map(\.name), ["img00.jpg"], "the opened image does not show on its own")
        XCTAssertEqual(toastText(viewer), expected)
        XCTAssertNil(hudMessage(viewer))
        let toasts: Int = try XCTUnwrap(property(hud(viewer), "toastGeneration"))
        // A rescan (folder watcher, a file of the folder opened again) fails the same way, without another toast.
        viewer.rescanFolder()
        spin(0.3)
        XCTAssertEqual(property(hud(viewer), "toastGeneration"), toasts, "a rescan toasted again")

        // The folder itself: the message says it cannot be read, not that it has no images.
        viewer.open([folder])
        XCTAssertTrue(spin(5) { !viewer.isListingPendingForTests && self.hudMessage(viewer) != nil })
        XCTAssertEqual(hudMessage(viewer), "Cannot read “images”\nDrop images here or press ⌘O")
        XCTAssertEqual(toastText(viewer), expected)
        XCTAssertEqual(property(hud(viewer), "toastGeneration"), toasts + 1, "not one toast for the folder")
    }
}
