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
    /// `rating.auto_advance`: plain rating/label/flag keys also advance (already applied to `keymap`).
    public var autoAdvance = false
    /// `keymap.vim` (already applied to `keymap`).
    public var vimKeys = false
    /// `keymap.defaults` (already applied to `keymap`).
    public var keymapDefaults = true

    public init() {}
    public static let `default` = AppConfig()
}

/// Loads `config.toml`, hot-reloads it and reports errors without dropping the last good config.
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

    /// The store that loaded most recently: `app.reload_config` and `app.config` act on it.
    public private(set) static weak var current: ConfigStore?

    public let url: URL
    public private(set) var config = AppConfig.default
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

    public init(url: URL = ConfigStore.defaultURL) {
        self.url = url
    }

    deinit { sources.forEach { $0.cancel() } }

    /// Parse the file now, on the calling thread (missing file = defaults). A 5 KB file takes well under 1 ms.
    public func load() {
        ConfigStore.current = self
        apply(queue.sync { read(force: true) })
    }

    /// Re-read the file in the background and apply it on the main thread (`app.reload_config`).
    public func reload() {
        ConfigStore.current = self
        queue.async { [weak self] in
            guard let self else { return }
            let outcome = self.read(force: true)
            DispatchQueue.main.async { self.apply(outcome) }
        }
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

    /// Make sure a commented starter file exists (for `app.config`) and return its URL.
    @discardableResult
    public func createDefaultFileIfMissing() throws -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(ConfigStore.sampleConfig.utf8).write(to: url, options: .atomic)
            if watching { queue.async { [weak self] in self?.arm() } }
        }
        return url
    }

    // MARK: Loading

    private enum Outcome {
        case unchanged
        case loaded(AppConfig, warnings: [String])
        case failed(String)
    }

    /// On `queue`.
    private func read(force: Bool) -> Outcome {
        let data = try? Data(contentsOf: url)
        if !force, let lastData, lastData == data { return .unchanged }
        lastData = .some(data)
        guard let data else { return .loaded(.default, warnings: []) }
        let started = Trace.now()
        do {
            let (config, warnings) = try AppConfig.parse(toml: String(decoding: data, as: UTF8.self), fileName: url.lastPathComponent)
            Trace.log("config loaded \(url.lastPathComponent) (\(data.count) B) in \(String(format: "%.2f", Trace.ms(since: started))) ms")
            if !warnings.isEmpty { Trace.log("config warnings: \(warnings.joined(separator: "; "))") }
            return .loaded(config, warnings: warnings)
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
        case .loaded(let config, let warnings):
            lastError = nil
            self.warnings = warnings
            self.config = config
            onChange?(config)
            if let warning = lastWarning { (onWarning ?? onError)?(warning) }
        case .failed(let message):
            lastError = message
            onError?(message)
        }
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
