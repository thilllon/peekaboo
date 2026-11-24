import XCTest
@testable import PeekabooCore

final class KeymapTests: XCTestCase {
    private func seq(_ spec: String) -> [KeyChord] { KeyChord.sequence(spec: spec)! }

    private func resolve(_ map: Keymap, _ spec: String, _ context: KeyContext = .normal) -> KeymapResult {
        map.resolve(seq(spec), context: context)
    }

    private func config(_ text: String) throws -> AppConfig { try AppConfig(toml: text) }

    func testDefaultLayerMatchesTheResearchTable() {
        let map = Keymap.default
        let expected: [(String, [Action])] = [
            ("right", [.next]), ("down", [.next]), ("space", [.next]), ("pagedown", [.next]),
            ("left", [.previous]), ("up", [.previous]), ("shift+space", [.previous]), ("backspace", [.previous]),
            ("pageup", [.previous]), ("home", [.first]), ("cmd+up", [.first]), ("end", [.last]), ("cmd+down", [.last]),
            ("[", [.jump(-10)]), ("]", [.jump(10)]), ("z", [.zoomToggle]), ("cmd+0", [.zoomFit]), ("cmd+9", [.zoomFit]),
            ("cmd+1", [.zoomActual]), ("cmd+2", [.zoomSet(2)]), ("cmd+4", [.zoomSet(4)]), ("cmd+shift+0", [.zoomFill]),
            ("=", [.zoomIn]), ("+", [.zoomIn]), ("cmd+=", [.zoomIn]), ("-", [.zoomOut]), ("cmd+-", [.zoomOut]),
            ("shift+z", [.zoomKeep]), ("f", [.fullscreen]), ("return", [.fullscreen]), ("ctrl+cmd+f", [.fullscreen]),
            ("esc", [.escape]), ("i", [.hud]), ("tab", [.hudHide]), ("b", [.background]),
            ("r", [.rotateClockwise]), ("cmd+r", [.rotateClockwise]), (">", [.rotateClockwise]),
            ("shift+r", [.rotateCounterClockwise]), ("cmd+l", [.rotateCounterClockwise]), ("<", [.rotateCounterClockwise]),
            ("|", [.flipHorizontal]), ("_", [.flipVertical]),
            ("cmd+backspace", [.trash]), ("forwarddelete", [.trash]), ("cmd+z", [.undo]), ("cmd+shift+z", [.redo]),
            ("m", [.move("ask")]), ("c", [.copy("ask")]), ("opt+1", [.move("1")]), ("opt+9", [.move("9")]),
            ("opt+shift+1", [.copy("1")]), ("opt+shift+9", [.copy("9")]),
            ("cmd+shift+r", [.reveal]), ("cmd+c", [.copyImage]), ("opt+cmd+c", [.copyPath]),
            ("e", [.openWith("editor")]), ("shift+e", [.openWithChooser]),
            ("0", [.rate(0)]), ("3", [.rate(3)]), ("5", [.rate(5)]), ("shift+3", [.rate(3), .next]), ("shift+0", [.rate(0), .next]),
            ("6", [.label("red")]), ("7", [.label("yellow")]), ("8", [.label("green")]), ("9", [.label("blue")]),
            ("shift+6", [.label("red"), .next]), ("shift+9", [.label("blue"), .next]),
            ("p", [.flag("pick")]), ("x", [.flag("reject")]), ("u", [.flag("none")]),
            ("shift+p", [.flag("pick"), .next]), ("shift+x", [.flag("reject"), .next]), ("shift+u", [.flag("none"), .next]),
            ("cmd+,", [.config]), ("?", [.help]), ("cmd+/", [.help]), ("cmd+w", [.close]), ("q", [.close]),
            ("cmd+q", [.quit]), ("cmd+o", [.open]),
        ]
        for (spec, actions) in expected {
            XCTAssertEqual(resolve(map, spec), .actions(actions), spec)
        }
        XCTAssertTrue(map.conflicts().isEmpty)
        // The reserved system chords stay free.
        for spec in ["ctrl+space", "cmd+space", "ctrl+left", "cmd+tab", "cmd+h", "cmd+m", "cmd+shift+3", "ctrl+1"] {
            XCTAssertEqual(resolve(map, spec), .unbound, spec)
        }
    }

    func testZoomedContextPansAndFallsBack() {
        let map = Keymap.default
        XCTAssertEqual(resolve(map, "left", .zoomed), .actions([.pan(.left)]))
        XCTAssertEqual(resolve(map, "down", .zoomed), .actions([.pan(.down)]))
        XCTAssertEqual(resolve(map, "shift+up", .zoomed), .actions([.panEdge(.top)]))
        XCTAssertEqual(resolve(map, "shift+right", .zoomed), .actions([.panEdge(.right)]))
        // Space, backspace and page keys keep navigating; everything else falls back to normal.
        XCTAssertEqual(resolve(map, "space", .zoomed), .actions([.next]))
        XCTAssertEqual(resolve(map, "backspace", .zoomed), .actions([.previous]))
        XCTAssertEqual(resolve(map, "pagedown", .zoomed), .actions([.next]))
        XCTAssertEqual(resolve(map, "3", .zoomed), .actions([.rate(3)]))
        XCTAssertEqual(resolve(map, "shift+up"), .unbound)
    }

    func testVimLayerAddsSequences() throws {
        let map = try config("[keymap]\nvim = true\n").keymap
        XCTAssertEqual(resolve(map, "l"), .actions([.next]))
        XCTAssertEqual(resolve(map, "k"), .actions([.previous]))
        XCTAssertEqual(resolve(map, "shift+n"), .actions([.previous]))
        XCTAssertEqual(resolve(map, "g"), .pending)
        XCTAssertEqual(resolve(map, "g g"), .actions([.first]))
        XCTAssertEqual(resolve(map, "G"), .actions([.last]))
        XCTAssertEqual(resolve(map, "d"), .pending)
        XCTAssertEqual(resolve(map, "d d"), .actions([.trash]))
        XCTAssertEqual(resolve(map, "y p"), .actions([.copyPath]))
        XCTAssertEqual(resolve(map, "y y"), .actions([.copyImage]))
        XCTAssertEqual(resolve(map, "y q"), .unbound)
        XCTAssertEqual(resolve(map, "w"), .actions([.zoomFit]))
        XCTAssertEqual(resolve(map, "h", .zoomed), .actions([.pan(.left)]))
        XCTAssertEqual(resolve(map, "shift+j", .zoomed), .actions([.panEdge(.bottom)]))
        // The default layer stays.
        XCTAssertEqual(resolve(map, "right"), .actions([.next]))
        XCTAssertTrue(map.conflicts().isEmpty)
        XCTAssertEqual(resolve(Keymap.default, "g"), .unbound)
    }

    func testOverridesUnbindingAndActionLists() throws {
        let map = try config("""
        [slots]
        keep = "~/Pictures/Keep"
        [keys]
        "space" = "zoom.toggle"
        "tab" = "none"
        "k" = "file.move:keep"
        "shift+3" = ["meta.rate:3", "nav.next", "nav.next"]
        "ctrl+x o" = "exec:open -a ImageOptim {path}"
        [keys.zoomed]
        "left" = "none"
        "a" = "pan.center"
        """).keymap
        XCTAssertEqual(resolve(map, "space"), .actions([.zoomToggle]))
        XCTAssertEqual(resolve(map, "tab"), .unbound)
        XCTAssertEqual(resolve(map, "k"), .actions([.move("keep")]))
        XCTAssertEqual(resolve(map, "shift+3"), .actions([.rate(3), .next, .next]))
        XCTAssertEqual(resolve(map, "ctrl+x"), .pending)
        XCTAssertEqual(resolve(map, "ctrl+x o"), .actions([.exec("open -a ImageOptim {path}")]))
        // "none" in [keys.zoomed] removes the zoomed binding, so the key falls back to [keys].
        XCTAssertEqual(resolve(map, "left", .zoomed), .actions([.previous]))
        XCTAssertEqual(resolve(map, "a", .zoomed), .actions([.panCenter]))
        XCTAssertEqual(resolve(map, "a"), .unbound)
        // Untouched defaults remain.
        XCTAssertEqual(resolve(map, "right"), .actions([.next]))
        XCTAssertEqual(map.sequences(for: .zoomToggle).map { KeyChord.spec(of: $0) }, ["space", "z"])
    }

    func testDefaultsOffStartsEmpty() throws {
        let map = try config("[keymap]\ndefaults = false\n[keys]\n\"n\" = \"nav.next\"\n").keymap
        XCTAssertEqual(resolve(map, "n"), .actions([.next]))
        XCTAssertEqual(resolve(map, "right"), .unbound)
        XCTAssertEqual(resolve(map, "left", .zoomed), .unbound)
    }

    func testAutoAdvance() throws {
        let map = try config("[rating]\nauto_advance = true\n").keymap
        XCTAssertEqual(resolve(map, "4"), .actions([.rate(4), .next]))
        XCTAssertEqual(resolve(map, "p"), .actions([.flag("pick"), .next]))
        XCTAssertEqual(resolve(map, "shift+4"), .actions([.rate(4), .next]))
    }

    func testSequencePrefixConflictsAreErrors() {
        XCTAssertThrowsError(try config("[keys]\n\"z z\" = \"zoom.fit\"\n")) { error in
            let error = error as! ConfigError
            XCTAssertEqual(error.errors.first?.line, 2)
            XCTAssertTrue(error.description.contains("\"z z\" conflicts with \"z\""), error.description)
        }
        // Unbinding the prefix resolves it.
        XCTAssertNoThrow(try config("[keys]\n\"z\" = \"none\"\n\"z z\" = \"zoom.fit\"\n"))
        XCTAssertThrowsError(try config("[keymap]\nvim = true\n[keys.zoomed]\n\"g\" = \"pan.center\"\n")) { error in
            XCTAssertEqual((error as! ConfigError).errors.first?.line, 4)
        }
    }

    func testResolveTreatsStoredNoneAsUnbound() {
        var map = Keymap.default
        map.bindings[.zoomed]?[seq("space")] = [.none]
        XCTAssertEqual(resolve(map, "space", .zoomed), .unbound)
        XCTAssertEqual(resolve(map, "space"), .actions([.next]))
    }
}
