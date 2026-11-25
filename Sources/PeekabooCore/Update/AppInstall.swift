import Darwin
import DiskArbitration
import Foundation

/// Always one Peekaboo.app. A copy started from a disk image, or from the read-only path App Translocation runs a
/// quarantined app from, cannot update itself, and every downloaded version left one more Peekaboo behind. Such a copy
/// installs itself into Applications (`install`), opens its files in the installed copy and quits; the installed
/// copy then ejects the Peekaboo disk images (`diskImages`).
///
/// A normal launch pays two C string comparisons on its executable's path (`needsInstalling(executable:)`), a copy kept
/// on a writable drive under /Volumes one `statfs` more; everything else runs only for a copy that needs installing,
/// or a second after the installed copy's launch.
public enum AppInstall {
    /// Argument of an installed copy started by the copy that installed it: `--eject-disk-images=<pid>`, the
    /// process to wait for before ejecting (the installing copy quits right after starting it).
    public static let ejectFlag = "--eject-disk-images"
    /// Comes with `ejectFlag` when nothing was installed: the copy started is newer than the one that started it.
    public static let keptNewerFlag = "--kept-newer"

    // MARK: Decision

    /// The executable (or bundle) at `path` must be installed to update itself: App Translocation runs it (a read-only
    /// copy of a quarantined app), or it lies on a read-only volume under /Volumes (a disk image). One on a writable
    /// volume (an external drive the app is kept on) stays where it is. All a normal launch pays, on `argv[0]` (the
    /// absolute path LaunchServices starts the app with): two C string comparisons, 0.1–0.4 µs on the first call;
    /// a path under /Volumes adds one `statfs` (`isOnReadOnlyVolume`, 2.5–6.5 µs). Foundation's `String.contains` on
    /// `Bundle.main.bundlePath` took 30–55 µs (M4 Pro, release build).
    @inline(__always)
    public static func needsInstalling(executable path: UnsafePointer<CChar>,
                                       isOnReadOnlyVolume: (UnsafePointer<CChar>) -> Bool = isOnReadOnlyVolume) -> Bool {
        if strncmp(path, "/Volumes/", 9) == 0 { return isOnReadOnlyVolume(path) }
        return strstr(path, "/AppTranslocation/") != nil
    }

    /// `path` lies on a volume mounted read-only (a disk image): one `statfs`.
    public static func isOnReadOnlyVolume(_ path: UnsafePointer<CChar>) -> Bool {
        var volume = statfs()
        return statfs(path, &volume) == 0 && volume.f_flags & UInt32(MNT_RDONLY) != 0
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

    /// Where Peekaboo installs itself: `/Applications/Peekaboo.app`, then `~/Applications/Peekaboo.app`.
    public static func locations(applications: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
                                 home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [applications, home.appendingPathComponent("Applications", isDirectory: true)]
            .map { $0.appendingPathComponent("Peekaboo.app", isDirectory: true) }
    }

    /// `/Applications/Peekaboo.app` when the user may install there: `applications` is writable (an administrator)
    /// and a bundle already there is Peekaboo's and the user's to replace (moving a folder into another folder needs
    /// write access to it too, which a copy of another account's or of an installer package does not grant). Else
    /// `~/Applications/Peekaboo.app`.
    public static func target(applications: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
                              home: URL = FileManager.default.homeDirectoryForCurrentUser,
                              isWritable: (URL) -> Bool = { access($0.path, W_OK) == 0 }) -> URL {
        let locations = locations(applications: applications, home: home)
        let system = locations[0]
        guard isWritable(applications) else { return locations[1] }
        guard FileManager.default.fileExists(atPath: system.path) else { return system }
        return peekabooBuild(system) != nil && isWritable(system) ? system : locations[1]
    }

    /// "Applications", "Applications in your home folder" (`~/Applications`), or the folder's name: where `folder`
    /// is, for the user.
    public static func place(_ folder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let path = folder.standardizedFileURL.path
        if path == "/Applications" { return "Applications" }
        if path == home.appendingPathComponent("Applications").standardizedFileURL.path { return "Applications in your home folder" }
        return folder.lastPathComponent
    }

    /// "Peekaboo.app in Applications": the bundle at `app`, for the user.
    public static func describe(_ app: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        "\(app.lastPathComponent) in \(place(app.deletingLastPathComponent(), home: home))"
    }

    // MARK: Install

    /// What `install` did.
    public enum Outcome: Equatable, Sendable {
        /// The target is this copy now.
        case installed
        /// The Peekaboo at the URL is kept as it is, and the files open in it: a newer build (`build`) at the target
        /// or in the other Applications folder, or the same build there.
        case kept(URL, build: Int)
        /// The Peekaboo at the URL (build `build`) runs: nothing may be swapped under a running app.
        case running(URL, build: Int)
    }

    /// Install the bundle `app` (Peekaboo `version`) at `target`, unless a newer Peekaboo is installed there or at one
    /// of `elsewhere` (the other Applications folder, where the same build counts too: installing it would make two),
    /// or the target runs (`isRunning`).
    ///
    /// An older or the same build at the target is replaced: `app` is copied into a new folder on the target's volume,
    /// its quarantine flag is removed (the running copy has passed Gatekeeper; the installed one must not be asked about
    /// again, nor translocated), the copy is verified like an update (identifier, version and build, `requirement`) and
    /// swapped in with one atomic rename. The target is checked again right before the swap, and what the swap moved
    /// out must still be what was checked (another installer may have put a newer build there meanwhile): if it is not,
    /// the swap is undone. A copy that fails a check leaves the target as it was, and a bundle at `target` that is not
    /// Peekaboo is never touched.
    public static func install(_ app: URL, version: AppVersion, at target: URL, elsewhere: [URL] = [], requirement: String,
                               isRunning: (URL) -> Bool) throws -> Outcome {
        let fm = FileManager.default
        var installed: Int?
        if fm.fileExists(atPath: target.path) {
            guard let build = peekabooBuild(target) else { throw UpdateError.install("\(describe(target)) is another app") }
            installed = build
        }
        // A newer Peekaboo is never replaced: the files open in the newest one installed. In the other folder the same
        // build counts too, unless the target holds it (replacing that one repairs it).
        var kept: (app: URL, build: Int)?
        if let installed, installed > version.build { kept = (target, installed) }
        for other in elsewhere {
            guard let build = peekabooBuild(other),
                  build > version.build || (build == version.build && installed != version.build) else { continue }
            if build > (kept?.build ?? 0) { kept = (other, build) }
        }
        if let kept { return isRunning(kept.app) ? .running(kept.app, build: kept.build) : .kept(kept.app, build: kept.build) }
        if let installed, isRunning(target) { return .running(target, build: installed) }

        let folder = target.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw UpdateError.install("cannot create \(place(folder)): \(error.localizedDescription)")
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
        try UpdateInstaller.verify(staged, version: version, requirement: requirement)
        // The copy and its signature check took 20–130 ms: a copy started meanwhile keeps its bundle.
        if let build = peekabooBuild(target), isRunning(target) { return .running(target, build: build) }
        do {
            try UpdateInstaller.swap(staged, over: target, version: version) { displaced in
                guard let build = peekabooBuild(displaced) else { throw UpdateError.install("\(describe(target)) is another app") }
                if build > version.build { throw Displaced.newer(build) }
            }
        } catch Displaced.newer(let build) {
            // The copy that put it there may have started it already.
            return isRunning(target) ? .running(target, build: build) : .kept(target, build: build)
        }
        return .installed
    }

    /// The swap moved a newer Peekaboo out of the target: undone.
    private enum Displaced: Error { case newer(Int) }

    /// Version of the Peekaboo bundle at `app`; nil when it is not Peekaboo or carries no release version.
    public static func peekabooVersion(_ app: URL) -> AppVersion? {
        guard let info = try? UpdateInstaller.bundleInfo(app), info.identifier == CodeSignature.bundleIdentifier else {
            return nil
        }
        return info.version
    }

    /// Build number (`CFBundleVersion`) of the Peekaboo bundle at `app`, 0 when it is not a number; nil when `app` is
    /// not Peekaboo (another identifier, no readable `Info.plist`).
    public static func peekabooBuild(_ app: URL) -> Int? {
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
            throw UpdateError.install("no folder for the copy on the volume of \(place(folder)): \(error.localizedDescription)")
        }
        guard UpdateInstaller.device(scratch) == UpdateInstaller.device(folder) else {
            try? fm.removeItem(at: scratch)
            throw UpdateError.install("no folder for the copy on the volume of \(place(folder))")
        }
        return scratch
    }

    /// Remove the quarantine flag (`com.apple.quarantine`) from `bundle` and everything in it (symbolic links
    /// themselves, never what they point to).
    public static func removeQuarantine(in bundle: URL) throws {
        try removeQuarantine(bundle.lastPathComponent, in: bundle)
        guard let entries = FileManager.default.enumerator(atPath: bundle.path) else { return }
        for case let entry as String in entries { try removeQuarantine(bundle.lastPathComponent + "/" + entry, in: bundle) }
    }

    /// `name`: the item's path from the bundle's folder on (`Peekaboo.app/Contents/…`).
    private static func removeQuarantine(_ name: String, in bundle: URL) throws {
        let path = bundle.deletingLastPathComponent().path + "/" + name
        // No such attribute, or a volume without extended attributes: nothing to remove.
        guard removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW) == 0 || errno == ENOATTR || errno == ENOTSUP else {
            throw UpdateError.install("cannot clear the quarantine flag of \(name): \(String(cString: strerror(errno)))")
        }
    }

    /// Why nothing was installed, for the line under "Peekaboo could not be installed in Applications".
    public static func failureReason(_ error: Error) -> String {
        switch error {
        case UpdateError.verification(let detail): return "The copy failed verification: \(detail)"
        case UpdateError.install(let detail): return detail.prefix(1).uppercased() + detail.dropFirst()
        default: return "\(error)"
        }
    }

    // MARK: Processes

    /// The processes other than this one whose executable lies in the bundle at `app`: copies of the app (other users'
    /// too, as far as the system tells), and the update installer a quitting copy starts (`--install-update`), which no
    /// list of apps shows. 1–2 ms.
    public static func processes(runningFrom app: URL) -> [pid_t] {
        // The path as the kernel names an executable (`/private/var/…`, where `resolvingSymlinksInPath` drops `/private`).
        guard let real = realpath(app.path, nil) else { return [] }
        let prefix = String(cString: real) + "/"
        free(real)
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let me = getpid()
        return pids.prefix(Int(max(count, 0))).filter { pid in
            pid != me && proc_pidpath(pid, &path, UInt32(path.count)) > 0 && String(cString: path).hasPrefix(prefix)
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

    /// The Peekaboo disk images among `volumes`: read-only local volumes mounted under `root`, holding none of the files
    /// in `keeping` (the ones the installed copy shows), with a Peekaboo.app of this bundle identifier at the top, as
    /// every Peekaboo disk image has it, and that are disk images indeed (`isDiskImage`), not a drive macOS mounts
    /// read-only (NTFS, a locked card, a disc). Only a volume that passes the first checks is read (one `Info.plist`)
    /// and asked about (DiskArbitration); the system volumes, writable drives and network shares are not.
    public static func diskImages(in volumes: [Volume], under root: String = "/Volumes/", keeping: [URL] = [],
                                  isDiskImage: (URL) -> Bool = isDiskImage) -> [URL] {
        let kept = keeping.map { $0.standardizedFileURL.path }
        return volumes.filter { volume in
            let path = volume.url.standardizedFileURL.path
            return volume.isReadOnly && volume.isLocal && path.hasPrefix(root) && !kept.contains { $0.hasPrefix(path + "/") }
                && peekabooBuild(volume.url.appendingPathComponent("Peekaboo.app", isDirectory: true)) != nil
                && isDiskImage(volume.url)
        }.map(\.url)
    }

    /// The volume mounted at `url` lies on a disk image (attached by Finder or `hdiutil`): its device, as
    /// DiskArbitration describes it (0.2–0.5 ms).
    public static func isDiskImage(_ url: URL) -> Bool {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let description = DADiskCopyDescription(disk) as? [String: Any]
        else { return false }
        return description[kDADiskDescriptionDeviceModelKey as String] as? String == "Disk Image"
    }
}
