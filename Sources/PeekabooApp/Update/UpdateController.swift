import AppKit
import PeekabooCore

/// The updater's UI: the banner in the viewer window, the app-menu items, toasts for manual checks, and the
/// Settings window's notifications. Created after launch; costs nothing until an update shows up.
final class UpdateController {
    let updater: Updater
    private let viewer: () -> ViewerWindowController?
    private var banner: UpdateBanner?
    /// Versions whose banner was shown in this run (an automatic re-check does not show it again).
    private var bannered: Set<AppVersion> = []
    private var observer: NSObjectProtocol?
    private static let bannerSeconds: TimeInterval = 30

    /// nil outside Peekaboo.app (`swift run`, tests).
    init?(settings: AppConfig.Updates, viewer: @escaping () -> ViewerWindowController?) {
        guard let updater = Updater(settings: settings) else { return nil }
        self.updater = updater
        self.viewer = viewer
        updater.onChange = { [weak self] phase, show in self?.changed(phase, show: show) }
        observer = NotificationCenter.default.addObserver(forName: Updater.checkNowNotification, object: nil, queue: .main) {
            [weak self] _ in self?.updater.checkNow(show: false)
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    // MARK: Menu

    /// "Check for Updates…".
    func checkForUpdates() {
        updater.checkNow(show: true)
    }

    /// The update item of the app menu: restart, download, or open the release page.
    func performUpdate() {
        switch updater.phase {
        case .ready: restart()
        case .available(_, nil): updater.downloadNow()
        case .available(let manifest, _?): NSWorkspace.shared.open(manifest.downloadPage)
        default: break
        }
    }

    var canPerformUpdate: Bool {
        switch updater.phase {
        case .ready, .available: return true
        default: return false
        }
    }

    /// Title and visibility of the update item in `menu` (the app menu), from the current phase.
    func refresh(_ menu: NSMenu?) {
        guard let item = menu?.items.first(where: { $0.identifier == MainMenu.updateItem }) else { return }
        switch updater.phase {
        case .ready(let manifest, _): item.title = "Restart to Update to \(manifest.version)"
        case .available(let manifest, nil): item.title = "Update to \(manifest.version)…"
        case .available(let manifest, _?): item.title = "Download Peekaboo \(manifest.version)…"
        case .downloading(let manifest): item.title = "Downloading \(manifest.version)…"
        default:
            item.isHidden = true
            return
        }
        item.isHidden = false
    }

    // MARK: Phase changes

    private func changed(_ phase: Updater.Phase, show: Bool) {
        refresh(NSApp.mainMenu?.items.first?.submenu)
        if show, phase != .idle { viewer()?.toast(updater.status) }
        switch phase {
        case .ready(let manifest, _):
            showBanner(manifest, "Peekaboo \(manifest.version) is ready", again: show,
                       [("Restart to Update", { [weak self] in self?.restart() }), ("Later", {})])
        case .available(let manifest, nil):
            showBanner(manifest, "Peekaboo \(manifest.version) is available", again: show,
                       [("Update", { [weak self] in self?.updater.downloadNow() }), ("Later", {})])
        case .available(let manifest, _?) where manifest.runs(on: ProcessInfo.processInfo.operatingSystemVersion):
            showBanner(manifest, "Peekaboo \(manifest.version) is available", again: show,
                       [("Download…", { NSWorkspace.shared.open(manifest.downloadPage) }), ("Later", {})])
        case .upToDate, .failed, .downloading:
            hideBanner()
        default:
            break
        }
    }

    private func restart() {
        let file = viewer()?.pipeline.currentFile?.url
        guard updater.restartToUpdate(reopening: file) else { return }
        NSApp.terminate(nil)
    }

    private func showBanner(_ manifest: UpdateManifest, _ text: String, again: Bool,
                            _ buttons: [(title: String, action: () -> Void)]) {
        guard again || !bannered.contains(manifest.version), let content = viewer()?.window?.contentView else { return }
        bannered.insert(manifest.version)
        hideBanner()
        // Every button also dismisses the banner.
        let banner = UpdateBanner(text: text, buttons: buttons.map { button in
            (button.title, { [weak self] in
                self?.hideBanner()
                button.action()
            })
        })
        banner.show(in: content)
        self.banner = banner
        Trace.log("update: banner “\(text)”")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.bannerSeconds) { [weak self, weak banner] in
            guard let self, let banner, self.banner === banner else { return }
            self.hideBanner()
        }
    }

    private func hideBanner() {
        banner?.removeFromSuperview()
        banner = nil
    }
}
