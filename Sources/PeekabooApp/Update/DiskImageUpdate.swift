import AppKit
import PeekabooCore

/// What a Peekaboo staged from a disk image has to agree on with the in-app updater (`Updater`): never two installers,
/// and the newest build wins. Main thread; tests fake it.
protocol UpdateInstalling: AnyObject {
    /// Build of the downloaded update that is ready to install; nil when none is.
    var readyBuild: Int? { get }
    /// The updater's installer runs: it installs behind the quitting app.
    var helperStarted: Bool { get }
    /// Quitting installs the ready update (auto-install is on, or the user asked for it).
    var installsOnQuit: Bool { get }
    /// "Restart to Update"; false when the installer cannot start (the updater says why).
    func restartToUpdate(reopening file: URL?, ejectingDiskImages: Bool) -> Bool
    /// The app quits: install the ready update behind it, if it is to.
    func installOnQuit()
    /// The copy of `version` (nil: none) in the updater's staging folder is a disk image's: its clean-ups leave it.
    func keepStaged(_ version: AppVersion?)
}

extension Updater: UpdateInstalling {}

/// A newer Peekaboo opened from a disk image while this one runs (issue #86). The downloaded copy is quarantined and was
/// never opened, so Finder hands its launch to Gatekeeper's first-launch path (CoreServicesUIAgent), which brings the
/// running Peekaboo to the front instead of starting the new one (`SETFRONT`): the new copy never runs, so this one acts.
///
/// When the user mounts a disk image under /Volumes with a newer Peekaboo.app at its top (or has it mounted already a few
/// seconds after launch), a utility queue stages that copy like a downloaded update: next to the updater's downloads,
/// without its quarantine flag, verified against the running app's Developer ID requirement (`AppInstall.stage`). The
/// next time the app comes to the front, which is what that double-click does, the update installer replaces this bundle
/// with the staged copy and relaunches it on the photo shown, with `--eject-disk-images=<installer pid>`: the relaunched
/// copy ejects the Peekaboo disk images (`DiskImageEjector`). Quitting first installs the copy without a relaunch.
///
/// Created a second after launch, next to the updater; the workspace observers are registered on the utility queue.
/// With nothing staged an activation costs one check.
final class DiskImageUpdate {
    /// Everything that touches the system (tests replace all of it).
    struct Hooks {
        /// The mounted volumes (`AppInstall.mountedVolumes`); asked on the utility queue.
        var volumes: () -> [AppInstall.Volume]
        /// The volume at the URL is a disk image (`AppInstall.isDiskImage`: DiskArbitration, nothing on it is read);
        /// utility queue.
        var isDiskImage: (URL) -> Bool
        /// Stage the Peekaboo bundle at `app` (`version`) in the staging folder `root`, on the utility queue; the staged
        /// bundle (`AppInstall.stage`).
        var stage: (_ app: URL, _ version: AppVersion, _ root: URL) throws -> URL
        /// Start the update installer (`UpdateInstaller.spawnHelper` with the app's executable).
        var spawn: (UpdateInstaller.Job) throws -> Void
        var terminate: () -> Void
        /// The app is in front (`NSApp.isActive`).
        var isActive: () -> Bool
        /// Where the mount and unmount notifications come from (`NSWorkspace.shared.notificationCenter`), asked on the
        /// utility queue.
        var notifications: () -> NotificationCenter

        static func live(executable: URL) -> Hooks {
            Hooks(volumes: { AppInstall.mountedVolumes() }, isDiskImage: AppInstall.isDiskImage, stage: { app, version, root in
                // Only a Developer ID signed Peekaboo takes a copy from a disk image: the team is what vouches for it. An
                // ad-hoc signature would let in any bundle that names Peekaboo's identifier (the updater has the
                // manifest's SHA-256 for that; a disk image comes with nothing).
                guard let team = CodeSignature.runningTeamIdentifier() else {
                    throw UpdateError.verification("this Peekaboo is not signed with a Developer ID")
                }
                guard let requirement = CodeSignature.updateRequirement(teamIdentifier: team) else {
                    throw UpdateError.verification("malformed team identifier")
                }
                return try AppInstall.stage(app, version: version, in: root, requirement: requirement)
            }, spawn: { try UpdateInstaller.spawnHelper($0, executable: executable) }, terminate: { NSApp.terminate(nil) },
                  isActive: { NSApp.isActive }, notifications: { NSWorkspace.shared.notificationCenter })
        }
    }

    /// A staged copy: `app` is `<staging root>/<version token>/Peekaboo.app`.
    struct Copy: Equatable {
        var version: AppVersion
        var app: URL
    }

    /// The running bundle and its version.
    let app: URL
    let current: AppVersion
    /// `UpdateInstaller.cacheFolder`: the staging root's, and the record of an install that failed.
    private let cache: URL?
    /// Disk images are mounted under it.
    private let volumesRoot: String
    /// Only the disk images this user mounted count (`AppInstall.Volume.owner`): with two accounts logged in at once, a
    /// copy is never staged from an image the other one opened (#90).
    let user: uid_t
    private let hooks: Hooks
    private weak var updates: UpdateInstalling?
    /// The volumes mounted at launch are looked at this long after `start`.
    private let scanDelay: TimeInterval
    /// The hand-over follows an activation this late: a file opened from Finder comes with the activation, in either
    /// order, and the relaunched copy must open that one.
    private let activationDelay: TimeInterval
    /// A hand-over that file operations held back follows this long after they have ended: their result stays readable.
    private let settleDelay: TimeInterval
    private let queue = DispatchQueue(label: "peekaboo.disk-image-update", qos: .utility)

    // What the app shows and does, asked on the main thread (the app delegate sets them).
    /// The file the relaunched copy opens.
    var shownFile: () -> URL? = { nil }
    var isRunningFileOperation: () -> Bool = { false }
    var toast: (String) -> Void = { _ in }

    // Main thread.
    /// The copy that installs the next time the app comes to the front.
    private(set) var pending: Copy? { didSet { arm() } }
    /// Copies being staged: an activation meanwhile waits for them (one may be newer than `pending`).
    private(set) var staging = 0 { didSet { arm() } }
    /// Mounts whose volumes are still being looked at: the double-click on a copy there may bring the app forward
    /// before the copy counts in `staging`, and that activation waits for the look as well.
    private(set) var looking = 0 { didSet { arm() } }
    /// A copy is pending, being staged or maybe on a volume just mounted: all an activation looks at. One stored flag,
    /// because a `Copy?` holds a URL, a type whose size Foundation only knows at run time: testing it for nil goes
    /// through its metadata (42 ns a call in a release build, against 1 ns for the flag).
    private var armed = false
    /// The workspace observers are registered (they are, on the utility queue, shortly after `start`).
    private(set) var isWatching = false
    /// The app came to the front while `armed`: the hand-over follows once nothing holds it back (a volume just
    /// mounted, a copy being staged, a file operation, a menu or a modal panel) and the app is still in front.
    private var handOverWanted = false
    /// Activations less than `activationDelay` old: the hand-over waits for the last of them.
    private var settling = 0
    /// Versions whose install was tried in this run: one attempt each.
    private var attempted: Set<AppVersion> = []
    /// An installer has started (this one's or the updater's) and the app quits.
    private(set) var handedOver = false
    private var terminating = false
    private var suddenTerminationDisabled = false

    // On `queue`.
    private var observers: [NSObjectProtocol] = []
    private var center: NotificationCenter?
    /// nil until the first scan: whether this bundle can be replaced, with the staging root it then has.
    private var prepared: Bool?
    private var root: URL?
    /// Read-only volumes looked at already (their paths), until they are unmounted.
    private var inspected: Set<String> = []
    /// The newest version staged in this run: only a newer one is staged next.
    private var newest: AppVersion?

    init(app: URL, current: AppVersion, cache: URL?, updates: UpdateInstalling?, volumesRoot: String = "/Volumes/",
         user: uid_t = getuid(), scanDelay: TimeInterval = 2, activationDelay: TimeInterval = 0.25,
         settleDelay: TimeInterval = 2.5, hooks: Hooks) {
        self.app = app
        self.current = current
        self.cache = cache
        self.updates = updates
        self.volumesRoot = volumesRoot
        self.user = user
        self.scanDelay = scanDelay
        self.activationDelay = activationDelay
        self.settleDelay = settleDelay
        self.hooks = hooks
    }

    deinit { if let center { observers.forEach(center.removeObserver) } }

    /// The disk-image update of this run, or nil: only Peekaboo.app with a release version, in front of the user. Never
    /// headless (tests), in the self-test, a scripted run (`PEEKABOO_ACTIONS`, even empty) or a copy that installs itself.
    static func forApp(bundle: Bundle = .main, presentation: Presentation, selfTest: Bool, installing: Bool,
                       isScripted: () -> Bool = { getenv("PEEKABOO_ACTIONS") != nil },
                       updates: UpdateInstalling?) -> DiskImageUpdate? {
        guard presentation == .interactive, !selfTest, !installing, !isScripted(),
              bundle.bundleIdentifier == CodeSignature.bundleIdentifier, bundle.bundleURL.pathExtension == "app",
              let executable = bundle.executableURL,
              let current = AppVersion(shortVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString"),
                                       bundleVersion: bundle.object(forInfoDictionaryKey: "CFBundleVersion"))
        else { return nil }
        return DiskImageUpdate(app: bundle.bundleURL, current: current, cache: UpdateInstaller.cacheFolder, updates: updates,
                               hooks: .live(executable: executable))
    }

    /// Watch the mounts, and look at the volumes mounted already in `scanDelay`. The workspace observers are registered
    /// on the utility queue: on the main thread the first two cost ~1 ms (system calls the workspace makes for them),
    /// on the utility queue nothing of it reaches the main thread. A volume mounted before they are is in the first scan.
    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            let started = Trace.now()
            let center = hooks.notifications()
            self.center = center
            observers = [
                center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: nil) { [weak self] _ in
                    // AppKit posts it on the main thread, so the mount counts before any activation that follows it.
                    if Thread.isMainThread { self?.mounted() } else { DispatchQueue.main.async { self?.mounted() } }
                },
                center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: nil) { [weak self] note in
                    guard let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
                    self?.queue.async { [weak self] in self?.inspected.remove(volume.standardizedFileURL.path) }
                },
            ]
            Trace.log(String(format: "disk image: watching the mounts (%.2f ms on a utility queue)", Trace.ms(since: started)))
            DispatchQueue.main.async { [weak self] in self?.isWatching = true }
        }
        queue.asyncAfter(deadline: .now() + scanDelay) { [weak self] in self?.scan() }
    }

    /// A volume was mounted (main thread): look at it on the queue; until that is done, an activation waits for it
    /// (`looking`).
    private func mounted() {
        looking += 1
        queue.async { [weak self] in
            self?.scan()
            DispatchQueue.main.async { [weak self] in self?.looked() }
        }
    }

    // MARK: Staging (on `queue`)

    /// Stage the newest Peekaboo on the disk images not looked at yet, if it is newer than this build and than what is
    /// staged already. A copy that fails anything is traced and left; the next newest is tried then.
    private func scan() {
        guard prepare(), let root else { return }
        let candidates = newerCopies()
        guard !candidates.isEmpty else { return }
        let failed = failedInstall()
        for (copy, version) in candidates {
            if let failed, failed.version == version.token {
                Trace.log("disk image: \(version) failed to install before (\(failed.reason)): \(copy.path) is left")
                continue
            }
            DispatchQueue.main.async { [weak self] in self?.staging += 1 }
            let started = Trace.now()
            let result = Result { try hooks.stage(copy, version, root) }
            let ms = Trace.ms(since: started)
            switch result {
            case .success(let staged):
                Trace.log(String(format: "disk image: staged %@ (build %d) from %@ in %.0f ms at %@", version.description,
                                 version.build, copy.path, ms, staged.path))
                newest = version
            case .failure(let error):
                Trace.log(String(format: "disk image: cannot stage %@ (%.0f ms): %@", copy.path, ms, "\(error)"))
            }
            DispatchQueue.main.async { [weak self] in
                self?.staged(try? result.map { Copy(version: version, app: $0) }.get())
            }
            if case .success = result { return }
        }
    }

    /// The first scan: whether this bundle can replace itself at all (not from a disk image, App Translocation or a
    /// folder it may not write), its staging root, and the copies earlier runs staged there that are stale now.
    private func prepare() -> Bool {
        if let prepared { return prepared }
        prepared = false
        if let reason = UpdateInstaller.cannotReplaceReason(app) {
            Trace.log("disk image: no update from a disk image: \(reason)")
            return false
        }
        guard let cache else { return false }
        do {
            let root = try UpdateInstaller.stagingRoot(for: app, cache: cache)
            UpdateInstaller.removeStaged(in: root, notNewerThan: current.build)
            self.root = root
            prepared = true
        } catch {
            Trace.log("disk image: no staging folder: \(error)")
        }
        return prepared == true
    }

    /// The Peekaboo.app at the top of each disk image this user mounted (a read-only local volume under `volumesRoot`)
    /// not looked at yet, if it is newer than this build and than the one staged, and runs on this macOS: newest first.
    /// Only a disk image is read (one `Info.plist`): never a locked card, a read-only drive or a network share, whose
    /// first read may have macOS ask the user for the Removable or Network Volumes permission. A volume another user
    /// mounted is neither asked about nor read, nor counted as looked at (that user's unmount may never be posted here,
    /// and an image of this user's mounted at its place later must count). A Peekaboo.app that is a symbolic link is
    /// left: it could point anywhere, a folder of the user's or a copy someone else may change later.
    private func newerCopies() -> [(app: URL, version: AppVersion)] {
        hooks.volumes().compactMap { volume -> (app: URL, version: AppVersion)? in
            let path = volume.url.standardizedFileURL.path
            guard volume.isReadOnly, volume.isLocal, path.hasPrefix(volumesRoot) else { return nil }
            guard volume.owner == user else {
                Trace.log("disk image: \(path) was mounted by another user (uid \(volume.owner)): left")
                return nil
            }
            guard inspected.insert(path).inserted, hooks.isDiskImage(volume.url) else { return nil }
            let copy = volume.url.appendingPathComponent("Peekaboo.app", isDirectory: true)
            guard !AppInstall.isSymbolicLink(copy) else {
                Trace.log("disk image: \(copy.path) is a symbolic link: left")
                return nil
            }
            guard let (version, minimum) = AppInstall.peekabooRelease(copy) else { return nil }
            guard version.build > max(current.build, newest?.build ?? 0) else {
                Trace.log("disk image: \(copy.path) is \(version) (build \(version.build)): not newer")
                return nil
            }
            // Installed, it would not start, and the copy it replaced would be gone.
            if let minimum, !UpdateManifest.runs(minimum, on: ProcessInfo.processInfo.operatingSystemVersion) {
                Trace.log("disk image: \(copy.path) is \(version), which needs macOS \(minimum): left")
                return nil
            }
            return (copy, version)
        }.sorted { $0.version > $1.version }
    }

    /// The install the update installer could not finish here (`UpdateInstaller.Failure`): never tried again from a disk
    /// image, so that a failing install cannot relaunch the app over and over.
    private func failedInstall() -> UpdateInstaller.Failure? {
        guard let cache, let failure = UpdateInstaller.Failure.read(in: cache),
              URL(fileURLWithPath: failure.target).resolvingSymlinksInPath().path == app.resolvingSymlinksInPath().path
        else { return nil }
        return failure
    }

    // MARK: Main thread

    private func arm() { armed = pending != nil || staging > 0 || looking > 0 }

    /// The volumes of a mount have been looked at (and a copy found there staged): a hand-over that waited for them
    /// follows.
    private func looked() {
        looking -= 1
        resume()
    }

    /// A copy was staged (nil: it failed): it is the pending one now, and the copy it supersedes goes.
    private func staged(_ copy: Copy?) {
        staging -= 1
        if let copy {
            if handedOver || terminating {
                Trace.log("disk image: \(copy.version) was staged as the app quits; it goes")
                remove(copy)
            } else {
                let previous = pending
                pending = copy
                updates?.keepStaged(copy.version)
                if !suddenTerminationDisabled {
                    // Logging out must quit the app properly, so that the copy installs.
                    ProcessInfo.processInfo.disableSuddenTermination()
                    suddenTerminationDisabled = true
                }
                if let previous, previous.version != copy.version { remove(previous) }
            }
        }
        resume()
    }

    /// The app came to the front (`applicationDidBecomeActive`, `applicationShouldHandleReopen`): hand over to the staged
    /// copy in `activationDelay`, if the app is still in front then. True once an installer has started and the app quits
    /// (no window to bring back).
    @discardableResult
    func activated() -> Bool {
        guard armed else { return false }
        return activatedWithACopy()
    }

    /// Out of line: `asyncAfter` takes Dispatch types whose size is only known at run time, and the stack space they need
    /// would be set up before the check above (7 ns instead of 1).
    @inline(never)
    private func activatedWithACopy() -> Bool {
        if handedOver { return true }
        handOverWanted = true
        settling += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + activationDelay) { [weak self] in
            guard let self else { return }
            settling -= 1
            resume()
        }
        return false
    }

    /// The file operations that ran in the background have ended (`FileActions`): a hand-over they held back follows in
    /// `settleDelay`.
    func fileOperationsEnded() {
        guard handOverWanted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) { [weak self] in self?.resume() }
    }

    /// The app quits (`applicationWillTerminate`). After a hand-over its installer is on its way. Otherwise the staged
    /// copy installs behind the quitting app, without a relaunch (it is the version the user opened), unless the updater
    /// installs a build as new or newer now; with none staged, the updater installs its ready update as before.
    func willTerminate() {
        guard !terminating else { return }
        terminating = true
        guard !handedOver else { return }
        if let copy = pending, !attempted.contains(copy.version), !updaterInstallsOnQuit(copy), isStillNewer(copy) {
            attempted.insert(copy.version)
            do {
                try hooks.spawn(UpdateInstaller.Job(pid: getpid(), staged: copy.app, target: app, version: copy.version))
                Trace.log("disk image: \(copy.version) installs behind the quitting app")
                return
            } catch {
                Trace.log("disk image: cannot install \(copy.version) on quit: \(error)")
            }
        }
        updates?.installOnQuit()
    }

    /// The updater's installer runs already, or the updater installs a build as new as `copy`'s or newer on this quit.
    private func updaterInstallsOnQuit(_ copy: Copy) -> Bool {
        guard let updates else { return false }
        return updates.helperStarted || (updates.installsOnQuit && (updates.readyBuild ?? 0) >= copy.version.build)
    }

    /// Hand over now if one is wanted, nothing holds it back any more and the app is still in front. Never before the
    /// last activation is `activationDelay` old, even when a copy is staged sooner: the file opened with it may follow.
    private func resume() {
        guard handOverWanted, settling == 0, staging == 0, looking == 0, hooks.isActive() else { return }
        handOver()
    }

    /// Hand over to the pending copy unless something holds it back.
    private func handOver() {
        guard !handedOver, !terminating else { return }
        // A menu or a modal panel (an alert, a folder picker) runs an event loop of its own: once it has ended.
        if let mode = RunLoop.current.currentMode, mode != .default {
            RunLoop.main.perform(inModes: [.default]) { [weak self] in self?.resume() }
            return
        }
        // A copy on its way, or on a volume just mounted, may be newer; a file operation would be cut short: once they
        // are done.
        if staging > 0 || looking > 0 || isRunningFileOperation() {
            let cause = staging > 0 ? "the copy being staged"
                : looking > 0 ? "the volume just mounted" : "the file operation"
            Trace.log("disk image: the update waits for \(cause)")
            return
        }
        handOverWanted = false
        guard let copy = pending, !attempted.contains(copy.version), updates?.helperStarted != true else { return }
        guard isStillNewer(copy) else {
            Trace.log("disk image: \(copy.app.path) is gone or no longer newer than \(app.path)")
            return drop()
        }
        attempted.insert(copy.version)
        let file = shownFile()
        if let updates, let ready = updates.readyBuild, ready >= copy.version.build {
            // The updater's download is as new or newer: it installs that one, with the same installer.
            Trace.log("disk image: the updater's build \(ready) installs instead of \(copy.version)")
            guard updates.restartToUpdate(reopening: file, ejectingDiskImages: true) else { return drop() }
        } else {
            let job = UpdateInstaller.Job(pid: getpid(), staged: copy.app, target: app, version: copy.version, relaunch: true,
                                          reopen: file, ejectDiskImages: true)
            do {
                try hooks.spawn(job)
            } catch {
                Trace.log("disk image: cannot start the installer: \(error)")
                toast("Peekaboo \(copy.version) could not be installed\n\(AppInstall.failureReason(error))")
                return drop()
            }
            Trace.log("disk image: installing \(copy.version) over \(app.path), then relaunching")
        }
        handedOver = true
        hooks.terminate()
    }

    /// The staged copy is still there as it was staged, newer than this build and than the bundle in its place now
    /// (another installer may have put a newer one there): two `Info.plist` reads, at a hand-over only.
    private func isStillNewer(_ copy: Copy) -> Bool {
        AppInstall.peekabooVersion(copy.app) == copy.version && copy.version.build > current.build
            && (AppInstall.peekabooBuild(app) ?? 0) < copy.version.build
    }

    /// Forget the pending copy and delete it.
    private func drop() {
        guard let copy = pending else { return }
        pending = nil
        updates?.keepStaged(nil)
        remove(copy)
        queue.async { [weak self] in
            if self?.newest == copy.version { self?.newest = nil }
        }
    }

    /// Delete a staged copy, unless the updater has made it its ready update (it found the same release staged).
    private func remove(_ copy: Copy) {
        let folder = copy.app.deletingLastPathComponent()
        guard updates?.readyBuild != copy.version.build, AppVersion(folder.lastPathComponent) == copy.version else { return }
        queue.async { try? FileManager.default.removeItem(at: folder) }
    }
}
