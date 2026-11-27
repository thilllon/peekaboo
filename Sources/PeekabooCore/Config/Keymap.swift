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
///
/// `zoomed` falls back to `normal`. A stored binding of exactly `[.none]` resolves to `.unbound`
/// and hides the fallback (`bind(_:to:context:)` with `.none` removes the binding instead).
public struct Keymap: Sendable, Equatable {
    public var bindings: [KeyContext: [[KeyChord]: [Action]]]

    public init(bindings: [KeyContext: [[KeyChord]: [Action]]]) {
        self.bindings = bindings
    }

    public func resolve(_ sequence: [KeyChord], context: KeyContext) -> KeymapResult {
        let contexts: [KeyContext] = context == .zoomed ? [.zoomed, .normal] : [.normal]
        for ctx in contexts {
            if let actions = bindings[ctx]?[sequence] {
                return actions == [.none] ? .unbound : .actions(actions)
            }
        }
        for ctx in contexts {
            if bindings[ctx]?.contains(where: { $0.key.count > sequence.count && $0.value != [.none]
                && $0.key.starts(with: sequence) }) == true {
                return .pending
            }
        }
        return .unbound
    }

    /// Bound sequences for `action` in the normal context (for menus and the help overlay).
    public func sequences(for action: Action) -> [[KeyChord]] {
        (bindings[.normal] ?? [:]).filter { $0.value == [action] }.keys.sorted {
            $0.count != $1.count ? $0.count < $1.count : KeyChord.spec(of: $0) < KeyChord.spec(of: $1)
        }
    }

    /// Bind a sequence; `[.none]` removes the binding from that context (`zoomed` then falls back to `normal`).
    public mutating func bind(_ sequence: [KeyChord], to actions: [Action], context: KeyContext = .normal) {
        if actions.count == 1, actions[0] == .none {
            bindings[context]?[sequence] = nil
        } else {
            bindings[context, default: [:]][sequence] = actions
        }
    }

    /// Sequence-prefix conflicts (`"z z"` while `"z"` is bound): `(longer, shorter)` pairs, sorted.
    /// `zoomed` is checked together with its `normal` fallback.
    public func conflicts() -> [(sequence: [KeyChord], prefix: [KeyChord])] {
        // Only a sequence of two chords or more can conflict (most keymaps have none: then no sets are built).
        guard bindings.values.contains(where: { $0.keys.contains { $0.count > 1 } }) else { return [] }
        var found: [(sequence: [KeyChord], prefix: [KeyChord])] = []
        func check(_ keys: Set<[KeyChord]>, against shorter: Set<[KeyChord]>) {
            for sequence in keys where sequence.count > 1 {
                for n in 1..<sequence.count where shorter.contains(Array(sequence.prefix(n))) {
                    found.append((sequence, Array(sequence.prefix(n))))
                }
            }
        }
        let normal = bindings[.normal] ?? [:]
        let zoomed = bindings[.zoomed] ?? [:]
        let normalKeys = Set(normal.filter { $0.value != [.none] }.keys)
        check(normalKeys, against: normalKeys)
        var merged = normalKeys
        for (sequence, actions) in zoomed {
            if actions == [.none] { merged.remove(sequence) } else { merged.insert(sequence) }
        }
        let zoomedKeys = Set(zoomed.filter { $0.value != [.none] }.keys)
        // Only report what the zoomed table itself introduces (normal-only conflicts are reported above).
        for sequence in merged where sequence.count > 1 {
            for n in 1..<sequence.count where merged.contains(Array(sequence.prefix(n))) {
                let prefix = Array(sequence.prefix(n))
                if zoomedKeys.contains(sequence) || zoomedKeys.contains(prefix) { found.append((sequence, prefix)) }
            }
        }
        var seen = Set<String>()
        return found.filter { seen.insert(KeyChord.spec(of: $0.sequence) + "|" + KeyChord.spec(of: $0.prefix)).inserted }
            .sorted { KeyChord.spec(of: $0.sequence) < KeyChord.spec(of: $1.sequence) }
    }

    // MARK: Built-in layers

    /// No bindings at all (`keymap.defaults = false`).
    public static let empty = Keymap(bindings: [.normal: [:], .zoomed: [:]])

    /// The default layer (docs/CONFIG.md): macOS conventions, then the viewer consensus, then Lightroom culling.
    public static let `default` = Keymap.build(defaults: true, vim: false, autoAdvance: false)

    /// One line of the default keymap: `actions` on each of `keys` in `context`. config.toml lists it as
    /// `"action" = key(s)` (one action) or one `"key" = [actions]` line per key (an action list).
    public struct DefaultBinding: Equatable, Sendable {
        public let context: KeyContext
        public let actions: [Action]
        public let keys: [String]
        /// The config file generation that added it (`ConfigFile.generation`; 1: the keymap of the first full file). A
        /// full file of an older generation gets it once, on each of its keys that the file does not use.
        public let generation: Int

        init(_ context: KeyContext, _ actions: [Action], _ keys: [String], generation: Int = 1) {
            self.context = context
            self.actions = actions
            self.keys = keys
            self.generation = generation
        }

        /// The same binding, added by `generation` (a new action's default key: `n(.newAction, "x").since(2)`).
        func since(_ generation: Int) -> DefaultBinding { DefaultBinding(context, actions, keys, generation: generation) }

        /// Its key sequences (the tables are static and covered by tests).
        var sequences: [[KeyChord]] { keys.map { try! KeyChord.parseSequence($0) } }
    }

    /// A heading of config.toml's keymap and the default bindings below it (all of one context).
    public struct DefaultGroup: Sendable {
        public let title: String
        public let bindings: [DefaultBinding]
    }

    /// The default layer in config.toml's order and groups. A default binding added later (a new action's key) gets the
    /// next file generation (`.since(n)`), so that full files written before get it appended (docs/CONFIG.md › Later
    /// versions); `ConfigFileTests.testGenerationOneIsFrozen` fails for one that does not.
    public static let defaultGroups: [DefaultGroup] = {
        func n(_ action: Action, _ keys: String...) -> DefaultBinding { DefaultBinding(.normal, [action], keys) }
        func z(_ action: Action, _ keys: String...) -> DefaultBinding { DefaultBinding(.zoomed, [action], keys) }
        // Culling (Lightroom): the key rates, labels or flags; shift+key does that and goes to the next image.
        let culling: [(key: String, action: Action)] = (0...5).map { ("\($0)", Action.rate($0)) }
            + [("6", .label("red")), ("7", .label("yellow")), ("8", .label("green")), ("9", .label("blue"))]
            + [("p", .flag("pick")), ("x", .flag("reject")), ("u", .flag("none"))]
        return [
            DefaultGroup(title: "Navigate", bindings: [
                n(.next, "right", "down", "space", "pagedown"),
                n(.previous, "left", "up", "shift+space", "backspace", "pageup"),
                n(.first, "home", "cmd+up"),
                n(.last, "end", "cmd+down"),
                n(.jump(-10), "["),
                n(.jump(10), "]"),
            ]),
            DefaultGroup(title: "Zoom", bindings: [
                n(.zoomToggle, "z"),
                n(.zoomFit, "cmd+0", "cmd+9"),
                n(.zoomActual, "cmd+1"),
                n(.zoomSet(2), "cmd+2"),
                n(.zoomSet(4), "cmd+4"),
                n(.zoomFill, "cmd+shift+0"),
                n(.zoomIn, "=", "+", "cmd+=", "cmd+shift+="),
                n(.zoomOut, "-", "cmd+-"),
                n(.zoomKeep, "shift+z"),
            ]),
            DefaultGroup(title: "View", bindings: [
                n(.fullscreen, "f", "return", "ctrl+cmd+f"),
                n(.escape, "esc"),
                n(.hud, "i"),
                n(.hudHide, "tab"),
                n(.background, "b"),
                n(.rotateClockwise, "r", "cmd+r", ">"),
                n(.rotateCounterClockwise, "shift+r", "cmd+l", "<"),
                n(.flipHorizontal, "|"),
                n(.flipVertical, "_"),
            ]),
            // YouTube's keys: k plays and pauses, comma and period step a frame.
            DefaultGroup(title: "Animations", bindings: [
                n(.playPause, "k"),
                n(.frameNext, "."),
                n(.framePrevious, ","),
            ]),
            DefaultGroup(title: "Files", bindings: [
                n(.trash, "cmd+backspace", "forwarddelete"),
                n(.undo, "cmd+z"),
                n(.redo, "cmd+shift+z"),
                n(.move("ask"), "m"),
                n(.copy("ask"), "c"),
                n(.reveal, "cmd+shift+r"),
                n(.copyImage, "cmd+c"),
                n(.copyPath, "opt+cmd+c"),
                n(.openWith("editor"), "e"),
                n(.openWithChooser, "shift+e"),
            ]),
            DefaultGroup(title: "Move to (opt+N) and copy to (opt+shift+N) the slots named 1 to 9",
                         bindings: (1...9).flatMap { [n(.move("\($0)"), "opt+\($0)"), n(.copy("\($0)"), "opt+shift+\($0)")] }),
            DefaultGroup(title: "Rate, label and flag (Lightroom culling)",
                         bindings: culling.map { n($0.action, $0.key) }),
            DefaultGroup(title: "The same, then go to the next image",
                         bindings: culling.map { DefaultBinding(.normal, [$0.action, .next], ["shift+" + $0.key]) }),
            // Then the picks alone: browse only them, copy them all to a folder.
            DefaultGroup(title: "Picks", bindings: [
                n(.picksOnly, "v"),
                n(.copyPicks("ask"), "shift+c"),
            ]),
            DefaultGroup(title: "App", bindings: [
                n(.config, "cmd+,"),
                n(.help, "?", "cmd+/"),
                n(.close, "cmd+w", "q"),
                n(.quit, "cmd+q"),
                n(.open, "cmd+o"),
            ]),
            DefaultGroup(title: "Pan", bindings: Action.Direction.allCases.map { z(.pan($0), $0.rawValue) } + [
                z(.panEdge(.left), "shift+left"),
                z(.panEdge(.right), "shift+right"),
                z(.panEdge(.top), "shift+up"),
                z(.panEdge(.bottom), "shift+down"),
            ]),
        ]
    }()

    /// Every default binding, in config.toml's order.
    public static let defaultBindings: [DefaultBinding] = defaultGroups.flatMap(\.bindings)

    /// Build the built-in part of a keymap: the default layer, the optional vim layer on top, and
    /// `rating.auto_advance` (plain rating/label/flag keys also advance).
    public static func build(defaults: Bool, vim: Bool, autoAdvance: Bool) -> Keymap {
        var map = Keymap.empty
        func bind(_ context: KeyContext, _ actions: [Action], _ specs: [String]) {
            for spec in specs {
                // The tables below are static and covered by tests.
                map.bindings[context, default: [:]][try! KeyChord.parseSequence(spec)] = actions
            }
        }
        func normal(_ action: Action, _ specs: String...) { bind(.normal, [action], specs) }
        func zoomed(_ action: Action, _ specs: String...) { bind(.zoomed, [action], specs) }

        if defaults {
            for binding in defaultBindings { bind(binding.context, binding.actions, binding.keys) }
        }
        if vim {
            normal(.next, "l", "j", "n")
            normal(.previous, "h", "k", "shift+n")
            normal(.first, "g g")
            normal(.last, "shift+g")
            normal(.zoomFit, "w")
            normal(.zoomActual, "shift+w")
            normal(.trash, "d d")
            normal(.copyImage, "y y")
            normal(.copyPath, "y p")
            normal(.panCenter, "shift+m")
            zoomed(.pan(.left), "h")
            zoomed(.pan(.down), "j")
            zoomed(.pan(.up), "k")
            zoomed(.pan(.right), "l")
            zoomed(.panEdge(.left), "shift+h")
            zoomed(.panEdge(.bottom), "shift+j")
            zoomed(.panEdge(.top), "shift+k")
            zoomed(.panEdge(.right), "shift+l")
        }
        if autoAdvance { map.applyAutoAdvance() }
        return map
    }

    /// The keymap of a config.toml that lists the default keymap, as Peekaboo writes it (`[keymap] defaults = false`):
    /// the vim layer, when on, under the file's bindings (a key the file binds keeps the file's action: `k` stays
    /// play / pause), and `rating.auto_advance` applied to the file's plain rating, label and flag keys.
    public static func written(vim: Bool, autoAdvance: Bool) -> Keymap {
        if !vim, !autoAdvance { return .default }
        var map = build(defaults: false, vim: vim, autoAdvance: false)
        for binding in defaultBindings {
            for sequence in binding.sequences { map.bind(sequence, to: binding.actions, context: binding.context) }
        }
        if autoAdvance { map.applyAutoAdvance() }
        return map
    }

    /// `rating.auto_advance`: every plain rating, label and flag key also goes to the next image. Applied to the default
    /// layer (`build`), or, with `[keymap] defaults = false`, to the file's bindings.
    mutating func applyAutoAdvance() {
        for (sequence, actions) in bindings[.normal] ?? [:] where Self.advancesAutomatically(sequence, actions) {
            bindings[.normal]?[sequence] = actions + [.next]
        }
    }

    /// `0`…`9`, `p`, `x` or `u` without a modifier, running one `meta.rate`, `meta.label` or `meta.flag` action.
    static func advancesAutomatically(_ sequence: [KeyChord], _ actions: [Action]) -> Bool {
        guard sequence.count == 1, sequence[0].modifiers.isEmpty, cullingKeys.contains(sequence[0].key),
              actions.count == 1 else { return false }
        switch actions[0] {
        case .rate, .label, .flag: return true
        default: return false
        }
    }

    private static let cullingKeys: Set<String> = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "p", "x", "u"]

    /// No binding of either context uses `sequence`, starts with it or is the start of it: a default binding that a
    /// later version adds takes only such keys.
    func leavesFree(_ sequence: [KeyChord]) -> Bool {
        for table in bindings.values {
            for bound in table.keys where bound.starts(with: sequence) || sequence.starts(with: bound) { return false }
        }
        return true
    }
}
