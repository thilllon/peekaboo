import Foundation

/// Changes to `config.toml` made from the Settings window, as minimal edits of the file's text (`TOMLEditor`):
/// comments, order and formatting stay as the user wrote them, and nothing but the changed entries moves.
///
/// Key bindings follow the file's own semantics (docs/CONFIG.md): user entries in `[keys]` / `[keys.zoomed]`
/// (either spelling, `"chord" = "action"` or `"action" = ["chord", …]`) on top of the built-in layers that
/// `[keymap] defaults`, `[keymap] vim` and `[rating] auto_advance` select. Two forms:
///
/// - The file lists the keymap (`defaults = false`, as Peekaboo writes it): a new key goes into its action's
///   `"action" = [...]` line, removing a key deletes it from its line (or the line), and changing a key replaces it in
///   place. `"none"` is written only for a key of the vim layer.
/// - An older file (`defaults = true`): entries on top of the built-in keymap. A binding that only restates it is not
///   written; turning off a built-in binding writes `"chord" = "none"`.
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

    /// Set `key` of `table`, e.g. `set("background", in: "view", to: .string("gray"))`. A new line gets `comment`.
    public mutating func set(_ key: String, in table: String, to value: TOMLValue) throws {
        try set(key, in: table, to: value, comment: nil)
    }

    mutating func set(_ key: String, in table: String, to value: TOMLValue, comment: String?) throws {
        let path = Self.path(table)
        try edit {
            try $0.set(value, key: key, in: path, reuseCommentedLine: !Self.exampleTables.contains(path[0]), comment: comment)
        }
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
    /// other keys). Nothing is written when the layer below the file's bindings already does exactly that.
    public mutating func bind(_ sequence: [KeyChord], to actions: [Action], context: KeyContext) throws {
        let base = try baseKeymap()
        // Already so in the file: nothing moves (a key would leave its place in its line and come back at the end).
        if try bindingEntries(context).contains(where: { $0.binds(sequence) == actions }) { return }
        try removeUserBindings(of: sequence, context: context)
        guard base.bindings[context]?[sequence] != actions else { return }
        try write(sequence, actions, context: context)
    }

    /// Free `sequence` in `context`: the user's entries for it go, and a binding of the layer below them (the built-in
    /// keymap, or with `defaults = false` the vim layer) is turned off with `"none"` (in `[keys.zoomed]` that lets the
    /// key fall back to `[keys]`). Given the `actions` the key is taken off (a row's key, removed), a file that lists the
    /// keymap writes `"none"` only for a binding of the vim layer to those actions: where its line shadowed another
    /// action of the vim layer (`k`), deleting the line gives the key to that one, as deleting it in an editor does.
    public mutating func unbind(_ sequence: [KeyChord], from actions: [Action]? = nil, context: KeyContext) throws {
        let base = try baseKeymap()
        try removeUserBindings(of: sequence, context: context)
        guard let below = base.bindings[context]?[sequence] else { return }
        if let actions, below != actions, try listsKeymap() { return }
        let table = try keyTables(context).primary
        try edit {
            try $0.set(.string("none"), key: KeyChord.spec(of: sequence), in: table, quoteKey: true, reuseCommentedLine: false)
        }
    }

    /// Give `actions` the key `new` instead of `old` in `context`. An `"action" = [...]` line of the file that lists `old`
    /// gets `new` in its place; otherwise it is `unbind(old, from: actions)`, then `bind(new)`.
    public mutating func rebind(_ old: [KeyChord], to new: [KeyChord], actions: [Action], context: KeyContext) throws {
        let base = try baseKeymap()
        func line() throws -> BindingEntry? {
            try bindingEntries(context).first { $0.sequence == nil && $0.actions == actions && $0.lists(old) }
        }
        // In place unless the layer below gives `old` to `actions` too (then it is turned off there), or to another
        // action in an older file (where taking a key off an action always frees it).
        let below = base.bindings[context]?[old]
        let inPlace = try listsKeymap() ? below != actions : below == nil
        guard actions.count == 1, inPlace, base.bindings[context]?[new] != actions, try line() != nil else {
            try unbind(old, from: actions, context: context)
            return try bind(new, to: actions, context: context)
        }
        try removeUserBindings(of: new, context: context)
        guard let entry = try line() else { return try bind(new, to: actions, context: context) }
        let chords = entry.chords.map { KeyChord.sequence(spec: $0) == old ? KeyChord.spec(of: new) : $0 }
        try edit { try $0.set(Self.value(ofKeys: chords), key: entry.key, in: entry.table) }
    }

    /// Give `actions` exactly its built-in keys in `context` again: the user's entries that bind it go, and so do the
    /// overrides of its built-in keys (`"none"`, or another action that took one of them). In a file that lists the
    /// keymap the built-in keys are those of the default lines (written back, an `"action" = [...]` line in its place)
    /// and of the vim layer when it is on.
    public mutating func reset(_ actions: [Action], context: KeyContext) throws {
        let autoAdvance = try flag(["rating", "auto_advance"], false)
        // What a key of the file runs: `auto_advance` makes its plain rating key advance, as the parser reads it.
        let advances = try autoAdvance && fileKeysAdvance()
        func effective(_ sequence: [KeyChord], _ bound: [Action]) -> [Action] {
            advances && Keymap.advancesAutomatically(sequence, bound) ? bound + [.next] : bound
        }
        guard try listsKeymap() else {
            let builtIn = try baseKeymap()
            for entry in try bindingEntries(context) {
                let keys = entry.sequences.filter { effective($0, entry.actions) == actions }
                guard !keys.isEmpty else { continue }
                if keys.count == entry.sequences.count {
                    try edit { try $0.remove(entry.path) }
                } else {
                    for sequence in keys { try removeUserBindings(of: sequence, context: context) }
                }
            }
            for (sequence, bound) in builtIn.bindings[context] ?? [:] where bound == actions {
                try removeUserBindings(of: sequence, context: context)
            }
            return
        }
        // The default lines that bind `actions` here (auto_advance makes a plain rating key advance), with those keys.
        let lines = Keymap.defaultBindings.filter { $0.context == context }.compactMap { binding -> Keymap.DefaultBinding? in
            let keys = zip(binding.keys, binding.sequences).filter { effective($0.1, binding.actions) == actions }.map(\.0)
            return keys.isEmpty ? nil : Keymap.DefaultBinding(context, binding.actions, keys, generation: binding.generation)
        }
        let defaultKeys = Set(lines.flatMap(\.sequences))
        // The vim layer's keys of `actions` that no default line takes: free them of the file's overrides.
        let reference = try Keymap.written(vim: flag(["keymap", "vim"], false), autoAdvance: autoAdvance)
        let base = try baseKeymap()
        for (sequence, bound) in base.bindings[context] ?? [:]
        where bound == actions && reference.bindings[context]?[sequence] == actions {
            try removeUserBindings(of: sequence, context: context)
        }
        // The file's other keys of `actions` go.
        for entry in try bindingEntries(context) {
            for sequence in entry.sequences where !defaultKeys.contains(sequence) && effective(sequence, entry.actions) == actions {
                try removeUserBindings(of: sequence, context: context)
            }
        }
        // Each default line: its keys taken from other bindings, then written (an "action" = [...] line keeps its place).
        for line in lines {
            func own() throws -> BindingEntry? {
                guard line.actions.count == 1 else { return nil }
                return try bindingEntries(context).first { $0.sequence == nil && $0.actions == line.actions }
            }
            for sequence in line.sequences {
                // A line of an action list the file still has stays where it is.
                if line.actions.count > 1, try bindingEntries(context).contains(where: { $0.binds(sequence) == line.actions }) {
                    continue
                }
                try removeUserBindings(of: sequence, context: context, except: own()?.path)
            }
            if let entry = try own() {
                let kept = entry.chords.filter { chord in !line.keys.contains { KeyChord.sequence(spec: $0) == KeyChord.sequence(spec: chord) } }
                try edit { try $0.set(Self.value(ofKeys: line.keys + kept), key: entry.key, in: entry.table) }
            } else {
                for sequence in line.sequences where base.bindings[context]?[sequence] != line.actions {
                    guard try !bindingEntries(context).contains(where: { $0.binds(sequence) == line.actions }) else { continue }
                    try write(sequence, line.actions, context: context)
                }
            }
        }
    }

    /// The built-in keymap again. In a file that lists the keymap, `[keys]` and `[keys.zoomed]` are written anew with
    /// the default lines (their sections replaced, `[keys.normal]` too); in an older file, every entry of those tables is
    /// removed, so the built-in keymap applies as it is.
    public mutating func resetBindings() throws {
        let tables = try keyTables(.normal).all + keyTables(.zoomed).all
        if try listsKeymap() {
            var generation = ConfigFile.generation
            if case .integer(let n)? = try document().value(["keymap", "generation"]) { generation = n }
            return try edit { try $0.replaceSections(Set(tables), with: ConfigFile.keysText(generation: generation)) }
        }
        for entry in try document().entries where tables.contains(Array(entry.path.dropLast())) {
            try edit { try $0.remove(entry.path) }
        }
    }

    /// Add a default binding of a later generation to a full file (`ConfigStore.upgradeFile`) as the file lists the
    /// default ones, whether the built-in keymap is under it or not: each key in its action's line (a new line at the
    /// end of the table if there is none), a `"key" = [actions]` line for an action list.
    mutating func add(_ binding: Keymap.DefaultBinding) throws {
        for sequence in binding.sequences { try write(sequence, binding.actions, context: binding.context, listed: true) }
    }

    /// The file lists the keymap: `[keymap] defaults = false`.
    private func listsKeymap() throws -> Bool { try !flag(["keymap", "defaults"], true) }

    /// `rating.auto_advance` applies to the file's own plain rating, label and flag keys (`ConfigReader`): in a file
    /// that lists the keymap, or in one Peekaboo wrote (it has `[keymap] generation`), whatever `defaults` says.
    private func fileKeysAdvance() throws -> Bool {
        if try listsKeymap() { return true }
        if case .integer? = try document().value(["keymap", "generation"]) { return true }
        return false
    }

    private func flag(_ path: [String], _ fallback: Bool) throws -> Bool {
        if case .bool(let value)? = try document().value(path) { return value }
        return fallback
    }

    /// The layer the file's `[keys]` tables go on top of: the built-in keymap (`defaults = true`), or the vim layer.
    private func baseKeymap() throws -> Keymap {
        try Keymap.build(defaults: flag(["keymap", "defaults"], true), vim: flag(["keymap", "vim"], false),
                         autoAdvance: flag(["rating", "auto_advance"], false))
    }

    /// Write a binding of `sequence` (none in the file now). In a file that lists the keymap (or `listed`), one action's
    /// key goes into that action's `"action" = [...]` line (a new one at the end of the table if there is none);
    /// otherwise, and for an action list, it is a new `"chord" = action(s)` line.
    private mutating func write(_ sequence: [KeyChord], _ actions: [Action], context: KeyContext, listed: Bool? = nil) throws {
        let spec = KeyChord.spec(of: sequence)
        let table = try keyTables(context).primary
        guard try listed ?? listsKeymap(), actions.count == 1 else {
            return try edit {
                try $0.set(Self.value(of: actions), key: spec, in: table, quoteKey: true, reuseCommentedLine: false)
            }
        }
        if let entry = try bindingEntries(context).first(where: { $0.sequence == nil && $0.actions == actions }) {
            return try edit { try $0.set(Self.value(ofKeys: entry.chords + [spec]), key: entry.key, in: entry.table) }
        }
        try edit { try $0.set(.string(spec), key: actions[0].id, in: table, quoteKey: true, reuseCommentedLine: false) }
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

        var key: String { path[path.count - 1] }
        var table: [String] { Array(path.dropLast()) }
        /// The key sequences it binds.
        var sequences: [[KeyChord]] { sequence.map { [$0] } ?? chords.compactMap(KeyChord.sequence(spec:)) }
        func lists(_ sequence: [KeyChord]) -> Bool { chords.contains { KeyChord.sequence(spec: $0) == sequence } }
        /// What it binds `sequence` to (nil: not that key).
        func binds(_ sequence: [KeyChord]) -> [Action]? {
            if let own = self.sequence { return own == sequence ? actions : nil }
            return lists(sequence) ? actions : nil
        }
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

    /// Take `sequence` out of the user's entries of `context` (but the one at `except`): a chord entry for it goes, an
    /// action entry loses it.
    private mutating func removeUserBindings(of sequence: [KeyChord], context: KeyContext, except: [String]? = nil) throws {
        for entry in try bindingEntries(context) where entry.path != except {
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

    /// An action entry's value: one chord, or a list of them.
    private static func value(ofKeys chords: [String]) -> TOMLValue {
        chords.count == 1 ? .string(chords[0]) : .array(chords.map(TOMLValue.string))
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
