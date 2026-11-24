import Foundation

/// Everything the user can configure. Every field has a built-in default; the
/// config file overrides only what it mentions.
public struct AppConfig: Sendable, Equatable {
    public enum FullscreenMode: String, Sendable, CaseIterable { case instant, native }
    public enum HUDMode: String, Sendable, CaseIterable { case off, minimal, full }

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

    public init() {}
    public static let `default` = AppConfig()
}

/// Loads `config.toml`, hot-reloads it and reports errors without dropping the last good config.
///
/// Walking-skeleton implementation (defaults only); the config workstream adds the
/// TOML parser, file watching and the full default keymap, keeping this API.
public final class ConfigStore {
    /// `$PEEKABOO_CONFIG`, else `$XDG_CONFIG_HOME/peekaboo/config.toml`, else `~/.config/peekaboo/config.toml`.
    public static var defaultURL: URL {
        let env = ProcessInfo.processInfo.environment
        if let path = env["PEEKABOO_CONFIG"], !path.isEmpty { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        let base = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("peekaboo/config.toml")
    }

    public let url: URL
    public private(set) var config = AppConfig.default
    /// Main thread, after every successful (re)load.
    public var onChange: ((AppConfig) -> Void)?
    /// Main thread, with a message such as `config.toml:17: unknown action "nav.nxt"`; the previous config stays active.
    public var onError: ((String) -> Void)?

    public init(url: URL = ConfigStore.defaultURL) {
        self.url = url
    }

    /// Parse the file now (missing file = defaults).
    public func load() {
        config = .default
        onChange?(config)
    }

    /// Reload whenever the file is saved.
    public func startWatching() {}

    /// Make sure a commented starter file exists (for `app.config`) and return its URL.
    @discardableResult
    public func createDefaultFileIfMissing() throws -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("# Peekaboo configuration — every key is optional.\n".utf8).write(to: url)
        }
        return url
    }
}
