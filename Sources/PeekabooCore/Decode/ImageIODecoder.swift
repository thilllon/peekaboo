import CoreGraphics
import Foundation
import ImageIO

/// Walking-skeleton decoder: correct for every ImageIO format but not yet fast
/// (CPU thumbnail resampling, BGRA conversion). The decode workstream replaces
/// the internals with the hardware/zero-copy paths from the research.
public final class ImageIODecoder: ImageDecoder, @unchecked Sendable {
    public init() {}

    public func probe(_ url: URL) throws -> ImageInfo {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else {
            throw DecodeError.unreadable(url.lastPathComponent)
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, options) as? [CFString: Any] else {
            throw DecodeError.unreadable(url.lastPathComponent)
        }
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0 else { throw DecodeError.unsupported(url.lastPathComponent) }
        let raw = props[kCGImagePropertyOrientation] as? UInt32 ?? 1
        return ImageInfo(
            pixelWidth: width, pixelHeight: height,
            orientation: CGImagePropertyOrientation(rawValue: raw) ?? .up,
            typeIdentifier: (CGImageSourceGetType(source) as String?) ?? "",
            hasAlpha: props[kCGImagePropertyHasAlpha] as? Bool ?? false,
            hasGainMap: false, frameCount: CGImageSourceGetCount(source),
            colorProfileName: props[kCGImagePropertyProfileName] as? String, exif: [:])
    }

    public func decode(_ url: URL, tier: Tier, targetLongSide: Int, pool: PixelBufferPool) throws -> DecodedImage {
        let start = Trace.now()
        let info = try probe(url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw DecodeError.unreadable(url.lastPathComponent)
        }
        let fullLong = max(info.pixelWidth, info.pixelHeight)
        let maxSize = tier == .full ? fullLong : min(fullLong, max(64, targetLongSide))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            throw DecodeError.unsupported(url.lastPathComponent)
        }
        let space = (image.colorSpace?.model == .rgb ? image.colorSpace : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let pixels = pool.make(width: image.width, height: image.height, layout: .bgra8,
                                     alpha: info.hasAlpha ? .premultiplied : .opaque, colorSpace: space),
              let context = pixels.makeContext() else { throw DecodeError.outOfMemory }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return DecodedImage(pixels: pixels, tier: tier, fullWidth: info.orientedWidth, fullHeight: info.orientedHeight,
                            orientation: .up, isHDR: false, decodeNanos: Trace.now() - start)
    }
}
