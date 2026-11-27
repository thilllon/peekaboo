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
    /// The other Applications folder's copy.
    private var other: URL { root.appendingPathComponent("home/Applications/Peekaboo.app", isDirectory: true) }

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

    func testADelegateWithoutAnInstallationBuildsItsWindow() throws {
        // main.swift decides before the delegate exists; tests never get that far, and a delegate without an installation
        // launches as usual.
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
                           quit: { _ in XCTFail("quit a copy"); return false },
                           open: { _, _, _, _, _ in XCTFail("opened") }, terminate: { XCTFail("quit") })
    }

    private struct Opened: Equatable {
        var urls: [URL]
        var app: URL
        var newInstance: Bool
        var arguments: [String]
    }

    /// A delegate launched from a fake disk image whose installation reports `outcomes` one after the other (or throws
    /// `failure`), with the file `first` on the command line. `quit` answers the request to quit a running copy, `opened`
    /// sees each hand-over (before it completes).
    private func launchInstalling(_ outcomes: [AppInstall.Outcome], failure: Error? = nil, quit: Bool = true,
                                  openError: Error? = nil, first: URL, record: @escaping (String) -> Void,
                                  opened: @escaping (Opened) -> Void) throws -> AppDelegate {
        var outcomes = outcomes
        let hooks = Installation.Hooks(install: { app, version, target in
            XCTAssertFalse(Thread.isMainThread, "the install runs off the main thread")
            record("install \(app.lastPathComponent) \(version) at \(target.path)")
            if let failure { throw failure }
            return outcomes.removeFirst()
        }, quit: { target in
            XCTAssertFalse(Thread.isMainThread, "waiting for a copy to quit happens off the main thread")
            record("quit \(target.path)")
            return quit
        }, open: { urls, app, newInstance, arguments, done in
            XCTAssertTrue(Thread.isMainThread)
            record("open \(urls.map(\.lastPathComponent).joined(separator: " "))")
            opened(Opened(urls: urls, app: app, newInstance: newInstance, arguments: arguments))
            DispatchQueue.global().async { done(openError) }
        }, terminate: { record("quit") })
        CommandLine.arguments = [savedArguments.first ?? "Peekaboo", first.path, "-NSDocumentRevisionsDebugMode", "YES"]
        let delegate = AppDelegate()
        delegate.presentation = .headless
        delegate.installation = Installation(app: try translocatedApp(), version: releaseVersion(26), target: target, hooks: hooks)
        self.delegate = delegate
        return delegate
    }

    private func launch(_ delegate: AppDelegate) {
        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    }

    func testAnInstallationBuildsNoWindowAndHandsTheFilesToTheInstalledCopy() throws {
        let a = writeImage(folder.appendingPathComponent("a.jpg"), width: 64, height: 48, gray: 0.3)
        let b = writeImage(folder.appendingPathComponent("b.jpg"), width: 64, height: 48, gray: 0.5)
        let c = writeImage(folder.appendingPathComponent("c.jpg"), width: 64, height: 48, gray: 0.7)
        var calls: [String] = []
        var opened: [Opened] = []
        let delegate = try launchInstalling([.installed], first: a, record: { calls.append($0) }, opened: { opened.append($0) })
        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        XCTAssertNil(property(delegate, "viewer") as ViewerWindowController?, "no window")
        // AppKit hands the command line's file over again, as an open-documents event.
        delegate.application(NSApp, open: [b, a])
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        // A file opened while the install runs goes along too.
        delegate.application(NSApp, open: [c])
        XCTAssertTrue(spin(5) { calls.last == "quit" }, "\(calls)")
        XCTAssertEqual(calls, ["install Peekaboo.app \(releaseVersion(26)) at \(target.path)", "open a.jpg b.jpg c.jpg", "quit"])
        XCTAssertEqual(opened, [Opened(urls: [a, b, c], app: target, newInstance: true, arguments: ["--eject-disk-images=\(getpid())"])],
                       "a new instance, while this copy still runs")
        XCTAssertNil(property(delegate, "viewer") as ViewerWindowController?, "still no window")
        XCTAssertFalse(NSApp.windows.contains { $0 is ViewerWindow && $0.isVisible })
    }

    func testAKeptOrRunningCopyGetsTheFiles() throws {
        let a = writeImage(folder.appendingPathComponent("a.jpg"), width: 64, height: 48, gray: 0.3)
        let eject = "--eject-disk-images=\(getpid())"
        for (outcome, expected) in [
            // A newer build at the target: started, and told that nothing was installed.
            (AppInstall.Outcome.kept(target, build: 27), Opened(urls: [a], app: target, newInstance: true, arguments: [eject, "--kept-newer"])),
            // The same build in the other Applications folder: started; it is the one installed.
            (.kept(other, build: 26), Opened(urls: [a], app: other, newInstance: true, arguments: [eject])),
            // Running already (the same or a newer build): the files go to it, nothing is ejected.
            (.running(target, build: 26), Opened(urls: [a], app: target, newInstance: false, arguments: [])),
            (.running(other, build: 27), Opened(urls: [a], app: other, newInstance: false, arguments: [])),
        ] {
            var calls: [String] = []
            var opened: [Opened] = []
            let delegate = try launchInstalling([outcome], first: a, record: { calls.append($0) }, opened: { opened.append($0) })
            launch(delegate)
            XCTAssertTrue(spin(5) { calls.last == "quit" }, "\(outcome): \(calls)")
            XCTAssertFalse(calls.contains { $0.hasPrefix("quit /") }, "\(outcome): nothing to quit")
            XCTAssertEqual(opened, [expected], "\(outcome)")
            XCTAssertNil(property(delegate, "viewer") as ViewerWindowController?)
        }
    }

    func testAnOlderCopyRunningAtTheTargetIsQuitFirst() throws {
        // Peekaboo stays open after its last window closes: an older one usually runs when a newer disk image is opened.
        let a = writeImage(folder.appendingPathComponent("a.jpg"), width: 64, height: 48, gray: 0.3)
        var calls: [String] = []
        var opened: [Opened] = []
        let delegate = try launchInstalling([.running(target, build: 25), .installed], first: a,
                                            record: { calls.append($0) }, opened: { opened.append($0) })
        launch(delegate)
        XCTAssertTrue(spin(5) { calls.last == "quit" }, "\(calls)")
        let install = "install Peekaboo.app \(releaseVersion(26)) at \(target.path)"
        XCTAssertEqual(calls, [install, "quit \(target.path)", install, "open a.jpg", "quit"])
        XCTAssertEqual(opened, [Opened(urls: [a], app: target, newInstance: true, arguments: ["--eject-disk-images=\(getpid())"])])
        delegate.installation = nil

        // Its update installer may have put a newer build there meanwhile: that one is kept and started.
        calls = []
        opened = []
        let again = try launchInstalling([.running(target, build: 25), .kept(target, build: 27)], first: a,
                                         record: { calls.append($0) }, opened: { opened.append($0) })
        launch(again)
        XCTAssertTrue(spin(5) { calls.last == "quit" }, "\(calls)")
        XCTAssertEqual(opened.map(\.arguments), [["--eject-disk-images=\(getpid())", "--kept-newer"]])
    }

    func testWhenTheInstallFailsPeekabooOpensTheFilesHere() throws {
        let a = writeImage(folder.appendingPathComponent("a.jpg"), width: 900, height: 600, gray: 0.4)
        let stillRunning = "Peekaboo could not be installed in Applications\n"
            + "The Peekaboo there is still running: quit every Peekaboo, then open this one again"
        for (outcomes, failure, quit, openError, toast) in [
            ([AppInstall.Outcome.installed], UpdateError.install("Peekaboo.app in Applications is another app") as Error?, true,
             nil as Error?, "Peekaboo could not be installed in Applications\nPeekaboo.app in Applications is another app"),
            ([.installed], nil, true, CocoaError(.fileNoSuchFile), "Peekaboo could not start Peekaboo.app in Applications\n"),
            // An older copy at the target that does not quit, or that runs again by the time it is installed.
            ([.running(target, build: 25)], nil, false, nil, stillRunning),
            ([.running(target, build: 25), .running(target, build: 25)], nil, true, nil, stillRunning),
        ] {
            var calls: [String] = []
            let delegate = try launchInstalling(outcomes, failure: failure, quit: quit, openError: openError, first: a,
                                                record: { calls.append($0) }, opened: { _ in })
            launch(delegate)
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

    func testFilesThatArriveDuringTheHandOverFollowTheOthers() throws {
        // The user, seeing no window yet, opens more files while the installed copy starts: they are not lost.
        let a = writeImage(folder.appendingPathComponent("a.jpg"), width: 64, height: 48, gray: 0.3)
        let b = writeImage(folder.appendingPathComponent("b.jpg"), width: 64, height: 48, gray: 0.5)
        let c = writeImage(folder.appendingPathComponent("c.jpg"), width: 64, height: 48, gray: 0.7)
        var calls: [String] = []
        var opened: [Opened] = []
        weak var weakDelegate: AppDelegate?
        let delegate = try launchInstalling([.installed], first: a, record: { calls.append($0) }, opened: { handOver in
            opened.append(handOver)
            switch opened.count {
            case 1: weakDelegate?.application(NSApp, open: [b, a])  // b is new, a went along already
            case 2: weakDelegate?.application(NSApp, open: [b, c])  // b is handed back here: not sent again
            default: break
            }
        })
        weakDelegate = delegate
        launch(delegate)
        XCTAssertTrue(spin(5) { calls.last == "quit" }, "\(calls)")
        let eject = "--eject-disk-images=\(getpid())"
        XCTAssertEqual(opened, [Opened(urls: [a], app: target, newInstance: true, arguments: [eject]),
                                Opened(urls: [b], app: target, newInstance: false, arguments: []),
                                Opened(urls: [c], app: target, newInstance: false, arguments: [])])
        XCTAssertEqual(calls.filter { $0 == "quit" }.count, 1)
        XCTAssertEqual(calls.last, "quit", "only once every file is there")
    }

    func testQuittingACopyWaitsUntilNoProcessRunsItsBundle() {
        // The processes that run the bundle, faked: one that no app this session could quit, like the update installer a
        // quitting copy starts, or a copy of another user's. Nothing is quit and no process is started (a copy of a
        // system binary run by a test makes Gatekeeper put dialogs on screen: issue #87).
        var calls: [String] = []
        /// `Installation.quit` of the target, while `running(n)` runs it at the n-th look.
        func quit(timeout: TimeInterval, running: (Int) -> [pid_t]) -> Bool {
            var looks = 0
            return Installation.quit(target, timeout: timeout, quitCopies: { calls.append("quit \($0.path)") }) { app in
                calls.append("look \(app.path)")
                looks += 1
                return running(looks)
            }
        }
        let (quitCopies, look) = ("quit \(target.path)", "look \(target.path)")
        XCTAssertTrue(quit(timeout: 0.2) { _ in [] }, "nothing runs it")
        XCTAssertEqual(calls, [quitCopies, look], "the copies are quit first")

        calls = []
        let started = Date()
        XCTAssertFalse(quit(timeout: 0.3) { _ in [4242] }, "it still runs")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.3)
        XCTAssertEqual(calls.first, quitCopies)
        XCTAssertGreaterThan(calls.count, 2, "it is looked at again while it runs: \(calls)")

        calls = []
        XCTAssertTrue(quit(timeout: 5) { $0 < 4 ? [4242] : [] }, "it has exited")
        XCTAssertEqual(calls, [quitCopies] + Array(repeating: look, count: 4))
    }

    func testQuittingAsksTheSystemWhichProcessesRunTheBundle() throws {
        // `quit`'s default process list, the system's (the copies to quit stay faked): sleep(1) runs from /bin, at its own
        // path (never a copy: issue #87). Shells run from /bin too, so only "it still runs" can be checked there.
        let sleep = Process()
        sleep.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleep.arguments = ["30"]
        try sleep.run()
        defer { if sleep.isRunning { sleep.terminate() } }
        XCTAssertFalse(Installation.quit(URL(fileURLWithPath: "/bin", isDirectory: true), timeout: 0.2, quitCopies: { _ in }),
                       "sleep runs from /bin")
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
                                                                   diskImages: { _ in calls.append("list"); return [] },
                                                                   quitCopies: { _ in calls.append("quit") },
                                                                   eject: { _ in calls.append("eject") }))
        self.delegate = delegate
        launch(delegate)
        spin(1.5)  // past the second after launch when the installed copy ejects
        XCTAssertEqual(calls, [])
    }

    func testTheEjectorWaitsForTheInstallerQuitsOldCopiesThenEjectsEveryImage() throws {
        let images = ["Peekaboo 20261126-85dff6", "Peekaboo 20261126-69a847", "Peekaboo"].map {
            URL(fileURLWithPath: "/Volumes/\($0)", isDirectory: true)
        }
        let shown = [URL(fileURLWithPath: "/home/someone/a.jpg")]
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
                                                    diskImages: { keeping in
            record("list keeping \(keeping.map(\.lastPathComponent))")
            return images
        }, quitCopies: { record("quit copies on \($0.count) images") }, eject: { url in
            record("eject \(url.lastPathComponent)")
            if url.lastPathComponent == "Peekaboo 20261126-69a847" { throw busy }  // in use for good
            if url.lastPathComponent == "Peekaboo", busyOnce {  // in use for a moment
                busyOnce = false
                throw busy
            }
        }), retryDelay: 0)
        var result: [DiskImageEjector.Failure]?
        var askedOnMain = false
        ejector.run(after: 4242, keeping: {
            askedOnMain = Thread.isMainThread
            return shown
        }) { failures in
            XCTAssertTrue(Thread.isMainThread)
            result = failures
        }
        XCTAssertTrue(spin(5) { result != nil })
        XCTAssertTrue(askedOnMain, "the files shown are read on the main thread")
        // The images in use are tried once more.
        XCTAssertEqual(lock.withLock { calls }, ["wait 4242", "list keeping [\"a.jpg\"]", "quit copies on 3 images",
                                                 "eject Peekaboo 20261126-85dff6", "eject Peekaboo 20261126-69a847", "eject Peekaboo",
                                                 "eject Peekaboo 20261126-69a847", "eject Peekaboo"])
        XCTAssertEqual(result, [DiskImageEjector.Failure(image: images[1], busy: true)])
        XCTAssertEqual(DiskImageEjector.toast("Peekaboo 26 is installed in Applications", failures: result ?? []),
                       "Peekaboo 26 is installed in Applications\n"
                       + "“Peekaboo 20261126-69a847” is in use: quit the app that uses it, then eject it in Finder")

        // No image mounted: nothing to quit, nothing to eject.
        result = nil
        calls = []
        DiskImageEjector(hooks: .init(waitForExit: { _ in false }, diskImages: { _ in [] },
                                      quitCopies: { _ in record("quit") }, eject: { _ in XCTFail("ejected") }))
            .run(after: 4242, keeping: { [] }) { result = $0 }
        XCTAssertTrue(spin(5) { result != nil })
        XCTAssertEqual(result, [])
        XCTAssertEqual(lock.withLock { calls }, [])
        XCTAssertEqual(DiskImageEjector.toast("Peekaboo 26 is installed in Applications", failures: []),
                       "Peekaboo 26 is installed in Applications")

        // An image that failed for another reason is not tried again, nor said to be in use.
        result = nil
        var attempts = 0
        DiskImageEjector(hooks: .init(waitForExit: { _ in true }, diskImages: { _ in images }, quitCopies: { _ in }, eject: { _ in
            attempts += 1
            throw CocoaError(.fileWriteNoPermission)
        })).run(after: 1, keeping: { [] }) { result = $0 }
        XCTAssertTrue(spin(5) { result != nil })
        XCTAssertEqual(attempts, 3, "an image that is not in use is not tried again")
        XCTAssertEqual(DiskImageEjector.toast("Installed", failures: result ?? []),
                       "Installed\nCould not eject “Peekaboo 20261126-85dff6”, “Peekaboo 20261126-69a847”, “Peekaboo”: eject them in Finder")
        let both = images.prefix(2).map { DiskImageEjector.Failure(image: $0, busy: true) }
        XCTAssertEqual(DiskImageEjector.toast("Installed", failures: both),
                       "Installed\n“Peekaboo 20261126-85dff6”, “Peekaboo 20261126-69a847” are in use: "
                       + "quit the apps that use them, then eject them in Finder")
        XCTAssertTrue(DiskImageEjector.isBusy(NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))))
        XCTAssertFalse(DiskImageEjector.isBusy(NSError(domain: NSOSStatusErrorDomain, code: -36)))
    }

    func testTheEjectorLeavesTheImagesAnotherUserMounted() throws {
        // Two accounts logged in at once (#90): the copy installed in one ejected the image the other had opened, tried
        // to unmount the one the other's Peekaboo ran from, and its toast would have named both. The images here are the
        // ones `AppInstall.diskImages` finds, for this process's user, among volumes faked as folders of the test's.
        let volumes = root.appendingPathComponent("Volumes", isDirectory: true)
        let other: uid_t = getuid() == 501 ? 502 : 501
        func image(_ name: String, owner: uid_t) throws -> AppInstall.Volume {
            let url = volumes.appendingPathComponent(name, isDirectory: true)
            _ = try fakePeekabooApp(in: url, version: releaseVersion(26))
            return AppInstall.Volume(url: url, isReadOnly: true, isLocal: true, owner: owner)
        }
        let theirs = [try image("Peekaboo 20261126-6c7b06", owner: other), try image("Peekaboo 20261126-85dff6", owner: other)]
        let mine = try image("Peekaboo 20261126-517cb0", owner: getuid())
        let lock = NSLock()
        var quit: [[String]] = [], ejected: [String] = []
        /// Run an ejector over `mounted`, every eject failing as an image in use (so that each one tried is named in the
        /// toast); the images that stay.
        func eject(_ mounted: [AppInstall.Volume]) -> [DiskImageEjector.Failure]? {
            var result: [DiskImageEjector.Failure]?
            DiskImageEjector(hooks: .init(waitForExit: { _ in true }, diskImages: { keeping in
                AppInstall.diskImages(in: mounted, under: volumes.path + "/", keeping: keeping, isDiskImage: { _ in true })
            }, quitCopies: { images in lock.withLock { quit.append(images.map(\.lastPathComponent)) } }, eject: { url in
                lock.withLock { ejected.append(url.lastPathComponent) }
                throw NSError(domain: NSOSStatusErrorDomain, code: -47)
            }), retryDelay: 0).run(after: 4242, keeping: { [] }) { result = $0 }
            XCTAssertTrue(spin(5) { result != nil })
            return result
        }

        let failures = try XCTUnwrap(eject([theirs[0], mine, theirs[1]]))
        XCTAssertEqual(lock.withLock { quit }, [[mine.url.lastPathComponent]], "only the copies that run from this user's image")
        XCTAssertEqual(lock.withLock { ejected }, [mine.url.lastPathComponent, mine.url.lastPathComponent], "in use: tried twice")
        let toast = DiskImageEjector.toast("Installed", failures: failures)
        XCTAssertEqual(toast, "Installed\n“Peekaboo 20261126-517cb0” is in use: quit the app that uses it, then eject it in Finder")
        for volume in theirs { XCTAssertFalse(toast.contains(volume.url.lastPathComponent), volume.url.lastPathComponent) }

        // Only the other user's images mounted: nothing is quit or ejected, and the toast names none.
        lock.withLock { (quit, ejected) = ([], []) }
        XCTAssertEqual(eject(theirs), [])
        XCTAssertEqual(lock.withLock { quit }, [])
        XCTAssertEqual(lock.withLock { ejected }, [])
    }

    func testTheInstalledCopySaysWhatItIsAndWhere() {
        let home = URL(fileURLWithPath: "/home/someone", isDirectory: true)
        let system = URL(fileURLWithPath: "/Applications/Peekaboo.app", isDirectory: true)
        let user = URL(fileURLWithPath: "/home/someone/Applications/Peekaboo.app", isDirectory: true)
        XCTAssertEqual(DiskImageEjector.installedText(version: "20261126-85dff6", app: system, keptNewer: false, home: home),
                       "Peekaboo 20261126-85dff6 is installed in Applications")
        XCTAssertEqual(DiskImageEjector.installedText(version: "20261126-85dff6", app: user, keptNewer: false, home: home),
                       "Peekaboo 20261126-85dff6 is installed in Applications in your home folder")
        // The disk image's copy was older: nothing was installed.
        XCTAssertEqual(DiskImageEjector.installedText(version: "20261127-aaaaaa", app: system, keptNewer: true, home: home),
                       "A newer Peekaboo (20261127-aaaaaa) is already in Applications")
        XCTAssertEqual(DiskImageEjector.installedText(version: nil, app: system, keptNewer: false, home: home),
                       "Peekaboo is installed in Applications")
    }
}
