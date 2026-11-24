/// What the printable keys of a keyboard layout type, and how a press of one becomes the `KeyChord` that
/// config strings spell in US terms (`?` is `shift+/`, `+` is `shift+=`), so the default keymap works on
/// German, French, Swedish, … keyboards too. The app reads it from the current ASCII-capable layout, so it
/// stays the same while a Korean or Japanese input method is active.
///
/// A press matches by key, in this order:
/// - letters are the keys labelled with them: `z` is the Z key on QWERTZ and AZERTY;
/// - digits are the keys that type them, unshifted or (AZERTY, whose number row types `&`, `é`, `"`, …)
///   with shift; where a layout types a digit only with option (Lithuanian, Vietnamese), the number-row
///   key in its US place;
/// - a symbol is the key that types it: the shifted symbol while shift is held (German ⇧ß is `?`), else
///   the unshifted one (the German `+` key is `+`);
/// - any other key, one typing `ü`, `ß`, `é`, `ñ`, … or a symbol of the US number row (French `$`, which
///   would read as shift plus a digit), is the US key in its place: German `ü` is `[`;
/// - option and command never change the key: `opt+1` is the 1 key, whatever it types with option.
public struct KeyboardLayout: Equatable, Sendable {
    /// What a key types without modifiers and with shift: one printable ASCII character (letters in
    /// lower case), or nil for anything else (a letter such as `ü`, a dead key's accent).
    public struct Key: Equatable, Sendable {
        public let base: Character?
        public let shifted: Character?

        public init(_ base: Character?, shifted: Character?) {
            self.base = base.flatMap(Self.printable).map { Character($0.lowercased()) }
            self.shifted = shifted.flatMap(Self.printable)
        }

        private static func printable(_ c: Character) -> Character? {
            guard let ascii = c.asciiValue, ascii > 0x20, ascii < 0x7F else { return nil }
            return c
        }
    }

    /// By virtual key code (HIToolbox `kVK_*`).
    public let keys: [Int: Key]
    /// Number-row keys that stand for the US digit in their place, because no typing key of the layout
    /// types that digit without option (Lithuanian, Vietnamese).
    private let digitsByPlace: [Int: Character]

    public init(keys: [Int: Key]) {
        self.keys = keys
        // Only the typing keys count: the keypad (key codes from 65) is matched as kp0…kp9, never as digits.
        let typed = Set(keys.filter { $0.key < 65 }.values.flatMap { [$0.base, $0.shifted] }.compactMap { $0 })
        digitsByPlace = Self.usDigitKeys.filter { !typed.contains($0.value) }
    }

    /// The chord for a press of the key `code` with `modifiers`; nil for a key that types nothing printable.
    /// Named keys (arrows, return, F-keys, the keypad) are the caller's.
    public func chord(keyCode code: Int, modifiers: KeyModifiers) -> KeyChord? {
        let key = keys[code]
        if let base = key?.base, base.isLetter || base.isNumber {
            return KeyChord(key: String(base), modifiers: modifiers)
        }
        if let shifted = key?.shifted, shifted.isNumber {
            return KeyChord(key: String(shifted), modifiers: modifiers)
        }
        if let digit = digitsByPlace[code] { return KeyChord(key: String(digit), modifiers: modifiers) }
        if modifiers.contains(.shift), let shifted = key?.shifted,
           let chord = Self.symbolChord(shifted, modifiers.subtracting(.shift)) {
            return chord
        }
        if let base = key?.base, let chord = Self.symbolChord(base, modifiers) { return chord }
        if let us = Self.usSymbolKeys[code] { return KeyChord(key: String(us), modifiers: modifiers) }
        return nil
    }

    /// The chord that types `symbol` on a US keyboard, plus `modifiers`: `/` is `/`, `?` is `shift+/`. Nil for
    /// the symbols of the US number row (`!` … `)`), which would read as shift plus a digit.
    static func symbolChord(_ symbol: Character, _ modifiers: KeyModifiers) -> KeyChord? {
        if !symbol.isLetter, !symbol.isNumber, KeyChord.unshiftedKeys.contains(symbol) {
            return KeyChord(key: String(symbol), modifiers: modifiers)
        }
        if let base = KeyChord.shiftedSymbols[symbol], !base.isNumber {
            return KeyChord(key: String(base), modifiers: modifiers.union(.shift))
        }
        return nil
    }

    /// The number row of a US (ANSI) keyboard, by virtual key code (`kVK_ANSI_1` … `kVK_ANSI_0`).
    static let usDigitKeys: [Int: Character] = [
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
    ]
    /// The symbol keys of a US (ANSI) keyboard, by virtual key code (`kVK_ANSI_Equal` … `kVK_ANSI_Grave`).
    static let usSymbolKeys: [Int: Character] = [
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",", 44: "/", 47: ".", 50: "`",
    ]

    /// The US layout (ABC): what the app matches with until it has read the current layout.
    public static let us: KeyboardLayout = {
        let letters: [Int: Character] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b", 12: "q", 13: "w",
            14: "e", 15: "r", 16: "y", 17: "t", 31: "o", 32: "u", 34: "i", 35: "p", 37: "l", 38: "j", 40: "k",
            45: "n", 46: "m",
        ]
        var keys: [Int: Key] = [:]
        for (code, letter) in letters { keys[code] = Key(letter, shifted: Character(letter.uppercased())) }
        for (code, key) in usDigitKeys.merging(usSymbolKeys, uniquingKeysWith: { a, _ in a }) {
            keys[code] = Key(key, shifted: KeyChord.shiftOf[key])
        }
        return KeyboardLayout(keys: keys)
    }()
}
