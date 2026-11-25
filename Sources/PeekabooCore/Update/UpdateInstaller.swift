import CryptoKit
import Darwin
import Foundation

/// Verifies, stages and installs a downloaded release.
///
/// An update is unzipped next to the app (same volume), checked (SHA-256 of the zip, code signature, identifier,
/// version) and installed by a helper — the app's own executable started with `--install-update` — that waits
/// for the app to quit, swaps the two bundles in one atomic `rename` (`RENAME_SWAP`), checks the result and only
/// then deletes the old bundle; on request it relaunches the app.
public enum UpdateInstaller {
    /// First argument of the helper process.
    public static let helperFlag = "--install-update"

    // MARK: Where

    /// Why the app at `app` cannot replace itself (nil when it can): App Translocation runs a quarantined app from
    /// a random read-only path, and a folder the user cannot write to (a disk image, an admin-owned folder) keeps
    /// the bundle in place. The update is then offered as a download instead.
    public static func cannotReplaceReason(_ app: URL) -> String? {
        if app.path.contains("/AppTranslocation/") {
            return "Peekaboo runs from a quarantined copy: move it to the Applications folder first"
        }
        if (try? app.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true {
            return "Peekaboo runs from the disk image: drag it to the Applications folder first"
        }
        let folder = app.deletingLastPathComponent()
        if access(folder.path, W_OK) != 0 || access(app.path, W_OK) != 0 {
            return "“\(folder.lastPathComponent)” is not writable"
        }
        return nil
    }

    /// `~/Library/Caches/com.thilllon.Peekaboo`, the updater's folder (not created here): `Updates/` holds the
    /// downloads staged on the home folder's volume, `InstallFailure.plist` the last install that failed.
    public static var cacheFolder: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(CodeSignature.bundleIdentifier, isDirectory: true)
    }

    /// `Updates/` of `cache`: the staging root for apps on the home folder's volume.
    public static func updatesFolder(in cache: URL) -> URL { cache.appendingPathComponent("Updates", isDirectory: true) }

    /// Folder for downloaded updates, on the volume of `app` so that the install is a rename: `Updates/` of
    /// `cache`, or, for an app on another volume, Peekaboo's folder among the system's temporary items on that
    /// volume. That one is the same in every run, so a download an earlier run left there is deleted with the next
    /// (`removeStaged`) instead of piling up in a new temporary folder per run.
    public static func stagingRoot(for app: URL, cache: URL) throws -> URL {
        let fm = FileManager.default
        let folder = app.deletingLastPathComponent()
        let updates = updatesFolder(in: cache)
        try fm.createDirectory(at: updates, withIntermediateDirectories: true)
        if device(updates) == device(folder) { return updates }
        // `<volume>/.TemporaryItems/folders.<uid>/TemporaryItems/NSIRD_…`: a new folder per call; keep its parent.
        let scratch = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
        try? fm.removeItem(at: scratch)
        let root = scratch.deletingLastPathComponent()
            .appendingPathComponent("\(CodeSignature.bundleIdentifier).Updates", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        guard device(root) == device(folder) else {
            throw UpdateError.install("no folder for the download on the volume of \(folder.path)")
        }
        return root
    }

    private static func device(_ url: URL) -> dev_t? {
        var info = stat()
        return stat(url.path, &info) == 0 ? info.st_dev : nil
    }

    /// Delete every staged version under `root` except `keeping`.
    public static func removeStaged(in root: URL, keeping: AppVersion? = nil) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for entry in entries where keeping == nil || AppVersion(entry.lastPathComponent) != keeping {
            try? fm.removeItem(at: entry)
        }
    }

    // MARK: Verify

    /// SHA-256 of a file, lowercase hex (read in 1 MB chunks).
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Unzip `zip` into the empty folder `directory` (`ditto`, as the release task zips it) and return the one
    /// app inside.
    public static func unpack(_ zip: URL, into directory: URL) throws -> URL {
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, directory.path]
        // Background work like the rest of the updater (a child process otherwise runs at the default QoS).
        ditto.qualityOfService = .utility
        ditto.standardOutput = FileHandle.nullDevice
        ditto.standardError = FileHandle.nullDevice
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw UpdateError.download("cannot unpack the update (ditto \(ditto.terminationStatus))") }
        let apps = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "app" } ?? []
        guard apps.count == 1 else { throw UpdateError.verification("expected one app in the zip, found \(apps.count)") }
        return apps[0]
    }

    /// The bundle at `app` is Peekaboo `version`, signed so that it meets `requirement`.
    public static func verify(_ app: URL, version: AppVersion, requirement: String) throws {
        let info = try bundleInfo(app)
        guard info.identifier == CodeSignature.bundleIdentifier else {
            throw UpdateError.verification("unexpected bundle identifier \(info.identifier ?? "none")")
        }
        guard info.version == version else {
            throw UpdateError.verification("it is version \(info.version?.description ?? "?"), not \(version)")
        }
        try CodeSignature.check(app, requirement: requirement)
    }

    /// Identifier and version of a bundle, read from its `Info.plist` (not through `Bundle`, which caches by path).
    static func bundleInfo(_ app: URL) throws -> (identifier: String?, version: AppVersion?) {
        let data: Data
        do {
            data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        } catch {
            throw UpdateError.verification("no Info.plist in \(app.lastPathComponent)")
        }
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return (plist?["CFBundleIdentifier"] as? String,
                (plist?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init))
    }

    // MARK: Install

    /// Put the verified bundle `staged` in place of `target` with one atomic swap. The old bundle lands at `staged`
    /// and is deleted once `target` reads as `version`; otherwise the swap is undone. A missing `target` (deleted
    /// meanwhile) is simply replaced.
    public static func install(_ staged: URL, over target: URL, version: AppVersion, requirement: String) throws {
        try verify(staged, version: version, requirement: requirement)
        let fm = FileManager.default
        guard fm.fileExists(atPath: target.path) else {
            do {
                try fm.moveItem(at: staged, to: target)
            } catch {
                throw UpdateError.install(error.localizedDescription)
            }
            return
        }
        guard renamex_np(staged.path, target.path, UInt32(RENAME_SWAP)) == 0 else {
            throw UpdateError.install(String(cString: strerror(errno)))
        }
        guard (try? bundleInfo(target))?.version == version else {
            _ = renamex_np(staged.path, target.path, UInt32(RENAME_SWAP))
            throw UpdateError.install("the new bundle did not read back as \(version)")
        }
        try? fm.removeItem(at: staged)
    }

    // MARK: Failed installs

    /// An install the helper could not finish (a volume without `RENAME_SWAP`, a bundle edited after it was
    /// checked, …), kept in `InstallFailure.plist` of the cache folder. The next run says so once, and automatic
    /// checks then offer that version as a download instead of fetching it again and failing on every quit; a
    /// manual check or a newer release tries again.
    public struct Failure: Codable, Equatable, Sendable {
        /// The version that did not install.
        public var version: String
        /// Path of the bundle it was meant to replace (another copy of the app is not concerned).
        public var target: String
        /// Why, for the user: e.g. `Operation not supported`.
        public var reason: String
        /// The user has been told (a toast, once).
        public var reported = false

        public init(version: AppVersion, target: URL, reason: String) {
            self.version = version.description
            self.target = target.path
            self.reason = reason
        }

        /// The record in `cache` (`cacheFolder` in the app).
        private static func record(in cache: URL) -> URL { cache.appendingPathComponent("InstallFailure.plist") }

        /// The recorded failure in `cache`; nil when there is none (or it is unreadable).
        public static func read(in cache: URL) -> Failure? {
            guard let data = try? Data(contentsOf: record(in: cache)) else { return nil }
            return try? PropertyListDecoder().decode(Failure.self, from: data)
        }

        /// Record (or replace) the failure in `cache`.
        public func write(in cache: URL) {
            do {
                try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                try PropertyListEncoder().encode(self).write(to: Self.record(in: cache), options: .atomic)
            } catch {
                Trace.log("update: cannot record the failed install: \(error)")
            }
        }

        public static func remove(in cache: URL) { try? FileManager.default.removeItem(at: record(in: cache)) }
    }

    /// What the user reads after "could not be installed:": the detail of an install error, the whole message
    /// otherwise.
    static func failureReason(_ error: Error) -> String {
        if case UpdateError.install(let detail) = error { return detail }
        return "\(error)"
    }

    // MARK: Helper process

    /// What the helper should do (parsed from its arguments).
    public struct Job: Equatable, Sendable {
        /// Process to wait for (the app that is quitting).
        public var pid: pid_t
        public var staged: URL
        public var target: URL
        public var version: AppVersion
        /// Start the app again after installing (or after failing to).
        public var relaunch = false
        /// File the relaunched app opens.
        public var reopen: URL?

        public init(pid: pid_t, staged: URL, target: URL, version: AppVersion, relaunch: Bool = false, reopen: URL? = nil) {
            self.pid = pid
            self.staged = staged
            self.target = target
            self.version = version
            self.relaunch = relaunch
            self.reopen = reopen
        }

        /// `--install-update <pid> <staged app> <target app> <version> [--relaunch] [--open <file>]`
        public var arguments: [String] {
            var arguments = [UpdateInstaller.helperFlag, String(pid), staged.path, target.path, version.description]
            if relaunch { arguments.append("--relaunch") }
            if let reopen { arguments += ["--open", reopen.path] }
            return arguments
        }

        /// Parses `arguments` (with or without the leading flag); nil when malformed.
        public init?(arguments: [String]) {
            var rest = arguments.first == UpdateInstaller.helperFlag ? Array(arguments.dropFirst()) : arguments
            guard rest.count >= 4, let pid = pid_t(rest[0]), pid > 0, let version = AppVersion(rest[3]) else { return nil }
            self.init(pid: pid, staged: URL(fileURLWithPath: rest[1]), target: URL(fileURLWithPath: rest[2]), version: version)
            rest.removeFirst(4)
            while let option = rest.first {
                rest.removeFirst()
                switch option {
                case "--relaunch": relaunch = true
                case "--open":
                    guard let path = rest.first else { return nil }
                    rest.removeFirst()
                    reopen = URL(fileURLWithPath: path)
                default: return nil
                }
            }
        }
    }

    /// Start the helper for `job` in its own session, so that it outlives the app.
    public static func spawnHelper(_ job: Job, executable: URL) throws {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own session (no hang-up from a terminal), and no file descriptors of the app but stderr.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addinherit_np(&actions, 2)
        let argv = ([executable.path] + job.arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable.path, &actions, &attributes, argv, environ)
        guard status == 0 else { throw UpdateError.install("cannot start the installer: \(String(cString: strerror(status)))") }
        Trace.log("update: installer \(pid) waits for \(job.pid) to quit")
    }

    /// Body of the helper process; returns its exit status. `requirement` defaults to the one for updates of the
    /// running app (the helper is the quitting app's own executable); a failed install is recorded in `cache`.
    public static func runHelper(_ arguments: [String], requirement: String? = nil, cache: URL? = cacheFolder) -> Int32 {
        guard let job = Job(arguments: arguments) else {
            FileHandle.standardError.write(Data("usage: Peekaboo \(helperFlag) <pid> <staged app> <target app> <version> [--relaunch] [--open <file>]\n".utf8))
            return 64
        }
        // Replacing the bundle under a running app could break it: without its exit, install nothing.
        guard waitForExit(job.pid, timeout: 120) else {
            Trace.log("update: process \(job.pid) did not quit; nothing installed")
            return 1
        }
        var status: Int32 = 0
        do {
            guard let requirement = requirement ?? CodeSignature.updateRequirementForRunningApp() else {
                throw UpdateError.verification("malformed team identifier")
            }
            try install(job.staged, over: job.target, version: job.version, requirement: requirement)
            Trace.log("update: installed \(job.version) at \(job.target.path)")
        } catch {
            Trace.log("update: \(error)")
            status = 1
            // Before the relaunch, so that the relaunched app can say so.
            if let cache { Failure(version: job.version, target: job.target, reason: failureReason(error)).write(in: cache) }
        }
        // The staged app sat in a folder named after its version (`<staging root>/<version>/Peekaboo.app`); after
        // the attempt it holds the old app or a download that failed its checks.
        let folder = job.staged.deletingLastPathComponent()
        if AppVersion(folder.lastPathComponent) == job.version { try? FileManager.default.removeItem(at: folder) }
        if job.relaunch { relaunch(job.target, reopening: job.reopen) }
        return status
    }

    /// Wait until process `pid` has exited (true) or `timeout` passed (false).
    static func waitForExit(_ pid: pid_t, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while kill(pid, 0) == 0 || errno != ESRCH {
            if Date() >= deadline { return false }
            usleep(20_000)
        }
        return true
    }

    private static func relaunch(_ app: URL, reopening file: URL?) {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", app.path] + (file.map { [$0.path] } ?? [])
        do {
            try open.run()
            open.waitUntilExit()
        } catch {
            Trace.log("update: cannot relaunch \(app.path): \(error)")
        }
    }
}
