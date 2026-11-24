import CoreGraphics
import XCTest
@testable import PeekabooCore

/// The foreground gate holds prefetch back only while the visible image's own decodes run, and only until it is sharp.
final class PipelineGateTests: PipelineTestCase {
    private final class Outcomes: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [DecodeOutcome] = []
        func append(_ outcome: DecodeOutcome) { lock.lock(); items.append(outcome); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
    }

    /// QuickLook generating a thumbnail for a file it has not seen takes 60–500 ms in its own processes.
    private static let slowQuickLook: DecodeScheduler.QuickLookSource = { _, _, info, pool, _ in
        usleep(400_000)
        guard let pixels = pool.make(width: 64, height: 48, layout: .bgra8, alpha: .opaque,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
        return DecodedImage(pixels: pixels, tier: .preview, fullWidth: info?.orientedWidth ?? 64,
                            fullHeight: info?.orientedHeight ?? 48, orientation: .up, isHDR: false, decodeNanos: 0)
    }

    private func ms(_ from: UInt64, _ to: UInt64) -> Double { Double(Int64(bitPattern: to &- from)) / 1e6 }

    /// A visible QuickLook probe uses no decode resource: prefetch does not wait for it.
    func testQuickLookProbeDoesNotGatePrefetch() {
        let decoder = FakeDecoder(latencyMs: [.preview: 1, .screen: 20, .full: 40])
        let outcomes = Outcomes()
        let scheduler = DecodeScheduler(decoder: decoder, pool: PixelBufferPool(device: device), limits: LaneLimits(),
                                        quickLook: Self.slowQuickLook) { outcomes.append($0) }
        defer { scheduler.stop() }
        let files = makeFiles(2)
        let probe = DecodeJob(key: JobKey(url: files[0].url, tier: .preview), file: files[0], prio: -3, kind: .visible,
                              lane: .general, targetLongSide: 256, estimateMs: 1, quickLook: true)
        let prefetch = DecodeJob(key: JobKey(url: files[1].url, tier: .screen), file: files[1], prio: 1000,
                                 kind: .prefetch, lane: .hardware, targetLongSide: 1024, estimateMs: 20)
        let start = Trace.now()
        scheduler.submit([probe, prefetch], visible: [probe.key, JobKey(url: files[0].url, tier: .screen)])
        XCTAssertTrue(spin(timeout: 2) { outcomes.count == 2 })
        let started = decoder.calls(.screen).first.map { ms(start, $0.start) } ?? .infinity
        XCTAssertLessThan(started, 200, "prefetch waited \(started) ms for the QuickLook probe")
    }

    /// After a jump to a file whose own preview is expensive, the visible image asks QuickLook while its screen tier
    /// decodes. The screen tier lands first; the neighbours' prefetch starts then, not when QuickLook answers.
    func testNeighboursPrefetchOnceTheVisibleImageIsSharp() {
        let decoder = FakeDecoder(latencyMs: [.preview: 300, .screen: 20, .full: 40])
        let pipeline = makePipeline(decoder, quickLook: Self.slowQuickLook) { config in config.quickLookSweep = true }
        let files = makeFiles(30, ext: "png")  // PNG: our own preview costs as much as the screen tier
        pipeline.setFiles(files, index: 0)
        spin(for: 1)
        let jump = Trace.now()
        pipeline.navigate(to: 15, isRepeat: false)
        XCTAssertTrue(spin { self.has(pipeline, files[16], .screen) })
        let sharp = decoder.calls(.screen).first { $0.url == files[15].url }
        let neighbour = decoder.calls(.screen).first { $0.url == files[16].url }
        XCTAssertNotNil(sharp)
        let started = neighbour.map { ms(jump, $0.start) } ?? .infinity
        XCTAssertLessThan(started, 200, "neighbour prefetch started \(started) ms after the jump")
        XCTAssertFalse(has(pipeline, files[15], .preview), "a QuickLook preview after the sharp tier is dropped")
    }

    /// The first image of a folder whose preview turns out expensive (no embedded thumbnail; the cost model expects
    /// one): its screen tier lands first and releases the gate, the preview still decoding does not hold it.
    func testSlowVisiblePreviewDoesNotGateAfterTheScreenTier() {
        let decoder = FakeDecoder(latencyMs: [.preview: 300, .screen: 20, .full: 40])
        let pipeline = makePipeline(decoder)
        let files = makeFiles(20)
        let start = Trace.now()
        pipeline.setFiles(files, index: 0)
        XCTAssertTrue(spin { self.has(pipeline, files[1], .screen) })
        let started = decoder.calls(.screen).first { $0.url == files[1].url }.map { ms(start, $0.start) } ?? .infinity
        XCTAssertLessThan(started, 200, "neighbour prefetch started \(started) ms after opening")
    }
}
