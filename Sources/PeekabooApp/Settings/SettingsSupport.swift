import AppKit
import PeekabooCore

/// What the Settings panes share: the config store they read and the write path.
///
/// Controls show what the applied file says (`ConfigStore.storedValue`, else the built-in default) and write through
/// `ConfigStore.edit` — a minimal edit of config.toml on the store's queue, applied by the same reload as an edit in a
/// text editor. Every key is addressed by name (`[table] key`), as config.toml spells it.
final class SettingsModel {
    let store: ConfigStore
    /// The last refused edit (shown in the window's banner until the file loads again or an edit succeeds).
    private(set) var editError: String?
    /// Main thread, after an edit was refused or succeeded (the banner shows `problem`).
    var onProblemChanged: (() -> Void)?

    init(store: ConfigStore) { self.store = store }

    var config: AppConfig { store.config }

    /// What the banner shows: the file's own error (edits wait until it is fixed), else a refused edit.
    var problem: String? {
        if let error = store.lastError { return "config.toml has a problem, so changes here wait until it is fixed:\n\(error)" }
        return editError.map { "This change was not saved:\n\($0)" }
    }

    /// The file loaded (an edit here or a save elsewhere): a refusal from before no longer applies.
    func fileLoaded() { editError = nil }

    /// The file's value of `key`, nil when it does not set it.
    func value(_ key: String, in table: String) -> TOMLValue? { store.storedValue(key, in: table) }

    func bool(_ key: String, in table: String, default fallback: Bool) -> Bool {
        if case .bool(let value)? = value(key, in: table) { return value }
        return fallback
    }

    /// Write `value` unless the file does not set the key and `value` is its default (nothing would change).
    func set(_ key: String, in table: String, to value: TOMLValue, default fallback: TOMLValue? = nil) {
        if let fallback, self.value(key, in: table) == nil, "\(value)" == "\(fallback)" { return }
        edit { try $0.set(key, in: table, to: value) }
    }

    func remove(_ key: String, in table: String) {
        edit { try $0.remove(key, in: table) }
    }

    /// One change of the file (several entries at once when needed); `done` runs after it is applied.
    func edit(_ change: @escaping (inout ConfigEditor) throws -> Void, done: (() -> Void)? = nil) {
        store.edit(change) { [weak self] error in
            guard let self else { return }
            self.editError = error.map { "\($0)" }
            self.onProblemChanged?()
            if error == nil { done?() }
        }
    }
}

/// One pane of the Settings window: built the first time it is shown, refreshed after every load of the config.
protocol SettingsPane: AnyObject {
    var view: NSView { get }
    /// Show the applied configuration (a field being edited keeps what the user typed).
    func refresh()
}

/// A control's action as a closure (`NSControl` target-action needs an object).
final class ControlAction: NSObject {
    private let run: (NSControl) -> Void
    init(_ run: @escaping (NSControl) -> Void) { self.run = run }
    @objc func fire(_ sender: NSControl) { run(sender) }
}

/// Writes a text field's value 0.6 s after the last keystroke (unless `live` is false), and at once when editing ends
/// (Return, Tab, a click elsewhere). `commit` returns false for a value it rejects: the field turns red until it is
/// valid.
final class FieldCommitter: NSObject, NSTextFieldDelegate {
    private let commit: (String) -> Bool
    private let live: Bool
    private var pending: DispatchWorkItem?

    init(live: Bool = true, _ commit: @escaping (String) -> Bool) {
        self.live = live
        self.commit = commit
    }

    func controlTextDidChange(_ notification: Notification) {
        guard live, let field = notification.object as? NSTextField else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self, weak field] in
            guard let self, let field else { return }
            self.run(field)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        run(field)
    }

    private func run(_ field: NSTextField) {
        pending?.cancel()
        pending = nil
        field.textColor = commit(field.stringValue) ? .labelColor : .systemRed
    }
}

/// Builders for the panes' label–control layout (a two-column grid like System Settings), and their bindings to
/// config keys. Each bound control registers how it shows the applied value; `refresh()` runs them all.
class SettingsForm: NSObject {
    let model: SettingsModel
    let grid = NSGridView()
    private var refreshers: [() -> Void] = []
    /// Targets and delegates the controls reference weakly.
    private var keepAlive: [AnyObject] = []

    init(model: SettingsModel) {
        self.model = model
        super.init()
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false
    }

    func refresh() { refreshers.forEach { $0() } }

    func onRefresh(_ refresher: @escaping () -> Void) { refreshers.append(refresher) }

    func retain(_ object: AnyObject) { keepAlive.append(object) }

    /// The grid in a view with the standard margins.
    func makeView(width: CGFloat = 600) -> NSView {
        let view = NSView()
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 30),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -30),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            view.widthAnchor.constraint(equalToConstant: width),
        ])
        if grid.numberOfColumns > 0 { grid.column(at: 0).xPlacement = .trailing }
        return view
    }

    // MARK: Rows

    /// `label:` in the first column, `views` side by side in the second.
    @discardableResult
    func row(_ label: String, _ views: NSView...) -> NSGridRow {
        let title = label.isEmpty ? NSGridCell.emptyContentView : NSTextField(labelWithString: label)
        let content = views.count == 1 ? views[0] : Self.hstack(views)
        let row = grid.addRow(with: [title, content])
        row.rowAlignment = .firstBaseline
        return row
    }

    /// A bold heading across both columns, with space above it (except at the top).
    func section(_ title: String) {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let row = grid.addRow(with: [label, NSGridCell.emptyContentView])
        row.mergeCells(in: NSRange(location: 0, length: 2))
        row.cell(at: 0).xPlacement = .leading
        if grid.numberOfRows > 1 { row.topPadding = 14 }
    }

    /// Small secondary text in the second column (what a setting does, what overrides it).
    @discardableResult
    func note(_ text: String) -> NSTextField {
        let label = Self.noteLabel(text)
        grid.addRow(with: [NSGridCell.emptyContentView, label])
        return label
    }

    static func noteLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 420
        return label
    }

    static func hstack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = spacing
        return stack
    }

    func button(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let target = ControlAction { _ in action() }
        retain(target)
        return NSButton(title: title, target: target, action: #selector(ControlAction.fire(_:)))
    }

    // MARK: Bound controls

    /// A checkbox for a boolean key.
    func checkbox(_ title: String, _ table: String, _ key: String, default fallback: Bool) -> NSButton {
        let target = ControlAction { [weak self] control in
            guard let button = control as? NSButton else { return }
            self?.model.set(key, in: table, to: .bool(button.state == .on), default: .bool(fallback))
        }
        retain(target)
        let box = NSButton(checkboxWithTitle: title, target: target, action: #selector(ControlAction.fire(_:)))
        onRefresh { [weak self, weak box] in
            guard let self, let box else { return }
            box.state = self.model.bool(key, in: table, default: fallback) ? .on : .off
        }
        return box
    }

    /// A pop-up menu for a key with a fixed set of string values.
    func popup(_ choices: [(title: String, value: String)], _ table: String, _ key: String, default fallback: String) -> NSPopUpButton {
        let target = ControlAction { [weak self] control in
            guard let popup = control as? NSPopUpButton, choices.indices.contains(popup.indexOfSelectedItem) else { return }
            self?.model.set(key, in: table, to: .string(choices[popup.indexOfSelectedItem].value), default: .string(fallback))
        }
        retain(target)
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: choices.map(\.title))
        popup.target = target
        popup.action = #selector(ControlAction.fire(_:))
        onRefresh { [weak self, weak popup] in
            guard let self, let popup else { return }
            var current = fallback
            if case .string(let value)? = self.model.value(key, in: table) { current = value }
            popup.selectItem(at: choices.firstIndex { $0.value == current } ?? 0)
        }
        return popup
    }

    /// A number field (with a stepper) for an integer or float key in `range`; `live: false` writes typed values only
    /// when editing ends.
    func number(_ table: String, _ key: String, default fallback: Double, range: ClosedRange<Double>, step: Double,
                integer: Bool, unit: String? = nil, live: Bool = true) -> NSView {
        let field = NSTextField(string: "")
        field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let stepper = NSStepper()
        stepper.minValue = range.lowerBound
        stepper.maxValue = range.upperBound
        stepper.increment = step
        stepper.valueWraps = false
        func format(_ value: Double) -> String {
            integer ? String(Int(value.rounded())) : String(format: "%g", value)
        }
        func write(_ value: Double) {
            let tomlValue: TOMLValue = integer ? .integer(Int(value.rounded())) : .float(value)
            model.set(key, in: table, to: tomlValue, default: integer ? .integer(Int(fallback)) : .float(fallback))
        }
        let committer = FieldCommitter(live: live) { [weak stepper] text in
            guard let value = Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
                  range.contains(value), !integer || value == value.rounded() else { return false }
            stepper?.doubleValue = value
            write(value)
            return true
        }
        field.delegate = committer
        retain(committer)
        let target = ControlAction { [weak field] control in
            guard let stepper = control as? NSStepper else { return }
            let value = (stepper.doubleValue / step).rounded() * step
            field?.stringValue = format(value)
            field?.textColor = .labelColor
            write(value)
        }
        retain(target)
        stepper.target = target
        stepper.action = #selector(ControlAction.fire(_:))
        field.toolTip = "\(format(range.lowerBound))–\(format(range.upperBound))"
        onRefresh { [weak self, weak field, weak stepper] in
            guard let self, let field, field.currentEditor() == nil else { return }
            var value = fallback
            switch self.model.value(key, in: table) {
            case .integer(let n)?: value = Double(n)
            case .float(let f)?: value = f
            default: break
            }
            field.stringValue = format(value)
            field.textColor = .labelColor
            stepper?.doubleValue = value
        }
        var views: [NSView] = [field, stepper]
        if let unit { views.append(NSTextField(labelWithString: unit)) }
        return Self.hstack(views, spacing: 4)
    }

    /// A text field for a string key; `validate` rejects values (they are not written).
    func text(_ table: String, _ key: String, default fallback: String, width: CGFloat,
              validate: @escaping (String) -> Bool = { !$0.isEmpty }) -> NSTextField {
        let field = NSTextField(string: "")
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        let committer = FieldCommitter { [weak self] text in
            guard validate(text) else { return false }
            self?.model.set(key, in: table, to: .string(text), default: .string(fallback))
            return true
        }
        field.delegate = committer
        retain(committer)
        onRefresh { [weak self, weak field] in
            guard let self, let field, field.currentEditor() == nil else { return }
            if case .string(let value)? = self.model.value(key, in: table) { field.stringValue = value } else { field.stringValue = fallback }
            field.textColor = .labelColor
        }
        return field
    }
}

/// `~/…` for paths in the home folder (config files stay portable between Macs and users).
func abbreviatedPath(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
