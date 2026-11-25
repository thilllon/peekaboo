import AppKit
import PeekabooCore
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    /// Windows in front and the app active, or out of sight and never active for tests (`.headless`).
    var presentation = Presentation.interactive
    private var viewer: ViewerWindowController?
    private let configStore = ConfigStore()
    /// Paths opened recently; during launch AppKit may deliver argv paths *and* an
    /// open-documents event for the same file, so dedupe for a short window.
    private var recentlyOpened: [String: Date] = [:]
    private var openedSomething = false
    private var selfTest: SelfTest?
    private var lastKeymap: Keymap?
    /// In-app updates (nil outside Peekaboo.app, and in the self-test).
    private var updates: UpdateController?
    /// The updater's current status line, for a window that opens after the last `PeekabooUpdateStatusChanged`.
    var updateStatus: String? { updates?.updater.status }
    /// Built the first time `app.config` (⌘,) runs, never at launch.
    private(set) var settings: SettingsWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The View menu carries its own full-screen items (instant and native); stop AppKit
        // from inserting a second "Enter Full Screen".
        UserDefaults.standard.register(defaults: ["NSFullScreenMenuItemEverywhere": false])
        configStore.load()
        // Build the window now so its creation overlaps the wait for the open-documents event.
        let viewer = ViewerWindowController(configStore: configStore, presentation: presentation)
        self.viewer = viewer
        // Until launch finishes, `open` presents the first frame in its own turn (AppKit's launch keeps the main
        // queue waiting ~70 ms) — and the app must be active for that frame to be in front.
        viewer.presentsSynchronously = true
        viewer.onOpenURLs = { [weak self] urls in self?.open(urls, dedupe: false) }
        viewer.onOpenPanel = { [weak self] in self?.showOpenPanel() }
        viewer.onOpenSettings = { [weak self] in self?.showSettings() }
        configStore.onChange = { [weak self] config in
            self?.viewer?.apply(config)
            self?.rebuildMenu(config.keymap)
            self?.updates?.updater.apply(config.updates)
        }
        configStore.onError = { [weak self] message in self?.viewer?.toast(message) }
        configStore.startWatching()

        let arguments = Array(CommandLine.arguments.dropFirst())
        if let flag = arguments.firstIndex(of: "--selftest") {
            let path = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : FileManager.default.currentDirectoryPath
            let test = SelfTest(folder: URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true), viewer: viewer)
            selfTest = test
            openedSomething = true
            activate()
            test.start()
            rebuildMenu(configStore.config.keymap)
            return
        }
        // `Peekaboo <path>` from a terminal: start immediately.
        let paths = arguments.filter { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }
        if !paths.isEmpty { open(paths.map { URL(fileURLWithPath: $0) }) }
        // After the first frame: the menu is not needed to draw it.
        rebuildMenu(configStore.config.keymap)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        viewer?.presentsSynchronously = false
        activate()
        // `load()` ran before `onError` was set: show a broken config, or the keys it skipped, now.
        if let problem = configStore.lastError ?? configStore.lastWarning { viewer?.toast(problem) }
        scheduleScriptedActions()
        // Launched from the Dock or Spotlight without a document: show the drop hint.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.openedSomething else { return }
            self.viewer?.showEmpty(nil)
        }
        // In-app updates start a second after launch, behind the first frame and its sharp tier; the first check
        // waits 10 s more.
        if selfTest == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.startUpdates() }
        }
    }

    private func startUpdates() {
        let started = Trace.now()
        updates = Updater(settings: configStore.config.updates).map { updater in
            UpdateController(updater: updater) { [weak self] in self?.viewer }
        }
        updates?.updater.start()
        if updates != nil {
            Trace.log(String(format: "update: set up in %.3f ms, first check in %.0f s", Trace.ms(since: started),
                             UpdatePolicy().firstCheckDelay))
        }
    }

    /// A ready update installs behind the quitting app (`[updates] auto_install`).
    func applicationWillTerminate(_ notification: Notification) {
        updates?.updater.installOnQuit()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard selfTest == nil else { return }
        open(urls)
    }

    /// Stay resident after the last window closes so the next open is instant.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock click: bring back the window with the last image (or the drop hint).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { viewer?.reopen() }
        return true
    }

    private func open(_ urls: [URL], dedupe: Bool = true) {
        let now = Date()
        // A duplicate arrives while the window shows the file; opening it again after closing the window is not one.
        let dedupe = dedupe && viewer?.window?.isVisible == true
        let fresh = urls.filter { url in
            let key = url.standardizedFileURL.path
            if dedupe, let t = recentlyOpened[key], now.timeIntervalSince(t) < 1.5 { return false }
            recentlyOpened[key] = now
            return true
        }
        guard !fresh.isEmpty else { return }
        openedSomething = true
        if viewer == nil { viewer = ViewerWindowController(configStore: configStore, presentation: presentation) }
        if viewer?.presentsSynchronously == true { activate() }
        viewer?.open(fresh)
    }

    /// Bring the app to the front (never headless).
    private func activate() {
        if presentation == .interactive { NSApp.activate() }
    }

    /// Development aid for scripted screenshots: `PEEKABOO_ACTIONS="view.hud,view.help"` performs
    /// those action ids one after another (400 ms apart), starting 1 s after launch.
    private func scheduleScriptedActions() {
        guard let script = ProcessInfo.processInfo.environment["PEEKABOO_ACTIONS"], !script.isEmpty else { return }
        let actions = script.split(separator: ",").compactMap { Action(id: String($0)) }
        for (i, action) in actions.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1 + 0.4 * Double(i)) { [weak self] in
                self?.viewer?.perform(action)
            }
        }
    }

    // MARK: Settings

    /// `app.config`: the Settings window, built on first use (internal for tests).
    func showSettings(_ pane: SettingsWindowController.Pane? = nil) {
        let started = Trace.now()
        let built = settings == nil
        let controller = settings ?? SettingsWindowController(store: configStore, updateStatus: { [weak self] in
            self?.updateStatus
        }, presentation: presentation) { [weak self] in
            self?.viewer?.perform(.configFile)
        }
        settings = controller
        controller.show(pane)
        controller.window?.displayIfNeeded()
        Trace.log(String(format: "settings window %@ in %.2f ms", built ? "built" : "shown", Trace.ms(since: started)))
    }

    // MARK: Open panel

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.message = "Choose images or a folder"
        panel.begin { [weak self] response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            self?.open(panel.urls, dedupe: false)
        }
    }

    // MARK: Menu

    private func rebuildMenu(_ keymap: Keymap) {
        guard keymap != lastKeymap else { return }
        lastKeymap = keymap
        let menu = MainMenu.make(keymap: keymap, target: self)
        NSApp.mainMenu = menu
        updates?.refresh(menu.items.first?.submenu)
        if Trace.enabled {
            for top in menu.items {
                let items = (top.submenu?.items ?? []).filter { !$0.isSeparatorItem }.map { item -> String in
                    let mods = item.keyEquivalentModifierMask
                    let key = item.keyEquivalent.isEmpty ? "" : " [\(mods.contains(.command) ? "⌘" : "")\(mods.contains(.shift) ? "⇧" : "")\(mods.contains(.option) ? "⌥" : "")\(mods.contains(.control) ? "⌃" : "")\(item.keyEquivalent.unicodeScalars.map { $0.value < 0x20 || $0.value > 0xF000 ? String(format: "U+%04X", $0.value) : String($0) }.joined())]"
                    return item.title + key
                }
                Trace.log("menu \(top.submenu?.title ?? "?"): \(items.joined(separator: ", "))")
            }
        }
    }

    @objc func performMenuAction(_ sender: NSMenuItem) {
        guard let action = (sender.representedObject as? ActionBox)?.action else { return }
        switch action {
        case .open: showOpenPanel()
        case .quit: NSApp.terminate(nil)
        case .config: showSettings()
        case .close where NSApp.keyWindow.map { $0 !== viewer?.window } == true:
            NSApp.keyWindow?.performClose(nil)  // File › Close Window closes the window in front (Settings)
        default: viewer?.perform(action)
        }
    }

    /// The standard About panel: "Version 20261125-ab2342 (35)", from `CFBundleShortVersionString` and the build
    /// number `CFBundleVersion`.
    @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [:])
    }

    @objc func checkForUpdates(_ sender: Any?) { updates?.checkForUpdates() }

    @objc func performUpdate(_ sender: Any?) { updates?.performUpdate() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(checkForUpdates(_:)): return updates != nil
        case #selector(performUpdate(_:)): return updates?.canPerformUpdate ?? false
        default: break
        }
        guard let action = (item.representedObject as? ActionBox)?.action else { return true }
        // Plain-key equivalents must never fire while another window (open panel, alert) is key.
        let plain = !item.keyEquivalent.isEmpty && item.keyEquivalentModifierMask.isDisjoint(with: [.command, .control])
        guard let viewer else { return action == .open || action == .quit }
        return viewer.canPerform(action, plainKeyEquivalent: plain)
    }
}
