import CoreGraphics
import Foundation
import ImageIO
import IOSurface
import Metal
import UniformTypeIdentifiers
import XCTest
@testable import PeekabooCore

/// Embedded previews (MPF large thumbnails) and decode concurrency, on JPEGs built in the test and,
/// when `$PEEKABOO_CORPUS` is set, on real photos.
final class DecodePreviewTests: XCTestCase {
    private var dir: URL!
    private var pool: PixelBufferPool!

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        pool = PixelBufferPool(device: device)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("peekaboo-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: Fixtures

    /// Four quadrant colours (memory order: top-left, top-right, bottom-left, bottom-right).
    private func quadrants(_ width: Int, _ height: Int, _ colors: [(UInt8, UInt8, UInt8)]) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = colors[(y < height / 2 ? 0 : 2) + (x < width / 2 ? 0 : 1)]
                let i = (y * width + x) * 4
                bytes[i] = c.0; bytes[i + 1] = c.1; bytes[i + 2] = c.2
            }
        }
        return try image(bytes, width, height)
    }

    /// Busy content (gradients plus hashed noise) so a decode costs what a photo of that size costs.
    private func busy(_ width: Int, _ height: Int, seed: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        var state = UInt32(truncatingIfNeeded: seed &* 2_654_435_761 | 1)
        for y in 0..<height {
            for x in 0..<width {
                state ^= state << 13; state ^= state >> 17; state ^= state << 5
                let i = (y * width + x) * 4
                bytes[i] = UInt8(truncatingIfNeeded: x &+ Int(state & 0x3F))
                bytes[i + 1] = UInt8(truncatingIfNeeded: y &+ Int((state >> 8) & 0x3F))
                bytes[i + 2] = UInt8(truncatingIfNeeded: (x ^ y) &+ seed &* 40)
            }
        }
        return try image(bytes, width, height)
    }

    private func image(_ bytes: [UInt8], _ width: Int, _ height: Int) throws -> CGImage {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                     space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func jpeg(_ image: CGImage, properties: [CFString: Any] = [:]) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        var props = properties
        props[kCGImageDestinationLossyCompressionQuality] = 0.9
        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// A multi-picture JPEG as cameras write it (CIPA DC-007): `primary` with an APP2 "MPF" index inserted
    /// after its APP0/APP1 segments, followed by the secondary JPEGs. `secondaries`: (MP type code, JPEG).
    static func mpfFile(primary: Data, secondaries: [(type: UInt32, jpeg: Data)]) -> Data {
        let bytes = [UInt8](primary)
        var insert = 2
        while insert + 4 <= bytes.count, bytes[insert] == 0xFF, bytes[insert + 1] == 0xE0 || bytes[insert + 1] == 0xE1 {
            insert += 2 + (Int(bytes[insert + 2]) << 8 | Int(bytes[insert + 3]))
        }
        func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        let count = 1 + secondaries.count
        let entryOffset = 8 + 2 + 3 * 12 + 4
        let payloadLength = 4 + entryOffset + 16 * count  // "MPF\0" + header/IFD + entries
        let segmentLength = 4 + payloadLength  // marker + length field + payload
        let base = insert + 4 + 4  // MP header: after FFE2, the length field and "MPF\0"
        let primarySize = bytes.count + segmentLength
        var payload = Array("MPF\0".utf8) + [0x4D, 0x4D, 0x00, 0x2A] + be32(8)
        payload += be16(3)
        payload += be16(0xB000) + be16(7) + be32(4) + Array("0100".utf8)
        payload += be16(0xB001) + be16(4) + be32(1) + be32(count)
        payload += be16(0xB002) + be16(7) + be32(16 * count) + be32(entryOffset)
        payload += be32(0)
        payload += be32(0x2003_0000) + be32(primarySize) + be32(0) + be16(0) + be16(0)
        var next = primarySize
        for secondary in secondaries {
            payload += be32(Int(secondary.type)) + be32(secondary.jpeg.count) + be32(next - base) + be16(0) + be16(0)
            next += secondary.jpeg.count
        }
        var out = Array(bytes[0..<insert]) + [0xFF, 0xE2] + be16(payloadLength + 2) + payload + Array(bytes[insert...])
        for secondary in secondaries { out += [UInt8](secondary.jpeg) }
        return Data(out)
    }

    private func pixel(_ pb: PixelBuffer, _ x: Int, _ y: Int) -> (Int, Int, Int) {
        if case .surface(let surface) = pb.storage { IOSurfaceLock(surface, .readOnly, nil) }
        defer { if case .surface(let surface) = pb.storage { IOSurfaceUnlock(surface, .readOnly, nil) } }
        let p = pb.baseAddress.advanced(by: y * pb.bytesPerRow + x * pb.layout.bytesPerPixel)
        func b(_ i: Int) -> Int { Int(p.load(fromByteOffset: i, as: UInt8.self)) }
        switch pb.layout {
        case .rgba8: return (b(0), b(1), b(2))
        case .bgra8: return (b(2), b(1), b(0))
        case .argb8: return (b(1), b(2), b(3))
        default: return (-1, -1, -1)
        }
    }

    // MARK: MPF

    private let rgbw: [(UInt8, UInt8, UInt8)] = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 255)]
    /// The preview's quadrants differ from the primary's, so the test sees which image was decoded.
    private let wbgr: [(UInt8, UInt8, UInt8)] = [(255, 255, 255), (0, 0, 255), (0, 255, 0), (255, 0, 0)]

    func testMPFLargeThumbnailIsThePreview() throws {
        let primary = try jpeg(try quadrants(2400, 1600, rgbw), properties: [kCGImageDestinationEmbedThumbnail: true])
        let large = try jpeg(try quadrants(1200, 800, wbgr))
        let gainMap = try jpeg(try quadrants(1800, 1200, rgbw))   // type 0: a gain map, never a preview
        let wide = try jpeg(try quadrants(1920, 1080, rgbw))      // 16:9 letterbox: wrong aspect ratio
        let vga = try jpeg(try quadrants(640, 426, wbgr))
        let file = Self.mpfFile(primary: primary, secondaries: [(0x01_0001, vga), (0x01_0002, large), (0, gainMap),
                                                                (0x01_0002, wide)])
        let url = dir.appendingPathComponent("camera.jpg")
        try file.write(to: url)

        let scan = try XCTUnwrap(JPEGScan.scan(url: url))
        XCTAssertTrue(scan.hasMPF)
        XCTAssertEqual(scan.width, 2400)
        XCTAssertEqual(scan.mpfPreviews.map { "\($0.width)x\($0.height)" }, ["640x426", "1200x800", "1920x1080"])
        let largeEntry = try XCTUnwrap(scan.mpfPreviews.first { $0.width == 1200 })
        XCTAssertEqual(largeEntry.length, large.count)
        XCTAssertEqual(Data(file[largeEntry.offset..<largeEntry.offset + 2]), Data([0xFF, 0xD8]))
        XCTAssertEqual(largeEntry.coding, .baseline)

        let decoder = ImageIODecoder()
        let info = try decoder.probe(url)
        XCTAssertEqual(info.pixelWidth, 2400, "ImageIO still sees the primary image")
        XCTAssertFalse(info.hasGainMap)
        let preview = try decoder.decode(url, tier: .preview, targetLongSide: 512, pool: pool)
        XCTAssertEqual(preview.pixels.width, 600, "1200 px MPF preview at /2 covers 512 px")
        XCTAssertEqual(preview.pixels.height, 400)
        XCTAssertEqual(preview.fullWidth, 2400)
        XCTAssertEqual(preview.orientation, .up)
        let p = preview.pixels
        let topLeft = pixel(p, p.width / 4, p.height / 4), bottomRight = pixel(p, p.width * 3 / 4, p.height * 3 / 4)
        XCTAssert(topLeft.0 > 230 && topLeft.1 > 230 && topLeft.2 > 230, "MPF preview decoded (white), got \(topLeft)")
        XCTAssert(bottomRight.0 > 230 && bottomRight.1 < 30 && bottomRight.2 < 30, "got \(bottomRight)")
        if IOSurfaceSPI.isAvailable, case .surface = p.storage {} else if IOSurfaceSPI.isAvailable {
            XCTFail("MPF previews go through the IOSurface (hardware JPEG) path")
        }
        // Larger tiers still come from the primary image.
        let screen = try decoder.decode(url, tier: .screen, targetLongSide: 1200, pool: pool)
        XCTAssertEqual(screen.pixels.width, 1200)
        let s = screen.pixels
        let red = pixel(s, s.width / 4, s.height / 4)
        XCTAssert(red.0 > 230 && red.1 < 30 && red.2 < 30, "primary decoded (red), got \(red)")
    }

    func testMPFPreviewKeepsOrientationAndSkipsMismatchedAspect() throws {
        // Only a 16:9 preview of a 3:2 image: ignored, the EXIF thumbnail / subsample path takes over.
        let primary = try jpeg(try quadrants(1500, 1000, rgbw), properties: [kCGImagePropertyOrientation: 6])
        let wide = try jpeg(try quadrants(1280, 720, wbgr))
        let url = dir.appendingPathComponent("wide.jpg")
        try Self.mpfFile(primary: primary, secondaries: [(0x01_0002, wide)]).write(to: url)
        let decoder = ImageIODecoder()
        let preview = try decoder.decode(url, tier: .preview, targetLongSide: 256, pool: pool)
        let red = pixel(preview.pixels, preview.pixels.width / 4, preview.pixels.height / 4)
        XCTAssertNotEqual(preview.pixels.width, 640, "the 16:9 preview is not used")
        XCTAssert(red.0 > 200 || preview.orientation == .up, "primary pixels, got \(red)")

        let matching = try jpeg(try quadrants(750, 500, wbgr))
        let oriented = dir.appendingPathComponent("oriented.jpg")
        try Self.mpfFile(primary: primary, secondaries: [(0x01_0001, matching)]).write(to: oriented)
        let image = try decoder.decode(oriented, tier: .preview, targetLongSide: 256, pool: pool)
        XCTAssertEqual(image.orientation, .right, "the primary's EXIF orientation applies to its MPF preview")
        XCTAssertEqual(image.pixels.width, 375, "stored (un-rotated) preview pixels at /2")
        XCTAssertEqual(image.fullWidth, 1000)
        XCTAssertEqual(image.fullHeight, 1500)
    }

    func testMalformedMPFIsIgnored() throws {
        let primary = try jpeg(try quadrants(800, 600, rgbw))
        let preview = try jpeg(try quadrants(400, 300, wbgr))
        var file = [UInt8](Self.mpfFile(primary: primary, secondaries: [(0x01_0001, preview)]))
        file.removeLast(preview.count / 2)  // truncated secondary image
        let url = dir.appendingPathComponent("truncated.jpg")
        try Data(file).write(to: url)
        let scan = try XCTUnwrap(JPEGScan.scan(url: url))
        XCTAssertTrue(scan.hasMPF)
        let image = try ImageIODecoder().decode(url, tier: .preview, targetLongSide: 100, pool: pool)
        XCTAssertGreaterThan(image.pixels.width, 0)
        // Entry offsets beyond the data, absurd counts: no crash, no previews.
        XCTAssertTrue(JPEGScan.mpfLargeThumbnails(Array("MPF\0MM\0*".utf8) + [0, 0, 0, 8, 0xFF, 0xFF], base: 0).isEmpty)
        XCTAssertTrue(JPEGScan.mpfLargeThumbnails(Array("MPF\0".utf8), base: 0).isEmpty)
    }

    // MARK: Corpus

    private func corpus() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["PEEKABOO_CORPUS"], !path.isEmpty else {
            throw XCTSkip("PEEKABOO_CORPUS is not set")
        }
        return URL(fileURLWithPath: path)
    }

    /// A real camera JPEG with a full-HD-class MPF preview (built from a corpus photo the way cameras store it)
    /// previews from that image at full sharpness, through the hardware path, in a few milliseconds.
    func testCorpusCameraJPEGPreviewsFromMPF() throws {
        let photo = try corpus().appendingPathComponent("jpeg/jpeg_12mp_4000x3000.jpg")
        guard FileManager.default.fileExists(atPath: photo.path) else { throw XCTSkip("no 12 MP JPEG in the corpus") }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(photo as CFURL, nil))
        let thumbOptions: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                             kCGImageSourceThumbnailMaxPixelSize: 1620]
        let previewImage = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary))
        XCTAssertEqual(previewImage.width, 1620)
        let url = dir.appendingPathComponent("camera12mp.jpg")
        try Self.mpfFile(primary: try Data(contentsOf: photo), secondaries: [(0x01_0002, try jpeg(previewImage))]).write(to: url)

        let decoder = ImageIODecoder()
        let plain = try decoder.decode(photo, tier: .preview, targetLongSide: 512, pool: pool)
        XCTAssertEqual(plain.pixels.width, 320, "without MPF: the 320 px EXIF thumbnail")
        _ = try decoder.decode(url, tier: .preview, targetLongSide: 512, pool: pool)
        let start = Trace.now()
        let preview = try decoder.decode(url, tier: .preview, targetLongSide: 512, pool: pool)
        let ms = Trace.ms(since: start)
        XCTAssertEqual(preview.pixels.width, 810, "1620 px MPF preview at /2")
        XCTAssertEqual(preview.pixels.height, 608)
        XCTAssertLessThan(ms, 15, "MPF preview decode: \(ms) ms")
        // Same picture as the primary: compare with the primary's own /4 decode (1000x750) at a few points.
        let screen = try decoder.decode(photo, tier: .screen, targetLongSide: 1000, pool: pool)
        var diff = 0, samples = 0
        for fy in stride(from: 0.1, to: 0.95, by: 0.2) {
            for fx in stride(from: 0.1, to: 0.95, by: 0.2) {
                let a = pixel(preview.pixels, Int(fx * Double(preview.pixels.width)), Int(fy * Double(preview.pixels.height)))
                let b = pixel(screen.pixels, Int(fx * Double(screen.pixels.width)), Int(fy * Double(screen.pixels.height)))
                diff += abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)
                samples += 3
            }
        }
        XCTAssertLessThan(Double(diff) / Double(samples), 40, "preview shows the same picture")
    }

    /// Gain maps travel as MPF secondary images too (type 0): they must never become the preview.
    func testCorpusGainMapIsNotAPreview() throws {
        let url = try corpus().appendingPathComponent("hdr/jpeg_apple_gainmap_new_small.jpg")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("no gain-map sample") }
        let scan = try XCTUnwrap(JPEGScan.scan(url: url))
        XCTAssertTrue(scan.hasMPF)
        XCTAssertTrue(scan.mpfPreviews.isEmpty, "\(scan.mpfPreviews)")
        let preview = try ImageIODecoder().decode(url, tier: .preview, targetLongSide: 512, pool: pool)
        XCTAssertEqual(preview.pixels.width, 384, "the primary image, not its gain map")
    }

    // MARK: Concurrency

    /// No decode path may use `kCGImageSourceShouldCacheImmediately` (ImageIO serialises those decodes
    /// process-wide) or share a `CGImageSource` between threads: 8 concurrent `.full` decodes of 8 different
    /// baseline JPEGs must overlap. They all need the two hardware JPEG engines, so the floor is ~4 rounds
    /// minus the CPU work that overlaps: measured 3.1–3.6x one decode (1200–6000 px wide; M4 Pro), while the
    /// serialising `ShouldCacheImmediately` path takes ~8x. Asserted: < 4.5x one decode, and faster than
    /// the same 8 decodes through the serialising path.
    func testConcurrentBaselineDecodesDoNotSerialise() throws {
        var urls: [URL] = []
        for i in 0..<8 {
            let url = dir.appendingPathComponent("busy\(i).jpg")
            try jpeg(try busy(2400, 1600, seed: i)).write(to: url)
            urls.append(url)
        }
        let decoder = ImageIODecoder()
        for url in urls { _ = try decoder.probe(url) }
        func decode(_ url: URL) throws {
            try autoreleasepool { _ = try decoder.decode(url, tier: .full, targetLongSide: 0, pool: pool) }
        }
        /// The serialising reference: one `CGImageSource` per call, decoded at creation.
        func cacheImmediately(_ url: URL) throws {
            try autoreleasepool {
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
                let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
                XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, options))
            }
        }
        func concurrentWall(_ body: @escaping (URL) throws -> Void) -> Double {
            var walls: [Double] = []
            for _ in 0..<3 {
                let lock = NSLock()
                var failures = 0
                let t0 = Trace.now()
                DispatchQueue.concurrentPerform(iterations: urls.count) { i in
                    do { try body(urls[i]) } catch { lock.lock(); failures += 1; lock.unlock() }
                }
                walls.append(Trace.ms(since: t0))
                XCTAssertEqual(failures, 0)
            }
            return walls.min() ?? 0
        }
        try decode(urls[0])
        var singles: [Double] = []
        for url in urls.prefix(5) {
            let t0 = Trace.now()
            try decode(url)
            singles.append(Trace.ms(since: t0))
        }
        let single = singles.sorted()[singles.count / 2]
        let wall = concurrentWall(decode)
        let serialised = concurrentWall(cacheImmediately)
        print(String(format: "8 concurrent baseline decodes: %.1f ms wall vs %.1f ms single (%.2fx); ShouldCacheImmediately %.1f ms",
                     wall, single, wall / single, serialised))
        XCTAssertLessThan(wall, 4.5 * single, "8 concurrent decodes \(wall) ms vs single \(single) ms")
        XCTAssertLessThan(wall, serialised, "the decoder overlaps decodes that ShouldCacheImmediately serialises")
    }
}
