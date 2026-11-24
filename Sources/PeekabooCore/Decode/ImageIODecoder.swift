import CoreGraphics
import Foundation
import ImageIO
import IOSurface

/// The decoder: ImageIO for metadata and every format, routed per file and tier to the fastest
/// path measured on Apple Silicon (docs/DESIGN.md §2):
///
/// | Source | `.preview` | `.screen` | `.full` |
/// |---|---|---|---|
/// | baseline JPEG | EXIF thumbnail, else IOSurface SPI /≤4 | IOSurface SPI, power-of-two subsample (≤ 4) covering the target | IOSurface SPI |
/// | progressive JPEG | EXIF thumbnail, else ImageIO /8 (DC-only) | libjpeg-turbo, DCT scale covering the target | libjpeg-turbo |
/// | HEIC / HEIF / AVIF | thumbnail item, else IOSurface SPI /≤4 | IOSurface SPI /≤4 | IOSurface SPI |
/// | camera RAW | embedded preview (CR3: own ISO-BMFF parse) | embedded preview at the target size if it covers it, else RAW decode /n | RAW decode (16-bit) |
/// | PNG, WebP, TIFF, … | thumbnail (`Always`) | IOSurface SPI /n | IOSurface SPI |
///
/// Every path hands over pixels in their native layout (no CPU colour or format conversion) and
/// creates its own `CGImageSource`, so concurrent calls are independent. Whenever the private
/// IOSurface entry point is missing or declines, the public `CGImageSourceCreateImageAtIndex`
/// path with a same-format draw takes over.
public final class ImageIODecoder: ImageDecoder, @unchecked Sendable {
    public init() {}

    /// Parsed metadata per file version: `probe` and the decodes of every tier share one parse.
    let probes = ProbeCache()

    /// Decode gain-map images (`hasGainMap`) to HDR (`kCGImageSourceDecodeToHDR`, extended-linear
    /// Display P3 `.rgba16f`, `isHDR = true`) for `.screen`/`.full`. Off by default: the HDR rendition
    /// costs 10–15× the SDR decode (1.4 vs 21 ms on a 384×512 Apple gain-map JPEG: gain-map application plus a converting draw; see
    /// `peekaboo-bench decode`), above the 2× budget. Enable with `PEEKABOO_HDR=1` or by setting it.
    nonisolated(unsafe) public static var decodeHDR = ProcessInfo.processInfo.environment["PEEKABOO_HDR"] != nil

    /// Baseline JPEGs up to this many pixels go to the hardware JPEG engines. Measured on M4 Pro /
    /// macOS 26.6 with the IOSurface path (CPU time ≪ wall time = hardware): 12–101.5 MP and
    /// 16384…65000 px wide images are all hardware-decoded; larger ones are unverified and go to
    /// libjpeg-turbo. (Progressive JPEGs are never hardware-decoded, whatever their size.)
    public static let hardwareJPEGMaxPixels = 102_000_000

    /// Embedded previews whose aspect ratio differs from the image by more than this are ignored
    /// (cropped or letterboxed camera thumbnails would shift the picture when the next tier lands).
    static let previewAspectTolerance = 0.01

    public func probe(_ url: URL) throws -> ImageInfo {
        try autoreleasepool { try ImageProbe.make(url: url, cache: probes).info }
    }

    public func lane(for url: URL, info: ImageInfo?, tier: Tier) -> DecodeLane {
        guard let info else {
            switch url.pathExtension.lowercased() {
            case "jpg", "jpeg", "jpe", "jfif", "heic", "heif", "hif", "avif": return .hardware
            default: return .general
            }
        }
        let format = info.exif["format"] ?? ""
        if format.hasPrefix("JPEG") {
            switch Self.jpegRoute(format: format, pixels: info.pixelWidth * info.pixelHeight) {
            case .hardware: return .hardware
            case .turbo:
                // Progressive previews use ImageIO's DC-only /8 path; everything else is libjpeg-turbo.
                return tier == .preview && format.hasPrefix("JPEG progressive") ? .general : .cpu
            case .imageIO: return .general
            }
        }
        switch info.typeIdentifier {
        case "public.heic", "public.heif", "public.avif", "public.heics", "public.avci", "public.avis": return .hardware
        // CR3 previews are embedded JPEG/HEVC (hardware); larger tiers may need a RAW decode.
        case "com.canon.cr3-raw-image": return tier == .preview ? .hardware : .general
        default: return .general
        }
    }

    public func decode(_ url: URL, tier: Tier, targetLongSide: Int, pool: PixelBufferPool) throws -> DecodedImage {
        let start = Trace.now()
        return try autoreleasepool {
            let probe = try ImageProbe.make(url: url, cache: probes)
            let target = tier == .full ? 0 : max(16, targetLongSide)
            let output = try decode(probe, url: url, tier: tier, target: target, pool: pool)
            let nanos = Trace.now() - start
            Trace.log("decode \(url.lastPathComponent) \(tier) via \(output.path): \(output.pixels.width)x\(output.pixels.height) "
                      + "\(output.pixels.layout) \(String(format: "%.2f", Double(nanos) / 1e6)) ms")
            return DecodedImage(pixels: output.pixels, tier: tier, fullWidth: probe.info.orientedWidth,
                                fullHeight: probe.info.orientedHeight, orientation: output.orientation,
                                isHDR: output.isHDR, decodeNanos: nanos)
        }
    }

    // MARK: - Routing

    enum JPEGRoute { case hardware, turbo, imageIO }

    static func jpegRoute(_ scan: JPEGScan) -> JPEGRoute {
        if scan.isCMYK || scan.components == 2 || scan.coding == .lossless || scan.coding == .arithmetic { return .imageIO }
        if scan.coding == .progressive || scan.width * scan.height > hardwareJPEGMaxPixels { return .turbo }
        return .hardware
    }

    static func jpegRoute(format: String, pixels: Int) -> JPEGRoute {
        if format.contains("CMYK") || format.contains("YCCK") || format.hasPrefix("JPEG lossless")
            || format.hasPrefix("JPEG arithmetic") { return .imageIO }
        if format.hasPrefix("JPEG progressive") || pixels > hardwareJPEGMaxPixels { return .turbo }
        return format.hasPrefix("JPEG baseline") ? .hardware : .imageIO
    }

    /// The largest factor in {1, 2, 4, 8} (≤ `maxFactor`) whose output long side still covers `target`.
    static func coveringSubsample(long: Int, target: Int, maxFactor: Int = 8) -> Int {
        guard target > 0 else { return 1 }
        var factor = 1
        for candidate in [2, 4, 8] where candidate <= maxFactor && long / candidate >= target { factor = candidate }
        return factor
    }

    struct Output {
        let pixels: PixelBuffer
        let orientation: CGImagePropertyOrientation
        var isHDR = false
        let path: String
    }

    private func decode(_ probe: ImageProbe, url: URL, tier: Tier, target: Int, pool: PixelBufferPool) throws -> Output {
        let info = probe.info
        if Self.decodeHDR, info.hasGainMap, tier != .preview, let hdr = hdrDecode(probe, target: target, pool: pool) {
            return hdr
        }
        switch probe.kind {
        case .jpeg(let scan):
            return try decodeJPEG(probe, scan: scan, url: url, data: nil, tier: tier, target: target, pool: pool)
        case .heif:
            if tier == .preview, probe.hasThumbnailItem, let thumb = embeddedThumbnail(probe, maxPixel: target, pool: pool) {
                return thumb
            }
            // HEVC/AV1 decode the whole image whatever the factor, and /8 is slower than /4
            // (HEIC 12 MP 36 vs 29 ms, 44 MP 122 vs 60 ms; AVIF 24 MP 52 vs 40 ms): cap at /4.
            return try surfaceOrPublic(probe, subsample: subsample(probe, target, maxFactor: 4), pool: pool)
        case .raw(let cr3):
            return try decodeRAW(probe, cr3: cr3, url: url, tier: tier, target: target, pool: pool)
        case .other:
            if tier == .preview {
                if let thumb = thumbnail(probe, maxPixel: target, always: true, pool: pool, path: "thumbnail") { return thumb }
            }
            return try surfaceOrPublic(probe, subsample: subsample(probe, target), pool: pool)
        }
    }

    private func subsample(_ probe: ImageProbe, _ target: Int, maxFactor: Int = 8) -> Int {
        Self.coveringSubsample(long: max(probe.info.pixelWidth, probe.info.pixelHeight), target: target,
                               maxFactor: maxFactor)
    }

    // MARK: JPEG

    /// `data`: in-memory JPEG (CR3 previews); nil reads `url`.
    private func decodeJPEG(_ probe: ImageProbe, scan: JPEGScan, url: URL, data: Data?, tier: Tier, target: Int,
                            pool: PixelBufferPool) throws -> Output {
        let route = Self.jpegRoute(scan)
        if tier == .preview, scan.hasEXIFThumbnail, let thumb = embeddedThumbnail(probe, maxPixel: target, pool: pool) {
            return thumb
        }
        let long = max(scan.width, scan.height)
        // Baseline JPEG: never /8 — it leaves the hardware path on the public CGImage route
        // (24 MP 43 vs 36 ms, 50 MP 138 vs 71 ms); through the IOSurface SPI /4 and /8 cost the same.
        let baselineFactor = Self.coveringSubsample(long: long, target: target, maxFactor: 4)
        switch route {
        case .hardware, .imageIO:
            return try surfaceOrPublic(probe, subsample: baselineFactor, pool: pool)
        case .turbo:
            if tier == .preview {
                // Progressive: ImageIO's /8 path decodes only the DC scan (24 MP ~32 ms vs ~300 ms for anything
                // larger). Baseline beyond the hardware limit: /4.
                let factor = scan.coding == .progressive ? 8 : baselineFactor
                if let output = try? surfaceOrPublic(probe, subsample: factor, pool: pool) { return output }
            }
            do {
                let pixels = try turbo(url: url, data: data, target: target, pool: pool)
                return Output(pixels: pixels, orientation: probe.info.orientation, path: "libjpeg-turbo")
            } catch TurboJPEG.Failure.memory {
                throw DecodeError.outOfMemory
            } catch {
                return try surfaceOrPublic(probe, subsample: Self.coveringSubsample(long: long, target: target), pool: pool)
            }
        }
    }

    private func turbo(url: URL, data: Data?, target: Int, pool: PixelBufferPool) throws -> PixelBuffer {
        let bytes = try data ?? Data(contentsOf: url, options: [.alwaysMapped])
        return try bytes.withUnsafeBytes { try TurboJPEG.decode($0, targetLongSide: target, pool: pool) }
    }

    // MARK: RAW

    private func decodeRAW(_ probe: ImageProbe, cr3: Bool, url: URL, tier: Tier, target: Int,
                           pool: PixelBufferPool) throws -> Output {
        let info = probe.info
        let long = max(info.pixelWidth, info.pixelHeight)
        if tier != .full {
            if cr3 {
                // ImageIO exposes no CR3 preview (asking runs a RAW decode): use the container's JPEGs.
                if let output = cr3Preview(url: url, info: info, tier: tier, target: target, pool: pool) { return output }
            } else {
                // Without `…Always` ImageIO returns the camera's embedded JPEG, scaled to the target when it is
                // larger (DCT scaling: NEF 8256 px preview → 3456 px in 93 ms and 48 MB instead of 127 ms and 180 MB
                // at native size). A preview smaller than the screen target falls through to a RAW decode.
                if let preview = embeddedThumbnail(probe, maxPixel: target, pool: pool),
                   tier == .preview || max(preview.pixels.width, preview.pixels.height) >= min(target, long) {
                    return preview
                }
            }
        }
        // RAW decode: the SPI declines full size (returns nil) but delivers 16-bit RGBA for /2…/8.
        let factor = Self.coveringSubsample(long: long, target: target)
        if factor > 1, let output = surface(probe, subsample: factor) { return output }
        return try publicImage(probe, subsample: factor, pool: pool)
    }

    private func cr3Preview(url: URL, info: ImageInfo, tier: Tier, target: Int, pool: PixelBufferPool) -> Output? {
        let candidates = CR3Preview.candidates(url: url).filter { abs(aspect($0.width, $0.height) - aspect(info.pixelWidth, info.pixelHeight))
            <= Self.previewAspectTolerance * aspect(info.pixelWidth, info.pixelHeight) }
        let need = min(target, max(info.pixelWidth, info.pixelHeight))
        guard let pick = candidates.first(where: { max($0.width, $0.height) >= need }) ?? (tier == .preview ? candidates.last : nil),
              let data = CR3Preview.bytes(url: url, pick),
              let source = CGImageSourceCreateWithData(data as CFData, ImageProbe.sourceOptions) else { return nil }
        guard let probe = try? data.withUnsafeBytes({ try ImageProbe(source: source, url: url, jpegBytes: $0) }) else {
            return nil
        }
        let decoded: Output?
        switch probe.kind {
        case .jpeg(let scan):
            decoded = try? decodeJPEG(probe, scan: scan, url: url, data: data, tier: tier == .preview ? .screen : tier,
                                      target: target, pool: pool)
        case .heif:
            // 10-bit PQ previews (HDR PQ shooting mode): ask ImageIO for its tone-mapped SDR rendition.
            decoded = try? publicImage(probe, subsample: subsample(probe, target), pool: pool,
                                       extra: [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToSDR])
        default:
            decoded = nil
        }
        guard let output = decoded else { return nil }
        // The embedded JPEG carries no orientation of its own; the RAW's EXIF orientation applies.
        return Output(pixels: output.pixels, orientation: output.orientation == .up ? info.orientation : output.orientation,
                      path: "cr3 \(pick.width)x\(pick.height) " + output.path)
    }

    // MARK: - Paths

    private func aspect(_ w: Int, _ h: Int) -> Double { Double(w) / Double(max(1, h)) }

    /// Accept a thumbnail only if its aspect ratio matches the (oriented) image within 1 %.
    private func aspectMatches(_ image: CGImage, _ info: ImageInfo) -> Bool {
        let want = aspect(info.orientedWidth, info.orientedHeight)
        return abs(aspect(image.width, image.height) - want) <= Self.previewAspectTolerance * want
    }

    /// The embedded thumbnail / preview (`MaxPixelSize` without `…Always`), oriented by ImageIO.
    private func embeddedThumbnail(_ probe: ImageProbe, maxPixel: Int, pool: PixelBufferPool) -> Output? {
        thumbnail(probe, maxPixel: maxPixel, always: false, pool: pool, path: "embedded")
    }

    private func thumbnail(_ probe: ImageProbe, maxPixel: Int, always: Bool, pool: PixelBufferPool, path: String) -> Output? {
        var options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
        ]
        if always { options[kCGImageSourceCreateThumbnailFromImageAlways] = true }
        guard let image = CGImageSourceCreateThumbnailAtIndex(probe.source, probe.index, options as CFDictionary),
              aspectMatches(image, probe.info),
              let pixels = try? NativeImage.pixels(image, pool: pool, opaque: !probe.info.hasAlpha) else { return nil }
        return Output(pixels: pixels, orientation: .up, path: "\(path) \(image.width)x\(image.height)")
    }

    /// IOSurface SPI decode, nil when the symbol is missing or ImageIO declines.
    private func surface(_ probe: ImageProbe, subsample: Int) -> Output? {
        guard let surface = IOSurfaceSPI.surface(probe.source, index: probe.index, subsample: subsample),
              let layout = IOSurfaceSPI.layout(of: surface) else { return nil }
        let (space, alpha) = traits(probe)
        let pixels = PixelBuffer(width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface),
                                 bytesPerRow: IOSurfaceGetBytesPerRow(surface), layout: layout, alpha: alpha,
                                 colorSpace: space, storage: .surface(surface))
        return Output(pixels: pixels, orientation: probe.info.orientation, path: "iosurface /\(subsample)")
    }

    /// Colour space and alpha semantics of the source pixels, without decoding. The SPI keeps the
    /// file's alpha as stored (PNG: straight, measured), so it is read from the lazy, header-only
    /// CGImage; opaque images with a well-known profile skip even that.
    private func traits(_ probe: ImageProbe) -> (CGColorSpace, AlphaMode) {
        if !probe.info.hasAlpha {
            switch probe.info.colorProfileName {
            case "sRGB IEC61966-2.1": return (TurboJPEG.sRGB, .opaque)
            case "Display P3": return (Self.displayP3, .opaque)
            default: break
            }
        }
        guard let image = CGImageSourceCreateImageAtIndex(probe.source, probe.index, ImageProbe.sourceOptions) else {
            return (TurboJPEG.sRGB, probe.info.hasAlpha ? .straight : .opaque)
        }
        let alpha: AlphaMode
        switch image.alphaInfo {
        case .premultipliedFirst, .premultipliedLast: alpha = .premultiplied
        case .first, .last: alpha = .straight
        default: alpha = probe.info.hasAlpha ? .straight : .opaque
        }
        return (NativeImage.rgbSpace(image), alpha)
    }

    private func surfaceOrPublic(_ probe: ImageProbe, subsample: Int, pool: PixelBufferPool) throws -> Output {
        if let output = surface(probe, subsample: subsample) { return output }
        return try publicImage(probe, subsample: subsample, pool: pool)
    }

    /// Public fallback: a lazy CGImage (parallel-safe, unlike `ShouldCacheImmediately`) decoded by a
    /// same-format draw into a pooled buffer.
    private func publicImage(_ probe: ImageProbe, subsample: Int, pool: PixelBufferPool,
                             extra: [CFString: Any] = [:]) throws -> Output {
        var options: [CFString: Any] = extra
        options[kCGImageSourceShouldCache] = false
        if subsample > 1 { options[kCGImageSourceSubsampleFactor] = subsample }
        guard let image = CGImageSourceCreateImageAtIndex(probe.source, probe.index, options as CFDictionary) else {
            throw DecodeError.unsupported(probe.info.typeIdentifier)
        }
        let pixels = try NativeImage.pixels(image, pool: pool, opaque: !probe.info.hasAlpha)
        return Output(pixels: pixels, orientation: probe.info.orientation, path: "cgimage /\(subsample)")
    }

    static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
    static let extendedLinearDisplayP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!

    /// Gain-map HDR rendition as extended-linear Display P3 half floats (behind `decodeHDR`).
    private func hdrDecode(_ probe: ImageProbe, target: Int, pool: PixelBufferPool) -> Output? {
        let factor = subsample(probe, target)
        var options: [CFString: Any] = [kCGImageSourceShouldCache: false,
                                        kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR]
        if factor > 1 { options[kCGImageSourceSubsampleFactor] = factor }
        guard let image = CGImageSourceCreateImageAtIndex(probe.source, probe.index, options as CFDictionary),
              let pixels = pool.make(width: image.width, height: image.height, layout: .rgba16f, alpha: .premultiplied,
                                     colorSpace: Self.extendedLinearDisplayP3),
              let context = pixels.makeContext() else { return nil }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Output(pixels: pixels, orientation: probe.info.orientation, isHDR: true, path: "hdr /\(factor)")
    }
}
