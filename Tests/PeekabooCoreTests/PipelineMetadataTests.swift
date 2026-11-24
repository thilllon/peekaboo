import CoreGraphics
import XCTest
@testable import PeekabooCore

/// Routes like `ImageIODecoder` does for progressive JPEGs: without metadata the extension says "hardware engines";
/// probed, the screen and full tiers are libjpeg-turbo work on a CPU lane. Records how many screen tiers run at once.
final class ProgressiveDecoder: ImageDecoder, @unchecked Sendable {
    let screenMs: Double
    private let lock = NSLock()
    private var running = 0
    private var _maxConcurrentScreens = 0

    init(screenMs: Double) { self.screenMs = screenMs }

    var maxConcurrentScreens: Int { lock.lock(); defer { lock.unlock() }; return _maxConcurrentScreens }

    func probe(_ url: URL) throws -> ImageInfo {
        ImageInfo(pixelWidth: 5947, pixelHeight: 3964, orientation: .up, typeIdentifier: "public.jpeg", hasAlpha: false,
                  hasGainMap: false, frameCount: 1, colorProfileName: nil, exif: ["format": "JPEG progressive"])
    }

    func decode(_ url: URL, tier: Tier, targetLongSide: Int, pool: PixelBufferPool) throws -> DecodedImage {
        if tier == .screen {
            lock.lock()
            running += 1
            _maxConcurrentScreens = max(_maxConcurrentScreens, running)
            lock.unlock()
        }
        usleep(useconds_t((tier == .preview ? 1 : screenMs) * 1000))
        if tier == .screen { lock.lock(); running -= 1; lock.unlock() }
        guard let pixels = pool.make(width: 64, height: 48, layout: .bgra8, alpha: .opaque,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { throw DecodeError.outOfMemory }
        return DecodedImage(pixels: pixels, tier: tier, fullWidth: 5947, fullHeight: 3964, orientation: .up, isHDR: false,
                            decodeNanos: 0)
    }

    func lane(for url: URL, info: ImageInfo?, tier: Tier) -> DecodeLane {
        guard let info else { return .hardware }  // ".jpg"
        return info.exif["format"] == "JPEG progressive" ? (tier == .preview ? .general : .cpu) : .hardware
    }
}

/// A file's metadata reaches the planner with its first decode, and decodes are charged to the lane they really use.
final class PipelineMetadataTests: PipelineTestCase {
    private final class Outcomes: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [DecodeOutcome] = []
        func append(_ outcome: DecodeOutcome) { lock.lock(); items.append(outcome); lock.unlock() }
        var all: [DecodeOutcome] { lock.lock(); defer { lock.unlock() }; return items }
    }

    /// Jobs planned before a file was ever probed carry the extension's lane (hardware engines, two slots). The worker
    /// probes first and charges them to the lane the decode takes, so five progressive screen tiers run side by side.
    func testWorkerSettlesTheLaneOfAFirstDecode() {
        let decoder = ProgressiveDecoder(screenMs: 150)
        let outcomes = Outcomes()
        let scheduler = DecodeScheduler(decoder: decoder, pool: PixelBufferPool(device: device), limits: LaneLimits()) {
            outcomes.append($0)
        }
        defer { scheduler.stop() }
        let files = makeFiles(5)
        let jobs = files.enumerated().map { i, file in
            DecodeJob(key: JobKey(url: file.url, tier: .screen), file: file, prio: Double(i), kind: .prefetch,
                      lane: .hardware, targetLongSide: 1024, estimateMs: 150)
        }
        scheduler.submit(jobs, visible: [])
        XCTAssertTrue(spin(timeout: 3) { outcomes.all.count == files.count })
        XCTAssertGreaterThanOrEqual(decoder.maxConcurrentScreens, 3, "CPU work held to the two hardware-engine slots")
        XCTAssertTrue(outcomes.all.allSatisfy { $0.info != nil }, "every outcome carries the file's metadata")
        XCTAssertEqual(Set(outcomes.all.map(\.job.lane)), [.cpu])
    }

    /// The first tier of a file is delivered with its metadata, however long the probe takes: the planner then plans
    /// the next tiers with the right lane and cost bucket instead of racing a probe that runs after delivery.
    func testFirstDeliveryCarriesMetadata() {
        let decoder = FakeDecoder()
        decoder.probeDelayMs = 30
        let pipeline = makePipeline(decoder)
        let files = makeFiles(6)
        var infoAtFirstDelivery: [String: Bool] = [:]
        pipeline.onDecoded = { file, _ in
            if infoAtFirstDelivery[file.name] == nil { infoAtFirstDelivery[file.name] = pipeline.info(for: file) != nil }
        }
        pipeline.setFiles(files, index: 0)
        // The neighbours' decodes run side by side and land in any order: wait for all three.
        XCTAssertTrue(spin(timeout: 5) { files.prefix(3).allSatisfy { self.has(pipeline, $0, .screen) } })
        XCTAssertGreaterThanOrEqual(infoAtFirstDelivery.count, 3)
        XCTAssertEqual(infoAtFirstDelivery.filter { !$0.value }.keys.sorted(), [], "delivered without metadata")
    }

    /// Metadata belongs to the browsing set: after switching folders (or showing nothing) none is kept for the files
    /// that left it, so a resident app does not accumulate an entry per file ever opened.
    func testMetadataOfFilesThatLeftTheSetIsReleased() {
        let pipeline = makePipeline(FakeDecoder(latencyMs: [.preview: 1, .screen: 2, .full: 3]))
        let first = makeFiles(8)
        pipeline.setFiles(first, index: 0)
        XCTAssertTrue(spin { pipeline.info(for: first[0]) != nil && pipeline.info(for: first[1]) != nil })
        let other = (0..<8).map { i in
            ImageFile(url: URL(fileURLWithPath: "/peekaboo-test/other/b\(i).jpg"), name: "b\(i).jpg", byteSize: 1000,
                      modified: 1, fileID: UInt64(100 + i))
        }
        pipeline.setFiles(other, index: 0)
        XCTAssertNil(pipeline.info(for: first[0]), "metadata kept for a file outside the browsing set")
        XCTAssertNil(pipeline.info(for: first[1]))
        pipeline.setFiles([], index: 0)
        XCTAssertNil(pipeline.info(for: other[0]))
    }

    /// Browsing a folder of progressive JPEGs at ~7 images/s: prefetch keeps more than two screen tiers decoding.
    func testProgressiveScreenTiersUseTheCPULanes() {
        let decoder = ProgressiveDecoder(screenMs: 200)
        let pipeline = makePipeline(decoder)
        let files = makeFiles(30)
        pipeline.setFiles(files, index: 0)
        XCTAssertTrue(spin { self.has(pipeline, files[0], .screen) })
        for i in 1...12 {
            spin(for: 0.15)
            pipeline.navigate(to: i, isRepeat: false)
        }
        spin(for: 0.3)
        XCTAssertGreaterThanOrEqual(decoder.maxConcurrentScreens, 3, "progressive screen tiers queued for two hardware slots")
    }
}
