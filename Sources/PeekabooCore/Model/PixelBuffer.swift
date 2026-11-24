import CoreGraphics
import Foundation
import IOSurface
import Metal

/// Memory layout of decoded pixels. The renderer samples every layout directly
/// (format + swizzle), so decoders never pay a CPU conversion pass — ImageIO's
/// native outputs differ per path (full decode = RGBX, thumbnails = XRGB, …).
public enum PixelLayout: Sendable, Equatable {
    /// Bytes R,G,B,A (or X). CG `*Last` + default byte order. Metal `.rgba8Unorm`.
    case rgba8
    /// Bytes B,G,R,A (or X). CG `*First | byteOrder32Little`, IOSurface 'BGRA'. Metal `.bgra8Unorm`.
    case bgra8
    /// Bytes A (or X),R,G,B. CG `*First` + default byte order. Metal `.rgba8Unorm` + swizzle.
    case argb8
    /// 16-bit unsigned normalized RGBA, little-endian (camera RAW decodes). Metal `.rgba16Unorm`.
    case rgba16
    /// 16-bit float RGBA, little-endian (HDR / extended range). Metal `.rgba16Float`.
    case rgba16f

    public var bytesPerPixel: Int {
        switch self {
        case .rgba8, .bgra8, .argb8: return 4
        case .rgba16, .rgba16f: return 8
        }
    }

    public var bitsPerComponent: Int { bytesPerPixel == 4 ? 8 : 16 }

    /// Metal format to wrap the bytes with (pair with `metalSwizzle`).
    public var metalFormat: MTLPixelFormat {
        switch self {
        case .rgba8, .argb8: return .rgba8Unorm
        case .bgra8: return .bgra8Unorm
        case .rgba16: return .rgba16Unorm
        case .rgba16f: return .rgba16Float
        }
    }

    /// Channel remap so that sampling always yields (r, g, b, a).
    public var metalSwizzle: MTLTextureSwizzleChannels {
        switch self {
        case .argb8: return MTLTextureSwizzleChannels(red: .green, green: .blue, blue: .alpha, alpha: .red)
        default: return MTLTextureSwizzleChannels(red: .red, green: .green, blue: .blue, alpha: .alpha)
        }
    }

    /// CGBitmapInfo for drawing into a buffer of this layout (alpha premultiplied).
    public var cgBitmapInfo: UInt32 {
        switch self {
        case .rgba8: return CGImageAlphaInfo.premultipliedLast.rawValue
        case .bgra8: return CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        case .argb8: return CGImageAlphaInfo.premultipliedFirst.rawValue
        case .rgba16: return CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        case .rgba16f:
            return CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue
        }
    }
}

/// How the fourth channel must be interpreted when compositing over the background.
public enum AlphaMode: Sendable, Equatable {
    /// Ignore the channel (it may hold garbage, e.g. CG `noneSkip*`).
    case opaque
    case premultiplied
    case straight
}

/// Decoded pixels in GPU-visible unified memory — either a shared `MTLBuffer`
/// we own (decode targets, pooled) or an `IOSurface` produced by ImageIO's
/// hardware path. The renderer wraps either one as a texture with zero copies.
///
/// Rule: whoever encodes GPU work that reads this buffer must keep the
/// `PixelBuffer` alive until that command buffer completes — a released buffer
/// goes back to the pool and may be overwritten by the next decode.
public final class PixelBuffer: @unchecked Sendable {
    public enum Storage {
        case metal(MTLBuffer)
        case surface(IOSurfaceRef)
    }

    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let layout: PixelLayout
    public let alpha: AlphaMode
    /// Color space the pixel values are encoded in (the renderer converts to its working space on the GPU).
    public let colorSpace: CGColorSpace
    public let storage: Storage
    fileprivate weak var pool: PixelBufferPool?

    public init(width: Int, height: Int, bytesPerRow: Int, layout: PixelLayout, alpha: AlphaMode,
                colorSpace: CGColorSpace, storage: Storage) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.layout = layout
        self.alpha = alpha
        self.colorSpace = colorSpace
        self.storage = storage
    }

    deinit {
        if case .metal(let buffer) = storage { pool?.recycle(buffer) }
    }

    /// CPU address of the first pixel. For IOSurfaces this is only stable while the surface is locked
    /// or after the producer has finished writing (ImageIO hands over finished surfaces).
    public var baseAddress: UnsafeMutableRawPointer {
        switch storage {
        case .metal(let buffer): return buffer.contents()
        case .surface(let surface): return IOSurfaceGetBaseAddress(surface)
        }
    }

    public var byteCount: Int { bytesPerRow * height }

    /// Bytes this buffer keeps alive (for cache budgets).
    public var allocatedBytes: Int {
        switch storage {
        case .metal(let buffer): return buffer.length
        case .surface(let surface): return IOSurfaceGetAllocSize(surface)
        }
    }

    /// A bitmap context drawing straight into this buffer (decode target). Alpha is premultiplied.
    public func makeContext() -> CGContext? {
        CGContext(data: baseAddress, width: width, height: height,
                  bitsPerComponent: layout.bitsPerComponent, bytesPerRow: bytesPerRow,
                  space: colorSpace, bitmapInfo: layout.cgBitmapInfo)
    }

    /// Zero-copy texture over these bytes (shader-read only, no mipmaps).
    public func makeTexture(device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: layout.metalFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .pixelFormatView]
        descriptor.swizzle = layout.metalSwizzle
        switch storage {
        case .metal(let buffer):
            descriptor.storageMode = .shared
            return buffer.makeTexture(descriptor: descriptor, offset: 0, bytesPerRow: bytesPerRow)
        case .surface(let surface):
            descriptor.storageMode = .shared
            return device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)
        }
    }
}

/// Recycles shared `MTLBuffer`s so steady-state decoding never pays for fresh,
/// zero-fill-on-demand pages (a 32 MB buffer is ~2k page faults on first touch).
public final class PixelBufferPool: @unchecked Sendable {
    public let device: MTLDevice
    /// Upper bound on bytes kept in the free list (in-use buffers are not counted).
    public let maxRetainedBytes: Int
    private var free: [Int: [MTLBuffer]] = [:]
    private var retainedBytes = 0
    private let lock = NSLock()
    /// Allocation granularity: rounding sizes up improves reuse across aspect ratios.
    private static let granule = 1 << 20

    public init(device: MTLDevice, maxRetainedBytes: Int = 768 << 20) {
        self.device = device
        self.maxRetainedBytes = maxRetainedBytes
    }

    public func rowBytes(width: Int, layout: PixelLayout) -> Int {
        let align = max(64, device.minimumLinearTextureAlignment(for: layout.metalFormat))
        return (width * layout.bytesPerPixel + align - 1) / align * align
    }

    /// A pooled, GPU-shareable buffer for `width`×`height` pixels of `layout`.
    public func make(width: Int, height: Int, layout: PixelLayout, alpha: AlphaMode,
                     colorSpace: CGColorSpace) -> PixelBuffer? {
        precondition(width > 0 && height > 0)
        let bpr = rowBytes(width: width, layout: layout)
        let length = (bpr * height + Self.granule - 1) / Self.granule * Self.granule
        guard let buffer = take(length) ?? device.makeBuffer(length: length, options: [.storageModeShared]) else {
            return nil
        }
        let pixels = PixelBuffer(width: width, height: height, bytesPerRow: bpr, layout: layout, alpha: alpha,
                                 colorSpace: colorSpace, storage: .metal(buffer))
        pixels.pool = self
        return pixels
    }

    /// Drop every pooled buffer (call on memory pressure).
    public func drain() {
        lock.lock(); free.removeAll(); retainedBytes = 0; lock.unlock()
    }

    public var pooledBytes: Int { lock.lock(); defer { lock.unlock() }; return retainedBytes }

    private func take(_ length: Int) -> MTLBuffer? {
        lock.lock(); defer { lock.unlock() }
        guard var list = free[length], let buffer = list.popLast() else { return nil }
        free[length] = list
        retainedBytes -= length
        return buffer
    }

    fileprivate func recycle(_ buffer: MTLBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard retainedBytes + buffer.length <= maxRetainedBytes else { return }
        free[buffer.length, default: []].append(buffer)
        retainedBytes += buffer.length
    }
}
