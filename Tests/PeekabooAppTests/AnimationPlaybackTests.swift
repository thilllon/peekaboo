import AppKit
import ImageIO
import XCTest
@testable import PeekabooApp
@testable import PeekabooCore
@testable import PeekabooRender

/// The viewer plays the animation on screen: frames step with `view.frame_next` / `view.frame_prev` (pausing),
/// `view.play_pause` toggles, the HUD shows the frame, and navigating away ends playback. Stills never get a player.
/// (Frames advancing on the display link need an awake display: the headless pacing is in `AnimationTests` and
/// `peekaboo-bench anim`.)
final class AnimationPlaybackTests: ViewerTestCase {
    /// Four 96×64 frames: red, green, blue, white, 100 ms each, looping.
    private func writeGIF(_ url: URL) throws -> URL {
        let colours: [(CGFloat, CGFloat, CGFloat)] = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 1)]
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, 4, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        for (r, g, b) in colours {
            let context = try XCTUnwrap(CGContext(data: nil, width: 96, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(CGColor(colorSpace: space, components: [r, g, b, 1])!)
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
                                       [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func player(_ viewer: ViewerWindowController) -> AnimationPlayer? { property(viewer, "player") }
    private func shownFrame(_ viewer: ViewerWindowController) -> Int? { property(viewer, "shownFrame") ?? nil }

    /// Red, green, blue or white: the dominant channels of the shown pixels' centre.
    private func colour(_ viewer: ViewerWindowController) -> String {
        guard let image = renderer(viewer).image else { return "-" }
        let px = image.pixels
        let p = px.baseAddress.advanced(by: px.height / 2 * px.bytesPerRow + px.width / 2 * 4).assumingMemoryBound(to: UInt8.self)
        let (r, g, b): (UInt8, UInt8, UInt8) = px.layout == .bgra8 ? (p[2], p[1], p[0]) : px.layout == .argb8 ? (p[1], p[2], p[3]) : (p[0], p[1], p[2])
        switch (r > 128, g > 128, b > 128) {
        case (true, false, false): return "red"
        case (false, true, false): return "green"
        case (false, false, true): return "blue"
        case (true, true, true): return "white"
        default: return "?"
        }
    }

    func testStepPlayPauseHUDAndNavigatingAway() throws {
        let gif = try writeGIF(folder.appendingPathComponent("a.gif"))
        writeImage(folder.appendingPathComponent("b.jpg"), width: 640, height: 480, gray: 0.5)
        let viewer = try makeViewer(toml: "[hud]\nmode = \"full\"\n")
        openAndWait(viewer, [gif])
        let visible = viewer.window?.occlusionState.contains(.visible) ?? false
        if visible {
            XCTAssertTrue(spin(5) { self.player(viewer)?.timing != nil }, "an animation on screen plays")
        } else {
            XCTAssertNil(player(viewer), "a hidden window (locked screen) plays nothing until it is visible")
        }
        // A step starts the player in any case.
        viewer.perform(.frameNext)
        let p = try XCTUnwrap(player(viewer))
        XCTAssertEqual(p.frameCount, 4)
        XCTAssertTrue(spin(5) { self.shownFrame(viewer) == (visible ? p.index : 1) && self.shownFrame(viewer) != nil })
        XCTAssertFalse(p.isPlaying, "stepping pauses")
        // Step to a known frame: frame 1 (green).
        while p.index != 1 { viewer.perform(.frameNext) }
        XCTAssertTrue(spin(5) { self.shownFrame(viewer) == 1 })
        XCTAssertEqual(colour(viewer), "green")
        XCTAssertEqual(viewer.shownTierForTests, .full)
        let rows: HUDContent? = property(hud(viewer), "content")
        XCTAssertTrue(rows?.details.contains { $0.label == "Frame" && $0.value == "2/4 · paused" } ?? false, "\(rows?.details ?? [])")

        viewer.perform(.framePrevious)
        viewer.perform(.framePrevious)
        XCTAssertTrue(spin(5) { self.shownFrame(viewer) == 3 }, "wraps to the last frame")
        XCTAssertEqual(colour(viewer), "white")

        viewer.perform(.playPause)
        XCTAssertTrue(p.isPlaying || property(viewer, "pausedWhileHidden") == true, "play (or paused while the window is hidden)")
        if p.isPlaying { XCTAssertTrue(renderer(viewer).isAnimating, "vsync-aligned presents while playing") }
        viewer.perform(.playPause)
        XCTAssertFalse(p.isPlaying)

        viewer.perform(.next)
        XCTAssertTrue(spin(5) { viewer.displayedFile?.name == "b.jpg" })
        XCTAssertNil(player(viewer), "navigating away ends playback")
        XCTAssertFalse(renderer(viewer).isAnimating)
        XCTAssertEqual(p.residentBytes, 0, "its frames are released")
        viewer.perform(.playPause)
        XCTAssertEqual(toastText(viewer), "Not an animation")
    }

    /// `view.play_pause` on an animation whose player has not started (hidden window, a skim just ended on it) plays it.
    func testPlayStartsAnAnimationThatHasNotStarted() throws {
        let gif = try writeGIF(folder.appendingPathComponent("a.gif"))
        let viewer = try makeViewer()
        openAndWait(viewer, [gif])
        guard player(viewer) == nil else { throw XCTSkip("the window is visible: the animation started on its own") }
        viewer.perform(.playPause)
        XCTAssertEqual(player(viewer)?.isPlaying, true)
        XCTAssertEqual(toastText(viewer), "Playing")
        viewer.perform(.playPause)
        XCTAssertEqual(player(viewer)?.isPlaying, false)
    }

    func testStillsNeverGetAPlayer() throws {
        let urls = writeSequence(4, width: 320, height: 240)
        let viewer = try makeViewer()
        openAndWait(viewer, [urls[0]])
        for _ in 0..<3 {
            viewer.perform(.next)
            spin(0.1)
            XCTAssertNil(player(viewer))
        }
    }
}
