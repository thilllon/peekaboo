import Foundation

/// Changes to `config.toml` made from the Settings window, as minimal edits of the file's text (`TOMLEditor`):
/// comments, order and formatting stay as the user wrote them, and nothing but the changed entries moves.
///
/// Key bindings follow the file's own semantics (docs/CONFIG.md): user entries in `[keys]` / `[keys.zoomed]`
/// (either spelling, `"chord" = "action"` or `"action" = ["chord", …]`) on top of the built-in keymap that
/// `[keymap] defaults`, `[keymap] vim` and `[rating] auto_advance` select. A binding that only restates the built-in
/// keymap is not written; turning off a built-in binding writes `"chord" = "none"`.
public struct ConfigEditor {
    private var toml: TOMLEditor

    public init(text: String) { toml = TOMLEditor(text) }

    /// The edited text.
    public var text: String { toml.text }

    // MARK: Settings

    /// Tables whose commented-out lines are examples of a value (a slot, an app, a binding), not documentation of a
    /// key: a new entry never takes over such a line and its comment.
    private static let exampleTables: Set<String> = ["slots", "apps", "keys"]

    /// The value of `key` in `table` (`"keys.zoomed"` for a subtable) as the text has it; nil when it is absent or the
    /// text is not valid TOML.
    public func value(_ key: String, in table: String) -> TOMLValue? {
        try? toml.value(at: Self.path(table) + [key])
    }

    /// Set `key` of `table`, e.g. `set("background", in: "view", to: .string("gray"))`.
    public mutating func set(_ key: String, in table: String, to value: TOMLValue) throws {
        let path = Self.path(table)
        try edit { try $0.set(value, key: key, in: path, reuseCommentedLine: !Self.exampleTables.contains(path[0])) }
    }

    /// Remove `key` of `table` (its built-in default applies again). Nothing happens when it is absent.
    public mutating func remove(_ key: String, in table: String) throws {
        try edit { try $0.remove(Self.path(table) + [key]) }
    }

    private static func path(_ table: String) -> [String] { table.split(separator: ".").map(String.init) }

    /// Run `change`, reporting TOML syntax errors with their line.
    private mutating func edit(_ change: (inout TOMLEditor) throws -> Void) throws {
        do {
            try change(&toml)
        } catch let error as TOMLError {
            throw ConfigEditError(line: error.line, message: error.message)
        } catch let error as TOMLEditError {
            throw ConfigEditError(line: nil, message: error.description)
        }
    }

    private func document() throws -> TOMLDocument {
        do {
            return try TOMLDocument(parsing: toml.text)
        } catch let error as TOMLError {
            throw ConfigEditError(line: error.line, message: error.message)
        }
    }

    // MARK: Key bindings

    /// Make `sequence` run `actions` in `context`, taking it from whatever it ran before (other actions keep their
    /// other keys). Nothing is written when the built-in keymap already does exactly that.
    public mutating func bind(_ sequence: [KeyChord], to actions: [Action], context: KeyContext) throws {
        let builtIn = try builtInKeymap()
        try removeUserBindings(of: sequence, context: context)
        guard builtIn.bindings[context]?[sequence] != actions else { return }
        let table = try keyTables(context).primary
        try edit {
            try $0.set(Self.value(of: actions), key: KeyChord.spec(of: sequence), in: table, quoteKey: true,
                       reuseCommentedLine: false)
        }
    }

    /// Free `sequence` in `context`: the user's entries for it go, and a built-in binding is turned off with `"none"`
    /// (in `[keys.zoomed]` that lets the key fall back to `[keys]`).
    public mutating func unbind(_ sequence: [KeyChord], context: KeyContext) throws {
        let builtIn = try builtInKeymap()
        try removeUserBindings(of: sequence, context: context)
        guard builtIn.bindings[context]?[sequence] != nil else { return }
        let table = try keyTables(context).primary
        try edit {
            try $0.set(.string("none"), key: KeyChord.spec(of: sequence), in: table, quoteKey: true, reuseCommentedLine: false)
        }
    }

    /// Give `actions` exactly its built-in keys in `context` again: the user's entries that bind it go, and so do the
    /// overrides of its built-in keys (`"none"`, or another action that took one of them).
    public mutating func reset(_ actions: [Action], context: KeyContext) throws {
        let builtIn = try builtInKeymap()
        for entry in try bindingEntries(context) where entry.actions == actions {
            try edit { try $0.remove(entry.path) }
        }
        for (sequence, bound) in builtIn.bindings[context] ?? [:] where bound == actions {
            try removeUserBindings(of: sequence, context: context)
        }
    }

    /// Remove every entry of `[keys]`, `[keys.normal]` and `[keys.zoomed]`: the built-in keymap applies as it is.
    public mutating func resetBindings() throws {
        let tables = try keyTables(.normal).all + keyTables(.zoomed).all
        for entry in try document().entries where tables.contains(Array(entry.path.dropLast())) {
            try edit { try $0.remove(entry.path) }
        }
    }

    /// The keymap the file starts from before its `[keys]` tables.
    private func builtInKeymap() throws -> Keymap {
        let document = try document()
        func flag(_ path: [String], _ fallback: Bool) -> Bool {
            if case .bool(let value)? = document.value(path) { return value }
            return fallback
        }
        return Keymap.build(defaults: flag(["keymap", "defaults"], true), vim: flag(["keymap", "vim"], false),
                            autoAdvance: flag(["rating", "auto_advance"], false))
    }

    /// Where new bindings of `context` go, and every table its bindings may be in (`[keys.normal]` is `[keys]`).
    private func keyTables(_ context: KeyContext) throws -> (primary: [String], all: [[String]]) {
        switch context {
        case .zoomed:
            return (["keys", "zoomed"], [["keys", "zoomed"]])
        case .normal:
            let explicit = Set(try document().tables.map(\.path))
            let primary = !explicit.contains(["keys"]) && explicit.contains(["keys", "normal"]) ? ["keys", "normal"] : ["keys"]
            return (primary, [["keys"], ["keys", "normal"]])
        }
    }

    /// One user entry of a keys table.
    private struct BindingEntry {
        let path: [String]
        /// A `"chord" = action(s)` entry's keys; nil for `"action" = chord(s)`.
        let sequence: [KeyChord]?
        /// What it binds: the value of a chord entry, the key of an action entry.
        let actions: [Action]
        /// An action entry's chords as written.
        let chords: [String]
    }

    private func bindingEntries(_ context: KeyContext) throws -> [BindingEntry] {
        let tables = try keyTables(context).all
        var result: [BindingEntry] = []
        for entry in try document().entries where tables.contains(Array(entry.path.dropLast())) {
            guard let key = entry.path.last else { continue }
            let strings: [String]
            switch entry.value {
            case .string(let s): strings = [s]
            case .array(let items): strings = items.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
            default: continue
            }
            // The parser reads a key that is an action id as `"action" = chord(s)` (`"none" = ["tab"]` too).
            if let action = Action(id: key) {
                result.append(BindingEntry(path: entry.path, sequence: nil, actions: [action], chords: strings))
            } else if let sequence = KeyChord.sequence(spec: key) {
                result.append(BindingEntry(path: entry.path, sequence: sequence, actions: strings.compactMap(Action.init(id:)),
                                           chords: []))
            }
        }
        return result
    }

    /// Take `sequence` out of the user's entries of `context`: a chord entry for it goes, an action entry loses it.
    private mutating func removeUserBindings(of sequence: [KeyChord], context: KeyContext) throws {
        for entry in try bindingEntries(context) {
            if let own = entry.sequence {
                if own == sequence { try edit { try $0.remove(entry.path) } }
                continue
            }
            let kept = entry.chords.filter { KeyChord.sequence(spec: $0) != sequence }
            guard kept.count != entry.chords.count else { continue }
            if kept.isEmpty {
                try edit { try $0.remove(entry.path) }
            } else {
                let value: TOMLValue = kept.count == 1 ? .string(kept[0]) : .array(kept.map(TOMLValue.string))
                try edit { try $0.set(value, key: entry.path[entry.path.count - 1], in: Array(entry.path.dropLast())) }
            }
        }
    }

    private static func value(of actions: [Action]) -> TOMLValue {
        actions.count == 1 ? .string(actions[0].id) : .array(actions.map { .string($0.id) })
    }
}

/// Why an edit was refused: the text is not valid TOML (`line` names the problem), or the change could not be made
/// without touching other lines.
public struct ConfigEditError: Error, Equatable, CustomStringConvertible {
    public let line: Int?
    public let message: String

    public var description: String { line.map { "line \($0): \(message)" } ?? message }
}

/// A binding that recording keys for other actions would take over or break.
public struct KeyConflict: Equatable, Sendable {
    /// The other binding: its keys, what they run, and the table they are in.
    public let sequence: [KeyChord]
    public let actions: [Action]
    public let context: KeyContext
    /// False: the same keys (they move to the new actions). True: a sequence that the new keys start, or one that
    /// starts them (`g` and `g g`): a bound key cannot start a sequence, so the other binding has to go.
    public let isPrefix: Bool
}

extension Keymap {
    /// What binding `sequence` to `actions` in `context` would take over or break; empty when the keys are free (in
    /// that table) or already run `actions`. A zoomed binding hiding a normal one is not a conflict: that is what
    /// `[keys.zoomed]` is for.
    public func conflicts(binding sequence: [KeyChord], to actions: [Action], context: KeyContext) -> [KeyConflict] {
        var result: [KeyConflict] = []
        if let current = bindings[context]?[sequence], current != actions, current != [.none] {
            result.append(KeyConflict(sequence: sequence, actions: current, context: context, isPrefix: false))
        }
        var candidate = self
        candidate.bind(sequence, to: actions, context: context)
        let other: KeyContext = context == .normal ? .zoomed : .normal
        for pair in candidate.conflicts() where pair.sequence == sequence || pair.prefix == sequence {
            let keys = pair.sequence == sequence ? pair.prefix : pair.sequence
            let table = bindings[context]?[keys] != nil ? context : other
            guard let bound = bindings[table]?[keys], bound != [.none],
                  !result.contains(where: { $0.sequence == keys && $0.context == table }) else { continue }
            result.append(KeyConflict(sequence: keys, actions: bound, context: table, isPrefix: true))
        }
        return result
    }

    /// Every action list bound in `context`'s own table, with its keys (shortest first, then by spelling).
    public func bindingsByActions(_ context: KeyContext) -> [[Action]: [[KeyChord]]] {
        var result: [[Action]: [[KeyChord]]] = [:]
        for (sequence, actions) in bindings[context] ?? [:] where actions != [.none] {
            result[actions, default: []].append(sequence)
        }
        for key in result.keys {
            result[key]?.sort { $0.count != $1.count ? $0.count < $1.count : KeyChord.spec(of: $0) < KeyChord.spec(of: $1) }
        }
        return result
    }
}
