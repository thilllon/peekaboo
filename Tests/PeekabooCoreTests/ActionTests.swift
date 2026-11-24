import XCTest
@testable import PeekabooCore

final class ActionTests: XCTestCase {
    func testSimpleIDsRoundTrip() {
        for id in Action.simpleIDs {
            let action = try! XCTUnwrap(Action(id: id), id)
            XCTAssertEqual(action.id, id)
        }
    }

    func testParameterisedIDs() {
        XCTAssertEqual(Action(id: "nav.forward:10"), .forward(10))
        XCTAssertEqual(Action(id: "file.move:~/Pictures/Keep"), .moveTo("~/Pictures/Keep"))
        XCTAssertEqual(Action(id: "file.open-with:Pixelmator Pro"), .openWith("Pixelmator Pro"))
        XCTAssertEqual(Action.copyTo("/tmp/x").id, "file.copy:/tmp/x")
        XCTAssertNil(Action(id: "nav.forward:0"))
        XCTAssertNil(Action(id: "file.move:"))
        XCTAssertNil(Action(id: "bogus"))
    }

    func testOrientedSize() {
        let info = ImageInfo(pixelWidth: 4000, pixelHeight: 3000, orientation: .right, typeIdentifier: "public.jpeg",
                             hasAlpha: false, hasGainMap: false, frameCount: 1, colorProfileName: nil, exif: [:])
        XCTAssertTrue(info.swapsAxes)
        XCTAssertEqual(info.orientedWidth, 3000)
        XCTAssertEqual(info.orientedHeight, 4000)
    }
}
