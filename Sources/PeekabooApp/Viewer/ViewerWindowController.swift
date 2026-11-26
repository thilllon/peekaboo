import AppKit
import PeekabooCore
import PeekabooRender

/// Borderless windows cannot become key by default; instant full screen needs them to.
final class ViewerWindow: NSWindow {
    /// Headless (tests): the frame stays where it is put, off every screen (`Presentation`).
    var staysOffScreen = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        staysOffScreen ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
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
        actions.onIdle = { [weak self] in self?.onFileOperationsEnded?() }
        return actions
    }()
    /// Main thread: the last file operation running in the background has ended, and its result is shown.
    var onFileOperationsEnded: (() -> Void)?

    /// A file operation runs in the background: a copy, a move to another volume, an undo or redo that copies across
    /// volumes, copying the picks.
    var isRunningFileOperation: Bool { fileActions.isBusy }
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
    /// `app.config` (⌘,): the app's Settings window. Without it, the config file opens in an editor.
    var onOpenSettings: (() -> Void)?

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
    /// The browsed folder may not be listed (macOS privacy protection, its permissions): the text that says so and how
    /// to allow it. The set is the opened image alone: its ends show this instead of "First image" / "Last image", and
    /// the folder is listed again whenever the window becomes key (back from System Settings). nil once it lists.
    private var refusedListing: String?
    /// Files without pixels whose decode failed (the pipeline never retries them), for the version that failed.
    private var failures: [URL: Failure] = [:]
    private struct Failure {
        let version: String?
        let reason: String
    }
    private var tags: [URL: FileTags] = [:]
    private var tagSummaries: [URL: String] = [:]
    /// The latest tag read asked for each file: an older one that lands later is stale.
    private var tagReadSerials: [URL: Int] = [:]
    private var tagReadSerial = 0

    // Picks
    /// The browsing set's picks (the Finder tag "Pick"): read off the main thread once per listing and kept current as
    /// the user marks. Empty while `[rating] storage = "none"`.
    private var picks = PickSet()
    /// The picks-only view (`view.picks_only`): `pipeline.files` holds the picks of `allFiles` in their order, plus the
    /// photo on screen when it is not a pick (it was un-picked there, or the view began on it) until the user moves on.
    private var picksOnly = false
    /// The whole browsing set while `picksOnly` (otherwise that is `pipeline.files`).
    private var allFiles: [ImageFile] = []
    /// The listing the picks were last read for, as it was listed then (sizes, dates, inodes): the next read of the
    /// folder reads only the files that are new or changed since. Empty until the first read of the folder lands.
    private var picksListing: [ImageFile] = []
    /// Files the viewer took out of the browsing set (moved away, trashed) since the folder was opened: one that comes
    /// back (Finder, Put Back) is read again rather than taken for what it was before it left.
    private var picksForgotten: Set<URL> = []
    /// Drops the result of a folder-wide read that a newer listing (or another folder) replaced.
    private var picksReadGeneration = 0
    /// The generation of the toast that shows the progress of copying the picks: a newer toast (another action's)
    /// stops the progress toasts, so they never hide what the user did meanwhile.
    private var progressToast: Int?
    private var lastAppliedRatingStorage: AppConfig.RatingStorage?
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
    /// In front and key, or out of sight for tests (`.headless`).
    let presentation: Presentation

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

    init(configStore: ConfigStore, presentation: Presentation = .interactive) {
        self.configStore = configStore
        self.presentation = presentation
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
        window.staysOffScreen = presentation == .headless

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
        applySwitches(config)
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
        if lastAppliedRatingStorage != config.ratingStorage {
            // Picks follow the tag storage: turned off, they are forgotten; turned on, the folder's tags are read.
            let changed = lastAppliedRatingStorage != nil
            lastAppliedRatingStorage = config.ratingStorage
            if changed, config.ratingStorage == .finderTags { readPicks() } else if changed { forgetPicks() }
        }
        applyPipelineConfig(config)
        if hud.isHelpVisible { hud.setHelp(KeyLabels.helpSections(config.keymap)) }
        if instantFullscreen != nil, let screen = window?.screen { rootView.topInset = notchInset(screen) }
        updateHUD()
    }

    /// Show a toast (e.g. a config error) for `seconds`.
    func toast(_ text: String, seconds: TimeInterval = 1.2) { hud.showToast(text, seconds: seconds) }

    /// `[decode]` and `[debug]`: process-wide flags the decode lanes and the trace read, set here once per apply (the
    /// environment variables force them). A change of `hdr` decodes the gain-map and PQ / HLG photos again; the one on
    /// screen keeps its pixels until its new sharp tier lands, which swaps in place (same geometry).
    private func applySwitches(_ config: AppConfig) {
        if ImageIODecoder.usesFastPath != config.fastPath { ImageIODecoder.usesFastPath = config.fastPath }
        let trace = config.trace || Trace.forcedByEnvironment
        if Trace.enabled != trace {
            Trace.enabled = trace
            tracksFrames = trace || onFramePresented != nil
        }
        let hdr = config.decodeHDR || ImageIODecoder.hdrForcedByEnvironment
        guard ImageIODecoder.decodeHDR != hdr else { return }
        ImageIODecoder.decodeHDR = hdr
        pipeline.redecode { info, tier in info.hasHDRRendition && tier != .preview }
        if let file = shownFile, let tier = shownTier, tier > .preview, pipeline.info(for: file)?.hasHDRRendition == true {
            shownTier = .preview  // so that the new sharp tier replaces what is on screen
        }
        Trace.log("HDR decoding \(hdr ? "on" : "off"): gain-map and PQ / HLG images decode again")
    }

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
        refusedListing = nil
        forgetPicks(replacingFiles: true)
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
        let folder = currentFolder
        showWindow(nil)
        makeKeyAndOrderFront()
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
            applyListing(Self.list(urls, folder: folder), urls: urls, singleFile: false, opened: opened)
            presentFirstFrameNow()
            return
        }
        updateHUD()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let listing = Self.list(urls, folder: folder)
            DispatchQueue.main.async {
                guard let self, generation == self.openGeneration else { return }
                self.applyListing(listing, urls: urls, singleFile: singleFile, opened: opened)
            }
        }
    }

    /// What `open` lists: the browsing set or the error, and when access to the folder was refused, the text that says
    /// so and how to allow it.
    private typealias Listing = (result: Result<(files: [ImageFile], index: Int), Error>, refusal: String?)

    /// `FolderScanner.browse(urls)`, and the refusal text when it failed for lack of access to `folder`: built here,
    /// with the listing (off the main thread but at launch) and only on failure, because naming a volume's switch
    /// asks the volume for its type.
    private static func list(_ urls: [URL], folder: URL?) -> Listing {
        let result = Result { try FolderScanner.browse(urls) }
        guard case .failure(let error) = result, let folder else { return (result, nil) }
        return (result, accessDeniedToast(error, folder: folder))
    }

    private func applyListing(_ listing: Listing, urls: [URL], singleFile: Bool, opened: UInt64) {
        listingPending = false
        refusedListing = listing.refusal
        guard case .success(let browsed) = listing.result, !browsed.files.isEmpty else {
            if case .failure(let error) = listing.result, listing.refusal != nil {
                Trace.log("folder not readable: \(currentFolder?.lastPathComponent ?? "?") (\(error))")
            }
            // An unreadable parent folder still shows the opened file on its own; a refused one also says why and how
            // to allow it, in a toast over the image (again at the ends of the set), or as the message of an opened
            // folder (`showEmpty`).
            if singleFile {
                if let refusal = refusedListing { hud.showToast(refusal, seconds: Self.accessDeniedToastSeconds) }
                updateHUD()
                readPicks()
            } else {
                showEmpty(urls.count == 1 ? urls.first : nil)
            }
            watchFolder()
            return
        }
        var files = browsed.files
        var index = browsed.index
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
        readPicks()
        Trace.log("folder listed: \(browsed.files.count) files, \(String(format: "%.1f", Trace.ms(since: opened))) ms after open")
    }

    /// The opened file before its folder is listed (size, date and inode not known yet).
    private static func placeholder(for url: URL) -> ImageFile {
        ImageFile(url: url, name: url.lastPathComponent, byteSize: 0, modified: 0, fileID: 0)
    }

    /// Long enough to read the way to allow it (a confirmation toast lasts 1.2 s).
    static let accessDeniedToastSeconds: TimeInterval = 6

    /// The text for `folder` when listing it failed with `error` because access was refused, with the way to allow it:
    /// macOS privacy protection refuses with EPERM (`privacySetting`), the folder's permissions with EACCES. nil for
    /// any other error. A toast has no button, so it names the System Settings pane instead of opening it.
    static func accessDeniedToast(_ error: Error, folder: URL) -> String? {
        guard let code = FolderScanner.posixCode(error) else { return nil }
        let cannot = "Peekaboo cannot read “\(folder.lastPathComponent)”\n"
        switch code {
        case EPERM: return cannot + privacySetting(for: folder)
        case EACCES: return cannot + "Its permissions do not let you read it: Finder › Get Info › Sharing & Permissions"
        default: return nil
        }
    }

    /// Where System Settings lets Peekaboo read `folder`, which macOS privacy protection refuses: the Files & Folders
    /// switch of the protected place it is in (Desktop, Documents or Downloads Folder, Removable or Network Volumes),
    /// else Full Disk Access, the only setting for the rest (Mail, Messages, Time Machine backups, other apps' data).
    /// Asks the volume of a folder in /Volumes for its type: never on the main thread.
    static func privacySetting(for folder: URL) -> String {
        let path = folder.standardizedFileURL.path
        let filesAndFolders = " for Peekaboo in System Settings › Privacy & Security › Files & Folders"
        if let place = FolderAccessRequest.folders.first(where: { isInside(path, $0.standardizedFileURL.path) }) {
            return "Turn on \(place.lastPathComponent) Folder" + filesAndFolders
        }
        let components = folder.standardizedFileURL.pathComponents
        if isInside(path, "/Volumes"), components.count > 2,
           !components.contains(".timemachine"), !components.contains("Backups.backupdb") {
            return "Turn on \(isOnNetworkVolume(path) ? "Network" : "Removable") Volumes" + filesAndFolders
        }
        return "Allow Peekaboo in System Settings › Privacy & Security › Full Disk Access"
    }

    /// `path` is `folder` or inside it, in any letter case (as the file system compares names).
    private static func isInside(_ path: String, _ folder: String) -> Bool {
        path.caseInsensitiveCompare(folder) == .orderedSame
            || path.range(of: folder + "/", options: [.anchored, .caseInsensitive]) != nil
    }

    /// The file system of `path` is not local (`MNT_LOCAL`): a network volume. False when `statfs` fails.
    static func isOnNetworkVolume(_ path: String) -> Bool {
        var volume = statfs()
        return statfs(path, &volume) == 0 && volume.f_flags & UInt32(MNT_LOCAL) == 0
    }

    /// Index of `url` in the browsing set (`browsingSet`) when it is a listed file of the folder being browsed.
    private func indexInBrowsingSet(_ url: URL) -> Int? {
        guard !listingPending, isInBrowsedFolder(url) else { return nil }
        let name = url.lastPathComponent
        return browsingSet.firstIndex { $0.name == name }
    }

    /// Finder (or a drop) opened another file of the folder being browsed: navigate to it and keep the listing and
    /// the cache, instead of starting over (which would free the cache on the main thread and decode it all again).
    private func openWithinBrowsingSet(_ index: Int) {
        showWindow(nil)
        makeKeyAndOrderFront()
        // In the picks-only view the file is looked up among the view's few files; a photo the view leaves out ends it,
        // on that photo.
        let position = picksOnly ? pipeline.files.firstIndex(of: browsingSet[index]) : index
        if picksOnly, position == nil { leavePicksOnly(showing: index, toast: "All photos") }
        if let position, position != pipeline.index {
            navigate(to: position, isRepeat: false)
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

    /// Nothing to show: an empty folder (or one Peekaboo may not read: `refusedListing`), or no file opened yet.
    func showEmpty(_ folder: URL?) {
        stopAnimation()
        forgetPicks(replacingFiles: true)
        replaceFiles([], index: 0)
        shownFile = nil
        shownTier = nil
        shownApproximate = false
        shownVersion = nil
        renderer.setImage(nil, key: nil)
        setLoading(false)
        renderFrame()
        if let folder {
            hud.setMessage(refusedListing ?? "No images in “\(folder.lastPathComponent)”\nDrop images here or press ⌘O")
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
        makeKeyAndOrderFront()
        if pipeline.currentFile == nil, shownFile == nil {
            showEmpty(nil)
        } else {
            presentCurrent()   // an animation closed with the window shows its still again and plays from there
            renderFrame()
        }
    }

    /// In front and key; headless: ordered in out of sight (`Presentation`).
    override func showWindow(_ sender: Any?) {
        if presentation == .headless { window?.orderInOutOfSight() } else { super.showWindow(sender) }
    }

    /// `window.makeKeyAndOrderFront(nil)`; headless: ordered in out of sight, like `showWindow`.
    private func makeKeyAndOrderFront() {
        if presentation == .headless { window?.orderInOutOfSight() } else { window?.makeKeyAndOrderFront(nil) }
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
            // A folder Peekaboo may not list browses the opened image alone: say why, not that it is the last one.
            if let refusal = refusedListing {
                if !isRepeat { hud.showToast(refusal, seconds: Self.accessDeniedToastSeconds) }
            } else if picksOnly {
                hud.showToast(index < 0 ? "First pick" : "Last pick")
            } else {
                hud.showToast(index < 0 ? "First image" : "Last image")
            }
            return
        }
        guard target != pipeline.index || shownFile == nil else { return }
        beginNavigation()
        progressToast = nil  // back to judging photos: a copy's progress toasts stop covering them (its summary comes)
        let leaving = picksOnly ? pipeline.currentFile : nil
        pipeline.navigate(to: target, isRepeat: isRepeat)
        // Moving on from a photo that is not a pick takes it out of the picks-only view.
        if let leaving, leaving != pipeline.currentFile, !picks.contains(leaving) { dropFromPicksView(leaving) }
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
        let position: String
        var counter: String?
        if listingPending {
            position = "…/…"
        } else if picksOnly {
            if picks.contains(file) {
                // Until the folder's first tag read lands, the view's size is not known yet.
                position = "Picks \(pipeline.index + 1)/\(picksKnown ? "\(pipeline.files.count)" : "…")"
            } else {
                // A photo that is not a pick (un-picked on screen, or the view began on it) stays until the user moves
                // on.
                let picksInView = pipeline.files.count - 1
                position = "Not a pick"
                counter = !picksKnown ? "Picks …" : picksInView == 0 ? "No picks left" : "Picks \(picksInView)"
            }
        } else {
            // A folder that may not be listed has images nobody counted.
            position = "\(pipeline.index + 1)/\(refusedListing == nil ? "\(pipeline.files.count)" : "?")"
            // Shown once the folder's first tag read has landed: before, it would count only the picks seen so far.
            if picksKnown, !picks.isEmpty { counter = "Picks \(picks.count)" }
        }
        var parts = [file.name, position]
        if let counter { parts.append(counter) }
        let info = pipeline.info(for: file)
        let onScreen = isShowing(file) ? renderer.image : nil
        if let info {
            parts.append("\(info.orientedWidth)×\(info.orientedHeight)")
        } else if let onScreen {
            parts.append("\(onScreen.fullWidth)×\(onScreen.fullHeight)")
        }
        if onScreen != nil { parts.append("Zoom \(KeyLabels.percent(renderer.effectiveScale))%") }
        if let summary = tagSummaries[file.url], !summary.isEmpty { parts.append(summary) }
        if failureReason(for: file) != nil { parts.append("cannot open") }
        var content = HUDContent(line: parts.joined(separator: "  ·  "))
        if hud.mode == .full { content.details = detailRows(file, info, onScreen) }
        hud.setContent(content)
        setTitle("\(file.name) — \(position)")
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
        // Two reads of one file can land out of order (a tag written between them): only the last one asked for counts.
        tagReadSerial &+= 1
        let serial = tagReadSerial
        tagReadSerials[url] = serial
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // A fresh URL: NSURL caches resource values, which would hide a tag just written.
            let values = try? URL(fileURLWithPath: url.path, isDirectory: false).resourceValues(forKeys: [.tagNamesKey, .labelNumberKey])
            let result = FileTags(names: values?.tagNames ?? [], labelNumber: values?.labelNumber ?? 0)
            DispatchQueue.main.async {
                guard let self, self.tagReadSerials[url] == serial else { return }
                self.tagReadSerials[url] = nil
                if self.tags.count > 4096 { self.tags.removeAll(); self.tagSummaries.removeAll() }
                let changed = self.tags[url] != result
                self.tags[url] = result
                self.tagSummaries[url] = result.summary
                // The read also says whether the file is a pick (e.g. one an undo brought back).
                let pickChanged = self.config.ratingStorage == .finderTags
                    && self.setPicked(url, result.names.contains(FileOperations.pickTag))
                if changed || pickChanged, self.pipeline.currentFile?.url == url { self.updateHUD() }
            }
        }
    }

    // MARK: Picks

    /// The picks-only view is on (the View menu's check mark).
    var isPicksOnly: Bool { picksOnly }

    /// Every file browsed: `allFiles` in the picks-only view, else the pipeline's set.
    private var browsingSet: [ImageFile] { picksOnly ? allFiles : pipeline.files }

    /// The folder's first tag read has landed: every pick of the listing is known (until then the counter would count
    /// only the picks seen so far, such as the photo on screen).
    private var picksKnown: Bool { !picksListing.isEmpty }

    /// Which files of the browsing set are picks: read off the main thread (utility QoS) after this run-loop turn, so at
    /// launch after the first frame. Files of the listing read last keep their known state while they are unchanged on
    /// disk; new, changed and returning files are read.
    private func readPicks() {
        guard config.ratingStorage == .finderTags else { return }
        let listing = browsingSet
        guard !listing.isEmpty else { return }
        picksReadGeneration &+= 1
        let generation = picksReadGeneration
        let previous = picksListing
        let known = picks.urls
        let unknown = picksForgotten
        picks.beginRead()
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.picksReadGeneration else {
                Retired.release(listing, previous)  // possibly the last references to a replaced listing
                return
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let started = Trace.now()
                let read = FileOperations.readPicks(of: listing, previous: previous, known: known, unknown: unknown)
                let ms = Trace.ms(since: started)
                DispatchQueue.main.async {
                    guard let self, generation == self.picksReadGeneration else {
                        Retired.release(read)
                        return
                    }
                    self.finishReadingPicks(read, ms: ms)
                }
            }
        }
    }

    private func finishReadingPicks(_ read: PicksRead, ms: Double) {
        let before = picks.urls
        let wasKnown = picksKnown
        picks.finishRead(read)
        Retired.release(picksListing)
        picksListing = read.listing
        Trace.log(String(format: "picks: %d of %d files (%d read in %.1f ms)", picks.count, read.listing.count, read.read,
                         ms))
        if picksOnly, picks.isEmpty {
            leavePicksOnly(toast: "No picks in this folder")
            return
        }
        guard picks.urls != before || !wasKnown else { return }
        refreshPicksView()
        updateHUD()
    }

    /// `url` is a pick now, or no longer (a flag written, a tag read). In the picks-only view another photo joins or
    /// leaves the view at once; the photo on screen stays until the user moves on. Returns whether the picks changed.
    @discardableResult
    private func setPicked(_ url: URL, _ picked: Bool) -> Bool {
        guard picks.set(url, picked: picked) else { return false }
        if picksOnly, url != pipeline.currentFile?.url { refreshPicksView() }
        return true
    }

    /// `view.picks_only`: browse only the picks, or every photo again. The photo on screen stays either way: a photo
    /// that is not a pick stays in the picks-only view until the user moves on (→ goes to the next pick after it).
    private func togglePicksOnly() {
        if picksOnly {
            leavePicksOnly(toast: "All photos: \(allFiles.count)")
            return
        }
        guard config.ratingStorage == .finderTags else {
            hud.showToast("Picks are off ([rating] storage = \"none\")")
            return
        }
        guard let current = pipeline.currentFile else { return }
        guard !listingPending else {
            hud.showToast("Still listing the folder")
            return
        }
        guard !picks.isEmpty || !picksKnown else {
            hud.showToast("No picks yet: P picks the photo on screen")
            return
        }
        let started = Trace.now()
        let all = pipeline.files
        // Found through the pipeline's lookup by name: the cost is the picks', not a hash of every file of the folder.
        let view = picks.view(of: all, keeping: current) { self.pipeline.index(of: $0) }
        picksOnly = true
        allFiles = all
        pipeline.setFiles(view, index: view.firstIndex(of: current) ?? 0)
        restartPrefetch()
        presentCurrent()
        updateHUD()
        hud.showToast(picksKnown ? "Picks only: \(picks.count)" : "Picks only (reading the tags…)")
        Trace.log(String(format: "picks only: %d of %d files, %.2f ms", view.count, all.count, Trace.ms(since: started)))
    }

    /// Back to every photo, on the photo at `showing` in `allFiles` (default: the photo on screen).
    private func leavePicksOnly(showing: Int? = nil, toast: String?) {
        guard picksOnly else { return }
        let started = Trace.now()
        let current = pipeline.currentFile
        // One walk of the folder puts the view's newer stamps back and says where the photo on screen is in it.
        let positions = mergeViewIntoAllFiles()
        let all = allFiles
        picksOnly = false
        allFiles = []
        let target: Int
        if let showing {
            target = showing
            beginNavigation()
        } else if positions.count == pipeline.files.count, positions.indices.contains(pipeline.index) {
            target = positions[pipeline.index]
        } else {
            target = current.flatMap { all.firstIndex(of: $0) } ?? 0  // not expected: the view is a part of the folder
        }
        pipeline.setFiles(all, index: target)
        if pipeline.currentFile == current { restartPrefetch() }
        presentCurrent()
        updateHUD()
        if let toast { hud.showToast(toast) }
        Trace.log(String(format: "all photos: %d files, %.2f ms", all.count, Trace.ms(since: started)))
    }

    /// Rebuild the picks-only view after the picks changed for photos not on screen (an undo, a redo, a read), keeping
    /// the photo on screen.
    private func refreshPicksView() {
        guard picksOnly, let current = pipeline.currentFile else { return }
        mergeViewIntoAllFiles()
        let view = picks.filter(allFiles, keeping: current)
        guard view != pipeline.files else { return }
        pipeline.setFiles(view, index: view.firstIndex(of: current) ?? 0)
        restartPrefetch()
        updateHUD()
    }

    /// The browsing set changed around the photo on screen (the picks-only view began, ended or changed): prefetch for
    /// its new neighbours as right after a key press. `setFiles` keeps the pipeline's navigation clock, so after a look
    /// at the photo longer than the prefetch horizon (2.5 s) the new neighbours would seem too far off to decode, and
    /// the next key press would find nothing ready. A step of 0 keeps the direction and the rhythm.
    private func restartPrefetch() {
        pipeline.navigate(to: pipeline.index, isRepeat: false)
        prepareNeighbours()
    }

    /// The picks-only view's newer stamps back in `allFiles` (`PickSet.merge`); returns where each entry of the view is
    /// in it.
    @discardableResult
    private func mergeViewIntoAllFiles() -> [Int] { PickSet.merge(pipeline.files, into: &allFiles) }

    /// The user moved on from `file`, which is no longer a pick: it leaves the picks-only view.
    private func dropFromPicksView(_ file: ImageFile) {
        var view = pipeline.files
        guard let i = view.firstIndex(of: file) else { return }
        view.remove(at: i)
        pipeline.setFiles(view, index: pipeline.index > i ? pipeline.index - 1 : pipeline.index)
    }

    /// Forget the picks: another folder opens, or `[rating] storage` became "none". The picks-only view ends; with
    /// `replacingFiles` the caller replaces the browsing set next, so the view's files are not put back first.
    private func forgetPicks(replacingFiles: Bool = false) {
        if picksOnly, !replacingFiles { leavePicksOnly(toast: nil) }
        // Often the last references to the previous folder's lists: freed off the main thread, since an open's first
        // decode is submitted next.
        Retired.release(allFiles, picksListing, picks, picksForgotten)
        picksOnly = false
        allFiles = []
        picks = PickSet()
        picksListing = []
        picksForgotten = []
        picksReadGeneration &+= 1
        if replacingFiles {
            // A tag read of the previous folder's photo that lands late is not about this set.
            tagReadSerials.removeAll()
        } else {
            updateHUD()
        }
    }

    /// `file.copy_picks`: every pick of the browsing set, in its order, to the target's folder. The copy reads the tags
    /// again first (another app may have changed them) and hands that read back: the counter and the view follow it.
    private func copyPicks(_ target: String) {
        guard config.ratingStorage == .finderTags else {
            hud.showToast("Picks are off ([rating] storage = \"none\")")
            return
        }
        guard let file = pipeline.currentFile else { return }
        guard !listingPending, picksKnown else {
            hud.showToast("Still reading the folder's tags: try again in a moment")
            return
        }
        let context = FileActionContext(file: file, index: pipeline.index, count: pipeline.files.count, window: window)
        let folder: URL
        switch fileActions.picksDestination(target, count: picks.count, context: context) {
        case .folder(let url): folder = url
        case .none(let result):
            handle(result)
            return
        }
        // The copy's read is the folder's newest: it replaces a read in flight, and what changes while it runs keeps
        // its newer state.
        picksReadGeneration &+= 1
        let generation = picksReadGeneration
        picks.beginRead()
        let started = Trace.now()
        handle(fileActions.copyPicks(of: browsingSet, count: picks.count, to: folder) { [weak self] read in
            guard let self, generation == self.picksReadGeneration else {
                Retired.release(read)
                return
            }
            self.finishReadingPicks(read, ms: Trace.ms(since: started))
        })
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

    /// Whether a menu item for `action` should be enabled (`keyWindow`: the app's key window).
    func canPerform(_ action: Action, plainKeyEquivalent: Bool, keyWindow: NSWindow? = NSApp.keyWindow) -> Bool {
        if plainKeyEquivalent, window?.isKeyWindow != true { return false }
        // Typing in another window (a Settings text field): the text gets the keys the menu shares with text editing,
        // such as ⌘⌫ (delete to the start of the line, not Move to Trash) and ⌘↑ / ⌘↓ (not First / Last Image).
        if let keyWindow, keyWindow !== window, keyWindow.firstResponder is NSText, !Self.appMenuActions.contains(action) {
            return false
        }
        switch action {
        case .open, .quit, .config, .configFile, .reloadConfig, .makeDefault, .help, .hud, .hudHide, .undo, .redo, .background:
            return true
        case .fullscreen, .fullscreenNative, .close, .escape:
            return window?.isVisible == true
        default:
            return pipeline.currentFile != nil
        }
    }

    /// Menu items about the app, not the image: enabled whichever window is in front.
    private static let appMenuActions: Set<Action> = [.open, .quit, .config, .configFile, .reloadConfig, .makeDefault, .close]

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
            case .configFile, .reloadConfig, .makeDefault: break  // app-level fallbacks below
            default: return
            }
        }
        if picksOnly, pipeline.files.count == 1, picksKnown, let current = pipeline.currentFile,
           !picks.contains(current) {
            // The picks-only view holds no pick any more (its one photo, on screen, was un-picked): a move goes on
            // among every photo instead of finding no pick to go to.
            switch action {
            case .next, .previous, .first, .last, .jump: leavePicksOnly(toast: "No picks left: all photos")
            default: break
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
        case .picksOnly: togglePicksOnly()
        case .copyPicks(let target): copyPicks(target)
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
        case .config:
            if let onOpenSettings { onOpenSettings() } else { openConfigFile() }
        case .configFile: openConfigFile()
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
        if let toast = FileActions.openConfigFile().toast { hud.showToast(toast) }
    }

    private func toggleHelp() {
        if hud.isHelpVisible { hud.setHelp(nil) } else { hud.setHelp(KeyLabels.helpSections(config.keymap)) }
    }

    /// Update the browsing set after a file action.
    private func handle(_ result: FileActionResult) {
        var toast = result.toast
        switch result.outcome {
        case .removed(let file):
            if remove(file), let text = toast { toast = text + " · no picks left" }
        case .restored(let file):
            restore(file)
        case .changed(let file, let picked):
            // The undo stack outlives a folder: an undo can reach a photo of the folder browsed before, whose tags are
            // not this set's.
            guard isBrowsed(file) else { break }
            if let picked, config.ratingStorage == .finderTags { setPicked(file.url, picked) }
            loadTags(for: file, force: true)
            updateHUD()
        case .unchanged:
            break
        }
        guard let toast else { return }
        switch result.progress {
        case .start?:
            progressToast = hud.showToast(toast)
        case .update?:
            // Only while the progress toast is still the one on screen: another toast, or a move to another photo, ends
            // them, so they never cover what the user did meanwhile.
            guard let shown = progressToast, hud.isShowingToast(shown) else { return }
            progressToast = hud.showToast(toast)
        case nil:
            hud.showToast(toast, seconds: result.toastSeconds ?? 1.2)
        }
    }

    /// A file action took `file` out of the browsing set (trash, a move, delete). Returns true when that emptied the
    /// picks-only view, which then ends on the photo that took the last pick's place.
    private func remove(_ file: ImageFile) -> Bool {
        var indexInAll: Int?
        if picksOnly, let k = allFiles.firstIndex(of: file) {
            allFiles.remove(at: k)
            indexInAll = k
        }
        var files = pipeline.files
        let index = files.firstIndex(of: file)
        guard index != nil || indexInAll != nil else { return false }
        listingEpoch &+= 1
        if file == unlistedFile { unlistedFile = nil }
        tags[file.url] = nil
        tagSummaries[file.url] = nil
        // A tag read in flight must not bring its tags, or its pick, back; and if the file comes back (Finder, Put
        // Back), its tags are read again.
        tagReadSerials[file.url] = nil
        picks.set(file.url, picked: false)
        picksForgotten.insert(file.url)
        guard let i = index else {
            updateHUD()  // a photo the picks-only view leaves out: only the counter changes
            return false
        }
        files.remove(at: i)
        if files.isEmpty {
            if picksOnly, !allFiles.isEmpty {
                let all = allFiles
                picksOnly = false
                allFiles = []
                beginNavigation()
                pipeline.setFiles(all, index: min(indexInAll ?? 0, all.count - 1))
                presentCurrent()
                updateHUD()
                return true
            }
            showEmpty(currentFolder)
            return false
        }
        // The file on screen went: show the one that took its place. Another one (a redo, a background move
        // that finished late): stay on the image being viewed.
        let current = pipeline.index
        if current == i { beginNavigation() }
        pipeline.setFiles(files, index: current == i ? min(i, files.count - 1) : current > i ? current - 1 : current)
        presentCurrent()
        updateHUD()
        return false
    }

    /// An undo (or a move that failed) brought `file` back: it shows again.
    private func restore(_ file: ImageFile) {
        // Back where it was, but only into the set it belongs to: an undo after opening another folder (or a
        // background move failing after the user moved on) must not inject a file of another folder.
        guard isInBrowsingSet(file) else { return }
        if picksOnly { mergeViewIntoAllFiles() }
        var files = browsingSet
        listingEpoch &+= 1
        if !files.contains(file) {
            files.append(file)
            files = NaturalSort.sort(files, by: \.name)
        }
        hud.setMessage(nil)
        beginNavigation()
        if picksOnly {
            // In the picks-only view it shows as the photo on screen (a pick once its tags are read: they travel with
            // the file); the photo on screen before is left behind if it was no longer a pick.
            Retired.release(allFiles)
            allFiles = files
            let view = picks.filter(files, keeping: file)
            pipeline.setFiles(view, index: view.firstIndex(of: file) ?? 0)
        } else {
            pipeline.setFiles(files, index: files.firstIndex(of: file) ?? pipeline.index)
        }
        presentCurrent()
        updateHUD()
        // A folder read in flight began without this file, and would drop what its tag read says: read again with it.
        if picks.isReading { readPicks() }
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

    /// `file` is one of the files browsed now: a file of the folder browsed (its path says so), or of the set opened.
    private func isBrowsed(_ file: ImageFile) -> Bool {
        switch browseSource {
        case .folder: return isInBrowsedFolder(file.url)
        case .files: return browsingSet.contains(file)
        case .none: return false
        }
    }

    // MARK: Animation

    /// Decoded frames an animation keeps: all of them when they fit (later loops decode nothing), else a window ahead.
    private var animationBudget: Int { min(pipeline.config.screenBudget / 8, 256 << 20) }

    /// `file` shows its first pixels: play it if it is an animation, once a skim past it is over and while the window is
    /// visible (`visibilityChanged` starts it later), on an exact tier (an early rendition's exact decode shows, and
    /// starts it, next). `asked`: a play / step action, which starts it in any case.
    private func startAnimationIfNeeded(_ file: ImageFile, asked: Bool = false) {
        guard player == nil, file == pipeline.currentFile, let info = pipeline.info(for: file), info.isAnimated,
              AnimationPlayer.fits(info, budgetBytes: animationBudget) else { return }
        startAnimationWork?.cancel()
        startAnimationWork = nil
        guard asked || (isWindowVisible && !shownApproximate) else { return }
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
        if shownFrame != nil {
            shownTier = nil
            shownApproximate = false
        }
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
        // Frames are exact: an early rendition shown before must not outlive them (neighbours would stay unprepared, and
        // its exact tier would replace the frame).
        shownTier = .full
        shownApproximate = false
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
            var frame = screen.frame
            if presentation == .headless { frame.origin = NSWindow.offScreenOrigin(for: frame.size) }
            window.setFrame(frame, display: true)
            rootView.topInset = notchInset(screen)
            makeKeyAndOrderFront()
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
            makeKeyAndOrderFront()
            window.makeFirstResponder(viewerView)
        }
        showChrome()
    }

    private func toggleNativeFullscreen() {
        if instantFullscreen != nil { toggleInstantFullscreen() }
        // A Space of its own on a screen: never for a headless window.
        if presentation == .interactive { window?.toggleFullScreen(nil) }
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
        // Back from System Settings, where the folder may have been allowed: list it again (off the main thread).
        if refusedListing != nil { rescanFolder() }
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
        // A folder that was refused lists now (allowed in System Settings, its permissions changed): browse it, and
        // watch it, which needed the same access.
        let allowed = refusedListing != nil
        if allowed {
            refusedListing = nil
            watchFolder()
            Trace.log("folder readable now: \(folder.lastPathComponent)")
        }
        var files = listed
        if let unlisted = unlistedFile {
            if files.contains(unlisted) || unlisted != pipeline.currentFile {
                unlistedFile = nil  // listed now, or the user moved on: it leaves the set with this listing
            } else {
                files = NaturalSort.sort(files + [unlisted], by: \.name)
            }
        }
        let fingerprint = { (list: [ImageFile]) in list.map { $0.url.path + "|" + $0.version } }
        if picksOnly { mergeViewIntoAllFiles() }
        guard allowed || fingerprint(files) != fingerprint(browsingSet) else { return }
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
        var viewEnded = false
        if picksOnly {
            // The view follows the new listing: its picks, and the photo on screen if it is still there.
            let before = allFiles
            Retired.release(allFiles)
            allFiles = files
            let kept = index.map { files[$0] }
            let view = picks.filter(files, keeping: kept)
            if view.isEmpty {
                // The last pick (and the photo on screen) left the folder: every photo again, at the photo on screen's
                // place in the folder (the pipeline's index was a place in the view).
                picksOnly = false
                allFiles = []
                let place = current.flatMap { before.firstIndex(of: $0) } ?? 0
                pipeline.setFiles(files, index: index ?? min(place, files.count - 1))
                viewEnded = true
            } else {
                pipeline.setFiles(view, index: kept.flatMap { view.firstIndex(of: $0) } ?? min(pipeline.index, view.count - 1))
            }
        } else {
            pipeline.setFiles(files, index: index ?? min(pipeline.index, files.count - 1))
        }
        if pipeline.currentFile != current { beginNavigation() }
        // The message was about the previous state (an empty folder, a removed file's error); `presentCurrent`
        // shows the current file's error again if it still has one.
        hud.setMessage(nil)
        presentCurrent()
        updateHUD()
        if viewEnded { hud.showToast("No picks left: all photos") }
        // New files (a rename gives a file a new name) may carry tags: read them.
        readPicks()
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
        if presentation == .headless, let window { observers.append(window.keepOffScreen()) }
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

    /// Windowed only: the title-bar strip always moves the window; elsewhere a drag moves it when there is nothing to
    /// pan (no image, or the image fits).
    func viewer(_: ViewerView, dragMovesWindowAt point: CGPoint) -> Bool {
        guard !isFullscreen, let window else { return false }
        let titleBar = window.frame.height - window.contentLayoutRect.height
        if point.y < titleBar { return true }
        return renderer.image == nil || !renderer.isZoomedBeyondFit
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

/// Frees lists the viewer replaced (a folder's files, the listing its picks were read for) off the main thread: when
/// the viewer held their last reference, releasing them costs the main thread 0.65 ms for 5,000 files and 18 ms for
/// 50,000 (every URL is released, cold in the cache), before the first decode of an open or after every rescan.
private final class Retired: @unchecked Sendable {
    private var values: [Any]

    private init(_ values: [Any]) { self.values = values }

    /// Keep `values` and free them on a utility queue 100 ms from now. Call it before the main thread drops its own
    /// references: by then they are gone, and the values' last release happens there.
    static func release(_ values: Any...) {
        let retired = Retired(values)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.1) { retired.values.removeAll() }
    }
}
