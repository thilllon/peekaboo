import Foundation

/// Every problem found in a config file, each with its line. The file is applied only when this is empty.
struct ConfigError: Error, Equatable, Sendable, CustomStringConvertible {
    let fileName: String
    let errors: [TOMLError]

    init(fileName: String, errors: [TOMLError]) {
        self.fileName = fileName
        self.errors = errors.sorted { ($0.line, $0.column) < ($1.line, $1.column) }
    }

    /// One line per problem: `config.toml:17: unknown action "nav.nxt"`.
    var messages: [String] { errors.map { "\(fileName):\($0.line): \($0.message)" } }

    /// The first problem, plus how many more there are (fits a toast).
    var description: String {
        guard let first = messages.first else { return "\(fileName): invalid" }
        return Self.summary(messages) ?? first
    }

    /// The first message plus how many more there are, e.g. `config.toml:3: … (+2 more)`; nil when empty.
    static func summary(_ messages: [String]) -> String? {
        guard let first = messages.first else { return nil }
        return messages.count > 1 ? "\(first) (+\(messages.count - 1) more)" : first
    }
}

extension AppConfig {
    /// Parse a `config.toml` strictly: keys the file does not mention keep their built-in defaults, and
    /// `ConfigError` lists every unknown table, key, value, chord or action with its line.
    public init(toml text: String, fileName: String = "config.toml") throws {
        let reading = try Self.read(toml: text, fileName: fileName)
        if !reading.unknown.isEmpty { throw ConfigError(fileName: fileName, errors: reading.unknown) }
        self = reading.config
    }

    /// Parse a `config.toml` the way the app loads it: unknown tables and keys (a typo, a setting from a
    /// newer version) are skipped and returned as warnings such as `config.toml:3: ignored unknown key
    /// "view.fit"`, and the rest of the file applies. Throws `ConfigError` for everything else (bad
    /// values, chords, actions, TOML syntax), listing each problem with its line.
    public static func parse(toml text: String, fileName: String = "config.toml") throws -> (config: AppConfig, warnings: [String]) {
        let reading = try read(toml: text, fileName: fileName)
        return (reading.config, reading.warnings(fileName: fileName))
    }

    /// The config plus what the file holds (the skipped unknown tables and keys, its generation, the default bindings of
    /// later generations it leaves the keys free for); throws for the other errors.
    static func read(toml text: String, fileName: String = "config.toml", schema: ConfigSchema? = nil) throws -> ConfigReading {
        let document: TOMLDocument
        do {
            document = try TOMLDocument(parsing: text)
        } catch let error as TOMLError {
            throw ConfigError(fileName: fileName, errors: [error])
        }
        var reader = ConfigReader(schema: schema)
        let config = reader.read(document)
        if !reader.errors.isEmpty { throw ConfigError(fileName: fileName, errors: reader.errors + reader.unknown) }
        return ConfigReading(config: config, unknown: reader.unknown, document: document, generation: reader.generation,
                             added: reader.added)
    }
}

/// A config file read without errors: what it applies, and what an upgrade of it needs to know.
struct ConfigReading {
    let config: AppConfig
    /// The unknown tables and keys it skipped.
    let unknown: [TOMLError]
    let document: TOMLDocument
    /// `[keymap] generation`: which settings and default bindings of later versions a full file has (nil: none).
    let generation: Int?
    /// The default bindings of later generations on the keys a full file of an older generation leaves free, each with
    /// those keys only: its keymap got them (`[keymap] defaults = false`), or has them through the built-in one (`true`).
    let added: [Keymap.DefaultBinding]

    func warnings(fileName: String) -> [String] {
        unknown.sorted { ($0.line, $0.column) < ($1.line, $1.column) }.map { "\(fileName):\($0.line): ignored \($0.message)" }
    }
}

/// Maps a TOML document onto `AppConfig`, collecting errors instead of stopping at the first one.
private struct ConfigReader {
    /// The settings and default bindings of the version reading (nil: this one's, built only when a file of an older
    /// generation needs its later bindings: never for a file of this generation at launch).
    let schema: ConfigSchema?
    var errors: [TOMLError] = []
    /// Unknown tables and keys: skipped, so they are warnings when loading leniently.
    var unknown: [TOMLError] = []
    var config = AppConfig()
    /// `keymap.generation`.
    var generation: Int?
    /// See `ConfigReading.added`.
    var added: [Keymap.DefaultBinding] = []

    init(schema: ConfigSchema?) { self.schema = schema }

    private static let tables: Set<[String]> = [
        ["view"], ["fullscreen"], ["hud"], ["cache"], ["rating"], ["keymap"], ["decode"], ["debug"], ["slots"], ["apps"],
        ["updates"], ["keys"], ["keys", "normal"], ["keys", "zoomed"],
    ]

    mutating func fail(_ entry: TOMLEntry, _ message: String) {
        errors.append(TOMLError(line: entry.line, column: entry.column, message: message))
    }

    /// An unknown key: it is skipped and the rest of the file still applies.
    mutating func skip(_ entry: TOMLEntry, _ message: String) {
        unknown.append(TOMLError(line: entry.line, column: entry.column, message: message))
    }

    mutating func read(_ document: TOMLDocument) -> AppConfig {
        for table in document.tables where !Self.tables.contains(table.path) {
            unknown.append(TOMLError(line: table.line, column: 1,
                                     message: "unknown table [\(table.path.joined(separator: "."))]"))
        }
        var keyEntries: [(entry: TOMLEntry, context: KeyContext, chord: String)] = []
        keyEntries.reserveCapacity(document.entries.count)
        for entry in document.entries {
            let path = entry.path
            if path.first == "keys" {
                switch path.count {
                case 2: keyEntries.append((entry, .normal, path[1]))
                case 3 where path[1] == "zoomed": keyEntries.append((entry, .zoomed, path[2]))
                case 3 where path[1] == "normal": keyEntries.append((entry, .normal, path[2]))
                default: skip(entry, "unknown key \"\(path.joined(separator: "."))\" (bindings go in [keys] or [keys.zoomed])")
                }
                continue
            }
            let name = path.joined(separator: ".")
            switch path.first {
            case "slots", "apps":
                guard path.count == 2 else { skip(entry, "unknown key \"\(name)\""); continue }
                guard case .string(let value) = entry.value, !value.trimmingCharacters(in: .whitespaces).isEmpty else {
                    fail(entry, "\(name) must be a non-empty string"); continue
                }
                if path[0] == "slots" { config.slots[path[1]] = value } else { config.apps[path[1]] = value }
                continue
            default: break
            }
            switch name {
            case "view.background":
                if let v = choice(entry, ["black", "gray", "checker"]) { config.background = v }
            case "view.keep_zoom": if let v = bool(entry) { config.keepZoom = v }
            case "view.zoom_step": if let v = number(entry, 1.01...8) { config.zoomStep = v }
            case "view.refine_delay_ms": if let v = integer(entry, 0...2000) { config.refineDelayMs = v }
            case "fullscreen.mode":
                if let v = choice(entry, AppConfig.FullscreenMode.allCases.map(\.rawValue)) {
                    config.fullscreen = AppConfig.FullscreenMode(rawValue: v)!
                }
            case "fullscreen.avoid_notch": if let v = bool(entry) { config.avoidNotch = v }
            case "hud.mode":
                if let v = choice(entry, AppConfig.HUDMode.allCases.map(\.rawValue)) { config.hud = AppConfig.HUDMode(rawValue: v)! }
            case "cache.memory_mb":
                if case .string("auto") = entry.value { config.cacheBudgetMB = nil } else if let v = integer(entry, 64...1_048_576, orAuto: true) {
                    config.cacheBudgetMB = v
                }
            case "rating.storage":
                if let v = choice(entry, AppConfig.RatingStorage.allCases.map(\.rawValue)) {
                    config.ratingStorage = AppConfig.RatingStorage(rawValue: v)!
                }
            case "rating.star":
                if case .string(let s) = entry.value, s.count == 1 { config.starCharacter = s } else {
                    fail(entry, "rating.star must be a single character, e.g. \"★\"")
                }
            case "rating.auto_advance": if let v = bool(entry) { config.autoAdvance = v }
            case "keymap.defaults": if let v = bool(entry) { config.keymapDefaults = v }
            case "keymap.vim": if let v = bool(entry) { config.vimKeys = v }
            case "keymap.generation": if let v = integer(entry, 1...1_000_000) { generation = v }
            case "decode.hdr": if let v = bool(entry) { config.decodeHDR = v }
            case "decode.fast_path": if let v = bool(entry) { config.fastPath = v }
            case "debug.trace": if let v = bool(entry) { config.trace = v }
            case "updates.check": if let v = bool(entry) { config.updates.check = v }
            case "updates.auto_install": if let v = bool(entry) { config.updates.autoInstall = v }
            default:
                skip(entry, "unknown key \"\(name)\"\(Self.keyHint(path))")
            }
        }
        config.keymap = buildKeymap(keyEntries, defaults: config.keymapDefaults, vim: config.vimKeys,
                                    autoAdvance: config.autoAdvance)
        return config
    }

    /// Every settings key, for hints about misplaced keys.
    private static let settingKeys = ConfigFile.settings.map { "\($0.table).\($0.key)" } + ["keymap.defaults", "keymap.generation"]

    /// ` (it belongs under [view])` for a known key in the wrong table, ` (key bindings go under [keys])`
    /// for a chord outside `[keys]`.
    private static func keyHint(_ path: [String]) -> String {
        guard let last = path.last else { return "" }
        if let home = settingKeys.first(where: { $0.hasSuffix("." + last) }) {
            return " (it belongs under [\(home.split(separator: ".")[0])])"
        }
        if path.count == 1, KeyChord.sequence(spec: last) != nil { return " (key bindings go under [keys])" }
        return ""
    }

    // MARK: Keys

    /// The file's bindings on top of the built-in layers `[keymap]` selects. With `defaults = false` (the file lists the
    /// keymap) the vim layer is under the file's bindings; with `true`, the built-in keymap with the vim layer on top.
    /// A full file of an older generation gets the default bindings of the later ones on the keys its own lines and the
    /// vim layer leave free (in `added`, for `ConfigStore.upgradeFile` to write in); they apply at once with
    /// `defaults = false`, and with `true` the built-in keymap has them already. `auto_advance` applies to the file's
    /// plain rating, label and flag keys in a file that lists the keymap or that Peekaboo wrote (it has a generation);
    /// an older file of overrides keeps its own entries as they are.
    private mutating func buildKeymap(_ entries: [(entry: TOMLEntry, context: KeyContext, chord: String)],
                                      defaults: Bool, vim: Bool, autoAdvance: Bool) -> Keymap {
        var keymap = defaults && !vim && !autoAdvance && schema == nil ? Keymap.default
            : Keymap.build(defaults ? schema?.bindings ?? Keymap.defaultBindings : [], vim: vim,
                           autoAdvance: defaults && autoAdvance)
        let older = generation.map { $0 < schema?.generation ?? ConfigFile.generation } ?? false
        // With the built-in keymap under the file, the file's own lines and the vim layer: what later bindings must leave
        // free (built only for a full file of an older generation, never at launch for one of this generation).
        var own = older && defaults ? Keymap.build([], vim: vim, autoAdvance: false) : nil
        var lineOf: [KeyContext: [[KeyChord]: Int]] = [:]
        func bind(_ sequence: [KeyChord], _ actions: [Action], _ entry: TOMLEntry, _ context: KeyContext) {
            if let earlier = lineOf[context, default: [:]].updateValue(entry.line, forKey: sequence) {
                lineOf[context]?[sequence] = earlier
                fail(entry, "\"\(KeyChord.spec(of: sequence))\" is already bound on line \(earlier)")
                return
            }
            keymap.bind(sequence, to: actions, context: context)
            own?.bind(sequence, to: actions, context: context)
        }
        for (entry, context, spec) in entries {
            // Two spellings: "chord" = action(s), or "action" = chord(s) to give one action several keys.
            if let action = Action(id: spec) {
                guard validate(action, entry), let specs = keySpecs(entry) else { continue }
                let actions = [action]
                for keys in specs {
                    do {
                        bind(try KeyChord.parseSequence(keys), actions, entry, context)
                    } catch {
                        fail(entry, "\"\(keys)\": \(error)")
                    }
                }
            } else {
                do {
                    let sequence = try KeyChord.parseSequence(spec)
                    guard let actions = actions(entry) else { continue }
                    bind(sequence, actions, entry, context)
                } catch {
                    fail(entry, "\"\(spec)\": \(error)"); continue
                }
            }
        }
        if let generation, older {
            if var own {
                addLaterBindings(after: generation, to: &own, used: lineOf)
            } else {
                addLaterBindings(after: generation, to: &keymap, used: lineOf)
            }
        }
        if autoAdvance, !defaults || generation != nil { keymap.applyAutoAdvance() }
        for conflict in keymap.conflicts() {
            let line = [conflict.sequence, conflict.prefix].compactMap { lineOf[.normal]?[$0] ?? lineOf[.zoomed]?[$0] }.first ?? 0
            errors.append(TOMLError(line: line, column: 1, message:
                "\"\(KeyChord.spec(of: conflict.sequence))\" conflicts with \"\(KeyChord.spec(of: conflict.prefix))\" (a bound key cannot start a sequence; unbind it with \"none\")"))
        }
        return keymap
    }

    /// The default bindings of the generations after `generation`, bound in `keymap` on each of their keys that the file
    /// does not mention (in either table, `"none"` included) and that no binding of `keymap` starts or is the start of
    /// (the file's and the vim layer's), and listed in `added`.
    private mutating func addLaterBindings(after generation: Int, to keymap: inout Keymap,
                                           used: [KeyContext: [[KeyChord]: Int]]) {
        for binding in (schema ?? .current).bindings where binding.generation > generation {
            var keys: [String] = []
            for (key, sequence) in zip(binding.keys, binding.sequences)
            where used[.normal]?[sequence] == nil && used[.zoomed]?[sequence] == nil && keymap.leavesFree(sequence) {
                keymap.bind(sequence, to: binding.actions, context: binding.context)
                keys.append(key)
            }
            if !keys.isEmpty { added.append(Keymap.DefaultBinding(binding.context, binding.actions, keys, generation: binding.generation)) }
        }
    }

    private mutating func actions(_ entry: TOMLEntry) -> [Action]? {
        let ids: [String]
        switch entry.value {
        case .string(let id): ids = [id]
        case .array(let items):
            var strings: [String] = []
            for item in items {
                guard case .string(let id) = item else { fail(entry, "actions must be strings"); return nil }
                strings.append(id)
            }
            guard !strings.isEmpty else { fail(entry, "empty action list (use \"none\" to unbind)"); return nil }
            ids = strings
        default:
            fail(entry, "expected an action string or a list of actions, got \(entry.value.typeName)"); return nil
        }
        var actions: [Action] = []
        for id in ids {
            guard let action = Action(id: id) else {
                fail(entry, "unknown action \"\(id)\"\(Self.suggestion(for: id))"); return nil
            }
            guard validate(action, entry) else { return nil }
            actions.append(action)
        }
        if actions.count > 1, actions.contains(.none) { fail(entry, "\"none\" cannot be part of an action list"); return nil }
        return actions
    }

    /// Move/copy targets must be a path, `ask`, `last`, a slot defined under `[slots]` or one of the slots 1…9 that the
    /// default keys name (`FileOperations.isKnownTarget`).
    private mutating func validate(_ action: Action, _ entry: TOMLEntry) -> Bool {
        switch action {
        case .move(let target), .copy(let target), .copyPicks(let target):
            if !FileOperations.isKnownTarget(target, slots: config.slots) {
                fail(entry, "unknown slot \"\(target)\" (add it under [slots])")
                return false
            }
        default: break
        }
        return true
    }

    /// The value of an `"action" = …` entry: one chord (sequence) or a list of them.
    private mutating func keySpecs(_ entry: TOMLEntry) -> [String]? {
        switch entry.value {
        case .string(let keys): return [keys]
        case .array(let items) where !items.isEmpty:
            var specs: [String] = []
            for item in items {
                guard case .string(let keys) = item else { fail(entry, "keys must be strings"); return nil }
                specs.append(keys)
            }
            return specs
        default:
            fail(entry, "expected a key or a list of keys for \"\(entry.path.last ?? "")\"")
            return nil
        }
    }

    /// ` (did you mean "nav.next"?)` for near misses of parameterless ids.
    private static func suggestion(for id: String) -> String {
        let name = id.split(separator: ":").first.map(String.init) ?? id
        let known = Action.simpleIDs + ["nav.jump", "zoom.set", "pan.edge", "file.move", "file.copy", "file.copy_picks",
                                        "file.open_with", "meta.rate", "meta.label", "meta.flag", "exec"]
        if known.contains(name) { return " (check its argument)" }
        let best = known.min { distance($0, name) < distance($1, name) }
        guard let best, distance(best, name) <= 3 else { return "" }
        return " (did you mean \"\(best)\"?)"
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var previous = row[0]
            row[0] = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return row[b.count]
    }

    // MARK: Typed values

    private mutating func bool(_ entry: TOMLEntry) -> Bool? {
        if case .bool(let v) = entry.value { return v }
        fail(entry, "\(entry.path.joined(separator: ".")) must be true or false, got \(entry.value.typeName)")
        return nil
    }

    private mutating func integer(_ entry: TOMLEntry, _ range: ClosedRange<Int>, orAuto: Bool = false) -> Int? {
        if case .integer(let v) = entry.value, range.contains(v) { return v }
        let name = entry.path.joined(separator: ".")
        fail(entry, "\(name) must be an integer in \(range.lowerBound)…\(range.upperBound)\(orAuto ? " or \"auto\"" : "")")
        return nil
    }

    private mutating func number(_ entry: TOMLEntry, _ range: ClosedRange<Double>) -> Double? {
        let value: Double?
        switch entry.value {
        case .float(let f): value = f
        case .integer(let n): value = Double(n)
        default: value = nil
        }
        if let value, range.contains(value) { return value }
        fail(entry, "\(entry.path.joined(separator: ".")) must be a number in \(range.lowerBound)…\(range.upperBound)")
        return nil
    }

    private mutating func choice(_ entry: TOMLEntry, _ options: [String]) -> String? {
        if case .string(let v) = entry.value, options.contains(v) { return v }
        fail(entry, "\(entry.path.joined(separator: ".")) must be one of \(options.map { "\"\($0)\"" }.joined(separator: ", "))")
        return nil
    }
}
