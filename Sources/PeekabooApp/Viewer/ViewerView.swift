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
}

/// Layer-hosting view whose backing layer is the renderer's `CAMetalLayer`.
final class ViewerView: NSView {
    weak var delegate: ViewerViewDelegate?
    let metalLayer = CAMetalLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    override func makeBackingLayer() -> CALayer { metalLayer }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        delegate?.viewerViewDidResize(self)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        delegate?.viewerViewDidResize(self)
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
}
