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
        // Split on the UTF-8 bytes of space and tab (they never occur inside another character's bytes): the config
        // parses a hundred of these at launch, nearly all of them one chord.
        if !spec.isEmpty, !spec.utf8.contains(where: { $0 == 0x20 || $0 == 0x09 }) { return [try parse(spec)] }
        let parts = spec.utf8.split(whereSeparator: { $0 == 0x20 || $0 == 0x09 })
        guard !parts.isEmpty else { throw KeySpecError("empty key") }
        return try parts.map { try parse(String(decoding: $0, as: UTF8.self)) }
    }

    /// Parse one chord, with a descriptive error. Works on UTF-8 bytes (no lowercased copies, no grapheme counting).
    public static func parse(_ raw: String) throws -> KeyChord {
        var rest = raw
        var modifiers: KeyModifiers = []
        // Peel `mod+` prefixes (ASCII names in any case); whatever remains (even "+" or "kp+") is the key.
        peel: while true {
            let bytes = rest.utf8
            for (prefix, modifier) in modifierPrefixes where bytes.count > prefix.count && hasPrefix(bytes, prefix) {
                modifiers.insert(modifier)
                rest = String(decoding: bytes.dropFirst(prefix.count), as: UTF8.self)
                continue peel
            }
            break
        }
        let token = rest
        guard !token.isEmpty else { throw KeySpecError("empty key") }
        if token.utf8.count == 1, let byte = token.utf8.first, byte < 0x80 {
            if byte >= 0x41, byte <= 0x5A {  // A–Z
                return KeyChord(key: String(UnicodeScalar(byte + 0x20)), modifiers: modifiers.union(.shift))
            }
            let base = shiftedBase[Int(byte)]
            if base != 0 { return KeyChord(key: String(UnicodeScalar(base)), modifiers: modifiers.union(.shift)) }
            if unshiftedBytes[Int(byte)] { return KeyChord(key: token, modifiers: modifiers) }
        }
        let lower = token.utf8.contains(where: { $0 >= 0x41 && $0 <= 0x5A }) || !token.utf8.allSatisfy({ $0 < 0x80 })
            ? token.lowercased() : token
        // No alias is a key name: the names (the common case) first.
        if let name = namedKeys.contains(lower) ? lower : namedKeyAliases[lower] {
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

    /// `modifierNames` as the UTF-8 bytes of `name+`.
    private static let modifierPrefixes: [([UInt8], KeyModifiers)] = modifierNames.map { (Array(($0.0 + "+").utf8), $0.1) }

    /// `bytes` starts with `prefix`, ASCII letters in any case (`prefix` is lowercase).
    private static func hasPrefix(_ bytes: String.UTF8View, _ prefix: [UInt8]) -> Bool {
        var index = bytes.startIndex
        for expected in prefix {
            let byte = bytes[index]
            guard byte == expected || (byte >= 0x41 && byte <= 0x5A && byte + 0x20 == expected) else { return false }
            index = bytes.index(after: index)
        }
        return true
    }

    /// US-ANSI: shifted symbol → its unshifted key.
    static let shiftedSymbols: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/",
        "~": "`",
    ]
    static let shiftOf: [Character: Character] = Dictionary(uniqueKeysWithValues: shiftedSymbols.map { ($1, $0) })

    /// Unshifted printable keys of the US layout.
    static let unshiftedKeys: Set<Character> = Set("abcdefghijklmnopqrstuvwxyz0123456789-=[]\\;',./`")

    /// `shiftedSymbols` and `unshiftedKeys` by ASCII byte, for `parse` (0: not a shifted symbol).
    private static let shiftedBase: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 128)
        for (symbol, base) in shiftedSymbols { table[Int(symbol.asciiValue!)] = base.asciiValue! }
        return table
    }()
    private static let unshiftedBytes: [Bool] = {
        var table = [Bool](repeating: false, count: 128)
        for key in unshiftedKeys { table[Int(key.asciiValue!)] = true }
        return table
    }()

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
