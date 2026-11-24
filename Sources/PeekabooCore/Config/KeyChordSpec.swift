/// Config-string chords: `"cmd+shift+k"`, `"opt+1"`, `"space"`, `"?"` (= `shift+/`), `"G"` (= `shift+g`),
/// `"+"` (= `shift+=`) and sequences such as `"g g"`.
///
/// Shifted symbols resolve through a static US-ANSI table, with `shift` as a modifier; `KeyboardLayout`
/// turns key presses on any layout into the same spelling.
struct KeySpecError: Error, Equatable, Sendable, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

extension KeyChord {
    /// Parse one chord. Returns nil for unknown keys or modifiers.
    public init?(spec: String) {
        guard let chord = try? KeyChord.parse(spec) else { return nil }
        self = chord
    }

    /// Parse a space-separated chord sequence (`"g g"`, `"ctrl+x o"`).
    public static func sequence(spec: String) -> [KeyChord]? {
        try? parseSequence(spec)
    }

    /// Like `sequence(spec:)`, with a message such as `unknown key "foo"`.
    public static func parseSequence(_ spec: String) throws -> [KeyChord] {
        // A lone space means the space bar.
        if spec == " " { return [KeyChord(key: "space")] }
        let parts = spec.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard !parts.isEmpty else { throw KeySpecError("empty key") }
        return try parts.map { try parse(String($0)) }
    }

    /// Parse one chord, with a descriptive error.
    public static func parse(_ raw: String) throws -> KeyChord {
        var rest = Substring(raw)
        var modifiers: KeyModifiers = []
        // Peel `mod+` prefixes; whatever remains (even "+" or "kp+") is the key.
        peel: while true {
            for (name, modifier) in modifierNames {
                let prefix = name + "+"
                if rest.count > prefix.count, rest.lowercased().hasPrefix(prefix) {
                    modifiers.insert(modifier)
                    rest = rest.dropFirst(prefix.count)
                    continue peel
                }
            }
            break
        }
        let token = String(rest)
        guard !token.isEmpty else { throw KeySpecError("empty key") }
        if token.count == 1, let character = token.first, character.isASCII {
            if character.isUppercase {
                return KeyChord(key: character.lowercased(), modifiers: modifiers.union(.shift))
            }
            if let base = shiftedSymbols[character] {
                return KeyChord(key: String(base), modifiers: modifiers.union(.shift))
            }
            if unshiftedKeys.contains(character) { return KeyChord(key: token, modifiers: modifiers) }
        }
        let lower = token.lowercased()
        if let name = namedKeyAliases[lower] ?? (namedKeys.contains(lower) ? lower : nil) {
            return KeyChord(key: name, modifiers: modifiers)
        }
        if token.contains("+") {
            let mod = token.split(separator: "+").first.map(String.init) ?? token
            throw KeySpecError("unknown modifier \"\(mod)\" (use cmd, opt, ctrl or shift)")
        }
        throw KeySpecError("unknown key \"\(token)\"")
    }

    /// Canonical config spelling, e.g. `cmd+shift+k` (round-trips through `init(spec:)`).
    public var spec: String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("cmd") }
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    /// Menu-style glyphs, e.g. `⇧⌘K`, `?`, `⌥1`, `Space` (for the help overlay and menus).
    public var symbol: String {
        var out = ""
        var shown = modifiers
        // A shifted symbol reads better as the symbol itself ("?" not "⇧/").
        var keyText = KeyChord.keyGlyphs[key] ?? (key.count == 1 ? key.uppercased() : key.capitalized)
        if modifiers.contains(.shift), key.count == 1, let character = key.first {
            if let shifted = KeyChord.shiftOf[character] { keyText = String(shifted); shown.remove(.shift) }
        }
        if shown.contains(.control) { out += "⌃" }
        if shown.contains(.option) { out += "⌥" }
        if shown.contains(.shift) { out += "⇧" }
        if shown.contains(.command) { out += "⌘" }
        return out + keyText
    }

    /// Sequence spelling, e.g. `g g`.
    public static func spec(of sequence: [KeyChord]) -> String {
        sequence.map(\.spec).joined(separator: " ")
    }

    private static let modifierNames: [(String, KeyModifiers)] = [
        ("cmd", .command), ("command", .command), ("super", .command), ("⌘", .command),
        ("opt", .option), ("option", .option), ("alt", .option), ("⌥", .option),
        ("ctrl", .control), ("control", .control), ("⌃", .control),
        ("shift", .shift), ("⇧", .shift),
    ]

    /// US-ANSI: shifted symbol → its unshifted key.
    static let shiftedSymbols: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/",
        "~": "`",
    ]
    static let shiftOf: [Character: Character] = Dictionary(uniqueKeysWithValues: shiftedSymbols.map { ($1, $0) })

    /// Unshifted printable keys of the US layout.
    static let unshiftedKeys: Set<Character> = Set("abcdefghijklmnopqrstuvwxyz0123456789-=[]\\;',./`")

    /// Named keys reported by `KeyChord(event:)`.
    public static let namedKeys: Set<String> = {
        var names: Set<String> = ["left", "right", "up", "down", "space", "return", "tab", "esc", "backspace",
                                  "forwarddelete", "home", "end", "pageup", "pagedown", "kpenter",
                                  "kp+", "kp-", "kp*", "kp/", "kp."]
        for n in 1...20 { names.insert("f\(n)") }
        for n in 0...9 { names.insert("kp\(n)") }
        return names
    }()

    static let namedKeyAliases: [String: String] = [
        "enter": "return", "escape": "esc", "delete": "backspace", "del": "forwarddelete",
        "pgup": "pageup", "pgdn": "pagedown", "pgdown": "pagedown", "spacebar": "space",
        "arrowleft": "left", "arrowright": "right", "arrowup": "up", "arrowdown": "down",
    ]

    private static let keyGlyphs: [String: String] = [
        "left": "←", "right": "→", "up": "↑", "down": "↓", "space": "Space", "return": "↩", "tab": "⇥",
        "esc": "⎋", "backspace": "⌫", "forwarddelete": "⌦", "home": "↖", "end": "↘", "pageup": "⇞",
        "pagedown": "⇟", "kpenter": "⌤",
    ]
}
