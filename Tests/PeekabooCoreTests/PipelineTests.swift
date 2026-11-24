import CoreGraphics
import Metal
import XCTest
@testable import PeekabooCore

/// Test double: configurable per-tier latency and lane, records every call. Thread-safe.
final class FakeDecoder: ImageDecoder, @unchecked Sendable {
    struct Call {
        let url: URL
        let tier: Tier
        let start: UInt64
        var end: UInt64 = 0
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _probes: [URL] = []
    private var inFlight: [DecodeLane: Int] = [:]
    private var _maxInFlight: [DecodeLane: Int] = [:]
    private var _maxTotal = 0
    private var total = 0
    var latencyMs: [Tier: Double]
    var lanes: [Tier: DecodeLane]
    var failing: Set<String> = []
    /// Pixel size per tier (the pool rounds every buffer up to 1 MB, so each cached tier costs 1 MB).
    let fullWidth: Int, fullHeight: Int

    init(latencyMs: [Tier: Double] = [.preview: 2, .screen: 20, .full: 40],
         lanes: [Tier: DecodeLane] = [.preview: .general, .screen: .hardware, .full: .hardware],
         fullSize: (Int, Int) = (4000, 3000)) {
        self.latencyMs = latencyMs
        self.lanes = lanes
        (fullWidth, fullHeight) = fullSize
    }

    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
    var probes: [URL] { lock.lock(); defer { lock.unlock() }; return _probes }
    func maxInFlight(_ lane: DecodeLane) -> Int { lock.lock(); defer { lock.unlock() }; return _maxInFlight[lane] ?? 0 }
    var maxTotalInFlight: Int { lock.lock(); defer { lock.unlock() }; return _maxTotal }

    func calls(_ tier: Tier) -> [Call] { calls.filter { $0.tier == tier } }

    func probe(_ url: URL) throws -> ImageInfo {
        lock.lock(); _probes.append(url); lock.unlock()
        return ImageInfo(pixelWidth: fullWidth, pixelHeight: fullHeight, orientation: .up, typeIdentifier: "public.jpeg",
                         hasAlpha: false, hasGainMap: false, frameCount: 1, colorProfileName: nil, exif: [:])
    }

    func decode(_ url: URL, tier: Tier, targetLongSide: Int, pool: PixelBufferPool) throws -> DecodedImage {
        let lane = self.lane(for: url, info: nil, tier: tier)
        lock.lock()
        let index = _calls.count
        _calls.append(Call(url: url, tier: tier, start: Trace.now()))
        inFlight[lane, default: 0] += 1
        total += 1
        _maxInFlight[lane] = max(_maxInFlight[lane] ?? 0, inFlight[lane]!)
        _maxTotal = max(_maxTotal, total)
        let latency = latencyMs[tier] ?? 1
        let fails = failing.contains(url.lastPathComponent)
        lock.unlock()
        usleep(useconds_t(latency * 1000))
        lock.lock()
        inFlight[lane, default: 1] -= 1
        total -= 1
        _calls[index].end = Trace.now()
        lock.unlock()
        if fails { throw DecodeError.unreadable(url.lastPathComponent) }
        let side = tier == .preview ? 64 : tier == .screen ? 128 : 256
        guard let pixels = pool.make(width: side, height: side * 3 / 4, layout: .bgra8, alpha: .opaque,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { throw DecodeError.outOfMemory }
        return DecodedImage(pixels: pixels, tier: tier, fullWidth: fullWidth, fullHeight: fullHeight, orientation: .up,
                            isHDR: false, decodeNanos: UInt64(latency * 1e6))
    }

    func lane(for url: URL, info: ImageInfo?, tier: Tier) -> DecodeLane { lanes[tier] ?? .general }
}

/// Shared helpers for pipeline tests (main-thread run-loop spinning, fake folders).
class PipelineTestCase: XCTestCase {
    var device: MTLDevice!

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        self.device = device
    }

    func makeFiles(_ count: Int, ext: String = "jpg") -> [ImageFile] {
        (0..<count).map { i in
            let name = String(format: "img%04d.\(ext)", i)
            return ImageFile(url: URL(fileURLWithPath: "/peekaboo-test/\(name)"), name: name, byteSize: 1000,
                             modified: 1, fileID: UInt64(i + 1))
        }
    }

    func makePipeline(_ decoder: FakeDecoder, configure: (inout PipelineConfig) -> Void = { _ in }) -> ImagePipeline {
        var config = PipelineConfig(screenLongSide: 1024, previewLongSide: 256, memoryBudget: 1 << 30)
        config.readAhead = false
        config.monitorsMemoryPressure = false
        config.sweepLanes = 0
        configure(&config)
        return ImagePipeline(decoder: decoder, pool: PixelBufferPool(device: device), config: config)
    }

    @discardableResult
    func spin(timeout: TimeInterval = 2, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.001))
        }
        return condition()
    }

    func spin(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.001)) }
    }

    func has(_ pipeline: ImagePipeline, _ file: ImageFile, _ tier: Tier) -> Bool {
        pipeline.cachedTiers(for: file).contains(tier)
    }
}

final class PipelineTests: PipelineTestCase {
    func testVisiblePreviewArrivesBeforeScreenThenNeighboursPrefetch() {
        let decoder = FakeDecoder()
        let pipeline = makePipeline(decoder)
        let files = makeFiles(20)
        var arrivals: [(ImageFile, Tier)] = []
        pipeline.onDecoded = { file, image in arrivals.append((file, image.tier)) }
        pipeline.setFiles(files, index: 0)
        XCTAssertTrue(spin { self.has(pipeline, files[0], .screen) })
        let first = arrivals.filter { $0.0 == files[0] }.map(\.1)
        XCTAssertEqual(first.first, .preview, "first pixel comes from the cheap preview")
        XCTAssertTrue(first.contains(.screen))
        XCTAssertTrue(spin { self.has(pipeline, files[1], .screen) }, "next image is prefetched")
        XCTAssertEqual(pipeline.info(for: files[0])?.pixelWidth, 4000, "metadata rides along with the first decode")
        XCTAssertEqual(decoder.probes.filter { $0 == files[0].url }.count, 1, "probed once per file")
        pipeline.navigate(to: 1, isRepeat: false)
        XCTAssertEqual(pipeline.stats.hits, 1)
        XCTAssertEqual(pipeline.best(for: files[1])?.tier, .screen)
    }

    func testQueuedJobsCancelOnJump() {
        let decoder = FakeDecoder(latencyMs: [.preview: 30, .screen: 120, .full: 200])
        let pipeline = makePipeline(decoder)
        let files = makeFiles(200)
        pipeline.setFiles(files, index: 0)
        for i in 1...6 {
            spin(for: 0.15)
            pipeline.navigate(to: i, isRepeat: false)
        }
        let jumpTime = Trace.now()
        pipeline.navigate(to: 150, isRepeat: false)
        XCTAssertTrue(spin(timeout: 3) { self.has(pipeline, files[150], .screen) })
        spin(for: 0.3)
        let late = decoder.calls.filter { $0.start > jumpTime + 2_000_000 }
        XCTAssertFalse(late.isEmpty)
        for call in late {
            let index = files.firstIndex { $0.url == call.url }!
            XCTAssertLessThanOrEqual(abs(index - 150), 48, "queued work of the old window must not start after the jump")
        }
    }

    func testSkimmingDecodesPreviewsOnlyAndScreenAfterDwell() {
        let decoder = FakeDecoder(latencyMs: [.preview: 2, .screen: 60, .full: 100])
        let pipeline = makePipeline(decoder)
        let files = makeFiles(100)
        pipeline.setFiles(files, index: 0)
        XCTAssertTrue(spin { self.has(pipeline, files[0], .screen) })
        spin(for: 0.3)
        var visibleAt: [(start: UInt64, index: Int)] = []
        for i in 1...25 {
            pipeline.navigate(to: i, isRepeat: i > 1)
            visibleAt.append((Trace.now(), i))
            spin(for: 0.03)
        }
        let releasedAt = Trace.now()
        XCTAssertTrue(pipeline.isSkimming)
        // No screen-tier decode may start for the image on screen while key-repeating.
        for call in decoder.calls(.screen) where call.start > visibleAt[1].start && call.start < releasedAt {
            let visible = visibleAt.last { $0.start <= call.start }!.index
            XCTAssertNotEqual(files.firstIndex { $0.url == call.url }, visible, "screen decode of the visible image while skimming")
        }
        XCTAssertTrue(spin(timeout: 2) { self.has(pipeline, files[25], .screen) }, "visible screen tier arrives after the dwell")
        if let call = decoder.calls(.screen).first(where: { $0.url == files[25].url }) {
            let waited = Double(call.start &- releasedAt) / 1e6
            if call.start > releasedAt { XCTAssertGreaterThanOrEqual(waited, 30, "screen tier waits for the adaptive dwell") }
        }
        XCTAssertGreaterThan(pipeline.cachedTiers(for: files[24]).count + pipeline.cachedTiers(for: files[20]).count, 0,
                             "previews were shown while skimming")
    }

    func testABPartnerIsPinnedUnderTightBudget() {
        let decoder = FakeDecoder()
        let pipeline = makePipeline(decoder) { config in
            config.screenBudget = 3 << 20
            config.fullBudget = 2 << 20
        }
        let files = makeFiles(40)
        pipeline.setFiles(files, index: 10)
        XCTAssertTrue(spin { self.has(pipeline, files[10], .screen) })
        for target in [11, 10, 11, 10, 11] {
            spin(for: 0.25)
            pipeline.navigate(to: target, isRepeat: false)
        }
        XCTAssertTrue(pipeline.navigation.isAB)
        spin(for: 0.6)
        XCTAssertEqual(Set(pipeline.pinnedFiles.map(\.name)), [files[11].name, files[10].name])
        XCTAssertTrue(has(pipeline, files[10], .screen) || has(pipeline, files[10], .full))
        XCTAssertTrue(has(pipeline, files[11], .screen) || has(pipeline, files[11], .full))
        XCTAssertLessThanOrEqual(pipeline.cachedBytes(for: .screen), 3 << 20)
    }

    func testEvictionKeepsBudgetAndDropsFarthestETA() {
        let decoder = FakeDecoder(latencyMs: [.preview: 1, .screen: 5, .full: 10])
        let pipeline = makePipeline(decoder) { config in
            config.screenBudget = 4 << 20
            config.previewBudget = 64 << 20
        }
        let files = makeFiles(60)
        pipeline.setFiles(files, index: 0)
        for i in 1...20 {
            spin(for: 0.12)
            pipeline.navigate(to: i, isRepeat: false)
        }
        spin(for: 0.3)
        XCTAssertLessThanOrEqual(pipeline.cachedBytes(for: .screen), 4 << 20)
        XCTAssertGreaterThan(pipeline.stats.evictions, 0)
        XCTAssertTrue(has(pipeline, files[20], .screen), "current image is pinned")
        XCTAssertFalse(has(pipeline, files[2], .screen), "far behind (largest ETA) goes first")
        let cached = Tier.allCases.reduce(0) { $0 + pipeline.cachedBytes(for: $1) }
        XCTAssertEqual(pipeline.stats.cachedBytes, cached)
    }

    func testMemoryPressureTrimsTiers() {
        let decoder = FakeDecoder(latencyMs: [.preview: 1, .screen: 3, .full: 5])
        let pipeline = makePipeline(decoder)
        let files = makeFiles(300)
        pipeline.setFiles(files, index: 100)
        XCTAssertTrue(spin { self.has(pipeline, files[100], .screen) })
        for i in 101...110 {
            spin(for: 0.1)
            pipeline.navigate(to: i, isRepeat: false)
        }
        pipeline.requestFullResolution()
        XCTAssertTrue(spin { self.has(pipeline, files[110], .full) })
        spin(for: 0.2)
        pipeline.handleMemoryPressure(critical: false)
        for (i, file) in files.enumerated() where i != 110 {
            XCTAssertFalse(has(pipeline, file, .full), "warning drops full resolution of other images")
            if abs(i - 110) > 4 { XCTAssertFalse(has(pipeline, file, .screen)) }
        }
        pipeline.handleMemoryPressure(critical: true)
        for (i, file) in files.enumerated() where i != 110 {
            XCTAssertFalse(has(pipeline, file, .screen), "critical keeps only the current sharp tiers")
            if abs(i - 110) > 32 { XCTAssertFalse(has(pipeline, file, .preview)) }
        }
        XCTAssertTrue(has(pipeline, files[110], .full))
        XCTAssertEqual(pipeline.stats.cachedBytes, Tier.allCases.reduce(0) { $0 + pipeline.cachedBytes(for: $1) })
    }

    func testSetFilesKeepsCacheForSurvivingFiles() {
        let decoder = FakeDecoder()
        let pipeline = makePipeline(decoder)
        let files = makeFiles(10)
        pipeline.setFiles(files, index: 0)
        XCTAssertTrue(spin { self.has(pipeline, files[1], .screen) && self.has(pipeline, files[0], .screen) })
        let decodes = pipeline.stats.decodes
        // Delete image 0: image 1 becomes current at index 0 and must not be decoded again.
        let survivors = Array(files.dropFirst())
        pipeline.setFiles(survivors, index: 0)
        XCTAssertTrue(pipeline.cachedTiers(for: files[0]).isEmpty, "removed files leave the cache")
        XCTAssertTrue(has(pipeline, files[1], .screen))
        XCTAssertEqual(pipeline.best(for: survivors[0])?.tier, .screen)
        spin(for: 0.1)
        XCTAssertFalse(decoder.calls.dropFirst(decodes).contains { $0.url == files[1].url && $0.tier == .screen })
        // A file that changed on disk is decoded again.
        let changed = ImageFile(url: files[1].url, name: files[1].name, byteSize: 2000, modified: 2, fileID: 2)
        pipeline.setFiles([changed] + Array(survivors.dropFirst()), index: 0)
        XCTAssertFalse(has(pipeline, changed, .screen))
        XCTAssertTrue(spin { self.has(pipeline, changed, .screen) })
    }

    func testOpenedFileSurvivesFolderListing() {
        let decoder = FakeDecoder(latencyMs: [.preview: 5, .screen: 80, .full: 100])
        let pipeline = makePipeline(decoder)
        let files = makeFiles(30)
        let opened = ImageFile(url: files[7].url, name: files[7].name, byteSize: 0, modified: 0, fileID: 0)
        pipeline.setFiles([opened], index: 0)
        spin(for: 0.02)
        pipeline.setFiles(files, index: 7)
        XCTAssertTrue(spin { self.has(pipeline, files[7], .screen) })
        XCTAssertEqual(decoder.calls(.screen).filter { $0.url == files[7].url }.count, 1,
                       "the running decode of the opened file is kept, not restarted")
    }

    func testLaneCaps() {
        let decoder = FakeDecoder(latencyMs: [.preview: 15, .screen: 40, .full: 60],
                                  lanes: [.preview: .general, .screen: .hardware, .full: .hardware])
        let pipeline = makePipeline(decoder) { $0.sweepLanes = 4 }
        let files = makeFiles(120)
        pipeline.setFiles(files, index: 0)
        for i in 1...12 {
            spin(for: 0.06)
            pipeline.navigate(to: i, isRepeat: false)
        }
        spin(for: 0.5)
        XCTAssertLessThanOrEqual(decoder.maxInFlight(.hardware), 3, "hardware engines: 2 + 1 for the visible image")
        XCTAssertLessThanOrEqual(decoder.maxInFlight(.general), 5, "general ImageIO: 4 + 1 for the visible image")
        XCTAssertLessThanOrEqual(decoder.maxTotalInFlight, 10)
    }

    func testRequestFullResolutionAndSpeculativeFull() {
        let decoder = FakeDecoder(fullSize: (8000, 6000))
        let pipeline = makePipeline(decoder)
        let files = makeFiles(5, ext: "png")  // 48 MP PNG: full resolution is expensive, never speculative
        pipeline.setFiles(files, index: 0)
        XCTAssertTrue(spin { self.has(pipeline, files[0], .screen) })
        spin(for: 0.5)
        XCTAssertFalse(has(pipeline, files[0], .full))
        pipeline.requestFullResolution()
        XCTAssertTrue(spin { self.has(pipeline, files[0], .full) })
        XCTAssertEqual(pipeline.best(for: files[0])?.tier, .full)

        let jpegs = makeFiles(5)  // JPEG: cheap enough for a speculative full decode after the dwell
        let other = makePipeline(FakeDecoder())
        other.setFiles(jpegs, index: 0)
        XCTAssertTrue(spin { self.has(other, jpegs[0], .screen) })
        XCTAssertFalse(has(other, jpegs[0], .full))
        XCTAssertTrue(spin(timeout: 2) { self.has(other, jpegs[0], .full) }, "speculative full after a 400 ms dwell")
    }

    func testFailuresAreReportedOnceAndNotRetried() {
        let decoder = FakeDecoder()
        decoder.failing = ["img0000.jpg"]
        let pipeline = makePipeline(decoder)
        let files = makeFiles(5)
        var failures: [ImageFile] = []
        pipeline.onFailed = { file, _ in failures.append(file) }
        pipeline.setFiles(files, index: 0)
        XCTAssertTrue(spin { !failures.isEmpty })
        spin(for: 0.6)
        XCTAssertEqual(failures, [files[0]])
        XCTAssertEqual(decoder.calls(.screen).filter { $0.url == files[0].url }.count, 1)
        XCTAssertGreaterThan(pipeline.stats.failures, 0)
    }

    func testSweepFillsPreviewsOnUtilityLanes() {
        let decoder = FakeDecoder(latencyMs: [.preview: 1, .screen: 5, .full: 10])
        let pipeline = makePipeline(decoder) { config in
            config.sweepLanes = 4
            config.previewBudget = 160 << 20
        }
        let files = makeFiles(400)
        pipeline.setFiles(files, index: 200)
        XCTAssertTrue(spin(timeout: 3) { pipeline.stats.sweepDecodes > 50 })
        XCTAssertTrue(spin(timeout: 3) { self.has(pipeline, files[200 + 40], .preview) && self.has(pipeline, files[200 - 40], .preview) },
                      "the sweep reaches beyond the prefetch windows")
        spin(for: 0.3)
        XCTAssertLessThanOrEqual(pipeline.cachedBytes(for: .preview), 160 << 20)
    }
}
