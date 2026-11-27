import AppKit
import PeekabooCore

/// A launch from a disk image or a translocated path (`AppInstall`): instead of a window, Peekaboo installs itself into
/// Applications, opens the launch's files in the installed copy and quits. Created in main.swift, before any warm-up
/// (such a launch needs none); the install runs once launching has finished, on a background queue.
final class Installation {
    /// Everything that touches the system (tests replace all of it).
    struct Hooks {
        /// Install the app at the target (`AppInstall.install`, which looks at the other Applications folder too).
        var install: (_ app: URL, _ version: AppVersion, _ target: URL) throws -> AppInstall.Outcome
        /// Quit the Peekaboo that runs at `target`, and wait until no process runs it (its update installer included);
        /// false when one still does.
        var quit: (_ target: URL) -> Bool
        /// Open `urls` (none: just the app) in the app at `target`: in a new instance started with `arguments`, or in
        /// the running one. `done` gets the error, on any thread.
        var open: (_ urls: [URL], _ target: URL, _ newInstance: Bool, _ arguments: [String],
                   _ done: @escaping (Error?) -> Void) -> Void
        var terminate: () -> Void

        static let live = Hooks(install: { app, version, target in
            guard let requirement = CodeSignature.updateRequirementForRunningApp() else {
                throw UpdateError.verification("malformed team identifier")
            }
            return try AppInstall.install(app, version: version, at: target, elsewhere: AppInstall.locations().filter { $0 != target },
                                          requirement: requirement, isRunning: { !AppInstall.processes(runningFrom: $0).isEmpty })
        }, quit: { Installation.quit($0, timeout: 10) }, open: Installation.open, terminate: { NSApp.terminate(nil) })
    }

    /// The running bundle (on the disk image, or translocated).
    let app: URL
    let version: AppVersion
    /// `AppInstall.target()`.
    let target: URL
    private let hooks: Hooks
    /// The launch's files: the paths on the command line, then every open-documents event (once each).
    private(set) var urls: [URL] = []
    private var collected: Set<String> = []
    /// From the hand-over on: the copy that gets the files, how many of `urls` it was given, and whether it runs.
    private var recipient: (app: URL, given: Int, started: Bool)?
    /// Hand-overs of files that arrived later, not finished yet.
    private var forwarding = 0

    init(app: URL, version: AppVersion, target: URL, hooks: Hooks) {
        self.app = app
        self.version = version
        self.target = target
        self.hooks = hooks
    }

    /// The installation this launch performs, or nil: asked only when the executable needs it (main.swift's
    /// `AppInstall.needsInstalling(executable:)`). The bundle at `path` must need it too; the self-test, scripted runs
    /// (`PEEKABOO_ACTIONS`, even empty), a copy that was just installed (it never installs again, whatever its path
    /// says) and anything but a versioned Peekaboo.app install nothing.
    static func forLaunch(path: String = Bundle.main.bundlePath, arguments: [String],
                          isScripted: () -> Bool = { getenv("PEEKABOO_ACTIONS") != nil },
                          target: () -> URL = { AppInstall.target() }, hooks: Hooks = .live) -> Installation? {
        guard AppInstall.needsInstalling(executable: path) else { return nil }
        let app = URL(fileURLWithPath: path, isDirectory: true)
        guard !arguments.contains("--selftest"), AppInstall.installingProcess(in: arguments) == nil, !isScripted(),
              app.pathExtension == "app", let version = AppInstall.peekabooVersion(app)
        else { return nil }
        let installation = Installation(app: app, version: version, target: target(), hooks: hooks)
        Trace.log("install: \(path) runs from \(path.hasPrefix("/Volumes/") ? "a disk image" : "App Translocation");"
                  + " installing \(version) at \(installation.target.path)")
        return installation
    }

    /// Keep `urls` for the installed copy (once each). Once the hand-over has started, they follow the others.
    func collect(_ urls: [URL]) {
        for url in urls where collected.insert(url.standardizedFileURL.path).inserted { self.urls.append(url) }
        forwardLateFiles()
    }

    /// Install, open the files in the installed copy and quit. `stay` gets the reason (main thread) when Peekaboo stays
    /// here instead: nothing was installed, or the installed copy did not start.
    func run(stay: @escaping (String) -> Void) {
        let started = Trace.now()
        let (app, version, target, hooks) = (self.app, self.version, self.target, self.hooks)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Self.install(app, version, at: target, hooks) }
            let ms = Trace.ms(since: started)
            DispatchQueue.main.async { [self] in
                switch result {
                case .failure(let error):
                    Trace.log(String(format: "install: failed after %.1f ms: %@", ms, "\(error)"))
                    stay("Peekaboo could not be installed in \(AppInstall.place(target.deletingLastPathComponent()))\n"
                         + AppInstall.failureReason(error))
                case .success(let outcome):
                    Trace.log(String(format: "install: %@ after %.1f ms", "\(outcome)", ms))
                    handOver(outcome, stay: stay)
                }
            }
        }
    }

    /// `hooks.install`. Peekaboo stays open after its last window closes, so an older copy often runs at the target:
    /// it is quit first (with its update installer, if it starts one), then the install is tried again.
    private static func install(_ app: URL, _ version: AppVersion, at target: URL, _ hooks: Hooks) throws -> AppInstall.Outcome {
        let outcome = try hooks.install(app, version, target)
        guard case .running(target, let build) = outcome, build < version.build else { return outcome }
        Trace.log("install: build \(build) runs at \(target.path); quitting it")
        let stillRunning = UpdateError.install("The Peekaboo there is still running: quit every Peekaboo, then open this one again")
        guard hooks.quit(target) else { throw stillRunning }
        let again = try hooks.install(app, version, target)
        if case .running(target, let build) = again, build < version.build { throw stillRunning }
        return again
    }

    /// Open the files in the installed copy, then quit: a new instance started with `--eject-disk-images=<this pid>`,
    /// so that it ejects the disk images once this copy has quit (`--kept-newer` too when it is newer and nothing was
    /// installed), or the copy that already runs. Files that arrive meanwhile go after them once it runs.
    private func handOver(_ outcome: AppInstall.Outcome, stay: @escaping (String) -> Void) {
        let eject = "\(AppInstall.ejectFlag)=\(getpid())"
        let (destination, newInstance, arguments): (URL, Bool, [String])
        switch outcome {
        case .installed: (destination, newInstance, arguments) = (target, true, [eject])
        case .kept(let url, let build):
            (destination, newInstance, arguments) = (url, true, build > version.build ? [eject, AppInstall.keptNewerFlag] : [eject])
        case .running(let url, _): (destination, newInstance, arguments) = (url, false, [])
        }
        recipient = (destination, urls.count, false)
        hooks.open(urls, destination, newInstance, arguments) { [self] error in
            DispatchQueue.main.async { [self] in
                guard let error else {
                    recipient?.started = true
                    forwardLateFiles()
                    return quitWhenDone()
                }
                Trace.log("install: cannot open \(destination.path): \(error)")
                recipient = nil
                stay("Peekaboo could not start \(AppInstall.describe(destination))\n\(error.localizedDescription)")
            }
        }
    }

    /// Files that arrived after the hand-over started go to the same copy once it runs, as open-documents events to
    /// the instance at its path (one that LaunchServices hands back here again is not sent twice).
    private func forwardLateFiles() {
        guard let recipient, recipient.started, recipient.given < urls.count else { return }
        let late = Array(urls[recipient.given...])
        self.recipient?.given = urls.count
        forwarding += 1
        Trace.log("install: \(late.count) more file(s) for \(recipient.app.path)")
        hooks.open(late, recipient.app, false, []) { [self] error in
            DispatchQueue.main.async { [self] in
                if let error { Trace.log("install: cannot open \(late.count) more file(s) in \(recipient.app.path): \(error)") }
                forwarding -= 1
                quitWhenDone()
            }
        }
    }

    /// Quit once the installed copy runs and has every file.
    private func quitWhenDone() {
        guard recipient?.started == true, forwarding == 0 else { return }
        hooks.terminate()
    }

    /// Quit the copies of Peekaboo that run the bundle at `app` in this session (`quitCopies`), and wait up to `timeout`
    /// until no process runs it any more (`processes`): the update installer a quitting copy may start swaps the bundle
    /// behind it first.
    static func quit(_ app: URL, timeout: TimeInterval, quitCopies: (URL) -> Void = Installation.quitCopies(of:),
                     processes: (URL) -> [pid_t] = { AppInstall.processes(runningFrom: $0) }) -> Bool {
        quitCopies(app)
        let deadline = Date().addingTimeInterval(timeout)
        while !processes(app).isEmpty {
            if Date() >= deadline { return false }
            usleep(50_000)
        }
        return true
    }

    /// Ask the copies of Peekaboo that run the bundle at `app` in this session to quit.
    private static func quitCopies(of app: URL) {
        let path = app.resolvingSymlinksInPath().path
        for copy in NSRunningApplication.runningApplications(withBundleIdentifier: CodeSignature.bundleIdentifier)
        where copy.processIdentifier != getpid() && copy.bundleURL?.resolvingSymlinksInPath().path == path {
            Trace.log("install: quitting process \(copy.processIdentifier)")
            copy.terminate()
        }
    }

    private static func open(_ urls: [URL], in target: URL, newInstance: Bool, arguments: [String],
                             done: @escaping (Error?) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        // A new instance of that bundle, even while this copy (the same bundle identifier) still runs.
        configuration.createsNewApplicationInstance = newInstance
        configuration.arguments = arguments
        let handler: (NSRunningApplication?, Error?) -> Void = { _, error in done(error) }
        if urls.isEmpty {
            NSWorkspace.shared.openApplication(at: target, configuration: configuration, completionHandler: handler)
        } else {
            NSWorkspace.shared.open(urls, withApplicationAt: target, configuration: configuration, completionHandler: handler)
        }
    }
}

/// The installed copy, started by the copy that installed it (`--eject-disk-images=<pid>`): a second after launch, on a
/// utility queue, it waits for that copy to quit, quits the older Peekaboo copies that still run from a Peekaboo disk
/// image, ejects the images this user mounted (`AppInstall.diskImages`: never another user's, nor one that holds a file
/// this copy shows) and says so in one toast, naming the images it could not eject.
final class DiskImageEjector {
    /// Everything that touches the system (tests replace all of it).
    struct Hooks {
        /// Wait until the process has quit (false: it still runs).
        var waitForExit: (pid_t) -> Bool
        /// The Peekaboo disk images this user mounted, but those that hold one of `keeping` (the files this copy shows).
        var diskImages: (_ keeping: [URL]) -> [URL]
        /// Quit the Peekaboo copies of this build or older that run from one of `images` in this session (each keeps its
        /// image in use), and wait a moment for them.
        var quitCopies: (_ images: [URL]) -> Void
        var eject: (URL) throws -> Void

        static let live = Hooks(waitForExit: { UpdateInstaller.waitForExit($0, timeout: 10) },
                                diskImages: { AppInstall.diskImages(in: AppInstall.mountedVolumes(), keeping: $0) },
                                quitCopies: { DiskImageEjector.quitCopies(on: $0, timeout: 3) },
                                eject: { try NSWorkspace.shared.unmountAndEjectDevice(at: $0) })
    }

    /// An image that stays mounted, and whether it is in use.
    struct Failure: Equatable {
        var image: URL
        var busy: Bool
    }

    private let hooks: Hooks
    /// An image in use is tried once more after this long (a thumbnail of one of its files may hold it a moment).
    private let retryDelay: TimeInterval
    private let queue = DispatchQueue(label: "peekaboo.eject", qos: .utility)

    init(hooks: Hooks = .live, retryDelay: TimeInterval = 2) {
        self.hooks = hooks
        self.retryDelay = retryDelay
    }

    /// Wait for process `pid` to quit, then eject the disk images but those holding a file of `keeping` (asked on the
    /// main thread), and hand the images that stay mounted to `done` on the main thread.
    func run(after pid: pid_t, keeping: @escaping () -> [URL], done: @escaping (_ failures: [Failure]) -> Void) {
        let (hooks, queue, retryDelay) = (self.hooks, self.queue, self.retryDelay)
        queue.async {
            let started = Trace.now()
            if !hooks.waitForExit(pid) { Trace.log("eject: process \(pid) still runs") }
            DispatchQueue.main.async {
                let keep = keeping()
                queue.async {
                    func finish(_ failures: [Failure]) {
                        Trace.log(String(format: "eject: done in %.0f ms", Trace.ms(since: started)))
                        DispatchQueue.main.async { done(failures) }
                    }
                    let images = hooks.diskImages(keep)
                    if !images.isEmpty { hooks.quitCopies(images) }
                    let failures = Self.eject(images, hooks)
                    let busy = failures.filter(\.busy).map(\.image)
                    guard !busy.isEmpty else { return finish(failures) }
                    queue.asyncAfter(deadline: .now() + retryDelay) {
                        finish(failures.filter { !$0.busy } + Self.eject(busy, hooks))
                    }
                }
            }
        }
    }

    /// Eject each of `images`; the ones that stay.
    private static func eject(_ images: [URL], _ hooks: Hooks) -> [Failure] {
        images.compactMap { image in
            do {
                try hooks.eject(image)
                Trace.log("eject: \(image.path)")
                return nil
            } catch {
                Trace.log("eject: \(image.path) failed: \(error)")
                return Failure(image: image, busy: isBusy(error))
            }
        }
    }

    /// The image is in use: `unmountAndEjectDevice` fails with `fBsyErr` (an app still has a file of it open).
    static func isBusy(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSOSStatusErrorDomain && error.code == -47) || (error.domain == NSPOSIXErrorDomain && error.code == Int(EBUSY))
    }

    /// Quit the Peekaboo copies other than this one, of this build or older, that run from one of `images`, and wait
    /// up to `timeout` for them to exit. `NSRunningApplication` lists this session's apps only: another account's copy
    /// is never asked to quit.
    static func quitCopies(on images: [URL], timeout: TimeInterval) {
        let roots = images.map { $0.resolvingSymlinksInPath().path + "/" }
        let build = Int(BuildInfo.build ?? "") ?? 0
        let copies = NSRunningApplication.runningApplications(withBundleIdentifier: CodeSignature.bundleIdentifier).filter { copy in
            guard copy.processIdentifier != getpid(), let bundle = copy.bundleURL?.resolvingSymlinksInPath() else { return false }
            return roots.contains { bundle.path.hasPrefix($0) } && (AppInstall.peekabooBuild(bundle) ?? 0) <= build
        }
        for copy in copies {
            Trace.log("eject: quitting \(copy.bundleURL?.path ?? "?") (process \(copy.processIdentifier))")
            copy.terminate()
        }
        let deadline = Date().addingTimeInterval(timeout)
        for copy in copies { _ = UpdateInstaller.waitForExit(copy.processIdentifier, timeout: max(deadline.timeIntervalSinceNow, 0)) }
    }

    /// What the installed copy `app` (`version`) says first: "Peekaboo 20261126-85dff6 is installed in Applications",
    /// or "A newer Peekaboo (…) is already in Applications" when nothing was installed (`keptNewer`).
    static func installedText(version: String?, app: URL, keptNewer: Bool,
                              home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let place = AppInstall.place(app.deletingLastPathComponent(), home: home)
        guard keptNewer else { return "Peekaboo\(version.map { " \($0)" } ?? "") is installed in \(place)" }
        return "A newer Peekaboo\(version.map { " (\($0))" } ?? "") is already in \(place)"
    }

    /// The toast: `installed` (`installedText`), then the images that are still mounted.
    static func toast(_ installed: String, failures: [Failure]) -> String {
        guard !failures.isEmpty else { return installed }
        let names = failures.map { "“\($0.image.lastPathComponent)”" }.joined(separator: ", ")
        let one = failures.count == 1
        guard failures.allSatisfy(\.busy) else {
            return installed + "\nCould not eject \(names): eject \(one ? "it" : "them") in Finder"
        }
        return installed + "\n" + (one ? "\(names) is in use: quit the app that uses it, then eject it in Finder"
                                       : "\(names) are in use: quit the apps that use them, then eject them in Finder")
    }
}
