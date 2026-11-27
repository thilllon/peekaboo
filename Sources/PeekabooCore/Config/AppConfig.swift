import CryptoKit
import Foundation

/// Everything the user can configure. Every field has a built-in default; the
/// config file overrides only what it mentions (`AppConfig(toml:)`, reference: docs/CONFIG.md).
public struct AppConfig: Sendable, Equatable {
    public enum FullscreenMode: String, Sendable, CaseIterable { case instant, native }
    public enum HUDMode: String, Sendable, CaseIterable { case off, minimal, full }
    /// Where `meta.rate` / `meta.label` / `meta.flag` are stored.
    public enum RatingStorage: String, Sendable, CaseIterable {
        case finderTags = "finder-tags"
        case none
    }

    public var keymap: Keymap = .default
    /// Named move/copy destinations for `file.move:<slot>` / `file.copy:<slot>` (paths, `~` allowed).
    public var slots: [String: String] = [:]
    /// Named apps for `file.open_with:<slot>` (bundle id, app name or path).
    public var apps: [String: String] = [:]
    /// `black`, `gray` or `checker`.
    public var background: String = "black"
    public var hud: HUDMode = .minimal
    public var fullscreen: FullscreenMode = .instant
    /// Fit the image below the camera housing on notched displays in full screen.
    public var avoidNotch = true
    /// Keep zoom and pan when moving to another image.
    public var keepZoom = false
    /// Delay after the last gesture before the high-quality re-rasterisation, in ms.
    public var refineDelayMs = 90
    /// Override for the decoded-pixel cache budget in MB (nil = automatic from RAM).
    public var cacheBudgetMB: Int?
    /// Factor of one `zoom.in` / `zoom.out` step (`view.zoom_step`).
    public var zoomStep = 1.25
    /// `rating.storage`.
    public var ratingStorage: RatingStorage = .finderTags
    /// `rating.star`: a rating of 3 is the Finder tag of three of these.
    public var starCharacter = "★"
    /// `keymap.defaults`, `keymap.vim` and `rating.auto_advance` as the file sets them (`keymap` is built from them).
    public var keymapDefaults = true
    public var vimKeys = false
    public var autoAdvance = false
    /// `decode.hdr`: decode gain-map photos and PQ / HLG images to HDR (10–15× the SDR cost). `PEEKABOO_HDR=1` turns it
    /// on whatever this says.
    public var decodeHDR = false
    /// `decode.fast_path`: decode through ImageIO's private IOSurface entry point. `PEEKABOO_NO_IOSURFACE_SPI=1` turns
    /// it off whatever this says.
    public var fastPath = true
    /// `debug.trace`: timestamped trace lines on stderr. `PEEKABOO_TRACE=1` turns it on whatever this says.
    public var trace = false
    /// `[updates]`.
    public var updates = Updates()

    /// `[updates]`: new releases.
    public struct Updates: Sendable, Equatable {
        /// `check`: look for a new release when online (10 s after launch at the earliest, then every 6 h and when
        /// the network comes back, at most hourly). "Check for Updates…" works either way.
        public var check = true
        /// `auto_install`: download a new release in the background and install it when Peekaboo quits.
        public var autoInstall = true

        public init(check: Bool = true, autoInstall: Bool = true) {
            self.check = check
            self.autoInstall = autoInstall
        }
    }

    public init() {}
    public static let `default` = AppConfig()
}

/// Loads `config.toml`, hot-reloads it and reports errors without dropping the last good config.
/// Unknown tables and keys are not errors: they are skipped, reported as warnings, and the rest applies.
///
/// Reloads parse on a background queue and apply on the main thread. The file *and* its directory
/// are watched, so both in-place writes and atomic saves (write a temporary file, rename it over)
/// are picked up; events are debounced by 50 ms.
public final class ConfigStore {
    /// `$PEEKABOO_CONFIG`, else `$XDG_CONFIG_HOME/peekaboo/config.toml`, else `~/.config/peekaboo/config.toml`.
    public static var defaultURL: URL {
        let env = ProcessInfo.processInfo.environment
        if let path = env["PEEKABOO_CONFIG"], !path.isEmpty { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        let base = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("peekaboo/config.toml")
    }

    /// The store that loaded most recently: `app.reload_config` and `app.config_file` act on it.
    public private(set) static weak var current: ConfigStore?

    /// Posted (main thread, the store as object) after every load that changed something — applied, or failed with
    /// `lastError` — whether it came from the file watcher, `load()` or `edit(_:completion:)`. For any number of
    /// observers (the Settings window) next to the owner's `onChange` / `onError`.
    public static let didLoadNotification = Notification.Name("PeekabooConfigDidLoad")

    public let url: URL
    public private(set) var config = AppConfig.default
    /// Text of the file `config` was loaded from (nil: no file, the built-in defaults).
    public private(set) var text: String?
    /// Main thread, after every successful (re)load.
    public var onChange: ((AppConfig) -> Void)?
    /// Main thread, with a message such as `config.toml:17: unknown action "nav.nxt"`; the previous config stays active.
    /// Also gets the warnings when `onWarning` is nil (every message is meant for a toast).
    public var onError: ((String) -> Void)?
    /// Main thread, after a load that applied but skipped unknown tables or keys, with a message such as
    /// `config.toml:3: ignored unknown key "view.fit" (+1 more)`. When nil, `onError` gets it.
    public var onWarning: ((String) -> Void)?
    /// The last load's error message (nil after a successful load), for errors raised before `onError` was set.
    public private(set) var lastError: String?
    /// Every unknown table and key the last successful load skipped, one line-numbered message each.
    public private(set) var warnings: [String] = []
    /// `warnings` as one toast-sized message; nil when there are none.
    public var lastWarning: String? { ConfigError.summary(warnings) }
    /// Debounce for file-system events.
    public var debounce: DispatchTimeInterval = .milliseconds(50)

    private let queue = DispatchQueue(label: "peekaboo.config", qos: .utility)
    /// Bytes of the last file read (nil = missing); guarded by `queue`.
    private var lastData: Data??
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?
    private var watching = false
    /// The settings and default bindings the file is read and written with (nil: this version's; tests play later
    /// versions with others).
    let schema: ConfigSchema?

    public convenience init(url: URL = ConfigStore.defaultURL) {
        self.init(url: url, schema: nil)
    }

    init(url: URL, schema: ConfigSchema?) {
        self.url = url
        self.schema = schema
    }

    deinit { sources.forEach { $0.cancel() } }

    /// Parse the file now, on the calling thread (missing file = defaults). A 5 KB file takes well under 1 ms.
    public func load() {
        ConfigStore.current = self
        apply(queue.sync { read(force: true) })
    }

    /// Reload whenever the file is saved.
    public func startWatching() {
        watching = true
        queue.async { [weak self] in self?.arm() }
    }

    public func stopWatching() {
        watching = false
        queue.async { [weak self] in
            self?.sources.forEach { $0.cancel() }
            self?.sources = []
        }
    }

    /// For `app.config_file`, on the store's queue (no file I/O on the main thread): create the full file when there is
    /// none, else bring the file Peekaboo wrote up to date (`upgradeFile`); then `completion` on the main thread with
    /// the file's URL, once the new contents are applied.
    public func prepareFile(completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let result: Result<Outcome?, Error> = Result {
                if try self.createDefaultFileIfMissing() { return self.read(force: true) }
                return self.upgradeNow().outcome
            }
            DispatchQueue.main.async {
                if case .success(let outcome?) = result { self.apply(outcome) }
                completion(result.map { _ in self.url })
            }
        }
    }

    /// The full file of the built-in configuration.
    private var fullText: String { schema.map { ConfigFile.text($0) } ?? ConfigFile.defaultText }

    /// Write the full file if there is no file (true when it did). On `queue`.
    func createDefaultFileIfMissing() throws -> Bool {
        guard !FileManager.default.fileExists(atPath: url.path) else { return false }
        try write(Data(fullText.utf8))
        Trace.log("config created \(url.lastPathComponent): every setting and the whole keymap")
        return true
    }

    // MARK: Upgrading

    /// What `upgradeFile` did.
    public enum Upgrade: Equatable, Sendable {
        /// Nothing: no file, a file of the user's, or a full file of this generation (or a newer one).
        case nothing
        /// An untouched starter file of an earlier version (only comments) became the full file.
        case rewroteStarter
        /// A full file of an older generation got the settings and default bindings of the later ones.
        case appended(from: Int, to: Int)
        /// It was left as it is: it changed while being upgraded, or the write failed.
        case failed(String)
    }

    /// Bring the file Peekaboo wrote up to date, on the store's queue (a second after launch, never on the launch path):
    /// an untouched starter file of an earlier version becomes the full file, and a full file of an older generation
    /// gets the settings that later versions added, with their defaults, and their default bindings on the keys it
    /// leaves free; its generation is raised, so that a binding the user deleted never comes back. Any other file —
    /// with an active line or a comment of the user's, an error, bytes that are not UTF-8 — is left as it is. The
    /// configuration in effect does not change (the new text must load as the same one); the write is atomic.
    /// `completion` runs on the main thread, after the new text is applied.
    public func upgradeFile(completion: ((Upgrade) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            let (upgrade, outcome) = self.upgradeNow()
            DispatchQueue.main.async {
                if let outcome { self.apply(outcome) }
                completion?(upgrade)
            }
        }
    }

    /// On `queue`.
    private func upgradeNow() -> (upgrade: Upgrade, outcome: Outcome?) {
        guard let data = try? Data(contentsOf: url) else { return (.nothing, nil) }
        let text = String(decoding: data, as: UTF8.self)
        guard text.utf8.elementsEqual(data), let (upgraded, upgrade) = Self.upgraded(text, schema: schema) else { return (.nothing, nil) }
        // An editor may have saved the file meanwhile: write only over the bytes the new text was made from.
        guard (try? Data(contentsOf: url)) == data else { return (.failed("\(url.lastPathComponent) changed meanwhile"), nil) }
        let started = Trace.now()
        do {
            try write(Data(upgraded.utf8))
        } catch {
            Trace.log("config upgrade failed: \(error.localizedDescription)")
            return (.failed(error.localizedDescription), nil)
        }
        Trace.log("config upgraded \(url.lastPathComponent) (\(upgrade)) in \(String(format: "%.2f", Trace.ms(since: started))) ms")
        return (upgrade, read(force: true))
    }

    /// `text` brought up to date (nil: nothing to do), as `upgradeFile` describes: the result loads as the same
    /// configuration (the starter's keymap becomes the file's own: `keymap.defaults` is false), with no new warning.
    static func upgraded(_ text: String, schema: ConfigSchema? = nil) -> (text: String, upgrade: Upgrade)? {
        let schema = schema ?? .current
        // A file with an error is the user's to fix: it is never touched.
        guard let reading = try? AppConfig.read(toml: text, schema: schema) else { return nil }
        let result: (text: String, upgrade: Upgrade)
        if isStarter(text, reading.document) {
            result = (ConfigFile.text(schema), .rewroteStarter)
        } else {
            guard let generation = reading.generation, generation < schema.generation else { return nil }
            var editor = ConfigEditor(text: text)
            do {
                for setting in schema.settings where setting.generation > generation && reading.document.value(setting.path) == nil {
                    try editor.set(setting.key, in: setting.table, to: setting.value(.default), comment: setting.comment)
                }
                for binding in reading.added { try editor.add(binding) }
                try editor.set("generation", in: "keymap", to: .integer(schema.generation))
            } catch {
                Trace.log("config upgrade skipped: \(error)")
                return nil
            }
            result = (editor.text, .appended(from: generation, to: schema.generation))
        }
        guard let after = try? AppConfig.read(toml: result.text, schema: schema), after.unknown.count <= reading.unknown.count
        else { return nil }
        var before = reading.config
        before.keymapDefaults = after.config.keymapDefaults
        return before == after.config ? result : nil
    }

    /// An untouched starter file of an earlier version: one of the texts they wrote (every setting commented out, so it
    /// changes nothing), byte for byte but for a byte order mark, CRLF line ends and the white space at its end. A file
    /// of comments that differs in anything else (the user's notes, a commented-out line of theirs, a value changed in
    /// a comment, a line deleted) is the user's.
    static func isStarter(_ text: String, _ document: TOMLDocument) -> Bool {
        document.entries.isEmpty && document.tables.isEmpty && starterDigests.contains(starterDigest(text))
    }

    /// The SHA-256 of each starter file a version of Peekaboo wrote, as `starterDigest` reads it: `SampleConfig.swift` at
    /// f60b311 (every release up to 20261126-517cb0), d4f0032, e04e29e and a5ba1b6 (development builds), and the one
    /// line of 9fbefc8. `ConfigFileTests` checks each against its text.
    private static let starterDigests: Set<String> = [
        "51310ba88711c0a4df68275dd13cc5b6574fc6e154b6028c5baa285696d1e031",
        "a697a098a1c8b1f2d95420f300391b5d5a84c01885ddd8bb47e925b3ea3dbaed",
        "21c3cf49826e935722e7df2b0d4d1a08efb24d1052d318ddaf04962d1add5240",
        "4f10be92de9b71fa353d44e3fdde66dfa7035d289b98a1c8032b559e6d684bc2",
        "2c37c51efa0e564193f8d269cc3307693a6295a3f0bf52a66b6c3dbb79489509",
    ]

    /// The SHA-256 (hex) of `text` without a byte order mark, with LF line ends and without the white space at its end.
    private static func starterDigest(_ text: String) -> String {
        var text = text
        while text.unicodeScalars.first == "\u{FEFF}" { text.unicodeScalars.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        while text.last?.isWhitespace == true { text.removeLast() }
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The value of `key` in `table` as the applied file writes it; nil when the file does not set it (the Settings
    /// window shows it, and tells a default from an explicit value with it).
    public func storedValue(_ key: String, in table: String) -> TOMLValue? {
        guard let text else { return nil }
        if storedDocument?.text != text { storedDocument = (text, try? TOMLDocument(parsing: text)) }
        return storedDocument?.document?.value(table.split(separator: ".").map(String.init) + [key])
    }

    /// `text` parsed again, on the first `storedValue` after a load (never on the launch path).
    private var storedDocument: (text: String, document: TOMLDocument?)?

    // MARK: Editing

    /// Change the file through `ConfigEditor` (minimal edits of its text; a missing file starts as the full file, and a
    /// file `upgradeFile` would bring up to date is brought up to date first), then write it and apply it. The result
    /// must load: an edit that would leave the file with an error — or one made while the file has one, or is not
    /// UTF-8 — is not written, and `completion` gets the error, e.g. `config.toml:17: unknown action "nav.nxt"`. A change
    /// that changes nothing writes nothing; when it changes nothing in the full file standing in for the file, `change`
    /// runs once more, on the file as it is, to tell (`changes`). The write is atomic and goes to the file a symbolic link
    /// points to, keeping the link and the file's permissions. Runs on the store's queue (no file I/O on the main
    /// thread); `completion` runs on the main thread after the new configuration is applied.
    public func edit(_ change: @escaping (inout ConfigEditor) throws -> Void, completion: ((Error?) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            let started = Trace.now()
            let result: Result<Outcome, Error> = Result {
                let name = self.url.lastPathComponent
                // The file as it is ("" for none), and the text the change is made on: the file, or the full file standing
                // in for none or for one `upgradeFile` would bring up to date.
                var current = ""
                let original: String
                if let existing = try? Data(contentsOf: self.url) {
                    let text = String(decoding: existing, as: UTF8.self)
                    // Decoding replaces invalid UTF-8 (a Latin-1 comment) all over the text: writing it back would
                    // change lines the edit never touched.
                    guard text.utf8.elementsEqual(existing) else {
                        throw ConfigEditError(line: nil, message: "\(name): not UTF-8 text (save it as UTF-8 to change it here)")
                    }
                    current = text
                    original = Self.upgraded(text, schema: self.schema)?.text ?? text
                } else {
                    original = self.fullText
                }
                var editor = ConfigEditor(text: original)
                do {
                    try change(&editor)
                } catch let error as ConfigEditError {
                    // `config.toml:17: …` like the load errors.
                    guard let line = error.line else { throw ConfigEditError(line: nil, message: "\(name): \(error.message)") }
                    throw ConfigError(fileName: name, errors: [TOMLError(line: line, column: 1, message: error.message)])
                }
                // A change that changes nothing writes nothing (and creates no file). The full file standing in for the file
                // says `defaults = false` where no file and a starter file mean true: turning the built-in keymap off
                // changes nothing in its text, but changes the file as it is.
                guard editor.text != original || (original != current && self.changes(change, current)) else { return .unchanged }
                _ = try AppConfig.read(toml: editor.text, fileName: name, schema: self.schema)
                try self.write(Data(editor.text.utf8))
                Trace.log("config edited in \(String(format: "%.2f", Trace.ms(since: started))) ms")
                return self.read(force: true)
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let outcome):
                    self.apply(outcome)
                    completion?(nil)
                case .failure(let error):
                    completion?(error)
                }
            }
        }
    }

    /// `change` makes `text` load as another configuration (both loading; on `queue`).
    private func changes(_ change: (inout ConfigEditor) throws -> Void, _ text: String) -> Bool {
        var editor = ConfigEditor(text: text)
        guard (try? change(&editor)) != nil, editor.text != text,
              let before = try? AppConfig.read(toml: text, schema: schema).config,
              let after = try? AppConfig.read(toml: editor.text, schema: schema).config else { return false }
        return after != before
    }

    /// Replace the file's contents atomically (on `queue`).
    private func write(_ data: Data) throws {
        let fm = FileManager.default
        let target = url.resolvingSymlinksInPath()
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let permissions = (try? fm.attributesOfItem(atPath: target.path))?[.posixPermissions]
        try data.write(to: target, options: .atomic)
        if let permissions { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path) }
        if watching { arm() }  // a new inode, or a file that did not exist
    }

    // MARK: Loading

    private enum Outcome {
        case unchanged
        case loaded(AppConfig, warnings: [String], text: String?)
        case failed(String)
    }

    /// On `queue`.
    private func read(force: Bool) -> Outcome {
        let data = try? Data(contentsOf: url)
        if !force, let lastData, lastData == data { return .unchanged }
        lastData = .some(data)
        guard let data else { return .loaded(.default, warnings: [], text: nil) }
        let started = Trace.now()
        let text = String(decoding: data, as: UTF8.self)
        do {
            let reading = try AppConfig.read(toml: text, fileName: url.lastPathComponent, schema: schema)
            let (config, warnings) = (reading.config, reading.warnings(fileName: url.lastPathComponent))
            Trace.log("config loaded \(url.lastPathComponent) (\(data.count) B) in \(String(format: "%.2f", Trace.ms(since: started))) ms")
            if !warnings.isEmpty { Trace.log("config warnings: \(warnings.joined(separator: "; "))") }
            return .loaded(config, warnings: warnings, text: text)
        } catch let error as ConfigError {
            Trace.log("config error: \(error.messages.joined(separator: "; "))")
            return .failed(error.description)
        } catch {
            return .failed("\(url.lastPathComponent): \(error)")
        }
    }

    private func apply(_ outcome: Outcome) {
        switch outcome {
        case .unchanged: return
        case .loaded(let config, let warnings, let text):
            lastError = nil
            self.warnings = warnings
            self.config = config
            self.text = text
            onChange?(config)
            if let warning = lastWarning { (onWarning ?? onError)?(warning) }
        case .failed(let message):
            lastError = message
            onError?(message)
        }
        NotificationCenter.default.post(name: Self.didLoadNotification, object: self)
    }

    // MARK: Watching (all on `queue`)

    private func arm() {
        sources.forEach { $0.cancel() }
        sources = []
        guard watching else { return }
        // The file (in-place writes) and the nearest existing directory above it (atomic saves, creation).
        var paths = [url.path]
        var directory = url.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.path), directory.pathComponents.count > 1 {
            directory = directory.deletingLastPathComponent()
        }
        paths.append(directory.path)
        for path in paths {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete, .attrib], queue: queue)
            source.setEventHandler { [weak self] in self?.fileEvent() }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
        }
    }

    private func fileEvent() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.arm() // the inode may have changed (atomic save)
            let outcome = self.read(force: false)
            if case .unchanged = outcome { return }
            DispatchQueue.main.async { self.apply(outcome) }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
