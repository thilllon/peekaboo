import AppKit
import PeekabooCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var viewer: ViewerWindowController?
    /// Paths opened during launch; AppKit may deliver argv paths *and* an
    /// open-documents event for the same file, so dedupe for a short window.
    private var recentlyOpened: [String: Date] = [:]
    private var openedSomething = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        // Build the window now so its creation overlaps the wait for the open-documents event.
        viewer = ViewerWindowController()
        // `Peekaboo <path>` from a terminal: start immediately.
        let paths = CommandLine.arguments.dropFirst().filter { FileManager.default.fileExists(atPath: $0) }
        if !paths.isEmpty { open(paths.map { URL(fileURLWithPath: $0) }) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        open(urls)
    }

    /// Stay resident after the last window closes so the next open is instant.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows, openedSomething { viewer?.showWindow(nil) }
        return true
    }

    private func open(_ urls: [URL]) {
        let now = Date()
        let fresh = urls.filter { url in
            let key = url.standardizedFileURL.path
            if let t = recentlyOpened[key], now.timeIntervalSince(t) < 1.5 { return false }
            recentlyOpened[key] = now
            return true
        }
        guard !fresh.isEmpty else { return }
        openedSomething = true
        if viewer == nil { viewer = ViewerWindowController() }
        viewer?.open(fresh)
    }
}
