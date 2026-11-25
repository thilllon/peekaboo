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
            AppInstall.needsInstalling(URL(fileURLWithPath: path)) { url in
                looked.append(url.path)
                return readOnly
            }
        }
        // Normal launches: the string check says no, and no volume is looked at.
        let home = NSHomeDirectory()
        for path in ["/Applications/Peekaboo.app", home + "/Applications/Peekaboo.app", home + "/Downloads/Peekaboo.app",
                     "/VolumesX/Peekaboo.app", "/private/Volumes/x/Peekaboo.app", "/Applications/AppTranslocation.app/Peekaboo.app"] {
            XCTAssertFalse(AppInstall.mayNeedInstalling(path), path)
            XCTAssertFalse(needs(path, readOnly: true), path)
        }
        XCTAssertEqual(looked, [], "a normal launch pays the string check alone")
        // The launch checks the executable's path (argv[0]).
        func executable(_ path: String) -> Bool { path.withCString { AppInstall.mayNeedInstalling(executable: $0) } }
        XCTAssertFalse(executable("/Applications/Peekaboo.app/Contents/MacOS/Peekaboo"))
        XCTAssertTrue(executable("/Volumes/Peekaboo 20261126-69a847/Peekaboo.app/Contents/MacOS/Peekaboo"))
        XCTAssertTrue(executable("/private/var/folders/xy/T/AppTranslocation/0F2A/d/Peekaboo.app/Contents/MacOS/Peekaboo"))
        XCTAssertFalse(executable("Peekaboo"), "a relative path from a terminal")

        // Under /Volumes: a read-only volume (a disk image) installs, a writable one (an external drive) does not.
        let image = "/Volumes/Peekaboo 20261126-69a847/Peekaboo.app"
        let drive = "/Volumes/SSD/Apps/Peekaboo.app"
        XCTAssertTrue(AppInstall.mayNeedInstalling(image))
        XCTAssertTrue(AppInstall.mayNeedInstalling(drive))
        XCTAssertTrue(needs(image, readOnly: true))
        XCTAssertFalse(needs(drive, readOnly: false))
        XCTAssertEqual(looked, [image, drive])

        // App Translocation's read-only copy installs, wherever it is mounted, without a volume lookup.
        looked = []
        let translocated = "/private/var/folders/xy/abc123/T/AppTranslocation/0F2A5C1E-9B7D-4E7A/d/Peekaboo.app"
        XCTAssertTrue(AppInstall.mayNeedInstalling(translocated))
        XCTAssertTrue(needs(translocated, readOnly: false))
        XCTAssertEqual(looked, [])
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

    func testTargetIsApplicationsWhenWritableElseTheHomeFolders() {
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let home = URL(fileURLWithPath: "/home/someone", isDirectory: true)
        var asked: [String] = []
        XCTAssertEqual(AppInstall.target(applications: applications, home: home) { asked.append($0.path); return true }.path,
                       "/Applications/Peekaboo.app")
        XCTAssertEqual(AppInstall.target(applications: applications, home: home) { asked.append($0.path); return false }.path,
                       "/home/someone/Applications/Peekaboo.app")
        XCTAssertEqual(asked, ["/Applications", "/Applications"], "only /Applications is checked")
        // The real check (`access`): a folder of the user's is writable, one made read-only is not.
        let writable = directory.appendingPathComponent("Applications", isDirectory: true)
        try? FileManager.default.createDirectory(at: writable, withIntermediateDirectories: true)
        XCTAssertEqual(AppInstall.target(applications: writable, home: home).path, writable.path + "/Peekaboo.app")
        try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: writable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: writable.path) }
        if access(writable.path, W_OK) != 0 {
            XCTAssertEqual(AppInstall.target(applications: writable, home: home).path, "/home/someone/Applications/Peekaboo.app")
        }
    }

    // MARK: Install

    /// The copy that runs from the "disk image" (a folder here) and the target in a scratch "Applications" folder.
    private func source(_ version: AppVersion) throws -> URL {
        try makeApp(directory.appendingPathComponent("Volumes/Peekaboo \(version)/Peekaboo.app"), version: version)
    }

    private var target: URL { directory.appendingPathComponent("Applications/Peekaboo.app", isDirectory: true) }

    private func install(_ app: URL, _ version: AppVersion, running: Bool = false) throws -> AppInstall.Outcome {
        try AppInstall.install(app, version: version, at: target, requirement: adHoc) { url in
            XCTAssertEqual(url, self.target)
            return running
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
        XCTAssertEqual(try install(try source(releaseVersion(26)), releaseVersion(26)), .newerInstalled(build: 27))
        XCTAssertEqual(AppInstall.peekabooVersion(target), releaseVersion(27))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: target.path)[.systemFileNumber] as? Int, before,
                       "the very same bundle")
    }

    func testLeavesARunningTargetAlone() throws {
        try makeApp(target, version: releaseVersion(25))
        XCTAssertEqual(try install(try source(releaseVersion(26)), releaseVersion(26), running: true), .running)
        XCTAssertEqual(AppInstall.peekabooVersion(target), releaseVersion(25), "nothing is swapped under a running app")
    }

    func testNeverTouchesAnotherAppOfThatName() throws {
        try makeApp(target, version: releaseVersion(25), identifier: "com.example.Peekaboo")
        let app = try source(releaseVersion(26))
        XCTAssertThrowsError(try install(app, releaseVersion(26))) { error in
            XCTAssertEqual(AppInstall.failureReason(error), "\(self.target.path) is another app")
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
            XCTAssertTrue(AppInstall.failureReason(error).hasPrefix("the copy failed verification: "), "\(error)")
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

        XCTAssertTrue(AppInstall.isOnReadOnlyVolume(mounted), "a disk image reads as read-only")
        XCTAssertFalse(AppInstall.isOnReadOnlyVolume(app))
        XCTAssertTrue(hasQuarantine(mounted.appendingPathComponent("Contents/MacOS/Peekaboo").path))

        let values = try mountPoint.resourceValues(forKeys: [.volumeIsReadOnlyKey, .volumeIsLocalKey])
        let volume = AppInstall.Volume(url: mountPoint, isReadOnly: values.volumeIsReadOnly == true,
                                       isLocal: values.volumeIsLocal == true)
        XCTAssertEqual(AppInstall.diskImages(in: [volume], under: directory.path + "/"), [mountPoint],
                       "a Peekaboo disk image, as the system describes it")

        XCTAssertEqual(try install(mounted, releaseVersion(26)), .installed)
        XCTAssertEqual(AppInstall.peekabooVersion(target), releaseVersion(26))
        XCTAssertFalse(hasQuarantine(target.path))
        XCTAssertFalse(hasQuarantine(target.appendingPathComponent("Contents/MacOS/Peekaboo").path))
        XCTAssertNoThrow(try CodeSignature.check(target, requirement: adHoc))
    }

    // MARK: Eject

    func testOnlyReadOnlyPeekabooImagesAreEjected() throws {
        let root = directory.appendingPathComponent("Volumes", isDirectory: true)
        func volume(_ name: String, app: String? = "com.thilllon.Peekaboo", readOnly: Bool = true, local: Bool = true,
                    at folder: URL? = nil) throws -> AppInstall.Volume {
            let url = (folder ?? root).appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            if let app { try makeApp(url.appendingPathComponent("Peekaboo.app"), version: releaseVersion(26), identifier: app, sign: false) }
            return AppInstall.Volume(url: url, isReadOnly: readOnly, isLocal: local)
        }
        let current = try volume("Peekaboo 20261126-85dff6")
        let older = try volume("Peekaboo 20261126-69a847")
        let first = try volume("Peekaboo", app: nil)  // 0.1.0's image was named "Peekaboo"
        try makeApp(first.url.appendingPathComponent("Peekaboo.app"), version: releaseVersion(1), shortVersion: "0.1.0", sign: false)
        let volumes = [
            current, older, first,
            try volume("SSD", readOnly: false),                       // a writable drive the user keeps the app on
            try volume("Peekaboo Share", local: false),               // a network share
            try volume("Other", app: "com.example.Peekaboo"),         // another app of that name
            try volume("Photos", app: nil),                           // a read-only image without Peekaboo
            try volume("Elsewhere", at: directory.appendingPathComponent("mnt", isDirectory: true)),  // not under the root
        ]
        XCTAssertEqual(AppInstall.diskImages(in: volumes, under: root.path + "/"), [current.url, older.url, first.url])
        // By default only volumes under /Volumes count: never the system volume, nor one mounted elsewhere.
        XCTAssertEqual(AppInstall.diskImages(in: volumes), [])
        XCTAssertEqual(AppInstall.diskImages(in: [AppInstall.Volume(url: URL(fileURLWithPath: "/"), isReadOnly: true, isLocal: true)]), [])
    }

    func testMountedVolumesListTheStartupDisk() {
        // The listing reads the mount table only (no volume's files).
        XCTAssertTrue(AppInstall.mountedVolumes().contains { $0.url.path == "/" && $0.isLocal })
    }
}
