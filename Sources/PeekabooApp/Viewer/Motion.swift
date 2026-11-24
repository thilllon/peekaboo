import AppKit
import PeekabooCore
import QuartzCore

/// Balances `Renderer.beginInteraction()` / `endInteraction()` across overlapping gestures:
/// explicit holds (pinch, drag, held pan keys, momentum) and idle-timed touches (scroll
/// wheel, trackpad scroll and its momentum), which end 120 ms after the last event.
final class InteractionGate {
    private let begin: () -> Void
    private let end: () -> Void
    private var holds = 0
    private var touchHeld = false
    private var touchDeadline: UInt64 = 0
    private var timer: Timer?

    init(begin: @escaping () -> Void, end: @escaping () -> Void) {
        self.begin = begin
        self.end = end
    }

    func acquire() {
        holds += 1
        if holds == 1 { begin() }
    }

    func release() {
        guard holds > 0 else { return }
        holds -= 1
        if holds == 0 { end() }
    }

    /// An event of a gesture without reliable end phases.
    func touch(idleMs: Double = 120) {
        touchDeadline = Trace.now() + UInt64(idleMs * 1e6)
        if !touchHeld {
            touchHeld = true
            acquire()
        }
        if timer == nil { schedule(after: idleMs / 1000) }
    }

    private func schedule(after seconds: Double) {
        let timer = Timer(timeInterval: max(seconds, 0.001), repeats: false) { [weak self] _ in self?.fire() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func fire() {
        timer = nil
        let now = Trace.now()
        if now < touchDeadline {
            schedule(after: Double(touchDeadline - now) / 1e9)
        } else if touchHeld {
            touchHeld = false
            release()
        }
    }
}

/// Display-rate motion: held pan keys and drag momentum, driven by the view's display link
/// (follows the window's screen: 120 Hz built-in, 144 Hz external) and paused when idle.
final class MotionDriver: NSObject {
    /// Applies a pan in view points and renders; called once per display refresh while moving.
    var onPan: ((CGVector) -> Void)?
    /// Motion started / stopped (hold and release the interaction gate).
    var onActiveChanged: ((Bool) -> Void)?
    /// Viewport size in points (pan speed and tap step are relative to it).
    var viewport: () -> CGSize = { CGSize(width: 1000, height: 700) }

    private weak var view: NSView?
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private(set) var isActive = false

    /// Held pan keys: key code → direction.
    private var held: [UInt16: Action.Direction] = [:]
    /// Distance still owed to each direction so that a tap moves at least 10 % of the viewport.
    private var owed: [Action.Direction: CGFloat] = [:]
    /// Momentum velocity in points per second.
    private var velocity = CGVector.zero

    /// Fraction of the viewport per second while a pan key is held.
    var keySpeed: CGFloat = 1.4
    /// Minimum travel of one tap, as a fraction of the viewport.
    var tapStep: CGFloat = 0.1

    init(view: NSView) {
        self.view = view
        super.init()
    }

    func isHolding(keyCode: UInt16) -> Bool { held[keyCode] != nil }

    func pressPanKey(_ keyCode: UInt16, direction: Action.Direction) {
        held[keyCode] = direction
        let size = viewport()
        let extent = direction == .left || direction == .right ? size.width : size.height
        owed[direction] = max(owed[direction] ?? 0, extent * tapStep)
        velocity = .zero
        start()
    }

    /// One smooth 10 % step (menu item or a pan inside a multi-action binding).
    func tap(_ direction: Action.Direction) {
        let size = viewport()
        let extent = direction == .left || direction == .right ? size.width : size.height
        owed[direction, default: 0] += extent * tapStep
        start()
    }

    /// Returns true when the key was a held pan key.
    @discardableResult
    func releasePanKey(_ keyCode: UInt16) -> Bool { held.removeValue(forKey: keyCode) != nil }

    func releaseAllKeys() { held.removeAll() }

    /// Start momentum with `velocity` (points per second, image movement direction).
    func fling(_ v: CGVector) {
        guard hypot(v.dx, v.dy) > 80 else { return }
        velocity = v
        start()
    }

    func stopMomentum() {
        velocity = .zero
        owed.removeAll()
        if held.isEmpty { setActive(false) }
    }

    private func start() {
        setActive(true)
        if link == nil, let view {
            let link = view.displayLink(target: self, selector: #selector(tick(_:)))
            if let fps = view.window?.screen?.maximumFramesPerSecond, fps > 0 {
                link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(min(fps, 60)), maximum: Float(fps), preferred: Float(fps))
            }
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        link?.isPaused = false
        lastTimestamp = 0
    }

    func screenChanged() {
        guard let link, let fps = view?.window?.screen?.maximumFramesPerSecond, fps > 0 else { return }
        link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(min(fps, 60)), maximum: Float(fps), preferred: Float(fps))
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let dt = lastTimestamp == 0 ? link.targetTimestamp - link.timestamp : now - lastTimestamp
        lastTimestamp = now
        let step = CGFloat(min(max(dt, 1.0 / 240), 1.0 / 30))
        var delta = CGVector.zero
        let size = viewport()
        let heldDirections = Set(held.values)
        for direction in Action.Direction.allCases {
            let isHeld = heldDirections.contains(direction)
            let remaining = owed[direction] ?? 0
            guard isHeld || remaining > 0 else { continue }
            let extent = direction == .left || direction == .right ? size.width : size.height
            var distance = extent * keySpeed * step
            if !isHeld { distance = min(distance, remaining) }
            owed[direction] = max(remaining - distance, 0)
            switch direction {
            // pan.left reveals the left part: the image moves right.
            case .left: delta.dx += distance
            case .right: delta.dx -= distance
            case .up: delta.dy += distance
            case .down: delta.dy -= distance
            }
        }
        if velocity != .zero {
            delta.dx += velocity.dx * step
            delta.dy += velocity.dy * step
            let decay = CGFloat(exp(-Double(step) / 0.32))
            velocity = CGVector(dx: velocity.dx * decay, dy: velocity.dy * decay)
            if hypot(velocity.dx, velocity.dy) < 12 { velocity = .zero }
        }
        if delta != .zero { onPan?(delta) }
        let owedAny = owed.values.contains { $0 > 0.01 }
        if held.isEmpty, !owedAny, velocity == .zero {
            link.isPaused = true
            lastTimestamp = 0
            setActive(false)
        }
    }

    private func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        onActiveChanged?(active)
    }

    func invalidate() {
        link?.invalidate()
        link = nil
    }
}
