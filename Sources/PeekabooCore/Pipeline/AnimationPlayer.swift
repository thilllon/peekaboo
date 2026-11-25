import Foundation
import Metal

/// Plays one animated image (`ImageInfo.isAnimated`): decodes its frames off the main thread, in order, and decides at
/// each display refresh which frame is due.
///
/// Memory stays bounded: when every frame fits `budgetBytes` each one is decoded once and kept, so later loops cost no
/// decoding; otherwise a window of up to `maxAhead` frames after the shown one is kept. Frame delays follow
/// `AnimationTiming` (browser clamping), loop counts end on the last frame. A frame that is not decoded by its
/// deadline keeps the previous one on screen; once more than a frame late the timeline is re-anchored (no catch-up
/// burst).
///
/// Main-thread only. Times are seconds on one monotonic clock: the display link's `targetTimestamp` and
/// `CACurrentMediaTime()` in the app, a synthetic clock in tests and the bench.
public final class AnimationPlayer {
    public let url: URL
    public let frameCount: Int
    /// Frame on screen (or, after `step`, the one asked for while it decodes).
    public private(set) var index = 0
    public private(set) var isPlaying = false
    /// A finite loop count has played out: the last frame stays until `play`.
    public private(set) var isFinished = false
    /// Frame delays and loop count, once the decoder has read them (nil before).
    public private(set) var timing: AnimationTiming?
    /// When the next frame is due (nil while paused, finished or before the timing is known).
    public private(set) var deadline: Double?
    /// Frame `i` finished decoding (main thread); show it when it is `index` and not on screen yet.
    public var onFrameDecoded: ((Int) -> Void)?
    /// Opening the file or decoding a frame failed: playback stopped on the frame shown.
    public var onFailed: ((Error) -> Void)?

    private let info: ImageInfo
    private let pool: PixelBufferPool
    private let queue = DispatchQueue(label: "peekaboo.animation", qos: .userInitiated)
    /// The decoder, touched on `queue` only.
    private final class Box: @unchecked Sendable { var decoder: AnimationDecoder? }
    private let box = Box()
    private var frames: [PixelBuffer?]
    private var decodeNanos: [UInt64]
    private var inFlight: Int?
    private var generation = 0
    private var plays = 0
    private let keepAll: Bool
    private let window: Int
    /// When `start` was called before the timing was known.
    private var pendingStart: Double?
    /// The shown frame is the pipeline's still, not one of ours: decode the next frames first.
    private var stillOnScreen = false

    /// Decoded bytes the player keeps (frames on screen and ahead).
    public private(set) var residentBytes = 0
    /// Frames decoded so far (all loops).
    public private(set) var decodedFrames = 0

    /// `budgetBytes`: decoded frames kept at most (frames beyond it are decoded again on the next loop). Frames come
    /// from a pool of the player's own on `device`, page-granular (a shared 1 MB-granular pool turned 640 KB frames into
    /// 1 MB each) and freed with the player.
    public init(url: URL, info: ImageInfo, device: MTLDevice, budgetBytes: Int, maxAhead: Int = 8) {
        self.url = url
        self.info = info
        frameCount = max(info.frameCount, 1)
        frames = Array(repeating: nil, count: frameCount)
        decodeNanos = Array(repeating: 0, count: frameCount)
        let frameBytes = max(info.pixelWidth * info.pixelHeight * 4, 1)
        keepAll = frameBytes * frameCount <= budgetBytes
        window = keepAll ? frameCount : min(max(budgetBytes / frameBytes, 2), maxAhead)
        // A ring recycles the buffers of the frames it drops; kept frames are only freed by `stop`.
        pool = PixelBufferPool(device: device, maxRetainedBytes: keepAll ? 0 : 2 * frameBytes, granule: 16 << 10)
        let generation = self.generation
        let box = self.box
        queue.async { [weak self] in
            do {
                let decoder = try AnimationDecoder(url: url, info: info)
                box.decoder = decoder
                let timing = decoder.timing
                DispatchQueue.main.async { self?.opened(timing, generation: generation) }
            } catch {
                DispatchQueue.main.async { self?.failed(error, generation: generation) }
            }
        }
    }

    deinit { stop() }

    /// Whether every frame is kept once decoded (otherwise a window ahead of the shown frame).
    public var keepsAllFrames: Bool { keepAll }

    /// Frame `i` as an image in the file's geometry, if it is decoded.
    public func frame(_ i: Int) -> DecodedImage? {
        guard frames.indices.contains(i), let pixels = frames[i] else { return nil }
        return DecodedImage(pixels: pixels, tier: .full, fullWidth: info.orientedWidth, fullHeight: info.orientedHeight,
                            orientation: info.orientation, isHDR: false, decodeNanos: decodeNanos[i])
    }

    /// Frame 0 is on screen since `now` (the still the pipeline decoded): play from there.
    public func start(at now: Double) {
        isPlaying = true
        isFinished = false
        index = 0
        plays = 0
        stillOnScreen = true
        deadline = timing.map { now + $0.delays[0] }
        pendingStart = now
        pump()
    }

    /// The frame due at `target` (the time the next refresh reaches the screen), if it changes; nil otherwise.
    /// `tolerance`: show a frame due at most this long after `target` now rather than a refresh late (half a refresh).
    public func advance(to target: Double, tolerance: Double = 0) -> DecodedImage? {
        guard isPlaying, let timing, let due = deadline, target + tolerance >= due else { return nil }
        let next = index + 1 == frameCount ? 0 : index + 1
        if next == 0, timing.loopCount > 0, plays + 1 >= timing.loopCount {
            isPlaying = false
            isFinished = true
            deadline = nil
            return nil
        }
        guard let image = frame(next) else {
            pump()   // late: the previous frame stays; shown as soon as it arrives
            return nil
        }
        if next == 0 { plays += 1 }
        index = next
        stillOnScreen = false
        let delay = timing.delays[next]
        // Ideal timeline (no drift), re-anchored when more than one frame late (no catch-up burst after a stall).
        deadline = target - due > delay ? target + delay : due + delay
        trim()
        pump()
        return image
    }

    /// Resume (or, when finished, restart from frame 0, which is returned to show now).
    @discardableResult
    public func play(at now: Double) -> DecodedImage? {
        var restart: DecodedImage?
        if isFinished {
            isFinished = false
            plays = 0
            index = 0
            stillOnScreen = false
            restart = frame(0)
        }
        isPlaying = true
        deadline = timing.map { now + $0.delays[index] }
        pump()
        return restart
    }

    public func pause() {
        isPlaying = false
        deadline = nil
    }

    /// Pause and move `delta` frames (wrapping). Returns the frame if it is decoded; otherwise `onFrameDecoded` reports
    /// it when it is.
    public func step(_ delta: Int) -> DecodedImage? {
        pause()
        isFinished = false
        stillOnScreen = false
        index = ((index + delta) % frameCount + frameCount) % frameCount
        trim()
        pump()
        return frame(index)
    }

    /// Give back every decoded frame except the one shown (memory pressure); they are decoded again when needed.
    public func trimToCurrent() {
        var released: [PixelBuffer] = []
        for i in frames.indices where i != index {
            if let pixels = frames[i] { released.append(pixels); frames[i] = nil }
        }
        account(released)
    }

    /// Stop decoding and release every frame (off the main thread).
    public func stop() {
        generation &+= 1
        isPlaying = false
        deadline = nil
        let released = frames.compactMap { $0 }
        frames = Array(repeating: nil, count: frameCount)
        residentBytes = 0
        inFlight = nil
        let box = self.box
        queue.async { box.decoder = nil }   // the source is released on its own queue
        Self.release(released)
    }

    // MARK: Decoding

    private func opened(_ timing: AnimationTiming, generation: Int) {
        guard generation == self.generation else { return }
        self.timing = timing
        if isPlaying, deadline == nil, let start = pendingStart { deadline = start + timing.delays[index] }
        pump()
    }

    private func failed(_ error: Error, generation: Int) {
        guard generation == self.generation else { return }
        Trace.log("animation \(url.lastPathComponent): \(error)")
        isPlaying = false
        deadline = nil
        onFailed?(error)
    }

    /// Frames wanted now, in decode order: the shown one, then the window ahead (the shown one last while it is the
    /// pipeline's still: the next frame is due first).
    private func wanted() -> [Int] {
        let ahead = keepAll ? frameCount - 1 : min(window, frameCount - 1)
        let upcoming = (0..<ahead).map { (index + 1 + $0) % frameCount }
        return stillOnScreen ? upcoming + [index] : [index] + upcoming
    }

    /// Start the next missing frame of the window (one decode at a time, in order).
    private func pump() {
        guard inFlight == nil, timing != nil, let next = wanted().first(where: { frames[$0] == nil }) else { return }
        inFlight = next
        let generation = self.generation
        let pool = self.pool
        let box = self.box
        queue.async { [weak self] in
            guard let decoder = box.decoder else { return }
            let start = Trace.now()
            let result = Result { try decoder.frame(next, pool: pool) }
            let nanos = Trace.now() - start
            DispatchQueue.main.async { self?.delivered(next, result, nanos: nanos, generation: generation) }
        }
    }

    private func delivered(_ i: Int, _ result: Result<PixelBuffer, Error>, nanos: UInt64, generation: Int) {
        guard generation == self.generation else { return }
        inFlight = nil
        switch result {
        case .success(let pixels):
            decodedFrames += 1
            guard wanted().contains(i) else {
                Self.release([pixels])
                pump()
                return
            }
            frames[i] = pixels
            decodeNanos[i] = nanos
            residentBytes += pixels.allocatedBytes
            onFrameDecoded?(i)
            pump()
        case .failure(let error):
            failed(error, generation: generation)
        }
    }

    /// Drop frames outside the window (ring mode only).
    private func trim() {
        guard !keepAll else { return }
        let keep = Set(wanted())
        var released: [PixelBuffer] = []
        for i in frames.indices where !keep.contains(i) {
            if let pixels = frames[i] { released.append(pixels); frames[i] = nil }
        }
        account(released)
    }

    private func account(_ released: [PixelBuffer]) {
        guard !released.isEmpty else { return }
        residentBytes -= released.reduce(0) { $0 + $1.allocatedBytes }
        Self.release(released)
    }

    /// The last release of a large buffer unmaps it: not on the main thread.
    private static func release(_ buffers: [PixelBuffer]) {
        guard !buffers.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { _ = buffers }
    }
}
