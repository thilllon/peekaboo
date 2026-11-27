import CoreGraphics
import ImageIO
import Metal
import UniformTypeIdentifiers
import XCTest
@testable import PeekabooCore

/// Test double: configurable per-tier latency and lane, records every call. Thread-safe.
final class FakeDecoder: ImageDecoder, @unchecked Sendable {
    struct Call {
        let url: URL
        let tier: Tier
        let start: UInt64
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
    /// Time a metadata probe takes (a slow volume, a RAW file).
    var probeDelayMs: Double = 0
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
        if probeDelayMs > 0 { usleep(useconds_t(probeDelayMs * 1000)) }
        return ImageInfo(pixelWidth: fullWidth, pixelHeight: fullHeight, orientation: .up, typeIdentifier: "public.jpeg",
                         hasAlpha: false, hasGainMap: false, frameCount: 1, colorProfileName: nil, exif: [:])
    }

    func decode(_ url: URL, tier: Tier, targetLongSide: Int, pool: PixelBufferPool) throws -> DecodedImage {
        let lane = self.lane(for: url, info: nil, tier: tier)
        lock.lock()
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

    func makePipeline(_ decoder: ImageDecoder, configure: (inout PipelineConfig) -> Void = { _ in }) -> ImagePipeline {
        makePipeline(decoder, quickLook: nil, configure: configure)
    }

    /// `quickLook` replaces QuickLook's thumbnail generator (for `quickLookSweep = true`).
    func makePipeline(_ decoder: ImageDecoder, quickLook: DecodeScheduler.QuickLookSource?,
                      configure: (inout PipelineConfig) -> Void = { _ in }) -> ImagePipeline {
        var config = PipelineConfig(screenLongSide: 1024, previewLongSide: 256, memoryBudget: 1 << 30)
        config.readAhead = false
        config.monitorsMemoryPressure = false
        config.sweepLanes = 0
        config.quickLookSweep = false
        configure(&config)
        let pool = PixelBufferPool(device: device)
        if let quickLook { return ImagePipeline(decoder: decoder, pool: pool, config: config, quickLook: quickLook) }
        return ImagePipeline(decoder: decoder, pool: pool, config: config)
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
        XCTAssertTrue((1...2).contains(decoder.probes.filter { $0 == files[0].url }.count),
                      "probed with the first decode, not with every tier")
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
        let minimumDwellMs = PrefetchTuning().dwellMinMs
        // No screen-tier decode may start for the image on screen before the adaptive dwell while key-repeating
        // (a slow machine may stretch an interval past the dwell; then the decode is legitimate).
        for call in decoder.calls(.screen) where call.start > visibleAt[1].start && call.start < releasedAt {
            let visible = visibleAt.last { $0.start <= call.start }!
            let shownFor = Double(call.start &- visible.start) / 1e6
            if files.firstIndex(where: { $0.url == call.url }) == visible.index {
                XCTAssertGreaterThanOrEqual(shownFor, minimumDwellMs - 1, "screen decode of the visible image while skimming")
            }
        }
        XCTAssertTrue(spin(timeout: 2) { self.has(pipeline, files[25], .screen) }, "visible screen tier arrives after the dwell")
        if let call = decoder.calls(.screen).first(where: { $0.url == files[25].url }), call.start > visibleAt.last!.start {
            let waited = Double(call.start &- visibleAt.last!.start) / 1e6
            XCTAssertGreaterThanOrEqual(waited, minimumDwellMs - 1, "screen tier waits for the adaptive dwell")
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
        XCTAssertTrue(spin { self.has(pipeline, files[110], .screen) })
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
        let screenDecodesOfOne = { decoder.calls(.screen).filter { $0.url == files[1].url }.count }
        let before = screenDecodesOfOne()
        // Delete image 0: image 1 becomes current at index 0 and must not be decoded again.
        let survivors = Array(files.dropFirst())
        pipeline.setFiles(survivors, index: 0)
        XCTAssertTrue(pipeline.cachedTiers(for: files[0]).isEmpty, "removed files leave the cache")
        XCTAssertTrue(has(pipeline, files[1], .screen))
        XCTAssertEqual(pipeline.best(for: survivors[0])?.tier, .screen)
        spin(for: 0.1)
        XCTAssertEqual(screenDecodesOfOne(), before, "the surviving screen tier is reused")
        // A file that changed on disk is decoded again.
        let changed = ImageFile(url: files[1].url, name: files[1].name, byteSize: 2000, modified: 2, fileID: 2)
        pipeline.setFiles([changed] + Array(survivors.dropFirst()), index: 0)
        XCTAssertFalse(has(pipeline, changed, .screen))
        XCTAssertTrue(spin { self.has(pipeline, changed, .screen) })
    }

    /// What replacing the set may free, collected from the cached files alone: the best tier of every file that has
    /// pixels, as looking each file of the set up gives it.
    func testCachedBestIsTheBestTierOfEveryCachedFile() {
        let pipeline = makePipeline(FakeDecoder())
        let files = makeFiles(40)
        pipeline.setFiles(files, index: 0)
        XCTAssertTrue(spin { self.has(pipeline, files[0], .screen) && self.has(pipeline, files[1], .screen) })
        let looked = files.compactMap { pipeline.best(for: $0) }.map { ObjectIdentifier($0.pixels) }
        XCTAssertGreaterThan(looked.count, 1)
        XCTAssertEqual(Set(pipeline.cachedBest.map { ObjectIdentifier($0.pixels) }), Set(looked))
        XCTAssertEqual(pipeline.cachedBest.count, looked.count)
        pipeline.setFiles([], index: 0)
        XCTAssertTrue(pipeline.cachedBest.isEmpty)
    }

    /// Files are indexed by name (unique within a folder); a set opened from several folders may repeat a name, and
    /// each file still keeps its own tiers.
    func testFilesWithTheSameNameInDifferentFoldersStayApart() {
        let decoder = FakeDecoder()
        let pipeline = makePipeline(decoder)
        let files = ["a", "b", "c"].enumerated().map { i, folder in
            ImageFile(url: URL(fileURLWithPath: "/peekaboo-test/\(folder)/x.jpg"), name: "x.jpg", byteSize: 1000,
                      modified: 1, fileID: UInt64(i + 1))
        }
        pipeline.setFiles(files, index: 1)
        XCTAssertTrue(spin { files.allSatisfy { self.has(pipeline, $0, .screen) } })
        spin(for: 0.1)
        for file in files {
            XCTAssertEqual(decoder.calls(.screen).filter { $0.url == file.url }.count, 1, file.url.path)
        }
        pipeline.setFiles([files[0], files[2]], index: 1)
        XCTAssertTrue(has(pipeline, files[0], .screen))
        XCTAssertTrue(has(pipeline, files[2], .screen))
        XCTAssertTrue(pipeline.cachedTiers(for: files[1]).isEmpty, "a removed file's tiers are dropped")
        XCTAssertEqual(pipeline.currentFile?.url, files[2].url)
    }

    /// Folders that share their names (camera folders opened together): every file is found at its own place, by name
    /// or, for a name that repeats, by URL; a URL listed twice is found at its first place.
    func testEveryFileOfFoldersSharingTheirNamesIsFoundAtItsPlace() {
        let pipeline = makePipeline(FakeDecoder())
        let files = (0..<3).flatMap { folder in
            (0..<50).map { i in
                let name = String(format: "IMG_%04d.jpg", i)
                return ImageFile(url: URL(fileURLWithPath: "/peekaboo-test/\(folder)/\(name)"), name: name, byteSize: 1000,
                                 modified: 1, fileID: UInt64(folder * 100 + i + 1))
            }
        }
        pipeline.setFiles(files + [files[120]], index: 0)
        for (i, file) in files.enumerated() { XCTAssertEqual(pipeline.index(of: file.url), i, file.url.path) }
        XCTAssertNil(pipeline.index(of: URL(fileURLWithPath: "/peekaboo-test/3/IMG_0000.jpg")))
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
        let pipeline = makePipeline(decoder)
        let files = makeFiles(120)
        pipeline.setFiles(files, index: 0)
        for i in 1...12 {
            spin(for: 0.06)
            pipeline.navigate(to: i, isRepeat: false)
        }
        spin(for: 0.5)
        XCTAssertLessThanOrEqual(decoder.maxInFlight(.hardware), 2, "two hardware engines")
        XCTAssertGreaterThan(decoder.maxInFlight(.hardware), 0)
        XCTAssertLessThanOrEqual(decoder.maxInFlight(.general), 5, "general ImageIO: 4 + 1 for the visible image")
        XCTAssertLessThanOrEqual(decoder.maxTotalInFlight, 6, "six decode lanes")
    }

    func testRequestFullResolutionAndSpeculativeFull() {
        let decoder = FakeDecoder(fullSize: (8000, 6000))
        let pipeline = makePipeline(decoder)
        let files = makeFiles(5, ext: "png")  // 48 MP PNG: full resolution is expensive, never speculative
        pipeline.setFiles(files, index: 0)
        pipeline.requestFullResolution()  // a preview on screen: ignored until the screen tier is there
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
            // The sweep only takes previews the cost model calls cheap, and the model learns from measured times:
            // on a slow CI machine the fake 1 ms previews measure above the 8 ms threshold. Call every preview cheap.
            config.tuning.cheapPreviewMs = .infinity
        }
        let files = makeFiles(400)
        pipeline.setFiles(files, index: 200)
        // Utility-QoS lanes can be slow on a loaded machine: generous timeouts.
        XCTAssertTrue(spin(timeout: 10) { pipeline.stats.sweepDecodes > 50 }, "sweep decodes: \(pipeline.stats.sweepDecodes)")
        XCTAssertTrue(spin(timeout: 10) { self.has(pipeline, files[200 + 40], .preview) && self.has(pipeline, files[200 - 40], .preview) },
                      "the sweep reaches beyond the prefetch windows")
        spin(for: 0.3)
        XCTAssertLessThanOrEqual(pipeline.cachedBytes(for: .preview), 160 << 20)
    }

    func testSweepTakesExpensivePreviewsFromQuickLook() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("peekaboo-ql-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for i in 0..<10 {
            let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(red: CGFloat(i) / 4, green: 0.5, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
            let url = directory.appendingPathComponent("q\(i).png")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        let files = try FolderScanner.scan(directory)
        // PNG previews cost a whole decode (24 MP ≈ 150 ms, inflate-bound): only QuickLook may fill them in the background.
        let decoder = FakeDecoder(latencyMs: [.preview: 300, .screen: 5, .full: 10])
        let pipeline = makePipeline(decoder) { config in
            config.sweepLanes = 2
            config.quickLookSweep = true
        }
        pipeline.setFiles(files, index: 0)
        // Files beyond the screen window keep a preview only.
        let previewOnly = { files.filter { pipeline.cachedTiers(for: $0) == [.preview] } }
        let served = spin(timeout: 15) { !previewOnly().isEmpty }
        guard served else { throw XCTSkip("QuickLook produced no thumbnail in this environment") }
        let previewed = previewOnly()
        XCTAssertGreaterThan(pipeline.stats.quickLookPreviews, 0)
        XCTAssertFalse(decoder.calls(.preview).contains { call in previewed.contains { $0.url == call.url } },
                       "QuickLook previews must not cost our own preview decode")
        XCTAssertEqual(pipeline.best(for: previewed[0])?.fullWidth, 4000, "layout size comes from the probed metadata")
    }
}
