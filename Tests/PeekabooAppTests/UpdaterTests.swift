import AppKit
import XCTest
@testable import PeekabooApp
@testable import PeekabooCore

/// Release `n` of these tests: `202611nn-0000nn` with build number `n` (25 < 26).
func releaseVersion(_ n: Int) -> AppVersion { AppVersion(name: String(format: "202611%02d-0000%02d", n, n), build: n)! }

/// The updater as the Settings window sees it (`PeekabooCheckForUpdatesNow` in, `PeekabooUpdateStatusChanged` out),
/// against a manifest file instead of the network, and a cache folder of its own. Nothing is installed, and the one
/// download tried is of a file that does not exist.
final class UpdaterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("peekaboo-updater-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        unsetenv("PEEKABOO_UPDATE_URL")
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func fakeApp(_ version: AppVersion) throws -> Bundle { try fakePeekabooApp(in: root, version: version) }

    /// The updater's folder for these tests (never the user's).
    private var cache: URL { root.appendingPathComponent("cache") }

    private func publish(_ version: AppVersion) throws { try publishManifest(in: root, version: version) }

    /// Statuses posted until one starts with `final`.
    private func statuses(until final: String, after trigger: () -> Void) -> [String] {
        var seen: [String] = []
        let done = expectation(description: final)
        let observer = NotificationCenter.default.addObserver(forName: Updater.statusNotification, object: nil, queue: .main) { note in
            guard let status = note.userInfo?["status"] as? String else { return }
            seen.append(status)
            if status.hasPrefix(final) { done.fulfill() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        trigger()
        wait(for: [done], timeout: 10)
        return seen
    }

    func testOnlyPeekabooAppUpdates() {
        XCTAssertNil(Updater(settings: AppConfig.Updates()), "the test runner is not Peekaboo.app")
    }

    func testCheckNowFromSettingsPostsTheStatus() throws {
        try publish(releaseVersion(25))
        let updater = try XCTUnwrap(Updater(settings: AppConfig.Updates(check: false), bundle: try fakeApp(releaseVersion(25)), cache: cache))
        let controller = UpdateController(updater: updater) { nil }
        let seen = statuses(until: "Up to date") {
            NotificationCenter.default.post(name: Notification.Name("PeekabooCheckForUpdatesNow"), object: nil)
        }
        XCTAssertEqual(seen, ["Checking for updates…", "Up to date (20261125-000025)"])
        XCTAssertEqual(updater.phase, .upToDate)
        XCTAssertFalse(controller.canPerformUpdate)
    }

    func testUpToDateClearsTheStagedDownloadsButADiskImagesCopy() throws {
        // A newer Peekaboo staged from a disk image (`DiskImageUpdate`) sits next to the downloads; a check that finds the
        // app up to date, or a download, clears everything else there.
        try publish(releaseVersion(25))
        let updates = UpdateInstaller.updatesFolder(in: cache)
        for build in [24, 26, 27] {
            try FileManager.default.createDirectory(at: updates.appendingPathComponent(releaseVersion(build).token),
                                                    withIntermediateDirectories: true)
        }
        let updater = try XCTUnwrap(Updater(settings: AppConfig.Updates(check: false), bundle: try fakeApp(releaseVersion(25)), cache: cache))
        updater.keepStaged(releaseVersion(27))
        _ = statuses(until: "Up to date") { updater.checkNow(show: false) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: updates.path), [releaseVersion(27).token])
        updater.keepStaged(nil)
        _ = statuses(until: "Up to date") { updater.checkNow(show: false) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: updates.path), [])
        XCTAssertNil(updater.readyBuild)
        XCTAssertFalse(updater.installsOnQuit)
        XCTAssertFalse(updater.helperStarted)
    }

    func testADownloadClearsTheStagedDownloadsButADiskImagesCopy() throws {
        // Build 25 runs with a disk image's 27 staged, and a check finds 26: the download that starts clears the
        // staging folder, but not the copy that installs at the next activation.
        try publishManifest(in: root, version: releaseVersion(26), zip: root.appendingPathComponent("missing.zip").absoluteString)
        let updates = UpdateInstaller.updatesFolder(in: cache)
        for build in [24, 27] {
            try FileManager.default.createDirectory(at: updates.appendingPathComponent(releaseVersion(build).token),
                                                    withIntermediateDirectories: true)
        }
        let updater = try XCTUnwrap(Updater(settings: AppConfig.Updates(check: false), bundle: try fakeApp(releaseVersion(25)), cache: cache))
        updater.keepStaged(releaseVersion(27))
        func failed(_ phase: Updater.Phase) -> Bool { if case .failed = phase { return true } else { return false } }
        let seen = phases(of: updater, until: failed) { updater.checkNow(show: false) }
        XCTAssertTrue(seen.contains { if case .downloading = $0.phase { return true } else { return false } }, "\(seen)")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: updates.path), [releaseVersion(27).token])
    }

    func testANewerReleaseWaitsForTheUserWithoutAutoInstall() throws {
        try publish(releaseVersion(26))
        let updater = try XCTUnwrap(Updater(settings: AppConfig.Updates(check: false, autoInstall: false),
                                            bundle: try fakeApp(releaseVersion(25)), cache: cache))
        let controller = UpdateController(updater: updater) { nil }
        let seen = statuses(until: "Peekaboo 20261126-000026 is available") { updater.checkNow(show: false) }
        XCTAssertEqual(seen.last, "Peekaboo 20261126-000026 is available")
        guard case .available(let manifest, nil) = updater.phase else { return XCTFail("\(updater.phase)") }
        XCTAssertEqual(manifest.version, releaseVersion(26))
        XCTAssertTrue(controller.canPerformUpdate)
    }

    func testStatusTexts() {
        let current = releaseVersion(25)
        func text(_ phase: Updater.Phase, _ settings: AppConfig.Updates = AppConfig.Updates(), installs: Bool = true) -> String {
            Updater.statusText(phase, current: current, settings: settings, installsOnQuit: installs)
        }
        XCTAssertEqual(text(.idle), "Peekaboo 20261125-000025 · checks for updates automatically")
        XCTAssertEqual(text(.idle, AppConfig.Updates(check: false)), "Peekaboo 20261125-000025 · automatic update checks are off")
        XCTAssertEqual(text(.checking), "Checking for updates…")
        XCTAssertEqual(text(.upToDate), "Up to date (20261125-000025)")
        XCTAssertEqual(text(.failed("Could not check for updates: offline")), "Could not check for updates: offline")
    }

    /// Phase changes, and whether each is to be shown (a toast), until one meets `done`.
    private func phases(of updater: Updater, until done: @escaping (Updater.Phase) -> Bool,
                        after trigger: () -> Void) -> [(phase: Updater.Phase, shown: Bool)] {
        var seen: [(phase: Updater.Phase, shown: Bool)] = []
        let finished = expectation(description: "phase")
        finished.assertForOverFulfill = false
        updater.onChange = { phase, show in
            seen.append((phase, show))
            if done(phase) { finished.fulfill() }
        }
        trigger()
        wait(for: [finished], timeout: 10)
        updater.onChange = nil
        return seen
    }

    /// The helper could not install release 26 behind the last quit: the next run says so once, and automatic checks
    /// offer the download instead of fetching it to fail again on every quit; "Check for Updates…" tries again.
    func testAFailedInstallIsToldOnceAndNotFetchedAgain() throws {
        // The zip does not exist: a retry fails at once, without the network.
        try publishManifest(in: root, version: releaseVersion(26), zip: root.appendingPathComponent("missing.zip").absoluteString)
        let app = try fakeApp(releaseVersion(25))
        UpdateInstaller.Failure(version: releaseVersion(26), target: app.bundleURL, reason: "Operation not supported")
            .write(in: cache)
        var policy = UpdatePolicy()
        policy.firstCheckDelay = 0
        func available(_ phase: Updater.Phase) -> Bool { if case .available = phase { return true } else { return false } }
        func downloading(_ phase: Updater.Phase) -> Bool { if case .downloading = phase { return true } else { return false } }

        let first = try XCTUnwrap(Updater(settings: AppConfig.Updates(), bundle: app, cache: cache, policy: policy))
        let seen = phases(of: first, until: available) { first.start() }
        XCTAssertEqual(seen.filter(\.shown).map(\.phase), [.failed("Peekaboo 20261126-000026 could not be installed: Operation not supported")])
        XCTAssertFalse(seen.contains { downloading($0.phase) }, "fetched again")
        guard case .available(_, let blocked) = first.phase else { return XCTFail("\(first.phase)") }
        XCTAssertEqual(blocked, "installing it failed (Operation not supported)")
        XCTAssertEqual(UpdateInstaller.Failure.read(in: cache)?.reported, true)

        // A later run: offered again, but not told again.
        let later = try XCTUnwrap(Updater(settings: AppConfig.Updates(), bundle: app, cache: cache, policy: policy))
        let again = phases(of: later, until: available) { later.start() }
        XCTAssertFalse(again.contains { $0.shown || downloading($0.phase) }, "\(again)")

        // A manual check tries again (and forgets the failure).
        let retry = phases(of: later, until: { if case .failed = $0 { return true } else { return false } }) {
            later.checkNow(show: false)
        }
        XCTAssertTrue(retry.contains { downloading($0.phase) }, "\(retry)")
        XCTAssertNil(UpdateInstaller.Failure.read(in: cache))
    }
}

/// A bundle in `root` that passes for Peekaboo.app `version` (unsigned: nothing may be installed from or over it).
func fakePeekabooApp(in root: URL, version: AppVersion) throws -> Bundle {
    let contents = root.appendingPathComponent("Peekaboo.app/Contents")
    try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    let info: [String: Any] = ["CFBundleIdentifier": "com.thilllon.Peekaboo", "CFBundleShortVersionString": version.name,
                               "CFBundleVersion": String(version.build), "CFBundleExecutable": "Peekaboo",
                               "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    FileManager.default.createFile(atPath: contents.appendingPathComponent("MacOS/Peekaboo").path, contents: Data())
    return try XCTUnwrap(Bundle(url: contents.deletingLastPathComponent()))
}

/// Serve a `latest.json` in `root` announcing `version` (its zip at `zip`) through `PEEKABOO_UPDATE_URL`.
func publishManifest(in root: URL, version: AppVersion, zip: String = "https://example.com/Peekaboo.zip") throws {
    let url = root.appendingPathComponent("latest.json")
    let json: [String: Any] = ["version": version.name, "build": version.build, "minimumSystemVersion": "14.0", "url": zip,
                               "sha256": String(repeating: "0", count: 64), "size": 10]
    try JSONSerialization.data(withJSONObject: json).write(to: url)
    setenv("PEEKABOO_UPDATE_URL", url.absoluteString, 1)
}

/// The banner in a real viewer window: building it blocks the main thread, so an automatic one waits for a pause in
/// the input, and one the user asked for shows at once.
final class UpdateBannerTests: ViewerTestCase {
    override func tearDown() {
        unsetenv("PEEKABOO_UPDATE_URL")
        super.tearDown()
    }

    private func banner(_ viewer: ViewerWindowController) -> UpdateBanner? {
        viewer.window?.contentView?.subviews.lazy.compactMap { $0 as? UpdateBanner }.first
    }

    func testAnAutomaticBannerWaitsForAPauseInTheInput() throws {
        let viewer = try makeViewer()
        try publishManifest(in: root, version: releaseVersion(26))
        let app = try fakePeekabooApp(in: root, version: releaseVersion(25))
        let updater = try XCTUnwrap(Updater(settings: AppConfig.Updates(check: false, autoInstall: false), bundle: app,
                                            cache: root.appendingPathComponent("cache")))
        let controller = UpdateController(updater: updater) { viewer }
        var idle: TimeInterval = 0.2  // the user is flipping through images
        controller.secondsSinceInput = { idle }
        updater.checkNow(show: false)
        XCTAssertTrue(spin(10) { if case .available = updater.phase { return true } else { return false } })
        spin(0.3)
        XCTAssertNil(banner(viewer), "a banner was built while the user was busy")
        idle = 5
        XCTAssertTrue(spin(5) { self.banner(viewer) != nil }, "no banner once the input paused")
        let automatic = banner(viewer)

        // "Check for Updates…" while the user is busy: the outcome comes with its banner at once.
        idle = 0.2
        updater.checkNow(show: true)
        XCTAssertTrue(spin(10) { self.banner(viewer).map { $0 !== automatic } ?? false }, "the asked-for banner waited")
        XCTAssertEqual(viewer.window?.contentView?.subviews.filter { $0 is UpdateBanner }.count, 1)
    }
}
