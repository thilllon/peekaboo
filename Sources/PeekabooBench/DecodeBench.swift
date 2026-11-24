import CoreGraphics
import Foundation
import ImageIO
import Metal
import PeekabooCore

/// `peekaboo-bench decode [--corpus DIR] [--iters N] [--screen PX] [--preview PX] [--threads N] [--skeleton]`
///
/// Per corpus file: median wall time of probe / `.preview` / `.screen` / `.full`, the output size and layout,
/// then the parallel throughput of `.screen` decodes over `nav/` (or the whole corpus) with N threads
/// (default 6, the scheduler's lane count) and with 1. `--skeleton` measures the walking-skeleton decoder
/// (CPU thumbnail resampling + BGRA conversion) for before/after comparisons.
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
            let t0 = Trace.now()
            _ = try? decoder.probe(url)
            probeTimes.append(Trace.ms(since: t0))
        }
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
    case .rgba16f: info = p.layout.cgBitmapInfo
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
