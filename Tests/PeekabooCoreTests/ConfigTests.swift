import XCTest
@testable import PeekabooCore

final class ConfigTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("peekaboo-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func errors(_ text: String) -> [String] {
        do {
            _ = try AppConfig(toml: text)
            return []
        } catch let error as ConfigError {
            return error.messages
        } catch {
            return ["\(error)"]
        }
    }

    func testEmptyFileIsTheDefault() throws {
        XCTAssertEqual(try AppConfig(toml: ""), AppConfig.default)
        XCTAssertEqual(try AppConfig(toml: "# only comments\n\n"), AppConfig.default)
        // The starter file of earlier versions (all comments) changes nothing.
        XCTAssertEqual(LegacyConfigFiles.releasedStarter.utf8.count, 3650, "the fixture is the released file, byte for byte")
        XCTAssertEqual(try AppConfig(toml: LegacyConfigFiles.releasedStarter), AppConfig.default)
        XCTAssertEqual(try AppConfig(toml: LegacyConfigFiles.firstStarter), AppConfig.default)
    }

    func testMapsEveryKey() throws {
        let config = try AppConfig(toml: """
        [view]
        background = "checker"
        keep_zoom = true
        zoom_step = 1.5
        refine_delay_ms = 120
        [fullscreen]
        mode = "native"
        avoid_notch = false
        [hud]
        mode = "full"
        [cache]
        memory_mb = 2048
        [rating]
        storage = "none"
        star = "*"
        auto_advance = true
        [keymap]
        defaults = true
        vim = true
        [slots]
        1 = "~/Pictures/Keep"
        keep = "./_keep"
        [apps]
        editor = "com.pixelmatorteam.pixelmator.x"
        """)
        XCTAssertEqual(config.background, "checker")
        XCTAssertTrue(config.keepZoom)
        XCTAssertEqual(config.zoomStep, 1.5)
        XCTAssertEqual(config.refineDelayMs, 120)
        XCTAssertEqual(config.fullscreen, .native)
        XCTAssertFalse(config.avoidNotch)
        XCTAssertEqual(config.hud, .full)
        XCTAssertEqual(config.cacheBudgetMB, 2048)
        XCTAssertEqual(config.ratingStorage, AppConfig.RatingStorage.none)
        XCTAssertEqual(config.starCharacter, "*")
        XCTAssertEqual(config.keymap.resolve(KeyChord.sequence(spec: "3")!, context: .normal), .actions([.rate(3), .next]))
        XCTAssertEqual(config.slots, ["1": "~/Pictures/Keep", "keep": "./_keep"])
        XCTAssertEqual(config.apps, ["editor": "com.pixelmatorteam.pixelmator.x"])
        XCTAssertEqual(config.keymap.resolve(KeyChord.sequence(spec: "g g")!, context: .normal), .actions([.first]))
        XCTAssertEqual(try AppConfig(toml: "[cache]\nmemory_mb = \"auto\"\n").cacheBudgetMB, nil)
    }

    func testDecodeAndDebugSwitches() throws {
        XCTAssertFalse(AppConfig.default.decodeHDR)
        XCTAssertTrue(AppConfig.default.fastPath)
        XCTAssertFalse(AppConfig.default.trace)
        let config = try AppConfig(toml: "[decode]\nhdr = true\nfast_path = false\n[debug]\ntrace = true\n")
        XCTAssertTrue(config.decodeHDR)
        XCTAssertFalse(config.fastPath)
        XCTAssertTrue(config.trace)
        XCTAssertEqual(errors("[decode]\nhdr = \"yes\"\n"), ["config.toml:2: decode.hdr must be true or false, got string"])
        XCTAssertEqual(errors("[view]\nhdr = true\n"), ["config.toml:2: unknown key \"view.hdr\" (it belongs under [decode])"])
        XCTAssertEqual(errors("[decode]\ntrace = true\n"), ["config.toml:2: unknown key \"decode.trace\" (it belongs under [debug])"])
        // The keymap layers are kept as set, next to the keymap built from them.
        let layers = try AppConfig(toml: "[keymap]\ndefaults = false\nvim = true\n[rating]\nauto_advance = true\n")
        XCTAssertFalse(layers.keymapDefaults)
        XCTAssertTrue(layers.vimKeys)
        XCTAssertTrue(layers.autoAdvance)
        XCTAssertEqual(layers.keymap, Keymap.build(defaults: false, vim: true, autoAdvance: true))
    }

    func testErrorsNameTheLine() {
        let messages = errors("""
        [view]
        background = "pink"
        fit = "fill"
        keep_zoom = "yes"
        [general]
        [keys]
        "right" = "nav.nxt"
        "hyper+k" = "nav.next"
        "j" = "file.move:nowhere"
        "+" = "zoom.in"
        "shift+=" = "zoom.out"
        "q" = []
        "w" = 3
        [keys.other]
        "a" = "nav.next"
        """)
        XCTAssertEqual(messages, [
            "config.toml:2: view.background must be one of \"black\", \"gray\", \"checker\"",
            "config.toml:3: unknown key \"view.fit\"",
            "config.toml:4: view.keep_zoom must be true or false, got string",
            "config.toml:5: unknown table [general]",
            "config.toml:7: unknown action \"nav.nxt\" (did you mean \"nav.next\"?)",
            "config.toml:8: \"hyper+k\": unknown modifier \"hyper\" (use cmd, opt, ctrl or shift)",
            "config.toml:9: unknown slot \"nowhere\" (add it under [slots])",
            "config.toml:11: \"shift+=\" is already bound on line 10",
            "config.toml:12: empty action list (use \"none\" to unbind)",
            "config.toml:13: expected an action string or a list of actions, got integer",
            "config.toml:14: unknown table [keys.other]",
            "config.toml:15: unknown key \"keys.other.a\" (bindings go in [keys] or [keys.zoomed])",
        ])
        XCTAssertEqual(errors("a = \n"), ["config.toml:1: expected a value"])
        XCTAssertEqual(errors("background = \"gray\"\n"), ["config.toml:1: unknown key \"background\" (it belongs under [view])"])
        XCTAssertEqual(errors("[hud]\nvim = true\n"), ["config.toml:2: unknown key \"hud.vim\" (it belongs under [keymap])"])
        XCTAssertEqual(errors("\"k\" = \"nav.next\"\n"), ["config.toml:1: unknown key \"k\" (key bindings go under [keys])"])
        XCTAssertEqual(errors("[keys]\n\"1\" = \"meta.rate:9\"\n"), ["config.toml:2: unknown action \"meta.rate:9\" (check its argument)"])
        XCTAssertEqual(errors("[keys]\n\"1\" = [\"none\", \"nav.next\"]\n"), ["config.toml:2: \"none\" cannot be part of an action list"])
    }

    func testUnknownKeysAreWarningsThatKeepTheRest() throws {
        // Keys from the research sample that are not implemented, mixed with real settings.
        let (config, warnings) = try AppConfig.parse(toml: """
        [general]
        sort = "name"
        [view]
        background = "gray"
        fit = "fit"
        [hud]
        mode = "full"
        position = "bottom-left"
        [rating]
        star_char = "*"
        [keys]
        "k" = "nav.next"
        [keys.other]
        "a" = "nav.next"
        """)
        XCTAssertEqual(config.background, "gray")
        XCTAssertEqual(config.hud, .full)
        XCTAssertEqual(config.keymap.resolve([KeyChord(key: "k")], context: .normal), .actions([.next]))
        XCTAssertEqual(warnings, [
            "config.toml:1: ignored unknown table [general]",
            "config.toml:2: ignored unknown key \"general.sort\"",
            "config.toml:5: ignored unknown key \"view.fit\"",
            "config.toml:8: ignored unknown key \"hud.position\"",
            "config.toml:10: ignored unknown key \"rating.star_char\"",
            "config.toml:13: ignored unknown table [keys.other]",
            "config.toml:14: ignored unknown key \"keys.other.a\" (bindings go in [keys] or [keys.zoomed])",
        ])
        // Anything else still rejects the whole file, listing the warnings' lines too.
        XCTAssertThrowsError(try AppConfig.parse(toml: "[view]\nfit = \"fit\"\nbackground = \"pink\"\n")) { error in
            XCTAssertEqual((error as? ConfigError)?.messages, [
                "config.toml:2: unknown key \"view.fit\"",
                "config.toml:3: view.background must be one of \"black\", \"gray\", \"checker\"",
            ])
        }
        // The strict initializer still rejects unknown keys.
        XCTAssertThrowsError(try AppConfig(toml: "[view]\nfit = \"fit\"\n"))
    }

    /// The file `app.config_file` creates is the full file, and the store loads it as the built-in configuration with
    /// zero errors and zero warnings.
    func testTheCreatedFileLoadsWithoutErrors() throws {
        let url = directory.appendingPathComponent("config.toml")
        let store = ConfigStore(url: url)
        XCTAssertTrue(try store.createDefaultFileIfMissing())
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(written, ConfigFile.defaultText)
        store.load()
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.warnings, [])
        XCTAssertEqual(store.config.keymap, Keymap.default)
        XCTAssertFalse(store.config.keymapDefaults)
    }

    func testStoreAppliesAFileWithUnknownKeysAndReportsThem() throws {
        let url = directory.appendingPathComponent("config.toml")
        try Data("[view]\nbackground = \"checker\"\nfit = \"fill\"\n[loading]\npreview_max_px = 1024\n".utf8).write(to: url)
        let store = ConfigStore(url: url)
        var messages: [String] = []
        var changes = 0
        store.onError = { messages.append($0) } // also gets warnings when onWarning is nil
        store.onChange = { _ in changes += 1 }
        store.load()
        XCTAssertEqual(store.config.background, "checker")
        XCTAssertEqual(changes, 1)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.warnings, [
            "config.toml:3: ignored unknown key \"view.fit\"",
            "config.toml:4: ignored unknown table [loading]",
            "config.toml:5: ignored unknown key \"loading.preview_max_px\"",
        ])
        XCTAssertEqual(messages, ["config.toml:3: ignored unknown key \"view.fit\" (+2 more)"])
        XCTAssertEqual(store.lastWarning, messages.first)
        // A clean file clears the warnings.
        try Data("[view]\nbackground = \"gray\"\n".utf8).write(to: url)
        store.load()
        XCTAssertEqual(store.warnings, [])
        XCTAssertNil(store.lastWarning)
        XCTAssertEqual(messages.count, 1)
    }

    func testErrorDescriptionFitsAToast() {
        let error = ConfigError(fileName: "config.toml", errors: [
            TOMLError(line: 9, column: 1, message: "second"), TOMLError(line: 2, column: 1, message: "first"),
        ])
        XCTAssertEqual(error.description, "config.toml:2: first (+1 more)")
    }

    // MARK: ConfigStore

    func testStoreLoadsKeepsPreviousConfigOnErrorAndReportsIt() throws {
        let url = directory.appendingPathComponent("config.toml")
        let store = ConfigStore(url: url)
        store.load()
        XCTAssertEqual(store.config, .default)
        XCTAssertNil(store.lastError)

        try Data("[hud]\nmode = \"off\"\n".utf8).write(to: url)
        var changes = 0
        var messages: [String] = []
        store.onChange = { _ in changes += 1 }
        store.onError = { messages.append($0) }
        store.load()
        XCTAssertEqual(store.config.hud, .off)
        XCTAssertEqual(changes, 1)

        try Data("[hud]\nmode = \"loud\"\n".utf8).write(to: url)
        store.load()
        XCTAssertEqual(store.config.hud, .off, "previous config stays active")
        XCTAssertEqual(messages, ["config.toml:2: hud.mode must be one of \"off\", \"minimal\", \"full\""])
        XCTAssertEqual(store.lastError, messages.first)
        XCTAssertEqual(changes, 1)
    }

    func testCreateDefaultFileWritesTheFullFile() throws {
        let url = directory.appendingPathComponent("nested/dir/config.toml")
        let store = ConfigStore(url: url)
        XCTAssertTrue(try store.createDefaultFileIfMissing())
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), ConfigFile.defaultText)
        try Data("# mine\n".utf8).write(to: url)
        XCTAssertFalse(try store.createDefaultFileIfMissing())
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# mine\n", "never overwrites")
        store.load()
        XCTAssertEqual(store.config, .default)
    }

    func testHotReloadSurvivesAtomicSavesAndInPlaceWrites() throws {
        let url = directory.appendingPathComponent("config.toml")
        try Data("[hud]\nmode = \"off\"\n".utf8).write(to: url)
        let store = ConfigStore(url: url)
        store.load()
        store.startWatching()
        defer { store.stopWatching() }

        func expectChange(_ check: @escaping (AppConfig) -> Bool, after write: () throws -> Void) throws {
            let changed = expectation(description: "reloaded")
            changed.assertForOverFulfill = false
            store.onChange = { config in if check(config) { changed.fulfill() } }
            try write()
            wait(for: [changed], timeout: 3)
        }

        // `load()` runs on the store's serial queue, so once it returns the watcher is armed.
        store.load()
        // Atomic save: a new inode renamed over the old file (vim, VS Code, …).
        try expectChange({ $0.hud == .full }) {
            try Data("[hud]\nmode = \"full\"\n".utf8).write(to: url, options: .atomic)
        }
        // In-place write to the (new) inode.
        try expectChange({ $0.hud == .minimal }) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data("[hud]\nmode = \"minimal\"\n".utf8))
            try handle.close()
        }
        // An unknown key is a warning: the rest of the file applies.
        let warned = expectation(description: "warning")
        store.onWarning = { message in
            if message == "config.toml:2: ignored unknown key \"hud.modee\"" { warned.fulfill() }
        }
        try expectChange({ $0.hud == .off }) {
            try Data("[hud]\nmodee = \"full\"\nmode = \"off\"\n".utf8).write(to: url, options: .atomic)
        }
        wait(for: [warned], timeout: 3)
        // An error is reported and the config stays.
        let failed = expectation(description: "error")
        store.onError = { message in if message.contains("hud.mode must be one of") { failed.fulfill() } }
        try Data("[hud]\nmode = \"loud\"\n".utf8).write(to: url, options: .atomic)
        wait(for: [failed], timeout: 3)
        XCTAssertEqual(store.config.hud, .off)
        // Deleting the file returns to the defaults.
        try expectChange({ $0 == .default }) { try FileManager.default.removeItem(at: url) }
    }

    func testDefaultURLHonoursTheEnvironment() throws {
        // PEEKABOO_CONFIG / XDG_CONFIG_HOME are read at call time; without them it is ~/.config/peekaboo.
        let env = ProcessInfo.processInfo.environment
        guard env["PEEKABOO_CONFIG"] == nil, env["XDG_CONFIG_HOME"] == nil else { throw XCTSkip("config env set") }
        XCTAssertTrue(ConfigStore.defaultURL.path.hasSuffix("/.config/peekaboo/config.toml"))
    }

    /// The full file (every setting, the whole keymap) and the starter file of earlier versions load in well under a
    /// millisecond (a loose bound: debug build, busy machine; `peekaboo-bench config` measures release builds).
    func testLoadIsFast() throws {
        for (name, text) in [("full file", ConfigFile.defaultText), ("released starter", LegacyConfigFiles.releasedStarter)] {
            let url = directory.appendingPathComponent("\(name).toml")
            try Data(text.utf8).write(to: url)
            let store = ConfigStore(url: url)
            store.load()
            var best = Double.infinity
            for _ in 0..<20 {
                let started = Trace.now()
                store.load()
                best = min(best, Trace.ms(since: started))
            }
            XCTAssertNil(store.lastError)
            XCTAssertLessThan(best, 5)
            print("ConfigStore.load (\(name), \(text.utf8.count) B): best \(String(format: "%.3f", best)) ms")
        }
    }
}
