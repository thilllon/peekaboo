import AppKit
import XCTest
@testable import PeekabooApp
@testable import PeekabooCore

/// A newer Peekaboo opened from a disk image while an older one runs (`DiskImageUpdate`, issue #86), with every hook
/// faked: the volumes are folders of the test's, staging copies a fake bundle, the updater is a stand-in, and nothing is
/// spawned, opened, ejected or quit. The running copy is build 25.
final class DiskImageUpdateTests: ViewerTestCase {
    /// The system behind the hooks. `volumes` and `stage` are called on the utility queue: that state is locked.
    private final class System: @unchecked Sendable {
        let center = NotificationCenter()
        private let lock = NSLock()
        private var mounted: [AppInstall.Volume] = []
        private var plainVolumes: Set<String> = []
        private var askedVolumes: [String] = []
        private var stageCalls: [AppVersion] = []
        private var failingVersions: Set<AppVersion> = []
        private var stageGate: DispatchSemaphore?
        private var volumesGate: DispatchSemaphore?
        // Main thread.
        var jobs: [UpdateInstaller.Job] = []
        /// When each of `jobs` was started.
        var started: [Date] = []
        var terminations = 0
        var active = false
        var spawnError: Error?

        var volumes: [AppInstall.Volume] {
            get { lock.withLock { mounted } }
            set { lock.withLock { mounted = newValue } }
        }
        /// Volumes (paths) that are no disk images: a locked card, a read-only drive.
        var notDiskImages: Set<String> {
            get { lock.withLock { plainVolumes } }
            set { lock.withLock { plainVolumes = newValue } }
        }
        /// Names of the volumes DiskArbitration was asked about, in order.
        var asked: [String] { lock.withLock { askedVolumes } }
        /// Versions staging was asked for, in order.
        var staged: [AppVersion] { lock.withLock { stageCalls } }
        /// Versions whose copy fails its checks.
        var failing: Set<AppVersion> {
            get { lock.withLock { failingVersions } }
            set { lock.withLock { failingVersions = newValue } }
        }
        /// Staging waits for it when set: a copy that takes its time.
        var gate: DispatchSemaphore? {
            get { lock.withLock { stageGate } }
            set { lock.withLock { stageGate = newValue } }
        }
        /// Listing the volumes waits for it when set: a scan that has not got as far as a copy yet (an unresponsive
        /// network share, a busy disk image).
        var listGate: DispatchSemaphore? {
            get { lock.withLock { volumesGate } }
            set { lock.withLock { volumesGate = newValue } }
        }

        func hooks() -> DiskImageUpdate.Hooks {
            DiskImageUpdate.Hooks(volumes: { [unowned self] in
                XCTAssertFalse(Thread.isMainThread, "the volumes are listed off the main thread")
                listGate?.wait()
                return volumes
            }, isDiskImage: { [unowned self] url in
                XCTAssertFalse(Thread.isMainThread)
                lock.withLock { askedVolumes.append(url.lastPathComponent) }
                return !notDiskImages.contains(url.standardizedFileURL.path)
            }, stage: { [unowned self] app, version, root in
                XCTAssertFalse(Thread.isMainThread, "staging runs off the main thread")
                lock.withLock { stageCalls.append(version) }
                gate?.wait()
                if failing.contains(version) { throw UpdateError.verification("code signature not valid") }
                let folder = root.appendingPathComponent(version.token, isDirectory: true)
                try? FileManager.default.removeItem(at: folder)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let staged = folder.appendingPathComponent("Peekaboo.app", isDirectory: true)
                try FileManager.default.copyItem(at: app, to: staged)
                return staged
            }, spawn: { [unowned self] job in
                XCTAssertTrue(Thread.isMainThread)
                if let spawnError { throw spawnError }
                jobs.append(job)
                started.append(Date())
            }, terminate: { [unowned self] in terminations += 1 }, isActive: { [unowned self] in active },
               notifications: { [unowned self] in
                // Registering the workspace observers costs ~1 ms on the main thread.
                XCTAssertFalse(Thread.isMainThread, "the workspace observers are registered on the utility queue")
                return center
            })
        }
    }

    /// The in-app updater, as the disk-image update sees it.
    private final class FakeUpdater: UpdateInstalling {
        var readyBuild: Int?
        var helperStarted = false
        var installsOnQuit = false
        var restartSucceeds = true
        private(set) var restarts: [(file: URL?, eject: Bool)] = []
        private(set) var quitInstalls = 0
        private(set) var kept: [AppVersion?] = []

        func restartToUpdate(reopening file: URL?, ejectingDiskImages: Bool) -> Bool {
            restarts.append((file, ejectingDiskImages))
            if restartSucceeds { helperStarted = true }
            return restartSucceeds
        }

        func installOnQuit() { quitInstalls += 1 }
        func keepStaged(_ version: AppVersion?) { kept.append(version) }
    }

    private var system: System!
    private var updater: FakeUpdater!
    /// The running Peekaboo.app (build 25), in the test's Applications folder.
    private var running: URL!
    private var delegate: AppDelegate?
    private var savedConfig: String?
    private var cache: URL { root.appendingPathComponent("cache", isDirectory: true) }
    /// Where copies are staged: the cache's Updates folder (the running app is on the same volume).
    private var stagingRoot: URL { UpdateInstaller.updatesFolder(in: cache) }

    override func setUpWithError() throws {
        try super.setUpWithError()
        system = System()
        updater = FakeUpdater()
        running = try fakePeekabooApp(in: root.appendingPathComponent("Applications", isDirectory: true),
                                      version: releaseVersion(25)).bundleURL
        // An app delegate's config store reads PEEKABOO_CONFIG when it is created: a file of the test's, never the user's.
        savedConfig = ProcessInfo.processInfo.environment["PEEKABOO_CONFIG"]
        let config = root.appendingPathComponent("launch.toml")
        try Data().write(to: config)
        setenv("PEEKABOO_CONFIG", config.path, 1)
        guard ConfigStore.defaultURL.path == config.path else { throw XCTSkip("PEEKABOO_CONFIG is not read back") }
    }

    override func tearDown() {
        if let viewer: ViewerWindowController = delegate.flatMap({ property($0, "viewer") }) {
            viewer.window?.close()
            spin(0.05)
        }
        delegate = nil
        if let savedConfig { setenv("PEEKABOO_CONFIG", savedConfig, 1) } else { unsetenv("PEEKABOO_CONFIG") }
        super.tearDown()
    }

    private func makeUpdate(system: System? = nil, updater: FakeUpdater? = nil, user: uid_t = getuid(),
                            scanDelay: TimeInterval = 60, activationDelay: TimeInterval = 0) -> DiskImageUpdate {
        DiskImageUpdate(app: running, current: releaseVersion(25), cache: cache, updates: updater ?? self.updater,
                        volumesRoot: root.path + "/Volumes/", user: user, scanDelay: scanDelay, activationDelay: activationDelay,
                        settleDelay: 0, hooks: (system ?? self.system).hooks())
    }

    /// A uid other than this process's: the account logged in next to this one.
    private static let anotherUser: uid_t = getuid() == 501 ? 502 : 501

    /// The staged copy of `version`.
    private func staged(_ version: AppVersion) -> URL {
        stagingRoot.appendingPathComponent("\(version.token)/Peekaboo.app", isDirectory: true)
    }

    /// A volume of the test's with a Peekaboo.app of `version` at its top (nil: none; another bundle identifier with
    /// `identifier`, the macOS it needs with `minimumSystemVersion`; with `linked`, the Peekaboo.app on the volume is a
    /// symbolic link to that bundle, kept outside the volume), mounted in `system` from now on by `owner` (this process's
    /// user by default): a disk image unless `diskImage` is false; `post` sends the mount notification.
    @discardableResult
    private func mount(_ name: String, _ version: AppVersion?, identifier: String = CodeSignature.bundleIdentifier,
                       minimumSystemVersion: String? = nil, linked: Bool = false, readOnly: Bool = true, local: Bool = true,
                       diskImage: Bool = true, owner: uid_t = getuid(), under parent: String = "Volumes",
                       in system: System? = nil, post: Bool = true) throws -> AppInstall.Volume {
        let system = system ?? self.system!
        let url = root.appendingPathComponent("\(parent)/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let version {
            let folder = linked ? root.appendingPathComponent("elsewhere/\(name)", isDirectory: true) : url
            let app = try fakePeekabooApp(in: folder, version: version).bundleURL
            var info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version.name,
                                       "CFBundleVersion": String(version.build), "CFBundleExecutable": "Peekaboo"]
            if let minimumSystemVersion { info["LSMinimumSystemVersion"] = minimumSystemVersion }
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
            if linked {
                try FileManager.default.createSymbolicLink(at: url.appendingPathComponent("Peekaboo.app"), withDestinationURL: app)
            }
        }
        if !diskImage { system.notDiskImages.insert(url.standardizedFileURL.path) }
        let volume = AppInstall.Volume(url: url, isReadOnly: readOnly, isLocal: local, owner: owner)
        system.volumes.append(volume)
        if post { notify(NSWorkspace.didMountNotification, url, in: system) }
        return volume
    }

    private func notify(_ name: Notification.Name, _ volume: URL, in system: System? = nil) {
        (system ?? self.system).center.post(name: name, object: nil, userInfo: [NSWorkspace.volumeURLUserInfoKey: volume])
    }

    private func unmount(_ volume: AppInstall.Volume) {
        system.volumes.removeAll { $0 == volume }
        notify(NSWorkspace.didUnmountNotification, volume.url)
    }

    /// Start `update` and wait until it watches the mounts (it registers its observers on its utility queue).
    private func watch(_ update: DiskImageUpdate, line: UInt = #line) {
        update.start()
        XCTAssertTrue(spin(5) { update.isWatching }, "not watching the mounts", line: line)
    }

    /// A component that has staged `version` from a volume of the test's, and is done looking at the mount.
    private func stagedUpdate(_ version: AppVersion = releaseVersion(26), system: System? = nil,
                              updater: FakeUpdater? = nil) throws -> DiskImageUpdate {
        let update = makeUpdate(system: system, updater: updater)
        watch(update)
        try mount("Peekaboo \(version.build)", version, in: system)
        XCTAssertTrue(spin(5) { update.pending?.version == version && update.looking == 0 }, "\(version) was not staged")
        return update
    }

    /// A headless app delegate that has finished launching, so that its second-after-launch setup follows, with `files`
    /// opened as open-documents events. (Its command line, the test runner's, is never read.)
    private func launchDelegate(opening files: [URL] = []) -> AppDelegate {
        let delegate = AppDelegate()
        delegate.presentation = .headless
        self.delegate = delegate
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        if !files.isEmpty { delegate.application(NSApp, open: files) }
        return delegate
    }

    private static let activation = Notification(name: NSApplication.didBecomeActiveNotification)

    // MARK: Which runs watch

    func testOnlyTheInteractivePeekabooAppWatchesDiskImages() throws {
        let bundle = try XCTUnwrap(Bundle(url: running))
        func update(_ presentation: Presentation = .interactive, selfTest: Bool = false, installing: Bool = false,
                    scripted: Bool = false, bundle: Bundle) -> DiskImageUpdate? {
            DiskImageUpdate.forApp(bundle: bundle, presentation: presentation, selfTest: selfTest, installing: installing,
                                   isScripted: { scripted }, updates: nil)
        }
        let found = try XCTUnwrap(update(bundle: bundle))  // never started: nothing is registered
        XCTAssertEqual(found.app, running)
        XCTAssertEqual(found.current, releaseVersion(25))
        XCTAssertEqual(found.user, getuid(), "only the disk images this user mounts count")
        XCTAssertNil(update(.headless, bundle: bundle), "tests")
        XCTAssertNil(update(selfTest: true, bundle: bundle))
        XCTAssertNil(update(installing: true, bundle: bundle), "a copy that installs itself")
        XCTAssertNil(update(scripted: true, bundle: bundle), "PEEKABOO_ACTIONS")
        XCTAssertNil(update(bundle: .main), "the test runner is not Peekaboo.app")

        // A headless app delegate, past the second after launch when the interactive app sets it up: none.
        let delegate = launchDelegate()
        spin(1.5)
        XCTAssertNil(delegate.diskImageUpdate)
    }

    // MARK: Staging

    func testOnlyANewerPeekabooOnAReadOnlyVolumeIsStaged() throws {
        let update = makeUpdate()
        watch(update)
        try mount("Peekaboo 24", releaseVersion(24), post: false)
        try mount("Peekaboo 25", releaseVersion(25), post: false)  // the running build
        try mount("Other", releaseVersion(27), identifier: "com.example.Peekaboo", post: false)
        try mount("SSD", releaseVersion(27), readOnly: false, post: false)  // a writable drive the app may be kept on
        // Read-only but no disk image (a locked card), or a network share: never read, so macOS never asks the user for
        // the Removable or Network Volumes permission on Peekaboo's behalf.
        try mount("Locked card", releaseVersion(27), diskImage: false, post: false)
        try mount("Share", releaseVersion(27), local: false, post: false)
        try mount("Elsewhere", releaseVersion(27), under: "mnt", post: false)  // not under /Volumes
        try mount("Photos", nil, post: false)
        // A Peekaboo.app that is a symbolic link could point anywhere: to a folder of the user's, whose quarantine
        // flags staging would clear, or to a copy someone else may change once it is installed.
        try mount("Link", releaseVersion(27), linked: true, post: false)
        try mount("Later", releaseVersion(27), minimumSystemVersion: "99.0", post: false)  // would not start on this macOS
        try mount("Peekaboo 26", releaseVersion(26), minimumSystemVersion: "14.0")
        XCTAssertTrue(spin(5) { update.pending?.version == releaseVersion(26) })
        XCTAssertEqual(system.staged, [releaseVersion(26)], "only the newer Peekaboo is copied")
        XCTAssertEqual(update.pending, DiskImageUpdate.Copy(version: releaseVersion(26), app: staged(releaseVersion(26))))
        XCTAssertEqual(updater.kept, [releaseVersion(26)], "the updater's clean-ups leave it")

        // The newest first; one that fails its checks is left, and the one it would have superseded stays.
        system.failing = [releaseVersion(28)]
        try mount("Peekaboo 28", releaseVersion(28), post: false)
        let newest = try mount("Peekaboo 27", releaseVersion(27))
        XCTAssertTrue(spin(5) { update.pending?.version == releaseVersion(27) })
        XCTAssertEqual(system.staged, [releaseVersion(26), releaseVersion(28), releaseVersion(27)])
        XCTAssertEqual(updater.kept, [releaseVersion(26), releaseVersion(27)])
        XCTAssertTrue(spin(5) { !FileManager.default.fileExists(atPath: self.staged(releaseVersion(26)).path) },
                      "the copy it supersedes goes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged(releaseVersion(27)).path))

        // Unmounted, the staged copy stays pending; mounted again, the same copy is not newer than itself.
        unmount(newest)
        let again = try mount("Peekaboo 27", releaseVersion(27))
        XCTAssertTrue(spin(5) { update.looking == 0 })
        XCTAssertEqual(update.pending?.version, releaseVersion(27))
        XCTAssertEqual(system.staged.count, 3)
        // An unmount makes the volume new again: another image mounted at the same place is looked at.
        unmount(again)
        try mount("Peekaboo 27", releaseVersion(29))
        XCTAssertTrue(spin(5) { update.pending?.version == releaseVersion(29) }, "the volume mounted there again was not read")
        XCTAssertEqual(system.staged, [releaseVersion(26), releaseVersion(28), releaseVersion(27), releaseVersion(29)])
    }

    func testADiskImageAnotherUserMountedIsNeverStagedFrom() throws {
        // Two accounts logged in at once (#90): a newer Peekaboo on a disk image the other account opened is not this
        // user's to install. Such a volume is neither asked about (DiskArbitration) nor read.
        let other = Self.anotherUser
        let update = makeUpdate()
        watch(update)
        try mount("Peekaboo 27", releaseVersion(27), owner: other, post: false)
        try mount("Peekaboo 28", releaseVersion(28), owner: 0)  // attached by root (`sudo hdiutil attach`)
        XCTAssertTrue(spin(5) { update.looking == 0 })
        XCTAssertEqual(system.asked, [])
        XCTAssertEqual(system.staged, [])
        XCTAssertNil(update.pending)

        // This user's image is staged as before; the others' are still left.
        try mount("Peekaboo 26", releaseVersion(26))
        XCTAssertTrue(spin(5) { update.pending?.version == releaseVersion(26) && update.looking == 0 })
        XCTAssertEqual(system.asked, ["Peekaboo 26"])
        XCTAssertEqual(system.staged, [releaseVersion(26)])

        // The other account ejects its image (that unmount need not be posted here) and this user opens one at the same
        // place: never counted as looked at, the place is looked at now.
        system.volumes.removeAll { $0.owner == other }
        try mount("Peekaboo 27", releaseVersion(27))
        XCTAssertTrue(spin(5) { update.pending?.version == releaseVersion(27) }, "this user's image was taken for the other's")
        XCTAssertEqual(system.staged, [releaseVersion(26), releaseVersion(27)])

        // The user given is the one compared: the other account's copy stages from its own images only.
        let theirs = System()
        let theirUpdate = makeUpdate(system: theirs, user: other)
        watch(theirUpdate)
        try mount("Peekaboo 29", releaseVersion(29), in: theirs, post: false)  // this process's user's
        try mount("Peekaboo 28", releaseVersion(28), owner: other, in: theirs)
        XCTAssertTrue(spin(5) { theirUpdate.pending?.version == releaseVersion(28) && theirUpdate.looking == 0 })
        XCTAssertEqual(theirs.asked, ["Peekaboo 28"])
        XCTAssertEqual(theirs.staged, [releaseVersion(28)])
    }

    func testTheStartupScanStagesACopyMountedBeforeAndClearsStaleOnes() throws {
        // What earlier runs staged: older builds, this one (installed by now), and a newer one the updater may install.
        for build in [24, 25, 27] {
            _ = try fakePeekabooApp(in: stagingRoot.appendingPathComponent(releaseVersion(build).token), version: releaseVersion(build))
        }
        try mount("Peekaboo 26", releaseVersion(26), post: false)
        let update = makeUpdate(scanDelay: 0.05)
        watch(update)
        XCTAssertTrue(spin(5) { update.pending?.version == releaseVersion(26) }, "the image mounted at launch")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: stagingRoot.path)),
                       [releaseVersion(26).token, releaseVersion(27).token])
    }

    func testACopyThatFailedToInstallBeforeIsNotStagedAgain() throws {
        // The installer could not put 26 in place of this app: staging it again would relaunch the app over and over.
        UpdateInstaller.Failure(version: releaseVersion(26), target: running, reason: "Operation not supported").write(in: cache)
        let update = makeUpdate()
        watch(update)
        try mount("Peekaboo 26", releaseVersion(26))
        spin(0.5)
        XCTAssertEqual(system.staged, [])
        try mount("Peekaboo 27", releaseVersion(27))
        XCTAssertTrue(spin(5) { update.pending?.version == releaseVersion(27) }, "a newer release is")
        XCTAssertEqual(system.staged, [releaseVersion(27)])
    }

    func testAnAppThatCannotReplaceItselfStagesNothing() throws {
        let folder = running.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        guard access(folder.path, W_OK) != 0 else { throw XCTSkip("running as root: every folder is writable") }
        let update = makeUpdate(scanDelay: 0)
        watch(update)
        try mount("Peekaboo 26", releaseVersion(26))
        spin(0.5)
        XCTAssertEqual(system.staged, [])
        XCTAssertNil(update.pending)
    }

    // MARK: Handing over

    func testActivationHandsOverOnceWithTheShownFileAndTheEjectOption() throws {
        let a = writeImage(folder.appendingPathComponent("a.jpg"), width: 64, height: 48, gray: 0.3)
        let delegate = launchDelegate(opening: [a])
        let viewer: ViewerWindowController = try XCTUnwrap(property(delegate, "viewer"))
        XCTAssertTrue(spin(5) { viewer.displayedFile?.name == "a.jpg" })
        let update = makeUpdate()
        delegate.diskImageUpdate = update
        watch(update)

        // Nothing staged: an activation changes nothing, a Dock click behaves as before.
        delegate.applicationDidBecomeActive(Self.activation)
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        XCTAssertEqual(system.jobs, [])

        try mount("Peekaboo 26", releaseVersion(26))
        XCTAssertTrue(spin(5) { update.pending != nil })
        XCTAssertEqual(system.jobs, [], "staging alone installs nothing")
        system.active = true
        delegate.applicationDidBecomeActive(Self.activation)
        XCTAssertTrue(spin(5) { self.system.jobs.count == 1 })
        let shown = try XCTUnwrap(viewer.pipeline.currentFile?.url)
        XCTAssertEqual(shown.lastPathComponent, "a.jpg")
        let expected = UpdateInstaller.Job(pid: getpid(), staged: staged(releaseVersion(26)), target: running,
                                           version: releaseVersion(26), relaunch: true, reopen: shown, ejectDiskImages: true)
        XCTAssertEqual(system.jobs, [expected])
        XCTAssertEqual(system.terminations, 1)
        XCTAssertTrue(update.handedOver)

        // A reopen event that comes along, another activation and the quit that follows: nothing more.
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false), "no window to bring back")
        delegate.applicationDidBecomeActive(Self.activation)
        spin(0.1)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertEqual(system.jobs, [expected], "never a second installer")
        XCTAssertEqual(system.terminations, 1)
        XCTAssertEqual(updater.quitInstalls, 0, "nor the updater's")
        XCTAssertTrue(updater.restarts.isEmpty)
    }

    func testTheRelaunchedCopyOpensTheFileOpenedWithTheActivation() throws {
        // A double-click on a photo in Finder activates the app and sends the photo, in either order: the hand-over waits
        // a moment after the activation, so that the relaunched copy opens that photo, not the one shown before.
        let a = writeImage(folder.appendingPathComponent("a.jpg"), width: 64, height: 48, gray: 0.3)
        let other = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let b = writeImage(other.appendingPathComponent("b.jpg"), width: 64, height: 48, gray: 0.6)
        let delegate = launchDelegate(opening: [a])
        let viewer: ViewerWindowController = try XCTUnwrap(property(delegate, "viewer"))
        XCTAssertTrue(spin(5) { viewer.displayedFile?.name == "a.jpg" })
        let update = makeUpdate(activationDelay: 0.3)
        delegate.diskImageUpdate = update
        watch(update)
        try mount("Peekaboo 26", releaseVersion(26))
        XCTAssertTrue(spin(5) { update.pending != nil })
        system.active = true
        delegate.applicationDidBecomeActive(Self.activation)
        var opened = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak delegate] in
            delegate?.application(NSApp, open: [b])
            opened = true
        }
        // Both, so that the late open never outlives the test.
        XCTAssertTrue(spin(5) { opened && self.system.jobs.count == 1 })
        XCTAssertEqual(system.jobs.first?.reopen?.lastPathComponent, "b.jpg")
    }

    func testAHandOverNeverComesSoonerThanTheActivationDelay() throws {
        // A copy staged (and its mount looked at) a moment after the activation: the photo opened from Finder with that
        // activation may still be on its way, so the hand-over waits the whole delay all the same.
        let update = makeUpdate(activationDelay: 0.4)
        watch(update)
        let gate = DispatchSemaphore(value: 0)
        system.gate = gate
        try mount("Peekaboo 26", releaseVersion(26))
        XCTAssertTrue(spin(5) { update.staging == 1 })
        system.active = true
        let activation = Date()
        update.activated()
        gate.signal()
        XCTAssertTrue(spin(5) { self.system.jobs.count == 1 })
        let waited = try XCTUnwrap(system.started.first).timeIntervalSince(activation)
        XCTAssertGreaterThan(waited, 0.39, "handed over \(waited) s after the activation")
    }

    func testAHandOverWaitsForAFileOperationAndFollowsWhenItEnds() throws {
        let update = try stagedUpdate()
        var busy = true
        update.isRunningFileOperation = { busy }
        system.active = true
        XCTAssertFalse(update.activated(), "a copy or move runs")
        spin(0.2)
        XCTAssertEqual(system.jobs, [])
        busy = false
        update.fileOperationsEnded()
        XCTAssertTrue(spin(5) { self.system.jobs.count == 1 }, "the hand-over follows once it has ended")
        XCTAssertEqual(system.jobs.first?.version, releaseVersion(26))
        XCTAssertEqual(system.terminations, 1)

        // Ended while the app is no longer in front: at the next activation instead.
        let later = System()
        let second = try stagedUpdate(system: later)
        busy = true
        second.isRunningFileOperation = { busy }
        XCTAssertFalse(second.activated())
        busy = false
        second.fileOperationsEnded()
        spin(0.2)
        XCTAssertEqual(later.jobs, [])
        later.active = true
        second.activated()
        XCTAssertTrue(spin(5) { later.jobs.count == 1 })
    }

    func testTheAppDelegateConnectsTheUpdateToTheViewersFileOperations() throws {
        // What `AppDelegate.connect` wires, through the viewer's real file actions: a copy running in the viewer holds
        // the hand-over back, and the end of one lets a held-back hand-over follow.
        let a = writeImage(folder.appendingPathComponent("a.jpg"), width: 64, height: 48, gray: 0.3)
        let delegate = launchDelegate(opening: [a])
        let viewer: ViewerWindowController = try XCTUnwrap(property(delegate, "viewer"))
        XCTAssertTrue(spin(5) { viewer.displayedFile?.name == "a.jpg" })
        let update = try stagedUpdate()
        delegate.diskImageUpdate = update
        let first = root.appendingPathComponent("first", isDirectory: true)
        viewer.perform(.copy(first.path))
        XCTAssertTrue(update.isRunningFileOperation(), "the viewer's copy runs in the background")
        XCTAssertTrue(spin(5) { !update.isRunningFileOperation() })
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.appendingPathComponent("a.jpg").path))

        // Held back (by a stand-in, so that nothing but the end of the next copy can let it follow), then released by
        // the end of a real copy.
        var busy = true
        update.isRunningFileOperation = { busy }
        system.active = true
        delegate.applicationDidBecomeActive(Self.activation)
        spin(0.2)
        XCTAssertEqual(system.jobs, [], "held back")
        busy = false
        viewer.perform(.copy(root.appendingPathComponent("second", isDirectory: true).path))
        XCTAssertTrue(spin(5) { self.system.jobs.count == 1 }, "the end of the viewer's copy never reached the update")
        XCTAssertEqual(system.jobs.first?.reopen?.lastPathComponent, "a.jpg")
        XCTAssertEqual(system.terminations, 1)
    }

    func testFileActionsSayWhileTheyRunInTheBackgroundAndWhenTheyEnd() throws {
        let viewer = try makeViewer()
        let urls = writeSequence(3)
        openAndWait(viewer, [urls[0]])
        var ended = 0
        viewer.onFileOperationsEnded = { ended += 1 }
        XCTAssertFalse(viewer.isRunningFileOperation)
        let copies = root.appendingPathComponent("copies", isDirectory: true)
        viewer.perform(.copy(copies.path))
        XCTAssertTrue(viewer.isRunningFileOperation, "a copy runs off the main thread")
        XCTAssertTrue(spin(5) { ended == 1 })
        XCTAssertFalse(viewer.isRunningFileOperation)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copies.appendingPathComponent("img00.jpg").path))
    }

    func testAHandOverWaitsForAMenuOrAModalPanelToClose() throws {
        let update = try stagedUpdate()
        system.active = true
        var result: Bool?
        // What an alert, the folder panel or a menu runs: an event loop in a mode of its own.
        RunLoop.main.perform(inModes: [.modalPanel]) { result = update.activated() }
        RunLoop.main.run(mode: .modalPanel, before: Date().addingTimeInterval(0.1))
        XCTAssertEqual(result, false)
        XCTAssertEqual(system.jobs, [], "nothing while the panel is up")
        XCTAssertTrue(spin(5) { self.system.jobs.count == 1 }, "once the run loop is back in its default mode")
    }

    func testAnActivationWhileACopyIsStagedWaitsForIt() throws {
        let update = makeUpdate()
        watch(update)
        let gate = DispatchSemaphore(value: 0)
        system.gate = gate
        try mount("Peekaboo 26", releaseVersion(26))
        XCTAssertTrue(spin(5) { update.staging == 1 })
        system.active = true
        XCTAssertFalse(update.activated(), "not staged yet")
        gate.signal()
        XCTAssertTrue(spin(5) { self.system.jobs.count == 1 }, "the hand-over follows once it is")
        XCTAssertEqual(system.jobs.first?.version, releaseVersion(26))

        // With an older copy staged, a newer one on its way is waited for: the newest installs.
        let later = System()
        let second = try stagedUpdate(system: later)
        later.gate = gate
        try mount("Peekaboo 27", releaseVersion(27), in: later)
        XCTAssertTrue(spin(5) { second.staging == 1 })
        later.active = true
        XCTAssertFalse(second.activated())
        gate.signal()
        XCTAssertTrue(spin(5) { later.jobs.count == 1 })
        XCTAssertEqual(later.jobs.first?.version, releaseVersion(27))
    }

    func testAnActivationBeforeTheMountIsLookedAtWaitsForIt() throws {
        // The double-click on the copy can bring the app forward before the scan of its mount has got as far as the
        // copy (a napped app, a sleeping network share among the volumes listed): that activation is the one that
        // counts.
        let update = makeUpdate()
        watch(update)
        let gate = DispatchSemaphore(value: 0)
        system.listGate = gate
        try mount("Peekaboo 26", releaseVersion(26))
        XCTAssertEqual(update.looking, 1, "counted as it is posted, on the main thread")
        XCTAssertEqual(update.staging, 0)
        system.active = true
        XCTAssertFalse(update.activated())
        spin(0.2)
        XCTAssertEqual(system.jobs, [], "nothing is staged yet")
        gate.signal()
        XCTAssertTrue(spin(5) { self.system.jobs.count == 1 }, "the hand-over follows once the copy is staged")
        XCTAssertEqual(system.jobs.first?.version, releaseVersion(26))
        XCTAssertEqual(update.looking, 0)

        // A mount with no newer Peekaboo on it: the activation that waited for it changes nothing.
        let later = System()
        later.listGate = gate
        let other = makeUpdate(system: later)
        watch(other)
        try mount("Photos", nil, in: later)
        later.active = true
        XCTAssertFalse(other.activated())
        gate.signal()
        XCTAssertTrue(spin(5) { other.looking == 0 })
        spin(0.1)
        XCTAssertEqual(later.jobs, [])
        XCTAssertEqual(later.terminations, 0)
    }

    func testTheUpdatersDownloadInstallsInsteadWhenItIsAsNewOrNewer() throws {
        let photo = URL(fileURLWithPath: "/Photos/a.jpg")
        for (ready, viaUpdater) in [(26, true), (27, true), (25, false)] {
            let system = System(), updater = FakeUpdater()
            updater.readyBuild = ready
            system.active = true
            let update = try stagedUpdate(system: system, updater: updater)
            update.shownFile = { photo }
            update.activated()
            XCTAssertTrue(spin(5) { system.terminations == 1 }, "\(ready)")
            XCTAssertEqual(updater.restarts.map(\.file), viaUpdater ? [photo] : [], "\(ready)")
            XCTAssertEqual(updater.restarts.map(\.eject), viaUpdater ? [true] : [], "the relaunched copy ejects the images")
            XCTAssertEqual(system.jobs.map(\.version), viaUpdater ? [] : [releaseVersion(26)], "one installer: \(ready)")
            XCTAssertEqual(system.terminations, 1)
            try FileManager.default.removeItem(at: root.appendingPathComponent("Volumes"))
        }

        // The updater's installer cannot start: it says why, and the app keeps running.
        updater.readyBuild = 27
        updater.restartSucceeds = false
        system.active = true
        let update = try stagedUpdate()
        update.activated()
        XCTAssertTrue(spin(5) { self.updater.restarts.count == 1 })
        XCTAssertEqual(system.terminations, 0)
        XCTAssertNil(update.pending)
        update.willTerminate()
        XCTAssertEqual(updater.quitInstalls, 1, "its ready update installs on quit as before")
        XCTAssertEqual(system.jobs, [])
    }

    func testAnInstallerThatCannotStartLeavesTheAppRunningWithAToast() throws {
        let update = try stagedUpdate()
        var toasts: [String] = []
        update.toast = { toasts.append($0) }
        system.spawnError = UpdateError.install("cannot start the installer: Resource temporarily unavailable")
        system.active = true
        update.activated()
        XCTAssertTrue(spin(5) { !toasts.isEmpty })
        XCTAssertEqual(toasts, ["Peekaboo 20261126-000026 could not be installed\nCannot start the installer: Resource temporarily unavailable"])
        XCTAssertEqual(system.terminations, 0)
        XCTAssertNil(update.pending)
        XCTAssertTrue(spin(5) { !FileManager.default.fileExists(atPath: self.staged(releaseVersion(26)).path) })

        // One attempt per version and run: the same image opened again is staged again, but neither the next
        // activation nor the quit starts its installer (or says so) a second time.
        system.spawnError = nil
        let image = try XCTUnwrap(system.volumes.first)
        unmount(image)
        try mount("Peekaboo 26", releaseVersion(26))
        XCTAssertTrue(spin(5) { update.pending?.version == releaseVersion(26) && update.looking == 0 }, "staged again")
        update.activated()
        spin(0.1)
        update.willTerminate()
        XCTAssertEqual(system.jobs, [])
        XCTAssertEqual(system.terminations, 0)
        XCTAssertEqual(toasts.count, 1)
        XCTAssertEqual(updater.quitInstalls, 1, "the updater's quit as before")
    }

    func testNoHandOverWhenTheStagedCopyIsGoneOrNoLongerNewer() throws {
        system.active = true
        let gone = try stagedUpdate()
        try FileManager.default.removeItem(at: staged(releaseVersion(26)).deletingLastPathComponent())
        gone.activated()
        XCTAssertTrue(spin(5) { gone.pending == nil })

        // Another installer put a newer Peekaboo in this one's place meanwhile: installing would downgrade it.
        let later = System()
        later.active = true
        let replaced = try stagedUpdate(system: later)
        _ = try fakePeekabooApp(in: running.deletingLastPathComponent(), version: releaseVersion(27))
        replaced.activated()
        XCTAssertTrue(spin(5) { replaced.pending == nil })
        replaced.willTerminate()
        XCTAssertEqual(system.jobs + later.jobs, [])
        XCTAssertEqual(system.terminations + later.terminations, 0)
    }

    // MARK: Quitting

    func testQuittingInstallsTheStagedCopyWithoutARelaunch() throws {
        let update = try stagedUpdate()
        update.willTerminate()
        XCTAssertEqual(system.jobs, [UpdateInstaller.Job(pid: getpid(), staged: staged(releaseVersion(26)), target: running,
                                                         version: releaseVersion(26))], "the version the user opened")
        XCTAssertEqual(updater.quitInstalls, 0)
        system.active = true
        update.activated()
        spin(0.1)
        XCTAssertEqual(system.jobs.count, 1, "the app is quitting: no hand-over")
        XCTAssertEqual(system.terminations, 0)

        // Unless the updater installs a build as new or newer on this quit (or its installer runs already).
        for (ready, installsOnQuit, helper, mine) in [(27, true, false, false), (26, true, false, false), (27, false, false, true),
                                                      (25, true, false, true), (nil, false, true, false)] as [(Int?, Bool, Bool, Bool)] {
            let system = System(), updater = FakeUpdater()
            (updater.readyBuild, updater.installsOnQuit, updater.helperStarted) = (ready, installsOnQuit, helper)
            try stagedUpdate(system: system, updater: updater).willTerminate()
            XCTAssertEqual(system.jobs.count, mine ? 1 : 0, "ready \(String(describing: ready)), installs on quit \(installsOnQuit)")
            XCTAssertEqual(updater.quitInstalls, mine ? 0 : 1)
            XCTAssertTrue(system.jobs.allSatisfy { !$0.relaunch && !$0.ejectDiskImages && $0.reopen == nil })
            try FileManager.default.removeItem(at: root.appendingPathComponent("Volumes"))
        }

        // Nothing staged: the updater's quit as before.
        let none = makeUpdate(updater: updater)
        none.willTerminate()
        XCTAssertEqual(updater.quitInstalls, 1)
    }
}
