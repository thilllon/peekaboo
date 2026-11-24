import CoreGraphics
import Metal
import XCTest
@testable import PeekabooCore

final class PixelBufferTests: XCTestCase {
    func testPoolRecyclesBuffers() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let pool = PixelBufferPool(device: device)
        let srgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var first: PixelBuffer? = pool.make(width: 1000, height: 700, format: .bgra8, colorSpace: srgb)
        let address = try XCTUnwrap(first).baseAddress
        XCTAssertEqual(try XCTUnwrap(first).bytesPerRow % 64, 0)
        first = nil
        XCTAssertGreaterThan(pool.pooledBytes, 0)
        let second = try XCTUnwrap(pool.make(width: 999, height: 700, format: .bgra8, colorSpace: srgb))
        XCTAssertEqual(second.baseAddress, address, "same size class should reuse the pooled buffer")
        XCTAssertEqual(pool.pooledBytes, 0)
    }

    func testContextDrawsIntoBuffer() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let pool = PixelBufferPool(device: device)
        let srgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let pb = try XCTUnwrap(pool.make(width: 16, height: 16, format: .bgra8, colorSpace: srgb))
        let ctx = try XCTUnwrap(pb.makeContext())
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let px = pb.baseAddress.load(as: UInt32.self)  // BGRA little-endian → 0xAARRGGBB
        XCTAssertEqual(px, 0xFFFF_0000)
    }
}
