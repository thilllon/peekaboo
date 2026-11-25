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
        let starter = ConfigStore.sampleConfig
        let text = try edit(starter) { try $0.bind(seq("y"), to: [.copyName], context: .normal) }
        XCTAssertTrue(text.contains("\n[keys]                        # \"chord\" = \"action\" or [\"action\", ...]; \"none\" removes a default binding\n\"y\" = \"file.copy_name\"\n# \"k\" = \"file.move:keep\""), text)
        XCTAssertEqual(try resolve(text, "y"), .actions([.copyName]))
        var expected = Keymap.default
        expected.bind(seq("y"), to: [.copyName])
        XCTAssertEqual(try AppConfig(toml: text).keymap, expected)
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
