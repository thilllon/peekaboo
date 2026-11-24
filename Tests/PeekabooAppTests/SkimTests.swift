import AppKit
import XCTest
@testable import PeekabooApp
@testable import PeekabooCore
@testable import PeekabooRender

/// Key auto-repeat navigation (skimming) and what follows it.
final class SkimTests: ViewerTestCase {
    /// A neighbour whose sharp tier was cached before the skim gets its fit canvas once the skim ends, so the
    /// first step afterwards is a present-only frame.
    func testNeighboursArePreparedOnceSkimmingEnds() throws {
        let viewer = try makeViewer()
        // Larger than the window (the fit view is a reduction), small enough that the screen tier is the whole image.
        let urls = writeSequence(12, width: 3000, height: 2000)
        openAndWait(viewer, [urls[0]])
        spin(0.6)
        // Two steps 400 ms apart: the screen window reaches three images ahead of img02.
        for _ in 0..<2 {
            viewer.perform(.next)
            spin(0.4)
        }
        let ahead = viewer.pipeline.files[3...5]
        XCTAssertTrue(spin(5) { ahead.allSatisfy { viewer.pipeline.cachedTiers(for: $0).contains(.screen) } },
                      "the screen window was not prefetched")

        // Hold →: two auto-repeats 33 ms apart (img03, img04), then key-up. img05 was cached at img02, where it was
        // not a neighbour to prepare.
        for _ in 0..<2 {
            viewer.perform(.next, isRepeat: true)
            spin(0.033)
        }
        XCTAssertEqual(viewer.pipeline.index, 4)
        XCTAssertTrue(spin(3) { viewer.displayedFile?.name == "img04.jpg" && viewer.shownTierForTests == .screen })
        spin(0.8)  // dwell: the skim is over

        viewer.perform(.next)
        XCTAssertEqual(viewer.displayedFile?.name, "img05.jpg")
        XCTAssertEqual(renderer(viewer).lastPath, "canvas")
        XCTAssertFalse(renderer(viewer).lastFrameRasterised, "the first frame after the skim ran a resampling pass")
    }
}
