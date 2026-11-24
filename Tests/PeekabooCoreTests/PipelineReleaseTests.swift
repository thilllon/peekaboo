import CoreGraphics
import Metal
import XCTest
@testable import PeekabooCore

/// Decoder whose pixels record the thread that frees them (`MTLBuffer` deallocator, run by the last release).
final class ReleaseTrackingDecoder: ImageDecoder, @unchecked Sendable {
    private let device: MTLDevice
    private let lock = NSLock()
    private var _freed = 0
    private var _freedOnMain = 0
    let latencyMs: [Tier: Double]

    init(device: MTLDevice, latencyMs: [Tier: Double] = [.preview: 1, .screen: 5, .full: 10]) {
        self.device = device
        self.latencyMs = latencyMs
    }

    var freed: Int { lock.lock(); defer { lock.unlock() }; return _freed }
    var freedOnMain: Int { lock.lock(); defer { lock.unlock() }; return _freedOnMain }

    func probe(_ url: URL) throws -> ImageInfo {
        ImageInfo(pixelWidth: 4000, pixelHeight: 3000, orientation: .up, typeIdentifier: "public.jpeg", hasAlpha: false,
                  hasGainMap: false, frameCount: 1, colorProfileName: nil, exif: [:])
    }

    func decode(_ url: URL, tier: Tier, targetLongSide: Int, pool: PixelBufferPool) throws -> DecodedImage {
        usleep(useconds_t((latencyMs[tier] ?? 1) * 1000))
        let page = Int(getpagesize())
        let length = 16 * page
        var raw: UnsafeMutableRawPointer?
        guard posix_memalign(&raw, page, length) == 0, let raw else { throw DecodeError.outOfMemory }
        guard let buffer = device.makeBuffer(bytesNoCopy: raw, length: length, options: .storageModeShared, deallocator: { [weak self] pointer, _ in
            self?.record(onMain: Thread.isMainThread)
            free(pointer)
        }) else {
            free(raw)
            throw DecodeError.outOfMemory
        }
        let pixels = PixelBuffer(width: 64, height: 48, bytesPerRow: 256, layout: .bgra8, alpha: .opaque,
                                 colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, storage: .metal(buffer))
        return DecodedImage(pixels: pixels, tier: tier, fullWidth: 4000, fullHeight: 3000, orientation: .up, isHDR: false,
                            decodeNanos: 0)
    }

    func lane(for url: URL, info: ImageInfo?, tier: Tier) -> DecodeLane { tier == .preview ? .general : .hardware }

    private func record(onMain: Bool) {
        lock.lock()
        _freed += 1
        if onMain { _freedOnMain += 1 }
        lock.unlock()
    }
}

/// Pixels the cache lets go of are freed off the main thread, and the pool's free buffers stay within the budget.
final class PipelineReleaseTests: PipelineTestCase {
    /// Evictions, late results, a replaced browsing set and a memory-pressure trim all drop pixels: none may be freed
    /// on the main thread (releasing a full-resolution IOSurface there costs 1–5 ms).
    func testDroppedPixelsAreFreedOffTheMainThread() {
        let decoder = ReleaseTrackingDecoder(device: device, latencyMs: [.preview: 1, .screen: 5, .full: 150])
        var config = PipelineConfig(screenLongSide: 1024, previewLongSide: 256, memoryBudget: 1 << 30)
        config.readAhead = false
        config.monitorsMemoryPressure = false
        config.sweepLanes = 0
        config.quickLookSweep = false
        config.screenBudget = 4 * 16 * Int(getpagesize())  // four screen tiers: browsing evicts
        let pipeline = ImagePipeline(decoder: decoder, pool: PixelBufferPool(device: device), config: config)
        let files = makeFiles(40)
        pipeline.setFiles(files, index: 0)
        XCTAssertTrue(spin { self.has(pipeline, files[0], .screen) })
        // Dwell past the speculative full (400 ms), leave before its 150 ms decode lands: the late result is dropped.
        for i in 1...6 {
            spin(for: 0.45)
            pipeline.navigate(to: i, isRepeat: false)
        }
        spin(for: 0.3)
        XCTAssertGreaterThan(pipeline.stats.wasted, 0, "late speculative full tiers were dropped")
        XCTAssertGreaterThan(pipeline.stats.evictions, 0)
        pipeline.setFiles(Array(files.prefix(3)), index: 2)  // most files removed
        pipeline.handleMemoryPressure(critical: true)
        spin(for: 0.1)
        pipeline.waitForReleases()
        XCTAssertGreaterThan(decoder.freed, 10)
        XCTAssertEqual(decoder.freedOnMain, 0, "pixels freed on the main thread")
    }

    /// Free buffers of the pool count against the memory budget: shrinking the budget evicts tiers into the pool,
    /// which must not keep them beyond what the cache leaves unused.
    func testPoolFreeBuffersStayWithinTheMemoryBudget() {
        let decoder = FakeDecoder(latencyMs: [.preview: 1, .screen: 2, .full: 3])
        let pool = PixelBufferPool(device: device)
        var config = PipelineConfig(screenLongSide: 1024, previewLongSide: 256, memoryBudget: 256 << 20)
        config.readAhead = false
        config.monitorsMemoryPressure = false
        config.sweepLanes = 0
        config.quickLookSweep = false
        let pipeline = ImagePipeline(decoder: decoder, pool: pool, config: config)
        let files = makeFiles(60)
        pipeline.setFiles(files, index: 0)
        for i in 1...30 {
            spin(for: 0.03)
            pipeline.navigate(to: i, isRepeat: false)
        }
        XCTAssertTrue(spin { pipeline.stats.cachedBytes >= 20 << 20 && pipeline.queuedDecodes == 0 })
        // A smaller budget (e.g. `[cache] memory_mb`): most tiers are evicted.
        var small = config
        small.memoryBudget = 8 << 20
        small.screenBudget = 2 << 20
        small.previewBudget = 2 << 20
        small.fullBudget = 2 << 20
        pipeline.updateConfig(small)
        pipeline.waitForReleases()
        XCTAssertLessThanOrEqual(pipeline.stats.cachedBytes, 8 << 20)
        XCTAssertLessThanOrEqual(pool.pooledBytes + pipeline.stats.cachedBytes, 8 << 20,
                                 "pool keeps \(pool.pooledBytes >> 20) MB beyond the budget")
    }
}
