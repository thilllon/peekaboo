import AppKit
import ImageIO
import Metal
import UniformTypeIdentifiers
import XCTest
@testable import PeekabooApp
@testable import PeekabooCore
@testable import PeekabooRender

/// Base class of the tests that drive a real `ViewerWindowController` (window, Metal renderer, pipeline, folder
/// watcher) on the main run loop. Skipped without a Metal device.
///
/// Nothing of a test run reaches the screen or the keyboard focus: the process can never become the active app, and
/// viewers are `.headless` (ordered in, rendering, but transparent and off every screen). Every test fails if the
/// process activated or a window became key or came on screen meanwhile (`assertNothingOnScreen`), or if it leaves a
/// viewer or Settings window open.
class ViewerTestCase: XCTestCase {
    /// Scratch directory of the test; `folder` (the browsed images) lives inside it.
    private(set) var root: URL!
    private(set) var folder: URL!
    private(set) var viewer: ViewerWindowController?
    /// Activations and windows that became key or visible during the test.
    private var focusEvents: [String] = []
    private var focusObservers: [NSObjectProtocol] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        // Windows need a window-server session (none for a runner started as a daemon).
        guard CGSessionCopyCurrentDictionary() != nil else { throw XCTSkip("no window-server session") }
        _ = NSApplication.shared
        // No Dock icon, no menu bar, and `NSApp.activate()` does nothing: the user's focus stays where it is.
        NSApp.setActivationPolicy(.prohibited)
        watchFocus()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-app-tests-\(UUID().uuidString)", isDirectory: true)
        folder = root.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let viewer {
            viewer.window?.close()
            spin(0.05)
        }
        viewer = nil
        // Subclasses close their own windows before this runs: one still ordered in would stay for the rest of the run.
        let open = NSApp.windows.filter { $0.isVisible && ($0 is ViewerWindow || $0 is SettingsWindow) }
        XCTAssertEqual(open.map(Self.describe), [], "the test left windows open")
        if let root { try? FileManager.default.removeItem(at: root) }
        for observer in focusObservers { NotificationCenter.default.removeObserver(observer) }
        focusObservers = []
        super.tearDown()
    }

    /// A headless viewer with the default configuration, or `toml` as its config file. Window state (`uiState`) is kept
    /// in memory, never in the defaults; `makeThumbnail` makes the image list's thumbnails.
    func makeViewer(toml: String? = nil, uiState: ViewerUIState = .inMemory(),
                    makeThumbnail: @escaping ThumbnailLoader.Make = ThumbnailLoader.standardMake) throws -> ViewerWindowController {
        let configURL = root.appendingPathComponent("config.toml")
        if let toml { try Data(toml.utf8).write(to: configURL) }
        let store = ConfigStore(url: configURL)
        store.load()
        let viewer = ViewerWindowController(configStore: store, presentation: .headless, uiState: uiState,
                                            makeThumbnail: makeThumbnail)
        self.viewer = viewer
        objc_setAssociatedObject(viewer, &Self.storeKey, store, .OBJC_ASSOCIATION_RETAIN)
        return viewer
    }

    private static var storeKey = 0

    // MARK: Images

    /// Writes a solid image (`gray` 0…1) of the given size and type.
    @discardableResult
    func writeImage(_ url: URL, width: Int, height: Int, gray: CGFloat, type: UTType = .jpeg) -> URL {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: space, components: [gray, gray, gray, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // A small mark, so encoders cannot collapse the image to a constant.
        context.setFillColor(CGColor(colorSpace: space, components: [1 - gray, 0.5, gray, 1])!)
        context.fill(CGRect(x: width / 3, y: height / 3, width: max(width / 8, 1), height: max(height / 8, 1)))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination), "cannot write \(url.lastPathComponent)")
        return url
    }

    /// `count` JPEGs named `prefix00.jpg`, `prefix01.jpg`, … in `directory`, each with its own gray.
    @discardableResult
    func writeSequence(_ count: Int, in directory: URL? = nil, prefix: String = "img", width: Int = 1200,
                       height: Int = 800) -> [URL] {
        let directory = directory ?? folder!
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (0..<count).map { i in
            writeImage(directory.appendingPathComponent(String(format: "%@%02d.jpg", prefix, i)),
                       width: width, height: height, gray: CGFloat(i % 10) / 10 + 0.05)
        }
    }

    /// Replaces `url` the way editors save: write a hidden temporary file next to it, rename it over the original.
    func atomicallyReplace(_ url: URL, width: Int, height: Int, gray: CGFloat, type: UTType) {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".saving-\(url.lastPathComponent)")
        writeImage(temporary, width: width, height: height, gray: gray, type: type)
        XCTAssertEqual(rename(temporary.path, url.path), 0, "rename failed")
    }

    // MARK: Waiting

    /// Runs the main run loop until `condition` holds or `seconds` pass; returns the condition's last value.
    @discardableResult
    func spin(_ seconds: TimeInterval, until condition: () -> Bool = { false }) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() >= deadline { return condition() }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        return true
    }

    /// Opens `urls` and waits until the folder is listed and the opened file shows a tier.
    func openAndWait(_ viewer: ViewerWindowController, _ urls: [URL], file: String? = nil,
                     line: UInt = #line) {
        viewer.open(urls)
        let expected = file ?? urls[0].lastPathComponent
        let ready = spin(10) {
            viewer.displayedFile?.name == expected && viewer.shownTierForTests != nil
                && !viewer.isListingPendingForTests
        }
        XCTAssertTrue(ready, "\(expected) was not shown", line: line)
    }

    // MARK: Focus and screen

    /// Records, until the test ends, every activation of the process and every window that becomes key or visible; a
    /// teardown block (it runs before `tearDown`, so before subclasses close their windows) then checks the state.
    private func watchFocus() {
        func record(_ name: Notification.Name, _ event: @escaping (Notification) -> String?) {
            focusObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                if let event = event(note) { self?.focusEvents.append(event) }
            })
        }
        record(NSApplication.didBecomeActiveNotification) { _ in "the test process became the active app" }
        record(NSWindow.didBecomeKeyNotification) { note in "\((note.object as? NSWindow).map(Self.describe) ?? "a window") became key" }
        record(NSWindow.didChangeOcclusionStateNotification) { note in
            guard let window = note.object as? NSWindow, window.occlusionState.contains(.visible) else { return nil }
            return "\(Self.describe(window)) came on screen"
        }
        addTeardownBlock { [weak self] in self?.assertNothingOnScreen() }
    }

    /// The process is not the active app, never was during the test, and none of its windows can be seen: every
    /// ordered-in window is transparent, off every screen and not key.
    func assertNothingOnScreen(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(focusEvents, [], file: file, line: line)
        XCTAssertFalse(NSApp.isActive, "the test process is the active app", file: file, line: line)
        let screens = NSScreen.screens.map(\.frame)
        for window in NSApp.windows where window.isVisible {
            XCTAssertEqual(window.alphaValue, 0, "\(Self.describe(window)) is not transparent", file: file, line: line)
            XCTAssertFalse(screens.contains { $0.intersects(window.frame) }, "\(Self.describe(window)) is on a screen \(screens)",
                           file: file, line: line)
            XCTAssertFalse(window.isKeyWindow, "\(Self.describe(window)) is key", file: file, line: line)
        }
    }

    /// A window, for failure messages: class, number, title, frame, alpha, and whether a controller still owns it.
    static func describe(_ window: NSWindow) -> String {
        let offScreen = (window as? ViewerWindow)?.staysOffScreen ?? (window as? SettingsWindow)?.staysOffScreen
        return "\(type(of: window)) #\(window.windowNumber) “\(window.title)” at \(window.frame) alpha \(window.alphaValue)"
            + " staysOffScreen \(offScreen.map { "\($0)" } ?? "-") controller \(window.windowController.map { "\(type(of: $0))" } ?? "none")"
    }

    // MARK: Introspection

    func renderer(_ viewer: ViewerWindowController) -> Renderer { property(viewer, "renderer")! }
    func hud(_ viewer: ViewerWindowController) -> HUD { property(viewer, "hud")! }

    /// Centred HUD message (nil = hidden).
    func hudMessage(_ viewer: ViewerWindowController) -> String? {
        let text: String?? = property(hud(viewer), "messageText")
        return text ?? nil
    }

    /// The 2-px progress line is visible.
    func isLoading(_ viewer: ViewerWindowController) -> Bool {
        let layer: CALayer = property(hud(viewer), "progress")!
        return !layer.isHidden
    }

    /// Text of the last toast (it stays in its layer after fading out).
    func toastText(_ viewer: ViewerWindowController) -> String? {
        guard let box: Any = property(hud(viewer), "toast"), let layer: CATextLayer = property(box, "text") else { return nil }
        return (layer.string as? NSAttributedString)?.string
    }

    /// A key-down event for `viewer`'s window (`keyCode` from Carbon's `kVK_*`).
    func keyDown(_ viewer: ViewerWindowController, keyCode: Int, characters: String, isRepeat: Bool = false,
                 modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: viewer.window?.windowNumber ?? 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: isRepeat, keyCode: UInt16(keyCode))!
    }

    /// Stored property `label` of `object` (any access level), through `Mirror`.
    func property<T>(_ object: Any, _ label: String) -> T? {
        var mirror: Mirror? = Mirror(reflecting: object)
        while let current = mirror {
            if let child = current.children.first(where: { $0.label == label }) { return child.value as? T }
            mirror = current.superclassMirror
        }
        return nil
    }
}

extension ViewerWindowController {
    var shownTierForTests: Tier? {
        Mirror(reflecting: self).children.first { $0.label == "shownTier" }?.value as? Tier
    }

    var isListingPendingForTests: Bool {
        (Mirror(reflecting: self).children.first { $0.label == "listingPending" }?.value as? Bool) ?? false
    }
}
