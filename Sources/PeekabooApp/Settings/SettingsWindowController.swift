import AppKit
import PeekabooCore

/// The Settings window (`app.config`, ⌘,): every option of config.toml, written to the file as it changes.
///
/// Nothing of it exists until it is first opened: the window and the selected pane are built then (measured with
/// `PEEKABOO_TRACE=1`: "settings window built"), the other panes when they are first selected. It follows the file:
/// any load of config.toml — an edit here, a save in an editor — refreshes the visible pane, and a file with an
/// error shows the error above the panes (edits wait until it is fixed).
final class SettingsWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    enum Pane: String, CaseIterable {
        case general, viewer, keyboard, files, performance, updates

        var title: String {
            switch self {
            case .general: return "General"
            case .viewer: return "Viewer"
            case .keyboard: return "Keyboard"
            case .files: return "Files"
            case .performance: return "Performance"
            case .updates: return "Updates"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .viewer: return "photo"
            case .keyboard: return "keyboard"
            case .files: return "folder"
            case .performance: return "speedometer"
            case .updates: return "arrow.triangle.2.circlepath"
            }
        }
    }

    let model: SettingsModel
    private let updateStatus: () -> String?
    private let openConfigFile: () -> Void
    private var panes: [Pane: SettingsPane] = [:]
    private(set) var current: Pane = .general
    private let container = NSView()
    private let bannerText = NSTextField(wrappingLabelWithString: "")
    private var banner: NSStackView!
    private var observer: NSObjectProtocol?

    /// `updateStatus`: the updater's status line now (`AppDelegate.updateStatus`; nil without an updater), shown when
    /// the Updates pane opens. `openConfigFile`: `app.config_file`.
    init(store: ConfigStore, updateStatus: @escaping () -> String?, openConfigFile: @escaping () -> Void) {
        model = SettingsModel(store: store)
        self.updateStatus = updateStatus
        self.openConfigFile = openConfigFile
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                                    styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        super.init(window: window)
        window.delegate = self
        let toolbar = NSToolbar(identifier: "PeekabooSettings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        bannerText.textColor = .systemRed
        bannerText.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        bannerText.preferredMaxLayoutWidth = 470
        let warning = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Error")!)
        warning.contentTintColor = .systemRed
        let open = NSButton(title: "Open config.toml", target: self, action: #selector(openFile))
        open.controlSize = .small
        banner = NSStackView(views: [warning, bannerText, NSView(), open])
        banner.orientation = .horizontal
        banner.alignment = .centerY
        banner.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 0, right: 20)
        let content = NSStackView(views: [banner, container])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 0
        banner.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        window.contentView = content

        observer = NotificationCenter.default.addObserver(forName: ConfigStore.didLoadNotification, object: store,
                                                          queue: .main) { [weak self] _ in self?.configLoaded() }
        model.onProblemChanged = { [weak self] in
            guard let self else { return }
            // A refused edit wrote nothing: the controls show what the file says again.
            if self.model.editError != nil { self.panes[self.current]?.refresh() }
            self.updateBanner()
        }
        select(.general)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    /// Bring the window to the front, on `pane` if given.
    func show(_ pane: Pane? = nil) {
        if let pane, pane != current { select(pane) }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// The pane object (built on first use).
    func pane(_ pane: Pane) -> SettingsPane {
        if let existing = panes[pane] { return existing }
        let made: SettingsPane
        switch pane {
        case .general: made = GeneralPane(model: model, openConfigFile: { [weak self] in self?.openConfigFile() })
        case .viewer: made = ViewerPane(model: model)
        case .keyboard: made = ShortcutsPane(model: model)
        case .files: made = FilesPane(model: model)
        case .performance: made = PerformancePane(model: model)
        case .updates: made = UpdatesPane(model: model, status: updateStatus)
        }
        panes[pane] = made
        return made
    }

    func select(_ pane: Pane) {
        (panes[current] as? ShortcutsPane)?.stopRecording()
        current = pane
        window?.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(pane.rawValue)
        window?.title = pane.title
        let object = self.pane(pane)
        let view = object.view
        object.refresh()
        container.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        updateBanner()
        fitWindow()
    }

    /// The window's content size follows the pane (top edge fixed), at once: an animated resize would hold the main
    /// thread for its 0.1–0.2 s.
    private func fitWindow() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: window.isVisible, animate: false)
    }

    private func configLoaded() {
        model.fileLoaded()
        panes[current]?.refresh()
        updateBanner()
    }

    private func updateBanner() {
        let problem = model.problem
        bannerText.stringValue = problem ?? ""
        guard banner.isHidden != (problem == nil) else { return }
        banner.isHidden = problem == nil
        fitWindow()
    }

    @objc private func openFile() { openConfigFile() }

    // MARK: NSToolbarDelegate

    private var identifiers: [NSToolbarItem.Identifier] { Pane.allCases.map { NSToolbarItem.Identifier($0.rawValue) } }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = Pane(rawValue: identifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(toolbarItemClicked(_:))
        return item
    }

    @objc private func toolbarItemClicked(_ sender: NSToolbarItem) {
        guard let pane = Pane(rawValue: sender.itemIdentifier.rawValue), pane != current else { return }
        select(pane)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        (panes[current] as? ShortcutsPane)?.stopRecording()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // The default apps may have changed in Finder meanwhile.
        if current == .general { panes[current]?.refresh() }
    }

    func windowDidResignKey(_ notification: Notification) {
        (panes[current] as? ShortcutsPane)?.cancelRecording()
    }
}

/// Text fields need the standard editing shortcuts, which the app's menu (built from the viewer's keymap) does not
/// carry: ⌘X ⌘C ⌘V ⌘A ⌘Z ⇧⌘Z go to the field being edited, and ⌘W closes this window rather than the viewer.
final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, let chord = KeyChord(event: event), chord.modifiers.contains(.command),
              chord.modifiers.isDisjoint(with: [.option, .control]) else { return super.performKeyEquivalent(with: event) }
        let shift = chord.modifiers.contains(.shift)
        if chord.key == "w", !shift {
            performClose(nil)
            return true
        }
        if firstResponder is NSText {
            let selector: Selector?
            switch (chord.key, shift) {
            case ("x", false): selector = #selector(NSText.cut(_:))
            case ("c", false): selector = #selector(NSText.copy(_:))
            case ("v", false): selector = #selector(NSText.paste(_:))
            case ("a", false): selector = #selector(NSText.selectAll(_:))
            case ("z", false): selector = Selector(("undo:"))
            case ("z", true): selector = Selector(("redo:"))
            default: selector = nil
            }
            if let selector, NSApp.sendAction(selector, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}
