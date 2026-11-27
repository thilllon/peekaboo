import XCTest
@testable import PeekabooCore

/// The config.toml Peekaboo writes (every setting active at its default, the whole keymap), its generations, and the
/// upgrade of the files earlier versions wrote. Files are temporary copies only: never the user's config.
final class ConfigFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("peekaboo-config-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func seq(_ spec: String) -> [KeyChord] { KeyChord.sequence(spec: spec)! }

    /// Every binding of a keymap, one sorted line each (`zoomed shift+left = pan.edge:left`), for readable diffs.
    private func lines(_ keymap: Keymap) -> [String] {
        [KeyContext.normal, .zoomed].flatMap { context in
            (keymap.bindings[context] ?? [:]).map { "\(context) \(KeyChord.spec(of: $0.key)) = \($0.value.map(\.id).joined(separator: ", "))" }
        }.sorted()
    }

    // MARK: The full file

    /// The issue's test: the written file parses to exactly the built-in configuration (`keymap.defaults` says the
    /// file lists the keymap) and exactly the built-in keymap, in both contexts.
    func testTheFullFileIsTheBuiltInConfiguration() throws {
        let (config, warnings) = try AppConfig.parse(toml: ConfigFile.defaultText)
        XCTAssertEqual(warnings, [])
        XCTAssertFalse(config.keymapDefaults, "the file is the whole keymap")
        var expected = AppConfig.default
        expected.keymapDefaults = false
        XCTAssertEqual(config, expected)
        XCTAssertEqual(lines(config.keymap), lines(Keymap.default))
        XCTAssertEqual(config.keymap.bindings[.normal], Keymap.default.bindings[.normal])
        XCTAssertEqual(config.keymap.bindings[.zoomed], Keymap.default.bindings[.zoomed])
        XCTAssertEqual(config.keymap, Keymap.default)
        XCTAssertEqual(try AppConfig.read(toml: ConfigFile.defaultText).generation, ConfigFile.generation)
        XCTAssertNoThrow(try AppConfig(toml: ConfigFile.defaultText), "strict parsing too")
    }

    /// Every setting is written, active (not commented out), with its comment; `[keymap]` says how to read the keys.
    func testEverySettingIsActive() throws {
        let document = try TOMLDocument(parsing: ConfigFile.defaultText)
        for setting in ConfigFile.settings {
            let entry = try XCTUnwrap(document.entries.first { $0.path == setting.path }, setting.path.joined(separator: "."))
            XCTAssertEqual(entry.value, setting.value(.default), setting.key)
            let line = ConfigFile.defaultText.split(separator: "\n").first { $0.hasPrefix(setting.key + " = ") && $0.contains("# " + setting.comment) }
            XCTAssertNotNil(line, "\(setting.key) has its comment")
        }
        XCTAssertEqual(document.value(["keymap", "defaults"]), .bool(false))
        XCTAssertEqual(document.value(["keymap", "generation"]), .integer(ConfigFile.generation))
        // The keys the parser reads as settings are exactly these (plus the two that describe the file).
        let settingPaths = Set(ConfigFile.settings.map(\.path) + [["keymap", "defaults"], ["keymap", "generation"]])
        let written = Set(document.entries.map(\.path).filter { !["keys", "slots", "apps"].contains($0[0]) })
        XCTAssertEqual(written, settingPaths)
        // Planned settings are named in prose only: nothing unknown is active.
        XCTAssertEqual(try AppConfig.parse(toml: ConfigFile.defaultText).warnings, [])
    }

    /// `Setting.value` is the inverse of the parser: a config with every setting changed, written, reads back the same.
    func testEverySettingRoundTrips() throws {
        var changed = AppConfig.default
        changed.background = "checker"
        changed.keepZoom = true
        changed.zoomStep = 1.5
        changed.refineDelayMs = 250
        changed.fullscreen = .native
        changed.avoidNotch = false
        changed.hud = .full
        changed.cacheBudgetMB = 2048
        changed.ratingStorage = .none
        changed.starCharacter = "*"
        changed.autoAdvance = true
        changed.decodeHDR = true
        changed.fastPath = false
        changed.trace = true
        changed.updates = AppConfig.Updates(check: false, autoInstall: false)
        changed.vimKeys = true
        let read = try AppConfig(toml: ConfigFile.text(settings: changed))
        var expected = changed
        expected.keymapDefaults = false
        expected.keymap = read.keymap
        XCTAssertEqual(read, expected)
        XCTAssertEqual(read.keymap, Keymap.written(vim: true, autoAdvance: true))
        // Every field of AppConfig (and of its [updates]) is a setting of the file, but the keymap, the slots, the apps
        // and keymapDefaults.
        let fields = Mirror(reflecting: AppConfig.default).children.count - 1 + Mirror(reflecting: AppConfig.default.updates).children.count
        XCTAssertEqual(fields, ConfigFile.settings.count + 4, "a new AppConfig field needs a ConfigFile.Setting")
    }

    /// The examples (slots, apps, more keys, "none") are comments; each is valid with the others uncommented, and none
    /// takes a key of the default keymap.
    func testTheExamplesAreValidWhenUncommented() throws {
        var uncommented = 0
        let edited = ConfigFile.defaultText.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard line.hasPrefix("# "), let entry = try? TOMLDocument(parsing: String(line.dropFirst(2))),
                  entry.entries.count == 1, entry.tables.isEmpty else { return String(line) }
            uncommented += 1
            return String(line.dropFirst(2))
        }
        XCTAssertEqual(uncommented, 12, "4 slots, 2 apps, 5 more keys, 1 zoomed key: \(edited)")
        let (config, warnings) = try AppConfig.parse(toml: edited.joined(separator: "\n"))
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(config.slots.count, 4)
        XCTAssertEqual(config.apps["preview"], "com.apple.Preview")
        XCTAssertEqual(config.keymap.resolve(seq("s"), context: .normal), .actions([.move("keep")]))
        XCTAssertEqual(config.keymap.resolve(seq("ctrl+x p"), context: .normal), .actions([.exec("open -a 'Pixelmator Pro' {path}")]))
        XCTAssertEqual(config.keymap.resolve(seq("space"), context: .zoomed), .actions([.pan(.down)]))
        // Apart from the example keys, the keymap is still the default one.
        var keymap = config.keymap
        for spec in ["s", "o", "ctrl+x o", "ctrl+x p"] { keymap.bind(seq(spec), to: [.none]) }
        keymap.bind(seq("space"), to: [.none], context: .zoomed)
        XCTAssertEqual(lines(keymap), lines(Keymap.default))
    }

    /// The file and the code's default layer are one table: `Keymap.default` is built from the groups the file lists.
    func testTheGroupsAreTheDefaultKeymap() throws {
        var keymap = Keymap.empty
        var seen = Set<String>()
        for binding in Keymap.defaultBindings {
            for (key, sequence) in zip(binding.keys, binding.sequences) {
                XCTAssertTrue(seen.insert("\(binding.context) \(KeyChord.spec(of: sequence))").inserted, "\(key) is bound twice")
                keymap.bind(sequence, to: binding.actions, context: binding.context)
            }
        }
        XCTAssertEqual(keymap, Keymap.default)
        // Each group is of one context, and [keys.zoomed] lists exactly the zoomed ones.
        for group in Keymap.defaultGroups { XCTAssertEqual(Set(group.bindings.map(\.context)).count, 1, group.title) }
        XCTAssertEqual(try AppConfig(toml: "[keymap]\ndefaults = false\n" + ConfigFile.keysText()).keymap, Keymap.default)
    }

    /// Generation 1 is the keymap and the settings of the first full file, frozen: a default binding or a setting added
    /// later gets the next generation (`.since(2)`, `Setting(…, generation: 2)`) and `ConfigFile.generation` is raised,
    /// so that full files written before get it appended (docs/CONFIG.md › Later versions). #93's new view action, for
    /// one: `n(.newAction, "x").since(2)` in its group, and `ConfigFile.generation = 2`.
    func testGenerationOneIsFrozen() throws {
        XCTAssertEqual(ConfigFile.generation, ConfigSchema.current.generation, "ConfigFile.generation is the newest generation")
        let generationOne = Keymap.defaultBindings.filter { $0.generation == 1 }.flatMap { binding in
            binding.keys.map { "\(binding.context == .normal ? "" : "zoomed ")\($0) = \(binding.actions.map(\.id).joined(separator: ", "))" }
        }
        XCTAssertEqual(generationOne, Self.generationOneKeys, "a default binding of a new action needs .since(\(ConfigFile.generation + 1))")
        XCTAssertEqual(ConfigFile.settings.filter { $0.generation == 1 }.map { "\($0.table).\($0.key)" }, [
            "view.background", "view.keep_zoom", "view.zoom_step", "view.refine_delay_ms", "fullscreen.mode",
            "fullscreen.avoid_notch", "hud.mode", "cache.memory_mb", "rating.storage", "rating.star", "rating.auto_advance",
            "decode.hdr", "decode.fast_path", "debug.trace", "updates.check", "updates.auto_install", "keymap.vim",
        ], "a new setting needs generation \(ConfigFile.generation + 1)")
        for binding in Keymap.defaultBindings { XCTAssertTrue((1...ConfigFile.generation).contains(binding.generation)) }
        for setting in ConfigFile.settings { XCTAssertTrue((1...ConfigFile.generation).contains(setting.generation)) }
    }

    /// The default keymap of generation 1, as config.toml lists it.
    private static let generationOneKeys = [
        "right = nav.next", "down = nav.next", "space = nav.next", "pagedown = nav.next",
        "left = nav.prev", "up = nav.prev", "shift+space = nav.prev", "backspace = nav.prev", "pageup = nav.prev",
        "home = nav.first", "cmd+up = nav.first", "end = nav.last", "cmd+down = nav.last",
        "[ = nav.jump:-10", "] = nav.jump:+10",
        "z = zoom.toggle", "cmd+0 = zoom.fit", "cmd+9 = zoom.fit", "cmd+1 = zoom.actual", "cmd+2 = zoom.set:2",
        "cmd+4 = zoom.set:4", "cmd+shift+0 = zoom.fill", "= = zoom.in", "+ = zoom.in", "cmd+= = zoom.in",
        "cmd+shift+= = zoom.in", "- = zoom.out", "cmd+- = zoom.out", "shift+z = zoom.keep",
        "f = view.fullscreen", "return = view.fullscreen", "ctrl+cmd+f = view.fullscreen", "esc = app.escape",
        "i = view.hud", "tab = view.hud_hide", "b = view.background", "r = view.rotate_cw", "cmd+r = view.rotate_cw",
        "> = view.rotate_cw", "shift+r = view.rotate_ccw", "cmd+l = view.rotate_ccw", "< = view.rotate_ccw",
        "| = view.flip_h", "_ = view.flip_v",
        "k = view.play_pause", ". = view.frame_next", ", = view.frame_prev",
        "cmd+backspace = file.trash", "forwarddelete = file.trash", "cmd+z = app.undo", "cmd+shift+z = app.redo",
        "m = file.move:ask", "c = file.copy:ask", "cmd+shift+r = file.reveal", "cmd+c = file.copy_image",
        "opt+cmd+c = file.copy_path", "e = file.open_with:editor", "shift+e = file.open_with_chooser",
    ] + (1...9).flatMap { ["opt+\($0) = file.move:\($0)", "opt+shift+\($0) = file.copy:\($0)"] } + [
        "0 = meta.rate:0", "1 = meta.rate:1", "2 = meta.rate:2", "3 = meta.rate:3", "4 = meta.rate:4", "5 = meta.rate:5",
        "6 = meta.label:red", "7 = meta.label:yellow", "8 = meta.label:green", "9 = meta.label:blue",
        "p = meta.flag:pick", "x = meta.flag:reject", "u = meta.flag:none",
        "shift+0 = meta.rate:0, nav.next", "shift+1 = meta.rate:1, nav.next", "shift+2 = meta.rate:2, nav.next",
        "shift+3 = meta.rate:3, nav.next", "shift+4 = meta.rate:4, nav.next", "shift+5 = meta.rate:5, nav.next",
        "shift+6 = meta.label:red, nav.next", "shift+7 = meta.label:yellow, nav.next", "shift+8 = meta.label:green, nav.next",
        "shift+9 = meta.label:blue, nav.next", "shift+p = meta.flag:pick, nav.next", "shift+x = meta.flag:reject, nav.next",
        "shift+u = meta.flag:none, nav.next",
        "v = view.picks_only", "shift+c = file.copy_picks:ask",
        "cmd+, = app.config", "? = view.help", "cmd+/ = view.help", "cmd+w = app.close", "q = app.close",
        "cmd+q = app.quit", "cmd+o = app.open",
        "zoomed left = pan.left", "zoomed right = pan.right", "zoomed up = pan.up", "zoomed down = pan.down",
        "zoomed shift+left = pan.edge:left", "zoomed shift+right = pan.edge:right", "zoomed shift+up = pan.edge:top",
        "zoomed shift+down = pan.edge:bottom",
    ]

    // MARK: Reading a file that lists the keymap

    /// Deleting a line unbinds its keys, changing a key moves the binding: nothing comes back from the code.
    func testTheFileIsTheWholeKeymap() throws {
        let deleted = ConfigFile.defaultText.replacingOccurrences(of: "\"view.hud_hide\" = \"tab\"\n", with: "")
        XCTAssertNotEqual(deleted, ConfigFile.defaultText)
        XCTAssertEqual(try AppConfig(toml: deleted).keymap.resolve(seq("tab"), context: .normal), .unbound)
        let moved = ConfigFile.defaultText.replacingOccurrences(of: "\"view.fullscreen\" = [\"f\",", with: "\"view.fullscreen\" = [\"g\",")
        let keymap = try AppConfig(toml: moved).keymap
        XCTAssertEqual(keymap.resolve(seq("f"), context: .normal), .unbound)
        XCTAssertEqual(keymap.resolve(seq("g"), context: .normal), .actions([.fullscreen]))
        let zoomed = ConfigFile.defaultText.replacingOccurrences(of: "\"pan.left\" = \"left\"\n", with: "")
        XCTAssertEqual(try AppConfig(toml: zoomed).keymap.resolve(seq("left"), context: .zoomed), .actions([.previous]),
                       "a zoomed key the file no longer binds falls back to [keys]")
    }

    /// `vim = true` adds the vim layer on the keys the file leaves free: the file's `k` (play / pause) stays.
    func testTheVimLayerGoesUnderTheFile() throws {
        let text = ConfigFile.defaultText.replacingOccurrences(of: "vim = false ", with: "vim = true  ")
        let keymap = try AppConfig(toml: text).keymap
        XCTAssertEqual(keymap, Keymap.written(vim: true, autoAdvance: false))
        XCTAssertEqual(keymap.resolve(seq("k"), context: .normal), .actions([.playPause]), "the file's line wins")
        XCTAssertEqual(keymap.resolve(seq("h"), context: .normal), .actions([.previous]))
        XCTAssertEqual(keymap.resolve(seq("g g"), context: .normal), .actions([.first]))
        XCTAssertEqual(keymap.resolve(seq("k"), context: .zoomed), .actions([.pan(.up)]))
        XCTAssertTrue(keymap.conflicts().isEmpty)
        // Everything else is the vim layer on the default keymap.
        var builtIn = Keymap.build(defaults: true, vim: true, autoAdvance: false)
        builtIn.bind(seq("k"), to: [.playPause])
        XCTAssertEqual(lines(keymap), lines(builtIn))
        // Deleting the line gives k to the vim layer; "none" removes a vim key.
        let free = text.replacingOccurrences(of: "\"view.play_pause\" = \"k\"\n", with: "")
            .replacingOccurrences(of: "# \"d d\" = \"none\"", with: "\"d d\" = \"none\"")
        let freed = try AppConfig(toml: free).keymap
        XCTAssertEqual(freed.resolve(seq("k"), context: .normal), .actions([.previous]))
        XCTAssertEqual(freed.resolve(seq("d d"), context: .normal), .unbound)
    }

    /// `auto_advance = true` makes the file's plain rating, label and flag keys advance, as it does the built-in ones.
    func testAutoAdvanceAppliesToTheFilesCullingKeys() throws {
        let text = ConfigFile.defaultText.replacingOccurrences(of: "auto_advance = false ", with: "auto_advance = true  ")
        let keymap = try AppConfig(toml: text).keymap
        XCTAssertEqual(keymap, Keymap.build(defaults: true, vim: false, autoAdvance: true))
        XCTAssertEqual(keymap, Keymap.written(vim: false, autoAdvance: true))
        XCTAssertEqual(keymap.resolve(seq("3"), context: .normal), .actions([.rate(3), .next]))
        XCTAssertEqual(keymap.resolve(seq("shift+3"), context: .normal), .actions([.rate(3), .next]))
        // A culling key moved to another key does not advance; another action on a culling key does.
        let moved = text.replacingOccurrences(of: "\"meta.rate:3\" = \"3\"", with: "\"meta.rate:3\" = \"t\"")
            .replacingOccurrences(of: "\"meta.label:blue\" = \"9\"", with: "\"meta.label:purple\" = \"9\"")
        let movedKeymap = try AppConfig(toml: moved).keymap
        XCTAssertEqual(movedKeymap.resolve(seq("t"), context: .normal), .actions([.rate(3)]))
        XCTAssertEqual(movedKeymap.resolve(seq("9"), context: .normal), .actions([.label("purple"), .next]))
        // An older file (the built-in keymap, its entries on top) is read as before: its own entries do not advance.
        let old = try AppConfig(toml: "[rating]\nauto_advance = true\n[keys]\n\"9\" = \"meta.label:purple\"\n").keymap
        XCTAssertEqual(old.resolve(seq("9"), context: .normal), .actions([.label("purple")]))
        XCTAssertEqual(old.resolve(seq("3"), context: .normal), .actions([.rate(3), .next]))
    }

    /// With the built-in keymap under the full file too (`defaults = true`: Settings' "Add built-in shortcuts config.toml
    /// does not list", or the line deleted), its culling lines still advance: they are the file's own bindings.
    func testAutoAdvanceAppliesToAFullFileWithTheBuiltInKeymapUnderIt() throws {
        var editor = ConfigEditor(text: ConfigFile.defaultText)
        try editor.set("auto_advance", in: "rating", to: .bool(true))
        try editor.set("defaults", in: "keymap", to: .bool(true))
        var deleted = editor
        try deleted.remove("defaults", in: "keymap")
        for text in [editor.text, deleted.text] {
            let config = try AppConfig(toml: text)
            XCTAssertTrue(config.keymapDefaults)
            XCTAssertEqual(config.keymap.resolve(seq("3"), context: .normal), .actions([.rate(3), .next]))
            XCTAssertEqual(config.keymap.resolve(seq("p"), context: .normal), .actions([.flag("pick"), .next]))
            XCTAssertEqual(config.keymap, Keymap.build(defaults: true, vim: false, autoAdvance: true))
        }
        // Another action on a culling key advances, as with defaults = false.
        let moved = editor.text.replacingOccurrences(of: "\"meta.label:blue\" = \"9\"", with: "\"meta.label:purple\" = \"9\"")
        XCTAssertNotEqual(moved, editor.text)
        XCTAssertEqual(try AppConfig(toml: moved).keymap.resolve(seq("9"), context: .normal), .actions([.label("purple"), .next]))
    }

    /// The default keys name the slots 1…9 whether they are set or not; another unknown slot is still an error.
    func testTheNumberedSlotsNeedNoEntry() throws {
        XCTAssertNoThrow(try AppConfig(toml: "[keys]\n\"file.move:4\" = \"opt+4\"\n\"x\" = \"file.copy:9\"\n"))
        XCTAssertThrowsError(try AppConfig(toml: "[keys]\n\"x\" = \"file.copy:10\"\n"))
        XCTAssertThrowsError(try AppConfig(toml: "[keys]\n\"x\" = \"file.move:keep\"\n"))
    }

    // MARK: Generations

    /// A later version: `y` for `file.copy_name` and `debug.trace` are generation 2.
    private var later: ConfigSchema {
        let settings = ConfigFile.settings.map { setting in
            setting.path == ["debug", "trace"] ? ConfigFile.Setting(setting.table, setting.key, setting.comment, generation: 2, setting.value) : setting
        }
        let added = Keymap.DefaultGroup(title: "Added", bindings: [
            Keymap.DefaultBinding(.normal, [.copyName], ["y"]).since(2),
            Keymap.DefaultBinding(.zoomed, [.panCenter], ["shift+m"]).since(2),
        ])
        return ConfigSchema(settings: settings, keyGroups: Keymap.defaultGroups + [added])
    }

    /// The file of generation 1 that the later version would have written then.
    private var generationOne: String { ConfigFile.text(later, generation: 1) }

    func testALaterVersionReadsAnOlderFileWithItsNewDefaultKeys() throws {
        XCTAssertEqual(later.generation, 2)
        XCTAssertFalse(generationOne.contains("trace = "))
        XCTAssertFalse(generationOne.contains("file.copy_name"))
        let reading = try AppConfig.read(toml: generationOne, schema: later)
        XCTAssertEqual(reading.generation, 1)
        XCTAssertEqual(reading.config.keymap.resolve(seq("y"), context: .normal), .actions([.copyName]), "before the file is upgraded")
        XCTAssertEqual(reading.config.keymap.resolve(seq("shift+m"), context: .zoomed), .actions([.panCenter]))
        XCTAssertEqual(reading.added.map(\.keys), [["y"], ["shift+m"]])
        // Read by this version (generation 1), the same file has no such keys.
        XCTAssertEqual(try AppConfig.read(toml: generationOne).config.keymap.resolve(seq("y"), context: .normal), .unbound)
        // A key the file uses keeps the file's binding: bound, unbound with "none", or a prefix of a sequence.
        for (line, spec) in [("\"y\" = \"file.trash\"", "y"), ("\"y\" = \"none\"", "y"), ("\"y y\" = \"file.trash\"", "y y")] {
            let text = generationOne.replacingOccurrences(of: "\n[keys.zoomed]", with: "\(line)\n\n[keys.zoomed]")
            let read = try AppConfig.read(toml: text, schema: later)
            XCTAssertEqual(read.added.map(\.keys), [["shift+m"]], line)
            XCTAssertEqual(read.config.keymap.resolve(seq(spec), context: .normal),
                           line.contains("none") ? .unbound : .actions([.trash]), line)
        }
        // A file of generation 2 gets nothing more.
        let current = try AppConfig.read(toml: ConfigFile.text(later), schema: later)
        XCTAssertEqual(current.added.map(\.keys), [])
        let deleted = ConfigFile.text(later).replacingOccurrences(of: "\"file.copy_name\" = \"y\"\n", with: "")
        XCTAssertEqual(try AppConfig.read(toml: deleted, schema: later).config.keymap.resolve(seq("y"), context: .normal),
                       .unbound, "a binding of generation 2 deleted from a file of generation 2 never comes back")
    }

    func testTheUpgradeAppendsTheLaterSettingsAndKeysOnce() throws {
        let (upgraded, upgrade) = try XCTUnwrap(ConfigStore.upgraded(generationOne, schema: later))
        XCTAssertEqual(upgrade, .appended(from: 1, to: 2))
        // The configuration in effect does not change.
        XCTAssertEqual(try AppConfig.read(toml: upgraded, schema: later).config, try AppConfig.read(toml: generationOne, schema: later).config)
        XCTAssertTrue(upgraded.contains("\n[debug]\n" + ConfigFile.commented("trace = false", "timestamped trace lines on stderr (PEEKABOO_TRACE=1 forces it)") + "\n"), upgraded)
        XCTAssertTrue(upgraded.contains("\"app.open\" = \"cmd+o\"\n\"file.copy_name\" = \"y\"\n"), "appended to [keys]")
        XCTAssertTrue(upgraded.contains("\"pan.edge:bottom\" = \"shift+down\"\n\"pan.center\" = \"shift+m\"\n"), "and to [keys.zoomed]")
        XCTAssertTrue(upgraded.contains(ConfigFile.commented("generation = 2", "the default keys and settings of later versions this file has")))
        let reading = try AppConfig.read(toml: upgraded, schema: later)
        XCTAssertEqual(reading.generation, 2)
        XCTAssertEqual(reading.added.map(\.keys), [])
        XCTAssertNil(ConfigStore.upgraded(upgraded, schema: later), "once")
        // Every other line is as it was.
        var lines = generationOne.components(separatedBy: "\n")
        for line in upgraded.components(separatedBy: "\n") { if let index = lines.firstIndex(of: line) { lines.remove(at: index) } }
        XCTAssertEqual(lines, [ConfigFile.commented("generation = 1", "the default keys and settings of later versions this file has")])

        // A key the user took meanwhile is not taken, and a setting the user set is kept.
        let mine = generationOne.replacingOccurrences(of: "\n[keys.zoomed]", with: "\"y\" = \"file.trash\"\n\n[keys.zoomed]")
            .replacingOccurrences(of: "[debug]\n", with: "[debug]\ntrace = true\n")
        let (kept, _) = try XCTUnwrap(ConfigStore.upgraded(mine, schema: later))
        let keptConfig = try AppConfig.read(toml: kept, schema: later).config
        XCTAssertEqual(keptConfig.keymap.resolve(seq("y"), context: .normal), .actions([.trash]))
        XCTAssertTrue(keptConfig.trace)
        XCTAssertFalse(kept.contains("file.copy_name"))
    }

    /// A full file with the built-in keymap under it (`defaults = true`) gets the later keys appended too, as the file
    /// lists keys: nothing changes in effect (the built-in keymap has them), and the file has them when it is the whole
    /// keymap again. A key its own lines use is not taken.
    func testTheUpgradeAppendsTheLaterKeysWithTheBuiltInKeymapUnderTheFile() throws {
        var editor = ConfigEditor(text: generationOne)
        try editor.set("defaults", in: "keymap", to: .bool(true))
        let text = editor.text
        let reading = try AppConfig.read(toml: text, schema: later)
        XCTAssertEqual(reading.config.keymap.resolve(seq("y"), context: .normal), .actions([.copyName]), "the later version's built-in key")
        XCTAssertEqual(reading.added.map(\.keys), [["y"], ["shift+m"]])
        let (upgraded, upgrade) = try XCTUnwrap(ConfigStore.upgraded(text, schema: later))
        XCTAssertEqual(upgrade, .appended(from: 1, to: 2))
        XCTAssertTrue(upgraded.contains("\"app.open\" = \"cmd+o\"\n\"file.copy_name\" = \"y\"\n"), upgraded)
        XCTAssertTrue(upgraded.contains("\"pan.edge:bottom\" = \"shift+down\"\n\"pan.center\" = \"shift+m\"\n"))
        XCTAssertTrue(upgraded.contains("\n[debug]\n" + ConfigFile.commented("trace = false", "timestamped trace lines on stderr (PEEKABOO_TRACE=1 forces it)") + "\n"))
        XCTAssertNil(ConfigStore.upgraded(upgraded, schema: later), "once")
        var off = ConfigEditor(text: upgraded)
        try off.set("defaults", in: "keymap", to: .bool(false))
        let whole = try AppConfig.read(toml: off.text, schema: later).config.keymap
        XCTAssertEqual(whole.resolve(seq("y"), context: .normal), .actions([.copyName]))
        XCTAssertEqual(whole.resolve(seq("shift+m"), context: .zoomed), .actions([.panCenter]))

        let mine = text.replacingOccurrences(of: "\n[keys.zoomed]", with: "\"y\" = \"file.trash\"\n\n[keys.zoomed]")
        XCTAssertEqual(try AppConfig.read(toml: mine, schema: later).added.map(\.keys), [["shift+m"]])
        let (kept, _) = try XCTUnwrap(ConfigStore.upgraded(mine, schema: later))
        XCTAssertFalse(kept.contains("file.copy_name"), kept)
        XCTAssertEqual(try AppConfig.read(toml: kept, schema: later).config.keymap.resolve(seq("y"), context: .normal), .actions([.trash]))
    }

    /// A deleted binding of the file's own generation never comes back, whatever later versions add.
    func testADeletedBindingNeverComesBack() throws {
        let deleted = generationOne.replacingOccurrences(of: "\"view.hud\" = \"i\"\n", with: "")
        let (upgraded, _) = try XCTUnwrap(ConfigStore.upgraded(deleted, schema: later))
        XCTAssertFalse(upgraded.contains("\"view.hud\""))
        XCTAssertEqual(try AppConfig.read(toml: upgraded, schema: later).config.keymap.resolve(seq("i"), context: .normal), .unbound)
    }

    // MARK: Upgrading the files of earlier versions

    /// Every starter file a version wrote, untouched, becomes the full file; a byte order mark, CRLF line ends and the
    /// line ends at the end of the file do not count.
    func testAnUntouchedStarterFileBecomesTheFullFile() throws {
        XCTAssertEqual(LegacyConfigFiles.starters.count, 5)
        for starter in LegacyConfigFiles.starters {
            for text in ["\u{FEFF}" + starter, starter.replacingOccurrences(of: "\n", with: "\r\n"), String(starter.dropLast()),
                         starter + "\n\n", starter] {
                let (upgraded, upgrade) = try XCTUnwrap(ConfigStore.upgraded(text), String(text.prefix(60)))
                XCTAssertEqual(upgrade, .rewroteStarter)
                XCTAssertEqual(upgraded, ConfigFile.defaultText)
            }
        }
    }

    /// Any file with an active line, or that is not a starter file exactly, is the user's: never rewritten. A starter
    /// file the user wrote in without changing what it applies keeps what they wrote.
    func testOtherFilesAreLeftAsTheyAre() throws {
        let starter = LegacyConfigFiles.releasedStarter
        let cases = [
            starter.replacingOccurrences(of: "# [view]\n# background = \"black\"", with: "[view]\nbackground = \"gray\""),
            starter.replacingOccurrences(of: "# [view]\n", with: "[view]\n"),  // a table, no setting
            "# my notes\n# [view]\n# background = \"gray\"\n",  // comments, not a starter file
            // The starter file with the user's notes, a binding of theirs commented out for now, a commented-out value
            // changed, a line deleted.
            starter + "# Slot 1 is the client folder.\n# \"s\" = \"file.move:keep\"   # my keep key, off for now\n",
            starter.replacingOccurrences(of: "# background = \"black\" ", with: "# background = \"gray\"  "),
            starter.replacingOccurrences(of: "# star = \"★\"                    # 3 stars -> Finder tag \"★★★\"\n", with: ""),
            "# Peekaboo configuration: my own\n",
            "",
            "\n\n",
            "[view]\nbackground = \"gray\"\n",
            "[keymap]\ndefaults = false\n[keys]\n\"n\" = \"nav.next\"\n",  // an empty-start keymap of the user's, no generation
            "[view]\nbackground = \"pink\"\n",  // an error: the user's to fix
            starter + "[view\n",
            ConfigFile.defaultText,  // this generation
            ConfigFile.defaultText.replacingOccurrences(of: "generation = 1 ", with: "generation = 7 "),  // a newer version's
        ]
        for text in cases {
            XCTAssertNotEqual(text, starter)
            XCTAssertNil(ConfigStore.upgraded(text), text)
        }
    }

    /// Through the store, as a second after launch: atomic, the link and the permissions kept, applied at once.
    func testTheStoreUpgradesAStarterFileInPlace() throws {
        let real = directory.appendingPathComponent("dotfiles/peekaboo.toml")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(LegacyConfigFiles.releasedStarter.utf8).write(to: real)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path)
        let link = directory.appendingPathComponent("config.toml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let store = ConfigStore(url: link)
        store.load()
        XCTAssertTrue(store.config.keymapDefaults)
        var notified = 0
        let observer = NotificationCenter.default.addObserver(forName: ConfigStore.didLoadNotification, object: store,
                                                              queue: nil) { _ in notified += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        XCTAssertEqual(upgrade(store), .rewroteStarter)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), real.path, "still a link")
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), ConfigFile.defaultText)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertFalse(store.config.keymapDefaults, "applied")
        XCTAssertEqual(store.config.keymap, Keymap.default)
        XCTAssertEqual(store.text, ConfigFile.defaultText)
        XCTAssertEqual(notified, 1)
        XCTAssertEqual(upgrade(store), .nothing, "nothing more to do")
        XCTAssertEqual(notified, 1)
    }

    func testTheStoreNeverCreatesOrTouchesAnotherFile() throws {
        let url = directory.appendingPathComponent("config.toml")
        let store = ConfigStore(url: url)
        XCTAssertEqual(upgrade(store), .nothing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "no file is created")
        let mine = Data("# mine\n[view]\nbackground = \"gray\"\n".utf8)
        try mine.write(to: url)
        let notUTF8 = Data(Array("# Peekaboo configuration caf".utf8) + [0xE9] + Array("\n".utf8))
        for bytes in [mine, notUTF8] {
            try bytes.write(to: url)
            let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
            XCTAssertEqual(upgrade(store), .nothing)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, modified)
        }
    }

    /// `app.config_file`: the full file when there is none, the starter file brought up to date, a file of the user's
    /// as it is.
    func testPrepareFileForTheEditor() throws {
        let url = directory.appendingPathComponent("nested/config.toml")
        let store = ConfigStore(url: url)
        XCTAssertEqual(prepare(store), url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), ConfigFile.defaultText)
        XCTAssertFalse(store.config.keymapDefaults, "applied")
        try Data(LegacyConfigFiles.releasedStarter.utf8).write(to: url)
        XCTAssertEqual(prepare(store), url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), ConfigFile.defaultText)
        try Data("[view]\nbackground = \"gray\"\n".utf8).write(to: url)
        XCTAssertEqual(prepare(store), url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "[view]\nbackground = \"gray\"\n")
    }

    /// A Settings change to an untouched starter file writes the full file with the change.
    func testAnEditOfAStarterFileWritesTheFullFile() throws {
        let url = directory.appendingPathComponent("config.toml")
        try Data(LegacyConfigFiles.releasedStarter.utf8).write(to: url)
        let store = ConfigStore(url: url)
        store.load()
        let done = expectation(description: "edited")
        store.edit({ try $0.set("background", in: "view", to: .string("gray")) }) { error in
            XCTAssertNil(error)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text, ConfigFile.defaultText.replacingOccurrences(of: "background = \"black\"   ", with: "background = \"gray\"    "))
        XCTAssertEqual(store.config.background, "gray")
        XCTAssertEqual(store.config.keymap, Keymap.default)
    }

    private func upgrade(_ store: ConfigStore) -> ConfigStore.Upgrade? {
        let done = expectation(description: "upgraded")
        var result: ConfigStore.Upgrade?
        store.upgradeFile { result = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        return result
    }

    private func prepare(_ store: ConfigStore) -> URL? {
        let done = expectation(description: "prepared")
        var url: URL?
        store.prepareFile { url = try? $0.get(); done.fulfill() }
        wait(for: [done], timeout: 5)
        return url
    }
}
