import XCTest
@testable import PeekabooCore

/// Formatting-preserving edits of config.toml: `parse(edit(text))` is the expected config, and every line the edit
/// does not touch stays byte-identical.
final class TOMLEditorTests: XCTestCase {
    private func set(_ text: String, _ table: String, _ key: String, _ value: TOMLValue) throws -> String {
        var editor = ConfigEditor(text: text)
        try editor.set(key, in: table, to: value)
        return editor.text
    }

    /// A minimal line diff (longest common subsequence): the lines only `before` has, and the lines only `after` has.
    private func changedLines(_ before: String, _ after: String) -> (removed: [String], added: [String]) {
        let a = before.components(separatedBy: "\n"), b = after.components(separatedBy: "\n")
        var common = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                common[i][j] = a[i] == b[j] ? common[i + 1][j + 1] + 1 : max(common[i + 1][j], common[i][j + 1])
            }
        }
        var removed: [String] = [], added: [String] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                i += 1; j += 1
            } else if j < b.count, i == a.count || common[i][j + 1] >= common[i + 1][j] {
                added.append(b[j]); j += 1
            } else {
                removed.append(a[i]); i += 1
            }
        }
        return (removed, added)
    }

    func testReplacesOnlyTheValueAndKeepsTheCommentColumn() throws {
        let text = """
        # my config
        [view]
        background = "black"   # favourite
          keep_zoom   =   false
        zoom_step = 1.25

        """
        let edited = try set(text, "view", "background", .string("gray"))
        XCTAssertEqual(edited, text.replacingOccurrences(of: "\"black\"   #", with: "\"gray\"    #"))
        // A longer value pushes the comment, keeping one space.
        let longer = try set(text, "view", "background", .string("checker-long-value"))
        XCTAssertTrue(longer.contains("background = \"checker-long-value\" # favourite"), longer)
        // Spacing around `=` and the indentation are the user's.
        XCTAssertEqual(try set(text, "view", "keep_zoom", .bool(true)),
                       text.replacingOccurrences(of: "=   false", with: "=   true"))
        XCTAssertEqual(try set(text, "view", "zoom_step", .float(2)), text.replacingOccurrences(of: "1.25", with: "2.0"))
        // Setting the value it already has changes nothing.
        XCTAssertEqual(try set(text, "view", "background", .string("black")), text)
    }

    func testStarterFileGetsItsCommentedLinesUncommented() throws {
        let starter = ConfigStore.sampleConfig
        let edited = try set(starter, "view", "background", .string("gray"))
        let change = changedLines(starter, edited)
        XCTAssertEqual(change.removed, ["# [view]", "# background = \"black\"          # black | gray | checker   (cycle with b)"])
        XCTAssertEqual(change.added, ["[view]", "background = \"gray\"           # black | gray | checker   (cycle with b)"])
        var expected = AppConfig.default
        expected.background = "gray"
        XCTAssertEqual(try AppConfig(toml: edited), expected)

        // The next key of the same (now real) table takes its own commented line, in place.
        let second = try set(edited, "view", "keep_zoom", .bool(true))
        XCTAssertEqual(changedLines(edited, second).added,
                       ["keep_zoom = true              # keep zoom and pan when moving to another image (toggle: shift+z)"])
        expected.keepZoom = true
        XCTAssertEqual(try AppConfig(toml: second), expected)

        // Another commented table.
        let third = try set(second, "hud", "mode", .string("full"))
        XCTAssertEqual(changedLines(second, third).added, ["[hud]", "mode = \"full\"                 # off | minimal | full   (cycle with i)"])
        expected.hud = .full
        XCTAssertEqual(try AppConfig(toml: third), expected)
    }

    /// Every setting of docs/CONFIG.md, set on the starter file: the result loads as exactly that change, and at most
    /// the table line and the key's line change.
    func testEverySettingRoundTripsOnTheStarterFile() throws {
        typealias Case = (table: String, key: String, value: TOMLValue, check: (AppConfig) -> Bool)
        let cases: [Case] = [
            ("view", "background", .string("checker"), { $0.background == "checker" }),
            ("view", "keep_zoom", .bool(true), { $0.keepZoom }),
            ("view", "zoom_step", .float(1.5), { $0.zoomStep == 1.5 }),
            ("view", "refine_delay_ms", .integer(250), { $0.refineDelayMs == 250 }),
            ("fullscreen", "mode", .string("native"), { $0.fullscreen == .native }),
            ("fullscreen", "avoid_notch", .bool(false), { !$0.avoidNotch }),
            ("hud", "mode", .string("off"), { $0.hud == .off }),
            ("cache", "memory_mb", .integer(2048), { $0.cacheBudgetMB == 2048 }),
            ("rating", "storage", .string("none"), { $0.ratingStorage == AppConfig.RatingStorage.none }),
            ("rating", "star", .string("*"), { $0.starCharacter == "*" }),
            ("rating", "auto_advance", .bool(true), { $0.autoAdvance }),
            ("keymap", "defaults", .bool(false), { !$0.keymapDefaults }),
            ("keymap", "vim", .bool(true), { $0.vimKeys }),
            ("decode", "hdr", .bool(true), { $0.decodeHDR }),
            ("decode", "fast_path", .bool(false), { !$0.fastPath }),
            ("debug", "trace", .bool(true), { $0.trace }),
            ("updates", "check", .bool(false), { !$0.updates.check }),
            ("updates", "auto_install", .bool(false), { !$0.updates.autoInstall }),
            ("slots", "5", .string("~/Desktop/Five"), { $0.slots == ["5": "~/Desktop/Five"] }),
            ("apps", "viewer", .string("com.apple.Preview"), { $0.apps == ["viewer": "com.apple.Preview"] }),
        ]
        let starter = ConfigStore.sampleConfig
        for (table, key, value, check) in cases {
            let edited = try set(starter, table, key, value)
            let config = try AppConfig(toml: edited)
            XCTAssertTrue(check(config), "\(table).\(key)")
            let change = changedLines(starter, edited)
            XCTAssertLessThanOrEqual(change.removed.count + change.added.count, 4, "\(table).\(key): \(change)")
            // Nothing else changed: undoing the edit's own lines gives the starter file back.
            var reverted = ConfigEditor(text: edited)
            try reverted.remove(key, in: table)
            XCTAssertEqual(try AppConfig(toml: reverted.text), .default, "\(table).\(key)")
        }
    }

    func testAddsAMissingKeyBelowTheLastEntryOfItsTable() throws {
        let text = "[view]\nbackground = \"gray\"\n\n[hud]\nmode = \"full\"\n"
        XCTAssertEqual(try set(text, "view", "keep_zoom", .bool(true)),
                       "[view]\nbackground = \"gray\"\nkeep_zoom = true\n\n[hud]\nmode = \"full\"\n")
        // A table without entries: right below its header, also at the end of a file without a final newline.
        XCTAssertEqual(try set("[view]\n[hud]\n", "view", "keep_zoom", .bool(true)), "[view]\nkeep_zoom = true\n[hud]\n")
        XCTAssertEqual(try set("[view]", "view", "keep_zoom", .bool(true)), "[view]\nkeep_zoom = true\n")
        // A multi-line array is one entry: the new key goes below its closing bracket.
        let array = "[keys]\n\"nav.next\" = [\n  \"n\",  # n\n  \"ctrl+f\",\n]\n# end\n"
        var editor = ConfigEditor(text: array)
        try editor.bind([KeyChord(key: "y")], to: [.copyName], context: .normal)
        XCTAssertEqual(editor.text, "[keys]\n\"nav.next\" = [\n  \"n\",  # n\n  \"ctrl+f\",\n]\n\"y\" = \"file.copy_name\"\n# end\n")
    }

    func testAppendsAMissingTable() throws {
        XCTAssertEqual(try set("[view]\nbackground = \"gray\"\n", "decode", "hdr", .bool(true)),
                       "[view]\nbackground = \"gray\"\n\n[decode]\nhdr = true\n")
        XCTAssertEqual(try set("[view]\nbackground = \"gray\"", "decode", "hdr", .bool(true)),
                       "[view]\nbackground = \"gray\"\n\n[decode]\nhdr = true\n")
        XCTAssertEqual(try set("# notes\n\n", "decode", "hdr", .bool(true)), "# notes\n\n[decode]\nhdr = true\n")
        XCTAssertEqual(try set("", "decode", "hdr", .bool(true)), "[decode]\nhdr = true\n")
        XCTAssertEqual(try set("", "keys.zoomed", "x", .string("pan.left")), "[keys.zoomed]\nx = \"pan.left\"\n")
    }

    /// Uncommenting `# [hud]` would move the real `keep_zoom` below it into [hud]: the edit appends instead.
    func testNeverUncommentsAHeaderThatWouldMoveOtherEntries() throws {
        let text = "[view]\nbackground = \"gray\"\n# [hud]\n# mode = \"minimal\"\nkeep_zoom = true\n"
        let edited = try set(text, "hud", "mode", .string("full"))
        XCTAssertEqual(edited, text + "\n[hud]\nmode = \"full\"\n")
        let config = try AppConfig(toml: edited)
        XCTAssertTrue(config.keepZoom)
        XCTAssertEqual(config.hud, .full)
    }

    func testRemoveDeletesExactlyTheEntryLines() throws {
        let text = "[keys]\n# keep this\n\"nav.next\" = [\n  \"n\",\n  \"ctrl+f\",\n]  # trailing\n\"x\" = \"file.trash\"\n"
        var editor = ConfigEditor(text: text)
        try editor.remove("nav.next", in: "keys")
        XCTAssertEqual(editor.text, "[keys]\n# keep this\n\"x\" = \"file.trash\"\n")
        try editor.remove("x", in: "keys")
        XCTAssertEqual(editor.text, "[keys]\n# keep this\n")
        try editor.remove("x", in: "keys")  // absent: nothing happens
        XCTAssertEqual(editor.text, "[keys]\n# keep this\n")
        // The last line without its newline.
        var last = ConfigEditor(text: "[view]\nbackground = \"gray\"")
        try last.remove("background", in: "view")
        XCTAssertEqual(last.text, "[view]\n")
    }

    func testReplacesAMultiLineValue() throws {
        let text = "[keys]\n\"nav.next\" = [\n  \"n\",\n  \"ctrl+f\",\n]  # next\n\"x\" = \"file.trash\"\n"
        let edited = try set(text, "keys", "nav.next", .array([.string("n")]))
        XCTAssertEqual(edited, "[keys]\n\"nav.next\" = [\"n\"]  # next\n\"x\" = \"file.trash\"\n")
    }

    func testFindsDottedAndTopLevelSpellings() throws {
        XCTAssertEqual(try set("view.background = \"black\"\n", "view", "background", .string("gray")),
                       "view.background = \"gray\"\n")
        XCTAssertEqual(try set("[view]\n\"background\" = 'black'\n", "view", "background", .string("gray")),
                       "[view]\n\"background\" = \"gray\"\n")
    }

    func testKeepsWindowsLineEndings() throws {
        let edited = try set("[view]\r\nbackground = \"black\"\r\n", "hud", "mode", .string("full"))
        XCTAssertEqual(edited, "[view]\r\nbackground = \"black\"\r\n\r\n[hud]\r\nmode = \"full\"\r\n")
        XCTAssertEqual(try AppConfig(toml: edited).hud, .full)
    }

    func testSpellsKeysAndStringsSafely() throws {
        var editor = ConfigEditor(text: "")
        try editor.bind(try KeyChord.parseSequence("cmd+,"), to: [.configFile], context: .normal)
        try editor.set("my slot", in: "slots", to: .string("~/Pictures/\"Best\" \\ \n\tof"))
        XCTAssertEqual(editor.text, "[keys]\n\"cmd+,\" = \"app.config_file\"\n\n[slots]\n\"my slot\" = \"~/Pictures/\\\"Best\\\" \\\\ \\n\\tof\"\n")
        let config = try AppConfig(toml: editor.text)
        XCTAssertEqual(config.slots["my slot"], "~/Pictures/\"Best\" \\ \n\tof")
        XCTAssertEqual(config.keymap.resolve(try KeyChord.parseSequence("cmd+,"), context: .normal), .actions([.configFile]))
        XCTAssertEqual(TOMLValue.float(1e-5).tomlText, "1e-05")
        XCTAssertEqual(TOMLValue.string("\u{1}").tomlText, "\"\\u0001\"")
    }

    /// Example entries of `[slots]`, `[apps]` and `[keys]` describe their example value: a new entry never takes over
    /// such a line (or its comment); only the table header is uncommented.
    func testExampleLinesOfOpenTablesAreNotReused() throws {
        let starter = ConfigStore.sampleConfig
        let edited = try set(starter, "slots", "3", .string("~/Desktop"))
        let change = changedLines(starter, edited)
        XCTAssertEqual(change.removed, ["# [slots]                       # destinations for file.move:<slot> / file.copy:<slot>; opt+N moves, opt+shift+N copies"])
        XCTAssertEqual(change.added, ["[slots]                       # destinations for file.move:<slot> / file.copy:<slot>; opt+N moves, opt+shift+N copies",
                                      "3 = \"~/Desktop\""])
        XCTAssertTrue(edited.contains("# 3 = \"./_rejects\"              # relative = next to the current image"))
    }

    func testRefusesTextThatIsNotTOML() {
        XCTAssertThrowsError(try set("[view\nbackground = 1\n", "view", "background", .string("gray"))) { error in
            XCTAssertEqual((error as? ConfigEditError)?.line, 1, "\(error)")
        }
    }
}
