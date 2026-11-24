import CoreGraphics
import Foundation
import QuickLookThumbnailing

/// QuickLook's system thumbnail cache as a preview source for the background sweep: it persists across launches
/// (≈ 1.2 ms per previously seen file; first generation ≈ 85 ms, done in QuickLook's own processes), so files whose
/// own preview decode is expensive (no embedded thumbnail, PNG, WebP…) still get previews without our CPU time.
enum QuickLookPreview {
    struct Miss: Error {}

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var image: CGImage?
        func set(_ image: CGImage?) { lock.lock(); self.image = image; lock.unlock() }
        func get() -> CGImage? { lock.lock(); defer { lock.unlock() }; return image }
    }

    /// Blocking: QuickLook's thumbnail (EXIF orientation applied) drawn into a pooled buffer, or nil on a miss or timeout.
    static func preview(_ url: URL, longSide: Int, info: ImageInfo?, pool: PixelBufferPool,
                        timeout: TimeInterval) -> DecodedImage? {
        let start = Trace.now()
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: longSide, height: longSide),
                                                   scale: 1, representationTypes: .thumbnail)
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            box.set(representation?.cgImage)
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            QLThumbnailGenerator.shared.cancel(request)
            return nil
        }
        guard let image = box.get(), image.width > 0, image.height > 0 else { return nil }
        let space = (image.colorSpace?.model == .rgb ? image.colorSpace : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let pixels = pool.make(width: image.width, height: image.height, layout: .bgra8,
                                     alpha: info?.hasAlpha == true ? .premultiplied : .opaque, colorSpace: space),
              let context = pixels.makeContext() else { return nil }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let fullWidth = info?.orientedWidth ?? image.width
        let fullHeight = info?.orientedHeight ?? image.height
        return DecodedImage(pixels: pixels, tier: .preview, fullWidth: fullWidth, fullHeight: fullHeight,
                            orientation: .up, isHDR: false, decodeNanos: Trace.now() - start)
    }
}
