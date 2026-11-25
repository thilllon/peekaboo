import CPeekabooDecode
import CoreGraphics
import Foundation
import ImageIO
import IOSurface

/// The decoder: ImageIO for metadata and every format, routed per file and tier to the fastest
/// path measured on Apple Silicon (docs/DESIGN.md §2):
///
/// | Source | `.preview` | `.screen` | `.full` |
/// |---|---|---|---|
/// | baseline JPEG | MPF large thumbnail, else EXIF thumbnail, else IOSurface SPI /≤4 | IOSurface SPI, power-of-two subsample (≤ 4) covering the target | IOSurface SPI |
/// | progressive JPEG | MPF large thumbnail, else EXIF thumbnail, else ImageIO /8 (DC-only) | libjpeg-turbo, DCT scale covering the target; on screen, the first-pass scans first (approximate, beside it) | libjpeg-turbo (same early rendition when zoomed) |
/// | HEIC / HEIF / AVIF | thumbnail item, else IOSurface SPI /≤4 | IOSurface SPI /≤4 | IOSurface SPI |
/// | camera RAW | embedded preview (CR3: own ISO-BMFF parse) | embedded preview at the target size if it covers it, else RAW decode /n | RAW decode (16-bit) |
/// | PNG (RGB, RGBA, palette; not interlaced) | own decoder (`CPeekabooDecode`), box filter /n | own decoder, box filter /n covering the target | own decoder (16-bit stays 16-bit) |
/// | other PNG, WebP, TIFF, … | thumbnail (`Always`) | IOSurface SPI /n | IOSurface SPI |
///
/// Every path hands over pixels in their native layout (no CPU colour or format conversion) and
/// creates its own `CGImageSource`, so concurrent calls are independent. Whenever the private
/// IOSurface entry point is missing or declines, the public `CGImageSourceCreateImageAtIndex`
/// path with a same-format draw takes over.
public final class ImageIODecoder: ImageDecoder, @unchecked Sendable {
    public init() {}

    /// Parsed metadata per file version: `probe` and the decodes of every tier share one parse.
    let probes = DecodeProbeCache()

    /// Decode gain-map images (`hasGainMap`) to HDR (`kCGImageSourceDecodeToHDR`, extended-linear
    /// Display P3 `.rgba16f`, `isHDR = true`) for `.screen`/`.full`. Off by default: the HDR rendition
    /// costs 10–15× the SDR decode (1.4–2.1 vs 21–27 ms on a 384×512 Apple gain-map JPEG: gain-map
    /// application plus a converting draw; see `peekaboo-bench decode`), above the 2× budget.
    /// Enable with `PEEKABOO_HDR=1` or by setting it.
    nonisolated(unsafe) public static var decodeHDR = ProcessInfo.processInfo.environment["PEEKABOO_HDR"] != nil

    /// Baseline JPEGs up to this many pixels go to the hardware JPEG engines. Measured on M4 Pro /
    /// macOS 26.6 with the IOSurface path (CPU time ≪ wall time = hardware): 12–101.5 MP and
    /// 16384…65000 px wide images are all hardware-decoded; larger ones are unverified and go to
    /// libjpeg-turbo. (Progressive JPEGs are never hardware-decoded, whatever their size.)
    public static let hardwareJPEGMaxPixels = 102_000_000

    /// Fraction of the `.screen` target a progressive JPEG's libjpeg-turbo DCT scale must cover. At 1 (default)
    /// the screen tier covers the target (24 MP on a 3456 px screen: full size, 273 ms). At 0.85 it may stop at
    /// 1/2 (2974 px, 86 %: 255 ms, a quarter of the memory; 101 MP: 1/4, 616 vs 617 ms). That only pays off once
    /// the renderer accepts such a tier at fit: `Renderer.wantsFullResolution` asks for `.full` above 1.01×,
    /// which would decode the whole image again. Set with `PEEKABOO_PROGRESSIVE_COVERAGE=0.85` or directly.
    nonisolated(unsafe) public static var progressiveScreenCoverage: Double = {
        let value = ProcessInfo.processInfo.environment["PEEKABOO_PROGRESSIVE_COVERAGE"].flatMap(Double.init) ?? 1
        return min(1, max(0.5, value))
    }()

    /// Embedded previews whose aspect ratio differs from the image by more than this are ignored
    /// (cropped or letterboxed camera thumbnails would shift the picture when the next tier lands).
    static let previewAspectTolerance = 0.01

    public func probe(_ url: URL) throws -> ImageInfo {
        try autoreleasepool { try DecodeProbe.make(url: url, cache: probes).info }
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
                // Previews go through ImageIO (progressive: DC-only /8; beyond the hardware limit: /4);
                // larger tiers are libjpeg-turbo.
                return tier == .preview ? .general : .cpu
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
        try decode(url, tier: tier, targetLongSide: targetLongSide, pool: pool, partial: nil)
    }

    public func decode(_ url: URL, tier: Tier, targetLongSide: Int, pool: PixelBufferPool, partial: PartialSink?) throws
        -> DecodedImage {
        let start = Trace.now()
        return try autoreleasepool {
            let probe = try DecodeProbe.make(url: url, cache: probes)
            let target = tier == .full ? 0 : max(16, targetLongSide)
            let early = tier == .preview ? nil : partial.map { EarlyRendition(sink: $0, url: url, tier: tier, start: start) }
            defer { early?.finish() }
            let output = try decode(probe, url: url, tier: tier, target: target, pool: pool, early: early)
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

    private func decode(_ probe: DecodeProbe, url: URL, tier: Tier, target: Int, pool: PixelBufferPool,
                        early: EarlyRendition?) throws -> Output {
        let info = probe.info
        if Self.decodeHDR, info.hasGainMap, tier != .preview, let hdr = hdrDecode(probe, target: target, pool: pool) {
            return hdr
        }
        switch probe.kind {
        case .jpeg(let scan):
            return try decodeJPEG(probe, scan: scan, url: url, data: nil, tier: tier, target: target, pool: pool,
                                  early: early)
        case .heif:
            if tier == .preview, probe.hasThumbnailItem, let thumb = embeddedThumbnail(probe, maxPixel: target, pool: pool) {
                return thumb
            }
            // HEVC/AV1 decode the whole image whatever the factor, and /8 is slower than /4
            // (HEIC 12 MP 36 vs 29 ms, 44 MP 122 vs 60 ms; AVIF 24 MP 52 vs 40 ms): cap at /4.
            // Previews without a thumbnail item: /4 is also cheaper than a resampled ImageIO thumbnail
            // (`CreateThumbnailAtIndex`, `…Always`, 1024 px) and /8, and still ≥ 512 px for ≥ 2048 px images
            // (M4 Pro, macOS 26.6, /4 vs thumbnail vs /8: HEIC 12 MP 28.9 / 32.3 / 37.0 ms, 44 MP 55.3 / 68.0 / 63.1,
            // 50 MP 65.6 / 71.7 / 72.7; AVIF 24 MP 39.2 / 45.0 / 46.2).
            return try surfaceOrPublic(probe, subsample: subsample(probe, target, maxFactor: 4), pool: pool)
        case .raw(let cr3):
            return try decodeRAW(probe, cr3: cr3, url: url, tier: tier, target: target, pool: pool)
        case .other:
            if info.typeIdentifier == "public.png", let output = try png(probe, url: url, target: target, pool: pool) {
                return output
            }
            if tier == .preview {
                if let thumb = thumbnail(probe, maxPixel: target, always: true, pool: pool, path: "thumbnail") { return thumb }
            }
            return try surfaceOrPublic(probe, subsample: subsample(probe, target), pool: pool)
        }
    }

    // MARK: PNG

    /// PNG through `CPeekabooDecode`: streaming zlib inflate on a second thread, branchless unfiltering on this one,
    /// the samples as stored (RGBA 8-bit, or 16-bit at full size), box-filtered by the power of two (≤ 8) covering
    /// `target`. 24 MP RGB: 153 ms vs 281 ms through ImageIO (whose subsample factor saves nothing), the same sample
    /// values. Prefetch takes the second thread too: one-thread decodes (~200 ms) left fewer previews ready while
    /// skimming a PNG folder (first pixel p90 108–123 vs 24–32 ms). Nil hands the file to ImageIO: grayscale (ImageIO's
    /// gray colour space and converting draw), Adam7, APNG, anything malformed.
    private func png(_ probe: DecodeProbe, url: URL, target: Int, pool: PixelBufferPool) throws -> Output? {
        guard let bytes = try? Data(contentsOf: url, options: [.alwaysMapped]) else { return nil }
        return try bytes.withUnsafeBytes { raw -> Output? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            var header = pb_png_info()
            guard pb_png_read_info(base, raw.count, &header) == PB_PNG_OK else { return nil }
            let factor = Self.coveringSubsample(long: Int(max(header.width, header.height)), target: target)
            let wide = pb_png_output_bytes_per_pixel(&header, UInt32(factor)) == 8
            let alpha: AlphaMode = header.has_alpha == 0 ? .opaque : factor == 1 ? .straight : .premultiplied
            guard let pixels = pool.make(width: Int(pb_png_scaled(header.width, UInt32(factor))),
                                         height: Int(pb_png_scaled(header.height, UInt32(factor))),
                                         layout: wide ? .rgba16 : .rgba8, alpha: alpha, colorSpace: pngSpace(probe)) else {
                throw DecodeError.outOfMemory
            }
            let status = pb_png_decode(base, raw.count, UInt32(factor), pixels.baseAddress.assumingMemoryBound(to: UInt8.self),
                                       pixels.bytesPerRow, 2)
            guard status == PB_PNG_OK else { return nil }
            return Output(pixels: pixels, orientation: probe.info.orientation, path: "png /\(factor)")
        }
    }

    /// The colour space ImageIO gives the PNG (sRGB when untagged, the iCCP profile, linear sRGB for gAMA 1.0, sRGB for
    /// gAMA 1/2.2 with or without cHRM; a palette's base space): the fast path changes how samples are decoded, not
    /// how they are interpreted.
    private func pngSpace(_ probe: DecodeProbe) -> CGColorSpace {
        switch probe.info.colorProfileName {
        case "sRGB IEC61966-2.1": return TurboJPEG.sRGB
        case "Display P3": return Self.displayP3
        default: break
        }
        guard let space = CGImageSourceCreateImageAtIndex(probe.source, probe.index, DecodeProbe.sourceOptions)?.colorSpace
        else { return TurboJPEG.sRGB }
        if space.model == .indexed, let base = space.baseColorSpace, base.model == .rgb { return base }
        return space.model == .rgb ? space : TurboJPEG.sRGB
    }

    private func subsample(_ probe: DecodeProbe, _ target: Int, maxFactor: Int = 8) -> Int {
        Self.coveringSubsample(long: max(probe.info.pixelWidth, probe.info.pixelHeight), target: target,
                               maxFactor: maxFactor)
    }

    // MARK: JPEG

    /// `data`: in-memory JPEG (CR3 previews); nil reads `url`. `early`: where the first-pass rendition of a progressive
    /// JPEG goes while its exact decode runs.
    private func decodeJPEG(_ probe: DecodeProbe, scan: JPEGScan, url: URL, data: Data?, tier: Tier, target: Int,
                            pool: PixelBufferPool, early: EarlyRendition? = nil) throws -> Output {
        let route = Self.jpegRoute(scan)
        if tier == .preview {
            // The largest embedded preview first: an MPF large thumbnail (640–1920 px) beats the 160 px EXIF one.
            if let preview = mpfPreview(probe, scan: scan, url: url, data: data, target: target, pool: pool) { return preview }
            if scan.hasEXIFThumbnail, let thumb = embeddedThumbnail(probe, maxPixel: target, pool: pool) { return thumb }
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
            // `.screen` of a progressive JPEG is a covering libjpeg-turbo decode unless `progressiveScreenCoverage`
            // relaxes it (DCT scales are 1/2, 1/4, 1/8 only; see `TurboJPEG.coveringScale`). Measured alternatives
            // (24 MP 5947×3964, 3456 px screen, M4 Pro, macOS 26.6): ImageIO /2 305.6 ms (IOSurface SPI) /
            // 307.9 ms (CGImage), /4 301.1 / 311.7 ms — every AC scan is still entropy-decoded; only /8 is
            // DC-only (31 ms) but covers 21 % of the screen. libjpeg-turbo full 273 ms, 1/2 (2974 px, 86 % of
            // the screen) 255 ms; 101 MP 1/4 616 ms vs 1/2 617 ms. Entropy decoding dominates, so a
            // sub-covering screen tier saves ≤ 7 % yet looks softer, and the renderer then asks for `.full`
            // at fit (it wants a tier ≥ 1.01× the displayed size), which costs the whole decode again.
            // What does pay off is skipping the refinement scans: the image on screen gets the first-pass rendition
            // (`EarlyRendition`) from another core in 42–146 ms while this decode runs, unslowed.
            do {
                let coverage = tier == .screen && scan.coding == .progressive ? Self.progressiveScreenCoverage : 1
                let covering = Int((Double(target) * coverage).rounded(.up))
                let bytes = try data ?? Data(contentsOf: url, options: [.alwaysMapped])
                if let early, scan.coding == .progressive, Self.earlyRenditionFits(scan, target: covering) {
                    early.start(bytes, target: covering, info: probe.info, pool: pool)
                }
                let pixels = try bytes.withUnsafeBytes { try TurboJPEG.decode($0, targetLongSide: covering, pool: pool) }
                return Output(pixels: pixels, orientation: probe.info.orientation, path: "libjpeg-turbo")
            } catch TurboJPEG.Failure.memory {
                throw DecodeError.outOfMemory
            } catch {
                return try surfaceOrPublic(probe, subsample: Self.coveringSubsample(long: long, target: target), pool: pool)
            }
        }
    }

    /// The largest MPF large thumbnail whose aspect ratio matches the image (±1 %), decoded like a baseline
    /// JPEG: IOSurface SPI (hardware), power-of-two subsample ≤ 4 covering `target`. The preview is stored
    /// like the primary image, so the primary's EXIF orientation and colour space apply.
    private func mpfPreview(_ probe: DecodeProbe, scan: JPEGScan, url: URL, data: Data?, target: Int,
                            pool: PixelBufferPool) -> Output? {
        let info = probe.info
        let want = aspect(info.pixelWidth, info.pixelHeight)
        guard let pick = scan.mpfPreviews
            .filter({ abs(aspect($0.width, $0.height) - want) <= Self.previewAspectTolerance * want })
            .max(by: { $0.width * $0.height < $1.width * $1.height }),
            let bytes = Self.read(url: url, data: data, offset: pick.offset, length: pick.length),
            let source = CGImageSourceCreateWithData(bytes as CFData, DecodeProbe.sourceOptions) else { return nil }
        let factor = Self.coveringSubsample(long: max(pick.width, pick.height), target: target,
                                            maxFactor: pick.coding == .baseline ? 4 : 8)
        let path = "mpf \(pick.width)x\(pick.height)"
        if let surface = IOSurfaceSPI.surface(source, index: 0, subsample: factor), let layout = IOSurfaceSPI.layout(of: surface) {
            let (space, alpha) = traits(probe)
            let pixels = PixelBuffer(width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface),
                                     bytesPerRow: IOSurfaceGetBytesPerRow(surface), layout: layout, alpha: alpha,
                                     colorSpace: space, storage: .surface(surface))
            return Output(pixels: pixels, orientation: info.orientation, path: "\(path) iosurface /\(factor)")
        }
        var options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if factor > 1 { options[kCGImageSourceSubsampleFactor] = factor }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary),
              let pixels = try? NativeImage.pixels(image, pool: pool, opaque: true) else { return nil }
        return Output(pixels: pixels, orientation: info.orientation, path: "\(path) cgimage /\(factor)")
    }

    /// `length` bytes at `offset` of `data`, or of the file at `url` (bounds-checked against its size).
    static func read(url: URL, data: Data?, offset: Int, length: Int) -> Data? {
        guard offset >= 0, length > 0, length <= 64 << 20 else { return nil }
        if let data {
            guard offset + length <= data.count else { return nil }
            return data.subdata(in: data.startIndex + offset..<data.startIndex + offset + length)
        }
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, offset + length <= Int(st.st_size) else { return nil }
        var bytes = Data(count: length)
        let n = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, length, off_t(offset)) }
        return n == length ? bytes : nil
    }

    /// The early rendition holds a second whole-image coefficient buffer while it decodes (2 bytes per sample, chroma
    /// planes smaller by their subsampling: 0.6 GB for a 101 MP 4:4:4 file, 71 MB for 24 MP 4:2:0) and its own output
    /// until the exact tier replaces it (0.4 GB for that 101 MP file's `.full`): only when both together are small
    /// against physical memory (RAM / 32: 1.5 GB on 48 GB, 256 MB on 8 GB).
    static func earlyRenditionFits(_ scan: JPEGScan, target: Int,
                                   physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Bool {
        let factor = TurboJPEG.coveringScale(width: scan.width, height: scan.height, target: target)
        let output = Double(TurboJPEG.scaled(scan.width, factor)) * Double(TurboJPEG.scaled(scan.height, factor)) * 4
        let chroma = Double(max(0, scan.components - 1)) / Double(max(1, scan.lumaH * scan.lumaV))
        let coefficients = Double(scan.width) * Double(scan.height) * (1 + chroma) * 2
        return coefficients + output <= Double(physicalMemory) / 32
    }

    // MARK: RAW

    private func decodeRAW(_ probe: DecodeProbe, cr3: Bool, url: URL, tier: Tier, target: Int,
                           pool: PixelBufferPool) throws -> Output {
        let info = probe.info
        let long = max(info.pixelWidth, info.pixelHeight)
        if tier != .full {
            if cr3 {
                // ImageIO exposes no CR3 preview (asking runs a RAW decode): use the container's JPEG / HEVC
                // renditions (HDR PQ EOS R5 Mark II `.screen` from its HEVC tile grid: 88 ms vs 421 ms for the RAW).
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
              let source = CGImageSourceCreateWithData(data as CFData, DecodeProbe.sourceOptions) else { return nil }
        guard let probe = try? data.withUnsafeBytes({ try DecodeProbe(source: source, url: url, jpegBytes: $0) }) else {
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
    private func embeddedThumbnail(_ probe: DecodeProbe, maxPixel: Int, pool: PixelBufferPool) -> Output? {
        thumbnail(probe, maxPixel: maxPixel, always: false, pool: pool, path: "embedded")
    }

    private func thumbnail(_ probe: DecodeProbe, maxPixel: Int, always: Bool, pool: PixelBufferPool, path: String) -> Output? {
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
    private func surface(_ probe: DecodeProbe, subsample: Int) -> Output? {
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
    private func traits(_ probe: DecodeProbe) -> (CGColorSpace, AlphaMode) {
        if !probe.info.hasAlpha {
            switch probe.info.colorProfileName {
            case "sRGB IEC61966-2.1": return (TurboJPEG.sRGB, .opaque)
            case "Display P3": return (Self.displayP3, .opaque)
            default: break
            }
        }
        guard let image = CGImageSourceCreateImageAtIndex(probe.source, probe.index, DecodeProbe.sourceOptions) else {
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

    private func surfaceOrPublic(_ probe: DecodeProbe, subsample: Int, pool: PixelBufferPool) throws -> Output {
        if let output = surface(probe, subsample: subsample) { return output }
        return try publicImage(probe, subsample: subsample, pool: pool)
    }

    /// Public fallback: a lazy CGImage (parallel-safe, unlike `ShouldCacheImmediately`) decoded by a
    /// same-format draw into a pooled buffer.
    private func publicImage(_ probe: DecodeProbe, subsample: Int, pool: PixelBufferPool,
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
    private func hdrDecode(_ probe: DecodeProbe, target: Int, pool: PixelBufferPool) -> Output? {
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

/// The first-pass rendition of one progressive JPEG decode, made on another core while the exact decode runs and
/// handed to the sink as an approximate tier. The exact decode is not slowed (screen tier with / without it, medians
/// of 5 runs: 24 MP 4:4:4 298 / 300 ms, 4:2:0 166 / 164 ms, 101 MP 673 / 682 ms, panorama 932 / 933 ms) and the
/// rendition lands after 42 ms (24 MP 4:2:0) to 146 ms (22705 px panorama) instead of 164–933 ms.
final class EarlyRendition: @unchecked Sendable {
    private let sink: PartialSink
    private let url: URL
    private let tier: Tier
    private let start: UInt64
    private let lock = NSLock()
    private var finished = false

    init(sink: PartialSink, url: URL, tier: Tier, start: UInt64) {
        self.sink = sink
        self.url = url
        self.tier = tier
        self.start = start
    }

    /// The exact decode is done: a rendition still decoding is dropped.
    func finish() {
        lock.lock(); finished = true; lock.unlock()
    }

    private var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    /// Decode the first-pass scans of `bytes` at the scale covering `target`, at the caller's QoS, if the sink still
    /// wants a rendition.
    func start(_ bytes: Data, target: Int, info: ImageInfo, pool: PixelBufferPool) {
        guard sink.wanted() else { return }
        let qos = DispatchQoS.QoSClass(rawValue: qos_class_self()) ?? .userInitiated
        DispatchQueue.global(qos: qos).async { [self] in
            // Asked again: on a saturated machine the block may start late, after the user moved on.
            guard !isFinished, sink.wanted() else { return }
            let t0 = Trace.now()
            let decoded = autoreleasepool {
                try? bytes.withUnsafeBytes { try TurboJPEG.decodeFirstPasses($0, targetLongSide: target, pool: pool) }
            }
            guard let pixels = decoded, !isFinished, sink.wanted() else { return }
            Trace.log("decode \(url.lastPathComponent) \(tier) early first-pass scans: \(pixels.width)x\(pixels.height) "
                      + String(format: "%.2f ms (%.2f ms after the decode began)", Trace.ms(since: t0), Trace.ms(since: start)))
            sink.deliver(DecodedImage(pixels: pixels, tier: tier, fullWidth: info.orientedWidth, fullHeight: info.orientedHeight,
                                      orientation: info.orientation, isHDR: false, decodeNanos: Trace.now() - start,
                                      isApproximate: true))
        }
    }
}
