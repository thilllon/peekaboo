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
        XCTAssertEqual(try AppConfig(toml: ConfigStore.sampleConfig), AppConfig.default)
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
        XCTAssertTrue(config.autoAdvance)
        XCTAssertTrue(config.vimKeys)
        XCTAssertEqual(config.slots, ["1": "~/Pictures/Keep", "keep": "./_keep"])
        XCTAssertEqual(config.apps, ["editor": "com.pixelmatorteam.pixelmator.x"])
        XCTAssertEqual(config.keymap.resolve(KeyChord.sequence(spec: "g g")!, context: .normal), .actions([.first]))
        XCTAssertEqual(try AppConfig(toml: "[cache]\nmemory_mb = \"auto\"\n").cacheBudgetMB, nil)
    }

    func testSampleTemplateIsAValidConfig() throws {
        let config = try AppConfig(toml: ConfigStore.sampleTemplate)
        XCTAssertEqual(config.slots.count, 4)
        XCTAssertEqual(config.apps["preview"], "com.apple.Preview")
        XCTAssertEqual(config.keymap.resolve([KeyChord(key: "k")], context: .normal), .actions([.move("keep")]))
        XCTAssertEqual(config.keymap.resolve([KeyChord(key: "tab")], context: .normal), .unbound)
        XCTAssertEqual(config.keymap.resolve(KeyChord.sequence(spec: "ctrl+x p")!, context: .normal),
                       .actions([.exec("open -a 'Pixelmator Pro' {path}")]))
        // Apart from the examples, the sample spells out the defaults.
        var expected = AppConfig.default
        expected.slots = config.slots
        expected.apps = config.apps
        expected.keymap = config.keymap
        XCTAssertEqual(config, expected)
        // Every line of the starter file is a comment or blank.
        XCTAssertTrue(ConfigStore.sampleConfig.split(separator: "\n").allSatisfy { $0.hasPrefix("#") })
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
        XCTAssertEqual(errors("[keys]\n\"1\" = \"meta.rate:9\"\n"), ["config.toml:2: unknown action \"meta.rate:9\" (check its argument)"])
        XCTAssertEqual(errors("[keys]\n\"1\" = [\"none\", \"nav.next\"]\n"), ["config.toml:2: \"none\" cannot be part of an action list"])
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

    func testCreateDefaultFileWritesTheCommentedSample() throws {
        let url = directory.appendingPathComponent("nested/dir/config.toml")
        let store = ConfigStore(url: url)
        XCTAssertEqual(try store.createDefaultFileIfMissing(), url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), ConfigStore.sampleConfig)
        try Data("# mine\n".utf8).write(to: url)
        try store.createDefaultFileIfMissing()
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

        // Give the watcher a moment to arm on its queue.
        Thread.sleep(forTimeInterval: 0.05)
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
        // An error is reported and the config stays.
        let failed = expectation(description: "error")
        store.onError = { message in if message.contains("unknown key") { failed.fulfill() } }
        try Data("[hud]\nmodee = \"off\"\n".utf8).write(to: url, options: .atomic)
        wait(for: [failed], timeout: 3)
        XCTAssertEqual(store.config.hud, .minimal)
        // Deleting the file returns to the defaults.
        try expectChange({ $0 == .default }) { try FileManager.default.removeItem(at: url) }
    }

    func testDefaultURLHonoursTheEnvironment() throws {
        // PEEKABOO_CONFIG / XDG_CONFIG_HOME are read at call time; without them it is ~/.config/peekaboo.
        let env = ProcessInfo.processInfo.environment
        guard env["PEEKABOO_CONFIG"] == nil, env["XDG_CONFIG_HOME"] == nil else { throw XCTSkip("config env set") }
        XCTAssertTrue(ConfigStore.defaultURL.path.hasSuffix("/.config/peekaboo/config.toml"))
    }

    func testLoadIsFast() throws {
        let url = directory.appendingPathComponent("config.toml")
        try Data(ConfigStore.sampleTemplate.utf8).write(to: url)
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
        print("ConfigStore.load (sample, \(ConfigStore.sampleTemplate.utf8.count) B): best \(String(format: "%.3f", best)) ms")
    }
}
