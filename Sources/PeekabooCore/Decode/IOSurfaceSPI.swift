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

    /// Whether the SPI is present at runtime (tests and the bench report it).
    static var isAvailable: Bool { create != nil }

    /// Decode `index` of `source` into an IOSurface (`subsample` ∈ {1, 2, 4, 8}).
    static func surface(_ source: CGImageSource, index: Int, subsample: Int) -> IOSurfaceRef? {
        guard let create else { return nil }
        var options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if subsample > 1 { options[kCGImageSourceSubsampleFactor] = subsample }
        return create(source, index, options as CFDictionary)?.takeRetainedValue()
    }

    /// Pixel layouts the renderer can sample straight from an ImageIO surface.
    static func layout(of surface: IOSurfaceRef) -> PixelLayout? {
        guard IOSurfaceGetPlaneCount(surface) == 0 else { return nil }
        switch IOSurfaceGetPixelFormat(surface) {
        case 0x4247_5241: return IOSurfaceGetBytesPerElement(surface) == 4 ? .bgra8 : nil  // 'BGRA'
        case 0x6C36_3472: return IOSurfaceGetBytesPerElement(surface) == 8 ? .rgba16 : nil  // 'l64r' 16-bit RGBA LE
        case 0x5247_6841: return IOSurfaceGetBytesPerElement(surface) == 8 ? .rgba16f : nil  // 'RGhA' half float
        default: return nil  // YCbCr ('xf20', '420f'), 10-bit, …: let the public path handle it
        }
    }
}
