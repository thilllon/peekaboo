import CoreGraphics
import Foundation
import IOSurface
import Metal
import PeekabooCore
import simd

// Swift mirrors of the MSL structs (all members 4-byte scalars or SIMD4 → identical layout).
struct SrcInfo {
    var m0 = SIMD4<Float>(1, 0, 0, 0), m1 = SIMD4<Float>(0, 1, 0, 0), m2 = SIMD4<Float>(0, 0, 1, 0)
    var width: Int32 = 1, height: Int32 = 1
    var tileShift: Int32 = 14, tileCols: Int32 = 1
    var tileCount: Int32 = 1, trc: Int32 = 0
    var alpha: Int32 = 0, lutSize: Int32 = 2
}

struct DP {
    var taps: Int32 = 0, baseOff: Int32 = 0, factor: Int32 = 2, srcW: Int32 = 0, srcH: Int32 = 0, dstW: Int32 = 0
    var dstH: Int32 = 0, rowStart: Int32 = 0, dstRow0: Int32 = 0, tmpRows: Int32 = 0, fromLevel0: Int32 = 0, pad: Int32 = 0
}

/// One decoded tier on the GPU: zero-copy level-0 tiles over the decoder's buffer, the colour transform,
/// and a linear-light Lanczos-3 pyramid (levels ≥ 1, `rgba16Float`) built asynchronously in ≤ 2 ms chunks.
///
/// Main-thread state: `levels`, `readyLevel`, `linearPreview`. The builder works on its own queue and
/// publishes finished levels to the main queue.
final class GPUImage {
    static let maxTextureSide = 16384
    static let tileShift = 14   // 16384-px tiles (Apple9 limit); reads pick the tile, so no apron is needed

    let image: DecodedImage
    let width: Int, height: Int
    let tiles: [MTLTexture]
    let tileCols: Int
    var src: SrcInfo
    let lut: MTLBuffer
    /// Full-resolution stored (pre-orientation) size.
    let storedWidth: Double, storedHeight: Double
    /// Tier texels per full-resolution stored pixel.
    let scaleX: Double, scaleY: Double
    let hasAlpha: Bool
    /// Pyramid levels (index = level; 0 is the tier texture itself, accessed through `tiles`).
    private(set) var levels: [MTLTexture?]
    /// Highest level L such that every level in 1...L is built (0: none yet).
    private(set) var readyLevel = 0
    /// The first level the pyramid builds (1, or more for images whose half size still exceeds the texture limit).
    let firstLevel: Int
    let maxLevel: Int
    /// Stage-0 linear float copy (previews only), for the hardware-bilinear B-spline.
    var linearPreview: MTLTexture?
    var linearPreviewPending = false
    var onLevelReady: ((Int) -> Void)?
    private let cancelLock = NSLock()
    private var cancelledFlag = false
    private var buildStarted = false
    /// Keeps a bytesNoCopy wrapper of an IOSurface alive for tiled surfaces.
    private let surfaceBuffer: MTLBuffer?

    var isUsable: Bool { !tiles.isEmpty }
    var isFullResolution: Bool { abs(scaleX - 1) < 1e-9 && abs(scaleY - 1) < 1e-9 }

    init(image: DecodedImage, device: MTLDevice) {
        self.image = image
        let px = image.pixels
        width = px.width
        height = px.height
        let swaps = image.orientation.rawValue >= 5 && image.orientation.rawValue <= 8
        storedWidth = Double(swaps ? image.fullHeight : image.fullWidth)
        storedHeight = Double(swaps ? image.fullWidth : image.fullHeight)
        scaleX = storedWidth > 0 ? Double(width) / storedWidth : 1
        scaleY = storedHeight > 0 ? Double(height) / storedHeight : 1
        hasAlpha = px.alpha != .opaque

        let transform = ColorTransform.forSpace(px.colorSpace)
        let srgbFormat = transform.usesSRGBCurve && px.alpha == .opaque && (px.layout == .rgba8 || px.layout == .bgra8)
        var info = SrcInfo()
        info.m0 = SIMD4(transform.rows.0, 0); info.m1 = SIMD4(transform.rows.1, 0); info.m2 = SIMD4(transform.rows.2, 0)
        info.width = Int32(width); info.height = Int32(height)
        info.trc = srgbFormat ? 0 : transform.curve.rawValue
        info.alpha = px.alpha == .opaque ? 0 : (px.alpha == .premultiplied ? 1 : 2)
        let table = transform.lut.isEmpty ? [Float](repeating: 0, count: 2) : transform.lut
        info.lutSize = Int32(table.count)
        lut = device.makeBuffer(bytes: table, length: table.count * 4, options: .storageModeShared)!

        // Level-0 tiles: views into the decoder's memory, no copies.
        let cols = (width + Self.maxTextureSide - 1) / Self.maxTextureSide
        let rows = (height + Self.maxTextureSide - 1) / Self.maxTextureSide
        tileCols = cols
        info.tileCols = Int32(cols)
        info.tileCount = Int32(cols * rows)
        info.tileShift = Int32(Self.tileShift)
        var made: [MTLTexture] = []
        var wrapper: MTLBuffer?
        let format: MTLPixelFormat = srgbFormat ? (px.layout == .bgra8 ? .bgra8Unorm_srgb : .rgba8Unorm_srgb) : px.layout.metalFormat
        if cols * rows <= 16 {
            var buffer: MTLBuffer?
            switch px.storage {
            case .metal(let b): buffer = b
            case .surface(let surface):
                if cols * rows > 1 {
                    let length = IOSurfaceGetAllocSize(surface)
                    wrapper = device.makeBuffer(bytesNoCopy: IOSurfaceGetBaseAddress(surface), length: length,
                                                options: .storageModeShared, deallocator: nil)
                    buffer = wrapper
                }
            }
            for ty in 0..<rows {
                for tx in 0..<cols {
                    let x0 = tx * Self.maxTextureSide, y0 = ty * Self.maxTextureSide
                    let w = min(Self.maxTextureSide, width - x0), h = min(Self.maxTextureSide, height - y0)
                    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
                    d.usage = [.shaderRead]
                    d.swizzle = px.layout.metalSwizzle
                    d.storageMode = .shared
                    var tex: MTLTexture?
                    if let buffer {
                        let offset = y0 * px.bytesPerRow + x0 * px.layout.bytesPerPixel
                        tex = buffer.makeTexture(descriptor: d, offset: offset, bytesPerRow: px.bytesPerRow)
                    } else if case .surface(let surface) = px.storage {
                        tex = device.makeTexture(descriptor: d, iosurface: surface, plane: 0)
                    }
                    if let tex { made.append(tex) }
                }
            }
            if made.count != cols * rows { made = [] }
        }
        tiles = made
        surfaceBuffer = wrapper
        src = info

        // Pyramid geometry. Levels whose size would exceed the texture limit are skipped: the first built level is
        // decimated straight from level 0 by 2^firstLevel.
        var first = 1
        while (width >> first) > Self.maxTextureSide || (height >> first) > Self.maxTextureSide { first += 1 }
        firstLevel = min(first, 3)
        let longSide = max(width, height)
        var top = 0
        while (longSide >> (top + 1)) >= 8 { top += 1 }
        maxLevel = (width >> firstLevel) > Self.maxTextureSide || (height >> firstLevel) > Self.maxTextureSide ? 0 : max(0, top)
        levels = Array(repeating: nil, count: maxLevel + 1)
    }

    func levelSize(_ L: Int) -> (Int, Int) { (max(1, width >> L), max(1, height >> L)) }

    func cancel() { cancelLock.lock(); cancelledFlag = true; cancelLock.unlock() }
    var isCancelled: Bool { cancelLock.lock(); defer { cancelLock.unlock() }; return cancelledFlag }

    /// Main thread: record a finished level.
    fileprivate func publish(level L: Int, texture: MTLTexture) {
        levels[L] = texture
        var r = 0
        if L >= firstLevel {
            r = firstLevel - 1
            while r + 1 <= maxLevel, levels[r + 1] != nil { r += 1 }
            if r < firstLevel { r = 0 }
        }
        readyLevel = max(readyLevel, r)
        onLevelReady?(L)
    }

    /// Highest built level ≤ `wanted` (0 = level 0).
    func bestLevel(atMost wanted: Int) -> Int {
        guard wanted >= firstLevel, readyLevel >= firstLevel else { return 0 }
        return min(wanted, readyLevel)
    }

    /// Start building the pyramid on the background queue (idempotent).
    func startPyramid(context: RenderContext) {
        guard !buildStarted, isUsable, maxLevel >= firstLevel else { return }
        buildStarted = true
        let job = PyramidJob(image: self, context: context)
        PyramidJob.queue.async { job.run() }
    }
}

/// 2^m decimation taps: Lanczos-3 stretched by `factor`, centred on the output texel.
func decimationWeights(factor d: Int) -> (weights: [Float], baseOff: Int) {
    let centre = Double(d - 1) / 2
    let radius = 3.0 * Double(d)
    let lo = Int(ceil(centre - radius)), hi = Int(floor(centre + radius))
    var w: [Double] = []
    for i in lo...hi { w.append(lanczos3(Double(i) - centre, stretch: Double(d))) }
    let s = w.reduce(0, +)
    return (w.map { Float($0 / s) }, lo)
}

@inline(__always) func lanczos3(_ x: Double, stretch: Double = 1) -> Double {
    let v = abs(x / stretch)
    guard v < 3 else { return 0 }
    if v < 1e-12 { return 1 }
    let a = Double.pi * v
    return 3 * sin(a) * sin(a / 3) / (a * a)
}

/// Builds the pyramid of one `GPUImage` in command buffers of ≈ 1–2 ms GPU time each, committing the next only
/// after the previous one completed so frames never queue behind more than one chunk.
private final class PyramidJob: @unchecked Sendable {
    static let queue = DispatchQueue(label: "com.thilllon.peekaboo.pyramid", qos: .userInitiated)
    /// Output texels per command buffer (≈ 0.3 ns per texel-pass on M4 Pro → ~1.2 ms).
    static let texelBudget = 4_000_000

    let image: GPUImage
    let context: RenderContext
    init(image: GPUImage, context: RenderContext) { self.image = image; self.context = context }

    func run() {
        let start = Trace.now()
        let device = context.device
        let img = image
        var previous: MTLTexture?
        let (w2, _) = img.levelSize(img.firstLevel)
        let maxBandTmpRows = 2 * 256 * (1 << (img.firstLevel - 1)) + 64 * (1 << img.firstLevel)
        let tmpDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: max(1, w2),
                                                               height: maxBandTmpRows, mipmapped: false)
        tmpDesc.usage = [.shaderRead, .shaderWrite]
        tmpDesc.storageMode = .private
        guard let tmp = device.makeTexture(descriptor: tmpDesc) else { return }
        var cb: MTLCommandBuffer?
        var encoder: MTLComputeCommandEncoder?
        var pending = 0
        func flush() {
            encoder?.endEncoding(); encoder = nil
            if let c = cb { c.commit(); c.waitUntilCompleted() }
            cb = nil; pending = 0
        }
        for L in img.firstLevel...img.maxLevel {
            if img.isCancelled { flush(); return }
            let factor = L == img.firstLevel ? (1 << img.firstLevel) : 2
            let (sw, sh) = L == img.firstLevel ? (img.width, img.height) : img.levelSize(L - 1)
            let (dw, dh) = img.levelSize(L)
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: dw, height: dh, mipmapped: false)
            desc.usage = [.shaderRead, .shaderWrite]
            desc.storageMode = .private
            guard let dst = device.makeTexture(descriptor: desc) else { flush(); return }
            let (weights, baseOff) = decimationWeights(factor: factor)
            let taps = weights.count
            // Band height so that the H-pass rows fit the tmp texture.
            let bandRows = max(1, min(dh, (maxBandTmpRows - taps - 2) / factor))
            var r0 = 0
            while r0 < dh {
                let r1 = min(dh, r0 + bandRows)
                let hr0 = max(0, r0 * factor + baseOff)
                let hr1 = min(sh - 1, (r1 - 1) * factor + baseOff + taps - 1)
                let tmpRows = max(1, hr1 - hr0 + 1)
                if cb == nil {
                    cb = context.queue.makeCommandBuffer()
                    cb?.label = "pyramid"
                    encoder = cb?.makeComputeCommandEncoder()
                }
                guard let e = encoder else { return }
                var d = DP(taps: Int32(taps), baseOff: Int32(baseOff), factor: Int32(factor), srcW: Int32(sw), srcH: Int32(sh),
                           dstW: Int32(dw), dstH: Int32(dh), rowStart: Int32(hr0), dstRow0: Int32(r0), tmpRows: Int32(tmpRows),
                           fromLevel0: L == img.firstLevel ? 1 : 0, pad: 0)
                e.setComputePipelineState(context.downH)
                context.bindTiles(e, img)
                e.setTexture(previous ?? context.dummy, index: 16)
                e.setTexture(tmp, index: 17)
                e.setBytes(&d, length: MemoryLayout<DP>.stride, index: 0)
                weights.withUnsafeBytes { e.setBytes($0.baseAddress!, length: $0.count, index: 1) }
                var info = img.src
                e.setBytes(&info, length: MemoryLayout<SrcInfo>.stride, index: 4)
                e.setBuffer(img.lut, offset: 0, index: 5)
                e.dispatchThreads(MTLSize(width: dw, height: tmpRows, depth: 1),
                                  threadsPerThreadgroup: MTLSize(width: 32, height: 8, depth: 1))
                e.memoryBarrier(scope: .textures)
                e.setComputePipelineState(context.downV)
                e.setTexture(tmp, index: 0)
                e.setTexture(dst, index: 1)
                e.dispatchThreads(MTLSize(width: dw, height: r1 - r0, depth: 1),
                                  threadsPerThreadgroup: MTLSize(width: 32, height: 8, depth: 1))
                e.memoryBarrier(scope: .textures)
                pending += dw * tmpRows * (factor == 2 ? 1 : factor / 2) + dw * (r1 - r0)
                if pending >= Self.texelBudget { flush() }
                r0 = r1
            }
            flush()
            previous = dst
            let level = L
            DispatchQueue.main.async { img.publish(level: level, texture: dst) }
        }
        let ms = Trace.ms(since: start)
        Trace.log("pyramid \(img.width)x\(img.height) levels \(img.firstLevel)...\(img.maxLevel) in \(String(format: "%.2f", ms)) ms")
    }
}
