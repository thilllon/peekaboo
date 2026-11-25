import AppKit
import PeekabooCore

/// A launch from a disk image or a translocated path (`AppInstall`): instead of a window, Peekaboo installs itself into
/// Applications, opens the launch's files in the installed copy and quits. Created in `applicationWillFinishLaunching`;
/// the install runs once launching has finished, on a background queue.
final class Installation {
    /// Everything that touches the system (tests replace all of it).
    struct Hooks {
        /// Install the app at the target (`AppInstall.install`).
        var install: (_ app: URL, _ version: AppVersion, _ target: URL) throws -> AppInstall.Outcome
        /// Open `urls` (none: just the app) in the app at `target`: in a new instance started with `arguments`, or in
        /// the running one. `done` gets the error, on any thread.
        var open: (_ urls: [URL], _ target: URL, _ newInstance: Bool, _ arguments: [String],
                   _ done: @escaping (Error?) -> Void) -> Void
        var terminate: () -> Void

        static let live = Hooks(install: { app, version, target in
            guard let requirement = CodeSignature.updateRequirementForRunningApp() else {
                throw UpdateError.verification("malformed team identifier")
            }
            return try AppInstall.install(app, version: version, at: target, requirement: requirement,
                                          isRunning: Installation.isRunning)
        }, open: Installation.open, terminate: { NSApp.terminate(nil) })
    }

    /// The running bundle (on the disk image, or translocated).
    let app: URL
    let version: AppVersion
    /// `AppInstall.target()`.
    let target: URL
    private let hooks: Hooks
    /// The launch's files: the paths on the command line, then every open-documents event until the handover.
    private(set) var urls: [URL] = []
    private var collected: Set<String> = []

    init(app: URL, version: AppVersion, target: URL, hooks: Hooks) {
        self.app = app
        self.version = version
        self.target = target
        self.hooks = hooks
    }

    /// The installation this launch performs, or nil: asked only when the executable's path may need it (the app
    /// delegate's `AppInstall.mayNeedInstalling(executable:)`), never headless. The bundle at `path` must need it too;
    /// the self-test, scripted runs (`PEEKABOO_ACTIONS`, even empty), a copy that was just installed (it never installs
    /// again, whatever its path says) and anything but a versioned Peekaboo.app install nothing.
    static func forLaunch(path: String = Bundle.main.bundlePath, arguments: [String],
                          isScripted: () -> Bool = { getenv("PEEKABOO_ACTIONS") != nil },
                          target: () -> URL = { AppInstall.target() }, hooks: Hooks = .live) -> Installation? {
        guard AppInstall.mayNeedInstalling(path) else { return nil }
        let app = URL(fileURLWithPath: path, isDirectory: true)
        guard !arguments.contains("--selftest"), AppInstall.installingProcess(in: arguments) == nil, !isScripted(),
              app.pathExtension == "app", AppInstall.needsInstalling(app), let version = AppInstall.peekabooVersion(app)
        else { return nil }
        let installation = Installation(app: app, version: version, target: target(), hooks: hooks)
        Trace.log("install: \(path) runs from \(path.hasPrefix("/Volumes/") ? "a disk image" : "App Translocation");"
                  + " installing \(version) at \(installation.target.path)")
        return installation
    }

    /// Keep `urls` for the installed copy (once each).
    func collect(_ urls: [URL]) {
        for url in urls where collected.insert(url.standardizedFileURL.path).inserted { self.urls.append(url) }
    }

    /// Install, open the files in the installed copy and quit. `stay` gets the reason (main thread) when Peekaboo stays
    /// here instead: nothing was installed, or the installed copy did not start.
    func run(stay: @escaping (String) -> Void) {
        let started = Trace.now()
        let (app, version, target, install) = (self.app, self.version, self.target, hooks.install)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try install(app, version, target) }
            let ms = Trace.ms(since: started)
            DispatchQueue.main.async { [self] in
                switch result {
                case .failure(let error):
                    Trace.log(String(format: "install: failed after %.1f ms: %@", ms, "\(error)"))
                    stay("Peekaboo could not be installed in Applications: \(AppInstall.failureReason(error))")
                case .success(let outcome):
                    Trace.log(String(format: "install: %@ after %.1f ms", "\(outcome)", ms))
                    handOver(outcome, stay: stay)
                }
            }
        }
    }

    /// A running installed copy gets the files as open-documents events; otherwise a new instance starts with them and
    /// with `--eject-disk-images=<this pid>`, so that it ejects the disk images once this copy has quit.
    private func handOver(_ outcome: AppInstall.Outcome, stay: @escaping (String) -> Void) {
        let running = outcome == .running
        let arguments = running ? [] : ["\(AppInstall.ejectFlag)=\(getpid())"]
        hooks.open(urls, target, !running, arguments) { [self] error in
            DispatchQueue.main.async { [self] in
                guard let error else { return hooks.terminate() }
                Trace.log("install: cannot open \(target.path): \(error)")
                stay("Peekaboo could not start \(target.path): \(error.localizedDescription)")
            }
        }
    }

    /// A Peekaboo process other than this one runs the bundle at `app`.
    static func isRunning(_ app: URL) -> Bool {
        let path = app.resolvingSymlinksInPath().path
        return NSRunningApplication.runningApplications(withBundleIdentifier: CodeSignature.bundleIdentifier).contains {
            $0.processIdentifier != getpid() && $0.bundleURL?.resolvingSymlinksInPath().path == path
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
/// utility queue, it waits for that copy to quit, ejects every Peekaboo disk image (`AppInstall.diskImages`) and says
/// so in one toast, naming the images it could not eject (one still in use).
final class DiskImageEjector {
    /// Everything that touches the system (tests replace all of it).
    struct Hooks {
        /// Wait until the process has quit (false: it still runs).
        var waitForExit: (pid_t) -> Bool
        var diskImages: () -> [URL]
        var eject: (URL) throws -> Void

        static let live = Hooks(waitForExit: { UpdateInstaller.waitForExit($0, timeout: 10) },
                                diskImages: { AppInstall.diskImages(in: AppInstall.mountedVolumes()) },
                                eject: { try NSWorkspace.shared.unmountAndEjectDevice(at: $0) })
    }

    private let hooks: Hooks
    /// An image in use is tried once more after this long (a thumbnail of one of its files may hold it a moment).
    private let retryDelay: TimeInterval
    private let queue = DispatchQueue(label: "peekaboo.eject", qos: .utility)

    init(hooks: Hooks = .live, retryDelay: TimeInterval = 2) {
        self.hooks = hooks
        self.retryDelay = retryDelay
    }

    /// Wait for process `pid` to quit, eject the disk images, then hand the toast to `done` on the main thread
    /// (`failed`: an image is still mounted).
    func run(after pid: pid_t, done: @escaping (_ toast: String, _ failed: Bool) -> Void) {
        let (hooks, queue, retryDelay) = (self.hooks, self.queue, self.retryDelay)
        queue.async {
            let started = Trace.now()
            if !hooks.waitForExit(pid) { Trace.log("eject: process \(pid) still runs") }
            func finish(_ failures: [(image: URL, busy: Bool)]) {
                Trace.log(String(format: "eject: done in %.0f ms", Trace.ms(since: started)))
                let toast = Self.toast(failed: failures.map(\.image.lastPathComponent), busy: failures.allSatisfy(\.busy))
                DispatchQueue.main.async { done(toast, !failures.isEmpty) }
            }
            let failures = Self.eject(hooks.diskImages(), hooks)
            let busy = failures.filter(\.busy).map(\.image)
            guard !busy.isEmpty else { return finish(failures) }
            queue.asyncAfter(deadline: .now() + retryDelay) {
                finish(failures.filter { !$0.busy } + Self.eject(busy, hooks))
            }
        }
    }

    /// Eject each of `images`; the ones that stay, and whether each is in use.
    private static func eject(_ images: [URL], _ hooks: Hooks) -> [(image: URL, busy: Bool)] {
        images.compactMap { image in
            do {
                try hooks.eject(image)
                Trace.log("eject: \(image.path)")
                return nil
            } catch {
                Trace.log("eject: \(image.path) failed: \(error)")
                return (image, isBusy(error))
            }
        }
    }

    /// The image is in use: `unmountAndEjectDevice` fails with `fBsyErr` (an app still has a file of it open).
    static func isBusy(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSOSStatusErrorDomain && error.code == -47) || (error.domain == NSPOSIXErrorDomain && error.code == Int(EBUSY))
    }

    /// "Peekaboo is installed in Applications", and the images that are still mounted (`busy`: all of them in use).
    static func toast(failed: [String], busy: Bool) -> String {
        let installed = "Peekaboo is installed in Applications"
        guard !failed.isEmpty else { return installed }
        let names = failed.map { "“\($0)”" }.joined(separator: ", ")
        let one = failed.count == 1
        guard busy else { return installed + "\nCould not eject \(names): eject \(one ? "it" : "them") in Finder" }
        return installed + "\n" + (one ? "\(names) is in use: eject it in Finder once it is free"
                                       : "\(names) are in use: eject them in Finder once they are free")
    }
}
