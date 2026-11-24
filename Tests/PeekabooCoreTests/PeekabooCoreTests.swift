import XCTest
@testable import PeekabooCore

final class PeekabooCoreTests: XCTestCase {
    func testVersion() { XCTAssertFalse(PeekabooInfo.version.isEmpty) }
}
