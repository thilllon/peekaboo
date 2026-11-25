import AppKit
import Network
import PeekabooCore

/// In-app updates (no Sparkle): reads `latest.json` of the latest GitHub release and installs a newer release
/// through `UpdateInstaller`.
///
/// Nothing of it runs on the launch path: the first check waits `UpdatePolicy.firstCheckDelay` after launch, then
/// it re-checks every 6 h and when the network comes back (at most hourly). Network, disk and code-signature work
/// run on a utility queue (E-cores); the main thread only receives each new `Phase`.
final class Updater {
    /// Posted by the Settings window's "Check Now" button: checks at once (the outcome is in the status).
    static let checkNowNotification = Notification.Name("PeekabooCheckForUpdatesNow")
    /// Posted on the main thread whenever `status` changes, with `userInfo["status"]` (a `String`).
    static let statusNotification = Notification.Name("PeekabooUpdateStatusChanged")
    static let releaseManifest = URL(string: "https://github.com/thilllon/peekaboo/releases/latest/download/latest.json")!

    enum Phase: Equatable {
        /// No check finished yet.
        case idle
        case checking
        case upToDate
        /// A newer release that is not downloaded: it waits for the user (`auto_install = false`), or cannot be
        /// installed in place (`blocked` says why; the release page is offered instead).
        case available(UpdateManifest, blocked: String?)
        case downloading(UpdateManifest)
        /// Downloaded, verified and staged: installs when the app quits, or now with "Restart to Update".
        case ready(UpdateManifest, app: URL)
        case failed(String)
    }

    /// Main thread.
    private(set) var phase = Phase.idle
    /// The verified update waiting to be installed (main thread). Unlike `phase` it survives a re-check that is in
    /// flight or fails, so quitting at that moment still installs it.
    private(set) var ready: (manifest: UpdateManifest, app: URL)?
    /// One line for the Settings window and the toasts, e.g. `Up to date (20261125)`.
    private(set) var status = ""
    /// Main thread, after every phase change; `show` is true when the user asked for this outcome.
    var onChange: ((Phase, _ show: Bool) -> Void)?

    let current: AppVersion
    private let app: URL
    private let executable: URL
    private let manifestURL: URL
    /// `PEEKABOO_UPDATE_URL` (a test server or file): http and file URLs are accepted, nothing is remembered.
    private let isTestManifest: Bool
    private let policy = UpdatePolicy()
    private static let lastCheckKey = "PeekabooUpdateLastCheck"

    // Main thread.
    private var settings: AppConfig.Updates
    /// The user asked for the available update ("Update to …"), so it installs on quit even without auto-install.
    private var requested = false
    private var helperStarted = false
    private var suddenTerminationDisabled = false

    // On `queue`.
    private let queue = DispatchQueue(label: "peekaboo.update", qos: .utility)
    private var queueSettings: AppConfig.Updates
    private var requestedOnQueue = false
    private var started = false
    private var busy = false
    /// The outcome of the check in flight goes to a toast (a manual check asked for it).
    private var showOutcome = false
    private var lastCheck: Date?
    private var timer: DispatchSourceTimer?
    private var monitor: NWPathMonitor?
    private var connectivity = ConnectivityEdge()
    private var stagingRoot: URL?
    private var staged: (manifest: UpdateManifest, app: URL)?

    /// nil unless this is Peekaboo running from its app bundle with a version (not `swift run`, not tests).
    init?(settings: AppConfig.Updates, bundle: Bundle = .main) {
        guard bundle.bundleIdentifier == CodeSignature.bundleIdentifier, bundle.bundleURL.pathExtension == "app",
              let executable = bundle.executableURL,
              let current = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
        else { return nil }
        self.current = current
        app = bundle.bundleURL
        self.executable = executable
        let override = ProcessInfo.processInfo.environment["PEEKABOO_UPDATE_URL"].flatMap { $0.isEmpty ? nil : URL(string: $0) }
        manifestURL = override ?? Self.releaseManifest
        isTestManifest = override != nil
        self.settings = settings
        queueSettings = settings
        status = Self.statusText(.idle, current: current, settings: settings, installsOnQuit: settings.autoInstall)
    }

    // MARK: Main-thread API

    /// Begin automatic checks (call after launch: the first check waits `firstCheckDelay`).
    func start() {
        queue.asyncAfter(deadline: .now() + policy.firstCheckDelay) { [weak self] in
            guard let self else { return }
            self.started = true
            self.lastCheck = self.isTestManifest ? nil : UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
            self.updateMonitoring()
            self.check(.launch)
        }
    }

    /// `[updates]` changed (config reload, Settings window).
    func apply(_ settings: AppConfig.Updates) {
        guard settings != self.settings else { return }
        var waiting = false
        if case .available(_, nil) = phase { waiting = true }
        // Auto-install turned on with an update waiting: fetch it now.
        let fetch = waiting && settings.autoInstall && !self.settings.autoInstall
        self.settings = settings
        publish(phase)
        queue.async { [weak self] in
            guard let self else { return }
            self.queueSettings = settings
            self.updateMonitoring()
            if fetch {
                self.check(.manual)
            } else if self.started {
                self.check(.connectivity)  // checks turned on: look now (throttled)
            }
        }
    }

    /// "Check for Updates…" (`show`: report the outcome in a toast) or the Settings window's "Check Now".
    func checkNow(show: Bool) {
        queue.async { [weak self] in self?.check(.manual, show: show) }
    }

    /// "Update to …": download the available update now (it then installs on quit, or on restart).
    func downloadNow() {
        requested = true
        queue.async { [weak self] in
            guard let self else { return }
            self.requestedOnQueue = true
            self.check(.manual, show: true)
        }
    }

    /// "Restart to Update": start the installer, which relaunches the app (reopening `file`) once it has quit.
    /// False when the installer cannot start (the phase then says why): the app keeps running.
    func restartToUpdate(reopening file: URL?) -> Bool {
        guard let ready else { return false }
        return startInstaller(ready.manifest, staged: ready.app, relaunch: true, reopen: file)
    }

    /// The app is quitting: install a ready update behind it (auto-install on, or asked for).
    func installOnQuit() {
        guard let ready, settings.autoInstall || requested else { return }
        _ = startInstaller(ready.manifest, staged: ready.app, relaunch: false, reopen: nil)
    }

    private func startInstaller(_ manifest: UpdateManifest, staged: URL, relaunch: Bool, reopen: URL?) -> Bool {
        guard !helperStarted else { return true }
        let job = UpdateInstaller.Job(pid: getpid(), staged: staged, target: app, version: manifest.version,
                                      relaunch: relaunch, reopen: reopen)
        do {
            try UpdateInstaller.spawnHelper(job, executable: executable)
            helperStarted = true
            return true
        } catch {
            publish(.failed("Update failed: \(error)"), show: true)
            return false
        }
    }

    // MARK: Checking (on `queue`)

    private func updateMonitoring() {
        guard started, queueSettings.check else {
            timer?.cancel()
            timer = nil
            monitor?.cancel()
            monitor = nil
            return
        }
        if timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            // Wall clock: an interval that passes during sleep fires on wake.
            timer.schedule(wallDeadline: .now() + policy.interval, repeating: policy.interval, leeway: .seconds(600))
            timer.setEventHandler { [weak self] in self?.check(.timer) }
            timer.resume()
            self.timer = timer
        }
        if monitor == nil {
            let monitor = NWPathMonitor()
            connectivity = ConnectivityEdge()
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self, self.connectivity.update(online: path.status == .satisfied) else { return }
                Trace.log("update: network is back")
                self.check(.connectivity)
            }
            monitor.start(queue: queue)
            self.monitor = monitor
        }
    }

    private func check(_ trigger: UpdateTrigger, show: Bool = false) {
        guard !busy else {
            // A manual check while another is in flight gets that one's outcome.
            if show { showOutcome = true }
            return
        }
        guard policy.shouldCheck(trigger, automatic: queueSettings.check, lastCheck: lastCheck, now: Date()) else { return }
        busy = true
        showOutcome = show
        Trace.log("update: \(trigger.rawValue) check of \(manifestURL.absoluteString)")
        // A background re-check leaves a ready update on show until it has an outcome.
        if staged == nil || trigger == .manual { publish(.checking) }
        var request = URLRequest(url: manifestURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // Automatic checks wait for a connection; a manual one reports at once that there is none.
        let session = makeSession(waitsForConnectivity: trigger != .manual, resourceTimeout: trigger == .manual ? 30 : 600)
        session.dataTask(with: request) { [weak self] data, response, error in
            self?.queue.async { self?.received(data, response, error) }
        }.resume()
        session.finishTasksAndInvalidate()
    }

    private func received(_ data: Data?, _ response: URLResponse?, _ error: Error?) {
        do {
            if let error { throw UpdateError.download(error.localizedDescription) }
            // The server answered: that counts as a check, even if the latest release has no manifest (yet).
            lastCheck = Date()
            if !isTestManifest { UserDefaults.standard.set(lastCheck, forKey: Self.lastCheckKey) }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw UpdateError.download("the release server answered HTTP \(http.statusCode)")
            }
            let manifest = try UpdateManifest(data: data ?? Data(), allowInsecureURLs: isTestManifest)
            Trace.log("update: latest is \(manifest.version), running \(current)")
            evaluate(manifest)
        } catch {
            finish(.failed("Could not check for updates: \(error)"))
        }
    }

    private func evaluate(_ manifest: UpdateManifest) {
        guard manifest.version > current else {
            // An update staged but installed another way (the DMG), or a withdrawn release, is stale now.
            staged = nil
            if let cached = UpdateInstaller.cachedUpdates { UpdateInstaller.removeStaged(in: cached) }
            return finish(.upToDate)
        }
        guard manifest.runs(on: ProcessInfo.processInfo.operatingSystemVersion) else {
            return finish(.available(manifest, blocked: "it needs macOS \(manifest.minimumSystemVersion)"))
        }
        if let reason = UpdateInstaller.cannotReplaceReason(app) { return finish(.available(manifest, blocked: reason)) }
        if let staged, staged.manifest.version == manifest.version, FileManager.default.fileExists(atPath: staged.app.path) {
            return finish(.ready(manifest, app: staged.app))
        }
        // Without auto-install nothing touches the disk until the user asks for the update.
        guard queueSettings.autoInstall || requestedOnQueue else { return finish(.available(manifest, blocked: nil)) }
        if stagingRoot == nil { stagingRoot = try? UpdateInstaller.stagingRoot(for: app) }
        guard let root = stagingRoot, let requirement = CodeSignature.updateRequirementForRunningApp() else {
            return finish(.available(manifest, blocked: "it cannot be staged"))
        }
        // Downloaded by an earlier run that quit before installing it: check it again (the cache is the user's).
        let folder = root.appendingPathComponent(manifest.version.description, isDirectory: true)
        let previous = folder.appendingPathComponent("Peekaboo.app", isDirectory: true)
        if (try? UpdateInstaller.verify(previous, version: manifest.version, requirement: requirement)) != nil {
            staged = (manifest, previous)
            return finish(.ready(manifest, app: previous))
        }
        download(manifest, into: folder, root: root, requirement: requirement)
    }

    private func download(_ manifest: UpdateManifest, into folder: URL, root: URL, requirement: String) {
        let fm = FileManager.default
        // A newer release replaces whatever was staged before.
        staged = nil
        UpdateInstaller.removeStaged(in: root)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return finish(.failed("Update failed: \(error.localizedDescription)"))
        }
        publish(.downloading(manifest), show: showOutcome)
        Trace.log("update: downloading \(manifest.url.absoluteString)")
        let started = Trace.now()
        let zip = folder.appendingPathComponent("Peekaboo-\(manifest.version).zip")
        let session = makeSession(waitsForConnectivity: true, resourceTimeout: 30 * 60)
        session.downloadTask(with: manifest.url) { [weak self] location, response, error in
            // The temporary file is deleted when this handler returns: move it first.
            var failure = error.map { UpdateError.download($0.localizedDescription) }
            if failure == nil, let http = response as? HTTPURLResponse, http.statusCode != 200 {
                failure = .download("the release server answered HTTP \(http.statusCode)")
            }
            if failure == nil {
                do {
                    guard let location else { throw UpdateError.download("no file") }
                    try fm.moveItem(at: location, to: zip)
                } catch {
                    failure = .download("cannot save the download: \(error.localizedDescription)")
                }
            }
            let ms = Trace.ms(since: started)
            self?.queue.async { self?.downloaded(zip, manifest, folder: folder, requirement: requirement, failure: failure, ms: ms) }
        }.resume()
        session.finishTasksAndInvalidate()
    }

    private func downloaded(_ zip: URL, _ manifest: UpdateManifest, folder: URL, requirement: String,
                            failure: UpdateError?, ms: Double) {
        do {
            if let failure { throw failure }
            let size = (try? zip.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            guard size == manifest.size else { throw UpdateError.verification("\(size) bytes, expected \(manifest.size)") }
            guard try UpdateInstaller.sha256(of: zip) == manifest.sha256 else { throw UpdateError.verification("SHA-256 mismatch") }
            let app = try UpdateInstaller.unpack(zip, into: folder)
            try? FileManager.default.removeItem(at: zip)
            try UpdateInstaller.verify(app, version: manifest.version, requirement: requirement)
            Trace.log(String(format: "update: %@ downloaded in %.0f ms and verified", manifest.version.description, ms))
            staged = (manifest, app)
            finish(.ready(manifest, app: app))
        } catch {
            try? FileManager.default.removeItem(at: folder)
            finish(.failed("Update failed: \(error)"))
        }
    }

    /// The check (and download) in flight is over.
    private func finish(_ phase: Phase) {
        busy = false
        var phase = phase
        // A background re-check that failed (offline) changes nothing about the update that is ready.
        if case .failed(let message) = phase, let staged, !showOutcome {
            Trace.log("update: \(message)")
            phase = .ready(staged.manifest, app: staged.app)
        }
        publish(phase, show: showOutcome)
        showOutcome = false
    }

    private func makeSession(waitsForConnectivity: Bool, resourceTimeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = waitsForConnectivity
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = ["User-Agent": "Peekaboo/\(current)"]
        return URLSession(configuration: configuration)
    }

    // MARK: Publishing

    /// Hand `phase` to the main thread (from any thread).
    private func publish(_ phase: Phase, show: Bool = false) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.publish(phase, show: show) }
            return
        }
        if case .failed(let message) = phase { Trace.log("update: \(message)") }
        self.phase = phase
        switch phase {
        case .ready(let manifest, let app):
            ready = (manifest, app)
            if !suddenTerminationDisabled {
                // Logging out must quit the app properly, so that the ready update installs.
                ProcessInfo.processInfo.disableSuddenTermination()
                suddenTerminationDisabled = true
            }
        case .upToDate, .available, .downloading: ready = nil
        case .idle, .checking, .failed: break
        }
        let text = Self.statusText(phase, current: current, settings: settings, installsOnQuit: settings.autoInstall || requested)
        if text != status {
            status = text
            NotificationCenter.default.post(name: Self.statusNotification, object: self, userInfo: ["status": text])
        }
        onChange?(phase, show)
    }

    static func statusText(_ phase: Phase, current: AppVersion, settings: AppConfig.Updates, installsOnQuit: Bool) -> String {
        switch phase {
        case .idle:
            return "Peekaboo \(current) · " + (settings.check ? "checks for updates automatically" : "automatic update checks are off")
        case .checking: return "Checking for updates…"
        case .upToDate: return "Up to date (\(current))"
        case .available(let manifest, nil): return "Peekaboo \(manifest.version) is available"
        case .available(let manifest, let reason?): return "Peekaboo \(manifest.version) is available, but \(reason)"
        case .downloading(let manifest): return "Downloading \(manifest.version)…"
        case .ready(let manifest, _):
            return "Peekaboo \(manifest.version) is ready: restart to update" + (installsOnQuit ? ", or it installs when Peekaboo quits" : "")
        case .failed(let message): return message
        }
    }
}
