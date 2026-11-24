import CoreGraphics
import Foundation
import ImageIO

/// Moves the pixels of an ImageIO `CGImage` into a pooled `PixelBuffer` **in the image's own
/// memory layout** (full decodes RGBX → `.rgba8`, thumbnails XRGB → `.argb8`, HEIC/AVIF thumbnails
/// RGBA premultiplied, RAW 16-bit RGBX LE → `.rgba16`): the renderer samples every layout with a
/// format + swizzle, so no CPU conversion ever runs. The copy is one `memcpy` per row from the
/// provider's bytes (CoreGraphics' `CGDataProviderRetainBytePtr`, resolved at runtime); when the
/// provider has no direct bytes (lazy RAW decodes) a draw into a context of the identical format
/// and colour space performs the decode without converting.
enum NativeImage {
    private typealias RetainFn = @convention(c) (CGDataProvider) -> UnsafeRawPointer?
    private typealias ReleaseFn = @convention(c) (CGDataProvider) -> Void
    private static let handle = UnsafeMutableRawPointer(bitPattern: -2)
    private static let retainBytes: RetainFn? = dlsym(handle, "CGDataProviderRetainBytePtr").map {
        unsafeBitCast($0, to: RetainFn.self)
    }
    private static let releaseBytes: ReleaseFn? = dlsym(handle, "CGDataProviderReleaseBytePtr").map {
        unsafeBitCast($0, to: ReleaseFn.self)
    }

    /// The `PixelLayout`/`AlphaMode` that describes `image`'s bytes exactly, or nil.
    static func layout(of image: CGImage) -> (PixelLayout, AlphaMode)? {
        let info = image.bitmapInfo
        let order = CGBitmapInfo(rawValue: info.rawValue & CGBitmapInfo.byteOrderMask.rawValue)
        let float = info.contains(.floatComponents)
        let alpha = image.alphaInfo
        let mode: AlphaMode
        switch alpha {
        case .noneSkipLast, .noneSkipFirst, .none: mode = .opaque
        case .premultipliedLast, .premultipliedFirst: mode = .premultiplied
        case .last, .first: mode = .straight
        default: return nil
        }
        let last = alpha == .noneSkipLast || alpha == .premultipliedLast || alpha == .last
        let first = alpha == .noneSkipFirst || alpha == .premultipliedFirst || alpha == .first
        switch (image.bitsPerComponent, image.bitsPerPixel, float) {
        case (8, 32, false):
            let big = order.rawValue == 0 || order == .byteOrder32Big
            if last && big { return (.rgba8, mode) }       // bytes R G B A
            if first && big { return (.argb8, mode) }      // bytes A R G B
            if first && order == .byteOrder32Little { return (.bgra8, mode) }  // bytes B G R A
            return nil
        case (16, 64, false):
            return last && order == .byteOrder16Little ? (.rgba16, mode) : nil
        case (16, 64, true):
            return last && order == .byteOrder16Little ? (.rgba16f, mode) : nil
        default:
            return nil
        }
    }

    static func rgbSpace(_ image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb { return space }
        return TurboJPEG.sRGB
    }

    /// Copy `image` into a pooled buffer without converting. Returns nil when the layout is not
    /// representable (the caller then draws into `.bgra8`, which converts — rare formats only).
    static func copy(_ image: CGImage, pool: PixelBufferPool) -> PixelBuffer? {
        guard let (layout, alpha) = layout(of: image), image.colorSpace?.model ?? .rgb == .rgb else { return nil }
        let space = rgbSpace(image)
        guard let pixels = pool.make(width: image.width, height: image.height, layout: layout, alpha: alpha,
                                     colorSpace: space) else { return nil }
        let rowBytes = image.width * layout.bytesPerPixel
        if let provider = image.dataProvider, let retainBytes, let releaseBytes, let source = retainBytes(provider) {
            defer { releaseBytes(provider) }
            let srcStride = image.bytesPerRow
            guard srcStride >= rowBytes else { return nil }
            let dst = pixels.baseAddress
            if srcStride == pixels.bytesPerRow {
                memcpy(dst, source, srcStride * (image.height - 1) + rowBytes)
            } else {
                for y in 0..<image.height {
                    memcpy(dst + y * pixels.bytesPerRow, source + y * srcStride, rowBytes)
                }
            }
            return pixels
        }
        return draw(image, into: pixels) ? pixels : nil
    }

    /// Draw `image` into `pixels` through a context of the image's own bitmap format (no conversion
    /// when format and colour space match; this is also what forces lazy RAW decodes).
    static func draw(_ image: CGImage, into pixels: PixelBuffer) -> Bool {
        var info = image.bitmapInfo.rawValue
        // Bitmap contexts cannot hold straight alpha; such images are drawn premultiplied.
        let alphaMask = CGBitmapInfo.alphaInfoMask.rawValue
        if image.alphaInfo == .last { info = (info & ~alphaMask) | CGImageAlphaInfo.premultipliedLast.rawValue }
        if image.alphaInfo == .first { info = (info & ~alphaMask) | CGImageAlphaInfo.premultipliedFirst.rawValue }
        guard let context = CGContext(data: pixels.baseAddress, width: pixels.width, height: pixels.height,
                                      bitsPerComponent: image.bitsPerComponent, bytesPerRow: pixels.bytesPerRow,
                                      space: pixels.colorSpace, bitmapInfo: info) else { return false }
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
        return true
    }

    /// Last resort for layouts the renderer cannot sample (gray, CMYK, 16-bit big-endian, …):
    /// a converting draw into premultiplied BGRA.
    static func convert(_ image: CGImage, pool: PixelBufferPool, opaque: Bool) -> PixelBuffer? {
        let space = rgbSpace(image)
        guard let pixels = pool.make(width: image.width, height: image.height, layout: .bgra8,
                                     alpha: opaque ? .opaque : .premultiplied, colorSpace: space),
              let context = pixels.makeContext() else { return nil }
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }

    /// Native copy when possible, converting draw otherwise.
    static func pixels(_ image: CGImage, pool: PixelBufferPool, opaque: Bool) throws -> PixelBuffer {
        if let pixels = copy(image, pool: pool) { return pixels }
        if let pixels = convert(image, pool: pool, opaque: opaque) { return pixels }
        throw DecodeError.outOfMemory
    }
}
