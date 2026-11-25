import CoreGraphics
import Foundation
import ImageIO

/// The frames of one animation (GIF, APNG, animated WebP, HEICS, AVIS) as composited canvases, decoded by ImageIO from
/// one `CGImageSource`: disposal (none / background / previous) and blending (source / over) are ImageIO's, checked
/// against hand-made files in the tests. Frames are copied into pooled buffers in their native layout.
///
/// Animated WebP frames come from libwebp (`WebPFrames`): ImageIO composites every WebP frame from the first one
/// again, so the later frames of a long animation took longer than they are shown. The timing stays ImageIO's.
///
/// Not thread-safe: one serial queue owns it (a `CGImageSource` must never be shared across threads). Decode the
/// frames in order: ImageIO composites frame i from frame i − 1, so a jump re-composites from the start.
final class AnimationDecoder {
    let timing: AnimationTiming
    let frameCount: Int
    private let source: CGImageSource
    /// ImageIO declares some composited GIF frames opaque (`noneSkipLast`) although earlier frames left transparent
    /// areas (a "restore to background" disposal, then a frame without a transparent index); their fourth byte is the
    /// canvas alpha (0 there, 255 elsewhere). Honour it for GIF.
    private let alphaOverride: AlphaMode?
    private let opaque: Bool
    /// libwebp's frames of an animated WebP; nil for other formats, and for a WebP whose frame count or canvas
    /// libwebp reads differently from ImageIO (such a file goes through ImageIO, like before).
    private let webp: WebPFrames?
    /// Frames come from libwebp (for tests).
    var decodesWithLibWebP: Bool { webp != nil }

    init(url: URL, info: ImageInfo) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, DecodeProbe.sourceOptions) else {
            throw DecodeError.unreadable(url.lastPathComponent)
        }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { throw DecodeError.unsupported(url.lastPathComponent) }
        self.source = source
        frameCount = count
        timing = Self.timing(source, count: count)
        alphaOverride = info.typeIdentifier == "com.compuserve.gif" ? .premultiplied : nil
        opaque = !info.hasAlpha && alphaOverride == nil
        webp = info.typeIdentifier == "org.webmproject.webp" ? (try? WebPFrames(url: url)).flatMap {
            $0.frameCount == count && $0.canvasWidth == info.pixelWidth && $0.canvasHeight == info.pixelHeight ? $0 : nil
        } : nil
    }

    /// Declared delays (one container read; per-frame properties only where the container lists no unclamped delay:
    /// APNG, whose container carries ImageIO's own clamp at 50 ms) and the loop count.
    static func timing(_ source: CGImageSource, count: Int) -> AnimationTiming {
        let container = CGImageSourceCopyProperties(source, DecodeProbe.sourceOptions) as? [CFString: Any] ?? [:]
        let format = AnimationTiming.animationDictionary(container) ?? [:]
        let entries = format[kCGImagePropertyGIFFrameInfoArray] as? [[CFString: Any]] ?? []
        let delays = (0..<count).map { i -> Double in
            let entry = i < entries.count ? entries[i] : [:]
            if let declared = AnimationTiming.seconds(entry[kCGImagePropertyGIFUnclampedDelayTime]) {
                return AnimationTiming.clamp(declared)
            }
            let frame = (CGImageSourceCopyPropertiesAtIndex(source, i, DecodeProbe.sourceOptions) as? [CFString: Any])
                .flatMap(AnimationTiming.animationDictionary) ?? [:]
            return AnimationTiming.clamp(AnimationTiming.seconds(frame[kCGImagePropertyGIFUnclampedDelayTime])
                ?? AnimationTiming.seconds(frame[kCGImagePropertyGIFDelayTime])
                ?? AnimationTiming.seconds(entry[kCGImagePropertyGIFDelayTime]))
        }
        let loops = (format[kCGImagePropertyGIFLoopCount] as? NSNumber)?.intValue ?? 0
        return AnimationTiming(delays: delays, loopCount: loops)
    }

    /// Frame `index`, composited at canvas size.
    func frame(_ index: Int, pool: PixelBufferPool) throws -> PixelBuffer {
        if let webp { return try webp.frame(index, pool: pool) }
        return try autoreleasepool {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, DecodeProbe.sourceOptions) else {
                throw DecodeError.unsupported("frame \(index)")
            }
            let skipsAlpha = image.alphaInfo == .noneSkipLast || image.alphaInfo == .noneSkipFirst
            return try NativeImage.pixels(image, pool: pool, opaque: opaque, alpha: skipsAlpha ? alphaOverride : nil)
        }
    }
}
