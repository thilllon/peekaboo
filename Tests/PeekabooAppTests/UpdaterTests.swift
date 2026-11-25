import AppKit
import XCTest
@testable import PeekabooApp
@testable import PeekabooCore

/// The updater as the Settings window sees it (`PeekabooCheckForUpdatesNow` in, `PeekabooUpdateStatusChanged` out),
/// against a manifest file instead of the network. Nothing is downloaded or installed.
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

    private func fakeApp(_ version: String) throws -> Bundle { try fakePeekabooApp(in: root, version: version) }

    private func publish(_ version: String) throws { try publishManifest(in: root, version: version) }

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
        try publish("20261125")
        let updater = try XCTUnwrap(Updater(settings: AppConfig.Updates(check: false), bundle: try fakeApp("20261125")))
        let controller = UpdateController(updater: updater) { nil }
        let seen = statuses(until: "Up to date") {
            NotificationCenter.default.post(name: Notification.Name("PeekabooCheckForUpdatesNow"), object: nil)
        }
        XCTAssertEqual(seen, ["Checking for updates…", "Up to date (20261125)"])
        XCTAssertEqual(updater.phase, .upToDate)
        XCTAssertFalse(controller.canPerformUpdate)
    }

    func testANewerReleaseWaitsForTheUserWithoutAutoInstall() throws {
        try publish("20261126")
        let updater = try XCTUnwrap(Updater(settings: AppConfig.Updates(check: false, autoInstall: false),
                                            bundle: try fakeApp("20261125")))
        let controller = UpdateController(updater: updater) { nil }
        let seen = statuses(until: "Peekaboo 20261126 is available") { updater.checkNow(show: false) }
        XCTAssertEqual(seen.last, "Peekaboo 20261126 is available")
        guard case .available(let manifest, nil) = updater.phase else { return XCTFail("\(updater.phase)") }
        XCTAssertEqual(manifest.version, AppVersion("20261126"))
        XCTAssertTrue(controller.canPerformUpdate)
    }

    func testStatusTexts() {
        let current = AppVersion("20261125")!
        func text(_ phase: Updater.Phase, _ settings: AppConfig.Updates = AppConfig.Updates(), installs: Bool = true) -> String {
            Updater.statusText(phase, current: current, settings: settings, installsOnQuit: installs)
        }
        XCTAssertEqual(text(.idle), "Peekaboo 20261125 · checks for updates automatically")
        XCTAssertEqual(text(.idle, AppConfig.Updates(check: false)), "Peekaboo 20261125 · automatic update checks are off")
        XCTAssertEqual(text(.checking), "Checking for updates…")
        XCTAssertEqual(text(.upToDate), "Up to date (20261125)")
        XCTAssertEqual(text(.failed("Could not check for updates: offline")), "Could not check for updates: offline")
    }
}

/// A bundle in `root` that passes for Peekaboo.app `version` (unsigned: nothing may be installed from or over it).
private func fakePeekabooApp(in root: URL, version: String) throws -> Bundle {
    let contents = root.appendingPathComponent("Peekaboo.app/Contents")
    try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    let info: [String: Any] = ["CFBundleIdentifier": "com.thilllon.Peekaboo", "CFBundleShortVersionString": version,
                               "CFBundleExecutable": "Peekaboo", "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    FileManager.default.createFile(atPath: contents.appendingPathComponent("MacOS/Peekaboo").path, contents: Data())
    return try XCTUnwrap(Bundle(url: contents.deletingLastPathComponent()))
}

/// Serve a `latest.json` in `root` announcing `version` through `PEEKABOO_UPDATE_URL`.
private func publishManifest(in root: URL, version: String) throws {
    let url = root.appendingPathComponent("latest.json")
    let json: [String: Any] = ["version": version, "minimumSystemVersion": "26.0", "url": "https://example.com/Peekaboo.zip",
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
        try publishManifest(in: root, version: "20261126")
        let app = try fakePeekabooApp(in: root, version: "20261125")
        let updater = try XCTUnwrap(Updater(settings: AppConfig.Updates(check: false, autoInstall: false), bundle: app))
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
