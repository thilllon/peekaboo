import AppKit
import Carbon.HIToolbox
import PeekabooCore

extension KeyChord {
    /// The physical-key chord of a key event. Printable keys are translated through the current
    /// ASCII-capable layout (US/ABC under Korean 2-Set), so bindings work whatever the input method.
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
        } else if let character = KeyLayout.shared.character(for: code) {
            self.init(key: character, modifiers: modifiers)
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
        kVK_ANSI_Keypad0: "kp0", kVK_ANSI_Keypad1: "kp1", kVK_ANSI_Keypad2: "kp2", kVK_ANSI_Keypad3: "kp3",
        kVK_ANSI_Keypad4: "kp4", kVK_ANSI_Keypad5: "kp5", kVK_ANSI_Keypad6: "kp6", kVK_ANSI_Keypad7: "kp7",
        kVK_ANSI_Keypad8: "kp8", kVK_ANSI_Keypad9: "kp9", kVK_ANSI_KeypadPlus: "kp+", kVK_ANSI_KeypadMinus: "kp-",
        kVK_ANSI_KeypadMultiply: "kp*", kVK_ANSI_KeypadDivide: "kp/", kVK_ANSI_KeypadDecimal: "kp.",
    ]
}

/// keyCode → unshifted ASCII character of the current ASCII-capable keyboard layout.
final class KeyLayout {
    static let shared = KeyLayout()
    private var table: [Int: String] = [:]

    private init() {
        rebuild()
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
    }

    func character(for code: Int) -> String? { table[code] }

    private func rebuild() {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var result: [Int: String] = [:]
        data.withUnsafeBytes { buffer in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for code in 0..<128 {
                var dead: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, 4, &length, &chars)
                if status == noErr, length == 1, let scalar = Unicode.Scalar(chars[0]), scalar.isASCII, scalar.value > 0x20 {
                    result[code] = String(Character(scalar)).lowercased()
                }
            }
        }
        table = result
    }
}
