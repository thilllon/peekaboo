import Carbon
import XCTest
@testable import PeekabooCore

/// Key presses on non-US layouts match the US-spelled default keymap (`KeyboardLayout`).
final class KeyboardLayoutTests: XCTestCase {
    private static func layout(_ table: [Int: (Character, Character)]) -> KeyboardLayout {
        KeyboardLayout(keys: table.mapValues { KeyboardLayout.Key($0.0, shifted: $0.1) })
    }

    /// What the keys of macOS's German layout type (unshifted, shifted), by key code.
    private static let germanKeys: [Int: (Character, Character)] = [
        18: ("1", "!"), 19: ("2", "\""), 20: ("3", "§"), 21: ("4", "$"), 23: ("5", "%"), 22: ("6", "&"), 26: ("7", "/"),
        28: ("8", "("), 25: ("9", ")"), 29: ("0", "="), 27: ("ß", "?"), 24: ("´", "`"), 33: ("ü", "Ü"), 30: ("+", "*"),
        42: ("#", "'"), 41: ("ö", "Ö"), 39: ("ä", "Ä"), 43: (",", ";"), 47: (".", ":"), 44: ("-", "_"), 50: ("<", ">"),
        10: ("^", "°"), 6: ("y", "Y"), 16: ("z", "Z"), 12: ("q", "Q"), 15: ("r", "R"),
    ]
    /// The same for macOS's French (AZERTY) layout.
    private static let frenchKeys: [Int: (Character, Character)] = [
        18: ("&", "1"), 19: ("é", "2"), 20: ("\"", "3"), 21: ("'", "4"), 23: ("(", "5"), 22: ("§", "6"), 26: ("è", "7"),
        28: ("!", "8"), 25: ("ç", "9"), 29: ("à", "0"), 27: (")", "°"), 24: ("-", "_"), 33: ("^", "¨"), 30: ("$", "*"),
        42: ("`", "£"), 41: ("m", "M"), 39: ("ù", "%"), 43: (";", "."), 47: (":", "/"), 44: ("=", "+"), 50: ("<", ">"),
        10: ("@", "#"), 6: ("w", "W"), 16: ("y", "Y"), 12: ("a", "A"), 0: ("q", "Q"), 13: ("z", "Z"), 46: (",", "?"),
    ]

    /// What the default keymap does for a press of `code` with `modifiers`; nil when nothing is bound.
    private func actions(_ layout: KeyboardLayout, _ code: Int, _ modifiers: KeyModifiers = []) -> [Action]? {
        guard let chord = layout.chord(keyCode: code, modifiers: modifiers),
              case .actions(let actions) = Keymap.default.resolve([chord], context: .normal) else { return nil }
        return actions
    }

    func testUSKeysMatchAsBefore() {
        let us = KeyboardLayout.us
        XCTAssertEqual(us.keys.count, 47, "26 letters, 10 digits, 11 symbols")
        // The unshifted character with the modifiers as pressed, as the app always matched.
        for (code, key) in us.keys {
            for modifiers: KeyModifiers in [[], .shift, .option, .command, .control, [.command, .shift], [.option, .shift]] {
                XCTAssertEqual(us.chord(keyCode: code, modifiers: modifiers), KeyChord(key: String(key.base!), modifiers: modifiers))
            }
        }
        XCTAssertEqual(actions(us, 44, .shift), [.help])
        XCTAssertEqual(actions(us, 24, .shift), [.zoomIn])
        XCTAssertNil(us.chord(keyCode: 10, modifiers: []), "the ISO key types § on US: nothing to match")
    }

    func testGermanKeysDoWhatTheirLabelsSay() {
        let german = Self.layout(Self.germanKeys)
        XCTAssertEqual(actions(german, 30), [.zoomIn], "the + key")
        XCTAssertEqual(actions(german, 30, .command), [.zoomIn], "⌘+")
        XCTAssertEqual(actions(german, 30, .shift), [.zoomIn], "⇧+ types *, which must not read as ⇧8 (label, next)")
        XCTAssertEqual(actions(german, 44), [.zoomOut], "-")
        XCTAssertEqual(actions(german, 44, .command), [.zoomOut], "⌘-")
        XCTAssertEqual(actions(german, 44, .shift), [.flipVertical], "_")
        XCTAssertEqual(actions(german, 27, .shift), [.help], "? is ⇧ß")
        XCTAssertEqual(actions(german, 50), [.rotateCounterClockwise], "<")
        XCTAssertEqual(actions(german, 50, .shift), [.rotateClockwise], ">")
        // A key without an ASCII character is the US key in its place.
        XCTAssertEqual(actions(german, 33), [.jump(-10)], "ü is [")
        XCTAssertEqual(actions(german, 27), [.zoomOut], "ß is -")
        XCTAssertEqual(actions(german, 24), [.zoomIn], "´ is =")
        // # is a shifted digit on US keyboards (it would rate 3 and advance): the US \ in its place.
        XCTAssertEqual(german.chord(keyCode: 42, modifiers: []), KeyChord(key: "\\"))
        // With shift held, the shifted symbol counts: ⇧, types ; (unbound), not < (rotate).
        XCTAssertEqual(german.chord(keyCode: 43, modifiers: .shift), KeyChord(key: ";"))
        // Letters follow the layout; digits and option keep the physical key.
        XCTAssertEqual(actions(german, 16), [.zoomToggle], "z is the Z key")
        XCTAssertNil(actions(german, 6), "y")
        XCTAssertEqual(actions(german, 29, .shift), [.rate(0), .next], "⇧0 stays shift+0 although it types =")
        XCTAssertEqual(actions(german, 23, .option), [.move("5")], "⌥5 stays opt+5 although it types [")
        XCTAssertEqual(actions(german, 20, .shift), [.rate(3), .next], "⇧3 types §")
    }

    func testFrenchNumberRowIsDigitsAndSymbolsAreTheKeysThatTypeThem() {
        let french = Self.layout(Self.frenchKeys)
        XCTAssertEqual(actions(french, 18), [.rate(1)], "& is the 1 key")
        XCTAssertEqual(actions(french, 18, .shift), [.rate(1), .next])
        XCTAssertEqual(actions(french, 18, .option), [.move("1")])
        XCTAssertEqual(actions(french, 18, [.option, .shift]), [.copy("1")])
        XCTAssertEqual(actions(french, 18, .command), [.zoomActual])
        XCTAssertEqual(actions(french, 19, .command), [.zoomSet(2)], "⌘é is ⌘2")
        XCTAssertEqual(actions(french, 21, .command), [.zoomSet(4)])
        XCTAssertEqual(actions(french, 29, .command), [.zoomFit], "⌘à is ⌘0")
        XCTAssertEqual(actions(french, 29, [.command, .shift]), [.zoomFill])
        XCTAssertEqual(actions(french, 22), [.label("red")], "§ is 6")
        XCTAssertEqual(actions(french, 28), [.label("green")], "! is 8")
        XCTAssertEqual(actions(french, 46, .shift), [.help], "? is ⇧, (it used to rotate, as <)")
        XCTAssertEqual(actions(french, 47, [.command, .shift]), [.help], "⌘/ is ⌘⇧:")
        XCTAssertEqual(actions(french, 46, .command), [.config], "⌘,")
        XCTAssertEqual(actions(french, 44), [.zoomIn], "=")
        XCTAssertEqual(actions(french, 44, .shift), [.zoomIn], "+")
        XCTAssertEqual(actions(french, 24), [.zoomOut], "-")
        XCTAssertEqual(actions(french, 24, .shift), [.flipVertical], "_")
        XCTAssertEqual(actions(french, 50, .shift), [.rotateClockwise], ">")
        // $ and ^ are shifted digits on US keyboards ($ would rate 4 and advance): the US keys in their place.
        XCTAssertEqual(actions(french, 30), [.jump(10)], "$ is ]")
        XCTAssertEqual(actions(french, 33), [.jump(-10)], "^ is [")
        XCTAssertNil(actions(french, 30, .shift), "⇧$ types *, which must not read as ⇧8")
        XCTAssertEqual(actions(french, 13), [.zoomToggle], "z")
        XCTAssertEqual(actions(french, 0), [.close], "q")
    }

    func testNumberRowStandsForDigitsOnlyWhereALayoutCannotTypeThem() {
        // Lithuanian types its digits only with option: the number row is the digits in their US places.
        let lithuanian = Self.layout([18: ("ą", "Ą"), 19: ("č", "Č"), 25: ("„", "("), 29: ("“", ")"), 24: ("ž", "Ž")])
        XCTAssertEqual(actions(lithuanian, 18), [.rate(1)], "ą is 1")
        XCTAssertEqual(actions(lithuanian, 19, .command), [.zoomSet(2)], "⌘č is ⌘2")
        XCTAssertEqual(actions(lithuanian, 25, .shift), [.label("blue"), .next], "⇧„ types (, and is ⇧9")
        XCTAssertEqual(actions(lithuanian, 24), [.zoomIn], "ž is =")
        // Dvorak-Left types [ ] / on the number row and its digits elsewhere: those keys stay symbols.
        let dvorakLeft = Self.layout([18: ("[", "{"), 19: ("]", "}"), 20: ("/", "?"), 24: ("1", "!"), 27: ("2", "@"),
                                      29: ("3", "#")])
        XCTAssertEqual(actions(dvorakLeft, 18), [.jump(-10)])
        XCTAssertEqual(actions(dvorakLeft, 19), [.jump(10)])
        XCTAssertEqual(actions(dvorakLeft, 20, .shift), [.help])
        XCTAssertEqual(actions(dvorakLeft, 24), [.rate(1)])
    }

    func testTheRebindingTheDocsSuggestForMissingKeysIsValid() throws {
        let keymap = try AppConfig(toml: """
        [keys]
        "shift+pageup" = "nav.jump:-10"
        "shift+pagedown" = "nav.jump:+10"
        "h" = "view.flip_h"
        """).keymap
        XCTAssertEqual(keymap.resolve(KeyChord.sequence(spec: "shift+pagedown")!, context: .normal), .actions([.jump(10)]))
        XCTAssertEqual(keymap.resolve([KeyChord(key: "h")], context: .normal), .actions([.flipHorizontal]))
        XCTAssertTrue(keymap.conflicts().isEmpty)
    }

    // MARK: The layouts installed with macOS

    private struct Installed {
        let layout: KeyboardLayout
        /// What each key types unshifted and with shift, any character.
        let typed: [Int: (String?, String?)]
    }

    /// An installed layout read the way the app reads the current one (`KeyLayout.rebuild`).
    private static func installed(_ id: String) -> Installed? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first,
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var keys: [Int: KeyboardLayout.Key] = [:]
        var typed: [Int: (String?, String?)] = [:]
        data.withUnsafeBytes { buffer in
            guard let uchr = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            func character(_ code: Int, _ state: UInt32) -> String? {
                var dead: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(uchr, UInt16(code), UInt16(kUCKeyActionDown), state, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, 4, &length, &chars)
                guard status == noErr, length == 1 else { return nil }
                return String(utf16CodeUnits: chars, count: 1)
            }
            let shift = UInt32(shiftKey >> 8) & 0xFF
            for code in 0..<128 {
                let base = character(code, 0), shifted = character(code, shift)
                typed[code] = (base, shifted)
                let key = KeyboardLayout.Key(base?.first, shifted: shifted?.first)
                if key.base != nil || key.shifted != nil { keys[code] = key }
            }
        }
        return Installed(layout: KeyboardLayout(keys: keys), typed: typed)
    }

    /// The typing keys (letters, digits, symbols, the ISO key), without return, tab and space.
    private static let typingKeys = (0...50).filter { ![36, 48, 49].contains($0) }

    private static let layouts = [
        "ABC", "US", "British", "Dvorak", "Dvorak-Left", "Colemak", "German", "SwissGerman", "Austrian", "French",
        "Belgian", "Swedish-Pro", "Norwegian", "Danish", "Finnish", "Spanish-ISO", "Italian", "Italian-Pro",
        "Portuguese", "Czech-QWERTY", "PolishPro", "Dutch", "Lithuanian", "Vietnamese",
    ]

    func testInstalledLayoutsReachTheDefaultsAndNeverMisfire() throws {
        let found = Self.layouts.compactMap { name in Self.installed("com.apple.keylayout." + name).map { (name, $0) } }
        guard found.contains(where: { $0.0 == "German" }), found.contains(where: { $0.0 == "French" }) else {
            throw XCTSkip("keyboard layouts unavailable (found \(found.map(\.0)))")
        }
        // The tables of the tests above are what macOS's layouts type.
        for (name, table) in [("German", Self.germanKeys), ("French", Self.frenchKeys)] {
            let real = try XCTUnwrap(found.first { $0.0 == name }?.1.layout)
            for (code, key) in table {
                XCTAssertEqual(real.keys[code] ?? KeyboardLayout.Key(nil, shifted: nil), KeyboardLayout.Key(key.0, shifted: key.1),
                               "\(name) key \(code)")
            }
        }
        // US-like layouts match exactly as before: the unshifted character plus the modifiers as pressed.
        for (name, installed) in found where ["ABC", "US", "British", "Dvorak", "Colemak", "Dutch"].contains(name) {
            for code in Self.typingKeys {
                guard let base = installed.typed[code]?.0, let scalar = base.unicodeScalars.first,
                      scalar.isASCII, scalar.value > 0x20 else { continue }
                for modifiers: KeyModifiers in [[], .shift, .option, .command] {
                    XCTAssertEqual(installed.layout.chord(keyCode: code, modifiers: modifiers),
                                   KeyChord(key: base.lowercased(), modifiers: modifiers), "\(name) key \(code)")
                }
            }
        }
        let harmless: (Action) -> Bool = { action in
            switch action {
            case .jump, .zoomIn, .zoomOut, .zoomSet, .zoomFit, .zoomFill, .zoomActual, .help, .config, .rotateClockwise,
                 .rotateCounterClockwise, .flipHorizontal, .flipVertical, .frameNext, .framePrevious:
                return true
            default:
                return false
            }
        }
        let wanted: [[Action]] = [
            [.help], [.zoomIn], [.zoomOut], [.zoomActual], [.zoomFit], [.zoomFill], [.zoomSet(2)], [.zoomSet(4)],
            [.rate(1)], [.rate(1), .next], [.label("red")], [.move("1")], [.copy("1")], [.config], [.flipVertical],
            [.rotateClockwise], [.rotateCounterClockwise], [.playPause], [.frameNext], [.framePrevious],
        ]
        for (name, installed) in found {
            var reached = Set<[Action]>()
            for code in Self.typingKeys {
                for modifiers: KeyModifiers in [[], .shift, .option, [.option, .shift], .command, [.command, .shift]] {
                    guard let chord = installed.layout.chord(keyCode: code, modifiers: modifiers),
                          case .actions(let actions) = Keymap.default.resolve([chord], context: .normal) else { continue }
                    reached.insert(actions)
                    // A symbol key (one that is not a letter or digit key) only ever zooms, jumps or turns the view:
                    // never rates, labels, moves or closes (the risk of reading `*` as shift+8).
                    let isLetterOrDigitKey = chord.key.count == 1 && (chord.key.first!.isLetter || chord.key.first!.isNumber)
                    if !isLetterOrDigitKey {
                        XCTAssertTrue(actions.allSatisfy(harmless),
                                      "\(name) key \(code) (\(installed.typed[code].map { "\($0.0 ?? "-") \($0.1 ?? "-")" } ?? "")) "
                                      + "with \(modifiers.rawValue) -> \(actions)")
                    }
                }
            }
            for actions in wanted {
                XCTAssertTrue(reached.contains(actions), "\(name): no key for \(actions)")
            }
        }
    }

    func testMatchingAKeyIsCheap() throws {
        guard let german = Self.installed("com.apple.keylayout.German")?.layout else { throw XCTSkip("no German layout") }
        let started = Trace.now()
        var matched = 0
        for _ in 0..<1000 {
            for code in Self.typingKeys where german.chord(keyCode: code, modifiers: .shift) != nil { matched += 1 }
        }
        let perKey = Trace.ms(since: started) * 1000 / Double(1000 * Self.typingKeys.count)
        print("KeyboardLayout.chord: \(String(format: "%.3f", perKey)) µs per key press")
        XCTAssertGreaterThan(matched, 0)
        XCTAssertLessThan(perKey, 10)
    }
}
