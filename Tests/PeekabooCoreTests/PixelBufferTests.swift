import CoreGraphics
import Metal
import XCTest
@testable import PeekabooCore

final class PixelBufferTests: XCTestCase {
    private func device() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        return device
    }

    func testPoolRecyclesBuffers() throws {
        let pool = PixelBufferPool(device: try device())
        let srgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var first = pool.make(width: 1000, height: 700, layout: .bgra8, alpha: .opaque, colorSpace: srgb)
        let address = try XCTUnwrap(first).baseAddress
        XCTAssertEqual(try XCTUnwrap(first).bytesPerRow % 64, 0)
        first = nil
        XCTAssertGreaterThan(pool.pooledBytes, 0)
        let second = try XCTUnwrap(pool.make(width: 999, height: 700, layout: .bgra8, alpha: .opaque, colorSpace: srgb))
        XCTAssertEqual(second.baseAddress, address, "same size class should reuse the pooled buffer")
        XCTAssertEqual(pool.pooledBytes, 0)
    }

    func testContextDrawsIntoBufferAndTextureSeesIt() throws {
        let device = try device()
        let pool = PixelBufferPool(device: device)
        let srgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let pb = try XCTUnwrap(pool.make(width: 16, height: 16, layout: .bgra8, alpha: .premultiplied, colorSpace: srgb))
        let ctx = try XCTUnwrap(pb.makeContext())
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        XCTAssertEqual(pb.baseAddress.load(as: UInt32.self), 0xFFFF_0000)  // BGRA little-endian = 0xAARRGGBB
        let texture = try XCTUnwrap(pb.makeTexture(device: device))
        var pixel: UInt32 = 0
        texture.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        XCTAssertEqual(pixel, 0xFFFF_0000, "zero-copy texture must alias the decoded bytes")
    }

    func testARGBSwizzleMapsToRGBA() {
        let swizzle = PixelLayout.argb8.metalSwizzle
        XCTAssertEqual(swizzle.red, .green)
        XCTAssertEqual(swizzle.alpha, .red)
    }
}
