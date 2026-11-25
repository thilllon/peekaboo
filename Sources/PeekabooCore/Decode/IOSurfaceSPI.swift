import CoreGraphics
import Foundation
import ImageIO
import IOSurface

/// ImageIO's private `CGImageSourceCreateIOSurfaceAtIndex(source, index, options)`.
///
/// It decodes straight into an IOSurface (BGRA for 8-bit sources) that Metal wraps with zero
/// copies, and — unlike `kCGImageSourceShouldCacheImmediately` decodes, which ImageIO serialises
/// process-wide — it runs concurrently and keeps **both** hardware JPEG engines busy
/// (24 MP: 42 ms with 1 worker, 20 ms/image with 2). Measured on macOS 26.6:
/// baseline JPEG of any size we could produce (101 MP, 65000 px wide) is hardware-decoded on
/// this path. Resolved with `dlsym`; every caller has a public-API fallback for a nil result.
enum IOSurfaceSPI {
    private typealias CreateFn = @convention(c) (CGImageSource, Int, CFDictionary?) -> Unmanaged<IOSurfaceRef>?

    private static let create: CreateFn? = {
        if ProcessInfo.processInfo.environment["PEEKABOO_NO_IOSURFACE_SPI"] != nil { return nil }
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGImageSourceCreateIOSurfaceAtIndex") else {
            return nil
        }
        return unsafeBitCast(symbol, to: CreateFn.self)
    }()

    /// `[decode] fast_path`, set when the config is applied (a plain flag the decode lanes read).
    nonisolated(unsafe) static var enabled = true

    /// Whether the SPI is present at runtime and allowed (`PEEKABOO_NO_IOSURFACE_SPI` unset).
    static var isPresent: Bool { create != nil }

    /// Whether decodes use the SPI (tests and the bench report it).
    static var isAvailable: Bool { enabled && create != nil }

    /// ImageIO's private `kCGImageSurfaceFormatRequest` option: asked for `'420f'`, an 8-bit HEIF decodes to its native
    /// YCbCr instead of BGRA (12 MP 10 vs 32 ms, 50 MP 22 vs 83 ms: ImageIO's conversion runs on the CPU).
    private static let formatRequestKey: CFString? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "kCGImageSurfaceFormatRequest")
        .map { $0.assumingMemoryBound(to: CFString.self).pointee }

    /// Whether `surface(…, format:)` can ask for a pixel format.
    static var canRequestFormat: Bool { isAvailable && formatRequestKey != nil }

    /// Decode `index` of `source` into an IOSurface (`subsample` ∈ {1, 2, 4, 8}); nil while `enabled` is off.
    /// `request`: a `kCGImageSourceDecodeRequest` value (`kCGImageSourceDecodeToSDR` for PQ / HLG images, which the SPI
    /// honours). `format`: a surface pixel format to ask for (`canRequestFormat`).
    static func surface(_ source: CGImageSource, index: Int, subsample: Int, request: CFString? = nil,
                        format: OSType? = nil) -> IOSurfaceRef? {
        guard enabled, let create else { return nil }
        var options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if subsample > 1 { options[kCGImageSourceSubsampleFactor] = subsample }
        if let request { options[kCGImageSourceDecodeRequest] = request }
        if let format, let formatRequestKey { options[formatRequestKey] = NSNumber(value: format) }
        return create(source, index, options as CFDictionary)?.takeRetainedValue()
    }

    /// Pixel layouts the renderer can sample straight from an ImageIO surface.
    static func layout(of surface: IOSurfaceRef) -> PixelLayout? {
        guard IOSurfaceGetPlaneCount(surface) == 0 else { return nil }
        switch IOSurfaceGetPixelFormat(surface) {
        case 0x4247_5241: return IOSurfaceGetBytesPerElement(surface) == 4 ? .bgra8 : nil  // 'BGRA'
        case 0x6C36_3472: return IOSurfaceGetBytesPerElement(surface) == 8 ? .rgba16 : nil  // 'l64r' 16-bit RGBA LE
        case 0x5247_6841: return IOSurfaceGetBytesPerElement(surface) == 8 ? .rgba16f : nil  // 'RGhA' half float
        default: return nil  // bi-planar YCbCr ('xf20', '420f'): `YCbCrConverter`; anything else: the public path
        }
    }
}
