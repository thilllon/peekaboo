/// Everything a key, gesture or menu item can trigger. The keymap maps chords to
/// actions; the app executes them. String ids (`Action(id:)` / `.id`) are the
/// vocabulary of the user config file.
public enum Action: Hashable, Sendable {
    // Navigation
    case next, previous, first, last, random
    case forward(Int), backward(Int)
    // Zoom & view
    case zoomFit, zoomFill, zoomActual, zoomIn, zoomOut, zoomToggle
    case pan(PanDirection)
    case rotateClockwise, rotateCounterClockwise, flipHorizontal, flipVertical
    case toggleFullscreen, toggleHUD, toggleInfo, togglePixelGrid, cycleBackground, toggleHelp, toggleSlideshow
    // Files
    case trash, undo, revealInFinder, copyImage, copyPath
    /// Move / copy the current file to a folder: a path (`~` allowed) or a named slot from the config.
    case moveTo(String), copyTo(String)
    /// Open the current file with an application (name, path or bundle id).
    case openWith(String)
    // Sorting
    case sort(SortKey), reverseSort
    // App
    case closeWindow, quit, reloadConfig, openConfig

    public enum PanDirection: String, Sendable, CaseIterable { case left, right, up, down }
    public enum SortKey: String, Sendable, CaseIterable { case name, modified, size, type }

    private static let simple: [String: Action] = [
        "nav.next": .next, "nav.prev": .previous, "nav.first": .first, "nav.last": .last, "nav.random": .random,
        "zoom.fit": .zoomFit, "zoom.fill": .zoomFill, "zoom.actual": .zoomActual,
        "zoom.in": .zoomIn, "zoom.out": .zoomOut, "zoom.toggle": .zoomToggle,
        "pan.left": .pan(.left), "pan.right": .pan(.right), "pan.up": .pan(.up), "pan.down": .pan(.down),
        "rotate.cw": .rotateClockwise, "rotate.ccw": .rotateCounterClockwise,
        "flip.h": .flipHorizontal, "flip.v": .flipVertical,
        "view.fullscreen": .toggleFullscreen, "view.hud": .toggleHUD, "view.info": .toggleInfo,
        "view.pixel-grid": .togglePixelGrid, "view.background": .cycleBackground, "view.help": .toggleHelp,
        "view.slideshow": .toggleSlideshow,
        "file.trash": .trash, "file.undo": .undo, "file.reveal": .revealInFinder,
        "file.copy-image": .copyImage, "file.copy-path": .copyPath,
        "sort.name": .sort(.name), "sort.modified": .sort(.modified), "sort.size": .sort(.size),
        "sort.type": .sort(.type), "sort.reverse": .reverseSort,
        "window.close": .closeWindow, "app.quit": .quit, "config.reload": .reloadConfig, "config.open": .openConfig,
    ]

    /// Parse a config id such as `"nav.next"`, `"nav.forward:10"` or `"file.move:~/Pictures/Keep"`.
    public init?(id: String) {
        if let action = Action.simple[id] { self = action; return }
        guard let colon = id.firstIndex(of: ":") else { return nil }
        let name = String(id[..<colon])
        let argument = String(id[id.index(after: colon)...])
        guard !argument.isEmpty else { return nil }
        switch name {
        case "nav.forward": guard let n = Int(argument), n > 0 else { return nil }; self = .forward(n)
        case "nav.backward": guard let n = Int(argument), n > 0 else { return nil }; self = .backward(n)
        case "file.move": self = .moveTo(argument)
        case "file.copy": self = .copyTo(argument)
        case "file.open-with": self = .openWith(argument)
        default: return nil
        }
    }

    public var id: String {
        switch self {
        case .forward(let n): return "nav.forward:\(n)"
        case .backward(let n): return "nav.backward:\(n)"
        case .moveTo(let target): return "file.move:\(target)"
        case .copyTo(let target): return "file.copy:\(target)"
        case .openWith(let app): return "file.open-with:\(app)"
        default: return Action.simple.first { $0.value == self }!.key
        }
    }

    /// All parameterless ids, for help screens and validation messages.
    public static var simpleIDs: [String] { simple.keys.sorted() }
}

/// Modifier set of a key chord.
public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let control = KeyModifiers(rawValue: 1 << 2)
    public static let shift = KeyModifiers(rawValue: 1 << 3)
}

/// A key press independent of AppKit. `key` is a normalized name: a lowercase
/// printable character ("a", "1", "/", "[") or a named key ("left", "right", "up",
/// "down", "space", "return", "escape", "delete", "forward-delete", "tab", "home",
/// "end", "page-up", "page-down", "f1"…"f12"). Shift is kept as a modifier for
/// letters and named keys; for other characters the shifted character itself is
/// the key (shift+/ is "?" with no `.shift`).
public struct KeyChord: Hashable, Sendable {
    public let key: String
    public let modifiers: KeyModifiers

    public init(key: String, modifiers: KeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }
}
