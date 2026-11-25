import CPeekabooDecode
import CoreGraphics
import ImageIO
import Metal
import XCTest
@testable import PeekabooCore

/// The early rendition of progressive JPEGs: where the first-pass scans end, the rendition (geometry, colour space,
/// quality against the exact decode), its delivery, and that asking for it leaves the exact decode unchanged.
final class EarlyRenditionTests: XCTestCase {
    private var dir: URL!
    private var pool: PixelBufferPool!
    private let decoder = ImageIODecoder()

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        pool = PixelBufferPool(device: device)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("peekaboo-early-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    /// Gradients plus noise: every AC band carries data, so the refinement scans matter.
    private func textured(_ width: Int, _ height: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        var state: UInt64 = 9
        for y in 0..<height {
            for x in 0..<width {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let noise = Int(state >> 59)
                let i = (y * width + x) * 4
                bytes[i] = UInt8((x * 255 / width + noise) & 255)
                bytes[i + 1] = UInt8((y * 255 / height + 3 * noise) & 255)
                bytes[i + 2] = UInt8(((x ^ y) & 0x3F) * 4)
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                     space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    /// ImageIO's progressive JPEG uses libjpeg's standard script: DC, first passes with point transforms 1–2, then
    /// successive-approximation refinements (10 scans).
    private func jpeg(_ name: String, progressive: Bool, width: Int = 1600, height: Int = 1200) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.92]
        if progressive { properties[kCGImagePropertyJFIFDictionary] = [kCGImagePropertyJFIFIsProgressive: true] }
        CGImageDestinationAddImage(destination, try textured(width, height), properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw XCTSkip("no JPEG encoder") }
        return url
    }

    private func firstPassEnd(_ data: Data) -> Int {
        data.withUnsafeBytes { pb_jpeg_first_pass_end($0.baseAddress!.assumingMemoryBound(to: UInt8.self), $0.count) }
    }

    private func psnr(_ a: PixelBuffer, _ b: PixelBuffer) -> Double {
        var squared = 0.0
        for y in 0..<a.height {
            for i in 0..<(a.width * 4) where i % 4 != 3 {
                let d = Double(a.baseAddress.load(fromByteOffset: y * a.bytesPerRow + i, as: UInt8.self))
                    - Double(b.baseAddress.load(fromByteOffset: y * b.bytesPerRow + i, as: UInt8.self))
                squared += d * d
            }
        }
        let mse = squared / Double(a.width * a.height * 3)
        return mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
    }

    private func identical(_ a: PixelBuffer, _ b: PixelBuffer) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        return (0..<a.height).allSatisfy { y in
            memcmp(a.baseAddress + y * a.bytesPerRow, b.baseAddress + y * b.bytesPerRow, a.width * 4) == 0
        }
    }

    // MARK: First-pass end

    func testFirstPassEndIsTheLastFirstPassScan() throws {
        let data = try Data(contentsOf: jpeg("p.jpg", progressive: true))
        let end = firstPassEnd(data)
        XCTAssertGreaterThan(end, 0)
        XCTAssertLessThan(end, data.count / 2 + data.count / 4, "the refinement scans follow")
        XCTAssertEqual(data[end], 0xFF, "the cut falls on a marker")
        // Five scans before the cut: DC, Y 1–5, Cr, Cb, Y 6–63 (all first passes of the standard script).
        var scans = 0, i = 2
        while i < end {
            if data[i] == 0xFF, data[i + 1] == 0xDA { scans += 1 }
            i += 1
        }
        XCTAssertEqual(scans, 5)

        XCTAssertEqual(firstPassEnd(try Data(contentsOf: jpeg("b.jpg", progressive: false))), 0, "baseline")
        XCTAssertEqual(firstPassEnd(data.prefix(data.count / 5)), 0, "the data ends before every coefficient arrived")
        XCTAssertEqual(firstPassEnd(Data([0xFF, 0xD8, 0xFF])), 0)
        XCTAssertEqual(firstPassEnd(Data(repeating: 0xFF, count: 64)), 0)
    }

    // MARK: Rendition

    func testFirstPassRenditionHasTheExactGeometryAndIsClose() throws {
        let data = try Data(contentsOf: jpeg("p.jpg", progressive: true))
        for (target, width) in [(1600, 1600), (800, 800), (300, 400)] {
            let exact = try data.withUnsafeBytes { try TurboJPEG.decode($0, targetLongSide: target, pool: pool) }
            let early = try XCTUnwrap(data.withUnsafeBytes { try TurboJPEG.decodeFirstPasses($0, targetLongSide: target, pool: pool) })
            XCTAssertEqual(early.width, width)
            XCTAssertEqual(early.width, exact.width)
            XCTAssertEqual(early.height, exact.height)
            XCTAssertEqual(early.layout, .bgra8)
            XCTAssertEqual(early.alpha, .opaque)
            XCTAssertEqual(early.colorSpace.name, exact.colorSpace.name)
            let quality = psnr(early, exact)
            XCTAssertGreaterThan(quality, 28, "target \(target): every coefficient is there, at reduced precision")
            XCTAssertLessThan(quality, .infinity, "the refinement scans were skipped")
        }
        let baseline = try Data(contentsOf: jpeg("b.jpg", progressive: false))
        XCTAssertNil(try baseline.withUnsafeBytes { try TurboJPEG.decodeFirstPasses($0, targetLongSide: 800, pool: pool) })
    }

    // MARK: Delivery

    /// Collects what an `EarlyRendition` hands over.
    private final class Collector: @unchecked Sendable {
        let delivered = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var images: [DecodedImage] = []
        var wanted = true

        var sink: PartialSink {
            PartialSink(wanted: { [unowned self] in self.lock.lock(); defer { self.lock.unlock() }; return self.wanted },
                        deliver: { [unowned self] image in
                            self.lock.lock(); self.images.append(image); self.lock.unlock()
                            self.delivered.signal()
                        })
        }

        var received: [DecodedImage] { lock.lock(); defer { lock.unlock() }; return images }
    }

    func testEarlyRenditionIsDeliveredAsAnApproximateTier() throws {
        let url = try jpeg("p.jpg", progressive: true)
        let data = try Data(contentsOf: url)
        let info = try decoder.probe(url)
        let collector = Collector()
        EarlyRendition(sink: collector.sink, url: url, tier: .screen, start: Trace.now())
            .start(data, target: 800, info: info, pool: pool)
        XCTAssertEqual(collector.delivered.wait(timeout: .now() + 10), .success)
        let image = try XCTUnwrap(collector.received.first)
        XCTAssertTrue(image.isApproximate)
        XCTAssertEqual(image.tier, .screen)
        XCTAssertEqual(image.fullWidth, 1600)
        XCTAssertEqual(image.fullHeight, 1200)
        XCTAssertEqual(image.orientation, info.orientation)
        XCTAssertEqual(image.pixels.width, 800)

        let unwanted = Collector()
        unwanted.wanted = false
        EarlyRendition(sink: unwanted.sink, url: url, tier: .screen, start: Trace.now()).start(data, target: 800, info: info, pool: pool)
        let finished = Collector()
        let late = EarlyRendition(sink: finished.sink, url: url, tier: .screen, start: Trace.now())
        late.finish()
        late.start(data, target: 800, info: info, pool: pool)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(unwanted.received.isEmpty, "not when the image left the screen")
        XCTAssertTrue(finished.received.isEmpty, "not once the exact tier is done")
    }

    /// Asking for an early rendition never changes the exact decode, and only progressive JPEGs produce one.
    func testDecodeWithASinkReturnsTheExactTier() throws {
        let progressive = try jpeg("p.jpg", progressive: true)
        let collector = Collector()
        let plain = try decoder.decode(progressive, tier: .screen, targetLongSide: 1600, pool: pool)
        let withSink = try decoder.decode(progressive, tier: .screen, targetLongSide: 1600, pool: pool, partial: collector.sink)
        XCTAssertFalse(withSink.isApproximate)
        XCTAssertTrue(identical(plain.pixels, withSink.pixels), "the exact decode is unchanged")
        // The rendition races the exact decode; when it won, it is the approximate version of the same tier.
        for image in collector.received {
            XCTAssertTrue(image.isApproximate)
            XCTAssertEqual(image.pixels.width, withSink.pixels.width)
        }

        let baseline = try jpeg("b.jpg", progressive: false)
        let none = Collector()
        _ = try decoder.decode(baseline, tier: .screen, targetLongSide: 1600, pool: pool, partial: none.sink)
        _ = try decoder.decode(progressive, tier: .preview, targetLongSide: 200, pool: pool, partial: none.sink)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(none.received.isEmpty, "baseline JPEGs and previews have no early rendition")
    }

    // MARK: Robustness

    /// Corrupted and truncated variants of a progressive file: the scan walk and the truncated decode always return.
    func testMutatedProgressiveFilesNeverCrash() throws {
        let original = [UInt8](try Data(contentsOf: jpeg("p.jpg", progressive: true, width: 200, height: 160)))
        var state: UInt64 = 5
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(state >> 33) % max(bound, 1)
        }
        var rendered = 0
        for _ in 0..<400 {
            var bytes = original
            for _ in 0..<(1 + next(6)) { bytes[next(bytes.count)] = UInt8(next(256)) }
            if next(3) == 0 { bytes = Array(bytes.prefix(next(bytes.count))) }
            let image = bytes.withUnsafeBytes { raw -> PixelBuffer? in
                _ = pb_jpeg_first_pass_end(raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count)
                return try? TurboJPEG.decodeFirstPasses(raw, targetLongSide: 100, pool: pool)
            }
            if image != nil { rendered += 1 }
        }
        XCTAssertGreaterThan(rendered, 0)
    }
}
