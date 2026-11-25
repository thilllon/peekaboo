import Security
import XCTest
@testable import PeekabooCore

/// Date versions, `latest.json`, the check schedule, signature requirements and the bundle swap of the updater.
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

    func testVersionsOrderLegacyBeforeDatesAndSameDayReleases() throws {
        let ordered = ["0.1.0", "0.2", "1.0.0", "20231231", "20261124", "20261125", "20261125.1", "20261125.2",
                       "20261125.10", "20261126"].map { AppVersion($0)! }
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThan(a, b, "\(a) < \(b)")
            XCTAssertGreaterThan(b, a)
        }
        XCTAssertEqual(AppVersion("v0.1.0"), AppVersion("0.1.0"))
        XCTAssertEqual(AppVersion("0.1"), AppVersion("0.1.0"))
        XCTAssertEqual(AppVersion("20261125.0"), AppVersion("20261125"))
        XCTAssertEqual(Set(["0.1", "0.1.0", "v0.1.0"].compactMap(AppVersion.init)).count, 1)
        XCTAssertEqual(AppVersion(" 20261125.1 ")?.description, "20261125.1")
        XCTAssertEqual(AppVersion("v0.1.0")?.description, "0.1.0")
        XCTAssertEqual(AppVersion("20261125.0")?.description, "20261125")
        XCTAssertTrue(try XCTUnwrap(AppVersion("20261125.3")).isDateVersion)
        XCTAssertFalse(try XCTUnwrap(AppVersion("0.1.0")).isDateVersion)
    }

    func testMalformedVersionsAreRejected() {
        for text in ["", "v", "2026-11-25", "abc", "20261340", "20260230", "20230229", "19991231", "20261125.1.2",
                     "1..2", "1.2.3.4.5", ".1", "1.", "-1", "1.-2", "１２", "1234567890", "20261125.1234567890", "0x10"] {
            XCTAssertNil(AppVersion(text), text)
        }
        XCTAssertNotNil(AppVersion("20240229"))  // leap day
    }

    // MARK: Manifest

    private func manifest(_ fields: [String: Any]) -> Data {
        var json: [String: Any] = [
            "version": "20261126", "minimumSystemVersion": "26.0",
            "url": "https://github.com/thilllon/peekaboo/releases/download/20261126/Peekaboo-20261126.zip",
            "sha256": String(repeating: "aB", count: 32), "size": 2_412_345,
            "dmg": "https://github.com/thilllon/peekaboo/releases/download/20261126/Peekaboo-20261126.dmg",
            "notes": "https://github.com/thilllon/peekaboo/releases/tag/20261126", "published": "2026-11-26T09:30:00Z",
        ]
        for (key, value) in fields { json[key] = value is NSNull ? nil : value }
        return try! JSONSerialization.data(withJSONObject: json)
    }

    func testManifestParses() throws {
        let m = try UpdateManifest(data: manifest([:]))
        XCTAssertEqual(m.version, AppVersion("20261126"))
        XCTAssertEqual(m.sha256, String(repeating: "ab", count: 32))
        XCTAssertEqual(m.size, 2_412_345)
        XCTAssertEqual(m.url.lastPathComponent, "Peekaboo-20261126.zip")
        XCTAssertEqual(m.downloadPage.absoluteString, "https://github.com/thilllon/peekaboo/releases/tag/20261126")
        XCTAssertEqual(m.published, "2026-11-26T09:30:00Z")
        let bare = try UpdateManifest(data: manifest(["dmg": NSNull(), "notes": NSNull(), "published": NSNull()]))
        XCTAssertEqual(bare.downloadPage, bare.url)
        XCTAssertNil(bare.dmg)
        // Unknown fields from a newer release task are ignored.
        XCTAssertNoThrow(try UpdateManifest(data: manifest(["channel": "beta"])))
    }

    func testManifestRejectsBadFields() {
        let bad: [[String: Any]] = [
            ["version": "next"], ["version": NSNull()], ["sha256": "abc"], ["sha256": String(repeating: "g", count: 64)],
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
    private func makeApp(_ url: URL, version: String, identifier: String = "com.thilllon.Peekaboo",
                         sign: Bool = true) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version,
                                   "CFBundleVersion": version, "CFBundleExecutable": "Peekaboo",
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

    private func version(of app: URL) throws -> String? {
        try UpdateInstaller.bundleInfo(app).version?.description
    }

    private let adHoc = CodeSignature.updateRequirement(teamIdentifier: nil)!

    func testSignatureCheckAcceptsTheAppAndRejectsTampering() throws {
        let app = try makeApp(directory.appendingPathComponent("Peekaboo.app"), version: "20261126")
        XCTAssertNil(CodeSignature.teamIdentifier(of: app), "ad-hoc signatures carry no team")
        XCTAssertNoThrow(try UpdateInstaller.verify(app, version: AppVersion("20261126")!, requirement: adHoc))
        // Wrong version, wrong identifier, Developer ID required, an edited resource, no signature.
        XCTAssertThrowsError(try UpdateInstaller.verify(app, version: AppVersion("20261127")!, requirement: adHoc))
        XCTAssertThrowsError(try UpdateInstaller.verify(
            app, version: AppVersion("20261126")!, requirement: CodeSignature.updateRequirement(teamIdentifier: "ABCDE12345")!))
        let other = try makeApp(directory.appendingPathComponent("Other.app"), version: "20261126", identifier: "com.example.Other")
        XCTAssertThrowsError(try UpdateInstaller.verify(other, version: AppVersion("20261126")!, requirement: adHoc))
        try Data("tampered".utf8).write(to: app.appendingPathComponent("Contents/Resources/data.txt"))
        XCTAssertThrowsError(try UpdateInstaller.verify(app, version: AppVersion("20261126")!, requirement: adHoc)) { error in
            guard case UpdateError.verification = error else { return XCTFail("\(error)") }
        }
        let unsigned = try makeApp(directory.appendingPathComponent("Unsigned.app"), version: "20261126", sign: false)
        XCTAssertThrowsError(try UpdateInstaller.verify(unsigned, version: AppVersion("20261126")!, requirement: adHoc))
    }

    // MARK: Install

    func testInstallSwapsTheBundleAndDropsTheOldOne() throws {
        let target = try makeApp(directory.appendingPathComponent("Applications/Peekaboo.app"), version: "20261125")
        let staged = try makeApp(directory.appendingPathComponent("Updates/20261126/Peekaboo.app"), version: "20261126")
        try UpdateInstaller.install(staged, over: target, version: AppVersion("20261126")!, requirement: adHoc)
        XCTAssertEqual(try version(of: target), "20261126")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("Contents/Resources/data.txt"), encoding: .utf8),
                       "resource of 20261126")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "the old bundle (the backup) is deleted")
        XCTAssertNoThrow(try CodeSignature.check(target, requirement: adHoc))
    }

    func testInstallLeavesTheAppAloneWhenTheUpdateFailsItsChecks() throws {
        let target = try makeApp(directory.appendingPathComponent("Applications/Peekaboo.app"), version: "20261125")
        let staged = try makeApp(directory.appendingPathComponent("Updates/20261126/Peekaboo.app"), version: "20261126")
        // Not the expected version (a replayed or mixed-up download).
        XCTAssertThrowsError(try UpdateInstaller.install(staged, over: target, version: AppVersion("20261127")!, requirement: adHoc))
        XCTAssertEqual(try version(of: target), "20261125")
        XCTAssertEqual(try version(of: staged), "20261126")
        // Edited after it was verified (the staging folder belongs to the user).
        try Data("tampered".utf8).write(to: staged.appendingPathComponent("Contents/Resources/data.txt"))
        XCTAssertThrowsError(try UpdateInstaller.install(staged, over: target, version: AppVersion("20261126")!, requirement: adHoc))
        XCTAssertEqual(try version(of: target), "20261125")
        XCTAssertNoThrow(try CodeSignature.check(target, requirement: adHoc))
        // Gone (a cleaned cache).
        try FileManager.default.removeItem(at: staged)
        XCTAssertThrowsError(try UpdateInstaller.install(staged, over: target, version: AppVersion("20261126")!, requirement: adHoc))
        XCTAssertEqual(try version(of: target), "20261125")
    }

    func testInstallReplacesADeletedApp() throws {
        let target = directory.appendingPathComponent("Applications/Peekaboo.app")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = try makeApp(directory.appendingPathComponent("Updates/20261126/Peekaboo.app"), version: "20261126")
        try UpdateInstaller.install(staged, over: target, version: AppVersion("20261126")!, requirement: adHoc)
        XCTAssertEqual(try version(of: target), "20261126")
    }

    func testHelperWaitsForTheAppThenInstalls() throws {
        let target = try makeApp(directory.appendingPathComponent("Applications/Peekaboo.app"), version: "20261125")
        let staged = try makeApp(directory.appendingPathComponent("Updates/20261126/Peekaboo.app"), version: "20261126")
        // A process that has exited stands in for the app that quit.
        let quit = Process()
        quit.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try quit.run()
        quit.waitUntilExit()
        let job = UpdateInstaller.Job(pid: quit.processIdentifier, staged: staged, target: target, version: AppVersion("20261126")!)
        XCTAssertEqual(UpdateInstaller.runHelper(job.arguments, requirement: adHoc), 0)
        XCTAssertEqual(try version(of: target), "20261126")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path), "the version folder is removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Updates").path))
        // A running process is waited for, and nothing is installed while it runs.
        XCTAssertFalse(UpdateInstaller.waitForExit(getpid(), timeout: 0.05))
        XCTAssertTrue(UpdateInstaller.waitForExit(quit.processIdentifier, timeout: 0.05))
        XCTAssertEqual(UpdateInstaller.runHelper(["--install-update", "nope"]), 64)
    }

    func testHelperArgumentsRoundTrip() throws {
        let job = UpdateInstaller.Job(pid: 4242, staged: URL(fileURLWithPath: "/tmp/u/20261126/Peekaboo.app"),
                                      target: URL(fileURLWithPath: "/Applications/Peekaboo.app"),
                                      version: AppVersion("20261126")!, relaunch: true,
                                      reopen: URL(fileURLWithPath: "/Photos/a b.jpg"))
        XCTAssertEqual(job.arguments.first, UpdateInstaller.helperFlag)
        XCTAssertEqual(UpdateInstaller.Job(arguments: job.arguments), job)
        XCTAssertEqual(UpdateInstaller.Job(arguments: Array(job.arguments.dropFirst())), job)
        var plain = job
        plain.relaunch = false
        plain.reopen = nil
        XCTAssertEqual(UpdateInstaller.Job(arguments: plain.arguments), plain)
        for bad in [["--install-update"], ["0", "/a", "/b", "20261126"], ["x", "/a", "/b", "20261126"],
                    ["1", "/a", "/b", "next"], ["1", "/a", "/b", "20261126", "--open"], ["1", "/a", "/b", "20261126", "--rm"]] {
            XCTAssertNil(UpdateInstaller.Job(arguments: bad), "\(bad)")
        }
    }

    func testWhereTheAppCannotReplaceItself() throws {
        let app = try makeApp(directory.appendingPathComponent("Applications/Peekaboo.app"), version: "20261125", sign: false)
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

        let app = try makeApp(directory.appendingPathComponent("build/Peekaboo.app"), version: "20261126")
        let zip = directory.appendingPathComponent("Peekaboo-20261126.zip")
        try ditto(["-c", "-k", "--keepParent", app.path, zip.path])
        let folder = directory.appendingPathComponent("Updates/20261126")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let unpacked = try UpdateInstaller.unpack(zip, into: folder)
        XCTAssertEqual(unpacked.lastPathComponent, "Peekaboo.app")
        XCTAssertNoThrow(try UpdateInstaller.verify(unpacked, version: AppVersion("20261126")!, requirement: adHoc),
                         "ditto keeps the signature intact")
        // Not a zip.
        XCTAssertThrowsError(try UpdateInstaller.unpack(file, into: directory.appendingPathComponent("x")))
    }

    func testRemoveStagedKeepsOnlyTheWantedVersion() throws {
        let root = directory.appendingPathComponent("Updates")
        for name in ["20261124", "20261125", "20261125.1", "junk"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        UpdateInstaller.removeStaged(in: root, keeping: AppVersion("20261125"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["20261125"])
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
