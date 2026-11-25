import Security
import XCTest
@testable import PeekabooCore

/// Release `n` of the updater tests: `202611nn-0000nn` with build number `n` (24 < 25 < 26 < 27).
func releaseVersion(_ n: Int) -> AppVersion { AppVersion(name: String(format: "202611%02d-0000%02d", n, n), build: n)! }

/// Versions, `latest.json`, the check schedule, signature requirements and the bundle swap of the updater.
final class UpdateTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("peekaboo-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Versions

    func testVersionsAreNamedByDayAndHashAndOrderedByBuild() throws {
        let a = try XCTUnwrap(AppVersion(name: "20261125-ab2342", build: 35))
        XCTAssertEqual(a.name, "20261125-ab2342")
        XCTAssertEqual(a.description, "20261125-ab2342")
        XCTAssertEqual(a.build, 35)
        XCTAssertEqual(a.token, "20261125-ab2342+35")
        XCTAssertEqual(AppVersion(a.token), a)
        // The build number orders releases, whatever the day or the hash says.
        let b = try XCTUnwrap(AppVersion(name: "20261125-000001", build: 36))
        XCTAssertLessThan(a, b)
        XCTAssertGreaterThan(try XCTUnwrap(AppVersion(name: "20261124-ffffff", build: 37)), b)
        XCTAssertNotEqual(a, AppVersion(name: "20261125-ab2342", build: 36))
        XCTAssertNotEqual(a, AppVersion(name: "20261125-ab2343", build: 35))
        XCTAssertEqual(Set([a, try XCTUnwrap(AppVersion("20261125-ab2342+35"))]).count, 1)
        // From a bundle's CFBundleShortVersionString and CFBundleVersion.
        XCTAssertEqual(AppVersion(shortVersion: "20261125-ab2342", bundleVersion: "35"), a)
        XCTAssertNil(AppVersion(shortVersion: "20261125-ab2342", bundleVersion: "35.1"))
        XCTAssertNil(AppVersion(shortVersion: "20261125-ab2342", bundleVersion: nil))
        XCTAssertNil(AppVersion(shortVersion: 20261125, bundleVersion: "35"))
        XCTAssertNil(AppVersion(shortVersion: "0.1.0", bundleVersion: "26"), "0.1.0 predates the updater")
    }

    func testMalformedVersionsAreRejected() {
        for name in ["", "20261125", "20261125.1", "0.1.0", "v20261125-ab2342", "20261125-AB2342", "20261125-ab234",
                     "20261125-ab23420", "20261125_ab2342", "2026112-5ab2342", "20261340-ab2342", "20260230-ab2342",
                     "20230229-ab2342", "19991231-ab2342", "20261125-ab234g", " 20261125-ab2342", "\u{FF12}0261125-ab2342"] {
            XCTAssertNil(AppVersion(name: name, build: 35), name)
        }
        XCTAssertNotNil(AppVersion(name: "20240229-ab2342", build: 35))  // leap day
        XCTAssertNil(AppVersion(name: "20261125-ab2342", build: 0))
        XCTAssertNil(AppVersion(name: "20261125-ab2342", build: -1))
        for token in ["20261125-ab2342", "20261125-ab2342+", "20261125-ab2342+0", "20261125-ab2342+-3",
                      "20261125-ab2342+3+4", "20261125-ab2342+x", "+35", "20261125-ab2342+1234567890",
                      "20261125-ab2342 +35", "20261125"] {
            XCTAssertNil(AppVersion(token), token)
        }
    }

    // MARK: Manifest

    private func manifest(_ fields: [String: Any]) -> Data {
        var json: [String: Any] = [
            "version": "20261126-000026", "build": 26, "minimumSystemVersion": "26.0",
            "url": "https://github.com/thilllon/peekaboo/releases/download/v20261126-000026/Peekaboo-20261126-000026.zip",
            "sha256": String(repeating: "aB", count: 32), "size": 2_412_345,
            "dmg": "https://github.com/thilllon/peekaboo/releases/download/v20261126-000026/Peekaboo-20261126-000026.dmg",
            "notes": "https://github.com/thilllon/peekaboo/releases/tag/v20261126-000026", "published": "2026-11-26T09:30:00Z",
        ]
        for (key, value) in fields { json[key] = value is NSNull ? nil : value }
        return try! JSONSerialization.data(withJSONObject: json)
    }

    func testManifestParses() throws {
        let m = try UpdateManifest(data: manifest([:]))
        XCTAssertEqual(m.version, releaseVersion(26))
        XCTAssertEqual(m.sha256, String(repeating: "ab", count: 32))
        XCTAssertEqual(m.size, 2_412_345)
        XCTAssertEqual(m.url.lastPathComponent, "Peekaboo-20261126-000026.zip")
        XCTAssertEqual(m.downloadPage.absoluteString, "https://github.com/thilllon/peekaboo/releases/tag/v20261126-000026")
        XCTAssertEqual(m.published, "2026-11-26T09:30:00Z")
        let bare = try UpdateManifest(data: manifest(["dmg": NSNull(), "notes": NSNull(), "published": NSNull()]))
        XCTAssertEqual(bare.downloadPage, bare.url)
        XCTAssertNil(bare.dmg)
        // Unknown fields from a newer release task are ignored.
        XCTAssertNoThrow(try UpdateManifest(data: manifest(["channel": "beta"])))
    }

    func testManifestRejectsBadFields() {
        let bad: [[String: Any]] = [
            ["version": "next"], ["version": NSNull()], ["version": "20261126"], ["version": "20261126.1"],
            ["build": 0], ["build": -26], ["build": "26"], ["build": NSNull()], ["sha256": "abc"], ["sha256": String(repeating: "g", count: 64)],
            ["size": 0], ["size": UpdateManifest.maximumSize + 1], ["size": "12"], ["url": "http://example.com/a.zip"],
            ["url": "file:///tmp/a.zip"], ["url": NSNull()], ["notes": "javascript:alert(1)"], ["minimumSystemVersion": "tahoe"],
            ["minimumSystemVersion": "26.0.0.1"],
        ]
        for fields in bad {
            XCTAssertThrowsError(try UpdateManifest(data: manifest(fields)), "\(fields)") { error in
                guard case UpdateError.invalidManifest = error else { return XCTFail("\(fields): \(error)") }
            }
        }
        XCTAssertThrowsError(try UpdateManifest(data: Data("<html>404</html>".utf8)))
        // A local test server (PEEKABOO_UPDATE_URL) may serve over http or from files.
        XCTAssertNoThrow(try UpdateManifest(data: manifest(["url": "http://127.0.0.1:8000/a.zip"]), allowInsecureURLs: true))
        XCTAssertNoThrow(try UpdateManifest(data: manifest(["url": "file:///tmp/a.zip"]), allowInsecureURLs: true))
    }

    func testMinimumSystemVersion() throws {
        func runs(_ minimum: String, _ major: Int, _ minor: Int, _ patch: Int = 0) throws -> Bool {
            try UpdateManifest(data: manifest(["minimumSystemVersion": minimum]))
                .runs(on: OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch))
        }
        XCTAssertTrue(try runs("26.0", 26, 6, 2))
        XCTAssertTrue(try runs("26", 26, 0))
        XCTAssertTrue(try runs("14.0", 26, 0))
        XCTAssertFalse(try runs("26.1", 26, 0, 9))
        XCTAssertFalse(try runs("27.0", 26, 6))
        XCTAssertTrue(try runs("26.0.1", 26, 0, 1))
    }

    // MARK: Schedule

    func testChecksAreThrottledButManualOnesAreNot() {
        let policy = UpdatePolicy()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertGreaterThanOrEqual(policy.firstCheckDelay, 10)
        XCTAssertEqual(policy.interval, 6 * 3600)
        for trigger in [UpdateTrigger.launch, .timer, .connectivity] {
            XCTAssertTrue(policy.shouldCheck(trigger, automatic: true, lastCheck: nil, now: now), "\(trigger)")
            XCTAssertFalse(policy.shouldCheck(trigger, automatic: true, lastCheck: now - 59 * 60, now: now), "\(trigger)")
            XCTAssertTrue(policy.shouldCheck(trigger, automatic: true, lastCheck: now - 3600, now: now), "\(trigger)")
            // The clock went backwards: the "last check" is in the future.
            XCTAssertTrue(policy.shouldCheck(trigger, automatic: true, lastCheck: now + 600, now: now), "\(trigger)")
            XCTAssertFalse(policy.shouldCheck(trigger, automatic: false, lastCheck: nil, now: now), "\(trigger)")
        }
        XCTAssertTrue(policy.shouldCheck(.manual, automatic: false, lastCheck: now - 1, now: now))
        XCTAssertTrue(policy.shouldCheck(.manual, automatic: true, lastCheck: now, now: now))
    }

    func testConnectivityEdgeFiresWhenTheNetworkComesBack() {
        var edge = ConnectivityEdge()
        XCTAssertFalse(edge.update(online: true), "the first report is the baseline")
        XCTAssertFalse(edge.update(online: true))
        XCTAssertFalse(edge.update(online: false))
        XCTAssertTrue(edge.update(online: true))
        XCTAssertFalse(edge.update(online: true))
        var offlineAtStart = ConnectivityEdge()
        XCTAssertFalse(offlineAtStart.update(online: false))
        XCTAssertTrue(offlineAtStart.update(online: true))
    }

    // MARK: Signatures

    func testRequirementStrings() throws {
        XCTAssertEqual(CodeSignature.updateRequirement(teamIdentifier: nil), "identifier \"com.thilllon.Peekaboo\"")
        let developerID = try XCTUnwrap(CodeSignature.updateRequirement(teamIdentifier: "ABCDE12345"))
        XCTAssertEqual(developerID, "anchor apple generic and identifier \"com.thilllon.Peekaboo\""
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate leaf[subject.OU] = \"ABCDE12345\"")
        for text in [developerID, CodeSignature.updateRequirement(teamIdentifier: nil)!] {
            var requirement: SecRequirement?
            XCTAssertEqual(SecRequirementCreateWithString(text as CFString, [], &requirement), errSecSuccess, text)
        }
        for team in ["", "abcde12345", "ABCDE1234", "ABCDE123456", "ABCDE1234\"", "ABCDE 1234", "ÄBCDE12345"] {
            XCTAssertNil(CodeSignature.updateRequirement(teamIdentifier: team), team)
        }
    }

    /// A minimal app bundle: Info.plist, an executable (a copy of `/usr/bin/true`) and a resource, ad-hoc signed
    /// with `identifier`.
    @discardableResult
    private func makeApp(_ url: URL, version: AppVersion, identifier: String = "com.thilllon.Peekaboo",
                         sign: Bool = true) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version.name,
                                   "CFBundleVersion": String(version.build), "CFBundleExecutable": "Peekaboo",
                                   "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: url.appendingPathComponent("Contents/MacOS/Peekaboo"))
        try Data("resource of \(version)".utf8).write(to: url.appendingPathComponent("Contents/Resources/data.txt"))
        if sign {
            let codesign = Process()
            codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            codesign.arguments = ["--force", "--sign", "-", "--identifier", identifier, url.path]
            codesign.standardOutput = FileHandle.nullDevice
            codesign.standardError = FileHandle.nullDevice
            do { try codesign.run() } catch { throw XCTSkip("codesign is not available") }
            codesign.waitUntilExit()
            guard codesign.terminationStatus == 0 else { throw XCTSkip("codesign failed (\(codesign.terminationStatus))") }
        }
        return url
    }

    private func version(of app: URL) throws -> AppVersion? {
        try UpdateInstaller.bundleInfo(app).version
    }

    private let adHoc = CodeSignature.updateRequirement(teamIdentifier: nil)!

    func testSignatureCheckAcceptsTheAppAndRejectsTampering() throws {
        let app = try makeApp(directory.appendingPathComponent("Peekaboo.app"), version: releaseVersion(26))
        XCTAssertNil(CodeSignature.teamIdentifier(of: app), "ad-hoc signatures carry no team")
        XCTAssertNoThrow(try UpdateInstaller.verify(app, version: releaseVersion(26), requirement: adHoc))
        // Wrong version, wrong identifier, Developer ID required, an edited resource, no signature.
        XCTAssertThrowsError(try UpdateInstaller.verify(app, version: releaseVersion(27), requirement: adHoc))
        XCTAssertThrowsError(try UpdateInstaller.verify(
            app, version: releaseVersion(26), requirement: CodeSignature.updateRequirement(teamIdentifier: "ABCDE12345")!))
        let other = try makeApp(directory.appendingPathComponent("Other.app"), version: releaseVersion(26), identifier: "com.example.Other")
        XCTAssertThrowsError(try UpdateInstaller.verify(other, version: releaseVersion(26), requirement: adHoc))
        try Data("tampered".utf8).write(to: app.appendingPathComponent("Contents/Resources/data.txt"))
        XCTAssertThrowsError(try UpdateInstaller.verify(app, version: releaseVersion(26), requirement: adHoc)) { error in
            guard case UpdateError.verification = error else { return XCTFail("\(error)") }
        }
        let unsigned = try makeApp(directory.appendingPathComponent("Unsigned.app"), version: releaseVersion(26), sign: false)
        XCTAssertThrowsError(try UpdateInstaller.verify(unsigned, version: releaseVersion(26), requirement: adHoc))
    }

    // MARK: Install

    func testInstallSwapsTheBundleAndDropsTheOldOne() throws {
        let target = try makeApp(directory.appendingPathComponent("Applications/Peekaboo.app"), version: releaseVersion(25))
        let staged = try makeApp(directory.appendingPathComponent("Updates/\(releaseVersion(26).token)/Peekaboo.app"), version: releaseVersion(26))
        try UpdateInstaller.install(staged, over: target, version: releaseVersion(26), requirement: adHoc)
        XCTAssertEqual(try version(of: target), releaseVersion(26))
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("Contents/Resources/data.txt"), encoding: .utf8),
                       "resource of \(releaseVersion(26))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "the old bundle (the backup) is deleted")
        XCTAssertNoThrow(try CodeSignature.check(target, requirement: adHoc))
    }

    func testInstallLeavesTheAppAloneWhenTheUpdateFailsItsChecks() throws {
        let target = try makeApp(directory.appendingPathComponent("Applications/Peekaboo.app"), version: releaseVersion(25))
        let staged = try makeApp(directory.appendingPathComponent("Updates/\(releaseVersion(26).token)/Peekaboo.app"), version: releaseVersion(26))
        // Not the expected version (a replayed or mixed-up download).
        XCTAssertThrowsError(try UpdateInstaller.install(staged, over: target, version: releaseVersion(27), requirement: adHoc))
        XCTAssertEqual(try version(of: target), releaseVersion(25))
        XCTAssertEqual(try version(of: staged), releaseVersion(26))
        // Edited after it was verified (the staging folder belongs to the user).
        try Data("tampered".utf8).write(to: staged.appendingPathComponent("Contents/Resources/data.txt"))
        XCTAssertThrowsError(try UpdateInstaller.install(staged, over: target, version: releaseVersion(26), requirement: adHoc))
        XCTAssertEqual(try version(of: target), releaseVersion(25))
        XCTAssertNoThrow(try CodeSignature.check(target, requirement: adHoc))
        // Gone (a cleaned cache).
        try FileManager.default.removeItem(at: staged)
        XCTAssertThrowsError(try UpdateInstaller.install(staged, over: target, version: releaseVersion(26), requirement: adHoc))
        XCTAssertEqual(try version(of: target), releaseVersion(25))
    }

    func testInstallReplacesADeletedApp() throws {
        let target = directory.appendingPathComponent("Applications/Peekaboo.app")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = try makeApp(directory.appendingPathComponent("Updates/\(releaseVersion(26).token)/Peekaboo.app"), version: releaseVersion(26))
        try UpdateInstaller.install(staged, over: target, version: releaseVersion(26), requirement: adHoc)
        XCTAssertEqual(try version(of: target), releaseVersion(26))
    }

    func testHelperWaitsForTheAppThenInstalls() throws {
        let target = try makeApp(directory.appendingPathComponent("Applications/Peekaboo.app"), version: releaseVersion(25))
        let staged = try makeApp(directory.appendingPathComponent("Updates/\(releaseVersion(26).token)/Peekaboo.app"), version: releaseVersion(26))
        // A process that has exited stands in for the app that quit.
        let quit = Process()
        quit.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try quit.run()
        quit.waitUntilExit()
        let job = UpdateInstaller.Job(pid: quit.processIdentifier, staged: staged, target: target, version: releaseVersion(26))
        let cache = directory.appendingPathComponent("cache")
        XCTAssertEqual(UpdateInstaller.runHelper(job.arguments, requirement: adHoc, cache: cache), 0)
        XCTAssertEqual(try version(of: target), releaseVersion(26))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path), "the version folder is removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Updates").path))
        XCTAssertNil(UpdateInstaller.Failure.read(in: cache), "nothing failed")
        // A running process is waited for, and nothing is installed while it runs.
        XCTAssertFalse(UpdateInstaller.waitForExit(getpid(), timeout: 0.05))
        XCTAssertTrue(UpdateInstaller.waitForExit(quit.processIdentifier, timeout: 0.05))
        XCTAssertEqual(UpdateInstaller.runHelper(["--install-update", "nope"]), 64)
    }

    func testHelperRemembersAFailedInstall() throws {
        let target = try makeApp(directory.appendingPathComponent("Applications/Peekaboo.app"), version: releaseVersion(25))
        let staged = try makeApp(directory.appendingPathComponent("Updates/\(releaseVersion(26).token)/Peekaboo.app"), version: releaseVersion(26))
        try Data("tampered".utf8).write(to: staged.appendingPathComponent("Contents/Resources/data.txt"))
        let job = UpdateInstaller.Job(pid: try exitedProcess(), staged: staged, target: target, version: releaseVersion(26))
        let cache = directory.appendingPathComponent("cache")
        XCTAssertEqual(UpdateInstaller.runHelper(job.arguments, requirement: adHoc, cache: cache), 1)
        XCTAssertEqual(try version(of: target), releaseVersion(25), "the app is left alone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path), "the download is removed")
        let failure = try XCTUnwrap(UpdateInstaller.Failure.read(in: cache), "the next run must learn of it")
        XCTAssertEqual(failure.version, releaseVersion(26).token)
        XCTAssertEqual(failure.target, target.path)
        XCTAssertTrue(failure.reason.hasPrefix("the download failed verification: "), failure.reason)
        XCTAssertFalse(failure.reported)
    }

    func testFailureRecordRoundTrip() throws {
        let cache = directory.appendingPathComponent("cache")
        XCTAssertNil(UpdateInstaller.Failure.read(in: cache))
        var failure = UpdateInstaller.Failure(version: releaseVersion(26), target: URL(fileURLWithPath: "/Applications/Peekaboo.app"),
                                              reason: "Operation not supported")
        failure.write(in: cache)
        XCTAssertEqual(UpdateInstaller.Failure.read(in: cache), failure)
        failure.reported = true
        failure.write(in: cache)
        XCTAssertEqual(UpdateInstaller.Failure.read(in: cache)?.reported, true)
        UpdateInstaller.Failure.remove(in: cache)
        XCTAssertNil(UpdateInstaller.Failure.read(in: cache))
        XCTAssertEqual(UpdateInstaller.failureReason(UpdateError.install("Cross-device link")), "Cross-device link")
        XCTAssertEqual(UpdateInstaller.failureReason(UpdateError.verification("SHA-256 mismatch")),
                       "the download failed verification: SHA-256 mismatch")
    }

    /// An app on another volume stages in one folder of its own there (not a new temporary folder per run), and an
    /// update installs within that volume.
    func testStagingOnAnotherVolume() throws {
        let volume = try mountScratchVolume()
        let target = try makeApp(volume.appendingPathComponent("Applications/Peekaboo.app"), version: releaseVersion(25))
        let cache = directory.appendingPathComponent("cache")
        let root = try UpdateInstaller.stagingRoot(for: target, cache: cache)
        XCTAssertEqual(try UpdateInstaller.stagingRoot(for: target, cache: cache), root, "every run stages in the same folder")
        func device(_ url: URL) throws -> Int? { try FileManager.default.attributesOfItem(atPath: url.path)[.systemNumber] as? Int }
        XCTAssertEqual(try device(root), try device(volume), "on the app's volume, so that the install is a rename")
        XCTAssertNotEqual(try device(root), try device(cache))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.deletingLastPathComponent().path),
                       [root.lastPathComponent], "the temporary folders it was found with are gone")
        // On the home folder's volume it is the cache's Updates folder.
        let local = try makeApp(directory.appendingPathComponent("Applications/Peekaboo.app"), version: releaseVersion(25))
        XCTAssertEqual(try UpdateInstaller.stagingRoot(for: local, cache: cache), UpdateInstaller.updatesFolder(in: cache))

        // A download an earlier run left behind goes with the next one.
        let stale = root.appendingPathComponent(releaseVersion(24).token)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        UpdateInstaller.removeStaged(in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))

        let staged = try makeApp(root.appendingPathComponent("\(releaseVersion(26).token)/Peekaboo.app"), version: releaseVersion(26))
        let job = UpdateInstaller.Job(pid: try exitedProcess(), staged: staged, target: target, version: releaseVersion(26))
        XCTAssertEqual(UpdateInstaller.runHelper(job.arguments, requirement: adHoc, cache: cache), 0)
        XCTAssertEqual(try version(of: target), releaseVersion(26))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])

        // Staged on one volume for an app on another, the swap cannot happen: recorded with the system's reason.
        let elsewhere = try makeApp(root.appendingPathComponent("\(releaseVersion(27).token)/Peekaboo.app"), version: releaseVersion(27))
        let crossing = UpdateInstaller.Job(pid: try exitedProcess(), staged: elsewhere, target: local, version: releaseVersion(27))
        XCTAssertEqual(UpdateInstaller.runHelper(crossing.arguments, requirement: adHoc, cache: cache), 1)
        XCTAssertEqual(try version(of: local), releaseVersion(25))
        XCTAssertEqual(UpdateInstaller.Failure.read(in: cache)?.reason, String(cString: strerror(EXDEV)))
    }

    /// A process that has exited, standing in for the app that quit.
    private func exitedProcess() throws -> pid_t {
        let quit = Process()
        quit.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try quit.run()
        quit.waitUntilExit()
        return quit.processIdentifier
    }

    /// A scratch APFS volume mounted in `directory` until the test ends; skips the test where disk images cannot be
    /// attached.
    private func mountScratchVolume() throws -> URL {
        let image = directory.appendingPathComponent("scratch.dmg")
        let mountPoint = directory.appendingPathComponent("volume", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        guard hdiutil(["create", "-quiet", "-size", "16m", "-fs", "APFS", "-volname", "PeekabooTest", image.path]),
              hdiutil(["attach", "-quiet", "-nobrowse", "-noverify", "-noautoopen", "-mountpoint", mountPoint.path, image.path])
        else { throw XCTSkip("cannot attach a disk image here") }
        addTeardownBlock { [self] in _ = hdiutil(["detach", "-force", "-quiet", mountPoint.path]) }
        return mountPoint
    }

    /// Run hdiutil for at most 60 s; true when it succeeded.
    private func hdiutil(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let deadline = Date().addingTimeInterval(60)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        guard !process.isRunning else {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }

    func testHelperArgumentsRoundTrip() throws {
        let job = UpdateInstaller.Job(pid: 4242, staged: URL(fileURLWithPath: "/tmp/u/20261126/Peekaboo.app"),
                                      target: URL(fileURLWithPath: "/Applications/Peekaboo.app"),
                                      version: releaseVersion(26), relaunch: true,
                                      reopen: URL(fileURLWithPath: "/Photos/a b.jpg"))
        XCTAssertEqual(job.arguments.first, UpdateInstaller.helperFlag)
        XCTAssertEqual(UpdateInstaller.Job(arguments: job.arguments), job)
        XCTAssertEqual(UpdateInstaller.Job(arguments: Array(job.arguments.dropFirst())), job)
        var plain = job
        plain.relaunch = false
        plain.reopen = nil
        XCTAssertEqual(UpdateInstaller.Job(arguments: plain.arguments), plain)
        let token = releaseVersion(26).token
        for bad in [["--install-update"], ["0", "/a", "/b", token], ["x", "/a", "/b", token], ["1", "/a", "/b", "next"],
                    ["1", "/a", "/b", "20261126"], ["1", "/a", "/b", token, "--open"], ["1", "/a", "/b", token, "--rm"]] {
            XCTAssertNil(UpdateInstaller.Job(arguments: bad), "\(bad)")
        }
    }

    func testWhereTheAppCannotReplaceItself() throws {
        let app = try makeApp(directory.appendingPathComponent("Applications/Peekaboo.app"), version: releaseVersion(25), sign: false)
        XCTAssertNil(UpdateInstaller.cannotReplaceReason(app))
        let translocated = URL(fileURLWithPath: "/private/var/folders/xy/T/AppTranslocation/0F2A/d/Peekaboo.app")
        XCTAssertNotNil(UpdateInstaller.cannotReplaceReason(translocated))
        let folder = app.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        guard access(folder.path, W_OK) != 0 else { throw XCTSkip("running as root: every folder is writable") }
        XCTAssertEqual(UpdateInstaller.cannotReplaceReason(app), "“Applications” is not writable")
    }

    // MARK: Download checks

    func testSHA256AndUnpack() throws {
        let file = directory.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try UpdateInstaller.sha256(of: file), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        let app = try makeApp(directory.appendingPathComponent("build/Peekaboo.app"), version: releaseVersion(26))
        let zip = directory.appendingPathComponent("Peekaboo-20261126.zip")
        try ditto(["-c", "-k", "--keepParent", app.path, zip.path])
        let folder = directory.appendingPathComponent("Updates/\(releaseVersion(26).token)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let unpacked = try UpdateInstaller.unpack(zip, into: folder)
        XCTAssertEqual(unpacked.lastPathComponent, "Peekaboo.app")
        XCTAssertNoThrow(try UpdateInstaller.verify(unpacked, version: releaseVersion(26), requirement: adHoc),
                         "ditto keeps the signature intact")
        // Not a zip.
        XCTAssertThrowsError(try UpdateInstaller.unpack(file, into: directory.appendingPathComponent("x")))
    }

    func testRemoveStagedKeepsOnlyTheWantedVersion() throws {
        let root = directory.appendingPathComponent("Updates")
        for name in [releaseVersion(24).token, releaseVersion(25).token, "20261125", "20261125.1", "junk"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        UpdateInstaller.removeStaged(in: root, keeping: releaseVersion(25))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [releaseVersion(25).token])
        UpdateInstaller.removeStaged(in: root)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    private func ditto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: Config

    func testUpdatesTable() throws {
        XCTAssertEqual(AppConfig.default.updates, AppConfig.Updates(check: true, autoInstall: true))
        let config = try AppConfig(toml: "[updates]\ncheck = false\nauto_install = false\n")
        XCTAssertEqual(config.updates, AppConfig.Updates(check: false, autoInstall: false))
        XCTAssertThrowsError(try AppConfig(toml: "[updates]\ncheck = \"no\"\n")) { error in
            XCTAssertEqual((error as? ConfigError)?.messages, ["config.toml:2: updates.check must be true or false, got string"])
        }
        let (_, warnings) = try AppConfig.parse(toml: "[updates]\nchannel = \"beta\"\n[view]\nauto_install = true\n")
        XCTAssertEqual(warnings, [
            "config.toml:2: ignored unknown key \"updates.channel\"",
            "config.toml:4: ignored unknown key \"view.auto_install\" (it belongs under [updates])",
        ])
    }
}
