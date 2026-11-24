import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PeekabooCore

/// Reads the file and "decodes" it into a buffer whose first 8 bytes hold the number of bytes read, like a decoder
/// that renders a truncated file as far as it goes. An empty file fails, like ImageIO on a file not written yet.
final class FileContentDecoder: ImageDecoder, @unchecked Sendable {
    let delayMs: Double

    init(delayMs: Double = 2) { self.delayMs = delayMs }

    func probe(_ url: URL) throws -> ImageInfo {
        ImageInfo(pixelWidth: 4000, pixelHeight: 3000, orientation: .up, typeIdentifier: "public.jpeg", hasAlpha: false,
                  hasGainMap: false, frameCount: 1, colorProfileName: nil, exif: [:])
    }

    func decode(_ url: URL, tier: Tier, targetLongSide: Int, pool: PixelBufferPool) throws -> DecodedImage {
        let data = try Data(contentsOf: url)
        usleep(useconds_t(delayMs * 1000))
        guard !data.isEmpty else { throw DecodeError.unreadable(url.lastPathComponent) }
        guard let pixels = pool.make(width: 64, height: 48, layout: .bgra8, alpha: .opaque,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { throw DecodeError.outOfMemory }
        pixels.baseAddress.storeBytes(of: Int64(data.count), as: Int64.self)
        return DecodedImage(pixels: pixels, tier: tier, fullWidth: 4000, fullHeight: 3000, orientation: .up, isHDR: false,
                            decodeNanos: 0)
    }

    /// Bytes of the file the cached tier was decoded from.
    static func decodedBytes(_ image: DecodedImage?) -> Int64? { image?.pixels.baseAddress.load(as: Int64.self) }
}

/// The cache follows the file on disk, not the listing: a file being copied in, or rewritten in place, raises no
/// event on its directory once it exists.
final class PipelineFileChangeTests: PipelineTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("peekaboo-change-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    private func write(_ name: String, bytes: Int, age: TimeInterval? = nil) throws {
        try Data(repeating: 0x5A, count: bytes).write(to: url(name))
        if let age { try setAge(name, age) }
    }

    private func append(_ name: String, bytes: Int) throws {
        let handle = try FileHandle(forWritingTo: url(name))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0xA5, count: bytes))
        try handle.close()
    }

    private func setAge(_ name: String, _ age: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url(name).path)
    }

    private func decodedBytes(_ pipeline: ImagePipeline, _ file: ImageFile) -> Int64? {
        FileContentDecoder.decodedBytes(pipeline.best(for: file))
    }

    /// A copy in progress is listed (and prefetched) at its partial size. When the copy finishes, the file is decoded
    /// again and the listing entry catches up, without any directory event or rescan.
    func testPartialFileIsDecodedAgainWhenTheCopyCompletes() throws {
        try write("a.jpg", bytes: 1000, age: 3600)
        try write("b.jpg", bytes: 400)
        try write("c.jpg", bytes: 1000, age: 3600)
        let files = try FolderScanner.scan(directory)
        let pipeline = makePipeline(FileContentDecoder())
        pipeline.setFiles(files, index: 0)
        XCTAssertTrue(spin { self.decodedBytes(pipeline, files[1]) == 400 }, "the partial file is prefetched")
        try append("b.jpg", bytes: 600)
        XCTAssertTrue(spin(timeout: 5) { self.decodedBytes(pipeline, files[1]) == 1000 },
                      "still showing the partial decode: \(String(describing: decodedBytes(pipeline, files[1]))) bytes")
        XCTAssertEqual(pipeline.files[1].byteSize, 1000, "the listing entry follows the file")
        XCTAssertGreaterThan(pipeline.stats.changedOnDisk, 0)
        XCTAssertEqual(decodedBytes(pipeline, files[0]), 1000)
    }

    /// A decode that overlaps a write matches no version of the file: it is not cached, and the file is decoded again
    /// once nothing has been written for a while.
    func testDecodeRacingAWriteIsRepeatedOnceTheFileIsQuiet() throws {
        try write("a.jpg", bytes: 100)
        let files = try FolderScanner.scan(directory)
        // No speculative full decode: it would read the file again and hide a stale screen tier.
        let pipeline = makePipeline(FileContentDecoder(delayMs: 300)) { $0.tuning.fullMaxCostMs = 0 }
        pipeline.setFiles(files, index: 0)
        spin(for: 0.1)
        try append("a.jpg", bytes: 100)  // during the decode
        XCTAssertTrue(spin(timeout: 5) { self.decodedBytes(pipeline, files[0]) == 200 },
                      "cached \(String(describing: decodedBytes(pipeline, files[0]))) bytes")
    }

    /// An empty file (just created by a copy) fails to decode. That is not reported, and once the file is written it
    /// is decoded.
    func testFailureWhileTheFileIsWrittenIsRetried() throws {
        try write("a.jpg", bytes: 1000, age: 3600)
        try write("b.jpg", bytes: 0)
        let files = try FolderScanner.scan(directory)
        let pipeline = makePipeline(FileContentDecoder())
        var failed: [String] = []
        pipeline.onFailed = { file, _ in failed.append(file.name) }
        pipeline.setFiles(files, index: 1)
        spin(for: 0.2)
        try append("b.jpg", bytes: 800)
        XCTAssertTrue(spin(timeout: 5) { self.decodedBytes(pipeline, files[1]) == 800 }, "never retried")
        XCTAssertEqual(failed, [], "reported as broken while it was being written")
    }

    /// A file that stays broken once written is reported, after the settle time.
    func testFileThatStaysBrokenIsReported() throws {
        try write("a.jpg", bytes: 0)
        let files = try FolderScanner.scan(directory)
        let pipeline = makePipeline(FileContentDecoder())
        var failed: [String] = []
        pipeline.onFailed = { file, _ in failed.append(file.name) }
        pipeline.setFiles(files, index: 0)
        XCTAssertTrue(spin(timeout: 5) { !failed.isEmpty })
        XCTAssertEqual(failed.first, "a.jpg")
        spin(for: 0.6)
        XCTAssertEqual(pipeline.pendingRechecks, 0, "a settled file is not rechecked forever")
    }

    /// An editor that saves over the file in place (keeping an old modification time here) changes it without a
    /// directory event: coming back to it decodes the new content.
    func testInPlaceEditIsNoticedOnArrival() throws {
        try write("a.jpg", bytes: 1000, age: 3600)
        try write("b.jpg", bytes: 1000, age: 3600)
        let files = try FolderScanner.scan(directory)
        let pipeline = makePipeline(FileContentDecoder()) { $0.tuning.fullMaxCostMs = 0 }  // see above
        pipeline.setFiles(files, index: 0)
        XCTAssertTrue(spin { self.decodedBytes(pipeline, files[0]) == 1000 && self.has(pipeline, files[1], .screen) })
        spin(for: 0.1)
        pipeline.navigate(to: 1, isRepeat: false)
        try write("a.jpg", bytes: 2000, age: 3500)
        spin(for: 0.1)
        pipeline.navigate(to: 0, isRepeat: false)
        XCTAssertTrue(spin(timeout: 3) { self.decodedBytes(pipeline, files[0]) == 2000 },
                      "still the old content: \(String(describing: decodedBytes(pipeline, files[0]))) bytes")
    }

    /// Files whose modification time is far ahead of the clock (a camera with a wrong clock) are not rechecked.
    func testFutureModificationTimeCountsAsSettled() throws {
        try write("a.jpg", bytes: 1000, age: -86_400)
        let files = try FolderScanner.scan(directory)
        let pipeline = makePipeline(FileContentDecoder())
        pipeline.setFiles(files, index: 0)
        XCTAssertTrue(spin { self.has(pipeline, files[0], .screen) })
        spin(for: 0.1)
        XCTAssertEqual(pipeline.pendingRechecks, 0)
    }

    // MARK: Real decoder

    /// The finding's case end to end: ImageIO decodes a JPEG cut at 40 % as complete, the missing rows gray. Once the
    /// rest is written, the cached tier shows the real bottom rows (solid red here).
    func testTruncatedJPEGIsReplacedByTheCompleteFile() throws {
        let jpeg = try Self.jpegWithRedBottom(width: 1600, height: 1200)
        let target = url("b.jpg")
        try jpeg.prefix(jpeg.count * 2 / 5).write(to: target)
        let files = try FolderScanner.scan(directory)
        var config = PipelineConfig(screenLongSide: 1600, previewLongSide: 256, memoryBudget: 1 << 30)
        config.readAhead = false
        config.monitorsMemoryPressure = false
        config.sweepLanes = 0
        config.quickLookSweep = false
        let pipeline = ImagePipeline(decoder: ImageIODecoder(), pool: PixelBufferPool(device: device), config: config)
        pipeline.setFiles(files, index: 0)
        XCTAssertTrue(spin(timeout: 5) { self.has(pipeline, files[0], .screen) })
        XCTAssertFalse(Self.bottomIsRed(pipeline.best(for: files[0])), "the truncated file has no red rows")
        let handle = try FileHandle(forWritingTo: target)
        try handle.seekToEnd()
        try handle.write(contentsOf: jpeg.dropFirst(jpeg.count * 2 / 5))
        try handle.close()
        XCTAssertTrue(spin(timeout: 5) { Self.bottomIsRed(pipeline.best(for: files[0])) },
                      "the partial decode stays cached")
        XCTAssertEqual(pipeline.files[0].byteSize, Int64(jpeg.count))
    }

    private static func jpegWithRedBottom(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for row in stride(from: 0, to: height, by: 16) {
            context.setFillColor(red: 0.1, green: CGFloat(row) / CGFloat(height), blue: 0.8, alpha: 1)
            context.fill(CGRect(x: 0, y: row, width: width, height: 16))
        }
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: 64))  // CG's origin is the bottom-left corner
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
                                   [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// The middle of the last row is red (R high, G and B low) in whatever 8-bit layout the decoder returned.
    private static func bottomIsRed(_ image: DecodedImage?) -> Bool {
        guard let pixels = image?.pixels, pixels.layout.bytesPerPixel == 4 else { return false }
        let p = (pixels.baseAddress + (pixels.height - 1) * pixels.bytesPerRow + pixels.width / 2 * 4)
            .assumingMemoryBound(to: UInt8.self)
        let (r, g, b): (UInt8, UInt8, UInt8)
        switch pixels.layout {
        case .bgra8: (r, g, b) = (p[2], p[1], p[0])
        case .argb8: (r, g, b) = (p[1], p[2], p[3])
        default: (r, g, b) = (p[0], p[1], p[2])
        }
        return r > 200 && g < 70 && b < 70
    }
}
