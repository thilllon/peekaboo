import AppKit
import QuartzCore

/// Receives pointer gestures from the viewer view (view points, origin top-left).
protocol ViewerViewDelegate: AnyObject {
    func viewerViewDidResize(_ view: ViewerView)
    func viewer(_ view: ViewerView, magnifyBy factor: Double, at point: CGPoint, phase: NSEvent.Phase)
    func viewer(_ view: ViewerView, scrollBy delta: CGVector, at point: CGPoint, precise: Bool, modifiers: NSEvent.ModifierFlags, phase: NSEvent.Phase)
    func viewer(_ view: ViewerView, dragBy delta: CGVector, phase: NSEvent.Phase)
    func viewer(_ view: ViewerView, doubleClickAt point: CGPoint)
    func viewerSmartMagnify(_ view: ViewerView, at point: CGPoint)
    /// Files or folders were dropped on the window. Return false to reject the drop.
    func viewer(_ view: NSView, didDrop urls: [URL]) -> Bool
    /// The pointer moved inside the window (cursor / traffic-light auto-hide).
    func viewerPointerMoved(_ view: NSView)
}

/// `CAMetalLayer` that can report when each drawable it vends reaches the glass.
///
/// The renderer obtains drawables through `nextDrawable()`; overriding it lets the app
/// attach `addPresentedHandler` without touching the renderer. Tracking is off unless
/// tracing or the self-test enables it, so normal frames pay one branch.
final class PresentationTrackingLayer: CAMetalLayer {
    /// Called on the main thread with the tag set before the frame was rendered and the
    /// `CACurrentMediaTime`-based presentation time (0 = the drawable was dropped).
    var onPresented: ((Int, CFTimeInterval) -> Void)?
    /// Tag for the next drawable (set by the controller right before `render()`).
    var nextTag = 0
    private(set) var vendedTags: [Int] = []

    override init() { super.init() }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("unused") }

    override func nextDrawable() -> CAMetalDrawable? {
        let drawable = super.nextDrawable()
        if let drawable, let onPresented {
            let tag = nextTag
            drawable.addPresentedHandler { presented in
                let time = presented.presentedTime
                DispatchQueue.main.async { onPresented(tag, time) }
            }
        }
        return drawable
    }
}

/// Window content: black, hosts the viewer view (inset below the notch in instant full
/// screen) and accepts dropped files and folders anywhere in the window.
final class ViewerRootView: NSView {
    weak var delegate: ViewerViewDelegate?
    let viewerView: ViewerView
    /// Top inset for the image area (camera housing in notch-aware full screen).
    var topInset: CGFloat = 0 { didSet { if topInset != oldValue { needsLayout = true; layoutSubtreeIfNeeded() } } }
    private var trackingArea: NSTrackingArea?
    private var dropHighlight = false { didSet { updateDropHighlight() } }

    override init(frame: NSRect) {
        viewerView = ViewerView(frame: NSRect(origin: .zero, size: frame.size))
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layerContentsRedrawPolicy = .never
        addSubview(viewerView)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var isOpaque: Bool { true }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func layout() {
        super.layout()
        let frame = NSRect(x: 0, y: topInset, width: bounds.width, height: max(bounds.height - topInset, 1))
        if viewerView.frame != frame { viewerView.frame = frame }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layout()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { delegate?.viewerPointerMoved(self) }

    // MARK: Drag & drop

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(sender).isEmpty else { return [] }
        dropHighlight = true
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dropHighlight ? .copy : [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropHighlight = false }
    override func draggingEnded(_ sender: NSDraggingInfo) { dropHighlight = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlight = false
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        return delegate?.viewer(self, didDrop: urls) ?? false
    }

    private func updateDropHighlight() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        viewerView.dropOutline.isHidden = !dropHighlight
        CATransaction.commit()
    }
}

/// Layer-backed view whose backing layer is the renderer's `CAMetalLayer`; the HUD layers
/// are its sublayers, composited above the Metal content (no blur views).
final class ViewerView: NSView {
    weak var delegate: ViewerViewDelegate?
    let metalLayer = PresentationTrackingLayer()
    /// Container for HUD / toast / help layers (origin top-left, sized to the view).
    let overlayLayer = CALayer()
    let dropOutline = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        overlayLayer.actions = ["sublayers": NSNull(), "bounds": NSNull(), "position": NSNull()]
        metalLayer.addSublayer(overlayLayer)
        dropOutline.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
        dropOutline.borderWidth = 3
        dropOutline.isHidden = true
        overlayLayer.addSublayer(dropOutline)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    override func makeBackingLayer() -> CALayer { metalLayer }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutOverlay()
        delegate?.viewerViewDidResize(self)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        delegate?.viewerViewDidResize(self)
    }

    override func layout() {
        super.layout()
        layoutOverlay()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layoutOverlay()
    }

    func layoutOverlay() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Sublayers must use top-left coordinates. AppKit flips the layer tree of flipped views,
        // but only once the layer is attached; re-evaluated on every layout.
        if metalLayer.superlayer != nil { overlayLayer.isGeometryFlipped = !metalLayer.contentsAreFlipped() }
        overlayLayer.frame = metalLayer.bounds
        dropOutline.frame = overlayLayer.bounds.insetBy(dx: 2, dy: 2)
        CATransaction.commit()
    }

    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func magnify(with event: NSEvent) {
        delegate?.viewer(self, magnifyBy: 1 + Double(event.magnification), at: point(event), phase: event.phase)
    }

    override func smartMagnify(with event: NSEvent) { delegate?.viewerSmartMagnify(self, at: point(event)) }

    override func scrollWheel(with event: NSEvent) {
        let phase = event.phase.isEmpty ? event.momentumPhase : event.phase
        delegate?.viewer(self, scrollBy: CGVector(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY), at: point(event),
                         precise: event.hasPreciseScrollingDeltas, modifiers: event.modifierFlags, phase: phase)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { delegate?.viewer(self, doubleClickAt: point(event)); return }
        delegate?.viewer(self, dragBy: .zero, phase: .began)
    }

    override func mouseDragged(with event: NSEvent) {
        delegate?.viewer(self, dragBy: CGVector(dx: event.deltaX, dy: event.deltaY), phase: .changed)
    }

    override func mouseUp(with event: NSEvent) { delegate?.viewer(self, dragBy: .zero, phase: .ended) }

    override func mouseMoved(with event: NSEvent) { delegate?.viewerPointerMoved(self) }
}
