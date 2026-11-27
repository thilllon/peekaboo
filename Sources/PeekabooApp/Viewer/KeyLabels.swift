import AppKit
import PeekabooCore

/// Human-readable chords and action names for menus and the help overlay.
enum KeyLabels {
    static func label(_ chord: KeyChord) -> String {
        var s = ""
        if chord.modifiers.contains(.control) { s += "⌃" }
        if chord.modifiers.contains(.option) { s += "⌥" }
        if chord.modifiers.contains(.shift) { s += "⇧" }
        if chord.modifiers.contains(.command) { s += "⌘" }
        return s + keyLabel(chord.key)
    }

    static func label(_ sequence: [KeyChord]) -> String { sequence.map(label).joined(separator: " ") }

    static func keyLabel(_ key: String) -> String {
        switch key {
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        case "space": return "Space"
        case "return": return "↩"
        case "tab": return "⇥"
        case "esc": return "Esc"
        case "backspace": return "⌫"
        case "forwarddelete": return "⌦"
        case "home": return "Home"
        case "end": return "End"
        case "pageup": return "PgUp"
        case "pagedown": return "PgDn"
        case "kpenter": return "⌤"
        default:
            if key.hasPrefix("kp"), key.count > 2 { return "Num" + key.dropFirst(2) }
            return key.uppercased()
        }
    }

    /// The chord a menu item shows for `action`: prefer ⌘ chords (they behave like menu
    /// shortcuts everywhere), then ⌃, then plain keys; arrows before other plain keys.
    static func menuChord(for action: Action, in keymap: Keymap) -> KeyChord? {
        let singles = keymap.sequences(for: action).filter { $0.count == 1 }.map { $0[0] }
        func rank(_ c: KeyChord) -> (Int, Int, String) {
            let mods = c.modifiers.contains(.command) ? 0 : c.modifiers.contains(.control) ? 1 : 2
            let order = ["right", "left", "up", "down", "space", "return"]
            return (mods, order.firstIndex(of: c.key) ?? order.count, label(c))
        }
        return singles.min { rank($0) < rank($1) }
    }

    private static func function(_ code: Int) -> String { String(utf16CodeUnits: [unichar(code)], count: 1) }

    /// `NSMenuItem` key equivalent for a chord (nil when a menu cannot show it).
    static func menuKeyEquivalent(_ chord: KeyChord) -> (String, NSEvent.ModifierFlags)? {
        var mods: NSEvent.ModifierFlags = []
        if chord.modifiers.contains(.command) { mods.insert(.command) }
        if chord.modifiers.contains(.option) { mods.insert(.option) }
        if chord.modifiers.contains(.control) { mods.insert(.control) }
        if chord.modifiers.contains(.shift) { mods.insert(.shift) }
        let key: String
        switch chord.key {
        case "left": key = function(NSLeftArrowFunctionKey)
        case "right": key = function(NSRightArrowFunctionKey)
        case "up": key = function(NSUpArrowFunctionKey)
        case "down": key = function(NSDownArrowFunctionKey)
        case "space": key = " "
        case "return": key = "\r"
        case "tab": key = "\t"
        case "esc": key = "\u{1b}"
        case "backspace": key = "\u{8}"
        case "forwarddelete": key = function(NSDeleteFunctionKey)
        case "home": key = function(NSHomeFunctionKey)
        case "end": key = function(NSEndFunctionKey)
        case "pageup": key = function(NSPageUpFunctionKey)
        case "pagedown": key = function(NSPageDownFunctionKey)
        default:
            if chord.key.hasPrefix("f"), let n = Int(chord.key.dropFirst()), (1...20).contains(n) {
                key = function(NSF1FunctionKey + n - 1)
            } else if chord.key.count == 1 {
                key = chord.key
            } else {
                return nil
            }
        }
        return (key, mods)
    }

    /// `factor` as a whole percentage ("200" for 2). Any finite factor: `Int(_:)` would trap above Int.max.
    static func percent(_ factor: Double) -> String { String(format: "%.0f", (factor * 100).rounded()) }

    /// Short description of an action for menus and the help overlay.
    static func title(_ action: Action) -> String {
        switch action {
        case .next: return "Next Image"
        case .previous: return "Previous Image"
        case .first: return "First Image"
        case .last: return "Last Image"
        case .jump(let n): return n > 0 ? "Forward \(n)" : "Back \(-n)"
        case .zoomFit: return "Zoom to Fit"
        case .zoomFill: return "Zoom to Fill"
        case .zoomActual: return "Actual Size (100 %)"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .zoomToggle: return "Toggle Fit / 100 %"
        case .zoomKeep: return "Keep Zoom Across Images"
        case .zoomSet(let f): return "Zoom \(percent(f))%"
        case .pan(let d): return "Pan \(d.rawValue.capitalized)"
        case .panEdge(let e): return "Pan to \(e.rawValue.capitalized) Edge"
        case .panCenter: return "Center Image"
        case .fullscreen: return "Full Screen"
        case .fullscreenNative: return "Native Full Screen"
        case .hud: return "Cycle Info Overlay"
        case .hudHide: return "Hide Overlays"
        case .background: return "Cycle Background"
        case .help: return "Keyboard Shortcuts"
        case .rotateClockwise: return "Rotate Right"
        case .rotateCounterClockwise: return "Rotate Left"
        case .flipHorizontal: return "Flip Horizontal"
        case .flipVertical: return "Flip Vertical"
        case .playPause: return "Play / Pause Animation"
        case .frameNext: return "Next Frame"
        case .framePrevious: return "Previous Frame"
        case .picksOnly: return "Show Picks Only"
        case .imageList: return "Show Image List"
        case .trash: return "Move to Trash"
        case .delete: return "Delete Immediately"
        case .reveal: return "Reveal in Finder"
        case .copyPath: return "Copy Path"
        case .copyName: return "Copy Name"
        case .copyImage: return "Copy Image"
        case .openWithChooser: return "Open With…"
        case .move(let t): return "Move to \(t)"
        case .copy(let t): return "Copy to \(t)"
        case .copyPicks(let t):
            switch t {
            case "ask": return "Copy All Picks to…"
            case "last": return "Copy All Picks to the Last Folder"
            default: return "Copy All Picks to \(t)"
            }
        case .openWith(let a): return "Open With \(a)"
        case .rate(let n): return n == 0 ? "Clear Rating" : "Rate " + String(repeating: "★", count: n)
        case .label(let c): return c == "none" ? "Clear Label" : "Label \(c.capitalized)"
        case .flag(let f): return f == "none" ? "Clear Flag" : f.capitalized
        case .undo: return "Undo"
        case .redo: return "Redo"
        case .config: return "Settings…"
        case .configFile: return "Open config.toml"
        case .reloadConfig: return "Reload Config"
        case .escape: return "Close Overlay / Leave Full Screen / Close"
        case .close: return "Close Window"
        case .quit: return "Quit"
        case .open: return "Open…"
        case .makeDefault: return "Make Default Image Viewer"
        case .exec(let cmd): return "Run: \(cmd)"
        case .none: return "Unbound"
        }
    }

    /// Help-overlay section of an action.
    static func section(_ action: Action) -> Int {
        switch action {
        case .next, .previous, .first, .last, .jump: return 0
        case .zoomFit, .zoomFill, .zoomActual, .zoomIn, .zoomOut, .zoomToggle, .zoomKeep, .zoomSet: return 1
        case .pan, .panEdge, .panCenter: return 2
        case .fullscreen, .fullscreenNative, .hud, .hudHide, .background, .help,
             .rotateClockwise, .rotateCounterClockwise, .flipHorizontal, .flipVertical,
             .playPause, .frameNext, .framePrevious, .imageList: return 3
        case .trash, .delete, .reveal, .copyPath, .copyName, .copyImage, .openWithChooser, .move, .copy, .openWith, .exec: return 4
        case .rate, .label, .flag, .picksOnly, .copyPicks: return 5
        default: return 6
        }
    }

    static let sectionNames = ["Navigate", "Zoom", "Pan (zoomed)", "View", "File", "Rate, Label & Pick", "App"]

    /// Help text generated from the live keymap: one line per binding target, grouped by section.
    static func helpSections(_ keymap: Keymap) -> [(title: String, lines: [(keys: String, title: String)])] {
        var byAction: [[Action]: [[KeyChord]]] = [:]
        for context in [KeyContext.normal, .zoomed] {
            for (sequence, actions) in keymap.bindings[context] ?? [:] where actions != [.none] {
                byAction[actions, default: []].append(sequence)
            }
        }
        struct Line { let keys: String; let title: String; let order: String }
        var sections: [[Line]] = Array(repeating: [], count: sectionNames.count)
        for (actions, sequences) in byAction {
            guard let first = actions.first else { continue }
            let labels: [String] = Array(Set(sequences.map { label($0) }))
            let keys = labels.sorted { a, b in a.count != b.count ? a.count < b.count : a < b }
            let title = actions.map { KeyLabels.title($0) }.joined(separator: " + ")
            let order = actions.map { $0.id }.joined()
            sections[section(first)].append(Line(keys: keys.prefix(4).joined(separator: "  "), title: title, order: order))
        }
        var result: [(title: String, lines: [(keys: String, title: String)])] = []
        for (i, lines) in sections.enumerated() where !lines.isEmpty {
            let sorted = lines.sorted { $0.order < $1.order }
            result.append((title: sectionNames[i], lines: sorted.map { (keys: $0.keys, title: $0.title) }))
        }
        return result
    }
}
