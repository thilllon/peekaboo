import CoreGraphics
import Metal
import QuartzCore
import XCTest
@testable import PeekabooCore
@testable import PeekabooRender

/// `Renderer.setFrame`: animation frames keep the view, never evict prepared neighbours, and build no pyramid while
/// playing (a view that would read one draws bilinear from level 0) until playback pauses on a frame.
final class AnimationFrameTests: XCTestCase {
    private var pool: PixelBufferPool!

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        pool = PixelBufferPool(device: device)
    }

    private func image(_ w: Int, _ h: Int, shade: UInt8) -> DecodedImage {
        let pixels = pool.make(width: w, height: h, layout: .bgra8, alpha: .opaque,
                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
        let base = pixels.baseAddress.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            for x in 0..<w {
                let o = y * pixels.bytesPerRow + x * 4
                base[o] = shade; base[o + 1] = UInt8((x * 255) / max(w - 1, 1)); base[o + 2] = UInt8((y * 255) / max(h - 1, 1)); base[o + 3] = 255
            }
        }
        return DecodedImage(pixels: pixels, tier: .full, fullWidth: w, fullHeight: h, orientation: .up, isHDR: false, decodeNanos: 0)
    }

    private func spin(_ seconds: TimeInterval = 5, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
        return condition()
    }

    private func renderer(_ w: Int, _ h: Int) -> Renderer {
        let r = Renderer(layer: CAMetalLayer(), monitorsMemoryPressure: false)
        r.setViewSize(CGSize(width: w, height: h), backingScale: 1)
        return r
    }

    func testFramesKeepTheViewAndThePreparedNeighbours() {
        let r = renderer(200, 150)
        let still = image(400, 300, shade: 10)
        let neighbour = image(400, 300, shade: 200)
        r.setImage(still, key: "anim")
        r.prepare(neighbour)
        XCTAssertTrue(spin { r.isPyramidComplete(for: neighbour) })
        r.setZoom(.scale(2))
        r.rotate(clockwise: true)
        for shade in [20, 30, 40, 50, 60] as [UInt8] {
            r.setFrame(image(400, 300, shade: shade), playing: true)
            _ = r.renderOffscreen(format: .bgra8Unorm)
        }
        XCTAssertEqual(r.effectiveScale, 2, "zoom kept")
        XCTAssertEqual(r.quarterTurns, 1, "rotation kept")
        XCTAssertTrue(r.isPyramidComplete(for: neighbour), "the prepared neighbour is still known (not evicted by frames)")
        r.setImage(neighbour, key: "next")
        _ = r.renderOffscreen(format: .bgra8Unorm)
        XCTAssertEqual(r.lastPath, "canvas")
        XCTAssertFalse(r.lastFrameRasterised, "the neighbour's prepared fit canvas survived playback")
    }

    func testPlayingFramesBuildNoPyramidUntilPaused() {
        // A 1024 px frame in a 200 px view reads pyramid level 2 at fit.
        let r = renderer(200, 150)
        r.setImage(image(1024, 768, shade: 0), key: "anim")
        let frame = image(1024, 768, shade: 90)
        r.setFrame(frame, playing: true)
        _ = r.renderOffscreen(format: .bgra8Unorm)
        XCTAssertEqual(r.lastPath, "trilinear", "bilinear from level 0 while playing")
        XCTAssertFalse(spin(0.2) { r.isPyramidComplete(for: frame) }, "no pyramid while playing")
        r.setFrame(frame, playing: false)
        XCTAssertTrue(spin { r.isPyramidComplete(for: frame) }, "paused: the pyramid builds")
        _ = r.renderOffscreen(format: .bgra8Unorm)
        XCTAssertEqual(r.lastPath, "canvas", "paused: the high-quality path")
        XCTAssertTrue(r.lastFrameRasterised)
    }

    /// Below half-size views only: an enlarged frame takes the level-0 canvas while playing.
    func testEnlargedFramesUseTheLevelZeroCanvasWhilePlaying() {
        let r = renderer(800, 600)
        r.setImage(image(300, 200, shade: 0), key: "anim")
        r.setFrame(image(300, 200, shade: 50), playing: true)
        _ = r.renderOffscreen(format: .bgra8Unorm)
        XCTAssertEqual(r.lastPath, "canvas")
        let second = image(300, 200, shade: 150)
        r.setFrame(second, playing: true)
        let texture = r.renderOffscreen(format: .bgra8Unorm)
        XCTAssertTrue(r.lastFrameRasterised, "each frame is rasterised: the previous frame's canvas is not reused")
        var px = [UInt8](repeating: 0, count: 4)
        texture?.getBytes(&px, bytesPerRow: 4 * 800, from: MTLRegionMake2D(400, 300, 1, 1), mipmapLevel: 0)
        XCTAssertGreaterThan(Int(px[0]), 100, "the new frame's blue channel is on screen")
    }
}
