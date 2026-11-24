import CoreGraphics
import Foundation
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

public struct RenderSettings: Sendable, Equatable {
    public var background: Background = .black
    public init() {}
}

/// Process-wide GPU objects. `prewarm()` creates the device and compiles shaders on a
/// background thread at launch so the first window never waits for them (R6: fully hidden
/// behind AppKit initialisation).
public final class RenderContext: @unchecked Sendable {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    let imagePipeline: MTLRenderPipelineState

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
        do {
            let library = try device.makeLibrary(source: Shaders.source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "fullscreenVS")
            descriptor.fragmentFunction = library.makeFunction(name: "imageFS")
            descriptor.colorAttachments[0].pixelFormat = Renderer.drawableFormat
            imagePipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            fatalError("shader compilation failed: \(error)")
        }
    }
}

/// Draws one image into a `CAMetalLayer` with zoom, pan, rotation and flips.
///
/// Coordinates: view points, origin top-left, y down. Main-thread only.
/// Walking-skeleton implementation (single bilinear pass); the render workstream
/// replaces the internals with the PPR algorithm (quality pyramid, residual Lanczos,
/// settle-time re-rasterisation) while keeping this API.
public final class Renderer {
    public static let drawableFormat: MTLPixelFormat = .bgra8Unorm

    public let layer: CAMetalLayer
    public var settings = RenderSettings() { didSet { requestDisplay() } }
    /// Keep zoom and pan when switching to another image.
    public var keepZoom = false
    /// Asks the host to call `render()` soon (e.g. a refinement became available).
    public var onNeedsDisplay: (() -> Void)?

    public private(set) var zoomMode: ZoomMode = .fit
    public private(set) var image: DecodedImage?
    public private(set) var quarterTurns = 0
    public private(set) var flippedHorizontally = false
    public private(set) var flippedVertically = false

    private let context: RenderContext
    private var texture: MTLTexture?
    private var imageKey: AnyHashable?
    private var viewSize = CGSize(width: 1, height: 1)
    private var backingScale: CGFloat = 2
    /// Image-space point (display orientation, full-resolution pixels) at the view centre.
    private var center = SIMD2<Double>(0, 0)

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
        texture = image.flatMap { $0.pixels.makeTexture(device: context.device) }
        if isNewFile {
            quarterTurns = 0
            flippedHorizontally = false
            flippedVertically = false
            if !keepZoom { zoomMode = .fit }
            center = displaySize / 2
        }
        clampCenter()
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
        let anchorImage = anchor.map(imagePoint(atView:))
        zoomMode = mode
        if let anchor, let anchorImage {
            keep(anchorImage, at: anchor)
        } else if mode == .fit || mode == .fill {
            center = displaySize / 2
        }
        clampCenter()
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

    /// Gestures (pinch, scroll, drag) in progress: the renderer may use its cheap path and
    /// re-rasterise at full quality shortly after `endInteraction()`.
    public func beginInteraction() {}
    public func endInteraction() { requestDisplay() }

    // MARK: Drawing

    /// Encode and present a frame now.
    public func render() {
        guard let drawable = layer.nextDrawable(),
              let commands = context.queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = makeUniforms()
        encoder.setRenderPipelineState(context.imagePipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        if let texture { encoder.setFragmentTexture(texture, index: 0) }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        let retained = image  // keep the pixels alive until the GPU is done with them
        commands.addCompletedHandler { _ in _ = retained }
        commands.present(drawable)
        commands.commit()
    }

    // MARK: Internals

    private func requestDisplay() { onNeedsDisplay?() }

    private var drawableSize: SIMD2<Double> {
        SIMD2(Double(viewSize.width * backingScale), Double(viewSize.height * backingScale))
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

    private struct Uniforms {
        var pixelToUV: simd_float3x3
        var background: SIMD4<Float>
        var checker: Float
        var alphaMode: UInt32
        var hasImage: UInt32
    }

    private func makeUniforms() -> Uniforms {
        let s = effectiveScale, display = displaySize, drawable = drawableSize
        // drawable pixel -> display-space normalised coordinate n in [0,1]^2
        let toDisplay = simd_double3x3(rows: [
            SIMD3(1 / (s * display.x), 0, (center.x - drawable.x / (2 * s)) / display.x),
            SIMD3(0, 1 / (s * display.y), (center.y - drawable.y / (2 * s)) / display.y),
            SIMD3(0, 0, 1),
        ])
        // display-space n -> texture uv, undoing the user's rotation and flips
        var toTexture = matrix_identity_double3x3
        if flippedHorizontally { toTexture = simd_double3x3(rows: [SIMD3(-1, 0, 1), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]) * toTexture }
        if flippedVertically { toTexture = simd_double3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, -1, 1), SIMD3(0, 0, 1)]) * toTexture }
        let turn = simd_double3x3(rows: [SIMD3(0, 1, 0), SIMD3(-1, 0, 1), SIMD3(0, 0, 1)])  // undo one clockwise quarter turn
        var rotation = matrix_identity_double3x3
        for _ in 0..<quarterTurns { rotation = turn * rotation }
        let m = rotation * toTexture * toDisplay
        let f = simd_float3x3(SIMD3<Float>(Float(m[0][0]), Float(m[0][1]), Float(m[0][2])),
                              SIMD3<Float>(Float(m[1][0]), Float(m[1][1]), Float(m[1][2])),
                              SIMD3<Float>(Float(m[2][0]), Float(m[2][1]), Float(m[2][2])))
        let background: SIMD4<Float>
        switch settings.background {
        case .black: background = SIMD4(0, 0, 0, 1)
        case .gray: background = SIMD4(0.5, 0.5, 0.5, 1)
        case .checker: background = SIMD4(0.6, 0.6, 0.6, 1)
        }
        let alphaMode: UInt32
        switch image?.pixels.alpha {
        case .premultiplied: alphaMode = 1
        case .straight: alphaMode = 2
        default: alphaMode = 0
        }
        return Uniforms(pixelToUV: f, background: background,
                        checker: settings.background == .checker ? Float(8 * backingScale) : 0,
                        alphaMode: alphaMode, hasImage: texture == nil ? 0 : 1)
    }
}

enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 position [[position]]; };

    vertex VOut fullscreenVS(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VOut out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return out;
    }

    struct Uniforms {
        float3x3 pixelToUV;
        float4 background;
        float checker;
        uint alphaMode;
        uint hasImage;
    };

    fragment float4 imageFS(VOut in [[stage_in]],
                            texture2d<float> image [[texture(0)]],
                            constant Uniforms& u [[buffer(0)]]) {
        constexpr sampler bilinear(filter::linear, address::clamp_to_edge);
        float2 pixel = in.position.xy;
        float4 bg = u.background;
        if (u.checker > 0.0) {
            int2 cell = int2(floor(pixel / u.checker));
            bg.rgb = ((cell.x + cell.y) & 1) ? float3(0.75) : float3(0.55);
        }
        if (u.hasImage == 0) { return bg; }
        float2 uv = (u.pixelToUV * float3(pixel, 1.0)).xy;
        if (any(uv < 0.0) || any(uv > 1.0)) { return bg; }
        float4 c = image.sample(bilinear, uv);
        if (u.alphaMode == 0) { c.a = 1.0; }
        else if (u.alphaMode == 2) { c.rgb *= c.a; }
        return float4(c.rgb + bg.rgb * (1.0 - c.a), 1.0);
    }
    """
}
