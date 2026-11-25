import CoreGraphics
import Metal
import XCTest
@testable import PeekabooApp
@testable import PeekabooCore

/// Which decoded tier replaces the one on screen once early renditions (`DecodedImage.isApproximate`) exist.
final class EarlyRenditionDisplayTests: XCTestCase {
    func testExactTierReplacesItsEarlyRendition() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let pool = PixelBufferPool(device: device)
        func image(_ tier: Tier, approximate: Bool) throws -> DecodedImage {
            let pixels = try XCTUnwrap(pool.make(width: 8, height: 8, layout: .bgra8, alpha: .opaque,
                                                 colorSpace: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))))
            return DecodedImage(pixels: pixels, tier: tier, fullWidth: 64, fullHeight: 64, orientation: .up, isHDR: false,
                                decodeNanos: 1, isApproximate: approximate)
        }
        let improves = ViewerWindowController.improves
        XCTAssertTrue(improves(try image(.screen, approximate: true), .preview, false), "an early screen tier beats a preview")
        XCTAssertTrue(improves(try image(.screen, approximate: false), .screen, true), "the exact tier replaces its rendition")
        XCTAssertFalse(improves(try image(.screen, approximate: true), .screen, false), "never the other way round")
        XCTAssertFalse(improves(try image(.screen, approximate: true), .screen, true))
        XCTAssertFalse(improves(try image(.screen, approximate: false), .screen, false))
        XCTAssertTrue(improves(try image(.full, approximate: true), .screen, false), "zoomed in: an early full tier beats the screen tier")
        XCTAssertFalse(improves(try image(.screen, approximate: false), .full, true), "a lower tier never replaces a higher one")
        XCTAssertFalse(improves(try image(.preview, approximate: false), .screen, true))
    }
}
