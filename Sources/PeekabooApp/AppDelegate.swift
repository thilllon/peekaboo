import AppKit
import PeekabooCore
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var viewer: ViewerWindowController?
    private let configStore = ConfigStore()
    /// Paths opened during launch; AppKit may deliver argv paths *and* an
    /// open-documents event for the same file, so dedupe for a short window.
    private var recentlyOpened: [String: Date] = [:]
    private var openedSomething = false
    private var selfTest: SelfTest?
    private var lastKeymap: Keymap?

    func applicationWillFinishLaunching(_ notification: Notification) {
        configStore.load()
        rebuildMenu(configStore.config.keymap)
        // Build the window now so its creation overlaps the wait for the open-documents event.
        let viewer = ViewerWindowController(configStore: configStore)
        self.viewer = viewer
        viewer.onOpenURLs = { [weak self] urls in self?.open(urls, dedupe: false) }
        viewer.onOpenPanel = { [weak self] in self?.showOpenPanel() }
        configStore.onChange = { [weak self] config in
            self?.viewer?.apply(config)
            self?.rebuildMenu(config.keymap)
        }
        configStore.onError = { [weak self] message in self?.viewer?.toast(message) }
        configStore.startWatching()

        let arguments = Array(CommandLine.arguments.dropFirst())
        if let flag = arguments.firstIndex(of: "--selftest") {
            let path = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : FileManager.default.currentDirectoryPath
            let test = SelfTest(folder: URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true), viewer: viewer)
            selfTest = test
            openedSomething = true
            test.start()
            return
        }
        // `Peekaboo <path>` from a terminal: start immediately.
        let paths = arguments.filter { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }
        if !paths.isEmpty { open(paths.map { URL(fileURLWithPath: $0) }) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
        scheduleScriptedActions()
        // Launched from the Dock or Spotlight without a document: show the drop hint.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.openedSomething else { return }
            self.viewer?.showEmpty(nil)
        }
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
        let fresh = urls.filter { url in
            let key = url.standardizedFileURL.path
            if dedupe, let t = recentlyOpened[key], now.timeIntervalSince(t) < 1.5 { return false }
            recentlyOpened[key] = now
            return true
        }
        guard !fresh.isEmpty else { return }
        openedSomething = true
        if viewer == nil { viewer = ViewerWindowController(configStore: configStore) }
        viewer?.open(fresh)
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
        NSApp.mainMenu = MainMenu.make(keymap: keymap, target: self)
    }

    @objc func performMenuAction(_ sender: NSMenuItem) {
        guard let action = (sender.representedObject as? ActionBox)?.action else { return }
        switch action {
        case .open: showOpenPanel()
        case .quit: NSApp.terminate(nil)
        default: viewer?.perform(action)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = (item.representedObject as? ActionBox)?.action else { return true }
        // Plain-key equivalents must never fire while another window (open panel, alert) is key.
        let plain = !item.keyEquivalent.isEmpty && item.keyEquivalentModifierMask.isDisjoint(with: [.command, .control])
        guard let viewer else { return action == .open || action == .quit }
        return viewer.canPerform(action, plainKeyEquivalent: plain)
    }
}
