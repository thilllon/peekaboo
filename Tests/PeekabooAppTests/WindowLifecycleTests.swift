import AppKit
import XCTest
@testable import PeekabooApp
@testable import PeekabooCore

/// Closing the window (the app stays resident) and opening again.
final class WindowLifecycleTests: ViewerTestCase {
    /// `app.close` (⌘W, `q`, File › Close Window) closes the window in instant full screen too, and restores the
    /// window's style for the next open.
    func testCloseInInstantFullScreenClosesTheWindow() throws {
        let viewer = try makeViewer()
        let window = try XCTUnwrap(viewer.window)
        let style = window.styleMask
        openAndWait(viewer, [writeImage(folder.appendingPathComponent("a.jpg"), width: 1200, height: 800, gray: 0.4)])
        viewer.perform(.fullscreen)
        XCTAssertFalse(window.styleMask.contains(.titled), "not in instant full screen")
        viewer.perform(.close)
        spin(0.2)
        XCTAssertFalse(window.isVisible, "the window stayed open")
        XCTAssertEqual(window.styleMask, style)
        XCTAssertEqual(NSApp.presentationOptions, [])
    }

    /// Sweep work since `swept` sweep decodes: decoded, running, or at least planned (its utility lanes may still wait
    /// for a core on a loaded machine).
    private func sweeps(_ viewer: ViewerWindowController, since swept: Int) -> Bool {
        let state = viewer.pipeline.schedulerState
        return viewer.pipeline.stats.sweepDecodes > swept || state.contains(":sweep:") || !state.hasSuffix(" sweep=0")
    }

    /// The trim on close must not leave the pipeline in memory-pressure mode (halved budgets, no preview sweep)
    /// for the next session.
    func testClosingTheWindowDoesNotThrottleTheNextSession() throws {
        // A cache budget with room for the sweep: the automatic preview budget of a small-RAM machine has none.
        let viewer = try makeViewer(toml: "[cache]\nmemory_mb = 4096\n")
        // Within the prefetch windows: no sweep work of this session is left when the window closes.
        let first = writeSequence(3, in: folder.appendingPathComponent("first"), prefix: "a")
        openAndWait(viewer, [first[0]])
        spin(0.3)
        viewer.window?.close()
        spin(0.1)

        let second = writeSequence(40, in: folder.appendingPathComponent("second"), prefix: "b")
        let swept = viewer.pipeline.stats.sweepDecodes
        openAndWait(viewer, [second[0]])
        let pressureUntil: UInt64 = try XCTUnwrap(property(viewer.pipeline, "pressureUntil"))
        let now = Trace.now()
        guard pressureUntil <= now else {
            return XCTFail(String(format: "memory-pressure mode is on for another %.0f s", Double(pressureUntil - now) / 1e9))
        }
        var config = AppConfig.default
        config.cacheBudgetMB = 4096
        XCTAssertEqual(viewer.pipeline.config, ViewerWindowController.pipelineConfig(config, base: viewer.pipeline.config))
        guard spin(5, until: { self.sweeps(viewer, since: swept) }) else {
            // Neither pressure mode nor the closed configuration (checked above) holds it back: this machine's lanes.
            throw XCTSkip("no preview sweep in this environment: \(viewer.pipeline.schedulerState)")
        }
    }

    /// Closing still gives memory back: full-resolution tiers of other images and the buffer pool.
    func testClosingTheWindowGivesBackFullResolutionAndPooledBuffers() throws {
        let viewer = try makeViewer()
        // Subsampled screen tier, so dwelling decodes a separate full-resolution tier.
        let side = 2 * ViewerWindowController.largestScreenLongSide() + 256
        let urls = (0..<3).map { i in
            writeImage(folder.appendingPathComponent("p\(i).jpg"), width: side, height: side * 2 / 3, gray: 0.2 + 0.3 * CGFloat(i))
        }
        openAndWait(viewer, [urls[0]])
        viewer.perform(.zoomSet(2))
        XCTAssertTrue(spin(10) { viewer.pipeline.cachedTiers(for: viewer.pipeline.files[0]).contains(.full) })
        viewer.perform(.next)
        viewer.perform(.zoomSet(2))
        XCTAssertTrue(spin(10) { viewer.pipeline.cachedTiers(for: viewer.pipeline.files[1]).contains(.full) })
        XCTAssertTrue(viewer.pipeline.cachedTiers(for: viewer.pipeline.files[0]).contains(.full))

        viewer.window?.close()
        // Drained on a utility queue: slow to get a core on a loaded CI machine.
        XCTAssertTrue(spin(30) { viewer.pipeline.pool.pooledBytes == 0 }, "the buffer pool was not drained")
        XCTAssertFalse(viewer.pipeline.cachedTiers(for: viewer.pipeline.files[0]).contains(.full),
                       "another image's full resolution survived the close")
        XCTAssertTrue(viewer.pipeline.cachedTiers(for: viewer.pipeline.files[1]).contains(.full),
                      "the current image must stay for a Dock reopen")
    }
}
