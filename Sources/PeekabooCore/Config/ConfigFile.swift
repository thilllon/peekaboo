import Foundation

/// The config.toml Peekaboo writes: every setting active at its built-in default, with its comment, then the whole
/// default keymap (`[keymap] defaults = false`: the file is the keymap). It is generated from `AppConfig.default` and
/// `Keymap.defaultGroups`, so the file and the code never disagree (`ConfigFileTests` parses it back). Lines that are not
/// defaults (slots, apps, more bindings, `"none"`) are commented-out examples; settings that are planned but not read
/// yet are only named in prose.
///
/// Later versions: every setting and default binding carries the file generation that added it. A full file records its
/// own in `[keymap] generation`, and gets the newer ones appended once (`ConfigStore.upgradeFile`, docs/CONFIG.md ›
/// Later versions).
public enum ConfigFile {
    /// One setting of the file: where it lives, its comment, the generation that added it, and its value in a config
    /// as the file spells it (the inverse of `ConfigReader`; `ConfigFileTests` round-trips every one).
    struct Setting: Sendable {
        let table: String
        let key: String
        let comment: String
        let generation: Int
        let value: @Sendable (AppConfig) -> TOMLValue

        init(_ table: String, _ key: String, _ comment: String, generation: Int = 1,
             _ value: @escaping @Sendable (AppConfig) -> TOMLValue) {
            self.table = table
            self.key = key
            self.comment = comment
            self.generation = generation
            self.value = value
        }

        var path: [String] { [table, key] }
    }

    /// Every setting, in file order (`keymap.defaults` and `keymap.generation` describe the file itself and are written
    /// with the keymap). A setting added later gets the next generation, so that full files written before get it
    /// appended; `ConfigFileTests.testGenerationOneIsFrozen` fails for one that does not.
    static let settings: [Setting] = [
        Setting("view", "background", "black | gray | checker   (cycle with b)") { .string($0.background) },
        Setting("view", "keep_zoom", "keep zoom and pan when moving to another image (toggle: shift+z)") { .bool($0.keepZoom) },
        Setting("view", "zoom_step", "factor of one zoom.in / zoom.out step") { .float($0.zoomStep) },
        Setting("view", "refine_delay_ms", "pause after a zoom gesture before the high-quality re-render") {
            .integer($0.refineDelayMs)
        },
        Setting("fullscreen", "mode", "instant (borderless, no Space animation) | native (macOS Space)") {
            .string($0.fullscreen.rawValue)
        },
        Setting("fullscreen", "avoid_notch", "keep the image below the camera housing on notched displays") {
            .bool($0.avoidNotch)
        },
        Setting("hud", "mode", "off | minimal | full   (cycle with i)") { .string($0.hud.rawValue) },
        Setting("cache", "memory_mb", "decoded-image budget in MB, or \"auto\" (derived from installed memory)") {
            $0.cacheBudgetMB.map(TOMLValue.integer) ?? .string("auto")
        },
        Setting("rating", "storage", "finder-tags | none") { .string($0.ratingStorage.rawValue) },
        Setting("rating", "star", "3 stars -> Finder tag \"★★★\"") { .string($0.starCharacter) },
        Setting("rating", "auto_advance", "true: plain 0-9 / p / x / u also go to the next image (shift+key always does)") {
            .bool($0.autoAdvance)
        },
        Setting("decode", "hdr", "gain-map and PQ / HLG photos in HDR (10-15x the SDR decode time; PEEKABOO_HDR=1 forces it)") {
            .bool($0.decodeHDR)
        },
        Setting("decode", "fast_path", "ImageIO's private IOSurface path (false: public path only; PEEKABOO_NO_IOSURFACE_SPI=1)") {
            .bool($0.fastPath)
        },
        Setting("debug", "trace", "timestamped trace lines on stderr (PEEKABOO_TRACE=1 forces it)") { .bool($0.trace) },
        Setting("updates", "check", "look for a new release when online (never during launch, at most hourly)") {
            .bool($0.updates.check)
        },
        Setting("updates", "auto_install", "download it in the background and install it when Peekaboo quits") {
            .bool($0.updates.autoInstall)
        },
        Setting("keymap", "vim", "add the vim layer (h j k l, g g, G, d d, y y, y p ...) on keys [keys] leaves free") {
            .bool($0.vimKeys)
        },
    ]

    /// The generation a file written now records: the newest of the settings' and default bindings'. A literal, so that
    /// reading a file of this generation (at launch) never builds the tables; `ConfigFileTests` checks it. Raise it
    /// with the generation of a new setting or default binding.
    public static let generation = 1

    /// The full file of the built-in configuration (what `app.config_file` creates, and what a Settings change starts
    /// from when there is no file).
    public static let defaultText = text()

    /// The full file for `schema` up to `generation` (default: the schema's), with the settings of `config`.
    static func text(_ schema: ConfigSchema = .current, generation: Int? = nil, settings config: AppConfig = .default) -> String {
        let generation = generation ?? schema.generation
        var lines = header
        func table(_ name: String, comment: String? = nil) {
            lines.append("")
            lines.append(commented("[\(name)]", comment))
        }
        let settings = schema.settings.filter { $0.generation <= generation }
        for name in settingTables {
            table(name)
            for setting in settings where setting.table == name { lines.append(line(setting, config)) }
        }
        table("slots", comment: "destinations for file.move:<slot> / file.copy:<slot>; opt+N moves, opt+shift+N copies")
        lines += slotExamples
        table("apps", comment: "for file.open_with:<name>: a bundle id, an app name or a path")
        lines += appExamples
        table("keymap")
        lines.append(commented("defaults = false", "false: [keys] below is the whole keymap (true: the built-in one, with [keys] on top)"))
        for setting in settings where setting.table == "keymap" { lines.append(line(setting, config)) }
        lines.append(commented("generation = \(generation)", "the default keys and settings of later versions this file has"))
        return lines.joined(separator: "\n") + "\n\n" + keysText(schema, generation: generation)
    }

    /// The `[keys]` and `[keys.zoomed]` sections of the full file: the default bindings of `generation`, in their groups,
    /// then examples (Reset All in Settings writes them anew).
    static func keysText(_ schema: ConfigSchema = .current, generation: Int? = nil) -> String {
        let generation = generation ?? schema.generation
        var lines: [String] = []
        for (context, name, comment, examples) in [
            (KeyContext.normal, "keys", "the whole keymap: delete a key to unbind it, change it to move the binding", keyExamples),
            (.zoomed, "keys.zoomed", "while zoomed in beyond fit; keys not bound here work as in [keys]", zoomedExamples),
        ] {
            if !lines.isEmpty { lines.append("") }
            lines.append(commented("[\(name)]", comment))
            for group in schema.keyGroups {
                let bindings = group.bindings.filter { $0.context == context && $0.generation <= generation }
                guard !bindings.isEmpty else { continue }
                lines.append("# " + group.title)
                lines += bindings.flatMap(Self.lines)
            }
            lines += examples
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The tables of settings, in file order (`[keymap]` comes with the keys).
    private static let settingTables = ["view", "fullscreen", "hud", "cache", "rating", "decode", "debug", "updates"]

    private static let header = [
        "# Peekaboo configuration: every setting at its built-in default, and the whole keymap.",
        "# Saving this file applies it at once. An error shows as a toast with its line number, and the",
        "# previous configuration stays active; an unknown key is skipped with a warning, and the rest",
        "# applies. Reference: docs/CONFIG.md in the Peekaboo repository.",
        "# A setting you delete keeps its built-in default; a key you delete from [keys] is unbound.",
        "# Settings and default keys that later versions add are appended once, with their defaults.",
        "#",
        "# Planned, not read yet (skipped with a warning if set): the [general] table (sort, wrap,",
        "# include_hidden, recursive, open_multiple, keep_running, escape), the [loading] table, view.fit,",
        "# view.actual, view.upscale_filter, fullscreen.hide_cursor_ms, hud.position, hud.autohide_ms,",
        "# hud.font_size, hud.toast_ms, cache.prefetch_ahead, cache.prefetch_behind and cache.preview_count.",
    ]

    private static let slotExamples = [
        "# 1 = \"~/Pictures/Keep\"",
        "# 2 = \"~/Pictures/Later\"",
        commented("# 3 = \"./_rejects\"", "relative = next to the current image"),
        "# keep = \"~/Pictures/Keep\"",
    ]

    private static let appExamples = [
        commented("# editor = \"com.pixelmatorteam.pixelmator.x\"", "e opens the app named editor", column: 46),
        "# preview = \"com.apple.Preview\"",
    ]

    private static let keyExamples = [
        "",
        "# More keys, as examples (a key is bound once per table; an action may have several):",
        commented("# \"file.move:keep\" = \"s\"", "one-key keep (needs the keep slot above)", column: 46),
        commented("# \"o\" = \"file.open_with:preview\"", "needs the preview app above", column: 46),
        commented("# \"ctrl+x o\" = \"exec:open -a ImageOptim {path}\"", "a sequence: ctrl+x, then o", column: 56),
        commented("# \"ctrl+x p\" = \"exec:open -a 'Pixelmator Pro' {path}\"", "{path} is passed safely quoted",
                  column: 56),
        commented("# \"d d\" = \"none\"", "with vim = true: \"none\" unbinds a key of the vim layer", column: 46),
    ]

    private static let zoomedExamples = [
        "",
        commented("# \"space\" = \"pan.down\"", "an example: space pans down instead of going to the next image",
                  column: 46),
    ]

    /// `setting` with `config`'s value and its comment.
    private static func line(_ setting: Setting, _ config: AppConfig) -> String {
        commented(TOMLEditor.spelling(key: setting.key, quoted: false) + " = " + setting.value(config).tomlText,
                  setting.comment)
    }

    /// The file's lines of a default binding: `"action" = key(s)` for one action, one `"key" = [actions]` per key for
    /// an action list (the parser reads both).
    static func lines(_ binding: Keymap.DefaultBinding) -> [String] {
        if binding.actions.count == 1 {
            let keys: TOMLValue = binding.keys.count == 1 ? .string(binding.keys[0]) : .array(binding.keys.map(TOMLValue.string))
            return [TOMLValue.string(binding.actions[0].id).tomlText + " = " + keys.tomlText]
        }
        let actions = TOMLValue.array(binding.actions.map { .string($0.id) }).tomlText
        return binding.keys.map { TOMLValue.string($0).tomlText + " = " + actions }
    }

    /// `text` with `# comment` at `column` (at least one space before it), or `text` alone.
    static func commented(_ text: String, _ comment: String?, column: Int = 30) -> String {
        guard let comment else { return text }
        return text + String(repeating: " ", count: max(1, column - text.count)) + "# " + comment
    }
}

/// What a full config file holds, each part with the file generation that added it. `.current` is this version's
/// (`ConfigFile.settings`, `Keymap.defaultGroups`); tests make others to play later versions.
struct ConfigSchema: Sendable {
    let settings: [ConfigFile.Setting]
    let keyGroups: [Keymap.DefaultGroup]
    /// The newest generation of its settings and bindings: what a file written now records.
    let generation: Int

    init(settings: [ConfigFile.Setting], keyGroups: [Keymap.DefaultGroup]) {
        self.settings = settings
        self.keyGroups = keyGroups
        let bindings = keyGroups.flatMap(\.bindings)
        generation = max(1, settings.map(\.generation).max() ?? 1, bindings.map(\.generation).max() ?? 1)
    }

    var bindings: [Keymap.DefaultBinding] { keyGroups.flatMap(\.bindings) }

    static let current = ConfigSchema(settings: ConfigFile.settings, keyGroups: Keymap.defaultGroups)
}
