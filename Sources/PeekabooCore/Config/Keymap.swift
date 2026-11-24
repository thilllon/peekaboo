/// Where a key press happens; `zoomed` bindings override `normal` while the image is larger than fit.
public enum KeyContext: Hashable, Sendable {
    case normal
    case zoomed
}

public enum KeymapResult: Equatable, Sendable {
    /// Run these actions in order.
    case actions([Action])
    /// The chords so far are a prefix of a longer sequence ("g" of "g g"); wait for more.
    case pending
    case unbound
}

/// Chord sequences → actions, per context.
/// Walking-skeleton defaults; the config workstream adds the TOML loader, the full
/// default map from the research and hot reload, keeping this API.
public struct Keymap: Sendable, Equatable {
    public var bindings: [KeyContext: [[KeyChord]: [Action]]]

    public init(bindings: [KeyContext: [[KeyChord]: [Action]]]) {
        self.bindings = bindings
    }

    public func resolve(_ sequence: [KeyChord], context: KeyContext) -> KeymapResult {
        let contexts: [KeyContext] = context == .zoomed ? [.zoomed, .normal] : [.normal]
        for ctx in contexts {
            if let actions = bindings[ctx]?[sequence] { return .actions(actions) }
        }
        for ctx in contexts {
            if bindings[ctx]?.keys.contains(where: { $0.count > sequence.count && Array($0.prefix(sequence.count)) == sequence }) == true {
                return .pending
            }
        }
        return .unbound
    }

    /// Bound sequences for `action` in the normal context (for menus and the help overlay).
    public func sequences(for action: Action) -> [[KeyChord]] {
        (bindings[.normal] ?? [:]).filter { $0.value == [action] }.keys.sorted { $0.count < $1.count }
    }

    public static let `default`: Keymap = {
        func c(_ key: String, _ mods: KeyModifiers = []) -> [KeyChord] { [KeyChord(key: key, modifiers: mods)] }
        var normal: [[KeyChord]: [Action]] = [:]
        func bind(_ action: Action, _ chords: [KeyChord]...) { for chord in chords { normal[chord] = [action] } }
        bind(.next, c("right"), c("down"), c("space"), c("pagedown"))
        bind(.previous, c("left"), c("up"), c("space", .shift), c("backspace"), c("pageup"))
        bind(.first, c("home"), c("up", .command))
        bind(.last, c("end"), c("down", .command))
        bind(.jump(-10), c("["))
        bind(.jump(10), c("]"))
        bind(.zoomToggle, c("z"))
        bind(.zoomFit, c("0", .command))
        bind(.zoomActual, c("1", .command))
        bind(.zoomSet(2), c("2", .command))
        bind(.zoomIn, c("="), c("=", .shift), c("=", .command))
        bind(.zoomOut, c("-"), c("-", .command))
        bind(.fullscreen, c("f"), c("return"), c("f", [.control, .command]))
        bind(.escape, c("esc"))
        bind(.hud, c("i"))
        bind(.background, c("b"))
        bind(.rotateClockwise, c("r"))
        bind(.rotateCounterClockwise, c("r", .shift))
        bind(.trash, c("backspace", .command), c("forwarddelete"))
        bind(.undo, c("z", .command))
        bind(.redo, c("z", [.command, .shift]))
        bind(.reveal, c("r", [.command, .shift]))
        bind(.copyImage, c("c", .command))
        bind(.copyPath, c("c", [.command, .option]))
        bind(.config, c(",", .command))
        bind(.help, c("/", .shift))
        bind(.close, c("w", .command), c("q"))
        bind(.quit, c("q", .command))
        var zoomed: [[KeyChord]: [Action]] = [:]
        for direction in Action.Direction.allCases { zoomed[c(direction.rawValue)] = [.pan(direction)] }
        return Keymap(bindings: [.normal: normal, .zoomed: zoomed])
    }()
}
