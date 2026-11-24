import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PeekabooCore

final class TurboJPEGTests: XCTestCase {
    /// Encode a small JPEG with ImageIO and read its header back through the static libjpeg-turbo.
    func testHeaderOfEncodedJPEG() throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let image = try XCTUnwrap(ctx.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let header = try XCTUnwrap((data as Data).withUnsafeBytes { TurboJPEG.header($0) })
        XCTAssertEqual(header.width, 64)
        XCTAssertEqual(header.height, 48)
        XCTAssertFalse(header.progressive)
    }
}
