import Darwin
import Foundation

/// Always one Peekaboo.app. A copy started from a disk image, or from the read-only path App Translocation runs a
/// quarantined app from, cannot update itself, and every downloaded version left one more Peekaboo behind. Such a copy
/// installs itself into Applications (`install`), opens its files in the installed copy and quits; the installed
/// copy then ejects the Peekaboo disk images (`diskImages`).
///
/// A normal launch pays two C string comparisons on its executable's path (`mayNeedInstalling(executable:)`);
/// everything else runs only for a copy that needs installing, or a second after the installed copy's launch.
public enum AppInstall {
    /// Argument of an installed copy started by the copy that installed it: `--eject-disk-images=<pid>`, the
    /// process to wait for before ejecting (the installing copy quits right after starting it).
    public static let ejectFlag = "--eject-disk-images"

    // MARK: Decision

    /// The executable (or bundle) at `path` lies under /Volumes or in App Translocation: only then can it need
    /// installing. All a normal launch pays, on `argv[0]` (the absolute path LaunchServices starts the app with):
    /// 0.3–0.6 µs on its first call, where `Bundle.main.bundlePath` alone takes 4–6 µs and Foundation's
    /// `String.contains` on it 30–55 µs (M4 Pro, release build).
    @inline(__always)
    public static func mayNeedInstalling(executable path: UnsafePointer<CChar>) -> Bool {
        strncmp(path, "/Volumes/", 9) == 0 || strstr(path, "/AppTranslocation/") != nil
    }

    /// `mayNeedInstalling(executable:)` for a Swift string.
    public static func mayNeedInstalling(_ path: String) -> Bool {
        path.withCString { mayNeedInstalling(executable: $0) }
    }

    /// The bundle at `app` must be installed to update itself: App Translocation runs it (a read-only copy of a
    /// quarantined app), or it lies on a read-only volume under /Volumes (a disk image). One on a writable volume (an
    /// external drive the app is kept on) stays where it is.
    public static func needsInstalling(_ app: URL, isOnReadOnlyVolume: (URL) -> Bool = isOnReadOnlyVolume) -> Bool {
        let path = app.path
        if path.contains("/AppTranslocation/") { return true }
        return path.hasPrefix("/Volumes/") && isOnReadOnlyVolume(app)
    }

    /// `url` lies on a volume mounted read-only (a disk image).
    public static func isOnReadOnlyVolume(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
    }

    /// The process that installed this copy and started it, from `arguments` (`--eject-disk-images=<pid>`); nil for
    /// any other launch.
    public static func installingProcess(in arguments: [String]) -> pid_t? {
        let prefix = ejectFlag + "="
        for argument in arguments where argument.hasPrefix(prefix) {
            if let pid = pid_t(argument.dropFirst(prefix.count)), pid > 0 { return pid }
        }
        return nil
    }

    // MARK: Target

    /// `/Applications/Peekaboo.app` when the user may write to `applications` (an administrator), else
    /// `~/Applications/Peekaboo.app`.
    public static func target(applications: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
                              home: URL = FileManager.default.homeDirectoryForCurrentUser,
                              isWritable: (URL) -> Bool = { access($0.path, W_OK) == 0 }) -> URL {
        let folder = isWritable(applications) ? applications : home.appendingPathComponent("Applications", isDirectory: true)
        return folder.appendingPathComponent("Peekaboo.app", isDirectory: true)
    }

    // MARK: Install

    /// What `install` did with the target.
    public enum Outcome: Equatable, Sendable {
        /// The target is this copy now.
        case installed
        /// The target holds a newer build (`build`): kept as it is.
        case newerInstalled(build: Int)
        /// The target runs: left alone, since nothing may be swapped under a running app.
        case running
    }

    /// Install the bundle `app` (Peekaboo `version`) at `target`, unless the target runs or holds a newer build.
    ///
    /// An older or the same build there is replaced: `app` is copied into a new folder on the target's volume, its
    /// quarantine flag is removed (the running copy has passed Gatekeeper; the installed one must not be asked about
    /// again, nor translocated), the copy is verified like an update (identifier, version and build, `requirement`)
    /// and swapped in with one atomic rename (`UpdateInstaller.install`). A copy that fails a check leaves the target as
    /// it was, and a bundle at `target` that is not Peekaboo is never touched.
    public static func install(_ app: URL, version: AppVersion, at target: URL, requirement: String,
                               isRunning: (URL) -> Bool) throws -> Outcome {
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            guard let build = peekabooBuild(target) else {
                throw UpdateError.install("\(target.path) is another app")
            }
            if isRunning(target) { return .running }
            if build > version.build { return .newerInstalled(build: build) }
        }
        let folder = target.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw UpdateError.install("cannot create \(folder.path): \(error.localizedDescription)")
        }
        let scratch = try stagingFolder(for: folder)
        defer { try? fm.removeItem(at: scratch) }
        let staged = scratch.appendingPathComponent(target.lastPathComponent, isDirectory: true)
        do {
            try fm.copyItem(at: app, to: staged)
        } catch {
            throw UpdateError.install("cannot copy \(app.lastPathComponent): \(error.localizedDescription)")
        }
        try removeQuarantine(in: staged)
        try UpdateInstaller.install(staged, over: target, version: version, requirement: requirement)
        return .installed
    }

    /// Version of the Peekaboo bundle at `app`; nil when it is not Peekaboo or carries no release version.
    public static func peekabooVersion(_ app: URL) -> AppVersion? {
        guard let info = try? UpdateInstaller.bundleInfo(app), info.identifier == CodeSignature.bundleIdentifier else {
            return nil
        }
        return info.version
    }

    /// Build number (`CFBundleVersion`) of the Peekaboo bundle at `app`, 0 when it is not a number; nil when `app` is
    /// not Peekaboo (another identifier, no readable `Info.plist`).
    static func peekabooBuild(_ app: URL) -> Int? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == CodeSignature.bundleIdentifier
        else { return nil }
        return (plist["CFBundleVersion"] as? String).flatMap { Int($0) } ?? 0
    }

    /// A new, empty folder on the volume of `folder`, so that installing from it is a rename.
    static func stagingFolder(for folder: URL) throws -> URL {
        let fm = FileManager.default
        let scratch: URL
        do {
            scratch = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
        } catch {
            throw UpdateError.install("no folder for the copy on the volume of \(folder.path): \(error.localizedDescription)")
        }
        guard UpdateInstaller.device(scratch) == UpdateInstaller.device(folder) else {
            try? fm.removeItem(at: scratch)
            throw UpdateError.install("no folder for the copy on the volume of \(folder.path)")
        }
        return scratch
    }

    /// Remove the quarantine flag (`com.apple.quarantine`) from `bundle` and everything in it (symbolic links
    /// themselves, never what they point to).
    public static func removeQuarantine(in bundle: URL) throws {
        try removeQuarantine(atPath: bundle.path)
        guard let entries = FileManager.default.enumerator(atPath: bundle.path) else { return }
        for case let entry as String in entries { try removeQuarantine(atPath: bundle.path + "/" + entry) }
    }

    private static func removeQuarantine(atPath path: String) throws {
        // No such attribute, or a volume without extended attributes: nothing to remove.
        guard removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW) == 0 || errno == ENOATTR || errno == ENOTSUP else {
            throw UpdateError.install("cannot clear the quarantine flag of \(path): \(String(cString: strerror(errno)))")
        }
    }

    /// What the user reads after "Peekaboo could not be installed in Applications:".
    public static func failureReason(_ error: Error) -> String {
        switch error {
        case UpdateError.verification(let detail): return "the copy failed verification: \(detail)"
        case UpdateError.install(let detail): return detail
        default: return "\(error)"
        }
    }

    // MARK: Eject

    /// A mounted volume as the system lists it (nothing on it is read).
    public struct Volume: Equatable, Sendable {
        public var url: URL
        public var isReadOnly: Bool
        public var isLocal: Bool

        public init(url: URL, isReadOnly: Bool, isLocal: Bool) {
            self.url = url
            self.isReadOnly = isReadOnly
            self.isLocal = isLocal
        }
    }

    /// The mounted volumes that are not hidden (a disk image attached with `-nobrowse` is).
    public static func mountedVolumes() -> [Volume] {
        let keys: [URLResourceKey] = [.volumeIsReadOnlyKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return Volume(url: url, isReadOnly: values?.volumeIsReadOnly == true, isLocal: values?.volumeIsLocal == true)
        }
    }

    /// The Peekaboo disk images among `volumes`: read-only local volumes mounted under `root` with a Peekaboo.app of
    /// this bundle identifier at the top, as every Peekaboo disk image has it. Only a volume that passes the first
    /// three checks is read (one `Info.plist`); the system volumes, writable drives and network shares are not.
    public static func diskImages(in volumes: [Volume], under root: String = "/Volumes/") -> [URL] {
        volumes.filter { volume in
            volume.isReadOnly && volume.isLocal && volume.url.path.hasPrefix(root)
                && peekabooBuild(volume.url.appendingPathComponent("Peekaboo.app", isDirectory: true)) != nil
        }.map(\.url)
    }
}
