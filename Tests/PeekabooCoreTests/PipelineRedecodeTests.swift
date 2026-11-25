import XCTest
@testable import PeekabooCore

/// `ImagePipeline.redecode(where:)`: a decoder setting that changes some tiers (`[decode] hdr`) applies to the images
/// already cached, and to decodes that were running when it changed.
final class PipelineRedecodeTests: PipelineTestCase {
    func testStaleTiersAreDecodedAgainAndPreviewsStay() {
        let decoder = FakeDecoder(latencyMs: [.preview: 1, .screen: 5, .full: 10])
        let pipeline = makePipeline(decoder)
        let files = makeFiles(6)
        pipeline.setFiles(files, index: 0)
        XCTAssertTrue(spin { self.has(pipeline, files[0], .screen) && self.has(pipeline, files[1], .screen) })
        spin(for: 0.1)
        let screenCalls = decoder.calls(.screen).filter { $0.url == files[0].url }.count
        let decoded = expectation(description: "decoded again")
        decoded.assertForOverFulfill = false
        let changed = Trace.now()
        pipeline.onDecoded = { file, image in if file == files[0], image.tier == .screen { decoded.fulfill() } }

        pipeline.redecode { _, tier in tier != .preview }
        XCTAssertFalse(has(pipeline, files[0], .screen), "the stale tier is dropped at once")
        XCTAssertTrue(has(pipeline, files[0], .preview), "previews are not affected")
        wait(for: [decoded], timeout: 3)
        XCTAssertEqual(decoder.calls(.screen).filter { $0.url == files[0].url }.count, screenCalls + 1)
        XCTAssertTrue(decoder.calls(.screen).contains { $0.url == files[0].url && $0.start >= changed })
        XCTAssertTrue(spin { self.has(pipeline, files[1], .screen) }, "neighbours are decoded again too")
        // Previews still decoding when the setting changed (a slow runner) may land later, but none is decoded twice.
        let previews = decoder.calls(.preview).map(\.url)
        XCTAssertEqual(previews.count, Set(previews).count, "no preview was decoded again")
    }

    func testADecodeRunningAcrossTheChangeIsDropped() {
        let decoder = FakeDecoder(latencyMs: [.preview: 1, .screen: 300, .full: 10])
        // No speculative full decode: on a slow runner one starts as the old screen tier lands (the dwell is over by
        // then), makes the image sharp, and no screen tier is decoded again.
        let pipeline = makePipeline(decoder) { $0.tuning.fullMaxCostMs = -1 }
        let files = makeFiles(1)
        var screens: [UInt64] = []
        pipeline.onDecoded = { file, image in if image.tier == .screen { screens.append(Trace.now()) } }
        pipeline.setFiles(files, index: 0)
        XCTAssertTrue(spin { decoder.calls(.screen).count == 1 }, "the screen decode is running")
        let changed = Trace.now()
        pipeline.redecode { _, tier in tier == .screen }
        XCTAssertTrue(spin(timeout: 3) { !screens.isEmpty })
        let calls = decoder.calls(.screen)
        XCTAssertEqual(calls.count, 2, "the old rendition was decoded again")
        XCTAssertGreaterThanOrEqual(calls.last?.start ?? 0, changed)
        XCTAssertEqual(screens.count, 1, "only the new rendition is delivered")
        XCTAssertGreaterThan(pipeline.stats.wasted, 0)
    }

    /// A change that leaves the image on screen alone keeps its full-resolution request: the full decode still queued
    /// behind the neighbours' is not dropped (nothing would ask for it again).
    func testAnUnaffectedFullResolutionRequestStays() {
        let decoder = FakeDecoder(latencyMs: [.preview: 1, .screen: 300, .full: 10])
        let pipeline = makePipeline(decoder) { $0.tuning.fullMaxCostMs = -1 }  // no speculative full decodes
        let files = makeFiles(6)
        pipeline.setFiles(files, index: 0)
        XCTAssertTrue(spin(timeout: 3) { self.has(pipeline, files[0], .screen) })
        // Both hardware lanes decode neighbours now: the full tier has to wait for one.
        XCTAssertTrue(spin { decoder.calls(.screen).count >= 3 })
        pipeline.requestFullResolution()
        pipeline.redecode { _, _ in false }
        XCTAssertTrue(spin(timeout: 3) { self.has(pipeline, files[0], .full) })
    }
}
