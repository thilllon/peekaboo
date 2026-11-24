import AppKit
import QuartzCore
import XCTest
@testable import PeekabooApp
@testable import PeekabooCore

final class HUDTests: XCTestCase {
    private func text(_ hud: HUD, _ box: String) -> String? {
        guard let box = Mirror(reflecting: hud).children.first(where: { $0.label == box })?.value,
              let layer = Mirror(reflecting: box).children.first(where: { $0.label == "text" })?.value as? CATextLayer
        else { return nil }
        return (layer.string as? NSAttributedString)?.string
    }

    private func rows(_ n: Int) -> [HUDContent.Row] {
        [.init(label: "Camera", value: "FUJIFILM X100V"), .init(label: "Lens", value: "23 mm f/2"),
         .init(label: "Exposure", value: "23 mm  f/5.6  1/500 s  ISO 160"), .init(label: "Date", value: "2026-11-24 14:03"),
         .init(label: "Profile", value: "Display P3"), .init(label: "Format", value: "HEIC · HDR gain map"),
         .init(label: "Pixels", value: "6240×4160 (26.0 MP)"), .init(label: "Size", value: "\(n) MB"),
         .init(label: "Shown", value: "screen 3456×2304")]
    }

    /// Seconds for `count` HUD updates in full mode.
    private func time(_ hud: HUD, count: Int, rowsChange: Bool) -> Double {
        let start = Trace.now()
        for i in 0..<count {
            hud.setContent(HUDContent(line: "IMG_0042.HEIC  ·  42/120  ·  6240×4160  ·  \(i % 2 == 0 ? 50 : 51) %",
                                      details: rows(rowsChange ? i : 0)))
        }
        return Trace.ms(since: start) / 1000
    }

    /// A zoom gesture changes only the info line (its zoom %), at every event: the multi-line details box (the
    /// costly TextKit measurement) is laid out only when its rows change, or the HUD's size does.
    func testZoomUpdatesDoNotLayOutUnchangedDetails() throws {
        let hud = HUD(parent: CALayer())
        hud.layout(size: CGSize(width: 1200, height: 800), topInset: 0, scale: 2)
        hud.mode = .full
        _ = time(hud, count: 20, rowsChange: true)  // warm up fonts and TextKit
        let changing = time(hud, count: 200, rowsChange: true)
        let zoomOnly = time(hud, count: 200, rowsChange: false)
        print(String(format: "HUD update: %.1f µs with new details rows, %.1f µs for a zoom-%% change",
                     changing / 200 * 1e6, zoomOnly / 200 * 1e6))
        XCTAssertLessThan(zoomOnly, changing / 2, "unchanged details were laid out again at every update")

        // The boxes still show the latest content, also after a resize and a mode round trip.
        hud.setContent(HUDContent(line: "b.jpg  ·  2/3  ·  50 %", details: [rows(7)[7]]))
        XCTAssertEqual(text(hud, "info"), "b.jpg  ·  2/3  ·  50 %")
        XCTAssertEqual(text(hud, "details"), "Size  7 MB")
        hud.layout(size: CGSize(width: 900, height: 700), topInset: 0, scale: 2)
        hud.mode = .minimal
        hud.setContent(HUDContent(line: "c.jpg  ·  3/3  ·  50 %", details: [rows(9)[7]]))
        hud.mode = .full
        XCTAssertEqual(text(hud, "details"), "Size  9 MB")
    }
}
