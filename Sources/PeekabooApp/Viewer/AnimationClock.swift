import AppKit
import QuartzCore

/// Paces an animation on the view's display link (the window's screen: 120 Hz built-in, 144 Hz external), running the
/// link only around frame deadlines: between them it is paused and a timer wakes it a refresh and a half early. A
/// 10 fps GIF then wakes the main thread about 20 times a second instead of 120; still images never start it.
final class AnimationClock: NSObject {
    /// One refresh: the time its frame reaches the screen and the refresh period (seconds, `CACurrentMediaTime` base).
    var onTick: ((_ target: CFTimeInterval, _ period: CFTimeInterval) -> Void)?

    private weak var view: NSView?
    private var link: CADisplayLink?
    private var wake: DispatchSourceTimer?
    private var period: CFTimeInterval = 1.0 / 120

    init(view: NSView) {
        self.view = view
        super.init()
    }

    /// Tick around `deadline` (`CACurrentMediaTime` seconds); nil stops ticking.
    func schedule(_ deadline: CFTimeInterval?) {
        guard let deadline else {
            link?.isPaused = true
            wake?.schedule(deadline: .distantFuture)
            return
        }
        let lead = deadline - CACurrentMediaTime()
        if lead > 2 * period {
            link?.isPaused = true
            armWake(after: lead - 1.5 * period)
        } else {
            wake?.schedule(deadline: .distantFuture)
            startLink()
        }
    }

    func screenChanged() {
        guard let link, let fps = view?.window?.screen?.maximumFramesPerSecond, fps > 0 else { return }
        link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(min(fps, 60)), maximum: Float(fps), preferred: Float(fps))
        period = 1 / Double(fps)
    }

    func invalidate() {
        link?.invalidate()
        link = nil
        wake?.cancel()
        wake = nil
    }

    private func startLink() {
        if link == nil, let view {
            let link = view.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
            screenChanged()
        }
        link?.isPaused = false
    }

    private func armWake(after seconds: CFTimeInterval) {
        if wake == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.setEventHandler { [weak self] in
                self?.wake?.schedule(deadline: .distantFuture)
                self?.startLink()
            }
            timer.resume()
            wake = timer
        }
        wake?.schedule(deadline: .now() + seconds, leeway: .microseconds(500))
    }

    @objc private func tick(_ link: CADisplayLink) {
        let measured = link.targetTimestamp - link.timestamp
        if measured > 0.001 && measured < 0.05 { period = measured }
        onTick?(link.targetTimestamp, period)
    }
}
