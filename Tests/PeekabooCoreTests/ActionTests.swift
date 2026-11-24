import XCTest
@testable import PeekabooCore

final class ActionTests: XCTestCase {
    func testSimpleIDsRoundTrip() throws {
        for id in Action.simpleIDs {
            let action = try XCTUnwrap(Action(id: id), id)
            XCTAssertEqual(action.id, id)
        }
    }

    func testArgumentIDs() {
        XCTAssertEqual(Action(id: "nav.jump:+10"), .jump(10))
        XCTAssertEqual(Action(id: "nav.jump:-10"), .jump(-10))
        XCTAssertEqual(Action(id: "zoom.set:2"), .zoomSet(2))
        XCTAssertEqual(Action(id: "pan.edge:top"), .panEdge(.top))
        XCTAssertEqual(Action(id: "file.move:keep"), .move("keep"))
        XCTAssertEqual(Action(id: "file.copy:~/Pictures/Best"), .copy("~/Pictures/Best"))
        XCTAssertEqual(Action(id: "file.open_with:com.apple.Preview"), .openWith("com.apple.Preview"))
        XCTAssertEqual(Action(id: "meta.rate:3"), .rate(3))
        XCTAssertEqual(Action(id: "meta.label:red"), .label("red"))
        XCTAssertEqual(Action(id: "meta.flag:pick"), .flag("pick"))
        XCTAssertEqual(Action(id: "exec:open -R {path}"), .exec("open -R {path}"))
        for action in [Action.jump(10), .jump(-3), .zoomSet(2), .zoomSet(0.5), .move("1"), .rate(0), .exec("x {path}")] {
            XCTAssertEqual(Action(id: action.id), action, action.id)
        }
    }

    func testRejectsInvalidIDs() {
        for bad in ["bogus", "nav.jump:0", "nav.jump:x", "zoom.set:-1", "zoom.set:0", "file.move:", "meta.rate:6",
                    "meta.label:pink", "meta.flag:maybe", "pan.edge:middle", "exec:", "exec:   "] {
            XCTAssertNil(Action(id: bad), bad)
        }
    }

    func testOrientedSize() {
        let info = ImageInfo(pixelWidth: 4000, pixelHeight: 3000, orientation: .right, typeIdentifier: "public.jpeg",
                             hasAlpha: false, hasGainMap: false, frameCount: 1, colorProfileName: nil, exif: [:])
        XCTAssertTrue(info.swapsAxes)
        XCTAssertEqual(info.orientedWidth, 3000)
        XCTAssertEqual(info.orientedHeight, 4000)
    }
}

final class ImageFileTests: XCTestCase {
    func testIdentityIsTheURL() {
        let url = URL(fileURLWithPath: "/tmp/a.jpg")
        let early = ImageFile(url: url, name: "a.jpg", byteSize: 0, modified: 0, fileID: 0)
        let listed = ImageFile(url: url, name: "a.jpg", byteSize: 123, modified: 99, fileID: 7)
        XCTAssertEqual(early, listed)
        XCTAssertEqual(Set([early, listed]).count, 1)
        XCTAssertNotEqual(early.version, listed.version)
    }
}
