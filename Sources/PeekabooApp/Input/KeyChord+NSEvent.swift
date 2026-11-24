import AppKit
import Carbon.HIToolbox
import PeekabooCore

extension KeyChord {
    /// The chord of a key event. Named keys go by key code; printable keys through the current
    /// ASCII-capable layout (US/ABC under Korean 2-Set), so bindings work whatever the input method, and
    /// in the US spelling of `KeyChord(spec:)` (`?` is `shift+/`, `G` is `shift+g`) on any layout: on a
    /// German keyboard the `+` key is `+` and ⇧ß is `?` (see `KeyboardLayout`).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: KeyModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        let code = Int(event.keyCode)
        if let name = KeyChord.namedKeys[code] {
            self.init(key: name, modifiers: modifiers)
        } else if let chord = KeyLayout.shared.layout.chord(keyCode: code, modifiers: modifiers) {
            self = chord
        } else {
            return nil
        }
    }

    /// Named keys by virtual key code (HIToolbox Events.h).
    static let namedKeys: [Int: String] = [
        kVK_Return: "return", kVK_Tab: "tab", kVK_Space: "space", kVK_Delete: "backspace", kVK_Escape: "esc",
        kVK_Home: "home", kVK_PageUp: "pageup", kVK_ForwardDelete: "forwarddelete", kVK_End: "end",
        kVK_PageDown: "pagedown", kVK_LeftArrow: "left", kVK_RightArrow: "right", kVK_DownArrow: "down",
        kVK_UpArrow: "up", kVK_ANSI_KeypadEnter: "kpenter",
        kVK_F1: "f1", kVK_F2: "f2", kVK_F3: "f3", kVK_F4: "f4", kVK_F5: "f5", kVK_F6: "f6",
        kVK_F7: "f7", kVK_F8: "f8", kVK_F9: "f9", kVK_F10: "f10", kVK_F11: "f11", kVK_F12: "f12",
        kVK_F13: "f13", kVK_F14: "f14", kVK_F15: "f15", kVK_F16: "f16", kVK_F17: "f17", kVK_F18: "f18",
        kVK_F19: "f19", kVK_F20: "f20",
        kVK_ANSI_Keypad0: "kp0", kVK_ANSI_Keypad1: "kp1", kVK_ANSI_Keypad2: "kp2", kVK_ANSI_Keypad3: "kp3",
        kVK_ANSI_Keypad4: "kp4", kVK_ANSI_Keypad5: "kp5", kVK_ANSI_Keypad6: "kp6", kVK_ANSI_Keypad7: "kp7",
        kVK_ANSI_Keypad8: "kp8", kVK_ANSI_Keypad9: "kp9", kVK_ANSI_KeypadPlus: "kp+", kVK_ANSI_KeypadMinus: "kp-",
        kVK_ANSI_KeypadMultiply: "kp*", kVK_ANSI_KeypadDivide: "kp/", kVK_ANSI_KeypadDecimal: "kp.",
    ]
}

/// What the keys of the current ASCII-capable keyboard layout type, unshifted and with shift.
final class KeyLayout {
    static let shared = KeyLayout()
    /// US until the current layout has been read.
    private(set) var layout = KeyboardLayout.us

    private init() {
        rebuild()
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
    }

    private func rebuild() {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var keys: [Int: KeyboardLayout.Key] = [:]
        data.withUnsafeBytes { buffer in
            guard let uchr = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            /// What `code` types with the Carbon modifier state `state`; a dead key types its accent.
            func character(_ code: Int, _ state: UInt32) -> Character? {
                var dead: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(uchr, UInt16(code), UInt16(kUCKeyActionDown), state, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, 4, &length, &chars)
                guard status == noErr, length == 1, let scalar = Unicode.Scalar(chars[0]) else { return nil }
                return Character(scalar)
            }
            let shift = UInt32(shiftKey >> 8) & 0xFF
            for code in 0..<128 {
                let key = KeyboardLayout.Key(character(code, 0), shifted: character(code, shift))
                if key.base != nil || key.shifted != nil { keys[code] = key }
            }
        }
        layout = KeyboardLayout(keys: keys)
    }
}
