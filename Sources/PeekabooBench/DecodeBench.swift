import CoreGraphics
import Foundation
import ImageIO
import Metal
import PeekabooCore

/// `peekaboo-bench decode [--corpus DIR] [--iters N] [--screen PX] [--preview PX] [--threads N] [--skeleton]
///                        [--filter TEXT] [--dump DIR] [--mpf] [--variants]`
///
/// Per corpus file: median wall time of probe / `.preview` / `.screen` / `.full`, the output size and layout,
/// then the parallel throughput of `.screen` decodes over `nav/` (or the whole corpus) with N threads
/// (default 6, the scheduler's lane count) and with 1. `--skeleton` measures the walking-skeleton decoder
/// (CPU thumbnail resampling + BGRA conversion) for before/after comparisons. `--mpf` adds camera-style
/// copies of the corpus JPEGs carrying a 1620 px MPF large thumbnail (the corpus has none). `--variants`
/// times the rejected alternatives for progressive `.screen` and HEIF/AVIF `.preview` (ImageIO subsample
/// factors, resampled thumbnails, a sub-covering libjpeg-turbo scale).
/// The corpus defaults to `$PEEKABOO_CORPUS`.
func runDecodeBench(_ args: ArraySlice<String>) throws {
    var corpus = ProcessInfo.processInfo.environment["PEEKABOO_CORPUS"]
    var iters = 5
    var screen = 3456
    var preview = 512
    var threads = 6
    var skeleton = false
    var filter: String?
    var dump: URL?
    var mpf = false
    var variants = false
    var it = args.makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--corpus": corpus = it.next()
        case "--iters": iters = Int(it.next() ?? "") ?? iters
        case "--screen": screen = Int(it.next() ?? "") ?? screen
        case "--preview": preview = Int(it.next() ?? "") ?? preview
        case "--threads": threads = Int(it.next() ?? "") ?? threads
        case "--filter": filter = it.next()
        case "--skeleton": skeleton = true
        case "--dump": dump = it.next().map { URL(fileURLWithPath: $0) }
        case "--mpf": mpf = true
        case "--variants": variants = true
        default: throw BenchError.usage("unknown option \(arg)")
        }
    }
    guard let corpus else { throw BenchError.usage("set PEEKABOO_CORPUS or pass --corpus DIR") }
    guard let device = MTLCreateSystemDefaultDevice() else { throw BenchError.usage("no Metal device") }
    let pool = PixelBufferPool(device: device, maxRetainedBytes: 2 << 30)
    let decoder: ImageDecoder = skeleton ? SkeletonDecoder() : ImageIODecoder()
    let root = URL(fileURLWithPath: corpus)
    var files = imageFiles(in: root, skipping: "nav")
    if let filter { files = files.filter { $0.path.contains(filter) } }
    guard !files.isEmpty else { throw BenchError.usage("no images under \(corpus)") }
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("peekaboo-bench-\(getpid())")
    defer { try? FileManager.default.removeItem(at: scratch) }
    if mpf { files += try mpfCopies(of: files, in: scratch) }
    if variants {
        try runVariants(files, decoder: decoder, pool: pool, iters: iters, screen: screen)
        return
    }

    print("decoder: \(skeleton ? "skeleton" : "ImageIODecoder")  iters: \(iters)  preview: \(preview) px  screen: \(screen) px")
    func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
    func lpad(_ s: String, _ n: Int) -> String { s.count >= n ? s : String(repeating: " ", count: n - s.count) + s }
    print(pad("file", 46) + lpad("probe", 8) + lpad("preview", 9) + lpad("screen", 9) + lpad("full", 9)
          + "  preview out / screen out / full out")
    var totals = [Double](repeating: 0, count: 4)
    for url in files {
        let name = url.path.replacingOccurrences(of: root.path + "/", with: "")
        var row = pad(String(name.suffix(46)), 46)
        var outs: [String] = []
        var probeTimes: [Double] = []
        for _ in 0..<iters {
            // A fresh decoder each time: the probe column is the uncached metadata parse. The tier
            // decodes below then reuse the shared decoder's probe cache, as they do after the
            // pipeline's own probe.
            let fresh: ImageDecoder = skeleton ? decoder : ImageIODecoder()
            let t0 = Trace.now()
            _ = try? fresh.probe(url)
            probeTimes.append(Trace.ms(since: t0))
        }
        _ = try? decoder.probe(url)
        let probe = median(probeTimes)
        row += lpad(String(format: "%.2f", probe), 8)
        totals[0] += probe
        for (i, tier) in [Tier.preview, .screen, .full].enumerated() {
            let target = tier == .preview ? preview : screen
            var times: [Double] = []
            var out = "-"
            for _ in 0..<(tier == .full ? max(1, iters / 2) : iters) {
                autoreleasepool {
                    let t0 = Trace.now()
                    do {
                        let image = try decoder.decode(url, tier: tier, targetLongSide: target, pool: pool)
                        times.append(Trace.ms(since: t0))
                        let p = image.pixels
                        out = "\(p.width)x\(p.height) \(p.layout)\(image.orientation == .up ? "" : " o\(image.orientation.rawValue)")"
                        if let dump, times.count == 1 {
                            writePNG(p, to: dump.appendingPathComponent("\(url.lastPathComponent)-\(tier).png"))
                        }
                    } catch {
                        out = "error \(error)"
                    }
                }
            }
            let ms = median(times)
            totals[i + 1] += ms
            row += lpad(times.isEmpty ? "-" : String(format: "%.1f", ms), 9)
            outs.append(out)
        }
        print(row + "  " + outs.joined(separator: " / "))
        if !skeleton, let early = earlyRendition(url, decoder: decoder, screen: screen, iters: iters, pool: pool) {
            print(pad("", 46) + "  " + early)
        }
    }
    print(pad("TOTAL (sum of medians)", 46) + lpad(String(format: "%.1f", totals[0]), 8)
          + totals.dropFirst().map { lpad(String(format: "%.1f", $0), 9) }.joined())

    // HDR rendition cost vs SDR for gain-map files (`ImageIODecoder.decodeHDR` stays off unless < 2x).
    if !skeleton {
        let saved = ImageIODecoder.decodeHDR
        defer { ImageIODecoder.decodeHDR = saved }
        for url in files where (try? decoder.probe(url).hasGainMap) == true {
            var line = "hdr \(url.lastPathComponent):"
            for hdr in [false, true] {
                ImageIODecoder.decodeHDR = hdr
                var times: [Double] = []
                var out = ""
                for _ in 0..<iters {
                    autoreleasepool {
                        let t0 = Trace.now()
                        if let image = try? decoder.decode(url, tier: .screen, targetLongSide: screen, pool: pool) {
                            times.append(Trace.ms(since: t0))
                            out = "\(image.pixels.layout)\(image.isHDR ? " HDR" : "")"
                        }
                    }
                }
                line += String(format: " %@ %.2f ms (%@)", hdr ? "HDR" : "SDR", median(times), out)
            }
            print(line)
        }
    }

    // Parallel throughput of .screen decodes (the prefetch workload).
    let navDir = root.appendingPathComponent("nav")
    let navFiles = imageFiles(in: navDir, skipping: nil)
    let workload = navFiles.isEmpty ? files : navFiles
    for width in Array(Set([1, threads])).sorted() {
        let (wall, count) = parallel(workload, threads: width, decoder: decoder, tier: .screen, target: screen, pool: pool)
        print(String(format: "parallel .screen %@: %d threads, %d images in %.0f ms -> %.1f images/s (%.1f ms/image)",
                     navFiles.isEmpty ? "corpus" : "nav", width, count, wall, Double(count) / wall * 1000, wall / Double(count)))
    }
}

private enum BenchError: Error, CustomStringConvertible {
    case usage(String)
    var description: String { if case .usage(let s) = self { return s }; return "" }
}

/// `--dump DIR`: write a decoded buffer as PNG (visual check of layout, alpha and colour tagging).
private func writePNG(_ p: PixelBuffer, to url: URL) {
    let opaque = p.alpha == .opaque
    let info: UInt32
    switch p.layout {
    case .rgba8: info = (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue
    case .bgra8: info = (opaque ? CGImageAlphaInfo.noneSkipFirst : .premultipliedFirst).rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    case .argb8: info = (opaque ? CGImageAlphaInfo.noneSkipFirst : .premultipliedFirst).rawValue
    case .rgba16: info = (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue | CGBitmapInfo.byteOrder16Little.rawValue
    case .rgba16f, .bgr10a2: info = p.layout.cgBitmapInfo
    }
    let data = Data(bytes: p.baseAddress, count: p.byteCount)
    guard let provider = CGDataProvider(data: data as CFData),
          let image = CGImage(width: p.width, height: p.height, bitsPerComponent: p.layout.bitsPerComponent,
                              bitsPerPixel: p.layout.bytesPerPixel * 8, bytesPerRow: p.bytesPerRow, space: p.colorSpace,
                              bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil,
                              shouldInterpolate: false, intent: .defaultIntent),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

/// The first early rendition a decode hands its sink, and when (ms after the decode began).
private final class EarlyCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: (DecodedImage, Double)?

    func set(_ image: DecodedImage, ms: Double) {
        lock.lock(); defer { lock.unlock() }
        if captured == nil { captured = (image, ms) }
    }

    var result: (DecodedImage, Double)? {
        lock.lock(); defer { lock.unlock() }
        return captured
    }
}

/// The screen tier as the image on screen gets it (a sink that always wants an early rendition): when the early
/// rendition lands, beside the exact decode, and its PSNR against that exact tier. Nil for files without one.
private func earlyRendition(_ url: URL, decoder: ImageDecoder, screen: Int, iters: Int, pool: PixelBufferPool) -> String? {
    var times: [Double] = []
    var exactTimes: [Double] = []
    var quality = Double.nan
    for _ in 0..<iters {
        autoreleasepool {
            let capture = EarlyCapture()
            let t0 = Trace.now()
            let sink = PartialSink(wanted: { true }, deliver: { capture.set($0, ms: Trace.ms(since: t0)) })
            guard let exact = try? decoder.decode(url, tier: .screen, targetLongSide: screen, pool: pool, partial: sink) else {
                return
            }
            exactTimes.append(Trace.ms(since: t0))
            guard let (early, ms) = capture.result else { return }
            times.append(ms)
            if quality.isNaN { quality = psnr(early.pixels, exact.pixels) }
        }
    }
    guard !times.isEmpty else { return nil }
    return String(format: "early rendition (first-pass scans) %.1f ms, %.2f dB PSNR vs the exact screen tier (%.1f ms beside it)",
                  median(times), quality, median(exactTimes))
}

/// PSNR (dB) of the colour channels of two 8-bit buffers of the same size and layout.
private func psnr(_ a: PixelBuffer, _ b: PixelBuffer) -> Double {
    guard a.width == b.width, a.height == b.height, a.layout == b.layout, a.layout.bytesPerPixel == 4 else { return .nan }
    let alpha = a.layout == .argb8 ? 0 : 3
    var squared: UInt64 = 0
    for y in 0..<a.height {
        let pa = a.baseAddress.advanced(by: y * a.bytesPerRow).assumingMemoryBound(to: UInt8.self)
        let pb = b.baseAddress.advanced(by: y * b.bytesPerRow).assumingMemoryBound(to: UInt8.self)
        for i in 0..<(a.width * 4) where i % 4 != alpha {
            let d = Int(pa[i]) - Int(pb[i])
            squared += UInt64(d * d)
        }
    }
    let mse = Double(squared) / Double(a.width * a.height * 3)
    return mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
}

private func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
}

private func imageFiles(in dir: URL, skipping: String?) -> [URL] {
    guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
    var files: [URL] = []
    for case let url as URL in walker {
        if let skipping, url.pathComponents.contains(skipping) { continue }
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, !["md", "json", "txt"].contains(ext) else { continue }
        if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(url) }
    }
    return files.sorted { $0.path < $1.path }
}

private func parallel(_ files: [URL], threads: Int, decoder: ImageDecoder, tier: Tier, target: Int,
                      pool: PixelBufferPool) -> (Double, Int) {
    let lock = NSLock()
    var next = 0
    let t0 = Trace.now()
    DispatchQueue.concurrentPerform(iterations: threads) { _ in
        while true {
            lock.lock(); let i = next; next += 1; lock.unlock()
            guard i < files.count else { return }
            autoreleasepool { _ = try? decoder.decode(files[i], tier: tier, targetLongSide: target, pool: pool) }
        }
    }
    return (Trace.ms(since: t0), files.count)
}

/// The walking-skeleton decoder this workstream replaced (CPU thumbnail resampling, BGRA conversion),
/// kept for before/after numbers.
private final class SkeletonDecoder: ImageDecoder, @unchecked Sendable {
    func probe(_ url: URL) throws -> ImageInfo {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { throw DecodeError.unreadable(url.lastPathComponent) }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, options) as? [CFString: Any] else {
            throw DecodeError.unreadable(url.lastPathComponent)
        }
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0 else { throw DecodeError.unsupported(url.lastPathComponent) }
        let raw = props[kCGImagePropertyOrientation] as? UInt32 ?? 1
        return ImageInfo(pixelWidth: width, pixelHeight: height, orientation: CGImagePropertyOrientation(rawValue: raw) ?? .up,
                         typeIdentifier: (CGImageSourceGetType(source) as String?) ?? "",
                         hasAlpha: props[kCGImagePropertyHasAlpha] as? Bool ?? false, hasGainMap: false,
                         frameCount: CGImageSourceGetCount(source), colorProfileName: props[kCGImagePropertyProfileName] as? String,
                         exif: [:])
    }

    func decode(_ url: URL, tier: Tier, targetLongSide: Int, pool: PixelBufferPool) throws -> DecodedImage {
        let start = Trace.now()
        let info = try probe(url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw DecodeError.unreadable(url.lastPathComponent)
        }
        let fullLong = max(info.pixelWidth, info.pixelHeight)
        let maxSize = tier == .full ? fullLong : min(fullLong, max(64, targetLongSide))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxSize,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), options as CFDictionary) else {
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

// MARK: - --mpf

/// Camera-style copies of the JPEGs in `files`: an APP2 MPF index (CIPA DC-007) after APP0/APP1 and a
/// 1620 px "large thumbnail (full-HD class)" appended, the way Sony, Nikon or Fujifilm bodies store them.
private func mpfCopies(of files: [URL], in dir: URL) throws -> [URL] {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var out: [URL] = []
    for url in files where ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (props[kCGImagePropertyPixelWidth] as? Int ?? 0) >= 3000 else { continue }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 1620]
        guard let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { continue }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, "public.jpeg" as CFString, 1, nil) else { continue }
        CGImageDestinationAddImage(destination, preview, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { continue }
        let target = dir.appendingPathComponent("mpf_" + url.lastPathComponent)
        try mpfFile(primary: try Data(contentsOf: url), preview: encoded as Data).write(to: target)
        out.append(target)
    }
    return out
}

private func mpfFile(primary: Data, preview: Data) -> Data {
    let bytes = [UInt8](primary)
    var insert = 2
    while insert + 4 <= bytes.count, bytes[insert] == 0xFF, bytes[insert + 1] == 0xE0 || bytes[insert + 1] == 0xE1 {
        insert += 2 + (Int(bytes[insert + 2]) << 8 | Int(bytes[insert + 3]))
    }
    func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    let entryOffset = 8 + 2 + 3 * 12 + 4
    let payloadLength = 4 + entryOffset + 16 * 2
    let base = insert + 8  // FFE2, length, "MPF\0"
    let primarySize = bytes.count + 4 + payloadLength
    var payload = Array("MPF\0".utf8) + [0x4D, 0x4D, 0x00, 0x2A] + be32(8) + be16(3)
    payload += be16(0xB000) + be16(7) + be32(4) + Array("0100".utf8)
    payload += be16(0xB001) + be16(4) + be32(1) + be32(2)
    payload += be16(0xB002) + be16(7) + be32(32) + be32(entryOffset) + be32(0)
    payload += be32(0x2003_0000) + be32(primarySize) + be32(0) + be32(0)
    payload += be32(0x01_0002) + be32(preview.count) + be32(primarySize - base) + be32(0)
    return Data(Array(bytes[0..<insert]) + [0xFF, 0xE2] + be16(payloadLength + 2) + payload + Array(bytes[insert...])
                + [UInt8](preview))
}

// MARK: - --variants

private typealias SurfaceFn = @convention(c) (CGImageSource, Int, CFDictionary?) -> Unmanaged<IOSurfaceRef>?
private let surfaceSPI: SurfaceFn? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGImageSourceCreateIOSurfaceAtIndex")
    .map { unsafeBitCast($0, to: SurfaceFn.self) }

/// The alternatives measured for progressive JPEG `.screen` and HEIF/AVIF `.preview` (see the routing notes
/// in `ImageIODecoder`): every ImageIO subsample factor through the IOSurface SPI and a CGImage draw, a
/// resampled `…Always` thumbnail, and (progressive) the decoder's libjpeg-turbo `.screen` at a covering and
/// at a half-size scale.
private func runVariants(_ files: [URL], decoder: ImageDecoder, pool: PixelBufferPool, iters: Int, screen: Int) throws {
    func source(_ url: URL) -> CGImageSource? {
        CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    }
    func time(_ body: () -> String) -> String {
        var out = ""
        _ = autoreleasepool { body() }
        var times: [Double] = []
        for _ in 0..<iters {
            autoreleasepool {
                let t0 = Trace.now()
                out = body()
                times.append(Trace.ms(since: t0))
            }
        }
        return String(format: "%7.1f ms %@", median(times), out)
    }
    func surface(_ url: URL, _ factor: Int) -> String {
        var options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if factor > 1 { options[kCGImageSourceSubsampleFactor] = factor }
        guard let surfaceSPI, let src = source(url), let s = surfaceSPI(src, 0, options as CFDictionary)?.takeRetainedValue() else {
            return "nil"
        }
        return "\(IOSurfaceGetWidth(s))x\(IOSurfaceGetHeight(s))"
    }
    func drawn(_ url: URL, _ factor: Int) -> String {
        var options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if factor > 1 { options[kCGImageSourceSubsampleFactor] = factor }
        guard let src = source(url), let image = CGImageSourceCreateImageAtIndex(src, 0, options as CFDictionary),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return "nil" }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return "\(image.width)x\(image.height)"
    }
    func thumbnail(_ url: URL, _ maxPixel: Int) -> String {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                        kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCache: false]
        guard let src = source(url), let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return "nil" }
        return "\(image.width)x\(image.height)"
    }
    func tier(_ url: URL, _ target: Int) -> String {
        guard let image = try? decoder.decode(url, tier: .screen, targetLongSide: target, pool: pool) else { return "error" }
        return "\(image.pixels.width)x\(image.pixels.height)"
    }
    for url in files {
        guard let info = try? decoder.probe(url) else { continue }
        let format = info.exif["format"] ?? ""
        let heif = ["HEIC", "HEIF", "AVIF"].contains(format)
        if format == "PNG" {
            print("\(url.lastPathComponent) (PNG, \(info.pixelWidth)x\(info.pixelHeight))")
            let full = time {
                guard let image = try? decoder.decode(url, tier: .full, targetLongSide: 0, pool: pool) else { return "error" }
                return "\(image.pixels.width)x\(image.pixels.height)"
            }
            print("  .full (own decoder) \(full)   ImageIO iosurface /1 \(time { surface(url, 1) })")
            print("  pixels vs ImageIO: \(comparePNG(url, decoder: decoder, pool: pool))")
            continue
        }
        guard format.hasPrefix("JPEG progressive") || heif else { continue }
        print("\(url.lastPathComponent) (\(format), \(info.pixelWidth)x\(info.pixelHeight))")
        for factor in heif ? [2, 4, 8] : [1, 2, 4, 8] {
            print("  /\(factor)  iosurface \(time { surface(url, factor) })   cgimage+draw \(time { drawn(url, factor) })")
        }
        if heif {
            print("  thumbnail Always 1024 \(time { thumbnail(url, 1024) })")
        } else {
            let long = max(info.pixelWidth, info.pixelHeight)
            print("  libjpeg-turbo .screen covering \(screen) px \(time { tier(url, screen) })")
            print("  libjpeg-turbo .screen at half size \(time { tier(url, (long + 1) / 2) })")
        }
    }
}

/// The decoder's full-resolution PNG against ImageIO's (IOSurface SPI: BGRA 8-bit or 'l64r' RGBA 16-bit, straight
/// alpha): identical sample values, or how many differ.
private func comparePNG(_ url: URL, decoder: ImageDecoder, pool: PixelBufferPool) -> String {
    guard let ours = try? decoder.decode(url, tier: .full, targetLongSide: 0, pool: pool).pixels,
          let surfaceSPI, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let theirs = surfaceSPI(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)?.takeRetainedValue(),
          IOSurfaceGetWidth(theirs) == ours.width, IOSurfaceGetHeight(theirs) == ours.height else { return "not comparable" }
    IOSurfaceLock(theirs, .readOnly, nil)
    defer { IOSurfaceUnlock(theirs, .readOnly, nil) }
    let wide = ours.layout == .rgba16
    guard IOSurfaceGetBytesPerElement(theirs) == (wide ? 8 : 4) else { return "ImageIO layout differs" }
    var differing = 0, worst = 0
    for y in 0..<ours.height {
        let a = ours.baseAddress.advanced(by: y * ours.bytesPerRow)
        let b = IOSurfaceGetBaseAddress(theirs).advanced(by: y * IOSurfaceGetBytesPerRow(theirs))
        for x in 0..<ours.width {
            for c in 0..<4 {
                // Ours: R, G, B, A. ImageIO 8-bit: B, G, R, A; 16-bit: R, G, B, A.
                let other = wide || c == 1 || c == 3 ? c : 2 - c
                let d = wide
                    ? abs(Int(a.load(fromByteOffset: 8 * x + 2 * c, as: UInt16.self))
                          - Int(b.load(fromByteOffset: 8 * x + 2 * other, as: UInt16.self)))
                    : abs(Int(a.load(fromByteOffset: 4 * x + c, as: UInt8.self))
                          - Int(b.load(fromByteOffset: 4 * x + other, as: UInt8.self)))
                if d > 0 { differing += 1; worst = max(worst, d) }
            }
        }
    }
    return differing == 0 ? "identical (\(ours.width)x\(ours.height) \(ours.layout))" : "\(differing) samples differ, max \(worst)"
}
