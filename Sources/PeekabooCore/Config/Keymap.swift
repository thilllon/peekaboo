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
        if actions == [.none] {
            bindings[context]?[sequence] = nil
        } else {
            bindings[context, default: [:]][sequence] = actions
        }
    }

    /// Sequence-prefix conflicts (`"z z"` while `"z"` is bound): `(longer, shorter)` pairs, sorted.
    /// `zoomed` is checked together with its `normal` fallback.
    public func conflicts() -> [(sequence: [KeyChord], prefix: [KeyChord])] {
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
            normal(.next, "right", "down", "space", "pagedown")
            normal(.previous, "left", "up", "shift+space", "backspace", "pageup")
            normal(.first, "home", "cmd+up")
            normal(.last, "end", "cmd+down")
            normal(.jump(-10), "[")
            normal(.jump(10), "]")
            normal(.zoomToggle, "z")
            normal(.zoomFit, "cmd+0", "cmd+9")
            normal(.zoomActual, "cmd+1")
            normal(.zoomSet(2), "cmd+2")
            normal(.zoomSet(4), "cmd+4")
            normal(.zoomFill, "cmd+shift+0")
            normal(.zoomIn, "=", "+", "cmd+=", "cmd+shift+=")
            normal(.zoomOut, "-", "cmd+-")
            normal(.zoomKeep, "shift+z")
            normal(.fullscreen, "f", "return", "ctrl+cmd+f")
            normal(.escape, "esc")
            normal(.hud, "i")
            normal(.hudHide, "tab")
            normal(.background, "b")
            normal(.rotateClockwise, "r", "cmd+r", ">")
            normal(.rotateCounterClockwise, "shift+r", "cmd+l", "<")
            normal(.flipHorizontal, "|")
            normal(.flipVertical, "_")
            // Animations: YouTube's keys (k plays and pauses, comma and period step a frame).
            normal(.playPause, "k")
            normal(.frameNext, ".")
            normal(.framePrevious, ",")
            normal(.trash, "cmd+backspace", "forwarddelete")
            normal(.undo, "cmd+z")
            normal(.redo, "cmd+shift+z")
            normal(.move("ask"), "m")
            normal(.copy("ask"), "c")
            for n in 1...9 {
                normal(.move("\(n)"), "opt+\(n)")
                normal(.copy("\(n)"), "opt+shift+\(n)")
            }
            normal(.reveal, "cmd+shift+r")
            normal(.copyImage, "cmd+c")
            normal(.copyPath, "opt+cmd+c")
            normal(.openWith("editor"), "e")
            normal(.openWithChooser, "shift+e")
            // Culling (Lightroom): the key sets, shift+key sets and advances.
            var culling: [(String, Action)] = (0...5).map { ("\($0)", Action.rate($0)) }
            culling += [("6", .label("red")), ("7", .label("yellow")), ("8", .label("green")), ("9", .label("blue"))]
            culling += [("p", .flag("pick")), ("x", .flag("reject")), ("u", .flag("none"))]
            for (key, action) in culling {
                bind(.normal, autoAdvance ? [action, .next] : [action], [key])
                bind(.normal, [action, .next], ["shift+\(key)"])
            }
            normal(.config, "cmd+,")
            normal(.help, "?", "cmd+/")
            normal(.close, "cmd+w", "q")
            normal(.quit, "cmd+q")
            normal(.open, "cmd+o")

            for direction in Action.Direction.allCases { zoomed(.pan(direction), direction.rawValue) }
            zoomed(.panEdge(.left), "shift+left")
            zoomed(.panEdge(.right), "shift+right")
            zoomed(.panEdge(.top), "shift+up")
            zoomed(.panEdge(.bottom), "shift+down")
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
        return map
    }
}
