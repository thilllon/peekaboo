import AppKit
import PeekabooCore
import PeekabooRender

/// One viewer window: owns the renderer, the pipeline and the browsing state, and
/// turns key presses and gestures into actions.
///
/// Walking skeleton: navigation, zoom/pan/rotate/flip, background, fullscreen and
/// close/quit work; file actions, HUD, help, instant fullscreen and config loading
/// are added by their workstreams.
final class ViewerWindowController: NSWindowController, NSWindowDelegate, ViewerViewDelegate {
    private let viewerView: ViewerView
    private let renderer: Renderer
    private let pipeline: ImagePipeline
    private let configStore: ConfigStore
    private var config: AppConfig { configStore.config }
    private lazy var fileActions = FileActions { [weak self] in self?.configStore.config ?? .default }
    private var pendingChords: [KeyChord] = []
    private var keyMonitor: Any?
    /// File currently on screen and the tier shown for it.
    private var shownFile: ImageFile?
    private var shownTier: Tier?

    init(configStore: ConfigStore) {
        self.configStore = configStore
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.setFrameAutosaveName("PeekabooViewer")
        if window.frame.origin == .zero { window.center() }

        viewerView = ViewerView(frame: window.contentLayoutRect)
        window.contentView = viewerView
        renderer = Renderer(layer: viewerView.metalLayer)
        let pool = PixelBufferPool(device: RenderContext.shared.device)
        pipeline = ImagePipeline(decoder: ImageIODecoder(), pool: pool,
                                 config: PipelineConfig(screenLongSide: Self.largestScreenLongSide()))
        super.init(window: window)
        window.delegate = self
        viewerView.delegate = self
        renderer.onNeedsDisplay = { [weak self] in self?.renderer.render() }
        pipeline.onDecoded = { [weak self] file, image in self?.decoded(image, for: file) }
        pipeline.onFailed = { [weak self] file, error in
            Trace.log("decode failed \(file.name): \(error)")
            if file == self?.pipeline.currentFile { self?.window?.title = "\(file.name) — cannot open" }
        }
        installKeyMonitor()
        apply(configStore.config)
        viewerViewDidResize(viewerView)
    }

    /// Apply a (re)loaded configuration.
    func apply(_ config: AppConfig) {
        renderer.keepZoom = config.keepZoom
        renderer.settings.background = Background(rawValue: config.background) ?? .black
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    // MARK: Opening

    /// Show `urls`: one file browses its folder, a folder browses its images, several files browse that set.
    func open(_ urls: [URL]) {
        guard let first = urls.first else { return }
        let opened = Trace.now()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // First pixel first: decode the opened file before listing its folder.
        let isFolder = (try? first.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        if urls.count == 1, !isFolder {
            pipeline.setFiles([ImageFile(url: first, name: first.lastPathComponent, byteSize: 0, modified: 0, fileID: 0)], index: 0)
            updateTitle()
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let listing = try? FolderScanner.browse(urls)
            DispatchQueue.main.async {
                guard let self, let listing, !listing.files.isEmpty else { return }
                self.pipeline.setFiles(listing.files, index: listing.index)
                self.updateTitle()
                Trace.log("folder listed: \(listing.files.count) files, \(String(format: "%.1f", Trace.ms(since: opened))) ms after open")
            }
        }
    }

    // MARK: Pipeline → screen

    private func decoded(_ image: DecodedImage, for file: ImageFile) {
        guard file == pipeline.currentFile else { return }
        if shownFile == file, let shownTier, shownTier >= image.tier { return }
        show(image, for: file)
    }

    private func show(_ image: DecodedImage, for file: ImageFile) {
        renderer.setImage(image, key: file.url)
        shownFile = file
        shownTier = image.tier
        renderer.render()
        if renderer.wantsFullResolution { pipeline.requestFullResolution() }
        Trace.log("shown \(file.name) tier=\(image.tier) \(image.pixels.width)x\(image.pixels.height) decode=\(String(format: "%.1f", Double(image.decodeNanos) / 1e6)) ms")
    }

    private func navigate(to index: Int, isRepeat: Bool) {
        guard !pipeline.files.isEmpty else { return }
        let target = min(max(index, 0), pipeline.files.count - 1)
        guard target != pipeline.index || shownFile == nil else { return }
        pipeline.navigate(to: target, isRepeat: isRepeat)
        updateTitle()
        if let file = pipeline.currentFile, let best = pipeline.best(for: file) {
            show(best, for: file)
        }
        // Otherwise keep the previous image on screen until the first tier arrives.
    }

    private func updateTitle() {
        guard let file = pipeline.currentFile else { return }
        window?.title = "\(file.name) — \(pipeline.index + 1)/\(pipeline.files.count)"
    }

    // MARK: Keys

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let chord = KeyChord(event: event) else { return false }
        pendingChords.append(chord)
        let context: KeyContext = renderer.isZoomedBeyondFit ? .zoomed : .normal
        switch config.keymap.resolve(pendingChords, context: context) {
        case .actions(let actions):
            pendingChords.removeAll()
            for action in actions { perform(action, isRepeat: event.isARepeat) }
            return true
        case .pending:
            return true
        case .unbound:
            let consumed = pendingChords.count > 1
            pendingChords.removeAll()
            return consumed
        }
    }

    func perform(_ action: Action, isRepeat: Bool = false) {
        if fileActions.handles(action), let file = pipeline.currentFile {
            let result = fileActions.perform(action, context: FileActionContext(
                file: file, index: pipeline.index, count: pipeline.files.count, window: window))
            handle(result)
            return
        }
        switch action {
        case .next: navigate(to: pipeline.index + 1, isRepeat: isRepeat)
        case .previous: navigate(to: pipeline.index - 1, isRepeat: isRepeat)
        case .first: navigate(to: 0, isRepeat: false)
        case .last: navigate(to: pipeline.files.count - 1, isRepeat: false)
        case .jump(let n): navigate(to: pipeline.index + n, isRepeat: isRepeat)
        case .zoomFit: zoom(.fit)
        case .zoomFill: zoom(.fill)
        case .zoomActual: zoom(.scale(1))
        case .zoomSet(let factor): zoom(.scale(factor))
        case .zoomIn: zoomStep(1.25)
        case .zoomOut: zoomStep(0.8)
        case .zoomToggle: zoom(renderer.zoomMode == .fit ? .scale(1) : .fit, anchor: mouseInView())
        case .zoomKeep: renderer.keepZoom.toggle()
        case .pan(let direction): pan(direction)
        case .panCenter: zoom(renderer.zoomMode)
        case .rotateClockwise: renderer.rotate(clockwise: true); renderer.render()
        case .rotateCounterClockwise: renderer.rotate(clockwise: false); renderer.render()
        case .flipHorizontal: renderer.flip(horizontal: true); renderer.render()
        case .flipVertical: renderer.flip(horizontal: false); renderer.render()
        case .background:
            let all = Background.allCases
            renderer.settings.background = all[(all.firstIndex(of: renderer.settings.background)! + 1) % all.count]
        case .fullscreen, .fullscreenNative: window?.toggleFullScreen(nil)
        case .escape:
            if window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil) } else { window?.performClose(nil) }
        case .close: window?.performClose(nil)
        case .quit: NSApp.terminate(nil)
        default: Trace.log("action not implemented yet: \(action.id)")
        }
    }

    /// Update the browsing set after a file action.
    private func handle(_ result: FileActionResult) {
        if let toast = result.toast { Trace.log("toast: \(toast)") }
        switch result.outcome {
        case .removed(let file):
            var files = pipeline.files
            guard let i = files.firstIndex(of: file) else { return }
            files.remove(at: i)
            shownFile = nil
            pipeline.setFiles(files, index: min(i, max(files.count - 1, 0)))
            updateTitle()
            if let current = pipeline.currentFile, let best = pipeline.best(for: current) { show(best, for: current) }
        case .restored(let file):
            var files = pipeline.files
            files.append(file)
            files.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            pipeline.setFiles(files, index: files.firstIndex(of: file) ?? pipeline.index)
            updateTitle()
        case .changed, .unchanged:
            break
        }
    }

    private func zoom(_ mode: ZoomMode, anchor: CGPoint? = nil) {
        renderer.setZoom(mode, anchor: anchor)
        renderer.render()
        if renderer.wantsFullResolution { pipeline.requestFullResolution() }
    }

    private func zoomStep(_ factor: Double) {
        renderer.zoom(by: factor, anchor: mouseInView() ?? CGPoint(x: viewerView.bounds.midX, y: viewerView.bounds.midY))
        renderer.render()
        if renderer.wantsFullResolution { pipeline.requestFullResolution() }
    }

    private func pan(_ direction: Action.Direction) {
        let stepX = viewerView.bounds.width * 0.1, stepY = viewerView.bounds.height * 0.1
        switch direction {
        case .left: renderer.pan(by: CGVector(dx: stepX, dy: 0))
        case .right: renderer.pan(by: CGVector(dx: -stepX, dy: 0))
        case .up: renderer.pan(by: CGVector(dx: 0, dy: stepY))
        case .down: renderer.pan(by: CGVector(dx: 0, dy: -stepY))
        }
        renderer.render()
    }

    private func mouseInView() -> CGPoint? {
        guard let window else { return nil }
        let p = viewerView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return viewerView.bounds.contains(p) ? p : nil
    }

    // MARK: ViewerViewDelegate

    func viewerViewDidResize(_ view: ViewerView) {
        renderer.setViewSize(view.bounds.size, backingScale: window?.backingScaleFactor ?? 2)
        renderer.render()
    }

    func viewer(_ view: ViewerView, magnifyBy factor: Double, at point: CGPoint, phase: NSEvent.Phase) {
        if phase.contains(.began) { renderer.beginInteraction() }
        renderer.zoom(by: factor, anchor: point)
        renderer.render()
        if phase.contains(.ended) || phase.contains(.cancelled) {
            renderer.endInteraction()
            if renderer.wantsFullResolution { pipeline.requestFullResolution() }
        }
    }

    func viewer(_ view: ViewerView, scrollBy delta: CGVector, at point: CGPoint, precise: Bool,
                modifiers: NSEvent.ModifierFlags, phase: NSEvent.Phase) {
        if modifiers.contains(.command) || !precise {
            // Mouse wheel or ⌘-scroll: zoom around the pointer.
            renderer.zoom(by: pow(1.0025, Double(delta.dy) * (precise ? 1 : 20)), anchor: point)
        } else {
            renderer.pan(by: delta)
        }
        renderer.render()
        if phase.contains(.ended) && renderer.wantsFullResolution { pipeline.requestFullResolution() }
    }

    func viewer(_ view: ViewerView, dragBy delta: CGVector, phase: NSEvent.Phase) {
        switch phase {
        case .began: renderer.beginInteraction()
        case .ended: renderer.endInteraction()
        default:
            renderer.pan(by: delta)
            renderer.render()
        }
    }

    func viewer(_ view: ViewerView, doubleClickAt point: CGPoint) { perform(.zoomToggle) }

    func viewerSmartMagnify(_ view: ViewerView, at point: CGPoint) {
        zoom(renderer.zoomMode == .fit ? .scale(1) : .fit, anchor: point)
    }

    // MARK: Helpers

    /// Long side in device pixels of the largest attached screen (the screen tier must cover it).
    static func largestScreenLongSide() -> Int {
        let sides = NSScreen.screens.map { screen -> Int in
            let size = screen.frame.size
            return Int(max(size.width, size.height) * screen.backingScaleFactor)
        }
        return max(sides.max() ?? 3456, 1024)
    }
}
