import AppKit
import XCTest
@testable import PeekabooApp
@testable import PeekabooCore
@testable import PeekabooRender

/// Applying a (re)loaded configuration to a running viewer.
final class ConfigReloadTests: ViewerTestCase {
    /// `app.reload_config` with no image open reports a broken config instead of "Config reloaded".
    func testReloadWithoutAnImageReportsTheError() throws {
        let viewer = try makeViewer(toml: "[view]\nbackground = \"gray\"\n")
        try Data("[keys]\n\"z\" = \"nav.nxt\"\n".utf8).write(to: root.appendingPathComponent("config.toml"))
        viewer.perform(.reloadConfig)
        let toast = try XCTUnwrap(toastText(viewer))
        XCTAssertNotEqual(toast, "Config reloaded")
        XCTAssertTrue(toast.contains("nav.nxt"), toast)
    }

    /// Skipped unknown keys are named after a reload with no image open too.
    func testReloadWithoutAnImageNamesSkippedKeys() throws {
        let viewer = try makeViewer()
        try Data("[view]\nfit = \"contain\"\n".utf8).write(to: root.appendingPathComponent("config.toml"))
        viewer.perform(.reloadConfig)
        let toast = try XCTUnwrap(toastText(viewer))
        XCTAssertTrue(toast.hasPrefix("Config reloaded · "), toast)
        XCTAssertTrue(toast.contains("view.fit"), toast)
    }

    /// A reload (for any other change) keeps the keep-zoom toggle the user set with `zoom.keep`.
    func testReloadKeepsTheKeepZoomToggle() throws {
        let viewer = try makeViewer()
        viewer.perform(.zoomKeep)
        XCTAssertTrue(renderer(viewer).keepZoom)
        var config = AppConfig.default
        config.background = "gray"
        viewer.apply(config)
        XCTAssertTrue(renderer(viewer).keepZoom, "a config reload switched keep-zoom off")
        config.keepZoom = true
        viewer.apply(config)
        viewer.perform(.zoomKeep)
        XCTAssertFalse(renderer(viewer).keepZoom)
        viewer.apply(config)
        XCTAssertFalse(renderer(viewer).keepZoom, "an unchanged keep_zoom overrode the user's toggle")
        config.keepZoom = false
        viewer.apply(config)
        XCTAssertFalse(renderer(viewer).keepZoom)
    }
}
