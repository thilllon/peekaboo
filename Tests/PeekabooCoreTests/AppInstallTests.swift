import Darwin
import XCTest
@testable import PeekabooCore

/// Always one Peekaboo.app (`AppInstall`): which launches install, where to, replacing an older copy and keeping a newer
/// one, the quarantine flag, and which volumes are Peekaboo disk images. Fake bundles and volumes in a scratch folder
/// (one disk image of its own); nothing here reads or changes /Applications, ~/Applications or a volume of the user's.
final class AppInstallTests: XCTestCase {
    private var directory: URL!
    private let adHoc = CodeSignature.updateRequirement(teamIdentifier: nil)!
    private static let quarantine = "com.apple.quarantine"
    /// A uid other than this process's: the account logged in next to this one.
    private static let anotherUser: uid_t = getuid() == 501 ? 502 : 501

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("peekaboo-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Decision

    func testOnlyADiskImageOrATranslocatedCopyInstalls() {
        var looked: [String] = []
        func needs(_ path: String, readOnly: Bool) -> Bool {
            AppInstall.needsInstalling(executable: path) { volume in
                looked.append(String(cString: volume))
                return readOnly
            }
        }
        // Normal launches: the string checks say no, and no volume is looked at.
        let home = NSHomeDirectory()
        for path in ["/Applications/Peekaboo.app", home + "/Applications/Peekaboo.app", home + "/Downloads/Peekaboo.app",
                     "/Applications/Peekaboo.app/Contents/MacOS/Peekaboo", "/VolumesX/Peekaboo.app",
                     "/private/Volumes/x/Peekaboo.app", "/Applications/AppTranslocation.app/Peekaboo.app",
                     "Peekaboo" /* a relative path from a terminal */] {
            XCTAssertFalse(needs(path, readOnly: true), path)
        }
        XCTAssertEqual(looked, [], "a normal launch pays the string checks alone")

        // Under /Volumes: a read-only volume (a disk image) installs, a writable one (an external drive) does not.
        let image = "/Volumes/Peekaboo 20261126-69a847/Peekaboo.app/Contents/MacOS/Peekaboo"
        let drive = "/Volumes/SSD/Apps/Peekaboo.app"
        XCTAssertTrue(needs(image, readOnly: true))
        XCTAssertFalse(needs(drive, readOnly: false))
        XCTAssertEqual(looked, [image, drive])

        // App Translocation's read-only copy installs, wherever it is mounted, without a volume lookup.
        looked = []
        for translocated in ["/private/var/folders/xy/abc123/T/AppTranslocation/0F2A5C1E-9B7D-4E7A/d/Peekaboo.app",
                             "/private/var/folders/xy/T/AppTranslocation/0F2A/d/Peekaboo.app/Contents/MacOS/Peekaboo"] {
            XCTAssertTrue(needs(translocated, readOnly: false), translocated)
        }
        XCTAssertEqual(looked, [])

        // The real volume check (`statfs`): the scratch folder is writable (the read-only one: the disk image test).
        XCTAssertFalse(AppInstall.isOnReadOnlyVolume(directory.path))
        XCTAssertFalse(AppInstall.isOnReadOnlyVolume(directory.appendingPathComponent("missing").path), "no such file")
    }

    func testTheInstalledCopyIsToldWhichProcessToWaitFor() {
        XCTAssertEqual(AppInstall.installingProcess(in: ["/Applications/Peekaboo.app/Contents/MacOS/Peekaboo",
                                                         "--eject-disk-images=4242"]), 4242)
        XCTAssertEqual(AppInstall.installingProcess(in: ["x", "/a.jpg", "\(AppInstall.ejectFlag)=17"]), 17)
        for arguments in [[], ["x"], ["x", "--eject-disk-images"], ["x", "--eject-disk-images="],
                          ["x", "--eject-disk-images=0"], ["x", "--eject-disk-images=-3"], ["x", "--eject-disk-images=abc"],
                          ["x", "--eject-disk-images", "4242"], ["x", "--selftest", "/tmp"]] {
            XCTAssertNil(AppInstall.installingProcess(in: arguments), "\(arguments)")
        }
    }

    // MARK: Target

    func testTargetIsApplicationsWhenWritableElseTheHomeFolders() throws {
        // Scratch folders stand in for /Applications and the home folder (the real ones are never looked at).
        let applications = directory.appendingPathComponent("System Applications", isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let system = applications.appendingPathComponent("Peekaboo.app", isDirectory: true)
        let user = home.appendingPathComponent("Applications/Peekaboo.app", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        XCTAssertEqual(AppInstall.locations(applications: applications, home: home), [system, user])
        var asked: [String] = []
        func target(writable: Bool) -> URL {
            AppInstall.target(applications: applications, home: home) { asked.append($0.lastPathComponent); return writable }
        }
        XCTAssertEqual(target(writable: true), system, "an administrator, nothing installed yet")
        XCTAssertEqual(target(writable: false), user)
        XCTAssertEqual(asked, ["System Applications", "System Applications"])

        // A bundle there must be a Peekaboo the user may replace: another app of that name is never replaced.
        try makeApp(system, version: releaseVersion(25), sign: false)
        asked = []
        XCTAssertEqual(target(writable: true), system)
        XCTAssertEqual(asked, ["System Applications", "Peekaboo.app"])
        try FileManager.default.removeItem(at: system)
        try makeApp(system, version: releaseVersion(25), identifier: "com.example.Peekaboo", sign: false)
        XCTAssertEqual(target(writable: true), user, "another app named Peekaboo.app")
        try FileManager.default.removeItem(at: system)

        // The real check (`access`). A bundle folder the user cannot write (another account's, an installer package's)
        // cannot be moved out of the way: the swap would fail with EACCES on every launch.
        try makeApp(system, version: releaseVersion(25), sign: false)
        XCTAssertEqual(AppInstall.target(applications: applications, home: home), system)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: system.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: system.path) }
        guard access(system.path, W_OK) != 0 else { throw XCTSkip("read-only folders are writable here (root?)") }
        XCTAssertEqual(AppInstall.target(applications: applications, home: home), user, "a bundle folder it cannot move")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: system.path)
        // Nor can anything go into a read-only Applications folder.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: applications.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: applications.path) }
        XCTAssertEqual(AppInstall.target(applications: applications, home: home), user, "a folder it cannot write")
    }

    func testPlacesAreNamedForTheUser() {
        let home = URL(fileURLWithPath: "/home/someone", isDirectory: true)
        XCTAssertEqual(AppInstall.place(URL(fileURLWithPath: "/Applications"), home: home), "Applications")
        XCTAssertEqual(AppInstall.place(URL(fileURLWithPath: "/home/someone/Applications/"), home: home),
                       "Applications in your home folder")
        XCTAssertEqual(AppInstall.place(URL(fileURLWithPath: "/Volumes/SSD/Apps"), home: home), "Apps")
        XCTAssertEqual(AppInstall.describe(URL(fileURLWithPath: "/Applications/Peekaboo.app"), home: home),
                       "Peekaboo.app in Applications")
    }

    // MARK: Install

    /// The copy that runs from the "disk image" (a folder here) and the target in a scratch "Applications" folder.
    private func source(_ version: AppVersion) throws -> URL {
        try makeApp(directory.appendingPathComponent("Volumes/Peekaboo \(version)/Peekaboo.app"), version: version)
    }

    private var target: URL { directory.appendingPathComponent("Applications/Peekaboo.app", isDirectory: true) }
    /// The other Applications folder's Peekaboo.app.
    private var other: URL { directory.appendingPathComponent("home/Applications/Peekaboo.app", isDirectory: true) }

    /// `AppInstall.install` at `target`, with `other` as the other Applications folder; `running`: the target runs.
    private func install(_ app: URL, _ version: AppVersion, running: Bool = false) throws -> AppInstall.Outcome {
        try AppInstall.install(app, version: version, at: target, elsewhere: [other], requirement: adHoc) { url in
            XCTAssertTrue([self.target, self.other].contains(url), url.path)
            return running && url == self.target
        }
    }

    private func resource(_ app: URL) throws -> String {
        try String(contentsOf: app.appendingPathComponent("Contents/Resources/data.txt"), encoding: .utf8)
    }

    func testInstallsIntoAFolderThatDoesNotExistYet() throws {
        let app = try source(releaseVersion(26))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path))
        XCTAssertEqual(try install(app, releaseVersion(26)), .installed)
        XCTAssertEqual(AppInstall.peekabooVersion(target), releaseVersion(26))
        XCTAssertNoThrow(try CodeSignature.check(target, requirement: adHoc))
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path), "the running copy stays where it is")
    }

    func testReplacesAnOlderBuildAndTheSameBuild() throws {
        try makeApp(target, version: releaseVersion(25))
        let app = try source(releaseVersion(26))
        XCTAssertEqual(try install(app, releaseVersion(26)), .installed)
        XCTAssertEqual(AppInstall.peekabooVersion(target), releaseVersion(26))
        XCTAssertEqual(try resource(target), "resource of \(releaseVersion(26))")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path),
                       ["Peekaboo.app"], "nothing is left next to it")

        // The same build again: replaced too (a damaged or quarantined copy is repaired that way).
        try Data("edited".utf8).write(to: target.appendingPathComponent("Contents/Resources/data.txt"))
        XCTAssertEqual(try install(app, releaseVersion(26)), .installed)
        XCTAssertEqual(try resource(target), "resource of \(releaseVersion(26))")
        XCTAssertNoThrow(try CodeSignature.check(target, requirement: adHoc))
    }

    func testReplacesTheFirstReleaseWhoseVersionIsNotADate() throws {
        // 0.1.0 (build 1), from before versions were dates.
        try makeApp(target, version: releaseVersion(1), shortVersion: "0.1.0")
        XCTAssertEqual(AppInstall.peekabooBuild(target), 1)
        XCTAssertNil(AppInstall.peekabooVersion(target))
        XCTAssertEqual(try install(try source(releaseVersion(26)), releaseVersion(26)), .installed)
        XCTAssertEqual(AppInstall.peekabooVersion(target), releaseVersion(26))
    }

    func testKeepsANewerBuild() throws {
        try makeApp(target, version: releaseVersion(27))
        let before = try FileManager.default.attributesOfItem(atPath: target.path)[.systemFileNumber] as? Int
        XCTAssertEqual(try install(try source(releaseVersion(26)), releaseVersion(26)), .kept(target, build: 27))
        XCTAssertEqual(AppInstall.peekabooVersion(target), releaseVersion(27))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: target.path)[.systemFileNumber] as? Int, before,
                       "the very same bundle")
    }

    func testKeepsANewerBuildInTheOtherApplicationsFolder() throws {
        // A standard user's target is ~/Applications, an administrator may have put a newer one into /Applications (and
        // the other way round): that one is used, and nothing is installed.
        let app = try source(releaseVersion(26))
        try makeApp(other, version: releaseVersion(27))
        XCTAssertEqual(try install(app, releaseVersion(26)), .kept(other, build: 27))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "no second Peekaboo")
        // Running, it gets the files.
        XCTAssertEqual(try AppInstall.install(app, version: releaseVersion(26), at: target, elsewhere: [other], requirement: adHoc,
                                              isRunning: { $0 == self.other }), .running(other, build: 27))
        // The same build there counts as installed too: installing it would make two.
        try FileManager.default.removeItem(at: other)
        try makeApp(other, version: releaseVersion(26))
        XCTAssertEqual(try install(app, releaseVersion(26)), .kept(other, build: 26))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        // Unless the target holds it as well: that one is replaced (repaired) as before.
        try makeApp(target, version: releaseVersion(26))
        XCTAssertEqual(try install(app, releaseVersion(26)), .installed)
        // Of two newer ones the newest wins; an older one there, or another app, changes nothing.
        try FileManager.default.removeItem(at: target)
        try makeApp(target, version: releaseVersion(27))
        try FileManager.default.removeItem(at: other)
        try makeApp(other, version: releaseVersion(28))
        XCTAssertEqual(try install(app, releaseVersion(26)), .kept(other, build: 28))
        for (version, identifier) in [(releaseVersion(25), "com.thilllon.Peekaboo"), (releaseVersion(28), "com.example.Peekaboo")] {
            try FileManager.default.removeItem(at: target)
            try FileManager.default.removeItem(at: other)
            try makeApp(other, version: version, identifier: identifier, sign: false)
            XCTAssertEqual(try install(app, releaseVersion(26)), .installed, identifier)
            XCTAssertEqual(AppInstall.peekabooVersion(target), releaseVersion(26))
            XCTAssertEqual(try UpdateInstaller.bundleInfo(other).identifier, identifier, "the other copy is left alone")
        }
    }

    func testLeavesARunningTargetAlone() throws {
        try makeApp(target, version: releaseVersion(25))
        XCTAssertEqual(try install(try source(releaseVersion(26)), releaseVersion(26), running: true), .running(target, build: 25))
        XCTAssertEqual(AppInstall.peekabooVersion(target), releaseVersion(25), "nothing is swapped under a running app")
    }

    /// What `install` finds is checked again right before the swap, and what the swap moved out must still be what was
    /// checked: another disk image's copy, or the installed copy's update installer, may change the target meanwhile.
    func testAChangedTargetIsNeverReplaced() throws {
        let app = try source(releaseVersion(26))
        let newer = try makeApp(directory.appendingPathComponent("Newer/Peekaboo.app"), version: releaseVersion(27))
        let another = try makeApp(directory.appendingPathComponent("Another/Peekaboo.app"), version: releaseVersion(28),
                                  identifier: "com.example.Peekaboo")
        /// Install over build 25, while `change` replaces the target after the first check.
        func install(changing change: @escaping () throws -> Void, running: [Bool] = [false, false]) throws -> AppInstall.Outcome {
            try? FileManager.default.removeItem(at: target)
            try makeApp(target, version: releaseVersion(25))
            var calls = 0
            return try AppInstall.install(app, version: releaseVersion(26), at: target, requirement: adHoc) { _ in
                defer { calls += 1 }
                if calls == 0 { try? change() }
                return running[min(calls, running.count - 1)]
            }
        }
        func put(_ bundle: URL) throws {
            try FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: bundle, to: target)
        }
        // A newer build put there meanwhile: the swap is undone, and that one is kept (it gets the files if it runs by then).
        XCTAssertEqual(try install(changing: { try put(newer) }), .kept(target, build: 27))
        XCTAssertEqual(AppInstall.peekabooVersion(target), releaseVersion(27))
        XCTAssertNoThrow(try CodeSignature.check(target, requirement: adHoc))
        XCTAssertEqual(try install(changing: { try put(newer) }, running: [false, false, true]), .running(target, build: 27))
        XCTAssertEqual(AppInstall.peekabooVersion(target), releaseVersion(27))
        // Another app put there meanwhile: undone too, and never touched.
        XCTAssertThrowsError(try install(changing: { try put(another) })) { error in
            XCTAssertEqual(AppInstall.failureReason(error), "Peekaboo.app in Applications is another app")
        }
        XCTAssertEqual(try UpdateInstaller.bundleInfo(target).identifier, "com.example.Peekaboo")
        XCTAssertEqual(try resource(target), "resource of \(releaseVersion(28))")
        // An older build put there meanwhile is replaced, like the one it replaced.
        let older = try makeApp(directory.appendingPathComponent("Older/Peekaboo.app"), version: releaseVersion(24))
        XCTAssertEqual(try install(changing: { try put(older) }), .installed)
        XCTAssertEqual(AppInstall.peekabooVersion(target), releaseVersion(26))
        // Started meanwhile: it keeps its bundle.
        XCTAssertEqual(try install(changing: {}, running: [false, true]), .running(target, build: 25))
        XCTAssertEqual(AppInstall.peekabooVersion(target), releaseVersion(25))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path),
                       ["Peekaboo.app"], "nothing is left next to it")
    }

    func testNeverTouchesAnotherAppOfThatName() throws {
        try makeApp(target, version: releaseVersion(25), identifier: "com.example.Peekaboo")
        let app = try source(releaseVersion(26))
        XCTAssertThrowsError(try install(app, releaseVersion(26))) { error in
            XCTAssertEqual(AppInstall.failureReason(error), "Peekaboo.app in Applications is another app")
        }
        XCTAssertEqual(try UpdateInstaller.bundleInfo(target).identifier, "com.example.Peekaboo")
        XCTAssertEqual(try resource(target), "resource of \(releaseVersion(25))")
        // A bundle without an Info.plist is not known to be Peekaboo either.
        try FileManager.default.removeItem(at: target.appendingPathComponent("Contents/Info.plist"))
        XCTAssertThrowsError(try install(app, releaseVersion(26)))
        XCTAssertEqual(try resource(target), "resource of \(releaseVersion(25))")
    }

    func testACopyThatFailsVerificationLeavesTheTargetUntouched() throws {
        try makeApp(target, version: releaseVersion(25))
        let app = try source(releaseVersion(26))
        // Edited after it was signed.
        try Data("tampered".utf8).write(to: app.appendingPathComponent("Contents/Resources/data.txt"))
        XCTAssertThrowsError(try install(app, releaseVersion(26))) { error in
            XCTAssertTrue(AppInstall.failureReason(error).hasPrefix("The copy failed verification: "), "\(error)")
        }
        XCTAssertEqual(AppInstall.peekabooVersion(target), releaseVersion(25))
        XCTAssertEqual(try resource(target), "resource of \(releaseVersion(25))")
        XCTAssertNoThrow(try CodeSignature.check(target, requirement: adHoc))
        // Not the version it claims to be; signed by another team.
        let other = try makeApp(directory.appendingPathComponent("Other/Peekaboo.app"), version: releaseVersion(26))
        XCTAssertThrowsError(try install(other, releaseVersion(27)))
        XCTAssertThrowsError(try AppInstall.install(other, version: releaseVersion(26), at: target,
                                                    requirement: CodeSignature.updateRequirement(teamIdentifier: "ABCDE12345")!,
                                                    isRunning: { _ in false }))
        XCTAssertEqual(AppInstall.peekabooVersion(target), releaseVersion(25))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path),
                       ["Peekaboo.app"], "no copy is left next to it")
    }

    func testTheInstalledCopyCarriesNoQuarantineFlag() throws {
        let app = try source(releaseVersion(26))
        let files = [app.path, app.appendingPathComponent("Contents/MacOS/Peekaboo").path,
                     app.appendingPathComponent("Contents/Resources/data.txt").path]
        for file in files { try setQuarantine(file) }
        XCTAssertEqual(try install(app, releaseVersion(26)), .installed)
        for file in files {
            let installed = file.replacingOccurrences(of: app.path, with: target.path)
            XCTAssertFalse(hasQuarantine(installed), installed)
            XCTAssertTrue(hasQuarantine(file), "the running copy is left as it is: \(file)")
        }
        XCTAssertNoThrow(try CodeSignature.check(target, requirement: adHoc))

        // On its own, on every file and folder of a bundle, and on a symbolic link itself (not what it points to).
        let bundle = try makeApp(directory.appendingPathComponent("Strip/Peekaboo.app"), version: releaseVersion(26), sign: false)
        let outside = directory.appendingPathComponent("outside.txt")
        try Data("x".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: bundle.appendingPathComponent("Contents/Resources/link"),
                                                   withDestinationURL: outside)
        try setQuarantine(outside.path)
        let all = try XCTUnwrap(FileManager.default.subpaths(atPath: bundle.path)).map { bundle.path + "/" + $0 } + [bundle.path]
        for path in all { try setQuarantine(path, noFollow: true) }
        try AppInstall.removeQuarantine(in: bundle)
        for path in all { XCTAssertFalse(hasQuarantine(path), path) }
        XCTAssertTrue(hasQuarantine(outside.path), "a link's destination outside the bundle is not touched")
        XCTAssertNoThrow(try AppInstall.removeQuarantine(in: bundle), "nothing left to remove")
    }

    /// A newer Peekaboo on a disk image, staged by the running copy for the update installer (`DiskImageUpdate`): next to
    /// the updater's downloads, without the quarantine flag, verified like an update; nothing is left of a copy that fails.
    func testStagesADiskImagesCopyLikeADownload() throws {
        let app = try source(releaseVersion(26))
        let files = [app.path, app.appendingPathComponent("Contents/MacOS/Peekaboo").path,
                     app.appendingPathComponent("Contents/Resources/data.txt").path]
        for file in files { try setQuarantine(file) }
        let root = directory.appendingPathComponent("cache/Updates", isDirectory: true)
        let folder = root.appendingPathComponent(releaseVersion(26).token, isDirectory: true)
        let staged = try AppInstall.stage(app, version: releaseVersion(26), in: root, requirement: adHoc)
        XCTAssertEqual(staged, folder.appendingPathComponent("Peekaboo.app", isDirectory: true), "where the updater stages a download")
        XCTAssertEqual(AppInstall.peekabooVersion(staged), releaseVersion(26))
        XCTAssertNoThrow(try CodeSignature.check(staged, requirement: adHoc))
        for file in files {
            XCTAssertFalse(hasQuarantine(file.replacingOccurrences(of: app.path, with: staged.path)), file)
            XCTAssertTrue(hasQuarantine(file), "the disk image's copy is left as it is: \(file)")
        }

        // Staged before (an earlier run, or the updater's download of that release): kept as it is.
        let inode = try FileManager.default.attributesOfItem(atPath: staged.path)[.systemFileNumber] as? Int
        XCTAssertEqual(try AppInstall.stage(app, version: releaseVersion(26), in: root, requirement: adHoc), staged)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: staged.path)[.systemFileNumber] as? Int, inode)
        // Unless it no longer verifies: copied again.
        try Data("edited".utf8).write(to: staged.appendingPathComponent("Contents/Resources/data.txt"))
        XCTAssertEqual(try AppInstall.stage(app, version: releaseVersion(26), in: root, requirement: adHoc), staged)
        XCTAssertEqual(try resource(staged), "resource of \(releaseVersion(26))")
        XCTAssertNoThrow(try CodeSignature.check(staged, requirement: adHoc))

        // A copy that fails its checks (edited after signing, another version than it says, another team's) leaves nothing.
        try FileManager.default.removeItem(at: folder)
        let tampered = try makeApp(directory.appendingPathComponent("Volumes/Tampered/Peekaboo.app"), version: releaseVersion(26))
        try Data("tampered".utf8).write(to: tampered.appendingPathComponent("Contents/Resources/data.txt"))
        let team = CodeSignature.updateRequirement(teamIdentifier: "ABCDE12345")!
        // One that needs a newer macOS would not start once installed, and the app it replaced would be gone.
        let later = try makeApp(directory.appendingPathComponent("Volumes/Later/Peekaboo.app"), version: releaseVersion(26),
                                minimumSystemVersion: "99.0")
        for (copy, version, requirement) in [(tampered, releaseVersion(26), adHoc), (app, releaseVersion(27), adHoc),
                                             (app, releaseVersion(26), team), (later, releaseVersion(26), adHoc)] {
            XCTAssertThrowsError(try AppInstall.stage(copy, version: version, in: root, requirement: requirement)) { error in
                XCTAssertTrue(AppInstall.failureReason(error).hasPrefix("The copy failed verification: "), "\(error)")
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [], "\(copy.path) \(version)")
        }
    }

    /// A disk image whose Peekaboo.app is a symbolic link: to a quarantined folder of the user's (its flags must stay),
    /// or to a signed Peekaboo someone else may change later (it must not become the staged copy, and so the app).
    func testNeverStagesASymbolicLink() throws {
        let root = directory.appendingPathComponent("cache/Updates", isDirectory: true)
        func link(_ name: String, to destination: URL) throws -> URL {
            let link = directory.appendingPathComponent("Volumes/\(name)/Peekaboo.app")
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
            return link
        }
        /// Every file and folder of `bundle`, with the quarantine flag.
        func flag(_ bundle: URL) throws -> [String] {
            let paths = try XCTUnwrap(FileManager.default.subpaths(atPath: bundle.path)).map { bundle.path + "/" + $0 } + [bundle.path]
            for path in paths { try setQuarantine(path, noFollow: true) }
            return paths
        }
        let downloads = try makeApp(directory.appendingPathComponent("Downloads/x"), version: releaseVersion(26), sign: false)
        let shared = try makeApp(directory.appendingPathComponent("Shared/Peekaboo.app"), version: releaseVersion(27))
        let flagged = try flag(downloads) + flag(shared)
        for (copy, version) in [(try link("Crafted", to: downloads), releaseVersion(26)),
                                (try link("Pointer", to: shared), releaseVersion(27))] {
            XCTAssertThrowsError(try AppInstall.stage(copy, version: version, in: root, requirement: adHoc)) { error in
                XCTAssertEqual(AppInstall.failureReason(error), "The copy failed verification: Peekaboo.app is a symbolic link")
            }
            XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [], [], copy.path)
        }
        for path in flagged { XCTAssertTrue(hasQuarantine(path), "what the link points to keeps its flag: \(path)") }

        // A link staged there before (by whatever) is neither used nor followed: a real copy replaces it.
        let app = try source(releaseVersion(27))
        let staged = root.appendingPathComponent("\(releaseVersion(27).token)/Peekaboo.app", isDirectory: true)
        try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: staged, withDestinationURL: shared)
        XCTAssertEqual(try AppInstall.stage(app, version: releaseVersion(27), in: root, requirement: adHoc), staged)
        XCTAssertFalse(AppInstall.isSymbolicLink(staged))
        XCTAssertNoThrow(try CodeSignature.check(staged, requirement: adHoc))
        XCTAssertNoThrow(try CodeSignature.check(shared, requirement: adHoc), "what it pointed to is left as it was")
        for path in flagged { XCTAssertTrue(hasQuarantine(path), path) }

        // Clearing the flag through a link is refused outright, and so is installing one (#81's copy from a disk
        // image).
        XCTAssertThrowsError(try AppInstall.removeQuarantine(in: try link("Again", to: downloads)))
        XCTAssertThrowsError(try install(try link("Install", to: shared), releaseVersion(27)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        for path in flagged { XCTAssertTrue(hasQuarantine(path), path) }
    }

    private func setQuarantine(_ path: String, noFollow: Bool = false) throws {
        let value = Array("0083;6745e3a1;Safari;".utf8)
        guard setxattr(path, Self.quarantine, value, value.count, 0, noFollow ? XATTR_NOFOLLOW : 0) == 0 else {
            throw XCTSkip("cannot set extended attributes here: \(String(cString: strerror(errno)))")
        }
    }

    private func hasQuarantine(_ path: String) -> Bool {
        getxattr(path, Self.quarantine, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// The real thing, but in the scratch folder: an app with the quarantine flag on a read-only (UDZO) disk image
    /// of the test's own, attached out of sight (`-nobrowse`) and detached when the test ends.
    func testInstallsFromAReadOnlyDiskImage() throws {
        let folder = directory.appendingPathComponent("image", isDirectory: true)
        let app = try makeApp(folder.appendingPathComponent("Peekaboo.app"), version: releaseVersion(26))
        try setQuarantine(app.path)
        try setQuarantine(app.appendingPathComponent("Contents/MacOS/Peekaboo").path)
        let image = directory.appendingPathComponent("Peekaboo-test.dmg")
        let mountPoint = directory.appendingPathComponent("mounted", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        guard hdiutil(["create", "-quiet", "-volname", "Peekaboo Test", "-srcfolder", folder.path, "-format", "UDZO", image.path]),
              hdiutil(["attach", "-quiet", "-readonly", "-nobrowse", "-noverify", "-noautoopen", "-mountpoint", mountPoint.path,
                       image.path])
        else { throw XCTSkip("cannot attach a disk image here") }
        addTeardownBlock { _ = hdiutil(["detach", "-force", "-quiet", mountPoint.path]) }
        let mounted = mountPoint.appendingPathComponent("Peekaboo.app", isDirectory: true)

        // The launch's check on the executable's path, as main.swift makes it (with the image under the scratch folder).
        let executable = mounted.appendingPathComponent("Contents/MacOS/Peekaboo").path
        XCTAssertTrue(AppInstall.isOnReadOnlyVolume(executable), "a disk image reads as read-only")
        XCTAssertTrue(AppInstall.isOnReadOnlyVolume(mounted.path))
        XCTAssertFalse(AppInstall.isOnReadOnlyVolume(app.path))
        XCTAssertTrue(hasQuarantine(executable))

        // The image's entry in the mount table, as `mountedVolumes` reads it: read-only, local, and this user's, who
        // attached it (`f_owner`; `st_uid` would show whoever looks). Attached with `-nobrowse`, it is not listed.
        var entry = statfs()
        XCTAssertEqual(statfs(mountPoint.path, &entry), 0)
        let listed = AppInstall.Volume(entry)
        XCTAssertEqual(listed.url.lastPathComponent, mountPoint.lastPathComponent)
        XCTAssertTrue(listed.isReadOnly)
        XCTAssertTrue(listed.isLocal)
        XCTAssertEqual(listed.owner, getuid(), "a disk image this user attached is this user's")
        XCTAssertFalse(AppInstall.mountedVolumes().contains { $0.url == listed.url }, "hidden")
        // Under the scratch folder's name: the kernel's is /private/var/….
        let volume = AppInstall.Volume(url: mountPoint, isReadOnly: listed.isReadOnly, isLocal: listed.isLocal, owner: listed.owner)
        // DiskArbitration tells a disk image from a drive: the startup disk is none.
        XCTAssertTrue(AppInstall.isDiskImage(mountPoint))
        XCTAssertFalse(AppInstall.isDiskImage(URL(fileURLWithPath: "/")))
        XCTAssertFalse(AppInstall.isDiskImage(directory), "a folder of the startup disk")
        XCTAssertEqual(AppInstall.diskImages(in: [volume], under: directory.path + "/"), [mountPoint],
                       "a Peekaboo disk image, as the system describes it")
        XCTAssertEqual(AppInstall.diskImages(in: [volume], under: directory.path + "/", user: Self.anotherUser), [],
                       "not another user's to eject")
        XCTAssertEqual(AppInstall.diskImages(in: [volume], under: directory.path + "/",
                                             keeping: [mountPoint.appendingPathComponent("Peekaboo.app/Contents/Info.plist")]), [],
                       "not while a file on it is shown")

        XCTAssertEqual(try install(mounted, releaseVersion(26)), .installed)
        XCTAssertEqual(AppInstall.peekabooVersion(target), releaseVersion(26))
        XCTAssertFalse(hasQuarantine(target.path))
        XCTAssertFalse(hasQuarantine(target.appendingPathComponent("Contents/MacOS/Peekaboo").path))
        XCTAssertNoThrow(try CodeSignature.check(target, requirement: adHoc))
    }

    // MARK: Eject

    func testOnlyReadOnlyPeekabooImagesAreEjected() throws {
        // Every volume here is this user's (another user's: `testOnlyTheImagesThisUserMountedAreEjected`).
        let root = directory.appendingPathComponent("Volumes", isDirectory: true)
        func volume(_ name: String, app: String? = "com.thilllon.Peekaboo", readOnly: Bool = true, local: Bool = true,
                    at folder: URL? = nil) throws -> AppInstall.Volume {
            let url = (folder ?? root).appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            if let app { try makeApp(url.appendingPathComponent("Peekaboo.app"), version: releaseVersion(26), identifier: app, sign: false) }
            return AppInstall.Volume(url: url, isReadOnly: readOnly, isLocal: local, owner: getuid())
        }
        let current = try volume("Peekaboo 20261126-85dff6")
        let older = try volume("Peekaboo 20261126-69a847")
        let first = try volume("Peekaboo", app: nil)  // 0.1.0's image was named "Peekaboo"
        try makeApp(first.url.appendingPathComponent("Peekaboo.app"), version: releaseVersion(1), shortVersion: "0.1.0", sign: false)
        let drive = try volume("USB")  // read-only too (NTFS, a locked card), with a Peekaboo.app on it, but no disk image
        let photos = try volume("Photos 2026")  // a read-only image of photos that ships a Peekaboo.app
        let volumes = [
            current, older, first, drive, photos,
            try volume("SSD", readOnly: false),                       // a writable drive the user keeps the app on
            try volume("Peekaboo Share", local: false),               // a network share
            try volume("Other", app: "com.example.Peekaboo"),         // another app of that name
            try volume("Photos", app: nil),                           // a read-only image without Peekaboo
            try volume("Elsewhere", at: directory.appendingPathComponent("mnt", isDirectory: true)),  // not under the root
        ]
        var asked: [String] = []
        let isDiskImage = { (url: URL) -> Bool in
            asked.append(url.lastPathComponent)
            return url != drive.url
        }
        let shown = [photos.url.appendingPathComponent("IMG_0001.HEIC"), URL(fileURLWithPath: "/home/someone/b.jpg")]
        XCTAssertEqual(AppInstall.diskImages(in: volumes, under: root.path + "/", keeping: shown, isDiskImage: isDiskImage),
                       [current.url, older.url, first.url])
        // DiskArbitration first, before anything on the volume is read (those without a Peekaboo are asked about too):
        // the first read of a card or a drive (`drive`) may have macOS ask the user for the Removable Volumes
        // permission.
        XCTAssertEqual(asked, [current, older, first, drive].map(\.url.lastPathComponent) + ["Other", "Photos"],
                       "every read-only local volume is asked about before it is read")
        XCTAssertEqual(AppInstall.diskImages(in: volumes, under: root.path + "/", isDiskImage: isDiskImage),
                       [current.url, older.url, first.url, photos.url], "once its photos are not shown")
        // By default only volumes under /Volumes count: never the system volume, nor one mounted elsewhere.
        asked = []
        XCTAssertEqual(AppInstall.diskImages(in: volumes, isDiskImage: isDiskImage), [])
        let startup = AppInstall.Volume(url: URL(fileURLWithPath: "/"), isReadOnly: true, isLocal: true, owner: 0)
        XCTAssertEqual(AppInstall.diskImages(in: [startup], user: 0, isDiskImage: isDiskImage), [])
        XCTAssertEqual(asked, [])
    }

    func testOnlyTheImagesThisUserMountedAreEjected() throws {
        // Two accounts logged in at once (#90): the copy one of them installed ejected the image the other had opened,
        // and tried to unmount the one the other's Peekaboo ran from. Peekaboo images all, read-only, local, under the
        // root; only who mounted them differs.
        let root = directory.appendingPathComponent("Volumes", isDirectory: true)
        func image(_ name: String, owner: uid_t) throws -> AppInstall.Volume {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try makeApp(url.appendingPathComponent("Peekaboo.app"), version: releaseVersion(26), sign: false)
            return AppInstall.Volume(url: url, isReadOnly: true, isLocal: true, owner: owner)
        }
        let me = getuid(), other = Self.anotherUser
        let theirs = try image("Peekaboo 20261126-6c7b06", owner: other)
        let mine = try image("Peekaboo 20261126-517cb0", owner: me)
        let running = try image("Peekaboo 20261126-85dff6", owner: other)  // the other account's Peekaboo runs from it
        let byRoot = try image("Peekaboo 20261126-69a847", owner: 0)  // attached by root (`sudo hdiutil attach`)
        let volumes = [theirs, mine, running, byRoot]
        var asked: [String] = []
        let isDiskImage = { (url: URL) -> Bool in
            asked.append(url.lastPathComponent)
            return true
        }
        XCTAssertEqual(AppInstall.diskImages(in: volumes, under: root.path + "/", isDiskImage: isDiskImage), [mine.url],
                       "this process's user's only")
        XCTAssertEqual(asked, [mine.url.lastPathComponent], "another user's volume is not even asked about")
        // The user is the one compared: the other account's copy would eject its own images, and only those.
        XCTAssertEqual(AppInstall.diskImages(in: volumes, under: root.path + "/", user: other, isDiskImage: { _ in true }),
                       [theirs.url, running.url])
        XCTAssertEqual(AppInstall.diskImages(in: volumes, under: root.path + "/", user: 0, isDiskImage: { _ in true }), [byRoot.url])
        XCTAssertEqual(AppInstall.diskImages(in: volumes, under: root.path + "/", keeping: [mine.url.appendingPathComponent("IMG_0001.HEIC")],
                                             user: me, isDiskImage: { _ in true }),
                       [], "this user's image holding a file shown stays as before")
    }

    func testAVolumeIsWhatItsMountTableEntrySays() {
        // Entries made by hand: nothing is mounted. The ejector and the disk-image scan rely on `isReadOnly` and `isLocal`
        // to leave writable drives and network shares alone, and the CI test's real image is read-only and local, so only
        // entries like these tell whether each is read from its own bit, whatever else is set.
        func entry(_ path: String, flags: Int32, owner: uid_t) -> statfs {
            var entry = statfs()
            entry.f_flags = UInt32(bitPattern: flags)
            entry.f_owner = owner
            withUnsafeMutableBytes(of: &entry.f_mntonname) { $0.copyBytes(from: Array(path.utf8)) }
            withUnsafeMutableBytes(of: &entry.f_mntfromname) { $0.copyBytes(from: Array("/dev/disk9s1".utf8)) }
            return entry
        }
        let url = URL(fileURLWithPath: "/Volumes/Peekaboo 20261126-517cb0", isDirectory: true)
        let me = getuid(), other = Self.anotherUser
        func volume(readOnly: Bool, local: Bool, owner: uid_t) -> AppInstall.Volume {
            AppInstall.Volume(url: url, isReadOnly: readOnly, isLocal: local, owner: owner)
        }
        XCTAssertEqual(AppInstall.Volume(entry(url.path, flags: MNT_RDONLY | MNT_LOCAL, owner: me)),
                       volume(readOnly: true, local: true, owner: me), "a disk image")
        XCTAssertEqual(AppInstall.Volume(entry(url.path, flags: MNT_LOCAL, owner: other)),
                       volume(readOnly: false, local: true, owner: other), "a writable drive")
        XCTAssertEqual(AppInstall.Volume(entry(url.path, flags: MNT_RDONLY, owner: 0)),
                       volume(readOnly: true, local: false, owner: 0), "a network share")
        // A disk image has more flags (`MNT_NOSUID`, `MNT_IGNORE_OWNERSHIP`, `MNT_QUARANTINE`, …): none of them counts.
        let rest = ~(MNT_RDONLY | MNT_LOCAL)
        XCTAssertEqual(AppInstall.Volume(entry(url.path, flags: rest, owner: me)),
                       volume(readOnly: false, local: false, owner: me), "every other flag")
        XCTAssertEqual(AppInstall.Volume(entry(url.path, flags: rest | MNT_RDONLY | MNT_LOCAL, owner: me)),
                       volume(readOnly: true, local: true, owner: me), "every flag")
        // The mount point, not the device, in UTF-8 as the kernel keeps it.
        let named = URL(fileURLWithPath: "/Volumes/Photos d’été – 2026", isDirectory: true)
        XCTAssertEqual(AppInstall.Volume(entry(named.path, flags: MNT_RDONLY | MNT_LOCAL, owner: me)).url, named)

        // A real entry: the scratch folder's volume is writable and local.
        var scratch = statfs()
        XCTAssertEqual(statfs(directory.path, &scratch), 0)
        XCTAssertFalse(AppInstall.Volume(scratch).isReadOnly)
        XCTAssertTrue(AppInstall.Volume(scratch).isLocal)
    }

    // MARK: Processes

    func testFindsTheProcessesThatRunABundle() throws {
        // The processes as the system lists them, faked: no test runs a copy of a system binary (on macOS 26 XProtect
        // flags it, and Gatekeeper puts dialogs on screen: issue #87). The kernel names the scratch folder /private/var/….
        let bundle = directory.appendingPathComponent("Running/Peekaboo.app", isDirectory: true)
        let namesake = directory.appendingPathComponent("Running/Peekaboo", isDirectory: true)
        for folder in [bundle.appendingPathComponent("Contents/MacOS"), namesake] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let real = try XCTUnwrap(realpath(directory.path, nil))
        let kernel = String(cString: real)
        free(real)
        let executable = kernel + "/Running/Peekaboo.app/Contents/MacOS/Peekaboo"
        // The app and the update installer it starts, this process, a namesake bundle next to it, and another program.
        let running: [(pid: pid_t, executable: String)] = [
            (4242, executable), (4243, executable), (getpid(), executable),
            (4244, kernel + "/Running/Peekaboo.app 2/Contents/MacOS/Peekaboo"), (4245, "/bin/sleep"),
        ]
        var listed = 0
        func processes(_ folder: URL) -> [pid_t] {
            AppInstall.processes(runningFrom: folder) {
                listed += 1
                return running
            }
        }
        XCTAssertEqual(processes(bundle), [4242, 4243], "the app and its update installer, never this process")
        XCTAssertEqual(processes(bundle.appendingPathComponent("Contents", isDirectory: true)), [4242, 4243], "anywhere inside")
        XCTAssertEqual(processes(namesake), [], "a folder next to it whose name starts the same")
        XCTAssertEqual(listed, 3)
        XCTAssertEqual(processes(directory.appendingPathComponent("Missing.app", isDirectory: true)), [])
        XCTAssertEqual(listed, 3, "the processes are not listed for a folder that does not exist")
    }

    func testFindsTheProcessesThatRunFromAFolder() throws {
        // sleep(1) at its own path, never a copy (issue #87), running for the test. Other processes may run from /bin too.
        let bin = URL(fileURLWithPath: "/bin", isDirectory: true)
        let process = Process()
        process.executableURL = bin.appendingPathComponent("sleep")
        process.arguments = ["30"]
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let pid = process.processIdentifier
        XCTAssertTrue(AppInstall.runningExecutables().contains { $0.pid == pid && $0.executable == "/bin/sleep" },
                      "the system lists it with its executable's path")
        XCTAssertTrue(AppInstall.processes(runningFrom: bin).contains(pid))
        // Neither a path that starts the same without the separator (sleep itself), nor a missing folder.
        for path in ["/bin/sleep", directory.appendingPathComponent("Missing.app").path] {
            XCTAssertFalse(AppInstall.processes(runningFrom: URL(fileURLWithPath: path)).contains(pid), path)
        }
        process.terminate()
        process.waitUntilExit()
        XCTAssertFalse(AppInstall.processes(runningFrom: bin).contains(pid), "it has exited")
        // The system names an executable by its real path, as `processes(runningFrom:)` resolves the folder: `swift test`
        // starts the runner through a symlink (`Bundle.main` names Developer/usr/bin/xctest, a link to …/Agents/xctest).
        let me = try XCTUnwrap(AppInstall.runningExecutables().first { $0.pid == getpid() })
        let started = try XCTUnwrap(Bundle.main.executablePath)
        let real = try XCTUnwrap(realpath(started, nil))
        defer { free(real) }
        XCTAssertEqual(me.executable, String(cString: real), "started as \(started)")
        // Never this process, not even from the folder of its own executable.
        let runner = URL(fileURLWithPath: me.executable).deletingLastPathComponent()
        XCTAssertFalse(AppInstall.processes(runningFrom: runner).contains(getpid()), runner.path)
    }

    func testMountedVolumesListTheStartupDisk() {
        // The listing reads the mount table only (no volume's files): the startup disk, mounted by the system (owner 0,
        // whoever runs the test), and no hidden volume (devfs is mounted `nobrowse` at /dev).
        let volumes = AppInstall.mountedVolumes()
        let startup = volumes.first { $0.url.path == "/" }
        XCTAssertEqual(startup?.isLocal, true)
        XCTAssertEqual(startup?.owner, 0, "the system mounted it")
        XCTAssertFalse(volumes.contains { $0.url.path == "/dev" }, "hidden")
    }
}
