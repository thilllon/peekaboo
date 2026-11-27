import CoreGraphics
import Foundation
import ImageIO
import Metal
import PeekabooCore
import UniformTypeIdentifiers

/// `peekaboo-bench thumbs [file|folder …] [--size PX] [--iters N]`
///
/// The image list's thumbnails: `Thumbnail.make` for each file at the list's size (default 96 px, twice its row height),
/// on a utility-QoS thread as the app makes them. Per file: the first call (the file and ImageIO cold), the median of the
/// next N (default 5), where the pixels came from (the embedded preview, a CR3's container rendition, the image itself)
/// and the size; then the median of N made from the viewer's `.preview` tier of the file (decoded first as the pipeline
/// does, at 512 px, not timed), which the list uses when the pipeline holds one. Last, the wall time to fill one screen
/// of the list, 20 rows of a folder on the app's two utility lanes, from the files and from their previews. Without
/// arguments: every image of `$PEEKABOO_CORPUS` (default ~/Library/Caches/peekaboo-corpus) but `nav/`, which is the
/// screenful, plus two synthetic 24 MP JPEGs of noise, with and without an EXIF thumbnail.
func runThumbsBench(_ args: ArraySlice<String>) throws {
    var size = 96
    var iterations = 5
    var paths: [String] = []
    var it = args.makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--size": size = Int(it.next() ?? "") ?? size
        case "--iters": iterations = Int(it.next() ?? "") ?? iterations
        default: paths.append((arg as NSString).expandingTildeInPath)
        }
    }
    let corpus = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PEEKABOO_CORPUS"]
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/peekaboo-corpus").path)
    var temporary: URL?
    defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
    var files: [URL] = []
    var screenful: URL?
    if paths.isEmpty {
        for folder in ["jpeg", "formats", "raw", "hdr", "anim"] {
            files += imageFiles(in: corpus.appendingPathComponent(folder))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("peekaboo-thumbs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporary = directory
        files += [false, true].compactMap { syntheticJPEG(in: directory, embedThumbnail: $0) }
        screenful = corpus.appendingPathComponent("nav")
    } else {
        for path in paths {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                files += imageFiles(in: URL(fileURLWithPath: path))
                screenful = screenful ?? URL(fileURLWithPath: path)
            } else {
                files.append(URL(fileURLWithPath: path))
            }
        }
    }
    guard !files.isEmpty else { throw BenchError.usage("usage: peekaboo-bench thumbs [file|folder …] [--size PX] [--iters N]") }
    print("thumbs bench: \(files.count) files, \(size) px, utility QoS, first call and median of \(iterations)")
    let pixels = size
    let pool = MTLCreateSystemDefaultDevice().map { PixelBufferPool(device: $0) }
    let decoder = ImageIODecoder()
    /// The viewer's `.preview` tier of `url`, as its pipeline decodes it.
    func preview(_ url: URL) -> DecodedImage? {
        guard let pool else { return nil }
        return try? decoder.decode(url, tier: .preview, targetLongSide: PipelineConfig().previewLongSide, pool: pool)
    }
    var bySource: [String: [Double]] = [:]
    var fromPreviews: [Double] = []
    for url in files {
        let (first, firstMs) = onUtilityThread { Thumbnail.make(url, maxPixelSize: pixels) }
        var times: [Double] = []
        for _ in 0..<iterations { times.append(onUtilityThread { Thumbnail.make(url, maxPixelSize: pixels) }.1) }
        let source = first?.source.rawValue ?? "none"
        let warm = times.sorted()[times.count / 2]
        bySource[source, default: []].append(warm)
        let shape = first.map { "\($0.image.width)x\($0.image.height)" } ?? "-"
        var line = url.lastPathComponent.padding(toLength: 46, withPad: " ", startingAt: 0)
            + source.padding(toLength: 10, withPad: " ", startingAt: 0) + shape.padding(toLength: 8, withPad: " ", startingAt: 0)
            + String(format: "first %8.2f ms   median %8.2f ms", firstMs, warm)
        if let decoded = preview(url) {
            var previewTimes: [Double] = []
            for _ in 0..<iterations {
                previewTimes.append(onUtilityThread { Thumbnail.make(from: decoded, maxPixelSize: pixels) }.1)
            }
            let median = previewTimes.sorted()[previewTimes.count / 2]
            fromPreviews.append(median)
            line += String(format: "   from the viewer's %dx%d preview %6.3f ms", decoded.pixels.width, decoded.pixels.height, median)
        }
        print(line)
    }
    for (source, times) in bySource.sorted(by: { $0.key < $1.key }) {
        let sorted = times.sorted()
        print(String(format: "%@: %d files, median of the medians %.2f ms (%.2f–%.2f)", source, times.count,
                     sorted[sorted.count / 2], sorted.first ?? 0, sorted.last ?? 0))
    }
    if !fromPreviews.isEmpty {
        let sorted = fromPreviews.sorted()
        print(String(format: "from the viewer's preview: %d files, median of the medians %.3f ms (%.3f–%.3f)", sorted.count,
                     sorted[sorted.count / 2], sorted.first ?? 0, sorted.last ?? 0))
    }
    if let screenful {
        let rows = Array(imageFiles(in: screenful).prefix(20))
        guard !rows.isEmpty else { return }
        // As the list does: a job per row on a utility queue, two at a time.
        func fill(_ jobs: [@Sendable () -> Void]) -> Double {
            let queue = OperationQueue()
            queue.qualityOfService = .utility
            queue.maxConcurrentOperationCount = 2
            let started = Trace.now()
            for job in jobs { queue.addOperation(job) }
            queue.waitUntilAllOperationsAreFinished()
            return Trace.ms(since: started)
        }
        let fromFiles = fill(rows.map { url in { _ = Thumbnail.make(url, maxPixelSize: pixels) } })
        let previews = rows.compactMap(preview)
        let fromPreviewTiers = fill(previews.map { decoded in { _ = Thumbnail.make(from: decoded, maxPixelSize: pixels) } })
        print(String(format: "a screenful: %d rows of %@ in %.1f ms from the files, %.1f ms from the viewer's previews "
                     + "(two utility lanes)", rows.count, screenful.lastPathComponent, fromFiles, fromPreviewTiers))
    }
}

private enum BenchError: Error, CustomStringConvertible {
    case usage(String)
    var description: String { if case .usage(let text) = self { return text }; return "" }
}

/// Images of `folder` (not its subfolders), in name order.
private func imageFiles(in folder: URL) -> [URL] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return names.filter { !$0.hasPrefix(".") && !$0.hasSuffix(".md") }.sorted().map { folder.appendingPathComponent($0) }
}

/// Run `body` on a utility-QoS thread, as the list makes thumbnails, and time it there.
private func onUtilityThread<T>(_ body: @escaping @Sendable () -> T) -> (T, Double) {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: (T, Double)?
    DispatchQueue.global(qos: .utility).async {
        let started = Trace.now()
        let value = body()
        result = (value, Trace.ms(since: started))
        done.signal()
    }
    done.wait()
    return result!
}

/// A 6000×4000 JPEG of noise (photo-like entropy: the decode is not trivial), with or without an EXIF thumbnail.
private func syntheticJPEG(in directory: URL, embedThumbnail: Bool) -> URL? {
    let width = 6000, height = 4000
    var generator = SystemRandomNumberGenerator()
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    // Smooth gradients with noise: about what a camera JPEG at quality 0.9 holds.
    for y in 0..<height {
        for x in 0..<width {
            let p = (y * width + x) * 4
            let noise = UInt8(truncatingIfNeeded: generator.next() & 31)
            bytes[p] = UInt8(truncatingIfNeeded: x * 255 / width) &+ noise
            bytes[p + 1] = UInt8(truncatingIfNeeded: y * 255 / height) &+ noise
            bytes[p + 2] = 128 &+ noise
            bytes[p + 3] = 255
        }
    }
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                              space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { return nil }
    let url = directory.appendingPathComponent("synthetic_24mp\(embedThumbnail ? "_exif_thumbnail" : "").jpg")
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else { return nil }
    var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
    if embedThumbnail { properties[kCGImageDestinationEmbedThumbnail] = true }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    return CGImageDestinationFinalize(destination) ? url : nil
}
