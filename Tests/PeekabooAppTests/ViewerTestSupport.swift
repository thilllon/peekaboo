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
class ViewerTestCase: XCTestCase {
    /// Scratch directory of the test; `folder` (the browsed images) lives inside it.
    private(set) var root: URL!
    private(set) var folder: URL!
    private(set) var viewer: ViewerWindowController?

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        _ = NSApplication.shared
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
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    /// A viewer with the default configuration, or `toml` as its config file.
    func makeViewer(toml: String? = nil) throws -> ViewerWindowController {
        let configURL = root.appendingPathComponent("config.toml")
        if let toml { try Data(toml.utf8).write(to: configURL) }
        let store = ConfigStore(url: configURL)
        store.load()
        let viewer = ViewerWindowController(configStore: store)
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

    /// Stored property `label` of `object` (any access level), through `Mirror`.
    func property<T>(_ object: Any, _ label: String) -> T? {
        var mirror: Mirror? = Mirror(reflecting: object)
        while let current = mirror {
            if let child = current.children.first(where: { $0.label == label }) { return child.value as? T }
            mirror = current.superclassMirror
        }
        return nil
    }

    func index(of name: String, in viewer: ViewerWindowController) -> Int? {
        viewer.pipeline.files.firstIndex { $0.name == name }
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
