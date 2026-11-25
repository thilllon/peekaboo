import CoreGraphics
import XCTest
@testable import PeekabooCore

/// Hands an approximate rendition of every screen and full tier to the sink when it is wanted (as `ImageIODecoder`
/// does for progressive JPEGs), then decodes the exact tier like `FakeDecoder`.
final class PartialDecoder: ImageDecoder, @unchecked Sendable {
    let exact = FakeDecoder(latencyMs: [.preview: 2, .screen: 60, .full: 80])
    private let lock = NSLock()
    private var _asked: [(URL, Tier, Bool)] = []

    /// Every sink consulted: file, tier, and whether it wanted a rendition.
    var asked: [(URL, Tier, Bool)] { lock.lock(); defer { lock.unlock() }; return _asked }

    func probe(_ url: URL) throws -> ImageInfo { try exact.probe(url) }

    func decode(_ url: URL, tier: Tier, targetLongSide: Int, pool: PixelBufferPool) throws -> DecodedImage {
        try exact.decode(url, tier: tier, targetLongSide: targetLongSide, pool: pool)
    }

    func decode(_ url: URL, tier: Tier, targetLongSide: Int, pool: PixelBufferPool, partial: PartialSink?) throws
        -> DecodedImage {
        if let partial {
            let wanted = partial.wanted()
            lock.lock(); _asked.append((url, tier, wanted)); lock.unlock()
            if wanted, let pixels = pool.make(width: 128, height: 96, layout: .bgra8, alpha: .opaque,
                                              colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) {
                partial.deliver(DecodedImage(pixels: pixels, tier: tier, fullWidth: exact.fullWidth, fullHeight: exact.fullHeight,
                                             orientation: .up, isHDR: false, decodeNanos: 1, isApproximate: true))
            }
        }
        return try exact.decode(url, tier: tier, targetLongSide: targetLongSide, pool: pool)
    }

    func lane(for url: URL, info: ImageInfo?, tier: Tier) -> DecodeLane { exact.lane(for: url, info: info, tier: tier) }
}

final class PipelinePartialTests: PipelineTestCase {
    /// The current image shows the early rendition while its screen tier decodes; the exact tier replaces it in the
    /// cache and on screen. Prefetched neighbours never pay for one.
    func testEarlyRenditionIsShownNotCachedAndOnlyForTheCurrentImage() {
        let decoder = PartialDecoder()
        let pipeline = makePipeline(decoder)
        let files = makeFiles(6)
        var arrivals: [(ImageFile, Tier, Bool)] = []
        pipeline.onDecoded = { file, image in arrivals.append((file, image.tier, image.isApproximate)) }
        pipeline.setFiles(files, index: 0)
        XCTAssertTrue(spin { self.has(pipeline, files[0], .screen) })
        XCTAssertTrue(spin { self.has(pipeline, files[1], .screen) && self.has(pipeline, files[2], .screen) })

        let first = arrivals.filter { $0.0 == files[0] }
        let early = first.firstIndex { $0.1 == .screen && $0.2 }
        let exact = first.firstIndex { $0.1 == .screen && !$0.2 }
        XCTAssertNotNil(early, "the early rendition reached the view")
        XCTAssertNotNil(exact)
        if let early, let exact { XCTAssertLessThan(early, exact, "and before the exact tier") }
        XCTAssertEqual(pipeline.best(for: files[0])?.isApproximate, false, "only the exact tier is cached")
        XCTAssertEqual(pipeline.stats.partials, 1)

        XCTAssertFalse(arrivals.contains { $0.0 != files[0] && $0.2 }, "no early rendition for a neighbour")
        let neighbours = decoder.asked.filter { $0.0 != files[0].url }
        XCTAssertFalse(neighbours.isEmpty)
        XCTAssertFalse(neighbours.contains { $0.2 }, "prefetch decodes are told not to make one")
        XCTAssertFalse(decoder.asked.contains { $0.1 == .preview }, "previews are never asked")
    }

    /// Zooming in: the full tier's decode also hands over an early rendition, which the view shows over the screen tier.
    func testFullResolutionRequestGetsAnEarlyRendition() {
        let decoder = PartialDecoder()
        let pipeline = makePipeline(decoder)
        let files = makeFiles(3)
        var arrivals: [(Tier, Bool)] = []
        pipeline.onDecoded = { file, image in if file == files[0] { arrivals.append((image.tier, image.isApproximate)) } }
        pipeline.setFiles(files, index: 0)
        XCTAssertTrue(spin { self.has(pipeline, files[0], .screen) })
        pipeline.requestFullResolution()
        XCTAssertTrue(spin { self.has(pipeline, files[0], .full) })
        XCTAssertTrue(arrivals.contains { $0 == (.full, true) })
        XCTAssertEqual(arrivals.last.map { $0.0 }, .full)
        XCTAssertEqual(arrivals.last.map { $0.1 }, false)
        XCTAssertEqual(pipeline.best(for: files[0])?.isApproximate, false)
    }

    /// The app decodes the file it opens before its folder is listed (a placeholder without size or date); the listing
    /// lands during that decode (~80 ms, the rendition takes 40–150 ms). The rendition is still shown.
    func testEarlyRenditionOfTheOpenedFileSurvivesTheListing() {
        let decoder = PartialDecoder()
        let pipeline = makePipeline(decoder)
        let files = makeFiles(6)
        let opened = ImageFile(url: files[2].url, name: files[2].name, byteSize: 0, modified: 0, fileID: 0)
        var approximate: [ImageFile] = []
        pipeline.onDecoded = { file, image in if image.isApproximate { approximate.append(file) } }
        pipeline.setFiles([opened], index: 0)
        // The worker hands over the rendition of the placeholder's decode; the main thread lists the folder before its
        // run loop turns (deliveries wait for it).
        let deadline = Date().addingTimeInterval(3)
        while !decoder.asked.contains(where: { $0.0 == opened.url && $0.1 == .screen }) && Date() < deadline { usleep(1000) }
        pipeline.setFiles(files, index: 2)
        XCTAssertTrue(spin { self.has(pipeline, files[2], .screen) })
        XCTAssertEqual(approximate, [files[2]], "the early rendition of the opened file was dropped")
    }

    /// A rendition that arrives after the user moved on is dropped (deliveries reach the main thread only when its run
    /// loop turns, after the jump here).
    func testEarlyRenditionOfAnImageLeftBehindIsDropped() {
        let decoder = PartialDecoder()
        decoder.exact.latencyMs[.screen] = 150
        let pipeline = makePipeline(decoder)
        let files = makeFiles(40)
        var approximate: [ImageFile] = []
        pipeline.onDecoded = { file, image in if image.isApproximate { approximate.append(file) } }
        pipeline.setFiles(files, index: 0)
        pipeline.navigate(to: 30, isRepeat: false)
        XCTAssertTrue(spin { self.has(pipeline, files[30], .screen) })
        XCTAssertEqual(approximate, [files[30]])
    }
}
