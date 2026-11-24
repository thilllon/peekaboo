import AppKit
import PeekabooCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []
    /// Paths opened during launch; AppKit may deliver argv paths *and* an
    /// open-documents event for the same file, so dedupe for a short window.
    private var recentlyOpened: [String: Date] = [:]

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        // `Peekaboo <path>` from a terminal: start as early as possible.
        let paths = CommandLine.arguments.dropFirst().filter { FileManager.default.fileExists(atPath: $0) }
        if !paths.isEmpty { open(urls: paths.map { URL(fileURLWithPath: $0) }) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        open(urls: urls)
    }

    /// Stay resident after the last window closes so the next open is instant.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func open(urls: [URL]) {
        let now = Date()
        let fresh = urls.filter { url in
            let key = url.standardizedFileURL.path
            if let t = recentlyOpened[key], now.timeIntervalSince(t) < 1.5 { return false }
            recentlyOpened[key] = now
            return true
        }
        guard let first = fresh.first else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.title = first.lastPathComponent
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
    }
}
