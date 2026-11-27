import XCTest
@testable import PeekabooCore

/// `ConfigStore.edit`: the Settings window's write path (never the user's real config: every store here has its own
/// temporary file).
final class ConfigStoreEditTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("peekaboo-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Run `change` through `store.edit` and wait for its completion.
    @discardableResult
    private func edit(_ store: ConfigStore, _ change: @escaping (inout ConfigEditor) throws -> Void) -> Error? {
        let done = expectation(description: "edited")
        var failure: Error?
        store.edit(change) { error in
            failure = error
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return failure
    }

    func testEditCreatesTheFullFileAppliesItAndNotifies() throws {
        let url = directory.appendingPathComponent("nested/config.toml")
        let store = ConfigStore(url: url)
        store.load()
        // A change that changes nothing creates no file.
        XCTAssertNil(edit(store) { try $0.bind([KeyChord(key: "right")], to: [.next], context: .normal) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        var changes: [AppConfig] = []
        store.onChange = { changes.append($0) }
        var notified = 0
        let observer = NotificationCenter.default.addObserver(forName: ConfigStore.didLoadNotification, object: store,
                                                              queue: nil) { _ in notified += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        XCTAssertNil(edit(store) { try $0.set("hdr", in: "decode", to: .bool(true)) })
        let written = try String(contentsOf: url, encoding: .utf8)
        // The full file, with the one value changed in place (its comment keeps its column).
        let line = { (value: String) in ConfigFile.commented("hdr = \(value)", "gain-map and PQ / HLG photos in HDR (10-15x the SDR decode time; PEEKABOO_HDR=1 forces it)") }
        XCTAssertEqual(written, ConfigFile.defaultText.replacingOccurrences(of: line("false"), with: line("true")))
        XCTAssertNotEqual(written, ConfigFile.defaultText)
        XCTAssertTrue(store.config.decodeHDR)
        XCTAssertEqual(changes.last?.decodeHDR, true)
        XCTAssertEqual(notified, 1)
        XCTAssertEqual(store.text, written)
        XCTAssertEqual(store.storedValue("hdr", in: "decode"), .bool(true))
        XCTAssertEqual(store.storedValue("trace", in: "debug"), .bool(false), "the full file sets every key")
        XCTAssertNil(store.storedValue("keep", in: "slots"), "a key the file does not set")

        // An edit that changes nothing writes nothing and notifies nobody.
        XCTAssertNil(edit(store) { try $0.set("hdr", in: "decode", to: .bool(true)) })
        XCTAssertEqual(notified, 1)
    }

    /// The full file an edit starts from without a file (or for a starter file) says `defaults = false`, while the file
    /// in effect has the built-in keymap: turning it off (the Keyboard pane's first checkbox) is a change, and writes the
    /// full file. Reset All, which changes nothing there, still writes nothing.
    func testTurningTheBuiltInKeymapOffWritesTheFullFile() throws {
        let url = directory.appendingPathComponent("config.toml")
        let store = ConfigStore(url: url)
        store.load()
        XCTAssertTrue(store.config.keymapDefaults)
        XCTAssertNil(edit(store) { try $0.resetBindings() })
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "nothing to reset")
        XCTAssertNil(edit(store) { try $0.set("defaults", in: "keymap", to: .bool(false)) })
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), ConfigFile.defaultText)
        XCTAssertFalse(store.config.keymapDefaults)
        XCTAssertEqual(store.config.keymap, Keymap.default)

        let starter = LegacyConfigFiles.releasedStarter
        try Data(starter.utf8).write(to: url)
        store.load()
        XCTAssertTrue(store.config.keymapDefaults)
        XCTAssertNil(edit(store) { try $0.resetBindings() })
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), starter, "nothing to reset")
        XCTAssertNil(edit(store) { try $0.set("defaults", in: "keymap", to: .bool(false)) })
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), ConfigFile.defaultText)
        XCTAssertFalse(store.config.keymapDefaults)
        XCTAssertEqual(store.config.keymap, Keymap.default)
    }

    func testAnEditThatWouldBreakTheFileIsNotWritten() throws {
        let url = directory.appendingPathComponent("config.toml")
        let text = "[view]\nbackground = \"gray\"\n"
        try Data(text.utf8).write(to: url)
        let store = ConfigStore(url: url)
        store.load()
        let error = edit(store) { try $0.bind([KeyChord(key: "y")], to: [.move("nowhere")], context: .normal) }
        XCTAssertEqual(error.map { "\($0)" }, "config.toml:5: unknown slot \"nowhere\" (add it under [slots])")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
        // A file with an error already: edits wait until it is fixed.
        try Data("[view]\nbackground = \"pink\"\n".utf8).write(to: url)
        store.load()
        XCTAssertNotNil(store.lastError)
        XCTAssertNotNil(edit(store) { try $0.set("keep_zoom", in: "view", to: .bool(true)) })
        // Not TOML at all: the line is named.
        try Data("[view\n".utf8).write(to: url)
        let syntax = edit(store) { try $0.set("keep_zoom", in: "view", to: .bool(true)) }
        XCTAssertTrue("\(syntax.map { "\($0)" } ?? "")".hasPrefix("config.toml:1: "), "\(String(describing: syntax))")
    }

    /// A file with bytes that are not UTF-8 (a Latin-1 comment) loads, but an edit would rewrite those bytes on lines
    /// it never touched: it is refused and the file stays as it is.
    func testAFileThatIsNotUTF8IsNotRewritten() throws {
        let url = directory.appendingPathComponent("config.toml")
        let bytes = Data(Array("# caf".utf8) + [0xE9] + Array("\n[view]\nbackground = \"gray\"\n".utf8))
        try bytes.write(to: url)
        let store = ConfigStore(url: url)
        store.load()
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.config.background, "gray")
        let error = edit(store) { try $0.set("keep_zoom", in: "view", to: .bool(true)) }
        XCTAssertEqual(error.map { "\($0)" }, "config.toml: not UTF-8 text (save it as UTF-8 to change it here)")
        XCTAssertEqual(try Data(contentsOf: url), bytes, "the file is untouched")
        XCTAssertFalse(store.config.keepZoom)
    }

    func testEditWritesThroughASymbolicLinkAndKeepsPermissions() throws {
        let real = directory.appendingPathComponent("dotfiles/peekaboo.toml")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[view]\nbackground = \"gray\"\n".utf8).write(to: real)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path)
        let link = directory.appendingPathComponent("config.toml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let store = ConfigStore(url: link)
        store.load()
        XCTAssertNil(edit(store) { try $0.set("background", in: "view", to: .string("checker")) })
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), real.path, "still a link")
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "[view]\nbackground = \"checker\"\n")
        let permissions = try FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        XCTAssertEqual(store.config.background, "checker")
    }

    /// A Settings change is on disk and applied within a few milliseconds (read, edit, verify, write, reload).
    func testAnEditIsAppliedQuickly() throws {
        let url = directory.appendingPathComponent("config.toml")
        try Data(ConfigFile.defaultText.utf8).write(to: url)
        let store = ConfigStore(url: url)
        store.load()
        var times: [Double] = []
        for i in 0..<12 {
            let started = Trace.now()
            XCTAssertNil(edit(store) { try $0.set("refine_delay_ms", in: "view", to: .integer(100 + i)) })
            times.append(Trace.ms(since: started))
        }
        XCTAssertEqual(store.config.refineDelayMs, 111)
        let median = times.sorted()[times.count / 2]
        print(String(format: "ConfigStore.edit (full file, %d B): median %.2f ms, best %.2f ms",
                     ConfigFile.defaultText.utf8.count, median, times.min() ?? 0))
        XCTAssertLessThan(median, 250, "a regression guard: ~1.3 ms on an M4 Pro, ~18 ms on a CI runner")
    }

    func testTheWatcherSeesAnEditOnlyOnce() throws {
        let url = directory.appendingPathComponent("config.toml")
        try Data("[view]\nbackground = \"gray\"\n".utf8).write(to: url)
        let store = ConfigStore(url: url)
        store.load()
        store.startWatching()
        defer { store.stopWatching() }
        store.load()  // the watcher is armed once `load()` returns (same serial queue)
        var changes = 0
        store.onChange = { _ in changes += 1 }
        XCTAssertNil(edit(store) { try $0.set("background", in: "view", to: .string("checker")) })
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(changes, 1, "the watcher found the file as the edit left it")
        // An external change still reloads.
        let reloaded = expectation(description: "external")
        store.onChange = { if $0.background == "black" { reloaded.fulfill() } }
        try Data("[view]\nbackground = \"black\"\n".utf8).write(to: url, options: .atomic)
        wait(for: [reloaded], timeout: 3)
    }
}
