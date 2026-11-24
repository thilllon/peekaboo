import CoreGraphics
import Foundation
import ImageIO
import Metal
import PeekabooCore
import QuartzCore
import simd

/// How the image is scaled into the view.
public enum ZoomMode: Equatable, Sendable {
    /// Whole image visible.
    case fit
    /// View completely covered.
    case fill
    /// Fixed magnification: device pixels per image pixel (1 = 100 %).
    case scale(Double)
}

public enum Background: String, Sendable, CaseIterable {
    case black, gray, checker
}

/// Kernel of the high-quality residual pass (the pyramid is always Lanczos-3).
public enum ResampleFilter: String, Sendable, CaseIterable {
    /// Lanczos-3: matches a direct offline Lanczos-3 resample (48–74 dB).
    case reference
    /// Magic Kernel Sharp 2013 (sharpens slightly).
    case crisp
    /// Mitchell–Netravali (B = C = 1/3).
    case soft
    /// Magic Kernel Sharp 2021 (spectrally flat).
    case flat

    var id: Int32 { switch self { case .reference: return 0; case .soft: return 1; case .crisp: return 2; case .flat: return 3 } }
    var radius: Double { switch self { case .reference: return 3; case .soft: return 2; case .crisp: return 2.5; case .flat: return 4.5 } }
    var bc: (Float, Float) { self == .soft ? (1.0 / 3, 1.0 / 3) : (0, 0) }
}

public struct RenderSettings: Sendable, Equatable {
    public var background: Background = .black
    /// Kernel of the high-quality pass.
    public var filter: ResampleFilter = .reference
    /// −2…+2; positive values sharpen (kernel blur = 1 − 0.05·sharpness).
    public var sharpness: Double = 0
    /// Delay of the high-quality re-rasterisation after a gesture settles (0: every frame is high quality).
    public var refineDelayMs: Double = 90
    /// Draw the texel grid at ≥ 800 %.
    public var pixelGrid: Bool = false
    /// Libplacebo-style anti-ringing: 0.5 when shrinking, 0.6 when enlarging.
    public var antiRinging: Bool = true
    public init() {}
}

/// Process-wide GPU objects. `prewarm()` creates the device and compiles shaders on a
/// background thread at launch so the first window never waits for them (R6: fully hidden
/// behind AppKit initialisation).
public final class RenderContext: @unchecked Sendable {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    let presentSDR: MTLRenderPipelineState
    let presentFloat: MTLRenderPipelineState
    let axisWeights: MTLComputePipelineState
    let resampleHLevel: MTLComputePipelineState
    let resampleHFast: MTLComputePipelineState
    let resampleHFastSigmoid: MTLComputePipelineState
    let resampleHGeneral: MTLComputePipelineState
    let resampleVLinear: MTLComputePipelineState
    let resampleVSigmoid: MTLComputePipelineState
    let downHLevel: MTLComputePipelineState
    let downHSource: MTLComputePipelineState
    let downV: MTLComputePipelineState
    let convertLinear: MTLComputePipelineState
    /// 1×1 texture bound to unused slots.
    let dummy: MTLTexture

    private static let lock = NSLock()
    private static var started = false
    private static var instance: RenderContext?
    private static let ready = DispatchSemaphore(value: 0)

    /// Start GPU initialisation on a background thread (idempotent). Call first thing in `main`.
    public static func prewarm() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true
        let thread = Thread {
            let context = RenderContext()
            lock.lock(); instance = context; lock.unlock()
            ready.signal()
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// The shared context, waiting for `prewarm()` to finish if needed.
    public static var shared: RenderContext {
        prewarm()
        ready.wait()
        ready.signal()
        lock.lock(); defer { lock.unlock() }
        return instance!
    }

    private init() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Peekaboo requires a Metal device")
        }
        self.device = device
        self.queue = queue
        let start = Trace.now()
        do {
            let options = MTLCompileOptions()
            options.mathMode = .fast
            let library = try device.makeLibrary(source: Shaders.source, options: options)
            func compute(_ name: String) throws -> MTLComputePipelineState {
                try device.makeComputePipelineState(function: library.makeFunction(name: name)!)
            }
            func present(_ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "fullscreenVS")
                descriptor.fragmentFunction = library.makeFunction(name: "presentFS")
                descriptor.colorAttachments[0].pixelFormat = format
                return try device.makeRenderPipelineState(descriptor: descriptor)
            }
            presentSDR = try present(.bgra8Unorm)
            presentFloat = try present(.rgba16Float)
            axisWeights = try compute("axisWeights")
            resampleHLevel = try compute("resampleH_level")
            resampleHFast = try compute("resampleH_fast")
            resampleHFastSigmoid = try compute("resampleH_fastSigmoid")
            resampleHGeneral = try compute("resampleH_general")
            resampleVLinear = try compute("resampleV_linear")
            resampleVSigmoid = try compute("resampleV_sigmoid")
            downHLevel = try compute("downH_level")
            downHSource = try compute("downH_source")
            downV = try compute("downV")
            convertLinear = try compute("convertLinear")
        } catch {
            fatalError("shader compilation failed: \(error)")
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .shared
        dummy = device.makeTexture(descriptor: d)!
        Trace.log("render context ready in \(String(format: "%.1f", Trace.ms(since: start))) ms")
    }

    func presentPipeline(for format: MTLPixelFormat) -> MTLRenderPipelineState {
        format == .rgba16Float ? presentFloat : presentSDR
    }

    /// Bind the level-0 tiles of `image` to compute texture slots 0..<16.
    func bindTiles(_ encoder: MTLComputeCommandEncoder, _ image: GPUImage?) {
        encoder.setTextures(tileArray(image), range: 0..<16)
    }

    func tileArray(_ image: GPUImage?) -> [MTLTexture?] {
        var list: [MTLTexture?] = Array(repeating: dummy, count: 16)
        if let image { for (i, t) in image.tiles.prefix(16).enumerated() { list[i] = t } }
        return list
    }
}

// MARK: - Geometry helpers

/// A signed permutation matrix [[a, b], [c, d]] (the dihedral group of the square): EXIF orientations,
/// quarter turns and flips. Acts on centred coordinates.
struct Perm: Equatable {
    var a: Int, b: Int, c: Int, d: Int
    static let identity = Perm(a: 1, b: 0, c: 0, d: 1)
    static let clockwise = Perm(a: 0, b: -1, c: 1, d: 0)
    static let flipH = Perm(a: -1, b: 0, c: 0, d: 1)
    static let flipV = Perm(a: 1, b: 0, c: 0, d: -1)

    static func * (l: Perm, r: Perm) -> Perm {
        Perm(a: l.a * r.a + l.b * r.c, b: l.a * r.b + l.b * r.d, c: l.c * r.a + l.d * r.c, d: l.c * r.b + l.d * r.d)
    }
    var transposed: Perm { Perm(a: a, b: c, c: b, d: d) }
    var swapsAxes: Bool { a == 0 }
    func apply(_ v: SIMD2<Double>) -> SIMD2<Double> { SIMD2(Double(a) * v.x + Double(b) * v.y, Double(c) * v.x + Double(d) * v.y) }
    func apply(_ v: SIMD2<Int>) -> SIMD2<Int> { SIMD2(a * v.x + b * v.y, c * v.x + d * v.y) }

    /// Stored pixels -> displayed (oriented) pixels for an EXIF orientation.
    static func exif(_ o: CGImagePropertyOrientation) -> Perm {
        switch o {
        case .up: return .identity
        case .upMirrored: return Perm(a: -1, b: 0, c: 0, d: 1)
        case .down: return Perm(a: -1, b: 0, c: 0, d: -1)
        case .downMirrored: return Perm(a: 1, b: 0, c: 0, d: -1)
        case .leftMirrored: return Perm(a: 0, b: 1, c: 1, d: 0)
        case .right: return Perm(a: 0, b: -1, c: 1, d: 0)
        case .rightMirrored: return Perm(a: 0, b: -1, c: -1, d: 0)
        case .left: return Perm(a: 0, b: 1, c: -1, d: 0)
        @unknown default: return .identity
        }
    }
}

// MSL mirrors.
struct RP {
    var ox: Float = 0, oy: Float = 0, sx: Float = 1, sy: Float = 1, kx: Float = 1, ky: Float = 1
    var radius: Float = 3, antiring: Float = 0, B: Float = 0, C: Float = 0
    var filter: Int32 = 0, srcW: Int32 = 1, srcH: Int32 = 1, dstW: Int32 = 1, dstH: Int32 = 1
    var rowStart: Int32 = 0, dstRow0: Int32 = 0, light: Int32 = 0, fromLevel0: Int32 = 0, tmpRows: Int32 = 1
}

struct AW { var o: Float = 0, s: Float = 1, k: Float = 1, radius: Float = 3, B: Float = 0, C: Float = 0; var filter: Int32 = 0, n: Int32 = 0 }

struct PresentP {
    var imageRect = SIMD4<Float>(0, 0, 0, 0)
    var bg0 = SIMD4<Float>(0, 0, 0, 1), bg1 = SIMD4<Float>(0, 0, 0, 1)
    var m0 = SIMD2<Float>(1, 0), m1 = SIMD2<Float>(0, 1), off = SIMD2<Float>(0, 0)
    var p0 = SIMD2<Int32>(1, 0), p1 = SIMD2<Int32>(0, 1), t = SIMD2<Int32>(0, 0)
    var canvasSize = SIMD2<Int32>(1, 1)
    var checker: Float = 0
    var mode: Int32 = 0
    var encode: Int32 = 1
    var ditherAmp: Float = 1.0 / 255.0
    var zoom: Float = 1
    var gridAlpha: Float = 0
    var lod: Float = 0
    var levelA: Int32 = 0
    var levelB: Int32 = -1
    var pad0: Int32 = 0, pad1: Int32 = 0, pad2: Int32 = 0
}

/// Draws one image into a `CAMetalLayer` with zoom, pan, rotation and flips — PPR (Peekaboo Progressive Resampler).
///
/// Coordinates: view points, origin top-left, y down. Main-thread only.
///
/// Every stage draws in one image coordinate system (full-resolution stored pixels), so swapping in a better tier
/// never moves the picture: Stage 0 previews use a cubic B-spline; screen and full tiers use a linear-light Lanczos-3
/// pyramid plus a constant-cost residual Lanczos-3 pass (r ∈ [1, 2)) rendered into a canvas; 1:1 is an exact copy,
/// ≥ 400 % sharp-bilinear; gestures draw trilinear and re-rasterise `refineDelayMs` after they settle.
public final class Renderer {
    public static let drawableFormat: MTLPixelFormat = .bgra8Unorm

    public let layer: CAMetalLayer
    public var settings = RenderSettings() {
        didSet {
            guard settings != oldValue else { return }
            if settings.filter != oldValue.filter || settings.sharpness != oldValue.sharpness
                || settings.antiRinging != oldValue.antiRinging { canvas = nil }
            requestDisplay()
        }
    }
    /// Keep zoom and pan when switching to another image.
    public var keepZoom = false
    /// Asks the host to call `render()` soon (e.g. a refinement became available).
    public var onNeedsDisplay: (() -> Void)?

    public private(set) var zoomMode: ZoomMode = .fit
    public private(set) var image: DecodedImage?
    public private(set) var quarterTurns = 0
    public private(set) var flippedHorizontally = false
    public private(set) var flippedVertically = false
    /// GPU time of the last completed frame (ms), for tracing and the bench.
    public private(set) var lastFrameGPUms: Double = 0
    /// Which path drew the last frame (tracing, tests).
    public private(set) var lastPath = "none"

    private let context: RenderContext
    private var gpu: GPUImage?
    private var imageKey: AnyHashable?
    private var viewSize = CGSize(width: 1, height: 1)
    private var backingScale: CGFloat = 2
    /// Image-space point (display orientation, full-resolution pixels) at the view centre.
    private var center = SIMD2<Double>(0, 0)

    // HQ canvas (linear Display P3, premultiplied, stored-axis orientation).
    private struct Canvas {
        let texture: MTLTexture
        let width: Int, height: Int
        let key: AnyHashable?
        let source: ObjectIdentifier
        let level: Int
        let f: Double
        let minv: Perm
        /// Stored-space position of canvas pixel (0,0)'s centre.
        let origin: SIMD2<Double>
        let drawable: SIMD2<Double>
    }
    private var canvas: Canvas?
    private var offscreenTarget: MTLTexture?
    private var canvasTexture: MTLTexture?
    private var tmpTexture: MTLTexture?
    private var tables: (fx: MTLBuffer, wx: MTLBuffer, fy: MTLBuffer, wy: MTLBuffer, capacity: Int)?
    private static let tmpRowsCapacity = 2048
    private static let panMargin = 128

    // Interaction / refinement.
    private var interacting = false
    private var cheapUntil: UInt64 = 0
    private var lastFrameWasCheap = false
    private var refineWork: DispatchWorkItem?
    /// The last frame used a lower pyramid level than wanted: redraw when it becomes ready.
    private var waitingForLevel = false
    /// The previous tier of the same file, drawn while the new tier's pyramid level builds.
    private var previousTier: GPUImage?

    // Prepared neighbours (GPU resources built ahead of time).
    private var prepared: [(id: ObjectIdentifier, gpu: GPUImage)] = []
    private static let preparedLimit = 4

    private var hdrActive = false

    public init(layer: CAMetalLayer) {
        context = RenderContext.shared
        self.layer = layer
        layer.device = context.device
        layer.pixelFormat = Self.drawableFormat
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        layer.maximumDrawableCount = 3
    }

    // MARK: Content

    /// Show `image`. A different `key` (another file) resets rotation and — unless `keepZoom` — the view;
    /// the same key with a better tier swaps pixels in place without moving anything.
    public func setImage(_ image: DecodedImage?, key: AnyHashable?) {
        let isNewFile = key != imageKey
        self.image = image
        imageKey = key
        let previous = gpu
        gpu = image.map { gpuImage(for: $0) }
        if let previous, previous !== gpu, !prepared.contains(where: { $0.gpu === previous }) { previous.cancel() }
        if isNewFile {
            previousTier = nil
        } else if let previous, previous !== gpu, previous.isUsable {
            previousTier = previous
        }
        if let gpu {
            gpu.onLevelReady = { [weak self, weak gpu] _ in
                guard let self, let gpu, gpu === self.gpu else { return }
                if self.waitingForLevel { self.requestDisplay() }
            }
            gpu.startPyramid(context: context)
        }
        if isNewFile {
            canvas = nil
            quarterTurns = 0
            flippedHorizontally = false
            flippedVertically = false
            if !keepZoom { zoomMode = .fit }
            center = displaySize / 2
        }
        configureDynamicRange(hdr: image?.isHDR ?? false)
        clampCenter()
    }

    /// Build GPU resources (textures, colour transform, pyramid) for an image that will probably be shown next,
    /// off the critical path. Cheap on the calling (main) thread; the pyramid builds in the background.
    public func prepare(_ image: DecodedImage) {
        let gpu = gpuImage(for: image)
        gpu.startPyramid(context: context)
    }

    private func gpuImage(for image: DecodedImage) -> GPUImage {
        let id = ObjectIdentifier(image.pixels)
        if let current = gpu, ObjectIdentifier(current.image.pixels) == id { return current }
        if let index = prepared.firstIndex(where: { $0.id == id }) {
            let hit = prepared.remove(at: index)
            prepared.append(hit)
            return hit.gpu
        }
        let made = GPUImage(image: image, device: context.device)
        prepared.append((id, made))
        while prepared.count > Self.preparedLimit {
            let evicted = prepared.removeFirst()
            if evicted.gpu !== gpu { evicted.gpu.cancel() }
        }
        return made
    }

    private func configureDynamicRange(hdr: Bool) {
        guard hdr != hdrActive else { return }
        hdrActive = hdr
        canvas = nil
        if hdr {
            layer.pixelFormat = .rgba16Float
            layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            layer.wantsExtendedDynamicRangeContent = true
            layer.preferredDynamicRange = .high
        } else {
            layer.pixelFormat = Self.drawableFormat
            layer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
            layer.wantsExtendedDynamicRangeContent = false
            layer.preferredDynamicRange = .standard
        }
    }

    // MARK: Geometry

    /// View size in points and the backing scale factor (device pixels per point).
    public func setViewSize(_ size: CGSize, backingScale scale: CGFloat) {
        viewSize = CGSize(width: max(size.width, 1), height: max(size.height, 1))
        backingScale = max(scale, 1)
        layer.contentsScale = backingScale
        layer.drawableSize = CGSize(width: viewSize.width * backingScale, height: viewSize.height * backingScale)
        clampCenter()
    }

    /// Device pixels per full-resolution image pixel right now.
    public var effectiveScale: Double {
        let display = displaySize
        guard display.x > 0, display.y > 0 else { return 1 }
        let drawable = drawableSize
        switch zoomMode {
        case .fit: return min(drawable.x / display.x, drawable.y / display.y)
        case .fill: return max(drawable.x / display.x, drawable.y / display.y)
        case .scale(let s): return s
        }
    }

    /// True when the view shows more detail than the current tier holds (ask the pipeline for `.full`).
    public var wantsFullResolution: Bool {
        guard let image, image.tier != .full else { return false }
        let tierLong = Double(max(image.pixels.width, image.pixels.height))
        let fullLong = Double(max(image.fullWidth, image.fullHeight))
        return effectiveScale * fullLong / max(tierLong, 1) > 1.01
    }

    /// True when the image is larger than the view (panning is meaningful).
    public var isZoomedBeyondFit: Bool {
        let display = displaySize * effectiveScale
        return display.x > drawableSize.x + 0.5 || display.y > drawableSize.y + 0.5
    }

    public func setZoom(_ mode: ZoomMode, anchor: CGPoint? = nil) {
        let before = effectiveScale
        let anchorImage = anchor.map(imagePoint(atView:))
        zoomMode = mode
        if let anchor, let anchorImage {
            keep(anchorImage, at: anchor)
        } else if mode == .fit || mode == .fill {
            center = displaySize / 2
        }
        clampCenter()
        if effectiveScale != before { zoomDidChange() }
    }

    /// Multiply the magnification, keeping the image point under `anchor` fixed.
    public func zoom(by factor: Double, anchor: CGPoint) {
        let target = min(max(effectiveScale * factor, minimumScale), 64)
        setZoom(.scale(target), anchor: anchor)
    }

    /// Move the image by `delta` view points (positive x moves the image right).
    public func pan(by delta: CGVector) {
        let s = effectiveScale
        center.x -= Double(delta.dx) * Double(backingScale) / s
        center.y -= Double(delta.dy) * Double(backingScale) / s
        clampCenter()
    }

    public func rotate(clockwise: Bool) {
        quarterTurns = (quarterTurns + (clockwise ? 1 : 3)) % 4
        center = displaySize / 2
        clampCenter()
    }

    public func flip(horizontal: Bool) {
        if horizontal { flippedHorizontally.toggle() } else { flippedVertically.toggle() }
    }

    /// Gestures (pinch, scroll, drag) in progress: the renderer uses its cheap path while the zoom changes and
    /// re-rasterises at full quality `refineDelayMs` after the zoom settles or `endInteraction()`.
    public func beginInteraction() { interacting = true }

    public func endInteraction() {
        interacting = false
        if lastFrameWasCheap { scheduleRefine() } else { requestDisplay() }
    }

    private func zoomDidChange() {
        guard interacting, settings.refineDelayMs > 0 else { return }
        scheduleRefine()
    }

    private func scheduleRefine() {
        let delay = max(0, settings.refineDelayMs) / 1000
        cheapUntil = Trace.now() + UInt64(delay * 1e9)
        refineWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.refineWork = nil
            self.cheapUntil = 0
            if self.lastFrameWasCheap || self.canvas == nil { self.requestDisplay() }
        }
        refineWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Drawing

    /// Encode and present a frame now.
    public func render() {
        guard let drawable = layer.nextDrawable(),
              let commands = context.queue.makeCommandBuffer() else { return }
        commands.label = "frame"
        encodeFrame(commands, target: drawable.texture)
        commands.present(drawable)
        commands.commit()
    }

    /// Render the current view into a new texture (tests and `peekaboo-bench`). `rgba16Float` returns linear
    /// Display P3 without dither; `bgra8Unorm` matches the SDR drawable. Waits for the GPU.
    /// `reuseTarget` renders into the texture returned by the previous call when size and format match (bench).
    public func renderOffscreen(size: CGSize? = nil, format: MTLPixelFormat = .rgba16Float, reuseTarget: Bool = false) -> MTLTexture? {
        let px = size ?? CGSize(width: drawableSize.x, height: drawableSize.y)
        let w = max(1, Int(px.width)), h = max(1, Int(px.height))
        var target: MTLTexture? = nil
        if reuseTarget, let t = offscreenTarget, t.width == w, t.height == h, t.pixelFormat == format { target = t }
        if target == nil {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .shared
            target = context.device.makeTexture(descriptor: d)
            if reuseTarget { offscreenTarget = target }
        }
        guard let target, let commands = context.queue.makeCommandBuffer() else { return nil }
        encodeFrame(commands, target: target)
        commands.commit()
        commands.waitUntilCompleted()
        lastFrameGPUms = (commands.gpuEndTime - commands.gpuStartTime) * 1000
        return target
    }

    /// Whether the pyramid of `image` (shown or prepared) is complete — for the bench and tests.
    public func isPyramidComplete(for image: DecodedImage) -> Bool {
        guard let g = knownGPUImage(image) else { return false }
        return g.maxLevel < g.firstLevel || g.readyLevel >= g.maxLevel
    }

    /// Wall and GPU time of the finished pyramid build of `image` (bench).
    public func pyramidBuildTime(for image: DecodedImage) -> (wallMs: Double, gpuMs: Double)? {
        knownGPUImage(image)?.pyramidStats
    }

    /// Drop the cached high-quality canvas so the next frame re-rasterises (bench, tests).
    public func discardCanvas() { canvas = nil }

    private func knownGPUImage(_ image: DecodedImage) -> GPUImage? {
        let id = ObjectIdentifier(image.pixels)
        if let gpu, ObjectIdentifier(gpu.image.pixels) == id { return gpu }
        return prepared.first(where: { $0.id == id })?.gpu
    }

    private enum Mode: Int32 { case background = 0, canvas = 1, exact = 2, bspline = 3, sharp = 4, trilinear = 5 }

    private func encodeFrame(_ commands: MTLCommandBuffer, target: MTLTexture) {
        let start = Trace.now()
        let isFloat = target.pixelFormat == .rgba16Float
        var q = PresentP()
        q.encode = isFloat ? 0 : 1
        q.ditherAmp = isFloat ? 0 : 1.0 / 255.0
        applyBackground(&q, linearOutput: isFloat)
        let D = SIMD2(Double(target.width), Double(target.height))
        var canvasTex: MTLTexture?
        var levelA: MTLTexture?, levelB: MTLTexture?
        var mode = Mode.background
        var g = gpu?.isUsable == true ? gpu : nil
        lastFrameWasCheap = false
        waitingForLevel = false
        // A new tier whose pyramid level is still building: keep drawing the previous tier of the same file
        // (same geometry) instead of an aliased frame; redraw when the level is ready.
        if let current = g {
            if current.readyLevel >= current.maxLevel { previousTier = nil }
            let f = 1 / effectiveScaleFor(drawable: D)
            if levelMissing(current, f: f), let prev = previousTier, prev.isUsable,
               !levelMissing(prev, f: f) || prev.image.tier == .preview {
                g = prev
                waitingForLevel = true
            }
        }

        if let g {
            let image = g.image
            // Geometry: stored (pre-orientation) full-resolution pixels -> display -> drawable.
            let s = effectiveScaleFor(drawable: D)
            let f = 1 / s
            let m = orientationPerm(image)
            let minv = m.transposed
            let disp = displaySize
            let stored = SIMD2(g.storedWidth, g.storedHeight)
            let c0 = minv.apply(center - disp / 2) + stored / 2
            let ts = SIMD2(g.scaleX, g.scaleY)
            let x0 = (0 - center.x) * s + D.x / 2, y0 = (0 - center.y) * s + D.y / 2
            let x1 = (disp.x - center.x) * s + D.x / 2, y1 = (disp.y - center.y) * s + D.y / 2
            q.imageRect = SIMD4(Float(x0), Float(y0), Float(x1), Float(y1))
            // drawable pixel centre -> tier texel: pos = At·q + bt
            let r0 = minv.apply(SIMD2<Double>(1, 0)), r1 = minv.apply(SIMD2<Double>(0, 1))  // columns of minv
            let At = (SIMD2(f * ts.x * r0.x, f * ts.x * r1.x), SIMD2(f * ts.y * r0.y, f * ts.y * r1.y))
            let bt = ts * (c0 - f * minv.apply(D / 2))
            q.m0 = SIMD2(Float(At.0.x), Float(At.0.y))
            q.m1 = SIMD2(Float(At.1.x), Float(At.1.y))
            q.off = SIMD2(Float(bt.x), Float(bt.y))
            q.p0 = SIMD2(Int32(minv.a), Int32(minv.b))
            q.p1 = SIMD2(Int32(minv.c), Int32(minv.d))
            let fT = f * max(ts.x, ts.y)
            let zoomT = 1 / fT
            q.zoom = Float(zoomT)
            let vis = (max(0, Int(floor(x0))), max(0, Int(floor(y0))), min(Int(D.x), Int(ceil(x1))), min(Int(D.y), Int(ceil(y1))))
            let visible = vis.0 < vis.2 && vis.1 < vis.3
            let wanted = fT > 1 + 1e-9 ? min(Int(floor(log2(fT) + 1e-9)), g.maxLevel) : 0
            let exactScale = abs(f * ts.x - 1) < 1e-6 && abs(f * ts.y - 1) < 1e-6
            let tReal = SIMD2(At.0.x * 0.5 + At.0.y * 0.5, At.1.x * 0.5 + At.1.y * 0.5) + bt - 0.5
            let tRound = SIMD2(tReal.x.rounded(), tReal.y.rounded())
            let snapAllowed = g.isFullResolution && zoomMode == .scale(1)
            let integral = abs(tReal.x - tRound.x) < 0.01 && abs(tReal.y - tRound.y) < 0.01

            if !visible {
                mode = .background
            } else if exactScale && (integral || snapAllowed) {
                mode = .exact
                q.t = SIMD2(Int32(tRound.x), Int32(tRound.y))
            } else if g.isFullResolution && s >= 4 {
                mode = .sharp
                if settings.pixelGrid && s >= 8 { q.gridAlpha = 0.35 }
            } else if image.tier == .preview && fT <= 1 + 1e-9 {
                mode = .bspline
                levelA = linearPreview(g, commands)
            } else {
                let sameView: (Canvas) -> Bool = { c in c.f == f && c.minv == minv && c.drawable == D }
                let reusable: Canvas? = {
                    guard let c = canvas, sameView(c) else { return nil }
                    if c.source == ObjectIdentifier(g) { return c.level >= g.bestLevel(atMost: wanted) ? c : nil }
                    // Same file, previous tier: keep showing it until the new tier's level is ready.
                    if c.key == imageKey, g.bestLevel(atMost: wanted) < wanted { return c }
                    return nil
                }()
                let canvasT: (Canvas) -> (SIMD2<Int>, Bool) = { c in
                    let tr = (c0 - c.origin) / f + minv.apply(SIMD2(0.5, 0.5) - D / 2)
                    let t = SIMD2(Int(tr.x.rounded()), Int(tr.y.rounded()))
                    let corners = [SIMD2(vis.0, vis.1), SIMD2(vis.2 - 1, vis.1), SIMD2(vis.0, vis.3 - 1), SIMD2(vis.2 - 1, vis.3 - 1)]
                    let inside = corners.allSatisfy { p in
                        let u = minv.apply(p) &+ t
                        return u.x >= 0 && u.y >= 0 && u.x < c.width && u.y < c.height
                    }
                    return (t, inside)
                }
                if let c = reusable, case let (t, inside) = canvasT(c), inside {
                    mode = .canvas
                    canvasTex = c.texture
                    q.t = SIMD2(Int32(t.x), Int32(t.y))
                    q.canvasSize = SIMD2(Int32(c.width), Int32(c.height))
                    if c.source != ObjectIdentifier(g) || c.level < wanted { waitingForLevel = true }
                } else if Trace.now() < cheapUntil || g.bestLevel(atMost: wanted) < wanted && image.tier != .preview && wanted > 0 {
                    // Gesture path (or the wanted level is still building): trilinear over the pyramid.
                    mode = .trilinear
                    lastFrameWasCheap = true
                    let lod = max(0, log2(fT))
                    q.lod = Float(lod)
                    let la = g.bestLevel(atMost: Int(floor(lod)))
                    q.levelA = Int32(la)
                    levelA = la > 0 ? g.levels[la] : nil
                    if la == Int(floor(lod)), lod > 0, la + 1 <= g.maxLevel, let next = g.levels[la + 1], g.readyLevel >= la + 1 {
                        q.levelB = Int32(la + 1); levelB = next
                    } else {
                        q.levelB = -1
                    }
                    if la < Int(floor(lod)) { waitingForLevel = true }
                } else {
                    // HQ: pyramid level + residual Lanczos-3 into the canvas.
                    let L = g.bestLevel(atMost: wanted)
                    if L < wanted { waitingForLevel = true }
                    let zoomedIn = (x1 - x0) > D.x + 0.5 || (y1 - y0) > D.y + 0.5
                    let margin = zoomedIn ? Self.panMargin : 0
                    let ex0 = max(Int(floor(x0)), vis.0 - margin), ey0 = max(Int(floor(y0)), vis.1 - margin)
                    let ex1 = min(Int(ceil(x1)), vis.2 + margin), ey1 = min(Int(ceil(y1)), vis.3 + margin)
                    let corners = [SIMD2(ex0, ey0), SIMD2(ex1 - 1, ey0), SIMD2(ex0, ey1 - 1), SIMD2(ex1 - 1, ey1 - 1)].map { minv.apply($0) }
                    let umin = SIMD2(corners.map(\.x).min()!, corners.map(\.y).min()!)
                    let umax = SIMD2(corners.map(\.x).max()!, corners.map(\.y).max()!)
                    let t = SIMD2(-umin.x, -umin.y)
                    let cw = umax.x - umin.x + 1, ch = umax.y - umin.y + 1
                    let origin = c0 - f * SIMD2(Double(t.x), Double(t.y)) + f * minv.apply(SIMD2(0.5, 0.5) - D / 2)
                    if let tex = encodeHQ(commands, g, level: L, f: f, origin: origin, width: cw, height: ch, image: image) {
                        canvas = Canvas(texture: tex, width: cw, height: ch, key: imageKey, source: ObjectIdentifier(g), level: L,
                                        f: f, minv: minv, origin: origin, drawable: D)
                        mode = .canvas
                        canvasTex = tex
                        q.t = SIMD2(Int32(t.x), Int32(t.y))
                        q.canvasSize = SIMD2(Int32(cw), Int32(ch))
                    }
                }
            }
        }
        lastPath = "\(mode)"
        q.mode = mode.rawValue

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(context.presentPipeline(for: target.pixelFormat))
        encoder.setFragmentBytes(&q, length: MemoryLayout<PresentP>.stride, index: 0)
        var info = g?.src ?? SrcInfo()
        encoder.setFragmentBytes(&info, length: MemoryLayout<SrcInfo>.stride, index: 1)
        encoder.setFragmentBuffer(g?.lut, offset: 0, index: 2)
        encoder.setFragmentTexture(canvasTex ?? context.dummy, index: 0)
        encoder.setFragmentTexture(levelA ?? context.dummy, index: 1)
        encoder.setFragmentTexture(levelB ?? context.dummy, index: 2)
        encoder.setFragmentTextures(context.tileArray(g), range: 3..<19)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        let retained = (g, canvasTex, levelA, levelB)
        commands.addCompletedHandler { [weak self] cb in
            _ = retained
            let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            DispatchQueue.main.async { self?.lastFrameGPUms = ms }
        }
        if Trace.enabled {
            let cpu = Trace.ms(since: start)
            Trace.log("render \(mode) cpu=\(String(format: "%.3f", cpu)) ms")
        }
    }

    private func applyBackground(_ q: inout PresentP, linearOutput: Bool) {
        func lin(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        switch settings.background {
        case .black: q.bg0 = SIMD4(0, 0, 0, 1)
        case .gray: q.bg0 = SIMD4(lin(0.5), lin(0.5), lin(0.5), 1)
        case .checker:
            q.bg0 = SIMD4(lin(0.55), lin(0.55), lin(0.55), 1)
            q.bg1 = SIMD4(lin(0.75), lin(0.75), lin(0.75), 1)
            q.checker = Float(8 * backingScale)
        }
        if settings.background != .checker { q.bg1 = q.bg0 }
    }

    /// Linear float copy of a preview tier (made once, in this frame's command buffer).
    private func linearPreview(_ g: GPUImage, _ commands: MTLCommandBuffer) -> MTLTexture? {
        if let t = g.linearPreview { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: g.width, height: g.height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        guard let tex = context.device.makeTexture(descriptor: d), let e = commands.makeComputeCommandEncoder() else { return nil }
        e.setComputePipelineState(context.convertLinear)
        context.bindTiles(e, g)
        e.setTexture(tex, index: 17)
        var info = g.src
        e.setBytes(&info, length: MemoryLayout<SrcInfo>.stride, index: 4)
        e.setBuffer(g.lut, offset: 0, index: 5)
        e.dispatchThreads(MTLSize(width: g.width, height: g.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        e.endEncoding()
        g.linearPreview = tex
        return tex
    }

    /// The PPR residual pass: level `L` of `g` resampled into a `width`×`height` canvas whose pixel (u, v) centre is
    /// at stored position `origin + f·(u, v)`.
    private func encodeHQ(_ commands: MTLCommandBuffer, _ g: GPUImage, level L: Int, f: Double, origin: SIMD2<Double>,
                          width cw: Int, height ch: Int, image: DecodedImage) -> MTLTexture? {
        guard cw > 0, ch > 0, cw <= GPUImage.maxTextureSide, ch <= GPUImage.maxTextureSide else { return nil }
        // Canvas texture (reused while large enough).
        if canvasTexture == nil || canvasTexture!.width < cw || canvasTexture!.height < ch {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: max(cw, canvasTexture?.width ?? 0),
                                                             height: max(ch, canvasTexture?.height ?? 0), mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            canvasTexture = context.device.makeTexture(descriptor: d)
        }
        if tmpTexture == nil || tmpTexture!.width < cw {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: max(cw, 64),
                                                             height: Self.tmpRowsCapacity, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            tmpTexture = context.device.makeTexture(descriptor: d)
        }
        let n = max(cw, ch)
        if tables == nil || tables!.capacity < n {
            let cap = max(n, 4096)
            let dev = context.device
            guard let fx = dev.makeBuffer(length: cap * 4, options: .storageModePrivate),
                  let wx = dev.makeBuffer(length: cap * 24 * 4, options: .storageModePrivate),
                  let fy = dev.makeBuffer(length: cap * 4, options: .storageModePrivate),
                  let wy = dev.makeBuffer(length: cap * 24 * 4, options: .storageModePrivate) else { return nil }
            tables = (fx, wx, fy, wy, cap)
        }
        guard let canvasTex = canvasTexture, let tmp = tmpTexture, let tables else { return nil }

        let (lw, lh) = g.levelSize(L)
        let scale = Double(1 << L)
        let sc = SIMD2(f * g.scaleX / scale, f * g.scaleY / scale)
        let corner = origin - 0.5 * f   // stored position of canvas pixel (0,0)'s top-left corner
        let blur = 1 - 0.05 * min(max(settings.sharpness, -2), 2)
        // Enlarging only happens at level 0 (any reduction picks a level with residual r ∈ [1, 2)).
        let enlarging = L == 0 && max(sc.x, sc.y) < 1 - 1e-9
        let reducing = !enlarging
        let filter = settings.filter
        var rp = RP()
        rp.ox = Float(corner.x * g.scaleX / scale); rp.oy = Float(corner.y * g.scaleY / scale)
        rp.sx = Float(sc.x); rp.sy = Float(sc.y)
        rp.kx = Float(max(1, sc.x) * blur); rp.ky = Float(max(1, sc.y) * blur)
        rp.radius = Float(filter.radius)
        rp.B = filter.bc.0; rp.C = filter.bc.1
        rp.filter = filter.id
        rp.antiring = settings.antiRinging ? (reducing ? -0.5 : 0.6) : 0
        rp.light = (enlarging && !g.hasAlpha && !image.isHDR) ? 1 : 0
        rp.srcW = Int32(lw); rp.srcH = Int32(lh)
        rp.dstW = Int32(cw); rp.dstH = Int32(ch)
        rp.fromLevel0 = L == 0 ? 1 : 0
        let levelTex = L == 0 ? context.dummy : (g.levels[L] ?? context.dummy)
        let ntapsX = min(24, Int(ceil(2 * Double(rp.radius * rp.kx))) + 1)
        let ntapsY = min(24, Int(ceil(2 * Double(rp.radius * rp.ky))) + 1)

        let fastSource = g.src.tileCount == 1 && g.src.trc == 0 && g.src.alpha != 2
        let hPipeline: MTLComputePipelineState
        if L > 0 { hPipeline = context.resampleHLevel }
        else if fastSource { hPipeline = rp.light == 1 ? context.resampleHFastSigmoid : context.resampleHFast }
        else { hPipeline = context.resampleHGeneral }
        guard let e = commands.makeComputeCommandEncoder() else { return nil }
        e.label = "PPR residual L\(L)"
        e.setComputePipelineState(context.axisWeights)
        for axis in 0..<2 {
            var a = AW(o: axis == 0 ? rp.ox : rp.oy, s: axis == 0 ? rp.sx : rp.sy, k: axis == 0 ? rp.kx : rp.ky,
                       radius: rp.radius, B: rp.B, C: rp.C, filter: rp.filter, n: Int32(axis == 0 ? cw : ch))
            e.setBytes(&a, length: MemoryLayout<AW>.stride, index: 0)
            e.setBuffer(axis == 0 ? tables.fx : tables.fy, offset: 0, index: 1)
            e.setBuffer(axis == 0 ? tables.wx : tables.wy, offset: 0, index: 2)
            e.dispatchThreads(MTLSize(width: axis == 0 ? cw : ch, height: 1, depth: 1),
                              threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        }
        e.memoryBarrier(scope: .buffers)
        // Bands of canvas rows so that the intermediate stays ≤ tmpRowsCapacity rows.
        let ry = Double(rp.radius * rp.ky)
        let rowsPerBand = max(1, min(ch, Int(Double(Self.tmpRowsCapacity - ntapsY - 4) / max(Double(rp.sy), 1e-6))))
        var b0 = 0
        var tx = Int32(ntapsX), ty = Int32(ntapsY)
        var info = g.src
        let tiles = context.tileArray(g)
        while b0 < ch {
            let b1 = min(ch, b0 + rowsPerBand)
            let py0 = Double(rp.oy) + (Double(b0) + 0.5) * Double(rp.sy) - 0.5
            let py1 = Double(rp.oy) + (Double(b1 - 1) + 0.5) * Double(rp.sy) - 0.5
            let rowStart = max(0, Int(ceil(py0 - ry)) - 1)
            let rowEnd = min(lh - 1, Int(ceil(py1 - ry)) + ntapsY)
            let tmpRows = max(1, min(Self.tmpRowsCapacity, rowEnd - rowStart + 1))
            rp.rowStart = Int32(rowStart); rp.dstRow0 = Int32(b0); rp.tmpRows = Int32(tmpRows)
            e.setComputePipelineState(hPipeline)
            e.setTextures(tiles, range: 0..<16)
            e.setTexture(levelTex, index: 16)
            e.setTexture(tmp, index: 17)
            e.setBytes(&rp, length: MemoryLayout<RP>.stride, index: 0)
            e.setBuffer(tables.fx, offset: 0, index: 1)
            e.setBuffer(tables.wx, offset: 0, index: 2)
            e.setBytes(&tx, length: 4, index: 3)
            e.setBytes(&info, length: MemoryLayout<SrcInfo>.stride, index: 4)
            e.setBuffer(g.lut, offset: 0, index: 5)
            e.dispatchThreads(MTLSize(width: cw, height: tmpRows, depth: 1), threadsPerThreadgroup: MTLSize(width: 32, height: 8, depth: 1))
            e.memoryBarrier(scope: .textures)
            e.setComputePipelineState(rp.light == 1 ? context.resampleVSigmoid : context.resampleVLinear)
            e.setTexture(tmp, index: 0)
            e.setTexture(canvasTex, index: 1)
            e.setBytes(&rp, length: MemoryLayout<RP>.stride, index: 0)
            e.setBuffer(tables.fy, offset: 0, index: 1)
            e.setBuffer(tables.wy, offset: 0, index: 2)
            e.setBytes(&ty, length: 4, index: 3)
            e.dispatchThreads(MTLSize(width: cw, height: b1 - b0, depth: 1), threadsPerThreadgroup: MTLSize(width: 32, height: 8, depth: 1))
            e.memoryBarrier(scope: .textures)
            b0 = b1
        }
        e.endEncoding()
        if Trace.enabled {
            Trace.log("HQ L\(L) canvas \(cw)x\(ch) taps \(ntapsX)x\(ntapsY) r=\(String(format: "%.3f", rp.sx)) light=\(rp.light) bands=\((ch + rowsPerBand - 1) / rowsPerBand)")
        }
        return canvasTex
    }

    // MARK: Internals

    private func requestDisplay() { onNeedsDisplay?() }

    private var drawableSize: SIMD2<Double> {
        SIMD2(Double(viewSize.width * backingScale), Double(viewSize.height * backingScale))
    }

    /// The HQ pass of `g` at reduction `f` (full-resolution pixels per device pixel) needs a level not built yet.
    private func levelMissing(_ g: GPUImage, f: Double) -> Bool {
        let fT = f * max(g.scaleX, g.scaleY)
        guard fT > 2 - 1e-9 else { return false }
        let wanted = min(Int(floor(log2(fT) + 1e-9)), g.maxLevel)
        return wanted > 0 && g.bestLevel(atMost: wanted) < wanted
    }

    private func effectiveScaleFor(drawable: SIMD2<Double>) -> Double {
        let display = displaySize
        guard display.x > 0, display.y > 0 else { return 1 }
        switch zoomMode {
        case .fit: return min(drawable.x / display.x, drawable.y / display.y)
        case .fill: return max(drawable.x / display.x, drawable.y / display.y)
        case .scale(let s): return s
        }
    }

    /// Stored pixels -> display: EXIF orientation, then the user's quarter turns, then flips (in display space).
    private func orientationPerm(_ image: DecodedImage) -> Perm {
        var m = Perm.exif(image.orientation)
        for _ in 0..<quarterTurns { m = Perm.clockwise * m }
        if flippedHorizontally { m = Perm.flipH * m }
        if flippedVertically { m = Perm.flipV * m }
        return m
    }

    /// Full-resolution image size after the user's rotation.
    private var displaySize: SIMD2<Double> {
        guard let image else { return SIMD2(1, 1) }
        let w = Double(image.fullWidth), h = Double(image.fullHeight)
        return quarterTurns % 2 == 0 ? SIMD2(w, h) : SIMD2(h, w)
    }

    private var minimumScale: Double {
        let display = displaySize, drawable = drawableSize
        return min(min(drawable.x / display.x, drawable.y / display.y), 1) / 4
    }

    private func imagePoint(atView point: CGPoint) -> SIMD2<Double> {
        let p = SIMD2(Double(point.x), Double(point.y)) * Double(backingScale)
        return (p - drawableSize / 2) / effectiveScale + center
    }

    private func keep(_ imagePoint: SIMD2<Double>, at viewPoint: CGPoint) {
        let p = SIMD2(Double(viewPoint.x), Double(viewPoint.y)) * Double(backingScale)
        center = imagePoint - (p - drawableSize / 2) / effectiveScale
    }

    private func clampCenter() {
        let s = effectiveScale, display = displaySize, drawable = drawableSize
        for axis in 0..<2 {
            let half = drawable[axis] / (2 * s)
            if display[axis] <= 2 * half {
                center[axis] = display[axis] / 2
            } else {
                center[axis] = min(max(center[axis], half), display[axis] - half)
            }
        }
    }
}
