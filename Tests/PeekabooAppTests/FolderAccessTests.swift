import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import PeekabooApp
@testable import PeekabooCore

/// First launch: macOS asks for Desktop, Documents and Downloads right after installation (#74). No test reads those
/// folders: every request lists through an injected function, so a test run never shows a prompt. Nor does a test
/// write a defaults domain: the flag is kept in memory.
final class FolderAccessTests: XCTestCase {
    /// The flag of a test, set from the listing queue.
    private final class Flag {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }

    private var flag = Flag()

    /// The request of the installed app's first launch (Peekaboo.app started by LaunchServices, not scripted, never
    /// asked), listing through `touch`.
    private func firstLaunch(touch: @escaping (URL) -> Bool) -> FolderAccessRequest {
        var request = FolderAccessRequest()
        let flag = flag
        request.isDone = { flag.isSet }
        request.markDone = { flag.set() }
        request.bundleURL = URL(fileURLWithPath: "/Applications/Peekaboo.app", isDirectory: true)
        request.launchedByLaunchServices = true
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
        let folders = FolderAccessRequest.folders
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
        XCTAssertFalse(flag.isSet, "flagged before every folder was listed")
        answer.signal()
        XCTAssertTrue(wait { self.flag.isSet }, "the flag was not set")
        lock.lock()
        XCTAssertEqual(touched, ["Desktop", "Documents", "Downloads"])
        XCTAssertFalse(onMain, "a folder was listed on the main thread")
        XCTAssertEqual(mostInFlight, 1, "folders were listed at the same time")
        lock.unlock()

        XCTAssertFalse(request.start(presentation: .interactive, selfTest: false), "a later launch asks again")
        usleep(100_000)
        lock.lock()
        XCTAssertEqual(touched.count, 3, "a later launch listed again")
        lock.unlock()
    }

    /// What a later launch spends on the main thread: building the request (bundle, environment, parent process) and
    /// the gate, which ends with the flag read from the app's defaults (here the test runner's own, without the flag:
    /// read, never written).
    func testALaterLaunchReadsOneFlag() {
        _ = UserDefaults.standard.bool(forKey: FolderAccessRequest.doneKey)  // loaded, as a second after launch
        var runs: [Double] = []
        for _ in 0..<5 {
            let started = Trace.now()
            var request = FolderAccessRequest()
            request.bundleURL = URL(fileURLWithPath: "/Applications/Peekaboo.app", isDirectory: true)
            request.launchedByLaunchServices = true
            request.scripted = false
            XCTAssertTrue(request.shouldRequest(presentation: .interactive, selfTest: false))
            runs.append(Trace.ms(since: started))
        }
        print(String(format: "folder access: a later launch's request and gate took %@ ms on the main thread",
                     runs.map { String(format: "%.4f", $0) }.joined(separator: " / ")))
    }

    /// Never in tests (headless), the self-test, a scripted run, a run from a shell or a debugger, or outside an app
    /// bundle (`swift run`).
    func testNeverInTestsTheSelfTestScriptedRunsAShellOrOutsideTheApp() {
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
        // `…/Peekaboo.app/Contents/MacOS/Peekaboo` from a terminal: macOS would ask for the terminal.
        var fromShell = request
        fromShell.launchedByLaunchServices = false
        XCTAssertFalse(fromShell.start(presentation: .interactive, selfTest: false), "a shell")
        var unbundled = request
        unbundled.bundleURL = URL(fileURLWithPath: "/tmp/peekaboo/.build/debug", isDirectory: true)
        XCTAssertFalse(unbundled.start(presentation: .interactive, selfTest: false), "swift run")
        usleep(100_000)
        lock.lock()
        XCTAssertEqual(touched, [])
        lock.unlock()
        XCTAssertFalse(flag.isSet)
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
        XCTAssertFalse(flag.isSet)
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

    /// macOS privacy protection refuses a folder with EPERM: the toast names the switch that allows it, the one of the
    /// protected place the folder is in, or Full Disk Access where Files & Folders has none. File permissions refuse
    /// with EACCES; any other error has no toast.
    func testTheToastOfARefusedFolderSaysHowToAllowIt() {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let trip = home.appendingPathComponent("Downloads/Trip 2026", isDirectory: true)
        let downloads = "Peekaboo cannot read “Trip 2026”\n"
            + "Turn on Downloads Folder for Peekaboo in System Settings › Privacy & Security › Files & Folders"
        XCTAssertEqual(ViewerWindowController.accessDeniedToast(POSIXError(.EPERM), folder: trip), downloads)
        let refused = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoPermission.rawValue,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        XCTAssertEqual(ViewerWindowController.accessDeniedToast(refused, folder: trip), downloads)

        let filesAndFolders = " for Peekaboo in System Settings › Privacy & Security › Files & Folders"
        let fullDiskAccess = "Allow Peekaboo in System Settings › Privacy & Security › Full Disk Access"
        let settings: [(String, String)] = [
            ("Desktop", "Turn on Desktop Folder" + filesAndFolders),
            ("Documents/Wedding/raw", "Turn on Documents Folder" + filesAndFolders),
            ("downloads/typed in lower case", "Turn on Downloads Folder" + filesAndFolders),
            ("Desktop Photos", fullDiskAccess),  // next to Desktop, not in it
            ("Library/Messages/Attachments/4f/15", fullDiskAccess),
            ("Library/Mail/V10", fullDiskAccess),
        ]
        for (path, setting) in settings {
            let folder = home.appendingPathComponent(path, isDirectory: true)
            XCTAssertEqual(ViewerWindowController.privacySetting(for: folder), setting, path)
        }
        // A camera card (no such volume here: its type is not known, and a card is removable); Time Machine backups.
        XCTAssertEqual(ViewerWindowController.privacySetting(for: URL(fileURLWithPath: "/Volumes/EOS_DIGITAL/DCIM/100CANON")),
                       "Turn on Removable Volumes" + filesAndFolders)
        XCTAssertEqual(ViewerWindowController.privacySetting(for: URL(fileURLWithPath: "/Volumes/.timemachine/A1/2026-11-25-120000.backup/Users")),
                       fullDiskAccess)
        XCTAssertEqual(ViewerWindowController.privacySetting(for: URL(fileURLWithPath: "/Volumes/Backup/Backups.backupdb/Mac")),
                       fullDiskAccess)
        XCTAssertFalse(ViewerWindowController.isOnNetworkVolume("/"))
        XCTAssertFalse(ViewerWindowController.isOnNetworkVolume(NSTemporaryDirectory()))

        XCTAssertEqual(ViewerWindowController.accessDeniedToast(POSIXError(.EACCES), folder: trip),
                       "Peekaboo cannot read “Trip 2026”\n"
                       + "Its permissions do not let you read it: Finder › Get Info › Sharing & Permissions")
        XCTAssertNil(ViewerWindowController.accessDeniedToast(POSIXError(.ENOENT), folder: trip))
        XCTAssertNil(ViewerWindowController.accessDeniedToast(CocoaError(.fileReadUnknown), folder: trip))
    }
}

/// A folder Peekaboo may not list: the opened image shows on its own and says why and how to allow it, at the ends of
/// the set too, and the folder lists again once it is allowed and the window becomes key.
final class UnreadableFolderTests: ViewerTestCase {
    /// `count` images in `folder`, which then lists no more (-wx--x--x: the images open by name, the listing fails
    /// with EACCES; macOS privacy protection refuses with EPERM). Skipped where permissions are not enforced.
    private func refusedFolder(_ count: Int) throws -> (urls: [URL], refusal: String) {
        let urls = writeSequence(count)
        XCTAssertEqual(chmod(folder.path, 0o311), 0)
        addTeardownBlock { [folder] in _ = chmod(folder!.path, 0o755) }
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY)
        if fd >= 0 { close(fd) }
        guard fd < 0 else { throw XCTSkip("permissions are not enforced for this user") }
        return (urls, try XCTUnwrap(ViewerWindowController.accessDeniedToast(POSIXError(.EACCES), folder: folder)))
    }

    private func toasts(_ viewer: ViewerWindowController) -> Int { property(hud(viewer), "toastGeneration") ?? -1 }

    private func hudLine(_ viewer: ViewerWindowController) -> String {
        let content: HUDContent? = property(hud(viewer), "content")
        return content?.line ?? ""
    }

    private func rescanInFlight(_ viewer: ViewerWindowController) -> Bool { property(viewer, "rescanInFlight") ?? false }

    private func becomeKey(_ viewer: ViewerWindowController) {
        viewer.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: viewer.window))
    }

    func testAFolderThatCannotBeListedSaysSoInOneToast() throws {
        let viewer = try makeViewer()
        let (urls, refusal) = try refusedFolder(2)

        openAndWait(viewer, [urls[0]])
        XCTAssertEqual(viewer.pipeline.files.map(\.name), ["img00.jpg"], "the opened image does not show on its own")
        XCTAssertEqual(toastText(viewer), refusal)
        XCTAssertNil(hudMessage(viewer))
        XCTAssertTrue(hudLine(viewer).hasPrefix("img00.jpg  ·  1/?  ·  "), hudLine(viewer))
        let shown = toasts(viewer)
        // A rescan (folder watcher, a file of the folder opened again) fails the same way, without another toast.
        viewer.rescanFolder()
        spin(0.3)
        XCTAssertEqual(toasts(viewer), shown, "a rescan toasted again")
    }

    /// → and ← cannot move in the set of one image: they say why again, not "Last image" / "First image" (which would
    /// replace the explanation for 1.2 s), and a held key does not repeat it.
    func testTheEndsOfTheSetSayWhyAgain() throws {
        let viewer = try makeViewer()
        let (urls, refusal) = try refusedFolder(3)
        openAndWait(viewer, [urls[0]])
        let shown = toasts(viewer)

        viewer.perform(.next)
        XCTAssertEqual(toastText(viewer), refusal)
        XCTAssertEqual(toasts(viewer), shown + 1)
        viewer.perform(.next, isRepeat: true)
        XCTAssertEqual(toasts(viewer), shown + 1, "a key repeat showed it again")
        viewer.perform(.previous)
        XCTAssertEqual(toastText(viewer), refusal)
        XCTAssertEqual(toasts(viewer), shown + 2)
        XCTAssertEqual(viewer.displayedFile?.name, "img00.jpg")
    }

    /// Allowed meanwhile (System Settings, here the folder's permissions): the window becoming key lists the folder
    /// again, which then browses and is watched as any other. Until then a refused rescan changes nothing.
    func testTheFolderListsOnceAllowedAndTheWindowBecomesKey() throws {
        let viewer = try makeViewer()
        let (urls, _) = try refusedFolder(3)
        openAndWait(viewer, [urls[0]])
        let shown = toasts(viewer)
        let unwatched: FolderWatcher? = property(viewer, "folderWatcher")
        XCTAssertNil(unwatched, "a folder that cannot be listed cannot be watched either")

        becomeKey(viewer)
        XCTAssertTrue(rescanInFlight(viewer), "becoming key did not list the refused folder again")
        XCTAssertTrue(spin(5) { !self.rescanInFlight(viewer) })
        XCTAssertEqual(viewer.pipeline.files.count, 1, "still refused")
        XCTAssertEqual(toasts(viewer), shown, "a refused rescan toasted")

        XCTAssertEqual(chmod(folder.path, 0o755), 0)
        becomeKey(viewer)
        XCTAssertTrue(spin(5) { viewer.pipeline.files.count == 3 }, "the allowed folder was not listed")
        XCTAssertEqual(viewer.displayedFile?.name, "img00.jpg")
        XCTAssertTrue(hudLine(viewer).hasPrefix("img00.jpg  ·  1/3  ·  "), hudLine(viewer))
        let watcher: FolderWatcher? = property(viewer, "folderWatcher")
        XCTAssertEqual(watcher?.directory, folder, "the allowed folder is not watched")
        // An edit saved now in another app shows, as in any watched folder.
        atomicallyReplace(urls[0], width: 800, height: 1200, gray: 0.9, type: .jpeg)
        XCTAssertTrue(spin(30) { self.renderer(viewer).image?.fullWidth == 800 }, "the edit does not show")
        viewer.perform(.next)
        XCTAssertTrue(spin(5) { viewer.displayedFile?.name == "img01.jpg" && viewer.shownTierForTests != nil })
        XCTAssertEqual(toasts(viewer), shown, "browsing the allowed folder toasted")
        viewer.perform(.next)
        viewer.perform(.next)
        XCTAssertEqual(toastText(viewer), "Last image")

        // A readable folder: becoming key lists nothing.
        XCTAssertTrue(spin(5) { !self.rescanInFlight(viewer) })
        becomeKey(viewer)
        XCTAssertFalse(rescanInFlight(viewer), "becoming key listed a readable folder")
    }

    /// The folder itself: its message says it cannot be read and how to allow it (no toast on top), until it is
    /// allowed.
    func testAnOpenedFolderSaysHowToAllowItInItsMessage() throws {
        let viewer = try makeViewer()
        let (_, refusal) = try refusedFolder(2)
        let shown = toasts(viewer)
        viewer.open([folder])
        XCTAssertTrue(spin(5) { !viewer.isListingPendingForTests && self.hudMessage(viewer) != nil })
        XCTAssertEqual(hudMessage(viewer), refusal)
        XCTAssertEqual(toasts(viewer), shown, "a toast repeats the message")

        XCTAssertEqual(chmod(folder.path, 0o755), 0)
        becomeKey(viewer)
        XCTAssertTrue(spin(5) { viewer.displayedFile?.name == "img00.jpg" && viewer.shownTierForTests != nil })
        XCTAssertNil(hudMessage(viewer))
    }

    /// An empty folder, once allowed, says that it has no images.
    func testAnAllowedEmptyFolderSaysItHasNoImages() throws {
        let viewer = try makeViewer()
        let (_, refusal) = try refusedFolder(0)
        viewer.open([folder])
        XCTAssertTrue(spin(5) { !viewer.isListingPendingForTests && self.hudMessage(viewer) != nil })
        XCTAssertEqual(hudMessage(viewer), refusal)

        XCTAssertEqual(chmod(folder.path, 0o755), 0)
        becomeKey(viewer)
        XCTAssertTrue(spin(5) { self.hudMessage(viewer) != refusal }, "still says it cannot read the folder")
        XCTAssertEqual(hudMessage(viewer), "No images in “images”\nDrop images here or press ⌘O")
    }
}
