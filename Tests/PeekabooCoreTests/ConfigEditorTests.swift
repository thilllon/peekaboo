import XCTest
@testable import PeekabooCore

/// Key-binding edits of config.toml (the Settings window's shortcut editor) and the conflict analysis behind
/// "this key is taken — press it again to move it".
final class ConfigEditorTests: XCTestCase {
    private func seq(_ spec: String) -> [KeyChord] { KeyChord.sequence(spec: spec)! }

    private func edit(_ text: String, _ change: (inout ConfigEditor) throws -> Void) throws -> String {
        var editor = ConfigEditor(text: text)
        try change(&editor)
        return editor.text
    }

    private func resolve(_ text: String, _ spec: String, _ context: KeyContext = .normal) throws -> KeymapResult {
        try AppConfig(toml: text).keymap.resolve(seq(spec), context: context)
    }

    // MARK: Override generation

    func testBindWritesOneChordEntry() throws {
        let text = try edit("") { try $0.bind(seq("y"), to: [.copyName], context: .normal) }
        XCTAssertEqual(text, "[keys]\n\"y\" = \"file.copy_name\"\n")
        XCTAssertEqual(try resolve(text, "y"), .actions([.copyName]))
        // An action list is written as a list.
        let list = try edit(text) { try $0.bind(seq("shift+y"), to: [.copyName, .next], context: .normal) }
        XCTAssertEqual(list, text + "\"shift+y\" = [\"file.copy_name\", \"nav.next\"]\n")
        XCTAssertEqual(try resolve(list, "shift+y"), .actions([.copyName, .next]))
    }

    func testBindingWhatTheBuiltInKeymapAlreadyDoesWritesNothing() throws {
        XCTAssertEqual(try edit("") { try $0.bind(seq("right"), to: [.next], context: .normal) }, "")
        // … and takes back an override of it.
        let overridden = "[keys]\n\"right\" = \"file.trash\"\n"
        XCTAssertEqual(try edit(overridden) { try $0.bind(seq("right"), to: [.next], context: .normal) }, "[keys]\n")
        // With the vim layer on, `l` is built in too.
        XCTAssertEqual(try edit("[keymap]\nvim = true\n") { try $0.bind(seq("l"), to: [.next], context: .normal) },
                       "[keymap]\nvim = true\n")
    }

    func testMovingAKeyReplacesItsEntry() throws {
        let text = "[keys]\n\"y\" = \"file.copy_name\"  # mine\n\"k\" = \"nav.next\"\n"
        let moved = try edit(text) { try $0.bind(seq("y"), to: [.copyPath], context: .normal) }
        XCTAssertEqual(moved, "[keys]\n\"k\" = \"nav.next\"\n\"y\" = \"file.copy_path\"\n")
        XCTAssertEqual(try resolve(moved, "y"), .actions([.copyPath]))
        // A built-in key: an override entry.
        let builtIn = try edit("") { try $0.bind(seq("f"), to: [.trash], context: .normal) }
        XCTAssertEqual(builtIn, "[keys]\n\"f\" = \"file.trash\"\n")
        XCTAssertEqual(try resolve(builtIn, "f"), .actions([.trash]))
        XCTAssertEqual(try resolve(builtIn, "return"), .actions([.fullscreen]), "the action keeps its other keys")
    }

    func testUnbindWritesNoneForBuiltInKeysAndRemovesTheUsersOwn() throws {
        let none = try edit("") { try $0.unbind(seq("tab"), context: .normal) }
        XCTAssertEqual(none, "[keys]\n\"tab\" = \"none\"\n")
        XCTAssertEqual(try resolve(none, "tab"), .unbound)
        let own = "[keys]\n\"y\" = \"file.copy_name\"\n"
        XCTAssertEqual(try edit(own) { try $0.unbind(seq("y"), context: .normal) }, "[keys]\n")
        // A built-in key the user had rebound: the entry becomes "none".
        let rebound = try edit("[keys]\n\"f\" = \"file.trash\"\n") { try $0.unbind(seq("f"), context: .normal) }
        XCTAssertEqual(rebound, "[keys]\n\"f\" = \"none\"\n")
        XCTAssertEqual(try resolve(rebound, "f"), .unbound)
        // Sequences can be removed too (they are recorded in config.toml only).
        let vim = try edit("[keymap]\nvim = true\n") { try $0.unbind(seq("g g"), context: .normal) }
        XCTAssertEqual(try resolve(vim, "g g"), .unbound)
    }

    func testActionSpelledEntriesLoseOneChordAtATime() throws {
        let text = "[keys]\n\"nav.next\" = [\"n\", \"ctrl+f\"]  # next\n\"none\" = [\"tab\", \"b\"]\n"
        let one = try edit(text) { try $0.unbind(seq("n"), context: .normal) }
        XCTAssertEqual(one, "[keys]\n\"nav.next\" = \"ctrl+f\"         # next\n\"none\" = [\"tab\", \"b\"]\n", "the comment keeps its column")
        let none = try edit(one) { try $0.unbind(seq("ctrl+f"), context: .normal) }
        XCTAssertEqual(none, "[keys]\n\"none\" = [\"tab\", \"b\"]\n")
        // Binding a key that a "none" list unbinds takes it out of the list.
        let back = try edit(none) { try $0.bind(seq("tab"), to: [.hudHide], context: .normal) }
        XCTAssertEqual(back, "[keys]\n\"none\" = \"b\"\n")
        XCTAssertEqual(try resolve(back, "tab"), .actions([.hudHide]))
        XCTAssertEqual(try resolve(back, "b"), .unbound)
    }

    func testResetGivesAnActionItsBuiltInKeysBack() throws {
        let text = """
        [keys]
        "ctrl+f" = "view.fullscreen"
        "view.fullscreen" = "y"
        "f" = "file.trash"
        "return" = "none"
        "tab" = "none"

        """
        let reset = try edit(text) { try $0.reset([.fullscreen], context: .normal) }
        XCTAssertEqual(reset, "[keys]\n\"tab\" = \"none\"\n")
        let keymap = try AppConfig(toml: reset).keymap
        XCTAssertEqual(keymap.sequences(for: .fullscreen), Keymap.default.sequences(for: .fullscreen))
        XCTAssertEqual(keymap.resolve(seq("tab"), context: .normal), .unbound, "other actions keep their changes")
        // An action list is reset as a whole.
        let rated = try edit("[keys]\n\"shift+3\" = \"meta.rate:3\"\n") { try $0.reset([.rate(3), .next], context: .normal) }
        XCTAssertEqual(try resolve(rated, "shift+3"), .actions([.rate(3), .next]))
    }

    func testResetAllRemovesEveryBindingAndKeepsTheRest() throws {
        let text = """
        # mine
        [keys]   # my keys
        "y" = "file.copy_name"
        "nav.next" = ["n"]
        [view]
        background = "gray"
        [keys.zoomed]
        "j" = "pan.down"

        """
        let reset = try edit(text) { try $0.resetBindings() }
        XCTAssertEqual(reset, "# mine\n[keys]   # my keys\n[view]\nbackground = \"gray\"\n[keys.zoomed]\n")
        let config = try AppConfig(toml: reset)
        XCTAssertEqual(config.keymap, Keymap.default)
        XCTAssertEqual(config.background, "gray")
    }

    func testZoomedBindingsGoToKeysZoomed() throws {
        let text = try edit("") { try $0.bind(seq("j"), to: [.pan(.down)], context: .zoomed) }
        XCTAssertEqual(text, "[keys.zoomed]\n\"j\" = \"pan.down\"\n")
        XCTAssertEqual(try resolve(text, "j", .zoomed), .actions([.pan(.down)]))
        XCTAssertEqual(try resolve(text, "j", .normal), .unbound)
        // Turning off a built-in zoomed key lets it fall back to [keys].
        let fallback = try edit(text) { try $0.unbind(seq("left"), context: .zoomed) }
        XCTAssertEqual(fallback, text + "\"left\" = \"none\"\n")
        XCTAssertEqual(try resolve(fallback, "left", .zoomed), .actions([.previous]))
    }

    func testKeysNormalIsTheSameTable() throws {
        let text = "[keys.normal]\n\"y\" = \"file.copy_name\"\n"
        let moved = try edit(text) { try $0.bind(seq("k"), to: [.next], context: .normal) }
        XCTAssertEqual(moved, text + "\"k\" = \"nav.next\"\n")
        XCTAssertEqual(try edit(moved) { try $0.unbind(seq("y"), context: .normal) }, "[keys.normal]\n\"k\" = \"nav.next\"\n")
    }

    func testTheStarterFileKeepsItsExamples() throws {
        let starter = LegacyConfigFiles.releasedStarter
        let text = try edit(starter) { try $0.bind(seq("y"), to: [.copyName], context: .normal) }
        XCTAssertTrue(text.contains("\n[keys]                        # \"chord\" = \"action\" or [\"action\", ...]; \"none\" removes a default binding\n\"y\" = \"file.copy_name\"\n# \"k\" = \"file.move:keep\""), text)
        XCTAssertEqual(try resolve(text, "y"), .actions([.copyName]))
        var expected = Keymap.default
        expected.bind(seq("y"), to: [.copyName])
        XCTAssertEqual(try AppConfig(toml: text).keymap, expected)
    }

    // MARK: A file that lists the keymap (as Peekaboo writes it)

    private var full: String { ConfigFile.defaultText }

    /// `full` with `old` replaced by `new` (each must be in it).
    private func full(_ old: String, _ new: String) -> String {
        XCTAssertTrue(full.contains(old), old)
        return full.replacingOccurrences(of: old, with: new)
    }

    func testANewKeyJoinsItsActionsLine() throws {
        XCTAssertEqual(try edit(full) { try $0.bind(seq("g"), to: [.fullscreen], context: .normal) },
                       full("\"view.fullscreen\" = [\"f\", \"return\", \"ctrl+cmd+f\"]", "\"view.fullscreen\" = [\"f\", \"return\", \"ctrl+cmd+f\", \"g\"]"))
        // An action without a line gets one at the end of [keys], above the examples; an action list a line of its own.
        XCTAssertEqual(try edit(full) { try $0.bind(seq("y"), to: [.copyName], context: .normal) },
                       full("\"app.open\" = \"cmd+o\"\n", "\"app.open\" = \"cmd+o\"\n\"file.copy_name\" = \"y\"\n"))
        XCTAssertEqual(try edit(full) { try $0.bind(seq("shift+y"), to: [.copyName, .next], context: .normal) },
                       full("\"app.open\" = \"cmd+o\"\n", "\"app.open\" = \"cmd+o\"\n\"shift+y\" = [\"file.copy_name\", \"nav.next\"]\n"))
        XCTAssertEqual(try edit(full) { try $0.bind(seq("y"), to: [.panCenter], context: .zoomed) },
                       full("\"pan.edge:bottom\" = \"shift+down\"\n", "\"pan.edge:bottom\" = \"shift+down\"\n\"pan.center\" = \"y\"\n"))
        // What the file already does changes nothing.
        XCTAssertEqual(try edit(full) { try $0.bind(seq("right"), to: [.next], context: .normal) }, full)
        // A key another action has leaves that action's line; no "none" is written.
        let taken = try edit(full) { try $0.bind(seq("f"), to: [.copyName], context: .normal) }
        XCTAssertEqual(taken, full("\"view.fullscreen\" = [\"f\", \"return\", \"ctrl+cmd+f\"]", "\"view.fullscreen\" = [\"return\", \"ctrl+cmd+f\"]")
            .replacingOccurrences(of: "\"app.open\" = \"cmd+o\"\n", with: "\"app.open\" = \"cmd+o\"\n\"file.copy_name\" = \"f\"\n"))
        XCTAssertEqual(try resolve(taken, "f"), .actions([.copyName]))
        XCTAssertEqual(try resolve(taken, "return"), .actions([.fullscreen]))
    }

    func testRemovingAKeyDeletesItFromItsLine() throws {
        let line = try edit(full) { try $0.unbind(seq("tab"), context: .normal) }
        XCTAssertEqual(line, full("\"view.hud_hide\" = \"tab\"\n", ""))
        XCTAssertEqual(try resolve(line, "tab"), .unbound)
        XCTAssertEqual(try edit(full) { try $0.unbind(seq("return"), context: .normal) },
                       full("[\"f\", \"return\", \"ctrl+cmd+f\"]", "[\"f\", \"ctrl+cmd+f\"]"))
        XCTAssertEqual(try edit(full) { try $0.unbind(seq("p"), context: .normal) }, full("\"meta.flag:pick\" = \"p\"\n", ""))
        let zoomed = try edit(full) { try $0.unbind(seq("left"), context: .zoomed) }
        XCTAssertEqual(zoomed, full("\"pan.left\" = \"left\"\n", ""))
        XCTAssertEqual(try resolve(zoomed, "left", .zoomed), .actions([.previous]), "falls back to [keys]")
        // A key of the vim layer is turned off with "none".
        let vim = full("vim = false ", "vim = true  ")
        let h = try edit(vim) { try $0.unbind(seq("h"), context: .normal) }
        XCTAssertEqual(h, vim.replacingOccurrences(of: "\"app.open\" = \"cmd+o\"\n", with: "\"app.open\" = \"cmd+o\"\n\"h\" = \"none\"\n"))
        XCTAssertEqual(try resolve(h, "h"), .unbound)
    }

    /// With vim on, the file's `"view.play_pause" = "k"` shadows the vim layer's `k`: moving or removing it gives `k` to
    /// the vim layer (as editing the line by hand does), while a key of the vim layer itself is turned off with "none".
    func testTheVimLayerUnderAFileThatListsTheKeymap() throws {
        let vim = full("vim = false ", "vim = true  ")
        let moved = try edit(vim) { try $0.rebind(seq("k"), to: seq("s"), actions: [.playPause], context: .normal) }
        XCTAssertEqual(moved, vim.replacingOccurrences(of: "\"view.play_pause\" = \"k\"", with: "\"view.play_pause\" = \"s\""))
        XCTAssertEqual(try resolve(moved, "k"), .actions([.previous]))
        let removed = try edit(vim) { try $0.unbind(seq("k"), from: [.playPause], context: .normal) }
        XCTAssertEqual(removed, vim.replacingOccurrences(of: "\"view.play_pause\" = \"k\"\n", with: ""))
        XCTAssertEqual(try resolve(removed, "k"), .actions([.previous]))
        // Freeing the key altogether (a conflict, or no action named) turns the vim layer's off too.
        let freed = try edit(vim) { try $0.unbind(seq("k"), context: .normal) }
        XCTAssertEqual(try resolve(freed, "k"), .unbound)
        // A key of the vim layer: "none", then the new key in the action's line.
        let changed = try edit(vim) { try $0.rebind(seq("h"), to: seq("t"), actions: [.previous], context: .normal) }
        XCTAssertTrue(changed.contains("\"nav.prev\" = [\"left\", \"up\", \"shift+space\", \"backspace\", \"pageup\", \"t\"]\n"), changed)
        XCTAssertTrue(changed.contains("\n\"h\" = \"none\"\n"), changed)
        XCTAssertEqual(try resolve(changed, "h"), .unbound)
        XCTAssertEqual(try resolve(changed, "t"), .actions([.previous]))
        // An older file keeps freeing a key it takes off an action: "none" for the built-in key under it.
        XCTAssertEqual(try edit("[keys]\n\"f\" = \"file.trash\"\n") { try $0.unbind(seq("f"), from: [.trash], context: .normal) },
                       "[keys]\n\"f\" = \"none\"\n")
    }

    func testChangingAKeyReplacesItInPlace() throws {
        XCTAssertEqual(try edit(full) { try $0.rebind(seq("f"), to: seq("g"), actions: [.fullscreen], context: .normal) },
                       full("[\"f\", \"return\", \"ctrl+cmd+f\"]", "[\"g\", \"return\", \"ctrl+cmd+f\"]"))
        XCTAssertEqual(try edit(full) { try $0.rebind(seq("tab"), to: seq("h"), actions: [.hudHide], context: .normal) },
                       full("\"view.hud_hide\" = \"tab\"", "\"view.hud_hide\" = \"h\""))
        // To a key another action has: it leaves that action's line.
        XCTAssertEqual(try edit(full) { try $0.rebind(seq("f"), to: seq("b"), actions: [.fullscreen], context: .normal) },
                       full("[\"f\", \"return\", \"ctrl+cmd+f\"]", "[\"b\", \"return\", \"ctrl+cmd+f\"]")
                        .replacingOccurrences(of: "\"view.background\" = \"b\"\n", with: ""))
        // A key of an action list: its line goes, the new key gets one.
        let list = try edit(full) { try $0.rebind(seq("shift+3"), to: seq("shift+t"), actions: [.rate(3), .next], context: .normal) }
        XCTAssertEqual(list, full("\"shift+3\" = [\"meta.rate:3\", \"nav.next\"]\n", "")
            .replacingOccurrences(of: "\"app.open\" = \"cmd+o\"\n", with: "\"app.open\" = \"cmd+o\"\n\"shift+t\" = [\"meta.rate:3\", \"nav.next\"]\n"))
        // An older file: "none" for the built-in key and a line for the new one, as before; a line of the user's that
        // lists the key is changed in place.
        XCTAssertEqual(try edit("") { try $0.rebind(seq("f"), to: seq("g"), actions: [.fullscreen], context: .normal) },
                       "[keys]\n\"f\" = \"none\"\n\"g\" = \"view.fullscreen\"\n")
        XCTAssertEqual(try edit("[keys]\n\"nav.next\" = [\"n\", \"ctrl+f\"]\n") {
            try $0.rebind(seq("n"), to: seq("j"), actions: [.next], context: .normal)
        }, "[keys]\n\"nav.next\" = [\"j\", \"ctrl+f\"]\n")
    }

    func testResetWritesTheDefaultLinesBack() throws {
        var editor = ConfigEditor(text: full)
        try editor.rebind(seq("f"), to: seq("g"), actions: [.fullscreen], context: .normal)
        try editor.bind(seq("y"), to: [.fullscreen], context: .normal)
        try editor.bind(seq("return"), to: [.copyName], context: .normal)
        try editor.reset([.fullscreen], context: .normal)
        XCTAssertEqual(editor.text, full, "in place; the key another action took is back")
        // A deleted line comes back (at the end of the table), and so does a line of an action list.
        let hud = try edit(full("\"view.hud\" = \"i\"\n", "")) { try $0.reset([.hud], context: .normal) }
        XCTAssertEqual(try AppConfig(toml: hud).keymap, Keymap.default)
        let rated = try edit(full) { editor in
            try editor.unbind(seq("shift+3"), context: .normal)
            try editor.reset([.rate(3), .next], context: .normal)
        }
        XCTAssertEqual(try AppConfig(toml: rated).keymap, Keymap.default)
        // With auto_advance, the plain key's own line ("meta.rate:3" = "3") is written back, at the end of the table;
        // the shift line it still has stays where it is.
        let advancing = full("auto_advance = false ", "auto_advance = true  ")
        let advanced = try edit(advancing) { editor in
            try editor.unbind(seq("3"), context: .normal)
            try editor.bind(seq("t"), to: [.rate(3), .next], context: .normal)
            try editor.reset([.rate(3), .next], context: .normal)
        }
        XCTAssertEqual(advanced, advancing.replacingOccurrences(of: "\"meta.rate:3\" = \"3\"\n", with: "")
            .replacingOccurrences(of: "\"app.open\" = \"cmd+o\"\n", with: "\"app.open\" = \"cmd+o\"\n\"meta.rate:3\" = \"3\"\n"))
        XCTAssertEqual(try AppConfig(toml: advanced).keymap, Keymap.written(vim: false, autoAdvance: true))
        // With vim, its keys are freed of their "none" (and k stays the file's).
        let vim = full("vim = false ", "vim = true  ")
        let freed = try edit(vim) { editor in
            try editor.unbind(seq("h"), context: .normal)
            try editor.reset([.previous], context: .normal)
        }
        XCTAssertEqual(freed, vim)
        XCTAssertEqual(try AppConfig(toml: freed).keymap, Keymap.written(vim: true, autoAdvance: false))
    }

    /// With the built-in keymap under the full file (`defaults = true`) and `auto_advance`, the file's culling lines
    /// advance, so ↺ on an advancing row finds them: here it takes the file's `9` back for the built-in one.
    func testResetFindsTheAdvancingKeysOfAFullFileWithTheBuiltInKeymapUnderIt() throws {
        var editor = ConfigEditor(text: full("\"meta.label:blue\" = \"9\"", "\"meta.label:purple\" = \"9\""))
        try editor.set("auto_advance", in: "rating", to: .bool(true))
        try editor.set("defaults", in: "keymap", to: .bool(true))
        XCTAssertEqual(try resolve(editor.text, "9"), .actions([.label("purple"), .next]))
        let reset = try edit(editor.text) { try $0.reset([.label("purple"), .next], context: .normal) }
        XCTAssertFalse(reset.contains("meta.label:purple"), reset)
        XCTAssertEqual(try resolve(reset, "9"), .actions([.label("blue"), .next]))
        XCTAssertEqual(try AppConfig(toml: reset).keymap, Keymap.build(defaults: true, vim: false, autoAdvance: true))
    }

    func testResetAllWritesTheKeysAnew() throws {
        let gray = full("background = \"black\"   ", "background = \"gray\"    ")
        var editor = ConfigEditor(text: gray)
        try editor.bind(seq("y"), to: [.copyName], context: .normal)
        try editor.unbind(seq("tab"), context: .normal)
        try editor.unbind(seq("left"), context: .zoomed)
        try editor.resetBindings()
        XCTAssertEqual(editor.text, gray, "every other line as it was")
        // Key tables elsewhere ([keys.normal] too): replaced at the end, the comment of the next table kept.
        let mixed = "[keymap]\ndefaults = false\n\n[keys.normal]\n\"n\" = \"nav.next\"\n# mine\n[view]\nbackground = \"gray\"\n[keys.zoomed]\n\"j\" = \"pan.down\"\n"
        let reset = try edit(mixed) { try $0.resetBindings() }
        XCTAssertEqual(reset, "[keymap]\ndefaults = false\n\n# mine\n[view]\nbackground = \"gray\"\n\n" + ConfigFile.keysText())
        XCTAssertEqual(try AppConfig(toml: reset).keymap, Keymap.default)
        XCTAssertEqual(try AppConfig(toml: reset).background, "gray")
    }

    // MARK: Conflicts

    func testConflictsNameTheActionThatOwnsTheKeys() {
        let keymap = Keymap.default
        XCTAssertEqual(keymap.conflicts(binding: seq("f"), to: [.trash], context: .normal),
                       [KeyConflict(sequence: seq("f"), actions: [.fullscreen], context: .normal, isPrefix: false)])
        XCTAssertEqual(keymap.conflicts(binding: seq("y"), to: [.trash], context: .normal), [], "a free key")
        XCTAssertEqual(keymap.conflicts(binding: seq("right"), to: [.next], context: .normal), [], "already so")
        XCTAssertEqual(keymap.conflicts(binding: seq("shift+3"), to: [.rate(3)], context: .normal),
                       [KeyConflict(sequence: seq("shift+3"), actions: [.rate(3), .next], context: .normal, isPrefix: false)])
    }

    func testSequencesConflictWithTheirPrefixes() throws {
        let vim = try AppConfig(toml: "[keymap]\nvim = true\n").keymap
        XCTAssertEqual(vim.conflicts(binding: seq("g"), to: [.trash], context: .normal),
                       [KeyConflict(sequence: seq("g g"), actions: [.first], context: .normal, isPrefix: true)])
        XCTAssertEqual(Keymap.default.conflicts(binding: seq("z z"), to: [.zoomFit], context: .normal),
                       [KeyConflict(sequence: seq("z"), actions: [.zoomToggle], context: .normal, isPrefix: true)])
        // A zoomed key that starts a sequence of [keys] conflicts too: zoomed falls back to it.
        XCTAssertEqual(vim.conflicts(binding: seq("g"), to: [.pan(.left)], context: .zoomed),
                       [KeyConflict(sequence: seq("g g"), actions: [.first], context: .normal, isPrefix: true)])
    }

    func testZoomedKeysOverrideNormalOnesWithoutConflict() {
        let keymap = Keymap.default
        XCTAssertEqual(keymap.conflicts(binding: seq("f"), to: [.pan(.left)], context: .zoomed), [])
        XCTAssertEqual(keymap.conflicts(binding: seq("left"), to: [.next], context: .zoomed),
                       [KeyConflict(sequence: seq("left"), actions: [.pan(.left)], context: .zoomed, isPrefix: false)])
    }

    /// "Press it again to move it": unbind what the keys would break, then bind them — one valid edit.
    func testMovingResolvesEveryConflict() throws {
        let text = "[keymap]\nvim = true\n"
        let keymap = try AppConfig(toml: text).keymap
        let conflicts = keymap.conflicts(binding: seq("g"), to: [.trash], context: .normal)
        let moved = try edit(text) { editor in
            for conflict in conflicts where conflict.isPrefix { try editor.unbind(conflict.sequence, context: conflict.context) }
            try editor.bind(seq("g"), to: [.trash], context: .normal)
        }
        XCTAssertEqual(moved, text + "\n[keys]\n\"g g\" = \"none\"\n\"g\" = \"file.trash\"\n")
        let config = try AppConfig(toml: moved)
        XCTAssertEqual(config.keymap.resolve(seq("g"), context: .normal), .actions([.trash]))
        XCTAssertTrue(config.keymap.conflicts().isEmpty)
    }

    func testBindingsByActionsGroupsKeys() {
        let groups = Keymap.default.bindingsByActions(.normal)
        XCTAssertEqual(groups[[.next]], [seq("down"), seq("pagedown"), seq("right"), seq("space")])
        XCTAssertEqual(groups[[.rate(3), .next]], [seq("shift+3")])
        XCTAssertNil(groups[[.pan(.left)]])
        XCTAssertEqual(Keymap.default.bindingsByActions(.zoomed)[[.pan(.left)]], [seq("left")])
    }
}
