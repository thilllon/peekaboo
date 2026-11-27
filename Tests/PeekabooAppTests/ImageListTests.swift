import AppKit
import Carbon.HIToolbox
import XCTest
@testable import PeekabooApp
@testable import PeekabooCore
@testable import PeekabooRender

/// Makes thumbnails instantly (or after `delay`) and records each call: the file, whether it ran on the main thread,
/// whether the viewer's preview of the file came with it, and how many ran at once.
final class ThumbnailRecorder: @unchecked Sendable {
    struct Call {
        let name: String
        let onMainThread: Bool
        let fromPreview: Bool
    }

    private let lock = NSLock()
    private var calls: [Call] = []
    private var running = 0
    private var most = 0
    private let delay: TimeInterval

    init(delay: TimeInterval = 0) { self.delay = delay }

    var make: ThumbnailLoader.Make {
        { [self] url, preview, size in
            lock.lock()
            running += 1
            most = max(most, running)
            lock.unlock()
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            let image = Self.image(min(size, 8))
            lock.lock()
            running -= 1
            calls.append(Call(name: url.lastPathComponent, onMainThread: Thread.isMainThread, fromPreview: preview != nil))
            lock.unlock()
            return image
        }
    }

    var made: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var mostAtOnce: Int {
        lock.lock()
        defer { lock.unlock() }
        return most
    }

    func count(_ name: String) -> Int { made.filter { $0.name == name }.count }

    private static func image(_ side: Int) -> CGImage {
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()!
    }
}

/// The image list (`view.image_list`, `t`): built on first use only, kept open or closed across launches (in the
/// injected store, never the defaults), following navigation, the picks-only view, file operations and rescans, and
/// costing navigation nothing measurable. Headless viewers throughout.
final class ImageListTests: ViewerTestCase {
    private func panel(_ viewer: ViewerWindowController) -> ImageListPanel? { property(viewer, "imageList") }
    private func rootView(_ viewer: ViewerWindowController) -> ViewerRootView { property(viewer, "rootView")! }
    private func viewerView(_ viewer: ViewerWindowController) -> ViewerView { property(viewer, "viewerView")! }

    /// `count` files `IMG_0000.jpg`… in the folder: the first `real` of them small JPEGs, the rest empty (listed, and
    /// shown as "cannot open": enough for a list).
    @discardableResult
    private func writeFolder(_ count: Int, real: Int = 3) -> [URL] {
        (0..<count).map { i in
            let url = folder.appendingPathComponent(String(format: "IMG_%04d.jpg", i))
            if i < real {
                writeImage(url, width: 320, height: 240, gray: CGFloat(i % 10) / 10 + 0.05)
            } else {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            return url
        }
    }

    /// Lay out and display the window now (rows are made in the layout pass).
    private func display(_ viewer: ViewerWindowController) {
        viewer.window?.layoutIfNeeded()
        viewer.window?.displayIfNeeded()
    }

    /// The rows of the list on screen.
    private func rowsOnScreen(_ panel: ImageListPanel) -> Range<Int> {
        let range = panel.table.rows(in: panel.table.visibleRect)
        return range.location..<(range.location + range.length)
    }

    private func isOnScreen(_ panel: ImageListPanel, _ row: Int) -> Bool {
        panel.table.visibleRect.intersects(panel.table.rect(ofRow: row))
    }

    private func cells(_ panel: ImageListPanel) -> [ImageListCell] {
        var cells: [ImageListCell] = []
        panel.table.enumerateAvailableRowViews { rowView, _ in
            if let cell = rowView.view(atColumn: 0) as? ImageListCell { cells.append(cell) }
        }
        return cells
    }

    /// A click on `row` of the list (mouse down, in window coordinates).
    private func click(_ panel: ImageListPanel, row: Int, in viewer: ViewerWindowController) throws {
        let rect = panel.table.rect(ofRow: row)
        let point = panel.table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: viewer.window?.windowNumber ?? 0, context: nil,
                                                     eventNumber: 0, clickCount: 1, pressure: 1))
        panel.table.mouseDown(with: event)
    }

    // MARK: Built on first use, kept across launches

    func testTheListIsBuiltOnFirstUseOnly() throws {
        let viewer = try makeViewer()
        let urls = writeFolder(20)
        openAndWait(viewer, [urls[0]])
        display(viewer)
        let root = rootView(viewer)
        XCTAssertNil(panel(viewer), "the list exists before it was opened")
        XCTAssertNil(root.sidebar)
        XCTAssertFalse(viewer.isImageListOpen)
        XCTAssertEqual(viewerView(viewer).frame.width, root.bounds.width, "the viewer does not have the whole width")

        viewer.perform(.imageList)
        let list = try XCTUnwrap(panel(viewer), "view.image_list did not build the list")
        XCTAssertTrue(viewer.isImageListOpen)
        XCTAssertTrue(root.sidebar === list)
        XCTAssertFalse(list.isHidden)
        XCTAssertEqual(list.frame.width, ImageListPanel.width)
        XCTAssertEqual(list.frame.maxX, root.bounds.maxX)
        XCTAssertEqual(viewerView(viewer).frame.width, root.bounds.width - ImageListPanel.width)
        XCTAssertEqual(list.files.map(\.name), viewer.pipeline.files.map(\.name))
        XCTAssertEqual(list.table.selectedRow, 0)
        XCTAssertFalse(list.table.acceptsFirstResponder, "the list would take the keys")

        viewer.perform(.imageList)
        XCTAssertFalse(viewer.isImageListOpen)
        XCTAssertTrue(list.isHidden)
        XCTAssertTrue(panel(viewer) === list, "closing it dropped the list")
        XCTAssertEqual(viewerView(viewer).frame.width, root.bounds.width)
        // Closed, it no longer follows the viewer.
        viewer.perform(.next)
        XCTAssertEqual(list.selectedRow, 0)
        viewer.perform(.imageList)
        XCTAssertEqual(list.selectedRow, 1, "opened again, it shows the image on screen")
    }

    /// Whether the list is open is kept across launches in the injected store; at launch the viewer keeps the room for
    /// it (the first frame fits beside it) and builds it in the main-queue turn after.
    func testOpenOrClosedIsKeptAcrossLaunches() throws {
        let state = ViewerUIState.inMemory()
        let urls = writeFolder(10)
        let first = try makeViewer(uiState: state)
        openAndWait(first, [urls[0]])
        first.perform(.imageList)
        XCTAssertTrue(state.isImageListOpen())
        first.window?.close()
        spin(0.05)

        let second = try makeViewer(uiState: state)
        XCTAssertTrue(second.isImageListOpen)
        XCTAssertNil(panel(second), "built at launch")
        let root = rootView(second)
        XCTAssertEqual(root.sidebarWidth, ImageListPanel.width)
        XCTAssertEqual(viewerView(second).frame.width, root.bounds.width - ImageListPanel.width,
                       "the first frame would not fit beside the list")
        second.open([urls[0]])
        XCTAssertTrue(spin(5) { self.panel(second) != nil }, "the list was not built after the first frame")
        XCTAssertEqual(second.displayedFile?.name, "IMG_0000.jpg")
        XCTAssertTrue(second.shownTierForTests.map { $0 >= .screen } == true, "the list was built before the image was sharp")
        let list = try XCTUnwrap(panel(second))
        XCTAssertFalse(list.isHidden)
        XCTAssertEqual(list.files.count, 10)
        second.perform(.imageList)
        XCTAssertFalse(state.isImageListOpen())
        XCTAssertEqual(viewerView(second).frame.width, root.bounds.width)
    }

    /// A headless viewer without a store of its own keeps the state in memory: the test runner's defaults are not
    /// written.
    func testAHeadlessViewerNeverWritesTheDefaults() throws {
        let before = UserDefaults.standard.object(forKey: ViewerUIState.imageListKey) as? Bool
        let store = ConfigStore(url: root.appendingPathComponent("other.toml"))
        let viewer = ViewerWindowController(configStore: store, presentation: .headless)
        defer {
            viewer.window?.close()
            spin(0.05)
        }
        viewer.showEmpty(nil)
        viewer.perform(.imageList)
        XCTAssertTrue(viewer.isImageListOpen)
        viewer.perform(.imageList)
        viewer.perform(.imageList)
        XCTAssertEqual(UserDefaults.standard.object(forKey: ViewerUIState.imageListKey) as? Bool, before)
    }

    // MARK: Following the viewer

    func testTheSelectionFollowsNavigationAndStaysInView() throws {
        let viewer = try makeViewer(makeThumbnail: ThumbnailRecorder().make)
        let urls = writeFolder(400)
        openAndWait(viewer, [urls[0]])
        viewer.perform(.imageList)
        let list = try XCTUnwrap(panel(viewer))
        display(viewer)
        XCTAssertEqual(list.table.numberOfRows, 400)
        for step in 1...3 {
            viewer.perform(.next)
            XCTAssertEqual(list.table.selectedRow, step)
        }
        for action in [Action.last, .jump(-10), .first, .jump(10), .jump(10), .jump(10)] {
            viewer.perform(action)
            display(viewer)
            let row = viewer.pipeline.index
            XCTAssertEqual(list.table.selectedRow, row, action.id)
            XCTAssertEqual(list.table.selectedRowIndexes.count, 1)
            XCTAssertTrue(isOnScreen(list, row), "\(action.id): row \(row) is not in view (\(rowsOnScreen(list)))")
            // The highlight is the row view's own layer (AppKit draws no selection): only the selected row shows it.
            var highlighted: [Int] = []
            list.table.enumerateAvailableRowViews { rowView, index in
                let layer: CALayer? = self.property(rowView, "highlight")
                if layer?.isHidden == false { highlighted.append(index) }
            }
            XCTAssertEqual(highlighted, [row], action.id)
        }
        // Rows are reused: only about a screenful exists, of 400.
        var rowViews = 0
        list.table.enumerateAvailableRowViews { _, _ in rowViews += 1 }
        XCTAssertLessThan(rowViews, 2 * rowsOnScreen(list).count + 8, "\(rowViews) row views for \(rowsOnScreen(list).count) rows on screen")
    }

    func testAClickShowsThatImage() throws {
        let viewer = try makeViewer(makeThumbnail: ThumbnailRecorder().make)
        let urls = writeSequence(12, width: 320, height: 240)
        openAndWait(viewer, [urls[0]])
        viewer.perform(.imageList)
        let list = try XCTUnwrap(panel(viewer))
        display(viewer)
        try click(list, row: 5, in: viewer)
        XCTAssertEqual(viewer.pipeline.index, 5)
        XCTAssertEqual(list.table.selectedRow, 5)
        XCTAssertTrue(spin(5) { viewer.displayedFile?.name == "img05.jpg" }, "\(viewer.displayedFile?.name ?? "nothing") on screen")
        // Keys stay the viewer's.
        XCTAssertFalse(viewer.window?.firstResponder === list.table)
        let right = String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!)
        XCTAssertTrue(viewer.handleKey(keyDown(viewer, keyCode: kVK_RightArrow, characters: right)))
        XCTAssertEqual(viewer.pipeline.index, 6)
        XCTAssertEqual(list.table.selectedRow, 6)
    }

    /// In the picks-only view the list shows the picks (with the photo on screen while it stays); flags follow P and U.
    func testThePicksOnlyViewListsThePicks() throws {
        let viewer = try makeViewer(makeThumbnail: ThumbnailRecorder().make)
        let urls = writeSequence(10, width: 320, height: 240)
        let ops = FileOperations()
        for i in [2, 5, 7] { try ops.setTags(FileOperations.flag("pick", in: FileOperations.tags(of: urls[i])), of: urls[i]) }
        guard FileOperations.isPicked(urls[2]) else { throw XCTSkip("volume does not store Finder tags") }
        openAndWait(viewer, [urls[2]])
        XCTAssertTrue(spin(10) {
            let picks: PickSet? = self.property(viewer, "picks")
            return picks?.isReading == false && picks?.count == 3
        }, "the picks were not read")
        viewer.perform(.imageList)
        let list = try XCTUnwrap(panel(viewer))
        display(viewer)
        let flagged = { Set(self.cells(list).filter(\.isPick).compactMap { $0.file?.name }) }
        XCTAssertEqual(flagged(), ["img02.jpg", "img05.jpg", "img07.jpg"])

        viewer.perform(.picksOnly)
        display(viewer)
        XCTAssertEqual(list.files.map(\.name), ["img02.jpg", "img05.jpg", "img07.jpg"])
        XCTAssertEqual(list.table.numberOfRows, 3)
        XCTAssertEqual(list.table.selectedRow, 0)
        viewer.perform(.next)
        XCTAssertEqual(list.table.selectedRow, 1)
        viewer.perform(.flag("none"))
        display(viewer)
        XCTAssertEqual(flagged(), ["img02.jpg", "img07.jpg"], "the un-picked photo still shows its flag")
        XCTAssertEqual(list.files.map(\.name), ["img02.jpg", "img05.jpg", "img07.jpg"], "it stays until the user moves on")
        viewer.perform(.next)
        display(viewer)
        XCTAssertEqual(list.files.map(\.name), ["img02.jpg", "img07.jpg"])
        XCTAssertEqual(list.table.selectedRow, 1)

        viewer.perform(.picksOnly)
        display(viewer)
        XCTAssertEqual(list.table.numberOfRows, 10)
        XCTAssertEqual(list.table.selectedRow, 7)
        viewer.perform(.previous)
        viewer.perform(.flag("pick"))
        XCTAssertEqual(flagged(), ["img02.jpg", "img06.jpg", "img07.jpg"], "P flags the row in the same turn")
    }

    /// The rows follow a file operation, its undo, files another app adds, and a file saved anew (its thumbnail is made
    /// again, for its new version).
    func testRowsFollowFileOperationsAndRescans() throws {
        let thumbnails = ThumbnailRecorder()
        let viewer = try makeViewer(makeThumbnail: thumbnails.make)
        let urls = writeSequence(6, width: 320, height: 240)
        openAndWait(viewer, [urls[1]])
        viewer.perform(.imageList)
        let list = try XCTUnwrap(panel(viewer))
        display(viewer)
        let names = { list.files.map(\.name) }
        viewer.perform(.move("./_out"))
        display(viewer)
        XCTAssertEqual(names(), ["img00.jpg", "img02.jpg", "img03.jpg", "img04.jpg", "img05.jpg"])
        XCTAssertEqual(list.table.numberOfRows, 5)
        XCTAssertEqual(list.table.selectedRow, 1)
        XCTAssertEqual(Set(cells(list).compactMap { $0.file?.name }), Set(names()), "rows of files that left remain")
        viewer.perform(.undo)
        display(viewer)
        XCTAssertEqual(names(), (0..<6).map { String(format: "img%02d.jpg", $0) })
        XCTAssertEqual(list.table.selectedRow, 1)

        writeImage(folder.appendingPathComponent("img02b.jpg"), width: 320, height: 240, gray: 0.3)
        XCTAssertTrue(spin(30) { names().contains("img02b.jpg") }, "a file another app added is not listed: \(names())")
        display(viewer)
        XCTAssertEqual(names()[3], "img02b.jpg")
        XCTAssertTrue(spin(5) { thumbnails.count("img02b.jpg") == 1 }, "the new row has no thumbnail")

        XCTAssertTrue(spin(10) { thumbnails.count("img03.jpg") >= 1 }, "img03's row has no thumbnail")
        spin(0.2)
        let made = thumbnails.count("img03.jpg")
        // Under memory pressure NSCache evicts on its own, and a row configured again makes its thumbnail again.
        if list.thumbnails.evicted == 0 { XCTAssertEqual(made, 1, "made again for the same version") }
        let before = try XCTUnwrap(list.files.first { $0.name == "img03.jpg" })
        atomicallyReplace(urls[3], width: 640, height: 480, gray: 0.9, type: .jpeg)
        XCTAssertTrue(spin(30) {
            guard let now = list.files.first(where: { $0.name == "img03.jpg" }), now.version != before.version else { return false }
            self.display(viewer)
            return self.cells(list).first { $0.file?.name == "img03.jpg" }
                .map { $0.key == ThumbnailLoader.key(now) && !$0.needsThumbnail } ?? false
        }, "the photo saved anew kept its old thumbnail")
        XCTAssertGreaterThan(thumbnails.count("img03.jpg"), made)
    }

    /// Opening the list shrinks the viewer view and the image refits to it, from the tier on screen: nothing is decoded
    /// again, either way.
    func testTheToggleRefitsWithoutDecodingAgain() throws {
        let viewer = try makeViewer(makeThumbnail: ThumbnailRecorder().make)
        let url = writeImage(folder.appendingPathComponent("photo.jpg"), width: 1600, height: 1000, gray: 0.4)
        openAndWait(viewer, [url])
        XCTAssertTrue(spin(10) { viewer.shownTierForTests.map { $0 >= .screen } ?? false })
        // Until the pipeline has nothing left to decode (a preview of the photo may follow its screen tier).
        var last = -1
        for _ in 0..<30 {
            spin(0.3)
            let now = viewer.pipeline.stats.decodes
            if now == last, viewer.pipeline.queuedDecodes == 0 { break }
            last = now
        }
        let renderer = renderer(viewer)
        let decodes = viewer.pipeline.stats.decodes
        let shown = try XCTUnwrap(renderer.image)
        let fullScale = renderer.effectiveScale
        let width = viewerView(viewer).frame.width
        viewer.perform(.imageList)
        XCTAssertEqual(viewerView(viewer).frame.width, width - ImageListPanel.width)
        XCTAssertLessThan(renderer.effectiveScale, fullScale, "the image did not refit to the narrower view")
        let view = viewerView(viewer).bounds.size, backing = Double(viewer.window?.backingScaleFactor ?? 2)
        let fit = min(Double(view.width) * backing / 1600, Double(view.height) * backing / 1000)
        XCTAssertEqual(renderer.effectiveScale, fit, accuracy: 1e-6, "not fitted to the narrower view")
        XCTAssertTrue(renderer.image?.pixels === shown.pixels, "another tier is on screen")
        spin(0.3)
        viewer.perform(.imageList)
        XCTAssertEqual(renderer.effectiveScale, fullScale, accuracy: 1e-9)
        spin(0.3)
        XCTAssertEqual(viewer.pipeline.stats.decodes, decodes, "the toggle decoded again")
        XCTAssertTrue(renderer.image?.pixels === shown.pixels)
    }

    /// In both full-screen modes the list stays at the right edge (instant full screen: the window has the screen's
    /// size, off every screen when headless).
    func testFullScreenKeepsTheList() throws {
        let viewer = try makeViewer(makeThumbnail: ThumbnailRecorder().make)
        let urls = writeSequence(4, width: 320, height: 240)
        openAndWait(viewer, [urls[0]])
        viewer.perform(.imageList)
        let list = try XCTUnwrap(panel(viewer))
        let window = try XCTUnwrap(viewer.window)
        display(viewer)
        // In a window the rows start below the (transparent) title bar.
        let titleBar = window.frame.height - window.contentLayoutRect.height
        XCTAssertGreaterThan(titleBar, 0)
        XCTAssertEqual(list.scrollView.contentInsets.top, titleBar)
        viewer.perform(.fullscreen)
        display(viewer)
        XCTAssertFalse(window.styleMask.contains(.titled), "not in instant full screen")
        let root = rootView(viewer)
        XCTAssertEqual(root.bounds.size, window.frame.size)
        XCTAssertEqual(list.frame.maxX, root.bounds.maxX)
        XCTAssertEqual(list.frame.width, ImageListPanel.width)
        XCTAssertEqual(list.frame.height, root.bounds.height - root.topInset)
        XCTAssertEqual(viewerView(viewer).frame.width, root.bounds.width - ImageListPanel.width)
        XCTAssertEqual(list.scrollView.contentInsets.top, 0, "a gap where the title bar was")
        viewer.perform(.next)
        XCTAssertEqual(list.table.selectedRow, 1)
        viewer.perform(.fullscreen)
        display(viewer)
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertEqual(viewerView(viewer).frame.width, root.bounds.width - ImageListPanel.width)
        XCTAssertEqual(list.scrollView.contentInsets.top, titleBar)
        assertNothingOnScreen()
    }

    // MARK: Thumbnails

    /// Thumbnails are made off the main thread, two at a time at most, for the rows on screen only; rows that leave
    /// before theirs started take it with them, and those made are not made again.
    func testThumbnailsAreMadeOffTheMainThreadForTheRowsOnScreen() throws {
        let thumbnails = ThumbnailRecorder(delay: 0.02)
        let viewer = try makeViewer(makeThumbnail: thumbnails.make)
        let urls = writeFolder(500)
        openAndWait(viewer, [urls[0]])
        viewer.perform(.imageList)
        let list = try XCTUnwrap(panel(viewer))
        display(viewer)
        let firstScreen = Set(rowsOnScreen(list).map { list.files[$0].name })
        XCTAssertGreaterThan(firstScreen.count, 5)
        XCTAssertTrue(spin(10) { list.thumbnails.pendingCount == 0 }, "\(list.thumbnails.pendingCount) thumbnails still pending")
        let made = thumbnails.made
        XCTAssertFalse(made.contains { $0.onMainThread }, "a thumbnail was made on the main thread")
        XCTAssertEqual(Set(made.map(\.name)), firstScreen, "made for rows that are not on screen")
        XCTAssertLessThanOrEqual(thumbnails.mostAtOnce, ThumbnailLoader.lanes)
        XCTAssertTrue(cells(list).filter { firstScreen.contains($0.file?.name ?? "") }.allSatisfy { !$0.needsThumbnail })

        // Jump far and back at once: the rows that left before their thumbnails started never get one.
        viewer.perform(.last)
        display(viewer)
        viewer.perform(.first)
        display(viewer)
        viewer.perform(.jump(250))
        display(viewer)
        XCTAssertTrue(spin(10) { list.thumbnails.pendingCount == 0 })
        XCTAssertGreaterThan(list.thumbnails.cancelled, 0, "no job was dropped")
        let lastScreen = Set(rowsOnScreen(list).map { list.files[$0].name })
        XCTAssertTrue(lastScreen.isSubset(of: Set(thumbnails.made.map(\.name))))
        XCTAssertLessThan(thumbnails.made.count, firstScreen.count * 4, "thumbnails for rows passed over")
        // Back to the first screen: from the cache (unless memory pressure made NSCache let some go).
        let before = thumbnails.made.count
        viewer.perform(.first)
        display(viewer)
        spin(0.2)
        if list.thumbnails.evicted == 0 {
            XCTAssertEqual(thumbnails.made.count, before, "cached thumbnails were made again")
            for name in firstScreen { XCTAssertEqual(thumbnails.count(name), 1, name) }
        } else {
            print("image list: the cache evicted \(list.thumbnails.evicted) thumbnails (memory pressure), not checked")
        }
    }

    /// No thumbnail starts while the viewer decodes the image on screen; they follow once it is sharp.
    func testThumbnailsWaitForTheImageOnScreen() throws {
        let thumbnails = ThumbnailRecorder()
        let viewer = try makeViewer(makeThumbnail: thumbnails.make)
        let urls = writeSequence(40, width: 2400, height: 1600)
        openAndWait(viewer, [urls[0]])
        XCTAssertTrue(spin(10) { viewer.shownTierForTests.map { $0 >= .screen } ?? false })
        viewer.perform(.imageList)
        let list = try XCTUnwrap(panel(viewer))
        display(viewer)
        XCTAssertTrue(spin(10) { list.thumbnails.pendingCount == 0 })
        // The last photo is far beyond the prefetch: its decode starts with the key press.
        viewer.perform(.last)
        // The photo before stays on screen until the last one has pixels.
        let sharp = { viewer.displayedFile?.name == "img39.jpg" && viewer.shownTierForTests.map { $0 >= .screen } == true }
        try XCTSkipIf(sharp(), "the last photo was decoded already")
        XCTAssertTrue(list.thumbnails.isPaused, "thumbnails may start beside the decode of the image on screen")
        let made = thumbnails.made.count
        display(viewer)
        XCTAssertEqual(thumbnails.made.count, made)
        XCTAssertTrue(spin(10, until: sharp))
        XCTAssertFalse(list.thumbnails.isPaused)
        XCTAssertTrue(spin(10) { thumbnails.count("img39.jpg") >= 1 }, "the rows on screen got no thumbnails")
    }

    /// A file the viewer holds a preview of (its sweep decodes them around the image on screen) gets its thumbnail from
    /// that preview, not from the file.
    func testThumbnailsComeFromTheViewersPreviews() throws {
        let thumbnails = ThumbnailRecorder()
        let viewer = try makeViewer(makeThumbnail: thumbnails.make)
        let urls = writeSequence(8, width: 1200, height: 800)
        openAndWait(viewer, [urls[0]])
        let previews = { viewer.pipeline.files.filter { viewer.pipeline.preview(for: $0) != nil }.count }
        XCTAssertTrue(spin(10) { previews() >= 7 }, "the sweep made \(previews()) previews")
        let held = previews()
        viewer.perform(.imageList)
        let list = try XCTUnwrap(panel(viewer))
        display(viewer)
        XCTAssertTrue(spin(10) { list.thumbnails.pendingCount == 0 && thumbnails.made.count == 8 })
        XCTAssertGreaterThanOrEqual(thumbnails.made.filter(\.fromPreview).count, held,
                                    "made from the files: \(thumbnails.made.filter { !$0.fromPreview }.map(\.name))")
        XCTAssertEqual(list.thumbnails.madeFromPreviews, thumbnails.made.filter(\.fromPreview).count)
    }

    /// The real thumbnails reach the rows: small images, from the embedded previews or the viewer's.
    func testRowsShowTheirThumbnails() throws {
        let viewer = try makeViewer()
        let urls = writeSequence(5, width: 900, height: 600)
        openAndWait(viewer, [urls[0]])
        viewer.perform(.imageList)
        let list = try XCTUnwrap(panel(viewer))
        display(viewer)
        XCTAssertTrue(spin(10) { list.thumbnails.made >= 5 && self.cells(list).allSatisfy { !$0.needsThumbnail } },
                      "rows without thumbnails")
        XCTAssertEqual(cells(list).count, 5)
        for cell in cells(list) {
            let layer: CALayer = try XCTUnwrap(property(cell, "thumbnail"))
            let contents = try XCTUnwrap(layer.contents, cell.file?.name ?? "?")
            XCTAssertEqual(CFGetTypeID(contents as CFTypeRef), CGImage.typeID)
            let image = contents as! CGImage
            XCTAssertEqual(max(image.width, image.height), ImageListPanel.thumbnailPixels, cell.file?.name ?? "?")
            XCTAssertEqual(image.colorSpace?.name, CGColorSpace.displayP3)
        }
    }

    // MARK: The key, the menu, the help

    func testTheKeyTheMenuAndTheHelpShowTheList() throws {
        XCTAssertEqual(KeyLabels.menuChord(for: .imageList, in: Keymap.default), KeyChord(key: "t"))
        XCTAssertEqual(KeyLabels.title(.imageList), "Show Image List")
        let view = try XCTUnwrap(KeyLabels.helpSections(Keymap.default).first { $0.title == "View" })
        XCTAssertTrue(view.lines.contains { $0.keys == "T" && $0.title == "Show Image List" }, "\(view.lines)")
        let menu = MainMenu.make(keymap: Keymap.default, target: NSObject())
        let viewMenu = try XCTUnwrap(menu.items.first { $0.title == "View" }?.submenu)
        let item = try XCTUnwrap(viewMenu.items.first { ($0.representedObject as? ActionBox)?.action == .imageList })
        XCTAssertEqual(item.title, "Show Image List")
        XCTAssertEqual(item.keyEquivalent, "t")
        XCTAssertEqual(item.keyEquivalentModifierMask, [])

        // `t` toggles it in a viewer, and the menu item's check mark follows.
        let viewer = try makeViewer()
        let urls = writeSequence(2, width: 320, height: 240)
        openAndWait(viewer, [urls[0]])
        XCTAssertTrue(viewer.handleKey(keyDown(viewer, keyCode: kVK_ANSI_T, characters: "t")))
        XCTAssertTrue(viewer.isImageListOpen)
        XCTAssertTrue(viewer.canPerform(.imageList, plainKeyEquivalent: false, keyWindow: nil))
        XCTAssertTrue(viewer.handleKey(keyDown(viewer, keyCode: kVK_ANSI_T, characters: "t")))
        XCTAssertFalse(viewer.isImageListOpen)
    }

    // MARK: Speed

    /// Rule #1: with the list open a change of image costs the main thread what it costs without it (one row selected
    /// and scrolled into view). Measured with the window's layout and display pass and the Core Animation commit.
    func testNavigationCostsTheSameWithTheListOpen() throws {
        let viewer = try makeViewer()
        let urls = writeSequence(60, width: 1600, height: 1067)
        openAndWait(viewer, [urls[0]])
        let window = try XCTUnwrap(viewer.window)
        func measure() -> Double {
            spin(1)
            var times: [Double] = []
            for action in [Action.next, .previous] {
                for _ in 0..<20 {
                    let started = Trace.now()
                    viewer.perform(action)
                    window.displayIfNeeded()
                    CATransaction.flush()
                    times.append(Trace.ms(since: started))
                    spin(0.15)
                }
            }
            return times.sorted()[times.count / 2]
        }
        let closed = measure()
        viewer.perform(.imageList)
        let open = measure()
        viewer.perform(.imageList)
        let closedAgain = measure()
        print(String(format: "navigation main thread (median of 40): list closed %.3f ms, open %.3f ms, closed again %.3f ms",
                     closed, open, closedAgain))
        // Against the slower closed phase: the two differ by a few tenths of a millisecond on a busy Mac.
        let reference = max(closed, closedAgain)
        XCTAssertLessThan(open, max(2 * reference, reference + 1), "a navigation costs more with the list open")
    }

    /// The list opens quickly (built, then a screenful of rows) on 5,000 images, and toggles (a resize and a refit)
    /// in a few milliseconds.
    func testOpeningAndTogglingTheListIsQuick() throws {
        let viewer = try makeViewer(makeThumbnail: ThumbnailRecorder().make)
        let urls = writeFolder(5000)
        openAndWait(viewer, [urls[0]])
        display(viewer)
        spin(0.5)
        let window = try XCTUnwrap(viewer.window)
        var started = Trace.now()
        viewer.perform(.imageList)
        window.displayIfNeeded()
        CATransaction.flush()
        let firstMs = Trace.ms(since: started)
        let list = try XCTUnwrap(panel(viewer))
        XCTAssertEqual(list.table.numberOfRows, 5000)
        var toggles: [Double] = []
        for _ in 0..<10 {
            spin(0.1)
            started = Trace.now()
            viewer.perform(.imageList)
            window.displayIfNeeded()
            CATransaction.flush()
            toggles.append(Trace.ms(since: started))
        }
        // From the first image to the last: one row selected and scrolled into view, the rows reused.
        spin(0.1)
        started = Trace.now()
        viewer.perform(.last)
        window.displayIfNeeded()
        CATransaction.flush()
        let lastMs = Trace.ms(since: started)
        var rowViews = 0
        list.table.enumerateAvailableRowViews { _, _ in rowViews += 1 }
        print(String(format: "image list on 5,000 images: first open %.2f ms, toggle median %.2f ms (min %.2f, max %.2f), "
                     + "first → last image %.2f ms, %d row views", firstMs, toggles.sorted()[toggles.count / 2],
                     toggles.min() ?? 0, toggles.max() ?? 0, lastMs, rowViews))
        XCTAssertLessThan(firstMs, 250, "a regression guard: ~10 ms on an M4 Pro")
        XCTAssertLessThan(toggles.sorted()[toggles.count / 2], 100)
        XCTAssertLessThan(rowViews, 100)
        XCTAssertEqual(list.table.selectedRow, 4999)
    }
}
