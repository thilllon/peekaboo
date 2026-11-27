import AppKit
import Carbon.HIToolbox
import PeekabooCore

/// Settings › Keyboard: every bindable action with its keys, in the normal and in the zoomed-in context.
///
/// + (or a key's menu › Change…) records the next key press, matched by physical key like the viewer does
/// (`KeyChord(event:)`), so recording works with any input method. Keys another action uses are named, and pressing
/// them again moves them (so does Move); keys that start a sequence, or a sequence that starts with them, are freed
/// the same way. Every change is a minimal edit of config.toml (`ConfigEditor`): in the file Peekaboo writes, which
/// lists the keymap, a key goes into its action's line, removing it deletes it there, and Change… replaces it in place;
/// in an older file of overrides, removing a built-in key writes `"chord" = "none"`. The rows come from
/// `Action.simpleIDs` and from what the keymaps bind (parameterized actions, action lists), so new actions appear here
/// without changes.
final class ShortcutsPane: SettingsForm, SettingsPane, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    struct Row: Equatable {
        let actions: [Action]
        let title: String
        let id: String
        let group: String
        /// Keys bound to exactly `actions` in the context's own table.
        let sequences: [[KeyChord]]
        /// They differ from the built-in keymap's.
        let modified: Bool
    }

    private enum Item {
        case group(String)
        case row(Row)
    }

    private(set) var context: KeyContext = .normal
    private var items: [Item] = []
    /// Actions added with the action field this session (a row stays until the window closes).
    private var added: [[Action]] = []
    /// Recording keys for `actions` (replacing `replacing` when changing a key).
    private(set) var recording: (actions: [Action], replacing: [KeyChord]?)?
    /// Keys pressed once that other bindings use: pressing them again moves them.
    private(set) var pendingMove: (sequence: [KeyChord], conflicts: [KeyConflict])?
    private var monitor: Any?

    let table = NSTableView()
    private let search = NSSearchField()
    private let contextControl = NSSegmentedControl(labels: ["Normal", "Zoomed in"], trackingMode: .selectOne, target: nil, action: nil)
    let status = NSTextField(wrappingLabelWithString: "")
    private let moveButton = NSButton(title: "Move", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let actionField = NSTextField(string: "")
    private(set) lazy var view: NSView = build()

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    // MARK: Layout

    private func build() -> NSView {
        let defaults = checkbox("Add built-in shortcuts config.toml does not list", "keymap", "defaults", default: true)
        defaults.toolTip = "Off (as Peekaboo writes the file): [keys] in config.toml is the whole keymap, and the vim keys go where it leaves a key free. On: the built-in shortcuts apply, with [keys] on top."
        let vim = checkbox("Vim keys (h j k l, g g, G, d d, y y …)", "keymap", "vim", default: false)
        let layers = Self.hstack([defaults, vim], spacing: 20)

        contextControl.selectedSegment = 0
        contextControl.target = self
        contextControl.action = #selector(contextChanged)
        search.placeholderString = "Search actions or keys"
        search.delegate = self
        search.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let filters = Self.hstack([contextControl, NSView(), search])
        filters.distribution = .fill

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil
        table.rowSizeStyle = .custom
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.usesAutomaticRowHeights = false
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 340).isActive = true
        table.sizeLastColumnToFit()

        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.preferredMaxLayoutWidth = 440
        // Two lines reserved, so a longer message never needs a taller window.
        status.maximumNumberOfLines = 2
        status.heightAnchor.constraint(equalToConstant: 30).isActive = true
        moveButton.target = self
        moveButton.action = #selector(moveNow)
        moveButton.controlSize = .small
        cancelButton.target = self
        cancelButton.action = #selector(cancelRecording)
        cancelButton.controlSize = .small
        let statusBar = Self.hstack([status, NSView(), moveButton, cancelButton])
        statusBar.alignment = .centerY

        actionField.placeholderString = "file.move:keep, meta.rate:4, nav.jump:+5, exec:open -a Preview {path}"
        actionField.target = self
        actionField.action = #selector(addAction)
        actionField.widthAnchor.constraint(equalToConstant: 330).isActive = true
        let add = NSButton(title: "Add", target: self, action: #selector(addAction))
        let resetAll = NSButton(title: "Reset All…", target: self, action: #selector(confirmResetAll))
        let addRow = Self.hstack([NSTextField(labelWithString: "Add an action:"), actionField, add, NSView(), resetAll])

        let hint = Self.noteLabel("Click + and press the new keys (Esc cancels). Keys in use are named: press them again to move them. Sequences such as “g g” are set in config.toml.")
        hint.preferredMaxLayoutWidth = 580

        let stack = NSStackView(views: [layers, filters, scroll, statusBar, addRow, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [filters, scroll, statusBar, addRow] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: 640).isActive = true
        showStatus(nil)
        return stack
    }

    // MARK: Rows

    override func refresh() {
        super.refresh()
        reloadRows()
    }

    private static let groupOrder = ["nav", "zoom", "pan", "view", "file", "meta", "app", "exec"]
    private static let groupTitles = ["nav": "Navigate", "zoom": "Zoom", "pan": "Pan (zoomed in)", "view": "View",
                                      "file": "Files", "meta": "Ratings, labels and flags", "app": "App", "exec": "Commands"]

    /// `rows()` for the keymap, context and added actions it was computed for (searching filters it per keystroke).
    private var cachedRows: (keymap: Keymap, context: KeyContext, added: [[Action]], rows: [Row])?

    /// Every action list worth a row in `context`, with its keys.
    func rows() -> [Row] {
        let config = model.config
        if let cached = cachedRows, cached.context == context, cached.added == added, cached.keymap == config.keymap {
            return cached.rows
        }
        // What "built-in keys" means for this file: the built-in keymap under the file's [keys], or, in a file that lists
        // the keymap, the default lines it was written with (the vim layer under them).
        let builtIn = !config.keymapDefaults ? Keymap.written(vim: config.vimKeys, autoAdvance: config.autoAdvance)
            : !config.vimKeys && !config.autoAdvance ? Keymap.default
            : Keymap.build(defaults: true, vim: config.vimKeys, autoAdvance: config.autoAdvance)
        let bound = config.keymap.bindingsByActions(context)
        let defaults = builtIn.bindingsByActions(context)
        var lists = Action.simpleIDs.compactMap(Action.init(id:)).filter { $0 != .none }.map { [$0] }
        var seen = Set(lists)
        for list in bound.keys.sorted(by: Self.idOrder) + defaults.keys.sorted(by: Self.idOrder) + added
        where seen.insert(list).inserted {
            lists.append(list)
        }
        let rows = lists.map { list in
            let sequences = bound[list] ?? []
            return Row(actions: list, title: list.map(KeyLabels.title).joined(separator: " + "),
                       id: list.map(\.id).joined(separator: " + "), group: list[0].namespace, sequences: sequences,
                       modified: Set(sequences) != Set(defaults[list] ?? []))
        }
        cachedRows = (config.keymap, context, added, rows)
        return rows
    }

    private static func idOrder(_ a: [Action], _ b: [Action]) -> Bool {
        a.map(\.id).joined(separator: " ").localizedStandardCompare(b.map(\.id).joined(separator: " ")) == .orderedAscending
    }

    private func reloadRows() {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = rows().filter { row in
            query.isEmpty || row.title.lowercased().contains(query) || row.id.lowercased().contains(query)
                || row.sequences.contains { Self.label($0).lowercased().contains(query) || KeyChord.spec(of: $0).contains(query) }
        }
        let groups = Dictionary(grouping: matching, by: \.group)
        let order = Self.groupOrder.filter { groups[$0] != nil } + groups.keys.filter { !Self.groupOrder.contains($0) }.sorted()
        items = order.flatMap { group -> [Item] in
            let rows = groups[group]!.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
            return [.group(Self.groupTitles[group] ?? group.capitalized)] + rows.map(Item.row)
        }
        table.reloadData()
    }

    /// Menu-style keys: `⌘D`, `?`, `G G`.
    static func label(_ sequence: [KeyChord]) -> String { sequence.map(\.symbol).joined(separator: " ") }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .group = items[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .group = items[row] { return 22 }
        return 32
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch items[row] {
        case .group(let title):
            let label = NSTextField(labelWithString: title)
            label.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            let cell = NSTableCellView()
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        case .row(let item):
            let identifier = NSUserInterfaceItemIdentifier("shortcut")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ShortcutCell ?? ShortcutCell(identifier: identifier)
            let recordingHere = recording?.actions == item.actions
            cell.configure(item, pane: self, recording: recordingHere && recording?.replacing == nil,
                           replacing: recordingHere ? recording?.replacing : nil)
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === search { reloadRows() }
    }

    @objc private func contextChanged() {
        stopRecording()
        context = contextControl.selectedSegment == 1 ? .zoomed : .normal
        showStatus(context == .zoomed ? "While zoomed in, these keys run instead of the normal ones; other keys work as in Normal." : nil)
        reloadRows()
    }

    // MARK: Recording

    /// Record the next key press for `actions` (instead of `replacing`, when changing a key).
    func record(_ actions: [Action], replacing: [KeyChord]? = nil) {
        stopRecording()
        recording = (actions, replacing)
        let title = actions.map(KeyLabels.title).joined(separator: " + ")
        showStatus("Press the new keys for “\(title)” · Esc cancels", cancel: true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.recording != nil, event.window === self.view.window else { return event }
            self.recorded(event)
            return nil
        }
        reloadRows()
    }

    /// A key press while recording (internal for tests).
    func recorded(_ event: NSEvent) {
        guard let (actions, replacing) = recording else { return }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if Int(event.keyCode) == kVK_Escape, flags.isEmpty {
            cancelRecording()
            return
        }
        guard let chord = KeyChord(event: event) else {
            NSSound.beep()
            return
        }
        let sequence = [chord]
        let label = Self.label(sequence)
        let title = actions.map(KeyLabels.title).joined(separator: " + ")
        if sequence == replacing || model.config.keymap.bindings[context]?[sequence] == actions {
            stopRecording()
            showStatus("\(label) already runs “\(title)”.")
            return
        }
        let conflicts = model.config.keymap.conflicts(binding: sequence, to: actions, context: context)
        if conflicts.isEmpty || pendingMove?.sequence == sequence {
            apply(sequence, to: actions, replacing: replacing, conflicts: conflicts)
            return
        }
        pendingMove = (sequence, conflicts)
        showStatus("\(Self.describe(conflicts, of: sequence)). Press \(label) again to move it to “\(title)” · Esc cancels",
                   move: true, cancel: true)
    }

    /// `⌘D is used by “Move to Trash”`, `G starts “G G” (First Image)`.
    static func describe(_ conflicts: [KeyConflict], of sequence: [KeyChord]) -> String {
        let keys = label(sequence)
        return conflicts.map { conflict in
            let owner = conflict.actions.map(KeyLabels.title).joined(separator: " + ")
            let place = conflict.context == .zoomed ? " while zoomed in" : ""
            guard conflict.isPrefix else { return "\(keys) is used by “\(owner)”\(place)" }
            let other = label(conflict.sequence)
            return conflict.sequence.count > sequence.count ? "\(keys) starts “\(other)” (\(owner))\(place)"
                : "\(keys) starts with “\(other)” (\(owner))\(place)"
        }.joined(separator: "; ")
    }

    @objc private func moveNow() {
        guard let (actions, replacing) = recording, let pending = pendingMove else { return }
        apply(pending.sequence, to: actions, replacing: replacing, conflicts: pending.conflicts)
    }

    private func apply(_ sequence: [KeyChord], to actions: [Action], replacing: [KeyChord]?, conflicts: [KeyConflict]) {
        stopRecording()
        let context = self.context
        let label = Self.label(sequence)
        let title = actions.map(KeyLabels.title).joined(separator: " + ")
        let taken = conflicts.map { $0.actions.map(KeyLabels.title).joined(separator: " + ") }
        model.edit({ editor in
            for conflict in conflicts where conflict.isPrefix { try editor.unbind(conflict.sequence, context: conflict.context) }
            if let replacing {
                try editor.rebind(replacing, to: sequence, actions: actions, context: context)
            } else {
                try editor.bind(sequence, to: actions, context: context)
            }
        }, done: { [weak self] in
            self?.showStatus("\(label) runs “\(title)”" + (taken.isEmpty ? "." : " (moved from “\(taken.joined(separator: "”, “"))”)."))
        })
    }

    @objc func cancelRecording() {
        stopRecording()
        showStatus(nil)
    }

    /// End recording (switching panes or contexts, closing the window).
    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        let wasRecording = recording != nil
        recording = nil
        pendingMove = nil
        moveButton.isHidden = true
        cancelButton.isHidden = true
        if wasRecording { reloadRows() }
    }

    private func showStatus(_ text: String?, move: Bool = false, cancel: Bool = false) {
        status.stringValue = text ?? ""
        moveButton.isHidden = !move
        cancelButton.isHidden = !cancel
    }

    // MARK: Editing

    func remove(_ sequence: [KeyChord], from row: Row) {
        let context = self.context
        let label = Self.label(sequence)
        model.edit({ try $0.unbind(sequence, from: row.actions, context: context) },
                   done: { [weak self] in self?.showStatus("Removed \(label) from “\(row.title)”.") })
    }

    func reset(_ row: Row) {
        let context = self.context
        model.edit({ try $0.reset(row.actions, context: context) },
                   done: { [weak self] in self?.showStatus("“\(row.title)” has its built-in keys again.") })
    }

    @objc private func addAction() {
        let id = actionField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        guard let action = Action(id: id), action != .none else {
            showStatus("“\(id)” is not an action (see Actions in docs/CONFIG.md).")
            return
        }
        switch action {
        case .move(let target), .copy(let target), .copyPicks(let target):
            guard FileOperations.isKnownTarget(target, slots: model.config.slots) else {
                showStatus("There is no destination “\(target)”: add it in Files › Move and copy destinations.")
                return
            }
        default: break
        }
        if !added.contains([action]) { added.append([action]) }
        actionField.stringValue = ""
        search.stringValue = ""
        reloadRows()
        if let index = items.firstIndex(where: { if case .row(let row) = $0 { return row.actions == [action] } else { return false } }) {
            table.scrollRowToVisible(index)
        }
        record([action])
    }

    @objc private func confirmResetAll() {
        let alert = NSAlert()
        alert.messageText = "Reset all shortcuts?"
        alert.informativeText = model.config.keymapDefaults
            ? "This removes every entry of [keys] and [keys.zoomed] from config.toml: the built-in shortcuts apply again."
            : "This writes [keys] and [keys.zoomed] of config.toml anew with the built-in shortcuts, in place of what they hold now."
        alert.addButton(withTitle: "Reset All")
        alert.addButton(withTitle: "Cancel")
        let reset: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.model.edit({ try $0.resetBindings() },
                             done: { self?.showStatus("All shortcuts are the built-in ones again.") })
        }
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: reset) } else { reset(alert.runModal()) }
    }
}

/// One action of the shortcut editor, drawn in one view: its name and id, a key cap per key (click: Change…, Remove),
/// a + cap to add keys, and ↺ when its keys differ from the built-in ones.
///
/// Drawn rather than built from buttons: an `NSButton` costs ~1 ms to create and size, and the dozen rows the pane
/// first shows had five each (~65 ms before the first frame); text and rounded rectangles draw in microseconds. Each
/// cap is an accessibility button, so VoiceOver can press it.
final class ShortcutCell: NSTableCellView, NSViewToolTipOwner {
    private enum Cap: Equatable {
        case key(Int)
        case add
        case reset
    }

    private weak var pane: ShortcutsPane?
    private var row: ShortcutsPane.Row?
    private var recording = false
    private var replacing: [KeyChord]?
    private var caps: [(rect: NSRect, cap: Cap)] = []
    private var laidOutWidth: CGFloat = -1

    private static let titleWidth: CGFloat = 230
    private static let titleFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    private static let modifiedFont = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
    private static let idAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor,
    ]
    private static let capFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var isFlipped: Bool { true }

    func configure(_ row: ShortcutsPane.Row, pane: ShortcutsPane, recording: Bool, replacing: [KeyChord]?) {
        self.row = row
        self.pane = pane
        self.recording = recording
        self.replacing = replacing
        // The caps (and their key indices) were the previous row's: none until the next layout.
        caps.removeAll()
        removeAllToolTips()
        laidOutWidth = -1
        needsDisplay = true
    }

    private func text(of cap: Cap) -> String {
        switch cap {
        case .key(let index):
            guard let row, row.sequences.indices.contains(index) else { return "" }
            return replacing == row.sequences[index] ? "Press keys…" : ShortcutsPane.label(row.sequences[index])
        case .add: return recording ? "Press keys…" : "+"
        case .reset: return "↺"
        }
    }

    private func isActive(_ cap: Cap) -> Bool {
        switch cap {
        case .key(let index): return row.map { $0.sequences.indices.contains(index) && replacing == $0.sequences[index] } ?? false
        case .add: return recording
        case .reset: return false
        }
    }

    /// Cap positions for the current width: keys, then +, left to right until ↺; keys that do not fit are left out
    /// (they stay in config.toml and in the search).
    private func layoutCaps() {
        guard laidOutWidth != bounds.width, let row else { return }
        laidOutWidth = bounds.width
        caps.removeAll()
        removeAllToolTips()
        let height: CGFloat = 20
        let y = (bounds.height - height) / 2
        let resetX = bounds.width - 28
        if row.modified { caps.append((NSRect(x: resetX, y: y, width: 22, height: height), .reset)) }
        let limit = resetX - 6
        var x = 8 + Self.titleWidth + 8
        let addWidth = width(of: .add)
        for index in row.sequences.indices {
            let w = width(of: .key(index))
            guard x + w + 4 + addWidth <= limit else { break }
            caps.append((NSRect(x: x, y: y, width: w, height: height), .key(index)))
            x += w + 4
        }
        caps.append((NSRect(x: x, y: y, width: addWidth, height: height), .add))
        for (rect, _) in caps { addToolTip(rect, owner: self, userData: nil) }
        setAccessibilityChildren(caps.map { rect, cap in
            let element = CapElement()
            element.setAccessibilityRole(.button)
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(rect)
            element.setAccessibilityLabel(accessibilityText(cap))
            element.press = { [weak self] in self?.activate(cap, at: rect) }
            return element
        })
        setAccessibilityLabel(row.title)
    }

    private func width(of cap: Cap) -> CGFloat {
        if cap == .reset { return 22 }
        let size = (text(of: cap) as NSString).size(withAttributes: [.font: Self.capFont])
        return max(ceil(size.width) + 14, 24)
    }

    private func accessibilityText(_ cap: Cap) -> String {
        guard let row else { return "" }
        switch cap {
        case .key(let index): return "\(row.title): \(KeyChord.spec(of: row.sequences[index]))"
        case .add: return "Add keys for \(row.title)"
        case .reset: return "Reset \(row.title) to its built-in keys"
        }
    }

    override func layout() {
        super.layout()
        layoutCaps()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        layoutCaps()
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: row.modified ? Self.modifiedFont : Self.titleFont, .foregroundColor: NSColor.labelColor,
        ]
        let middle = bounds.height / 2
        (row.title as NSString).draw(with: NSRect(x: 8, y: middle - 16, width: Self.titleWidth, height: 17),
                                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: titleAttributes)
        (row.id as NSString).draw(with: NSRect(x: 8, y: middle + 1, width: Self.titleWidth, height: 13),
                                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: Self.idAttributes)
        for (rect, cap) in caps {
            let active = isActive(cap)
            let label = text(of: cap)
            if cap != .reset {
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
                NSColor.labelColor.withAlphaComponent(0.06).setFill()
                path.fill()
                (active ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
                path.lineWidth = active ? 1.5 : 1
                path.stroke()
            }
            let color: NSColor = active ? .controlAccentColor : cap == .reset ? .secondaryLabelColor : .labelColor
            let font = cap == .reset ? NSFont.systemFont(ofSize: 14) : Self.capFont
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = (label as NSString).size(withAttributes: attributes)
            (label as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                                     withAttributes: attributes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let (rect, cap) = caps.first(where: { $0.rect.contains(point) }) else { return }
        activate(cap, at: rect)
    }

    private func activate(_ cap: Cap, at rect: NSRect) {
        guard let row, let pane else { return }
        switch cap {
        case .add: pane.record(row.actions)
        case .reset: pane.reset(row)
        case .key(let index):
            guard row.sequences.indices.contains(index) else { return }  // a VoiceOver element of the previous row
            let menu = NSMenu()
            if row.sequences[index].count == 1 {
                menu.addItem(withTitle: "Change…", action: #selector(change(_:)), keyEquivalent: "").target = self
            } else {
                menu.addItem(withTitle: "Sequences are changed in config.toml", action: nil, keyEquivalent: "").isEnabled = false
            }
            menu.addItem(withTitle: "Remove", action: #selector(removeKeys(_:)), keyEquivalent: "").target = self
            for item in menu.items { item.tag = index }
            menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY + 2), in: self)
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let row, let cap = caps.first(where: { $0.rect.contains(point) })?.cap else { return "" }
        switch cap {
        case .key(let index): return KeyChord.spec(of: row.sequences[index])
        case .add: return "Add keys for this action"
        case .reset: return "Reset to the built-in keys"
        }
    }

    @objc private func change(_ sender: NSMenuItem) {
        guard let row, row.sequences.indices.contains(sender.tag) else { return }
        pane?.record(row.actions, replacing: row.sequences[sender.tag])
    }

    @objc private func removeKeys(_ sender: NSMenuItem) {
        guard let row, row.sequences.indices.contains(sender.tag) else { return }
        pane?.remove(row.sequences[sender.tag], from: row)
    }
}

/// A key cap of `ShortcutCell` for VoiceOver.
private final class CapElement: NSAccessibilityElement {
    var press: () -> Void = {}

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }
}
