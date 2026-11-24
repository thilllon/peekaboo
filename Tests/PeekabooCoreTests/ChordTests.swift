import XCTest
@testable import PeekabooCore

final class ChordTests: XCTestCase {
    private func chord(_ key: String, _ modifiers: KeyModifiers = []) -> KeyChord { KeyChord(key: key, modifiers: modifiers) }

    func testModifiersAndNamedKeys() {
        XCTAssertEqual(KeyChord(spec: "cmd+shift+k"), chord("k", [.command, .shift]))
        XCTAssertEqual(KeyChord(spec: "Shift+Cmd+K"), chord("k", [.command, .shift]))
        XCTAssertEqual(KeyChord(spec: "opt+1"), chord("1", .option))
        XCTAssertEqual(KeyChord(spec: "alt+1"), chord("1", .option))
        XCTAssertEqual(KeyChord(spec: "ctrl+cmd+f"), chord("f", [.control, .command]))
        XCTAssertEqual(KeyChord(spec: "control+option+command+x"), chord("x", [.control, .option, .command]))
        XCTAssertEqual(KeyChord(spec: "space"), chord("space"))
        XCTAssertEqual(KeyChord(spec: "Space"), chord("space"))
        XCTAssertEqual(KeyChord(spec: "enter"), chord("return"))
        XCTAssertEqual(KeyChord(spec: "escape"), chord("esc"))
        XCTAssertEqual(KeyChord(spec: "cmd+backspace"), chord("backspace", .command))
        XCTAssertEqual(KeyChord(spec: "f12"), chord("f12"))
        XCTAssertEqual(KeyChord(spec: "f20"), chord("f20"))
        XCTAssertEqual(KeyChord(spec: "kp+"), chord("kp+"))
        XCTAssertEqual(KeyChord(spec: "ctrl+kp+"), chord("kp+", .control))
        XCTAssertEqual(KeyChord(spec: "kpenter"), chord("kpenter"))
        XCTAssertEqual(KeyChord(spec: "cmd+,"), chord(",", .command))
        XCTAssertEqual(KeyChord(spec: "opt+cmd+c"), chord("c", [.option, .command]))
    }

    func testShiftedSymbolsUseTheUSTable() {
        XCTAssertEqual(KeyChord(spec: "?"), chord("/", .shift))
        XCTAssertEqual(KeyChord(spec: "G"), chord("g", .shift))
        XCTAssertEqual(KeyChord(spec: "+"), chord("=", .shift))
        XCTAssertEqual(KeyChord(spec: "cmd++"), chord("=", [.command, .shift]))
        XCTAssertEqual(KeyChord(spec: "shift+="), KeyChord(spec: "+"))
        XCTAssertEqual(KeyChord(spec: "<"), chord(",", .shift))
        XCTAssertEqual(KeyChord(spec: ">"), chord(".", .shift))
        XCTAssertEqual(KeyChord(spec: "|"), chord("\\", .shift))
        XCTAssertEqual(KeyChord(spec: "_"), chord("-", .shift))
        XCTAssertEqual(KeyChord(spec: "!"), chord("1", .shift))
        XCTAssertEqual(KeyChord(spec: ")"), chord("0", .shift))
        XCTAssertEqual(KeyChord(spec: "~"), chord("`", .shift))
        XCTAssertEqual(KeyChord(spec: "\""), chord("'", .shift))
        XCTAssertEqual(KeyChord(spec: "shift+G"), chord("g", .shift))
        XCTAssertEqual(KeyChord(spec: "-"), chord("-"))
        XCTAssertEqual(KeyChord(spec: "cmd+-"), chord("-", .command))
        XCTAssertEqual(KeyChord(spec: "["), chord("["))
    }

    func testSequences() throws {
        XCTAssertEqual(KeyChord.sequence(spec: "g g"), [chord("g"), chord("g")])
        XCTAssertEqual(KeyChord.sequence(spec: "ctrl+x  o"), [chord("x", .control), chord("o")])
        XCTAssertEqual(KeyChord.sequence(spec: "y p"), [chord("y"), chord("p")])
        XCTAssertEqual(KeyChord.sequence(spec: "space"), [chord("space")])
        XCTAssertEqual(KeyChord.sequence(spec: " "), [chord("space")])
        XCTAssertNil(KeyChord.sequence(spec: ""))
        XCTAssertNil(KeyChord.sequence(spec: "g bogus"))
    }

    func testRejectsUnknownKeys() {
        for bad in ["bogus", "hyper+k", "cmd+", "ctrl+bogus", "é", "f21", "kp10"] {
            XCTAssertNil(KeyChord(spec: bad), bad)
        }
        XCTAssertThrowsError(try KeyChord.parse("hyper+k")) { error in
            XCTAssertTrue("\(error)".contains("unknown modifier \"hyper\""), "\(error)")
        }
        XCTAssertThrowsError(try KeyChord.parse("nope")) { error in
            XCTAssertEqual("\(error)", "unknown key \"nope\"")
        }
    }

    func testCanonicalSpecRoundTrips() {
        for spec in ["cmd+shift+k", "opt+1", "space", "shift+/", "ctrl+opt+shift+cmd+left", "kp+", "cmd+=", "f5"] {
            let parsed = KeyChord(spec: spec)
            XCTAssertNotNil(parsed, spec)
            XCTAssertEqual(parsed.flatMap { KeyChord(spec: $0.spec) }, parsed, spec)
        }
        XCTAssertEqual(KeyChord(spec: "shift+cmd+k")?.spec, "cmd+shift+k")
        XCTAssertEqual(KeyChord.spec(of: KeyChord.sequence(spec: "g g")!), "g g")
    }

    func testSymbols() {
        XCTAssertEqual(KeyChord(spec: "cmd+shift+k")?.symbol, "⇧⌘K")
        XCTAssertEqual(KeyChord(spec: "?")?.symbol, "?")
        XCTAssertEqual(KeyChord(spec: "opt+1")?.symbol, "⌥1")
        XCTAssertEqual(KeyChord(spec: "cmd+backspace")?.symbol, "⌘⌫")
        XCTAssertEqual(KeyChord(spec: "space")?.symbol, "Space")
    }
}
