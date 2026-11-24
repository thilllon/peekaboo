import XCTest
@testable import PeekabooCore

/// Launch fast path (`waitForCurrent`) and full-resolution requests for images whose screen tier is already full size.
final class PipelineLaunchTests: PipelineTestCase {
    func testWaitForCurrentDeliversWithoutAMainQueueTurn() {
        let decoder = FakeDecoder(latencyMs: [.preview: 5, .screen: 20, .full: 40])
        let pipeline = makePipeline(decoder)
        let files = makeFiles(10)
        var delivered: [Tier] = []
        pipeline.onDecoded = { file, image in if file == files[0] { delivered.append(image.tier) } }
        pipeline.setFiles(files, index: 0)
        // No run-loop spinning: the outcome is handed over synchronously.
        XCTAssertTrue(pipeline.waitForCurrent(timeout: 2))
        XCTAssertFalse(delivered.isEmpty)
        XCTAssertNotNil(pipeline.best(for: files[0]))
        // The main-queue hops that follow find the inbox drained: every tier is delivered exactly once.
        XCTAssertTrue(spin(until: { delivered.contains(.screen) }))
        spin(for: 0.1)
        XCTAssertEqual(delivered.count, Set(delivered).count, "duplicate deliveries: \(delivered)")
    }

    func testWaitForCurrentTimesOut() {
        let decoder = FakeDecoder(latencyMs: [.preview: 400, .screen: 400, .full: 400])
        let pipeline = makePipeline(decoder)
        let files = makeFiles(4)
        pipeline.setFiles(files, index: 0)
        let start = Date()
        XCTAssertFalse(pipeline.waitForCurrent(timeout: 0.05))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.3)
        XCTAssertTrue(spin(until: { pipeline.best(for: files[0]) != nil }))
    }

    func testWaitForCurrentWithoutFilesReturnsImmediately() {
        let pipeline = makePipeline(FakeDecoder())
        XCTAssertFalse(pipeline.waitForCurrent(timeout: 1))
    }

    /// A screen tier that already holds every pixel (small image) satisfies `.full`: no second decode is queued, neither
    /// for an explicit request nor speculatively after the dwell.
    func testNoFullDecodeWhenScreenTierIsFullResolution() {
        // The fake decodes the screen tier at 128×96: make that the full size.
        let decoder = FakeDecoder(latencyMs: [.preview: 1, .screen: 5, .full: 5], fullSize: (128, 96))
        let pipeline = makePipeline(decoder)
        let files = makeFiles(6)
        pipeline.setFiles(files, index: 0)
        XCTAssertTrue(spin(until: { self.has(pipeline, files[0], .screen) }))
        pipeline.requestFullResolution()
        spin(for: 0.6)  // past the speculative-full dwell (400 ms)
        XCTAssertTrue(decoder.calls(.full).isEmpty, "redundant full decodes: \(decoder.calls(.full).map(\.url.lastPathComponent))")
    }
}
