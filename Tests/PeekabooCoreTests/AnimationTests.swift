import Metal
import XCTest
@testable import PeekabooCore

/// Animated GIF / APNG / WebP: ImageIO's composited frames against the pixels the hand-made files must produce
/// (disposal none / background / previous, blending, transparency), frame delays with browser clamping, loop counts,
/// and the player's scheduling and memory bounds on a synthetic clock.
final class AnimationTests: XCTestCase {
    private var dir: URL!
    private var pool: PixelBufferPool!

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        pool = PixelBufferPool(device: device)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("peekaboo-anim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// Each pixel as R G B W K (opaque) or . (alpha < 50 %), rows separated by spaces.
    private func grid(_ pb: PixelBuffer) -> String {
        var rows: [String] = []
        for y in 0..<pb.height {
            var row = ""
            for x in 0..<pb.width {
                let p = pb.baseAddress.advanced(by: y * pb.bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
                let (r, g, b, a): (Int, Int, Int, Int)
                switch pb.layout {
                case .bgra8: (r, g, b, a) = (Int(p[2]), Int(p[1]), Int(p[0]), Int(p[3]))
                case .argb8: (r, g, b, a) = (Int(p[1]), Int(p[2]), Int(p[3]), Int(p[0]))
                default: (r, g, b, a) = (Int(p[0]), Int(p[1]), Int(p[2]), Int(p[3]))
                }
                let opaque = pb.alpha == .opaque || a >= 128
                if !opaque { row += "."; continue }
                switch (r > 200, g > 200, b > 200) {
                case (true, true, true): row += "W"
                case (true, false, false): row += "R"
                case (false, true, false): row += "G"
                case (false, false, true): row += "B"
                case (false, false, false): row += "K"
                default: row += "?"
                }
            }
            rows.append(row)
        }
        return rows.joined(separator: " ")
    }

    private func frames(_ url: URL) throws -> (AnimationDecoder, [String], [PixelBuffer]) {
        let info = try ImageIODecoder().probe(url)
        XCTAssertTrue(info.isAnimated, url.lastPathComponent)
        let decoder = try AnimationDecoder(url: url, info: info)
        let buffers = try (0..<decoder.frameCount).map { try decoder.frame($0, pool: pool) }
        return (decoder, buffers.map(grid), buffers)
    }

    // MARK: Timing

    func testDelayClampFollowsBrowsers() {
        XCTAssertEqual(AnimationTiming.clamp(nil), 0.1)
        XCTAssertEqual(AnimationTiming.clamp(0), 0.1)
        XCTAssertEqual(AnimationTiming.clamp(0.01), 0.1, "10 ms plays as 100 ms")
        XCTAssertEqual(AnimationTiming.clamp(0.011), 0.011)
        XCTAssertEqual(AnimationTiming.clamp(0.05), 0.05)
        XCTAssertEqual(AnimationTiming.clamp(-1), 0.1)
        XCTAssertEqual(AnimationTiming.clamp(.nan), 0.1)
        XCTAssertEqual(AnimationTiming.clamp(.infinity), 0.1)
    }

    func testOnlyAnimationFormatsAnimate() {
        func info(_ type: String, _ frames: Int) -> ImageInfo {
            ImageInfo(pixelWidth: 8, pixelHeight: 8, orientation: .up, typeIdentifier: type, hasAlpha: false, hasGainMap: false,
                      frameCount: frames, colorProfileName: nil, exif: [:])
        }
        for type in ["com.compuserve.gif", "public.png", "org.webmproject.webp", "public.heics", "public.avis"] {
            XCTAssertTrue(info(type, 2).isAnimated, type)
            XCTAssertFalse(info(type, 1).isAnimated, type)
        }
        // Multi-image stills: HEIC collections (dynamic wallpapers), TIFF pages, ICO sizes.
        for type in ["public.heic", "public.tiff", "com.microsoft.ico", "public.jpeg"] {
            XCTAssertFalse(info(type, 4).isAnimated, type)
        }
    }

    // MARK: Composited frames

    /// ImageIO composites GIF frames; it declares the last one opaque although "restore to background" left its
    /// top-left transparent (the fourth byte is 0 there): the decoder honours that byte.
    func testGIFDisposalTransparencyDelaysAndLoops() throws {
        let (decoder, grids, buffers) = try frames(try file("dispose.gif", AnimationFixtures.gif(loopCount: 3)))
        XCTAssertEqual(decoder.timing.delays, [0.1, 0.1, 0.05, 0.2], "0 and 1 cs play as 100 ms")
        XCTAssertEqual(decoder.timing.loopCount, 4, "NETSCAPE repeats 3 times: 4 plays")
        XCTAssertEqual(grids[0], Array(repeating: "RRRRRRRR", count: 8).joined(separator: " "))
        XCTAssertEqual(grids[1], "BBBBRRRR BBBBRRRR BBBBRRRR BBBBRRRR RRRRRRRR RRRRRRRR RRRRRRRR RRRRRRRR")
        XCTAssertEqual(grids[2], "....RRRR ....RRRR ....RRRR ....RRRR RRRRGRGR RRRRGRGR RRRRGRGR RRRRGRGR",
                       "background disposal clears to transparent; transparent pixels show the frame below")
        XCTAssertEqual(grids[3], "....RRRR ....RRRR ..WWRRRR ..WWRRRR RRRRRRRR RRRRRRRR RRRRRRRR RRRRRRRR",
                       "restore to previous; the transparent corner stays transparent")
        XCTAssertNotEqual(buffers[3].alpha, .opaque)
        XCTAssertEqual(try AnimationDecoder(url: try file("once.gif", AnimationFixtures.gif(loopCount: nil)),
                                            info: try ImageIODecoder().probe(dir.appendingPathComponent("once.gif"))).timing.loopCount,
                       1, "no NETSCAPE extension: one play")
        let forever = try file("forever.gif", AnimationFixtures.gif(loopCount: 0))
        XCTAssertEqual(try AnimationDecoder(url: forever, info: try ImageIODecoder().probe(forever)).timing.loopCount, 0)
    }

    func testAPNGDisposeAndBlend() throws {
        let url = try file("dispose.png", AnimationFixtures.apng(plays: 2))
        let (decoder, grids, _) = try frames(url)
        XCTAssertEqual(try ImageIODecoder().probe(url).typeIdentifier, "public.png")
        XCTAssertEqual(decoder.timing.delays, [0.1, 0.1, 0.05, 0.2], "ImageIO clamps APNG at 50 ms; we clamp like browsers")
        XCTAssertEqual(decoder.timing.loopCount, 2)
        XCTAssertEqual(grids[1], "BBBBRRRR BBBBRRRR BBBBRRRR BBBBRRRR RRRRRRRR RRRRRRRR RRRRRRRR RRRRRRRR")
        XCTAssertEqual(grids[2], "....RRRR ....RRRR ....RRRR ....RRRR RRRRGRGR RRRRGRGR RRRRGRGR RRRRGRGR")
        XCTAssertEqual(grids[3], "....RRRR ....RRRR ..WWRRRR ..WWRRRR RRRRRRRR RRRRRRRR RRRRRRRR RRRRRRRR")
        // `.apng` is listed and decoded by content.
        let renamed = try file("dispose.apng", AnimationFixtures.apng(plays: 2))
        XCTAssertTrue(FolderScanner.isSupported(renamed))
        XCTAssertTrue(try ImageIODecoder().probe(renamed).isAnimated)
    }

    func testAnimatedWebPDisposeAndBlend() throws {
        let (decoder, grids, _) = try frames(try file("dispose.webp", AnimationFixtures.webp))
        XCTAssertEqual(decoder.timing.delays, [0.1, 0.1, 0.05, 0.2])
        XCTAssertEqual(decoder.timing.loopCount, 3)
        let red = String(repeating: "R", count: 16)
        XCTAssertEqual(grids[0], Array(repeating: red, count: 16).joined(separator: " "))
        let top2 = Array(repeating: "........RRRRRRRR", count: 8)
        let bottom = (0..<8).map { $0 % 2 == 0 ? "RRRRRRRRGRGRGRGR" : "RRRRRRRRRGRGRGRG" }
        XCTAssertEqual(grids[2], (top2 + bottom).joined(separator: " "), "background disposal, then a blended frame")
        let top3 = Array(repeating: "........RRRRRRRR", count: 4) + Array(repeating: "....WWWWRRRRRRRR", count: 4)
        XCTAssertEqual(grids[3], (top3 + bottom).joined(separator: " "), "an unblended frame replaces what it covers")
    }

    // MARK: Player

    private func spin(until condition: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
    }

    private func player(_ name: String, _ data: Data, budget: Int = 64 << 20) throws -> AnimationPlayer {
        let url = try file(name, data)
        return AnimationPlayer(url: url, info: try ImageIODecoder().probe(url), device: pool.device, budgetBytes: budget)
    }

    func testPlayerShowsEachFrameAtItsDeadlineAndEndsAfterTheLastPlay() throws {
        let p = try player("once.gif", AnimationFixtures.gif(loopCount: nil))
        p.start(at: 0)
        spin { p.timing != nil && (1..<4).allSatisfy { p.frame($0) != nil } }
        XCTAssertTrue(p.keepsAllFrames)
        XCTAssertNil(p.advance(to: 0.05), "frame 0 (the still) stays 100 ms")
        XCTAssertNotNil(p.advance(to: 0.1))
        XCTAssertEqual(p.index, 1)
        XCTAssertNil(p.advance(to: 0.19))
        XCTAssertNotNil(p.advance(to: 0.2))
        XCTAssertNotNil(p.advance(to: 0.25), "frame 2 lasts 50 ms")
        XCTAssertEqual(p.index, 3)
        XCTAssertEqual(p.deadline ?? 0, 0.45, accuracy: 1e-9)
        XCTAssertNil(p.advance(to: 0.45), "one play: the last frame stays")
        XCTAssertTrue(p.isFinished)
        XCTAssertFalse(p.isPlaying)
        XCTAssertEqual(p.index, 3)
        // Play after the end restarts from frame 0, which is shown at once.
        spin { p.frame(0) != nil }
        XCTAssertNotNil(p.play(at: 1))
        XCTAssertEqual(p.index, 0)
        XCTAssertEqual(p.deadline ?? 0, 1.1, accuracy: 1e-9)
        p.stop()
        XCTAssertEqual(p.residentBytes, 0)
    }

    func testPlayerToleranceShowsAFrameDueWithinHalfARefresh() throws {
        let p = try player("t.gif", AnimationFixtures.gif(loopCount: 0))
        p.start(at: 0)
        spin { p.timing != nil && p.frame(1) != nil }
        XCTAssertNil(p.advance(to: 0.09, tolerance: 0.004))
        XCTAssertNotNil(p.advance(to: 0.097, tolerance: 0.004), "due 3 ms after this refresh: shown now, not a refresh late")
        XCTAssertEqual(p.deadline ?? 0, 0.2, accuracy: 1e-9, "the timeline does not drift")
    }

    func testPlayerReanchorsAfterAStallInsteadOfCatchingUp() throws {
        let p = try player("stall.gif", AnimationFixtures.gif(loopCount: 0))
        p.start(at: 0)
        spin { p.timing != nil && (0..<4).allSatisfy { p.frame($0) != nil } }
        XCTAssertNotNil(p.advance(to: 0.5), "400 ms late")
        XCTAssertEqual(p.index, 1)
        XCTAssertEqual(p.deadline ?? 0, 0.6, accuracy: 1e-9, "re-anchored: the next frame gets its full 100 ms")
        XCTAssertNotNil(p.advance(to: 0.6))
        XCTAssertEqual(p.index, 2, "one frame per refresh, no burst")
    }

    func testStepPausesAndWraps() throws {
        let p = try player("step.gif", AnimationFixtures.gif(loopCount: 0))
        p.start(at: 0)
        spin { p.timing != nil && (0..<4).allSatisfy { p.frame($0) != nil } }
        XCTAssertNotNil(p.step(-1))
        XCTAssertEqual(p.index, 3, "frame 0 back to the last frame")
        XCTAssertFalse(p.isPlaying)
        XCTAssertNil(p.deadline)
        XCTAssertNil(p.advance(to: 10), "paused")
        XCTAssertNotNil(p.step(1))
        XCTAssertEqual(p.index, 0)
        p.play(at: 2)
        XCTAssertTrue(p.isPlaying)
        XCTAssertEqual(p.deadline ?? 0, 2.1, accuracy: 1e-9)
    }

    func testKeepAllDecodesEachFrameOnce() throws {
        let p = try player("loop.gif", AnimationFixtures.gif(loopCount: 0))
        p.start(at: 0)
        spin { p.timing != nil && (0..<4).allSatisfy { p.frame($0) != nil } }
        var t = 0.0
        for _ in 0..<8 {   // two loops
            t = p.deadline ?? t
            XCTAssertNotNil(p.advance(to: t))
        }
        spin(until: { false }, timeout: 0.05)
        XCTAssertEqual(p.decodedFrames, 4, "later loops replay kept frames")
    }

    func testWindowBoundsMemoryWhenFramesDoNotFit() throws {
        // 8×8 frames are 256 bytes as estimated; a 600-byte budget keeps a window of 2 ahead plus the shown one.
        let p = try player("window.gif", AnimationFixtures.gif(loopCount: 0), budget: 600)
        XCTAssertFalse(p.keepsAllFrames)
        p.start(at: 0)
        var t = 0.0
        for _ in 0..<10 {
            spin { p.frame((p.index + 1) % 4) != nil }
            t = p.deadline ?? t
            XCTAssertNotNil(p.advance(to: t))
            let resident = (0..<4).filter { p.frame($0) != nil }.count
            XCTAssertLessThanOrEqual(resident, 3, "frame \(p.index): \(resident) frames kept")
        }
        XCTAssertGreaterThan(p.decodedFrames, 4, "frames outside the window are decoded again")
    }
}
