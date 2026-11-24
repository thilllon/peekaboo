import CoreGraphics
import Foundation
import Metal

/// Pixel layouts the decoder can produce and the renderer can sample with no conversion.
public enum PixelFormat: Sendable, Equatable {
    /// 8-bit BGRA, premultiplied alpha first, 32-bit little-endian
    /// (`premultipliedFirst | byteOrder32Little`) — Metal `.bgra8Unorm` / `.bgra8Unorm_srgb`.
    case bgra8
    /// 16-bit half-float RGBA, premultiplied alpha last, 16-bit little-endian
    /// (`premultipliedLast | floatComponents | byteOrder16Little`) — Metal `.rgba16Float`. HDR / wide gamut.
    case rgba16f

    public var bytesPerPixel: Int { self == .bgra8 ? 4 : 8 }
    public var bitsPerComponent: Int { self == .bgra8 ? 8 : 16 }
    public var metalFormat: MTLPixelFormat { self == .bgra8 ? .bgra8Unorm : .rgba16Float }
    public var cgBitmapInfo: UInt32 {
        switch self {
        case .bgra8:
            return CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        case .rgba16f:
            return CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue
        }
    }
}

/// Decoded pixels living in shared (unified) memory owned by an `MTLBuffer`.
///
/// The decoder draws straight into `baseAddress`; the renderer wraps `buffer`
/// with `makeTexture(descriptor:offset:bytesPerRow:)` — zero copies between
/// decode and GPU. Rule: anyone encoding GPU work that reads this buffer must
/// keep the `PixelBuffer` alive until that command buffer completes, because a
/// released buffer goes back to the pool and may be overwritten by the next decode.
public final class PixelBuffer: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let format: PixelFormat
    public let colorSpace: CGColorSpace
    public let buffer: MTLBuffer
    fileprivate weak var pool: PixelBufferPool?

    public var baseAddress: UnsafeMutableRawPointer { buffer.contents() }
    public var byteCount: Int { bytesPerRow * height }
    /// Bytes actually reserved (may exceed `byteCount` when a pooled buffer is reused).
    public var allocatedBytes: Int { buffer.length }

    fileprivate init(width: Int, height: Int, bytesPerRow: Int, format: PixelFormat,
                     colorSpace: CGColorSpace, buffer: MTLBuffer, pool: PixelBufferPool?) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.format = format
        self.colorSpace = colorSpace
        self.buffer = buffer
        self.pool = pool
    }

    deinit { pool?.recycle(buffer) }

    /// A bitmap context drawing directly into this buffer (the decode target).
    public func makeContext() -> CGContext? {
        CGContext(data: baseAddress, width: width, height: height,
                  bitsPerComponent: format.bitsPerComponent, bytesPerRow: bytesPerRow,
                  space: colorSpace, bitmapInfo: format.cgBitmapInfo)
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

    public func rowBytes(width: Int, format: PixelFormat) -> Int {
        let align = max(64, device.minimumLinearTextureAlignment(for: format.metalFormat))
        return (width * format.bytesPerPixel + align - 1) / align * align
    }

    public func make(width: Int, height: Int, format: PixelFormat, colorSpace: CGColorSpace) -> PixelBuffer? {
        precondition(width > 0 && height > 0)
        let bpr = rowBytes(width: width, format: format)
        let needed = bpr * height
        let length = (needed + Self.granule - 1) / Self.granule * Self.granule
        let buffer = take(length) ?? device.makeBuffer(length: length, options: [.storageModeShared])
        guard let buffer else { return nil }
        return PixelBuffer(width: width, height: height, bytesPerRow: bpr, format: format,
                           colorSpace: colorSpace, buffer: buffer, pool: self)
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
