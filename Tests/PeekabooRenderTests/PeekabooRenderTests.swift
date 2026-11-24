import XCTest
@testable import PeekabooRender

final class PeekabooRenderTests: XCTestCase {
    func testMetalDeviceAvailable() { XCTAssertNotNil(PeekabooRenderInfo.defaultDevice()) }
}
