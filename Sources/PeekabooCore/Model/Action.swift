/// Everything a key, gesture or menu item can trigger. The keymap maps chords
/// (or chord sequences) to one action or a list of actions; the app executes them.
///
/// Config ids follow `namespace.verb[:arg]` (see `Action(id:)`), e.g. `nav.next`,
/// `nav.jump:+10`, `zoom.set:2`, `file.move:keep`, `meta.rate:3`, `exec:open -R {path}`.
public enum Action: Hashable, Sendable {
    // nav
    case next, previous, first, last
    /// Relative jump, e.g. +10 / -10.
    case jump(Int)
    // zoom
    case zoomFit, zoomFill, zoomActual, zoomIn, zoomOut, zoomToggle, zoomKeep
    /// Absolute magnification (1 = one image pixel per device pixel).
    case zoomSet(Double)
    // pan
    case pan(Direction), panEdge(Edge), panCenter
    // view
    case fullscreen, fullscreenNative, hud, hudHide, background, help
    case rotateClockwise, rotateCounterClockwise, flipHorizontal, flipVertical
    // file
    case trash, delete, reveal, copyPath, copyName, copyImage, openWithChooser
    /// Move / copy the current file: a slot name, a path (`~` and `./relative` allowed), `ask` or `last`.
    case move(String), copy(String)
    /// Open with an app slot, bundle id, app name or path.
    case openWith(String)
    // meta (stored as Finder tags)
    case rate(Int)
    case label(String)
    case flag(String)
    // app
    case undo, redo, config, reloadConfig, escape, close, quit, open, makeDefault
    /// Shell template with `{path} {dir} {name} {stem} {ext} {index} {count}` placeholders; each becomes a quoted
    /// `${PEEKABOO_*}` reference and the values travel through the environment, never through the shell string.
    case exec(String)
    /// Explicitly unbound.
    case none

    public enum Direction: String, Sendable, CaseIterable { case left, right, up, down }
    public enum Edge: String, Sendable, CaseIterable { case left, right, top, bottom }

    private static let simple: [String: Action] = [
        "nav.next": .next, "nav.prev": .previous, "nav.first": .first, "nav.last": .last,
        "zoom.fit": .zoomFit, "zoom.fill": .zoomFill, "zoom.actual": .zoomActual, "zoom.in": .zoomIn,
        "zoom.out": .zoomOut, "zoom.toggle": .zoomToggle, "zoom.keep": .zoomKeep,
        "pan.left": .pan(.left), "pan.right": .pan(.right), "pan.up": .pan(.up), "pan.down": .pan(.down),
        "pan.center": .panCenter,
        "view.fullscreen": .fullscreen, "view.fullscreen_native": .fullscreenNative, "view.hud": .hud,
        "view.hud_hide": .hudHide, "view.background": .background, "view.help": .help,
        "view.rotate_cw": .rotateClockwise, "view.rotate_ccw": .rotateCounterClockwise,
        "view.flip_h": .flipHorizontal, "view.flip_v": .flipVertical,
        "file.trash": .trash, "file.delete": .delete, "file.reveal": .reveal, "file.copy_path": .copyPath,
        "file.copy_name": .copyName, "file.copy_image": .copyImage, "file.open_with_chooser": .openWithChooser,
        "app.undo": .undo, "app.redo": .redo, "app.config": .config, "app.reload_config": .reloadConfig,
        "app.escape": .escape, "app.close": .close, "app.quit": .quit, "app.open": .open,
        "app.make_default": .makeDefault,
        "none": .none,
    ]

    /// Parse a config id. Returns nil for unknown ids or invalid arguments.
    public init?(id raw: String) {
        let id = raw.trimmingCharacters(in: .whitespaces)
        if let action = Action.simple[id] { self = action; return }
        if id.hasPrefix("exec:") {
            let command = String(id.dropFirst(5))
            guard !command.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            self = .exec(command); return
        }
        guard let colon = id.firstIndex(of: ":") else { return nil }
        let name = String(id[..<colon])
        let arg = String(id[id.index(after: colon)...])
        guard !arg.isEmpty else { return nil }
        switch name {
        case "nav.jump":
            guard let n = Int(arg.hasPrefix("+") ? String(arg.dropFirst()) : arg), n != 0 else { return nil }
            self = .jump(n)
        case "zoom.set":
            guard let f = Double(arg), f > 0, f.isFinite else { return nil }
            self = .zoomSet(f)
        case "pan.edge":
            guard let edge = Edge(rawValue: arg) else { return nil }
            self = .panEdge(edge)
        case "file.move": self = .move(arg)
        case "file.copy": self = .copy(arg)
        case "file.open_with": self = .openWith(arg)
        case "meta.rate":
            guard let n = Int(arg), (0...5).contains(n) else { return nil }
            self = .rate(n)
        case "meta.label":
            guard Action.labels.contains(arg) else { return nil }
            self = .label(arg)
        case "meta.flag":
            guard ["pick", "reject", "none"].contains(arg) else { return nil }
            self = .flag(arg)
        default: return nil
        }
    }

    public static let labels = ["red", "orange", "yellow", "green", "blue", "purple", "gray", "none"]

    /// Canonical config id (round-trips through `init(id:)`).
    public var id: String {
        switch self {
        case .jump(let n): return "nav.jump:\(n > 0 ? "+" : "")\(n)"
        case .zoomSet(let f): return "zoom.set:\(f.formatted(.number.grouping(.never)))"
        case .panEdge(let edge): return "pan.edge:\(edge.rawValue)"
        case .move(let target): return "file.move:\(target)"
        case .copy(let target): return "file.copy:\(target)"
        case .openWith(let app): return "file.open_with:\(app)"
        case .rate(let n): return "meta.rate:\(n)"
        case .label(let color): return "meta.label:\(color)"
        case .flag(let flag): return "meta.flag:\(flag)"
        case .exec(let command): return "exec:\(command)"
        default: return Action.simple.first { $0.value == self }!.key
        }
    }

    /// Every parameterless id, for validation messages and the help overlay.
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

/// A physical key press, independent of AppKit and of the active input method.
///
/// `key` is the *unshifted* character of the key in the current ASCII-capable
/// layout ("a", "1", "/", "=") or a named key ("left", "right", "up", "down",
/// "space", "return", "tab", "esc", "backspace", "forwarddelete", "home", "end",
/// "pageup", "pagedown", "f1"…"f20", "kp0"…"kp9", "kp+", "kp-", "kp*", "kp/",
/// "kp.", "kpenter"). Shift is always a modifier: `?` is `shift+/`, `G` is
/// `shift+g`. Matching on the physical key keeps bindings working while a
/// non-Latin input method (e.g. Korean 2-Set) is active.
public struct KeyChord: Hashable, Sendable {
    public let key: String
    public let modifiers: KeyModifiers

    public init(key: String, modifiers: KeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }
}
