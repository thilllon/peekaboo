import AppKit
import XCTest
@testable import PeekabooApp
@testable import PeekabooCore

/// A launch from a disk image (`Installation`) and the installed copy's eject (`DiskImageEjector`) through the real app
/// delegate, with every hook faked: nothing is installed, opened, ejected or quit, and no volume of the user's is read.
final class InstallationTests: ViewerTestCase {
    private var delegate: AppDelegate?
    private var savedArguments: [String] = []
    private var savedConfig: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        // The delegate's config store reads PEEKABOO_CONFIG when it is created: a file of the test's, never the user's.
        savedConfig = ProcessInfo.processInfo.environment["PEEKABOO_CONFIG"]
        let config = root.appendingPathComponent("launch.toml")
        try Data().write(to: config)
        setenv("PEEKABOO_CONFIG", config.path, 1)
        guard ConfigStore.defaultURL.path == config.path else { throw XCTSkip("PEEKABOO_CONFIG is not read back") }
        savedArguments = CommandLine.arguments
    }

    override func tearDown() {
        if let viewer: ViewerWindowController = delegate.flatMap({ property($0, "viewer") }) {
            viewer.window?.close()
            spin(0.05)
        }
        delegate = nil
        CommandLine.arguments = savedArguments
        if let savedConfig { setenv("PEEKABOO_CONFIG", savedConfig, 1) } else { unsetenv("PEEKABOO_CONFIG") }
        super.tearDown()
    }

    private var target: URL { root.appendingPathComponent("Applications/Peekaboo.app", isDirectory: true) }

    /// A Peekaboo.app at an App Translocation path in the scratch folder (no volume lookup needed to install it).
    private func translocatedApp(_ version: AppVersion = releaseVersion(26)) throws -> URL {
        let folder = root.appendingPathComponent("T/AppTranslocation/0F2A5C1E/d", isDirectory: true)
        return try fakePeekabooApp(in: folder, version: version).bundleURL
    }

    // MARK: Which launches install

    func testOnlyADiskImageOrATranslocatedPeekabooInstalls() throws {
        var asked: [String] = []
        func installation(_ path: String, _ arguments: [String] = [], scripted: Bool = false) -> Installation? {
            Installation.forLaunch(path: path, arguments: arguments, isScripted: { asked.append("scripted"); return scripted },
                                   target: { asked.append("target"); return self.target }, hooks: failingHooks())
        }
        // A normal launch: decided by the bundle path alone.
        for path in ["/Applications/Peekaboo.app", NSHomeDirectory() + "/Applications/Peekaboo.app", root.path] {
            XCTAssertNil(installation(path), path)
        }
        XCTAssertEqual(asked, [], "a normal launch asks nothing more")

        let app = try translocatedApp()
        let found = try XCTUnwrap(installation(app.path))
        XCTAssertEqual(found.app.path, app.path)
        XCTAssertEqual(found.version, releaseVersion(26))
        XCTAssertEqual(found.target, target)
        // Never in the self-test, a scripted run, or the copy an installation started (whatever its path says).
        XCTAssertNil(installation(app.path, ["--selftest", root.path]))
        XCTAssertNil(installation(app.path, scripted: true))
        XCTAssertNil(installation(app.path, ["\(AppInstall.ejectFlag)=4242"]))
        // Nor for anything but a versioned Peekaboo.app.
        XCTAssertNil(installation(app.appendingPathComponent("Contents/MacOS/Peekaboo").path))
        let other = root.appendingPathComponent("T/AppTranslocation/1/d/Peekaboo.app", isDirectory: true)
        try FileManager.default.createDirectory(at: other.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.Other", "CFBundleVersion": "26",
                                                              "CFBundleShortVersionString": releaseVersion(26).name],
                                           format: .xml, options: 0).write(to: other.appendingPathComponent("Contents/Info.plist"))
        XCTAssertNil(installation(other.path))
        let undated = root.appendingPathComponent("T/AppTranslocation/2/d", isDirectory: true)
        let old = try fakePeekabooApp(in: undated, version: releaseVersion(26)).bundleURL
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.thilllon.Peekaboo", "CFBundleVersion": "1",
                                                              "CFBundleShortVersionString": "0.1.0"],
                                           format: .xml, options: 0).write(to: old.appendingPathComponent("Contents/Info.plist"))
        XCTAssertNil(installation(old.path), "a copy without a release version cannot be verified like an update")
    }

    func testAHeadlessLaunchNeverInstalls() throws {
        // A headless delegate (the tests) never asks: it builds its window as usual.
        CommandLine.arguments = [savedArguments.first ?? "Peekaboo"]
        let delegate = AppDelegate()
        delegate.presentation = .headless
        self.delegate = delegate
        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        XCTAssertNil(delegate.installation)
        XCTAssertNotNil(property(delegate, "viewer") as ViewerWindowController?)
    }

    // MARK: Handing over

    /// Hooks whose every call fails the test (the gate must not get that far).
    private func failingHooks() -> Installation.Hooks {
        Installation.Hooks(install: { _, _, _ in XCTFail("installed"); return .installed },
                           open: { _, _, _, _, _ in XCTFail("opened") }, terminate: { XCTFail("quit") })
    }

    private struct Opened {
        var urls: [URL]
        var target: URL
        var newInstance: Bool
        var arguments: [String]
    }

    /// A delegate launched from a fake disk image whose installation reports `outcome` (or throws `failure`), with the
    /// file `first` on the command line.
    private func launchInstalling(_ outcome: AppInstall.Outcome, failure: Error? = nil, openError: Error? = nil,
                                  first: URL, record: @escaping (String) -> Void,
                                  opened: @escaping (Opened) -> Void) throws -> AppDelegate {
        let hooks = Installation.Hooks(install: { app, version, target in
            XCTAssertFalse(Thread.isMainThread, "the install runs off the main thread")
            record("install \(app.lastPathComponent) \(version) at \(target.path)")
            if let failure { throw failure }
            return outcome
        }, open: { urls, target, newInstance, arguments, done in
            XCTAssertTrue(Thread.isMainThread)
            record("open")
            opened(Opened(urls: urls, target: target, newInstance: newInstance, arguments: arguments))
            DispatchQueue.global().async { done(openError) }
        }, terminate: { record("quit") })
        CommandLine.arguments = [savedArguments.first ?? "Peekaboo", first.path, "-NSDocumentRevisionsDebugMode", "YES"]
        let delegate = AppDelegate()
        delegate.presentation = .headless
        delegate.installation = Installation(app: try translocatedApp(), version: releaseVersion(26), target: target, hooks: hooks)
        self.delegate = delegate
        return delegate
    }

    func testAnInstallationBuildsNoWindowAndHandsTheFilesToTheInstalledCopy() throws {
        let a = writeImage(folder.appendingPathComponent("a.jpg"), width: 64, height: 48, gray: 0.3)
        let b = writeImage(folder.appendingPathComponent("b.jpg"), width: 64, height: 48, gray: 0.5)
        let c = writeImage(folder.appendingPathComponent("c.jpg"), width: 64, height: 48, gray: 0.7)
        var calls: [String] = []
        var opened: Opened?
        let delegate = try launchInstalling(.installed, first: a, record: { calls.append($0) }, opened: { opened = $0 })
        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        XCTAssertNil(property(delegate, "viewer") as ViewerWindowController?, "no window")
        // AppKit hands the command line's file over again, as an open-documents event.
        delegate.application(NSApp, open: [b, a])
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        // A file opened while the install runs goes along too.
        delegate.application(NSApp, open: [c])
        XCTAssertTrue(spin(5) { calls.last == "quit" }, "\(calls)")
        XCTAssertEqual(calls, ["install Peekaboo.app \(releaseVersion(26)) at \(target.path)", "open", "quit"])
        let handedOver = try XCTUnwrap(opened)
        XCTAssertEqual(handedOver.urls.map(\.lastPathComponent), ["a.jpg", "b.jpg", "c.jpg"])
        XCTAssertEqual(handedOver.target, target)
        XCTAssertTrue(handedOver.newInstance, "a new instance, while this copy still runs")
        XCTAssertEqual(handedOver.arguments, ["--eject-disk-images=\(getpid())"])
        XCTAssertNil(property(delegate, "viewer") as ViewerWindowController?, "still no window")
        XCTAssertFalse(NSApp.windows.contains { $0 is ViewerWindow && $0.isVisible })
    }

    func testANewerInstalledCopyStartsAndARunningOneGetsTheFiles() throws {
        let a = writeImage(folder.appendingPathComponent("a.jpg"), width: 64, height: 48, gray: 0.3)
        for (outcome, newInstance, arguments) in [(AppInstall.Outcome.newerInstalled(build: 27), true, ["--eject-disk-images=\(getpid())"]),
                                                  (.running, false, [])] {
            var calls: [String] = []
            var opened: Opened?
            let delegate = try launchInstalling(outcome, first: a, record: { calls.append($0) }, opened: { opened = $0 })
            delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
            delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            XCTAssertTrue(spin(5) { calls.last == "quit" }, "\(outcome): \(calls)")
            XCTAssertEqual(opened?.urls, [a])
            XCTAssertEqual(opened?.newInstance, newInstance, "\(outcome)")
            XCTAssertEqual(opened?.arguments, arguments, "\(outcome)")
            XCTAssertNil(property(delegate, "viewer") as ViewerWindowController?)
        }
    }

    func testWhenTheInstallFailsPeekabooOpensTheFilesHere() throws {
        let a = writeImage(folder.appendingPathComponent("a.jpg"), width: 900, height: 600, gray: 0.4)
        for (failure, openError, toast) in [
            (UpdateError.install("\(target.path) is another app") as Error?, nil as Error?,
             "Peekaboo could not be installed in Applications: \(target.path) is another app"),
            (nil, CocoaError(.fileNoSuchFile), "Peekaboo could not start \(target.path): "),
        ] {
            var calls: [String] = []
            let delegate = try launchInstalling(.installed, failure: failure, openError: openError, first: a,
                                                record: { calls.append($0) }, opened: { _ in })
            delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
            delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            XCTAssertTrue(spin(5) { (property(delegate, "viewer") as ViewerWindowController?)?.displayedFile?.name == "a.jpg" },
                          "the file opens here after all: \(calls)")
            let viewer: ViewerWindowController = try XCTUnwrap(property(delegate, "viewer"))
            XCTAssertNil(delegate.installation)
            XCTAssertFalse(calls.contains("quit"), "\(calls)")
            XCTAssertTrue(toastText(viewer)?.hasPrefix(toast) == true, toastText(viewer) ?? "no toast")
            assertNothingOnScreen()
            viewer.window?.close()
            spin(0.05)
        }
    }

    func testOnlyAnotherProcessRunningThatBundleCounts() {
        XCTAssertFalse(Installation.isRunning(target), "nothing runs from the scratch folder")
        XCTAssertFalse(Installation.isRunning(Bundle.main.bundleURL), "this process does not count")
    }

    // MARK: Ejecting the disk images

    func testAHeadlessLaunchNeverEjects() throws {
        let installer = Process()
        installer.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try installer.run()
        installer.waitUntilExit()
        CommandLine.arguments = [savedArguments.first ?? "Peekaboo", "\(AppInstall.ejectFlag)=\(installer.processIdentifier)"]
        var calls: [String] = []
        let delegate = AppDelegate()
        delegate.presentation = .headless
        delegate.diskImageEjector = DiskImageEjector(hooks: .init(waitForExit: { _ in calls.append("wait"); return true },
                                                                   diskImages: { calls.append("list"); return [] },
                                                                   eject: { _ in calls.append("eject") }))
        self.delegate = delegate
        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        spin(1.5)  // past the second after launch when the installed copy ejects
        XCTAssertEqual(calls, [])
    }

    func testTheEjectorWaitsForTheInstallerThenEjectsEveryImage() throws {
        let images = ["Peekaboo 20261126-85dff6", "Peekaboo 20261126-69a847", "Peekaboo"].map {
            URL(fileURLWithPath: "/Volumes/\($0)", isDirectory: true)
        }
        var calls: [String] = []
        let lock = NSLock()
        func record(_ call: String) {
            XCTAssertFalse(Thread.isMainThread, call)
            lock.withLock { calls.append(call) }
        }
        // What `unmountAndEjectDevice` throws for an image an app still has a file of open (fBsyErr).
        let busy = NSError(domain: NSOSStatusErrorDomain, code: -47)
        var busyOnce = true
        let ejector = DiskImageEjector(hooks: .init(waitForExit: { record("wait \($0)"); return true },
                                                    diskImages: { record("list"); return images },
                                                    eject: { url in
            record("eject \(url.lastPathComponent)")
            if url.lastPathComponent == "Peekaboo 20261126-69a847" { throw busy }  // in use for good
            if url.lastPathComponent == "Peekaboo", busyOnce {  // in use for a moment
                busyOnce = false
                throw busy
            }
        }), retryDelay: 0)
        var result: (String, Bool)?
        ejector.run(after: 4242) { toast, failed in
            XCTAssertTrue(Thread.isMainThread)
            result = (toast, failed)
        }
        XCTAssertTrue(spin(5) { result != nil })
        // The images in use are tried once more.
        XCTAssertEqual(lock.withLock { calls }, ["wait 4242", "list", "eject Peekaboo 20261126-85dff6",
                                                 "eject Peekaboo 20261126-69a847", "eject Peekaboo",
                                                 "eject Peekaboo 20261126-69a847", "eject Peekaboo"])
        XCTAssertEqual(result?.0, "Peekaboo is installed in Applications\n"
                       + "“Peekaboo 20261126-69a847” is in use: eject it in Finder once it is free")
        XCTAssertEqual(result?.1, true)

        // Every image ejected (or none mounted): the toast says it is installed, briefly.
        result = nil
        DiskImageEjector(hooks: .init(waitForExit: { _ in false }, diskImages: { [] }, eject: { _ in XCTFail("ejected") }))
            .run(after: 4242) { result = ($0, $1) }
        XCTAssertTrue(spin(5) { result != nil })
        XCTAssertEqual(result?.0, "Peekaboo is installed in Applications")
        XCTAssertEqual(result?.1, false)

        // Several images in use; an image that failed for another reason is not said to be in use.
        XCTAssertEqual(DiskImageEjector.toast(failed: ["A", "B"], busy: true),
                       "Peekaboo is installed in Applications\n“A”, “B” are in use: eject them in Finder once they are free")
        XCTAssertEqual(DiskImageEjector.toast(failed: ["A"], busy: false),
                       "Peekaboo is installed in Applications\nCould not eject “A”: eject it in Finder")
        XCTAssertTrue(DiskImageEjector.isBusy(NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))))
        XCTAssertFalse(DiskImageEjector.isBusy(NSError(domain: NSOSStatusErrorDomain, code: -36)))
        result = nil
        var attempts = 0
        DiskImageEjector(hooks: .init(waitForExit: { _ in true }, diskImages: { images }, eject: { _ in
            attempts += 1
            throw CocoaError(.fileWriteNoPermission)
        })).run(after: 1) { result = ($0, $1) }
        XCTAssertTrue(spin(5) { result != nil })
        XCTAssertEqual(attempts, 3, "an image that is not in use is not tried again")
        XCTAssertEqual(result?.0, "Peekaboo is installed in Applications\nCould not eject “Peekaboo 20261126-85dff6”, "
                       + "“Peekaboo 20261126-69a847”, “Peekaboo”: eject them in Finder")
    }
}
