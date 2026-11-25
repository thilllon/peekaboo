import AppKit
import PeekabooCore

/// The updater's UI: the banner in the viewer window, the app-menu items, toasts for manual checks, and the
/// Settings window's notifications. Created after launch; costs nothing until an update shows up.
final class UpdateController {
    let updater: Updater
    private let viewer: () -> ViewerWindowController?
    private var banner: UpdateBanner?
    /// Banners shown in this run (an automatic re-check does not show one again).
    private var bannered: Set<String> = []
    /// The banner of the latest phase, waiting for a pause in the input (`showPending`).
    private var pending: (text: String, buttons: [(title: String, action: () -> Void)])?
    private var waitsForQuiet = false
    private var observer: NSObjectProtocol?
    private static let bannerSeconds: TimeInterval = 30
    /// An automatic banner waits until the app has taken no event (key, pointer, gesture) for this long.
    private static let quietSeconds: TimeInterval = 1.5
    /// Seconds since the last event the app took from its queue (internal for tests).
    var secondsSinceInput: () -> TimeInterval = {
        ProcessInfo.processInfo.systemUptime - (NSApp?.currentEvent?.timestamp ?? 0)
    }

    init(updater: Updater, viewer: @escaping () -> ViewerWindowController?) {
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
        if updater.ready != nil { return restart() }
        switch updater.phase {
        case .available(_, nil): updater.downloadNow()
        case .available(let manifest, _?): NSWorkspace.shared.open(manifest.downloadPage)
        default: break
        }
    }

    var canPerformUpdate: Bool {
        if updater.ready != nil { return true }
        if case .available = updater.phase { return true }
        return false
    }

    /// Title and visibility of the update item in `menu` (the app menu).
    func refresh(_ menu: NSMenu?) {
        guard let item = menu?.items.first(where: { $0.identifier == MainMenu.updateItem }) else { return }
        if let ready = updater.ready {
            item.title = "Restart to Update to \(ready.manifest.version)"
        } else {
            switch updater.phase {
            case .available(let manifest, nil): item.title = "Update to \(manifest.version)…"
            case .available(let manifest, _?): item.title = "Download Peekaboo \(manifest.version)…"
            case .downloading(let manifest): item.title = "Downloading \(manifest.version)…"
            default:
                item.isHidden = true
                return
            }
        }
        item.isHidden = false
    }

    // MARK: Phase changes

    private func changed(_ phase: Updater.Phase, show: Bool) {
        refresh(NSApp?.mainMenu?.items.first?.submenu)
        if show, phase != .idle { viewer()?.toast(updater.status) }
        switch phase {
        case .ready(let manifest, _):
            showBanner("Peekaboo \(manifest.version) is ready — it installs when you quit", again: show,
                       [("Restart to Update", { [weak self] in self?.restart() }), ("Later", {})])
        case .available(let manifest, nil):
            showBanner("Peekaboo \(manifest.version) is available", again: show,
                       [("Update", { [weak self] in self?.updater.downloadNow() }), ("Later", {})])
        case .available(let manifest, _?) where manifest.runs(on: ProcessInfo.processInfo.operatingSystemVersion):
            showBanner("Peekaboo \(manifest.version) is available", again: show,
                       [("Download…", { NSWorkspace.shared.open(manifest.downloadPage) }), ("Later", {})])
        case .upToDate, .downloading:
            hideBanner()
        case .failed where updater.ready == nil:
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

    private func showBanner(_ text: String, again: Bool,
                            _ buttons: [(title: String, action: () -> Void)]) {
        guard again || !bannered.contains(text) else {
            pending = nil  // an older phase's banner is stale now
            return
        }
        pending = (text, buttons)
        showPending(now: again)
    }

    /// Show the pending banner: at once when the user asked for it, otherwise once the input has paused. Building it
    /// (an AppKit text field and buttons) blocks the main thread for 5–20 ms, which must not land between two images
    /// the user is flipping through or in a zoom gesture.
    private func showPending(now: Bool = false) {
        guard let pending, let content = viewer()?.window?.contentView else { return }
        let quiet = secondsSinceInput()
        if !now, quiet < Self.quietSeconds {
            guard !waitsForQuiet else { return }
            waitsForQuiet = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.quietSeconds - quiet) { [weak self] in
                self?.waitsForQuiet = false
                self?.showPending()
            }
            return
        }
        hideBanner()
        bannered.insert(pending.text)
        // Every button also dismisses the banner.
        let banner = UpdateBanner(text: pending.text, buttons: pending.buttons.map { button in
            (button.title, { [weak self] in
                self?.hideBanner()
                button.action()
            })
        })
        banner.show(in: content)
        self.banner = banner
        Trace.log("update: banner “\(pending.text)”")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.bannerSeconds) { [weak self, weak banner] in
            guard let self, let banner, self.banner === banner else { return }
            self.hideBanner()
        }
    }

    private func hideBanner() {
        pending = nil
        banner?.removeFromSuperview()
        banner = nil
    }
}
