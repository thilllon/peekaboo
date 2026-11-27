import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Small thumbnails for lists (the viewer's image list): an 8-bit BGRA image (premultiplied, Display P3) whose long side
/// is at most the size asked for, turned the way the photo is shown, in the format Core Animation composites as it is (a
/// layer's `contents` in another format is converted on the main thread when the layer tree is committed).
///
/// From a decoded tier the viewer holds (`make(from:)`), or from the file's embedded preview where it has one, so a whole
/// image is not decoded for it: the EXIF thumbnail of a JPEG (without the black bars cameras add to fit a 3:2 photo into
/// 4:3; 0.3–3 ms), the thumbnail item of a HEIC (1–3 ms), the preview of a camera RAW (11–33 ms), the container rendition
/// of a CR3 (13 ms), for which ImageIO has no preview (asking it runs a RAW decode). Without one (PNG, WebP, a HEIC
/// without thumbnail item, a JPEG without EXIF thumbnail) ImageIO makes it from the image, which decodes the file
/// (24 MP JPEG 34–69 ms, HEIC 48–77 ms, PNG 119–288 ms, WebP 327–386 ms). Times: `peekaboo-bench thumbs`, 96 px, warm.
/// Blocking: call it off the main thread.
public enum Thumbnail {
    /// Where the pixels came from.
    public enum Source: String, Sendable {
        /// The file's embedded thumbnail or preview.
        case embedded
        /// A rendition in the file's container that ImageIO does not expose (CR3).
        case container
        /// The image itself (no embedded preview).
        case image
    }

    public static func make(_ url: URL, maxPixelSize: Int) -> (image: CGImage, source: Source)? {
        let size = max(maxPixelSize, 1)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, DecodeProbe.sourceOptions),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let type = CGImageSourceGetType(source) as String? ?? ""
        if type == cr3Type {
            return containerPreview(url, raw: source, index: index, size: size).map { ($0, .container) }
        }
        // ImageIO takes the embedded thumbnail when there is one, and otherwise makes one from the image, with or
        // without `…FromImageIfAbsent` (macOS 26). What the file holds says which it will be.
        let embedded: Bool
        let exifThumbnail = type == UTType.jpeg.identifier && JPEGScan.scan(url: url)?.hasEXIFThumbnail == true
        if type == UTType.jpeg.identifier {
            embedded = exifThumbnail
        } else if heifTypes.contains(type) {
            embedded = hasThumbnailItem(source, index)
        } else {
            embedded = UTType(type)?.conforms(to: .rawImage) ?? false
        }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: size,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceShouldCache: false,
        ]
        guard let made = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { return nil }
        let thumbnail = exifThumbnail ? trimmed(made, source: source, index: index) : made
        return redraw(thumbnail, maxPixelSize: size).map { ($0, embedded ? .embedded : .image) }
    }

    /// A decoded tier of the file (the viewer's cached preview) as a thumbnail: no file read and no decode, its pixels
    /// drawn smaller: 0.1–0.6 ms from previews of up to 512 px, 1–4 ms from the 1,000–1,500 px ones of some JPEGs, HEICs
    /// and PNGs. Nil for HDR and 10-bit pixels, which the file then gives.
    public static func make(from decoded: DecodedImage, maxPixelSize: Int) -> CGImage? {
        let pixels = decoded.pixels
        guard !decoded.isHDR, let info = bitmapInfo(pixels.layout, pixels.alpha) else { return nil }
        // The image reads the buffer in place and keeps it alive until it is drawn (a pooled buffer is reused once
        // released).
        let retained = Unmanaged.passRetained(pixels)
        guard let provider = CGDataProvider(dataInfo: retained.toOpaque(), data: pixels.baseAddress, size: pixels.byteCount,
                                            releaseData: { info, _, _ in
                                                if let info { Unmanaged<PixelBuffer>.fromOpaque(info).release() }
                                            }) else {
            retained.release()
            return nil
        }
        guard let image = CGImage(width: pixels.width, height: pixels.height, bitsPerComponent: pixels.layout.bitsPerComponent,
                                  bitsPerPixel: pixels.layout.bytesPerPixel * 8, bytesPerRow: pixels.bytesPerRow,
                                  space: pixels.colorSpace, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                                  decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return redraw(image, maxPixelSize: maxPixelSize, orientation: decoded.orientation)
    }

    /// CoreGraphics' description of `layout` with `alpha` (an opaque buffer's fourth byte is padding).
    private static func bitmapInfo(_ layout: PixelLayout, _ alpha: AlphaMode) -> UInt32? {
        func info(last: Bool) -> CGImageAlphaInfo {
            switch alpha {
            case .opaque: return last ? .noneSkipLast : .noneSkipFirst
            case .premultiplied: return last ? .premultipliedLast : .premultipliedFirst
            case .straight: return last ? .last : .first
            }
        }
        switch layout {
        case .rgba8: return info(last: true).rawValue
        case .argb8: return info(last: false).rawValue
        case .bgra8: return info(last: false).rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        case .rgba16: return info(last: true).rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        case .rgba16f, .bgr10a2: return nil
        }
    }

    private static let cr3Type = "com.canon.cr3-raw-image"
    private static let heifTypes: Set<String> = ["public.heic", "public.heif", "public.avif", "public.heics", "public.avci",
                                                 "public.avis"]
    private static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!

    /// The HEIF's primary image has a thumbnail item.
    private static func hasThumbnailItem(_ source: CGImageSource, _ index: Int) -> Bool {
        guard let properties = CGImageSourceCopyProperties(source, DecodeProbe.sourceOptions) as? [CFString: Any],
              let contents = properties[kCGImagePropertyFileContentsDictionary] as? [CFString: Any],
              let images = contents[kCGImagePropertyImages] as? [[CFString: Any]], !images.isEmpty else { return false }
        let image = index < images.count ? images[index] : images[0]
        return !((image[kCGImagePropertyThumbnailImages] as? [Any])?.isEmpty ?? true)
    }

    /// A JPEG's EXIF thumbnail letterboxed to another aspect ratio than the photo's (cameras store 160×120 with black bars
    /// above and below a 3:2 photo): its middle, at the photo's aspect ratio. The photo's size and orientation come from
    /// its properties (0.1 ms).
    static func trimmed(_ thumbnail: CGImage, source: CGImageSource, index: Int) -> CGImage {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, DecodeProbe.sourceOptions) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return thumbnail }
        let orientation = (properties[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init)
        let turned = orientation.map(swapsAxes) ?? false
        let photo = turned ? Double(height) / Double(width) : Double(width) / Double(height)
        let w = Double(thumbnail.width), h = Double(thumbnail.height)
        guard abs(w / h - photo) > 0.01 * photo else { return thumbnail }
        let rect: CGRect
        if photo > w / h {
            let kept = (w / photo).rounded()
            rect = CGRect(x: 0, y: ((h - kept) / 2).rounded(), width: w, height: kept)
        } else {
            let kept = (h * photo).rounded()
            rect = CGRect(x: ((w - kept) / 2).rounded(), y: 0, width: kept, height: h)
        }
        return thumbnail.cropping(to: rect) ?? thumbnail
    }

    /// The smallest rendition of a CR3's container (`CR3Preview`: a 1620×1080 JPEG, or HEVC from bodies shooting HDR PQ, as
    /// ImageIO's tone-mapped SDR rendition), scaled by ImageIO and turned by the RAW's orientation (the rendition carries
    /// none of its own).
    private static func containerPreview(_ url: URL, raw: CGImageSource, index: Int, size: Int) -> CGImage? {
        guard let candidate = CR3Preview.candidates(url: url).first,
              let bytes = CR3Preview.bytes(url: url, candidate),
              let preview = CGImageSourceCreateWithData(bytes as CFData, DecodeProbe.sourceOptions) else { return nil }
        var options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: size,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceShouldCache: false,
        ]
        if candidate.isHEVC { options[kCGImageSourceDecodeRequest] = kCGImageSourceDecodeToSDR }
        guard let image = CGImageSourceCreateThumbnailAtIndex(preview, CGImageSourceGetPrimaryImageIndex(preview),
                                                              options as CFDictionary) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(raw, index, DecodeProbe.sourceOptions) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init)
        return redraw(image, maxPixelSize: size, orientation: orientation ?? .up)
    }

    static func swapsAxes(_ orientation: CGImagePropertyOrientation) -> Bool {
        switch orientation {
        case .leftMirrored, .right, .rightMirrored, .left: return true
        default: return false
        }
    }

    /// `image` drawn into an 8-bit BGRA bitmap (premultiplied, Display P3) at most `maxPixelSize` on its long side,
    /// turned by `orientation` (EXIF).
    static func redraw(_ image: CGImage, maxPixelSize: Int, orientation: CGImagePropertyOrientation = .up) -> CGImage? {
        let turned = swapsAxes(orientation)
        let storedWidth = Double(image.width), storedHeight = Double(image.height)
        let shownWidth = turned ? storedHeight : storedWidth, shownHeight = turned ? storedWidth : storedHeight
        guard shownWidth > 0, shownHeight > 0 else { return nil }
        let scale = min(1, Double(maxPixelSize) / max(shownWidth, shownHeight))
        let width = max(1, Int((shownWidth * scale).rounded())), height = max(1, Int((shownHeight * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: displayP3, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.interpolationQuality = .high
        let w = CGFloat(width), h = CGFloat(height)
        // Stored pixels → shown ones, in the context's coordinates (origin bottom left).
        let transform: CGAffineTransform
        switch orientation {
        case .up: transform = .identity
        case .upMirrored: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case .down: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case .downMirrored: transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case .leftMirrored: transform = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: w, ty: h)
        case .right: transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: h)
        case .rightMirrored: transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .left: transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: w, ty: 0)
        @unknown default: transform = .identity
        }
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: turned ? h : w, height: turned ? w : h))
        return context.makeImage()
    }
}
