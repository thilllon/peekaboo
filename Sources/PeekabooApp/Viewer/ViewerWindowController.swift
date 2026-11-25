import AppKit
import PeekabooCore
import PeekabooRender

/// Borderless windows cannot become key by default; instant full screen needs them to.
final class ViewerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// One rendered frame, for tracing and the self-test.
struct FrameRecord {
    /// File whose pixels the frame shows (nil = background only).
    let file: ImageFile?
    let tier: Tier?
    /// `Trace.now()` right after the frame was encoded and committed.
    let committed: UInt64
}

/// Finder tags of a file as the HUD shows them (stars, colour label, pick/reject).
struct FileTags: Equatable {
    var names: [String] = []
    var labelNumber = 0

    /// HUD text, e.g. `★★★ ⚑ Pick ● Red` (computed once when the tags are read).
    var summary: String {
        guard !names.isEmpty || labelNumber != 0 else { return "" }
        var parts: [String] = []
        // Stars are a tag made of 1–5 copies of one symbol (★ by default, configurable).
        if let stars = names.first(where: { name in
            guard let c = name.first, name.count <= 5, !c.isLetter, !c.isNumber else { return false }
            return name.allSatisfy { $0 == c }
        }) { parts.append(stars) }
        if names.contains("Pick") { parts.append("⚑ Pick") }
        if names.contains("Reject") { parts.append("✕ Reject") }
        let labels = Self.labelNames
        if labelNumber > 0, labelNumber < labels.count {
            parts.append("● \(labels[labelNumber])")
        } else if let color = names.first(where: { labels.dropFirst().contains($0) }) {
            parts.append("● \(color)")
        }
        return parts.joined(separator: " ")
    }

    /// Localized Finder label names (index = label number); read once.
    static let labelNames = NSWorkspace.shared.fileLabels
}

/// One viewer window: owns the renderer, the pipeline and the browsing state, turns key
/// presses, gestures and menu items into actions, and draws the HUD above the image.
final class ViewerWindowController: NSWindowController, NSWindowDelegate, ViewerViewDelegate {
    private enum BrowseSource { case none, folder(URL), files }

    private let rootView: ViewerRootView
    private let viewerView: ViewerView
    private let renderer: Renderer
    let pipeline: ImagePipeline
    private let configStore: ConfigStore
    private var config: AppConfig { configStore.config }
    private lazy var fileActions: FileActions = {
        let actions = FileActions { [weak self] in self?.configStore.config ?? .default }
        // Work that finishes later (exec:, open-with, make-default) still updates the list and shows its toast.
        actions.onLateResult = { [weak self] result in self?.handle(result) }
        return actions
    }()
    private let hud: HUD
    private lazy var gate = InteractionGate(
        begin: { [weak self] in self?.renderer.beginInteraction() },
        end: { [weak self] in
            self?.renderer.endInteraction()
            self?.afterGeometryChange()
        })
    private lazy var motion = MotionDriver(view: viewerView)
    /// Paces the animation on screen (idle for stills).
    private let animationClock: AnimationClock
    /// The animated image on screen plays here; nil for stills, which pay nothing.
    private var player: AnimationPlayer?
    /// Frame of `player` on screen (nil: the pipeline's still of frame 0).
    private var shownFrame: Int?
    /// Playback paused because the window is hidden, occluded or minimised: it resumes when the window is visible.
    private var pausedWhileHidden = false
    /// Starts the animation on screen once a skim past it is over.
    private var startAnimationWork: DispatchWorkItem?
    /// When the full HUD last showed a playing frame: it follows playback at most 10 times a second.
    private var frameHUDUpdated: UInt64 = 0

    /// Open requests from the window (drag & drop) and the `app.open` action.
    var onOpenURLs: (([URL]) -> Void)?
    var onOpenPanel: (() -> Void)?

    private var pendingChords: [KeyChord] = []
    private var keyMonitor: Any?
    /// File currently on screen and the tier shown for it (nil with a file: its error is shown).
    private var shownFile: ImageFile?
    private var shownTier: Tier?
    /// The shown tier is an early rendition (`DecodedImage.isApproximate`): its exact decode replaces it.
    private var shownApproximate = false
    /// Version of the shown file's contents (nil = not known: opened before its folder was listed).
    private var shownVersion: String?
    /// Bumped when the shown file's contents change on disk, so the renderer treats the new version as another image.
    private var contentRevision = 0
    /// Neighbours not prepared while skimming are prepared when the skim ends.
    private var prepareAfterSkim: DispatchWorkItem?

    // Browsing
    private var browseSource = BrowseSource.none
    private var openGeneration = 0
    private var listingPending = false
    /// One folder rescan at a time (concurrent ones could finish out of order); changes meanwhile list again after it.
    private var rescanInFlight = false
    private var rescanQueued = false
    /// Bumped when a file action changes the browsing set here: a listing started before it is stale.
    private var listingEpoch = 0
    /// The opened file when its folder's listing does not include it (a type the scan skips, a hidden file): it stays
    /// in the set while it is on screen.
    private var unlistedFile: ImageFile?
    /// Files without pixels whose decode failed (the pipeline never retries them), for the version that failed.
    private var failures: [URL: Failure] = [:]
    private struct Failure {
        let version: String?
        let reason: String
    }
    private var tags: [URL: FileTags] = [:]
    private var tagSummaries: [URL: String] = [:]
    private var loadingWork: DispatchWorkItem?
    private var navigationStart: UInt64 = 0
    private var lastAppliedHUDMode: AppConfig.HUDMode?
    private var lastAppliedBackground: String?
    private var lastAppliedKeepZoom: Bool?
    /// Re-lists the browsed folder when Finder (or anything else) adds, removes or renames files.
    private var folderWatcher: FolderWatcher?

    /// True while the app is still launching (until `applicationDidFinishLaunching`): `open` then lists the folder,
    /// waits for the first tier on the main thread and presents it at once, because AppKit's launch does not
    /// service the main queue for ~70 ms (`finishLaunching`, the open-documents event).
    var presentsSynchronously = false

    // Full screen and chrome
    private var instantFullscreen: (frame: NSRect, style: NSWindow.StyleMask)?
    private var lastPointerMove: UInt64 = 0
    private var idleTimer: Timer?
    private var chromeHidden = false

    // Gestures
    private var magnifying = false
    private var dragging = false
    private var dragVelocity = CGVector.zero
    private var lastDragEvent: UInt64 = 0

    // Rendering
    private var renderScheduled = false
    private var frameCounter = 0
    private var frames: [Int: FrameRecord] = [:]
    /// Observers for the self-test / tracing (main thread). Presentation time is `CACurrentMediaTime`-based; 0 = dropped.
    var onFramePresented: ((FrameRecord, CFTimeInterval) -> Void)?
    var onFrameCommitted: ((FrameRecord) -> Void)?
    /// Attach presented handlers to every drawable (on with `PEEKABOO_TRACE=1` and in the self-test).
    var tracksFrames = false { didSet { configureFrameTracking() } }

    private var memoryPressure: DispatchSourceMemoryPressure?
    /// The window is closed and the app stays resident: the pipeline keeps a small cache and decodes nothing ahead
    /// until the next open (`pipelineConfig(_:base:closed:)`).
    private var isClosed = false
    private var observers: [NSObjectProtocol] = []
    private var lastTitle = ""
    private var pendingTitle: String?

    init(configStore: ConfigStore) {
        self.configStore = configStore
        NSWindow.allowsAutomaticWindowTabbing = false
        let window = ViewerWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.animationBehavior = .none
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.setFrameAutosaveName("PeekabooViewer")
        if window.frame.origin == .zero { window.center() }

        rootView = ViewerRootView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
        viewerView = rootView.viewerView
        window.contentView = rootView
        renderer = Renderer(layer: viewerView.metalLayer)
        hud = HUD(parent: viewerView.overlayLayer)
        animationClock = AnimationClock(view: viewerView)
        let pool = PixelBufferPool(device: RenderContext.shared.device)
        let pipelineConfig = Self.pipelineConfig(
            configStore.config, base: PipelineConfig(screenLongSide: Self.largestScreenLongSide()))
        pipeline = ImagePipeline(decoder: ImageIODecoder(), pool: pool, config: pipelineConfig)
        super.init(window: window)
        window.delegate = self
        rootView.delegate = self
        viewerView.delegate = self
        renderer.onNeedsDisplay = { [weak self] in self?.setNeedsRender() }
        pipeline.onDecoded = { [weak self] file, image in self?.decoded(image, for: file) }
        pipeline.onFailed = { [weak self] file, error in self?.failed(file, error) }
        motion.viewport = { [weak self] in self?.viewerView.bounds.size ?? CGSize(width: 1000, height: 700) }
        motion.onPan = { [weak self] delta in
            guard let self else { return }
            self.renderer.pan(by: delta)
            self.renderFrame()
        }
        motion.onActiveChanged = { [weak self] active in
            if active { self?.gate.acquire() } else { self?.gate.release() }
        }
        animationClock.onTick = { [weak self] target, period in self?.animationTick(target: target, period: period) }
        installKeyMonitor()
        installSystemObservers()
        tracksFrames = Trace.enabled
        apply(configStore.config)
        viewerViewDidResize(viewerView)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        memoryPressure?.cancel()
        motion.invalidate()
        animationClock.invalidate()
        player?.stop()
    }

    /// Apply a (re)loaded configuration.
    func apply(_ config: AppConfig) {
        // Only a changed value overrides what the user picked at run time (`zoom.keep`, `view.background`, `view.hud`).
        if lastAppliedKeepZoom != config.keepZoom {
            lastAppliedKeepZoom = config.keepZoom
            renderer.keepZoom = config.keepZoom
        }
        if lastAppliedBackground != config.background {
            lastAppliedBackground = config.background
            renderer.settings.background = Background(rawValue: config.background) ?? .black
        }
        let refine = Double(max(config.refineDelayMs, 0))
        if renderer.settings.refineDelayMs != refine { renderer.settings.refineDelayMs = refine }
        if lastAppliedHUDMode != config.hud {
            hud.mode = config.hud
            lastAppliedHUDMode = config.hud
        }
        applyPipelineConfig(config)
        if hud.isHelpVisible { hud.setHelp(KeyLabels.helpSections(config.keymap)) }
        if instantFullscreen != nil, let screen = window?.screen { rootView.topInset = notchInset(screen) }
        updateHUD()
    }

    /// Show a toast (e.g. a config error).
    func toast(_ text: String) { hud.showToast(text) }

    /// The pipeline configuration for `config` and the window state.
    private func applyPipelineConfig(_ config: AppConfig) {
        let pipelineConfig = Self.pipelineConfig(config, base: pipeline.config, closed: isClosed)
        if pipelineConfig != pipeline.config { pipeline.updateConfig(pipelineConfig) }
    }

    /// The window is showing again: back to the full cache budgets and prefetch.
    private func wakeFromClosed() {
        guard isClosed else { return }
        isClosed = false
        applyPipelineConfig(config)
    }

    // MARK: Opening

    /// Show `urls`: one file browses its folder, a folder browses its images, several files browse that set.
    func open(_ urls: [URL]) {
        guard let first = urls.first else { return }
        wakeFromClosed()
        if urls.count == 1, let index = indexInBrowsingSet(first) {
            openWithinBrowsingSet(index)
            return
        }
        let opened = Trace.now()
        openGeneration += 1
        let generation = openGeneration
        failures.removeAll()
        unlistedFile = nil
        listingPending = true
        // First pixel first: decode the opened file before listing its folder, and submit that decode before the
        // window is ordered in and flushed (window-server work it can overlap). Decide "file or folder" from the URL
        // alone (no file-system access on the main thread). A file of a type the folder listing skips (an SVG, a
        // document) is opened as itself too: it shows its error, not another image of its folder.
        let singleFile = urls.count == 1 && !first.hasDirectoryPath
        if singleFile {
            browseSource = .folder(first.deletingLastPathComponent())
            beginNavigation()
            replaceFiles([Self.placeholder(for: first)], index: 0)
        } else {
            browseSource = urls.count == 1 ? .folder(first) : .files
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        hud.setMessage(nil)
        let synchronous = presentsSynchronously
        if synchronous {
            // Hand the window to the window server now, so the first frame can reach the glass before AppKit
            // finishes launching.
            CATransaction.flush()
        }
        if singleFile {
            presentCurrent()
            if synchronous { presentFirstFrameNow() }
        } else if synchronous {
            // Launched with a folder: list it in this turn (getattrlistbulk, ≈ 0.2 ms per 100 files) instead of
            // in a main-queue turn that AppKit's launch delays by ~70 ms.
            applyListing(try? FolderScanner.browse(urls), urls: urls, singleFile: false, opened: opened)
            presentFirstFrameNow()
            return
        }
        updateHUD()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let listing = try? FolderScanner.browse(urls)
            DispatchQueue.main.async {
                guard let self, generation == self.openGeneration else { return }
                self.applyListing(listing, urls: urls, singleFile: singleFile, opened: opened)
            }
        }
    }

    private func applyListing(_ listing: (files: [ImageFile], index: Int)?, urls: [URL], singleFile: Bool, opened: UInt64) {
        listingPending = false
        guard let listing, !listing.files.isEmpty else {
            // An unreadable parent folder still shows the opened file on its own.
            if singleFile {
                updateHUD()
            } else {
                showEmpty(urls.count == 1 ? urls.first : nil)
            }
            watchFolder()
            return
        }
        var files = listing.files
        var index = listing.index
        if singleFile, let url = urls.first,
           !(files.indices.contains(index) && files[index].url.standardizedFileURL == url.standardizedFileURL) {
            // The opened file is not in its folder's listing (a type the scan skips, a hidden file, a path typed in
            // another letter case): it stays on screen, among the folder's images.
            let file = Self.placeholder(for: url)
            files = NaturalSort.sort(files + [file], by: \.name)
            index = files.firstIndex(of: file) ?? 0
            unlistedFile = file
        }
        let previous = pipeline.currentFile
        replaceFiles(files, index: index)
        if let file = pipeline.currentFile, let version = Self.knownVersion(file) {
            // The opened file was shown (or failed) before its version was known; the pipeline keeps its tiers as
            // that version, and so does the view.
            if shownFile == file, shownVersion == nil { shownVersion = version }
            if let failure = failures[file.url], failure.version == nil {
                failures[file.url] = Failure(version: version, reason: failure.reason)
            }
        }
        if pipeline.currentFile != previous { beginNavigation() }
        presentCurrent()
        updateHUD()
        watchFolder()
        Trace.log("folder listed: \(listing.files.count) files, \(String(format: "%.1f", Trace.ms(since: opened))) ms after open")
    }

    /// The opened file before its folder is listed (size, date and inode not known yet).
    private static func placeholder(for url: URL) -> ImageFile {
        ImageFile(url: url, name: url.lastPathComponent, byteSize: 0, modified: 0, fileID: 0)
    }

    /// Index of `url` in the browsing set when it is a listed file of the folder being browsed.
    private func indexInBrowsingSet(_ url: URL) -> Int? {
        guard !listingPending, isInBrowsedFolder(url) else { return nil }
        let name = url.lastPathComponent
        return pipeline.files.firstIndex { $0.name == name }
    }

    /// Finder (or a drop) opened another file of the folder being browsed: navigate to it and keep the listing and
    /// the cache, instead of starting over (which would free the cache on the main thread and decode it all again).
    private func openWithinBrowsingSet(_ index: Int) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if index != pipeline.index {
            navigate(to: index, isRepeat: false)
        } else {
            presentCurrent()
            renderFrame()
            updateHUD()
        }
        // Pick up what the folder watcher cannot see (in-place edits while the window was closed).
        rescanFolder()
        Trace.log("opened \(pipeline.currentFile?.name ?? "?") within the browsed folder")
    }

    /// Replace the whole browsing set. The pixels it drops are freed off the main thread, 250 ms later (after the new
    /// set's first frames).
    private func replaceFiles(_ files: [ImageFile], index: Int) {
        let dropped = DeferredRelease(cachedImages())
        pipeline.setFiles(files, index: index)
        dropped.release(after: 0.25)
    }

    /// Smallest cache whose release is moved off the main thread: below it, freeing is cheaper than the scan that
    /// collects it (≈ 1.2 ms per 10k files). Internal for tests.
    var offMainReleaseMinimumBytes = 64 << 20

    /// The best tier of every cached file: what replacing the set or trimming the cache may free (a lower tier of the
    /// same file is small or rare).
    private func cachedImages() -> [DecodedImage] {
        guard pipeline.stats.cachedBytes >= offMainReleaseMinimumBytes else { return [] }
        return pipeline.files.compactMap { pipeline.best(for: $0) }
    }

    /// Launch fast path: wait (bounded) for the first tier of the current file and present it in this run-loop turn.
    private func presentFirstFrameNow() {
        guard shownFile == nil, let file = pipeline.currentFile else { return }
        let start = Trace.now()
        // `onDecoded` → `show` → `renderFrame` runs inside the wait.
        let ready = pipeline.waitForCurrent(timeout: 0.25)
        if ready, !isShowing(file) { presentCurrent() }
        CATransaction.flush()
        Trace.log(String(format: "launch: first tier %@ after a %.1f ms main-thread wait",
                         ready ? "presented" : "not ready", Trace.ms(since: start)))
    }

    /// Nothing to show: an empty folder, or no file opened yet.
    func showEmpty(_ folder: URL?) {
        stopAnimation()
        replaceFiles([], index: 0)
        shownFile = nil
        shownTier = nil
        shownApproximate = false
        shownVersion = nil
        renderer.setImage(nil, key: nil)
        setLoading(false)
        renderFrame()
        if let folder {
            hud.setMessage("No images in “\(folder.lastPathComponent)”\nDrop images here or press ⌘O")
        } else {
            hud.setMessage("Drop images or a folder here\nor press ⌘O to open")
        }
        updateHUD()
        showWindow(nil)
    }

    /// Re-show the window (Dock click) with the last image.
    func reopen() {
        wakeFromClosed()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if pipeline.currentFile == nil, shownFile == nil {
            showEmpty(nil)
        } else {
            presentCurrent()   // an animation closed with the window shows its still again and plays from there
            renderFrame()
        }
    }

    // MARK: Pipeline → screen

    private func decoded(_ image: DecodedImage, for file: ImageFile) {
        // Pixels arrived (another tier, or a new version of the file): it is no longer a failure.
        let hadFailed = failures.removeValue(forKey: file.url) != nil
        guard file == pipeline.currentFile else {
            prepareIfNeighbour(image, for: file)
            return
        }
        if hadFailed { hud.setMessage(nil) }
        if isShowing(file), let shownTier, !Self.improves(image, on: shownTier, approximate: shownApproximate) {
            updateHUD()
            return
        }
        show(image, for: file)
    }

    /// Whether `image` is better than the shown tier: a higher tier, or the exact decode of an early rendition.
    static func improves(_ image: DecodedImage, on tier: Tier, approximate: Bool) -> Bool {
        image.tier > tier || (image.tier == tier && approximate && !image.isApproximate)
    }

    /// Version of `file`'s contents; nil when not known (a file opened before its folder was listed).
    private static func knownVersion(_ file: ImageFile) -> String? {
        file.byteSize == 0 && file.modified == 0 ? nil : file.version
    }

    /// The screen shows `file` as it is now: that file (its pixels, or its error), and no other version of its
    /// contents was listed since (an edit saved in another app replaces the file under the same URL).
    private func isShowing(_ file: ImageFile) -> Bool {
        guard shownFile == file else { return false }
        guard let shownVersion, let version = Self.knownVersion(file) else { return true }
        return shownVersion == version
    }

    /// Put `image` (nil: nothing, for an error) of `file` on the renderer and record it as shown.
    private func setShown(_ file: ImageFile, _ image: DecodedImage?) {
        // A new version of the file on screen is another image to the renderer: it must not keep the old version's
        // geometry, texture or canvas while the new one's pyramid builds.
        if shownFile == file, !isShowing(file) { contentRevision &+= 1 }
        // Another file, another version of it, or its error: the animation on screen ends.
        if let player, player.url != file.url || !isShowing(file) || image == nil { stopAnimation() }
        renderer.setImage(image, key: RenderKey(url: file.url, revision: contentRevision))
        shownFile = file
        shownTier = image?.tier
        shownApproximate = image?.isApproximate ?? false
        shownVersion = Self.knownVersion(file)
    }

    // Both fields are read by the synthesized Hashable conformance (periphery reports them as assign-only).
    private struct RenderKey: Hashable {
        let url: URL
        let revision: Int
    }

    /// Neighbours whose GPU resources (texture, colour transform, pyramid) are built ahead of navigation: ±1 and the
    /// next-but-one in the direction of travel. With the image on screen that is the renderer's limit of 4 prepared
    /// images, so preparing never evicts what the next key press will show.
    private func neighbourOffsets() -> [Int] {
        let direction = pipeline.navigation.direction >= 0 ? 1 : -1
        return [direction, -direction, 2 * direction]
    }

    /// Neighbours are prepared only once the current image shows a sharp tier: until then the renderer's LRU still
    /// holds the current preview, which it draws while the screen tier's pyramid builds.
    private var currentIsSharp: Bool {
        guard let file = pipeline.currentFile, isShowing(file), let tier = shownTier else { return false }
        return tier >= .screen && !shownApproximate
    }

    private func prepareIfNeighbour(_ image: DecodedImage, for file: ImageFile) {
        guard image.tier != .preview, currentIsSharp else { return }
        let files = pipeline.files
        let isNeighbour = neighbourOffsets().contains { offset in
            let j = pipeline.index + offset
            return files.indices.contains(j) && files[j] == file
        }
        guard isNeighbour else { return }
        guard !pipeline.isSkimming else {
            prepareNeighboursWhenSkimEnds()
            return
        }
        // Only the best sharp tier (a late screen tier after a `.full` would be prepared for nothing).
        guard let best = pipeline.best(for: file), best.pixels === image.pixels else { return }
        renderer.prepare(image)
    }

    /// After the current image is shown: prepare the sharp tiers of the neighbours that are already decoded (the
    /// farthest first, so the next image is the most recently used entry of the renderer's LRU).
    private func prepareNeighbours() {
        guard currentIsSharp else { return }
        guard !pipeline.isSkimming else {
            prepareNeighboursWhenSkimEnds()
            return
        }
        let files = pipeline.files
        for offset in neighbourOffsets().reversed() {
            let j = pipeline.index + offset
            guard files.indices.contains(j), let best = pipeline.best(for: files[j]), best.tier != .preview else { continue }
            renderer.prepare(best)
        }
    }

    /// While skimming nothing is prepared (the cursor moves on before it would pay off), and no decode may land
    /// afterwards for a neighbour cached before or during the skim: prepare once the skim is over
    /// (`skimIntervalMs` after the last navigation), or again later if the user is still skimming then.
    private func prepareNeighboursWhenSkimEnds() {
        guard prepareAfterSkim == nil else { return }
        let sinceNav = pipeline.navigation.msSinceNav(now: Trace.now())
        let remainingMs = min(max(pipeline.config.tuning.skimIntervalMs - sinceNav, 0), 1000)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.prepareAfterSkim = nil
            self.prepareNeighbours()
        }
        prepareAfterSkim = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(remainingMs.rounded(.up)) + 2), execute: work)
    }

    private func failed(_ file: ImageFile, _ error: Error) {
        Trace.log("decode failed \(file.name): \(error)")
        // Another tier (a preview) is still worth showing; only a file without any pixels has failed.
        guard pipeline.best(for: file) == nil else { return }
        // Recorded for every file, current or prefetched: the pipeline never retries it (and never reports it again),
        // so reaching it later must show this error.
        let reason = Self.failureReason(error, file: file)
        failures[file.url] = Failure(version: Self.knownVersion(file), reason: reason)
        guard file == pipeline.currentFile else { return }
        showFailure(file, reason: reason)
    }

    private static func failureReason(_ error: Error, file: ImageFile) -> String {
        func detail(_ s: String, _ generic: String) -> String {
            s.isEmpty || s == file.name || s == file.url.path ? generic : "\(generic) (\(s))"
        }
        switch error as? DecodeError {
        case .unsupported(let s)?: return detail(s, "Unsupported format")
        case .unreadable(let s)?: return detail(s, "Damaged file or not an image")
        case .outOfMemory?: return "Not enough memory to decode it"
        case nil: return error.localizedDescription
        }
    }

    /// Why `file` (as it is now) cannot be shown, if its decode failed.
    private func failureReason(for file: ImageFile) -> String? {
        guard let failure = failures[file.url] else { return nil }
        if let failed = failure.version, let version = Self.knownVersion(file), failed != version { return nil }
        return failure.reason
    }

    /// `file` has no pixels and cannot be decoded: show its error, and never the previous image under its name.
    private func showFailure(_ file: ImageFile, reason: String) {
        if !isShowing(file) || shownTier != nil {
            setShown(file, nil)
            setLoading(false)
            renderFrame()
        }
        hud.setMessage("Cannot open “\(file.name)”\n\(reason)")
        updateHUD()
    }

    private func show(_ image: DecodedImage, for file: ImageFile) {
        let wasNewFile = !isShowing(file)
        let t0 = Trace.now()
        setShown(file, image)
        setLoading(false)
        if failureReason(for: file) == nil { hud.setMessage(nil) }
        let t1 = Trace.now()
        renderFrame()
        let t2 = Trace.now()
        requestFullResolutionIfNeeded()
        prepareNeighbours()
        startAnimationIfNeeded(file)
        updateHUD()
        if Trace.enabled {
            Trace.log(String(format: "show main thread: setImage %.3f  render %.3f  hud %.3f ms",
                             Double(t1 &- t0) / 1e6, Double(t2 &- t1) / 1e6, Double(Trace.now() &- t2) / 1e6))
            Trace.log("shown \(file.name) tier=\(image.tier) \(image.pixels.width)x\(image.pixels.height) decode=\(String(format: "%.1f", Double(image.decodeNanos) / 1e6)) ms\(wasNewFile ? String(format: " +%.2f ms after nav", Trace.ms(since: navigationStart)) : "")")
        }
    }

    /// Show the best tier of the current file now (or its error), or keep the previous image and arm the progress line.
    private func presentCurrent() {
        guard let file = pipeline.currentFile else { return }
        if let best = pipeline.best(for: file) {
            if !isShowing(file) || shownTier.map({ Self.improves(best, on: $0, approximate: shownApproximate) }) ?? true {
                show(best, for: file)
            }
        } else if let reason = failureReason(for: file) {
            showFailure(file, reason: reason)
        } else if !isShowing(file) {
            armLoadingIndicator(for: file)
        }
        loadTags(for: file)
    }

    private func beginNavigation() { navigationStart = Trace.now() }

    private func navigate(to index: Int, isRepeat: Bool) {
        guard !pipeline.files.isEmpty else { return }
        let target = min(max(index, 0), pipeline.files.count - 1)
        if target != index, target == pipeline.index {
            hud.showToast(index < 0 ? "First image" : "Last image")
            return
        }
        guard target != pipeline.index || shownFile == nil else { return }
        beginNavigation()
        pipeline.navigate(to: target, isRepeat: isRepeat)
        let t1 = Trace.now()
        presentCurrent()
        let t2 = Trace.now()
        // Title and HUD switch to the target in the same run-loop turn (same frame) as the swap.
        updateHUD()
        if Trace.enabled {
            let t3 = Trace.now()
            Trace.log(String(format: "nav main thread: pipeline %.3f  present %.3f  hud %.3f ms",
                             Double(t1 &- navigationStart) / 1e6, Double(t2 &- t1) / 1e6, Double(t3 &- t2) / 1e6))
        }
    }

    private func armLoadingIndicator(for file: ImageFile) {
        loadingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pipeline.currentFile == file, !self.isShowing(file) else { return }
            self.hud.setLoading(true)
            Trace.log("progress line: \(file.name) has no pixels 150 ms after navigation")
        }
        loadingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func setLoading(_ loading: Bool) {
        if !loading { loadingWork?.cancel(); loadingWork = nil }
        hud.setLoading(loading)
    }

    // MARK: HUD

    private func updateHUD() {
        guard let file = pipeline.currentFile else {
            hud.setContent(HUDContent())
            setTitle("Peekaboo")
            return
        }
        let index = listingPending ? "…" : "\(pipeline.index + 1)"
        let count = listingPending ? "…" : "\(pipeline.files.count)"
        var parts = [file.name, "\(index)/\(count)"]
        let info = pipeline.info(for: file)
        let onScreen = isShowing(file) ? renderer.image : nil
        if let info {
            parts.append("\(info.orientedWidth)×\(info.orientedHeight)")
        } else if let onScreen {
            parts.append("\(onScreen.fullWidth)×\(onScreen.fullHeight)")
        }
        if onScreen != nil { parts.append("\(KeyLabels.percent(renderer.effectiveScale)) %") }
        if let summary = tagSummaries[file.url], !summary.isEmpty { parts.append(summary) }
        if failureReason(for: file) != nil { parts.append("cannot open") }
        var content = HUDContent(line: parts.joined(separator: "  ·  "))
        if hud.mode == .full { content.details = detailRows(file, info, onScreen) }
        hud.setContent(content)
        setTitle("\(file.name) — \(index)/\(count)")
    }

    /// The title is hidden (Window menu and Mission Control only) and costs ~0.5 ms to set, so it
    /// follows the HUD after the frame instead of on the navigation's critical path, coalesced
    /// while skimming.
    private func setTitle(_ title: String) {
        guard title != lastTitle else {
            pendingTitle = nil
            return
        }
        let schedule = pendingTitle == nil
        pendingTitle = title
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, let title = self.pendingTitle else { return }
            self.pendingTitle = nil
            self.lastTitle = title
            self.window?.title = title
        }
    }

    private func detailRows(_ file: ImageFile, _ info: ImageInfo?, _ image: DecodedImage?) -> [HUDContent.Row] {
        var rows: [HUDContent.Row] = []
        let exif = info?.exif ?? [:]
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { rows.append(.init(label: label, value: value)) }
        }
        add("Camera", exif["camera"])
        add("Lens", exif["lens"])
        // The decoder formats each value ("35 mm", "f/2.8", "1/250 s", "ISO 100"): one exposure row.
        let exposure = ["focal", "aperture", "shutter", "iso"].compactMap { exif[$0] }.filter { !$0.isEmpty }
        if !exposure.isEmpty { add("Exposure", exposure.joined(separator: "  ")) }
        add("Date", exif["date"])
        add("Profile", exif["profile"] ?? info?.colorProfileName)
        var format = exif["format"] ?? info.map { Self.formatName($0.typeIdentifier) }
        if let info, info.hasGainMap { format = (format ?? "") + " · HDR gain map" }
        if let info, info.frameCount > 1 { format = (format ?? "") + " · \(info.frameCount) frames" }
        add("Format", format)
        if let player, player.url == file.url {
            add("Frame", "\(player.index + 1)/\(player.frameCount)"
                + (player.isPlaying ? "" : player.isFinished ? " · ended" : " · paused"))
        }
        if let info {
            let mp = Double(info.pixelWidth * info.pixelHeight) / 1e6
            add("Pixels", "\(info.orientedWidth)×\(info.orientedHeight) (\(String(format: "%.1f", mp)) MP)")
        }
        if file.byteSize > 0 { add("Size", ByteCountFormatter.string(fromByteCount: file.byteSize, countStyle: .file)) }
        if let image, let tier = shownTier {
            add("Shown", "\(tier) \(image.pixels.width)×\(image.pixels.height)\(image.isHDR ? " HDR" : "")"
                + (image.isApproximate ? " (first scans)" : ""))
        }
        return rows
    }

    private static func formatName(_ uti: String) -> String {
        let known = ["public.jpeg": "JPEG", "public.png": "PNG", "public.heic": "HEIC", "public.heif": "HEIF",
                     "public.avif": "AVIF", "org.webmproject.webp": "WebP", "public.tiff": "TIFF",
                     "public.jpeg-xl": "JPEG XL", "com.compuserve.gif": "GIF", "com.adobe.raw-image": "DNG"]
        if let name = known[uti] { return name }
        return uti.split(separator: ".").last.map { $0.uppercased() } ?? uti
    }

    private func loadTags(for file: ImageFile, force: Bool = false) {
        if !force, tags[file.url] != nil { return }
        let url = file.url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // A fresh URL: NSURL caches resource values, which would hide a tag just written.
            let values = try? URL(fileURLWithPath: url.path, isDirectory: false).resourceValues(forKeys: [.tagNamesKey, .labelNumberKey])
            let result = FileTags(names: values?.tagNames ?? [], labelNumber: values?.labelNumber ?? 0)
            DispatchQueue.main.async {
                guard let self else { return }
                if self.tags.count > 4096 { self.tags.removeAll(); self.tagSummaries.removeAll() }
                let changed = self.tags[url] != result
                self.tags[url] = result
                self.tagSummaries[url] = result.summary
                if changed, self.pipeline.currentFile?.url == url { self.updateHUD() }
            }
        }
    }

    // MARK: Rendering

    private func setNeedsRender() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.setNeedsRender() }
            return
        }
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.renderScheduled else { return }
            self.renderFrame()
        }
    }

    /// Encode and present one frame now (every frame of the window goes through here).
    private func renderFrame() {
        renderScheduled = false
        guard tracksFrames else {
            renderer.render()
            return
        }
        frameCounter += 1
        let tag = frameCounter
        viewerView.metalLayer.nextTag = tag
        renderer.render()
        let record = FrameRecord(file: renderer.image == nil ? nil : shownFile, tier: shownTier, committed: Trace.now())
        frames[tag] = record
        lastCommittedFrame = record
        if frames.count > 512 { frames = frames.filter { $0.key > tag - 256 } }
        onFrameCommitted?(record)
    }

    /// File whose pixels are on screen (may lag `pipeline.currentFile` until its first tier lands).
    var displayedFile: ImageFile? { shownFile }
    private(set) var lastCommittedFrame: FrameRecord?

    /// Present the current state again.
    func redraw() { renderFrame() }

    private func configureFrameTracking() {
        guard tracksFrames else {
            viewerView.metalLayer.onPresented = nil
            return
        }
        viewerView.metalLayer.onPresented = { [weak self] tag, time in
            guard let self, let record = self.frames.removeValue(forKey: tag) else { return }
            self.onFramePresented?(record, time)
        }
    }

    // MARK: Keys

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if event.type == .keyUp {
                return self.motion.releasePanKey(event.keyCode) ? nil : event
            }
            return self.handleKey(event) ? nil : event
        }
    }

    /// A key-down from the local monitor (internal for tests); true when it was handled.
    func handleKey(_ event: NSEvent) -> Bool {
        // A held pan key moves at display rate from key state; its auto-repeats are noise.
        if event.isARepeat, motion.isHolding(keyCode: event.keyCode) { return true }
        guard let chord = KeyChord(event: event) else { return false }
        let context: KeyContext = renderer.isZoomedBeyondFit ? .zoomed : .normal
        if event.isARepeat {
            // Auto-repeat repeats what is meant to be held (navigation, zoom steps) and never completes or starts a
            // sequence: holding ⌘⌫ must not trash a run of images, nor Esc leave full screen and then close the window.
            guard pendingChords.isEmpty else { return true }
            switch config.keymap.resolve([chord], context: context) {
            case .actions(let actions):
                if actions.allSatisfy(Self.repeats) { for action in actions { perform(action, isRepeat: true) } }
                return true
            case .pending:
                return true
            case .unbound:
                return false
            }
        }
        pendingChords.append(chord)
        var result = config.keymap.resolve(pendingChords, context: context)
        if case .unbound = result, pendingChords.count > 1 {
            // A broken sequence: the last chord may still be a binding on its own.
            pendingChords = [chord]
            result = config.keymap.resolve(pendingChords, context: context)
        }
        switch result {
        case .actions(let actions):
            pendingChords.removeAll()
            if actions.count == 1, case .pan(let direction) = actions[0] {
                motion.pressPanKey(event.keyCode, direction: direction)
                return true
            }
            for action in actions { perform(action) }
            return true
        case .pending:
            return true
        case .unbound:
            pendingChords.removeAll()
            return false
        }
    }

    /// Actions that run again on key auto-repeat (a held pan key moves from key state instead).
    private static func repeats(_ action: Action) -> Bool {
        switch action {
        case .next, .previous, .jump, .zoomIn, .zoomOut, .frameNext, .framePrevious: return true
        default: return false
        }
    }

    // MARK: Actions

    /// Whether a menu item for `action` should be enabled.
    func canPerform(_ action: Action, plainKeyEquivalent: Bool) -> Bool {
        if plainKeyEquivalent, window?.isKeyWindow != true { return false }
        switch action {
        case .open, .quit, .config, .reloadConfig, .makeDefault, .help, .hud, .hudHide, .undo, .redo, .background:
            return true
        case .fullscreen, .fullscreenNative, .close, .escape:
            return window?.isVisible == true
        default:
            return pipeline.currentFile != nil
        }
    }

    func perform(_ action: Action, isRepeat: Bool = false) {
        if fileActions.handles(action) {
            if let file = pipeline.currentFile {
                handle(fileActions.perform(action, context: FileActionContext(
                    file: file, index: pipeline.index, count: pipeline.files.count, window: window)))
                return
            }
            switch action {
            case .undo: handle(fileActions.undo()); return
            case .redo: handle(fileActions.redo()); return
            case .config, .reloadConfig, .makeDefault: break  // app-level fallbacks below
            default: return
            }
        }
        switch action {
        case .next: navigate(to: pipeline.index + 1, isRepeat: isRepeat)
        case .previous: navigate(to: pipeline.index - 1, isRepeat: isRepeat)
        case .first: navigate(to: 0, isRepeat: false)
        case .last: navigate(to: pipeline.files.count - 1, isRepeat: false)
        case .jump(let n): navigate(to: pipeline.index + n, isRepeat: isRepeat)
        case .zoomFit: zoom(.fit)
        case .zoomFill: zoom(.fill)
        case .zoomActual: zoom(.scale(1), anchor: mouseInView())
        case .zoomSet(let factor): zoom(.scale(min(factor, Self.maximumZoom)), anchor: mouseInView())
        case .zoomIn: zoomStep(Self.zoomFactor(config.zoomStep))
        case .zoomOut: zoomStep(1 / Self.zoomFactor(config.zoomStep))
        case .zoomToggle: zoom(renderer.zoomMode == .fit ? .scale(1) : .fit, anchor: mouseInView())
        case .zoomKeep:
            renderer.keepZoom.toggle()
            hud.showToast(renderer.keepZoom ? "Keep zoom: on" : "Keep zoom: off")
        case .pan(let direction): motion.tap(direction)
        case .panEdge(let edge): panToEdge(edge)
        case .panCenter: centerImage()
        case .rotateClockwise: renderer.rotate(clockwise: true); afterGeometryChange()
        case .rotateCounterClockwise: renderer.rotate(clockwise: false); afterGeometryChange()
        case .flipHorizontal: renderer.flip(horizontal: true); renderFrame()
        case .flipVertical: renderer.flip(horizontal: false); renderFrame()
        case .playPause: togglePlayback()
        case .frameNext: stepFrame(1)
        case .framePrevious: stepFrame(-1)
        case .background:
            let all = Background.allCases
            let next = all[((all.firstIndex(of: renderer.settings.background) ?? 0) + 1) % all.count]
            renderer.settings.background = next
            renderFrame()
            hud.showToast("Background: \(next.rawValue)")
        case .hud:
            hud.hidesAll = false
            let all = AppConfig.HUDMode.allCases
            hud.mode = all[((all.firstIndex(of: hud.mode) ?? 0) + 1) % all.count]
            updateHUD()
        case .hudHide: hud.hidesAll.toggle()
        case .help: toggleHelp()
        case .fullscreen:
            if config.fullscreen == .native { toggleNativeFullscreen() } else { toggleInstantFullscreen() }
        case .fullscreenNative: toggleNativeFullscreen()
        case .escape:
            if hud.isHelpVisible {
                hud.setHelp(nil)
            } else if instantFullscreen != nil {
                toggleInstantFullscreen()
            } else if window?.styleMask.contains(.fullScreen) == true {
                window?.toggleFullScreen(nil)
            } else {
                window?.performClose(nil)
            }
        case .close:
            // Instant full screen is borderless: without a close button `performClose` only beeps.
            if instantFullscreen != nil { window?.close() } else { window?.performClose(nil) }
        case .quit: NSApp.terminate(nil)
        case .open: onOpenPanel?()
        case .undo: handle(fileActions.undo())
        case .redo: handle(fileActions.redo())
        case .config: openConfigFile()
        case .reloadConfig:
            // With no file open (FileActions reports it otherwise): the error, or the skipped keys, not a success.
            configStore.load()
            hud.showToast(configStore.lastError ?? configStore.lastWarning.map { "Config reloaded · \($0)" } ?? "Config reloaded")
        case .none: break
        default:
            hud.showToast("\(KeyLabels.title(action)): not available")
            Trace.log("action not implemented: \(action.id)")
        }
    }

    private func openConfigFile() {
        do {
            let url = try configStore.createDefaultFileIfMissing()
            NSWorkspace.shared.open(url)
        } catch {
            hud.showToast("Cannot create config: \(error.localizedDescription)")
        }
    }

    private func toggleHelp() {
        if hud.isHelpVisible { hud.setHelp(nil) } else { hud.setHelp(KeyLabels.helpSections(config.keymap)) }
    }

    /// Update the browsing set after a file action.
    private func handle(_ result: FileActionResult) {
        if let toast = result.toast { hud.showToast(toast) }
        switch result.outcome {
        case .removed(let file):
            var files = pipeline.files
            guard let i = files.firstIndex(of: file) else { return }
            listingEpoch &+= 1
            files.remove(at: i)
            if file == unlistedFile { unlistedFile = nil }
            tags[file.url] = nil
            tagSummaries[file.url] = nil
            if files.isEmpty {
                showEmpty(currentFolder)
                return
            }
            // The file on screen went: show the one that took its place. Another one (a redo, a background move
            // that finished late): stay on the image being viewed.
            let current = pipeline.index
            if current == i { beginNavigation() }
            pipeline.setFiles(files, index: current == i ? min(i, files.count - 1) : current > i ? current - 1 : current)
            presentCurrent()
            updateHUD()
        case .restored(let file):
            // Back where it was, but only into the set it belongs to: an undo after opening another folder (or a
            // background move failing after the user moved on) must not inject a file of another folder.
            guard isInBrowsingSet(file) else { return }
            var files = pipeline.files
            listingEpoch &+= 1
            if !files.contains(file) {
                files.append(file)
                files = NaturalSort.sort(files, by: \.name)
            }
            hud.setMessage(nil)
            beginNavigation()
            pipeline.setFiles(files, index: files.firstIndex(of: file) ?? pipeline.index)
            presentCurrent()
            updateHUD()
        case .changed(let file):
            loadTags(for: file, force: true)
            updateHUD()
        case .unchanged:
            break
        }
    }

    private var currentFolder: URL? {
        if case .folder(let url) = browseSource { return url }
        return nil
    }

    /// `url` is a file of the folder being browsed.
    private func isInBrowsedFolder(_ url: URL) -> Bool {
        guard let folder = currentFolder, !url.hasDirectoryPath else { return false }
        return url.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path
    }

    /// `file` belongs to what is browsed: a file of its folder, or any file of an explicitly opened set.
    private func isInBrowsingSet(_ file: ImageFile) -> Bool {
        if case .files = browseSource { return true }
        return isInBrowsedFolder(file.url)
    }

    // MARK: Animation

    /// Decoded frames an animation keeps: all of them when they fit (later loops decode nothing), else a window ahead.
    private var animationBudget: Int { min(pipeline.config.screenBudget / 8, 256 << 20) }

    /// `file` shows its first pixels: play it if it is an animation, once a skim past it is over and while the window is
    /// visible (`visibilityChanged` starts it later). `asked`: a play / step action, which starts it in any case.
    private func startAnimationIfNeeded(_ file: ImageFile, asked: Bool = false) {
        guard player == nil, file == pipeline.currentFile, let info = pipeline.info(for: file), info.isAnimated,
              AnimationPlayer.fits(info, budgetBytes: animationBudget) else { return }
        startAnimationWork?.cancel()
        startAnimationWork = nil
        guard asked || isWindowVisible else { return }
        if !asked, pipeline.isSkimming {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isShowing(file) else { return }
                self.startAnimationIfNeeded(file)
            }
            startAnimationWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(pipeline.config.tuning.skimIntervalMs) + 2),
                                          execute: work)
            return
        }
        let player = AnimationPlayer(url: file.url, info: info, device: pipeline.pool.device, budgetBytes: animationBudget)
        player.onFrameDecoded = { [weak self, weak player] i in
            guard let self, let player, player === self.player else { return }
            if player.isPlaying {
                self.animationClock.schedule(player.deadline)   // the first frame also brings the timing
            } else if i == player.index, self.shownFrame != i, let frame = player.frame(i) {
                self.showFrame(frame, index: i, playing: false)   // the frame a step asked for
            }
        }
        player.onFailed = { [weak self, weak player] _ in
            guard let self, let player, player === self.player else { return }
            self.animationStateChanged()
        }
        self.player = player
        shownFrame = nil
        player.start(at: CACurrentMediaTime())
        animationStateChanged()
        Trace.log("animation \(file.name): \(info.frameCount) frames, \(player.keepsAllFrames ? "every frame kept" : "a window kept")")
    }

    private func stopAnimation() {
        startAnimationWork?.cancel()
        startAnimationWork = nil
        guard let player else { return }
        player.stop()
        self.player = nil
        // A frame of the player is on screen: the pipeline's still replaces it on the next present.
        if shownFrame != nil { shownTier = nil }
        shownFrame = nil
        pausedWhileHidden = false
        animationClock.schedule(nil)
        renderer.isAnimating = false
    }

    /// Playing, paused or finished: pace the clock, present vsync-aligned while playing, refine the frame on screen to
    /// full quality when it stops, refresh the HUD.
    private func animationStateChanged() {
        guard let player else { return }
        renderer.isAnimating = player.isPlaying
        animationClock.schedule(player.isPlaying ? player.deadline : nil)
        if !player.isPlaying, let i = shownFrame, let frame = player.frame(i) {
            renderer.setFrame(frame, playing: false)
            setNeedsRender()
        }
        updateHUD()
    }

    private func animationTick(target: CFTimeInterval, period: CFTimeInterval) {
        guard let player else {
            animationClock.schedule(nil)
            return
        }
        if let frame = player.advance(to: target, tolerance: period / 2) {
            showFrame(frame, index: player.index, playing: true)
        }
        if player.isPlaying { animationClock.schedule(player.deadline) } else { animationStateChanged() }
    }

    private func showFrame(_ frame: DecodedImage, index: Int, playing: Bool) {
        renderer.setFrame(frame, playing: playing)
        shownTier = .full
        shownFrame = index
        renderFrame()
        guard hud.mode == .full, !playing || Trace.ms(since: frameHUDUpdated) >= 100 else { return }
        frameHUDUpdated = Trace.now()
        updateHUD()
    }

    /// The player of the image on screen, started now if it is an animation that has not started yet.
    private func currentPlayer() -> AnimationPlayer? {
        if player == nil, let file = pipeline.currentFile, isShowing(file) { startAnimationIfNeeded(file, asked: true) }
        return player
    }

    private func togglePlayback() {
        // An animation that has not started yet (a skim just ended on it, the window was hidden) starts playing.
        let wasPlaying = self.player?.isPlaying ?? false
        guard let player = currentPlayer() else {
            hud.showToast(noPlayerToast)
            return
        }
        pausedWhileHidden = false
        if wasPlaying {
            player.pause()
            hud.showToast("Paused · frame \(player.index + 1)/\(player.frameCount)")
        } else {
            if !player.isPlaying, let frame = player.play(at: CACurrentMediaTime()) {
                showFrame(frame, index: player.index, playing: true)
            }
            hud.showToast("Playing")
        }
        animationStateChanged()
    }

    private func stepFrame(_ delta: Int) {
        guard let player = currentPlayer() else {
            hud.showToast(noPlayerToast)
            return
        }
        pausedWhileHidden = false
        if let frame = player.step(delta) { showFrame(frame, index: player.index, playing: false) }
        animationStateChanged()
    }

    /// Why a play / step key found no player: the image is a still, or an animation too large to play.
    private var noPlayerToast: String {
        guard let file = pipeline.currentFile, let info = pipeline.info(for: file), info.isAnimated,
              !AnimationPlayer.fits(info, budgetBytes: animationBudget) else { return "Not an animation" }
        return "Too large to animate"
    }

    private var isWindowVisible: Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    private func visibilityChanged() {
        guard let player else {
            if isWindowVisible, let file = pipeline.currentFile, isShowing(file) { startAnimationIfNeeded(file) }
            return
        }
        if !isWindowVisible, player.isPlaying {
            player.pause()
            pausedWhileHidden = true
            animationStateChanged()
        } else if isWindowVisible, pausedWhileHidden {
            pausedWhileHidden = false
            if let frame = player.play(at: CACurrentMediaTime()) { showFrame(frame, index: player.index, playing: true) }
            animationStateChanged()
        }
    }

    // MARK: Zoom & pan

    private func zoom(_ mode: ZoomMode, anchor: CGPoint? = nil) {
        renderer.setZoom(mode, anchor: anchor)
        afterGeometryChange()
    }

    /// Largest magnification, as `Renderer.zoom(by:)` allows (`zoom.set` accepts any positive factor).
    static let maximumZoom = 64.0

    /// `view.zoom_step`, guarded against values that would not zoom (≤ 1) or jump absurdly.
    static func zoomFactor(_ step: Double) -> Double {
        step.isFinite && step > 1.001 ? min(step, 16) : 1.25
    }

    private func zoomStep(_ factor: Double) {
        renderer.zoom(by: factor, anchor: mouseInView() ?? CGPoint(x: viewerView.bounds.midX, y: viewerView.bounds.midY))
        afterGeometryChange()
    }

    /// Present the new geometry, ask for full resolution when the view needs it, refresh the zoom %.
    private func afterGeometryChange() {
        renderFrame()
        requestFullResolutionIfNeeded()
        updateHUD()
    }

    /// Ask for `.full` only when the view shows more detail than the tier on screen holds — never when that tier
    /// already is full resolution (small images: the screen tier is the whole image).
    private func requestFullResolutionIfNeeded() {
        guard renderer.wantsFullResolution, let image = renderer.image, !Self.isFullResolution(image) else { return }
        pipeline.requestFullResolution()
    }

    /// The tier holds every pixel of the image (`fullWidth`/`fullHeight` are oriented, the pixels may not be yet:
    /// compare long and short sides).
    static func isFullResolution(_ image: DecodedImage) -> Bool {
        max(image.pixels.width, image.pixels.height) >= max(image.fullWidth, image.fullHeight)
            && min(image.pixels.width, image.pixels.height) >= min(image.fullWidth, image.fullHeight)
    }

    private func panToEdge(_ edge: Action.Edge) {
        let far: CGFloat = 1e7
        switch edge {
        case .left: renderer.pan(by: CGVector(dx: far, dy: 0))
        case .right: renderer.pan(by: CGVector(dx: -far, dy: 0))
        case .top: renderer.pan(by: CGVector(dx: 0, dy: far))
        case .bottom: renderer.pan(by: CGVector(dx: 0, dy: -far))
        }
        renderFrame()
    }

    private func centerImage() {
        guard let image = renderer.image else { return }
        let scale = renderer.effectiveScale
        let backing = Double(window?.backingScaleFactor ?? 2)
        var w = Double(image.fullWidth), h = Double(image.fullHeight)
        if renderer.quarterTurns % 2 == 1 { swap(&w, &h) }
        let vw = Double(viewerView.bounds.width) * backing, vh = Double(viewerView.bounds.height) * backing
        renderer.pan(by: CGVector(dx: 1e7, dy: 1e7))  // top-left corner
        renderer.pan(by: CGVector(dx: -max(w * scale - vw, 0) / (2 * backing), dy: -max(h * scale - vh, 0) / (2 * backing)))
        renderFrame()
    }

    private func mouseInView() -> CGPoint? {
        guard let window else { return nil }
        let p = viewerView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return viewerView.bounds.contains(p) ? p : nil
    }

    // MARK: Full screen

    private var isFullscreen: Bool { instantFullscreen != nil || window?.styleMask.contains(.fullScreen) == true }

    private func notchInset(_ screen: NSScreen) -> CGFloat { config.avoidNotch ? screen.safeAreaInsets.top : 0 }

    /// Borderless, screen-sized window with auto-hidden menu bar and Dock: no Space animation,
    /// takes effect on the next frame.
    private func toggleInstantFullscreen() {
        guard let window else { return }
        if instantFullscreen != nil {
            exitInstantFullscreen(reorder: true)
        } else {
            if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil); return }
            guard let screen = window.screen ?? NSScreen.main else { return }
            instantFullscreen = (window.frame, window.styleMask)
            window.setFrameAutosaveName("")  // never persist the full-screen frame
            NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
            window.styleMask = [.borderless]
            window.setFrame(screen.frame, display: true)
            rootView.topInset = notchInset(screen)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(viewerView)
            lastPointerMove = Trace.now()
            scheduleIdleCheck()
        }
    }

    /// Restore the window's style and frame. `reorder` is false while the window is closing.
    private func exitInstantFullscreen(reorder: Bool) {
        guard let window, let saved = instantFullscreen else { return }
        instantFullscreen = nil
        NSApp.presentationOptions = []
        window.styleMask = saved.style
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.setFrame(saved.frame, display: reorder)
        window.setFrameAutosaveName("PeekabooViewer")
        rootView.topInset = 0
        if reorder {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(viewerView)
        }
        showChrome()
    }

    private func toggleNativeFullscreen() {
        if instantFullscreen != nil { toggleInstantFullscreen() }
        window?.toggleFullScreen(nil)
    }

    // MARK: Cursor & chrome auto-hide

    func viewerPointerMoved(_: NSView) {
        lastPointerMove = Trace.now()
        if chromeHidden { showChrome() }
        scheduleIdleCheck()
    }

    private func scheduleIdleCheck(after seconds: Double = 1.5) {
        guard idleTimer == nil else { return }
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in self?.idleCheck() }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private func idleCheck() {
        idleTimer = nil
        let idle = Trace.ms(since: lastPointerMove)
        if idle < 1500 {
            scheduleIdleCheck(after: (1500 - idle) / 1000 + 0.01)
            return
        }
        guard let window, window.isKeyWindow else { return }
        if isFullscreen {
            NSCursor.setHiddenUntilMouseMoves(true)
        } else {
            let p = window.mouseLocationOutsideOfEventStream
            let inTitlebar = p.y > window.frame.height - 32 && p.y <= window.frame.height && p.x >= 0 && p.x <= window.frame.width
            if !inTitlebar { hideChrome() }
        }
    }

    private var titlebarControls: NSView? { window?.standardWindowButton(.closeButton)?.superview }

    private func hideChrome() {
        guard !chromeHidden, let controls = titlebarControls else { return }
        chromeHidden = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            controls.animator().alphaValue = 0
        }
    }

    private func showChrome() {
        guard chromeHidden else { return }
        chromeHidden = false
        guard let controls = titlebarControls else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            controls.animator().alphaValue = 1
        }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        stopAnimation()
        exitInstantFullscreen(reorder: false)
        motion.releaseAllKeys()
        motion.stopMomentum()
        hud.setHelp(nil)
        // Stay resident but give back the big caches; the current image stays for a Dock reopen. Not through
        // `handleMemoryPressure`, which would halve the budgets and pause the preview sweep of the next session.
        isClosed = true
        let trimmed = DeferredRelease(cachedImages())
        applyPipelineConfig(config)
        trimmed.release(drainingPool: pipeline.pool)
    }

    func windowDidResignKey(_ notification: Notification) {
        motion.releaseAllKeys()
        pendingChords.removeAll()
        showChrome()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        lastPointerMove = Trace.now()
        scheduleIdleCheck()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        motion.screenChanged()
        animationClock.screenChanged()
        if instantFullscreen != nil, let screen = window?.screen {
            window?.setFrame(screen.frame, display: true)
            rootView.topInset = notchInset(screen)
        }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        lastPointerMove = Trace.now()
        scheduleIdleCheck()
    }

    // MARK: Folder refresh

    /// Watch the browsed folder (vnode events, debounced 50 ms) and re-list it on every change.
    private func watchFolder() {
        guard case .folder(let folder) = browseSource else {
            folderWatcher = nil
            return
        }
        if folderWatcher?.directory == folder { return }
        folderWatcher = FolderWatcher(directory: folder) { [weak self] in self?.rescanFolder() }
        if folderWatcher == nil { Trace.log("cannot watch \(folder.lastPathComponent)") }
    }

    /// Re-list the browsed folder off the main thread and apply additions, removals and changed
    /// versions, keeping the current file (a `FolderWatcher` callback can call this directly).
    func rescanFolder() {
        guard case .folder(let folder) = browseSource, !listingPending else { return }
        guard !rescanInFlight else {
            rescanQueued = true
            return
        }
        rescanInFlight = true
        let generation = openGeneration
        let epoch = listingEpoch
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let files = try? FolderScanner.scan(folder)
            DispatchQueue.main.async {
                guard let self else { return }
                self.rescanInFlight = false
                let session = generation == self.openGeneration && !self.listingPending
                if session, epoch == self.listingEpoch, let files { self.applyRescan(files, of: folder) }
                // A file action during the scan (the listing may still hold a file just moved away), or changes
                // that arrived meanwhile: list again.
                if self.rescanQueued || (session && epoch != self.listingEpoch) {
                    self.rescanQueued = false
                    self.rescanFolder()
                }
            }
        }
    }

    private func applyRescan(_ listed: [ImageFile], of folder: URL) {
        var files = listed
        if let unlisted = unlistedFile {
            if files.contains(unlisted) || unlisted != pipeline.currentFile {
                unlistedFile = nil  // listed now, or the user moved on: it leaves the set with this listing
            } else {
                files = NaturalSort.sort(files + [unlisted], by: \.name)
            }
        }
        let fingerprint = { (list: [ImageFile]) in list.map { $0.url.path + "|" + $0.version } }
        guard fingerprint(files) != fingerprint(pipeline.files) else { return }
        if files.isEmpty {
            showEmpty(folder)
            return
        }
        let current = pipeline.currentFile
        var index = current.flatMap { files.firstIndex(of: $0) }
        if index == nil, let current, current.fileID != 0 {
            // Renamed (in Finder, by another app): the same file under its new name stays on screen.
            index = files.firstIndex { $0.fileID == current.fileID && $0.byteSize == current.byteSize }
        }
        pipeline.setFiles(files, index: index ?? min(pipeline.index, files.count - 1))
        if pipeline.currentFile != current { beginNavigation() }
        // The message was about the previous state (an empty folder, a removed file's error); `presentCurrent`
        // shows the current file's error again if it still has one.
        hud.setMessage(nil)
        presentCurrent()
        updateHUD()
        Trace.log("folder rescanned: \(files.count) files")
    }

    // MARK: System events

    private func installSystemObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensChanged()
        })
        // Hidden, occluded (another window, a locked screen) or minimised: the animation pauses.
        observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            self?.visibilityChanged()
        })
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let critical = source.data.contains(.critical)
            Trace.log("memory pressure: \(critical ? "critical" : "warning")")
            self.player?.trimToCurrent()
            self.pipeline.handleMemoryPressure(critical: critical)
        }
        source.activate()
        memoryPressure = source
    }

    /// Displays were added, removed or changed resolution: the screen tier must cover the largest one.
    private func screensChanged() {
        var pipelineConfig = pipeline.config
        let side = Self.largestScreenLongSide()
        if pipelineConfig.screenLongSide != side {
            pipelineConfig.screenLongSide = side
            pipeline.updateConfig(pipelineConfig)
            Trace.log("screen tier long side → \(side)")
        }
        motion.screenChanged()
        if instantFullscreen != nil, let screen = window?.screen {
            window?.setFrame(screen.frame, display: true)
            rootView.topInset = notchInset(screen)
        }
    }

    // MARK: ViewerViewDelegate

    func viewerViewDidResize(_ view: ViewerView) {
        let scale = window?.backingScaleFactor ?? 2
        renderer.setViewSize(view.bounds.size, backingScale: scale)
        hud.layout(size: view.bounds.size, topInset: instantFullscreen == nil ? 28 : 0, scale: scale)
        renderFrame()
        updateHUD()
    }

    func viewer(_: ViewerView, magnifyBy factor: Double, at point: CGPoint, phase: NSEvent.Phase) {
        if phase.contains(.began) || !magnifying {
            if !magnifying { magnifying = true; gate.acquire() }
            motion.stopMomentum()
        }
        renderer.zoom(by: factor, anchor: point)
        renderFrame()
        updateHUD()
        if phase.contains(.ended) || phase.contains(.cancelled) {
            magnifying = false
            gate.release()
        }
    }

    func viewer(_: ViewerView, scrollBy delta: CGVector, at point: CGPoint, precise: Bool,
                modifiers: NSEvent.ModifierFlags, phase: NSEvent.Phase) {
        gate.touch()
        if modifiers.contains(.command) || !precise {
            // Mouse wheel or ⌘-scroll: zoom around the pointer.
            renderer.zoom(by: pow(1.0025, Double(delta.dy) * (precise ? 1 : 20)), anchor: point)
            renderFrame()
            updateHUD()
        } else {
            if phase.contains(.began) { motion.stopMomentum() }
            renderer.pan(by: delta)
            renderFrame()
        }
    }

    func viewer(_: ViewerView, dragBy delta: CGVector, phase: NSEvent.Phase) {
        let now = Trace.now()
        switch phase {
        case .began:
            motion.stopMomentum()
            if !dragging { dragging = true; gate.acquire() }
            dragVelocity = .zero
            lastDragEvent = now
        case .ended:
            guard dragging else { return }
            dragging = false
            // Momentum only if the pointer was still moving when released.
            if Double(now &- lastDragEvent) / 1e6 < 50 { motion.fling(dragVelocity) }
            gate.release()
        default:
            let dt = max(Double(now &- lastDragEvent) / 1e9, 1.0 / 240)
            lastDragEvent = now
            let v = CGVector(dx: delta.dx / dt, dy: delta.dy / dt)
            dragVelocity = CGVector(dx: 0.6 * v.dx + 0.4 * dragVelocity.dx, dy: 0.6 * v.dy + 0.4 * dragVelocity.dy)
            renderer.pan(by: delta)
            renderFrame()
        }
    }

    func viewer(_: ViewerView, doubleClickAt point: CGPoint) {
        zoom(renderer.zoomMode == .fit ? .scale(1) : .fit, anchor: point)
    }

    func viewerSmartMagnify(_: ViewerView, at point: CGPoint) {
        zoom(renderer.zoomMode == .fit ? .scale(1) : .fit, anchor: point)
    }

    func viewer(_: NSView, didDrop urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        if let onOpenURLs { onOpenURLs(urls) } else { open(urls) }
        return true
    }

    // MARK: Helpers

    /// `base` with the cache budgets of `config`: `cache_budget_mb` sets the total and scales the per-tier budgets
    /// with it (so a larger budget is not capped by the automatic tier sizes); no value restores the automatic sizes.
    ///
    /// `closed` (the window is closed, the app stays resident): keep the current image, the previews and a quarter
    /// of the screen tiers (the nearest by ETA), no other full resolution, and decode nothing ahead until the window
    /// opens again. Unlike memory pressure this leaves no 60 s penalty (halved budgets, paused sweep) for the next open.
    static func pipelineConfig(_ config: AppConfig, base: PipelineConfig, closed: Bool = false) -> PipelineConfig {
        let automatic = PipelineConfig(screenLongSide: base.screenLongSide, previewLongSide: base.previewLongSide)
        var result = base
        result.tuning = automatic.tuning
        result.memoryBudget = automatic.memoryBudget
        result.screenBudget = automatic.screenBudget
        result.previewBudget = automatic.previewBudget
        result.fullBudget = automatic.fullBudget
        if let mb = config.cacheBudgetMB, mb > 0 {
            let total = mb << 20
            let factor = Double(total) / Double(max(automatic.memoryBudget, 1))
            result.memoryBudget = total
            result.screenBudget = Int(Double(automatic.screenBudget) * factor)
            result.previewBudget = Int(Double(automatic.previewBudget) * factor)
            result.fullBudget = Int(Double(automatic.fullBudget) * factor)
        }
        if closed {
            result.screenBudget /= 4
            result.fullBudget = 0  // the current image (pinned) keeps its own
            result.tuning.screenHorizonMs = 0
            result.tuning.previewHorizonMs = 0
            result.tuning.fullMaxCostMs = 0
            result.tuning.sweepEnabled = false
        }
        return result
    }

    /// Long side in device pixels of the largest attached screen (the screen tier must cover it).
    static func largestScreenLongSide() -> Int {
        let sides = NSScreen.screens.map { screen -> Int in
            let size = screen.frame.size
            return Int(max(size.width, size.height) * screen.backingScaleFactor)
        }
        return max(sides.max() ?? 3456, 1024)
    }
}

/// Keeps decoded images alive past a cache replacement or trim and frees them on a utility queue: releasing a warm
/// cache (gigabytes of IOSurfaces and buffers) costs 13–23 ms, which must not stall the main thread on an open.
private final class DeferredRelease: @unchecked Sendable {
    private var images: [DecodedImage]

    init(_ images: [DecodedImage]) { self.images = images }

    /// Free the images `delay` seconds from now (after the next frames), then drain `pool` (its buffers too).
    func release(after delay: TimeInterval = 0, drainingPool pool: PixelBufferPool? = nil) {
        guard !images.isEmpty || pool != nil else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            self.images.removeAll()
            pool?.drain()
        }
    }
}
