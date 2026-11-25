import Foundation
import PeekabooCore

/// First launch: let macOS ask for Desktop, Documents and Downloads right after installation (#74).
///
/// macOS asks "Peekaboo would like to access files in your Downloads folder" the first time the app reads each of
/// these folders, which would otherwise be the first time a folder there is browsed, in the middle of work. So at
/// first launch Peekaboo lists each of them once. macOS keeps each answer for the app's signature (a Developer ID
/// release keeps it across updates); browsing a folder that stays refused shows a toast that says how to allow it
/// (`ViewerWindowController.accessDeniedToast`).
///
/// Nothing of it runs on the launch path: the app delegate starts it a second after launch, behind the first frame,
/// next to the updater. The main thread reads one flag (at first launch it also builds three paths and hops to a
/// queue: < 0.1 ms). The folders are listed one after another on a utility queue, because a prompt blocks the thread
/// that touched its folder until it is answered. Never in tests (`.headless`), the self-test, scripted runs
/// (`PEEKABOO_ACTIONS` set, even empty) or outside an app bundle.
struct FolderAccessRequest {
    /// Set once every folder was listed, whatever the answers: later launches ask nothing.
    static let doneKey = "PeekabooFolderAccessRequested"

    var defaults = UserDefaults.standard
    /// Folder of the running bundle: Peekaboo.app, not `swift run` or a test runner.
    var bundleURL = Bundle.main.bundleURL
    /// A scripted run (smoke runs, screenshots).
    var scripted = getenv("PEEKABOO_ACTIONS") != nil
    /// In the order macOS asks for them (built when asked for: a later launch only reads the flag).
    var folders: [URL] {
        [FileManager.SearchPathDirectory.desktopDirectory, .documentDirectory, .downloadsDirectory]
            .compactMap { FileManager.default.urls(for: $0, in: .userDomainMask).first }
    }
    /// Reads one folder and returns whether it could; blocks while macOS asks. Tests pass their own: a test never
    /// shows a prompt.
    var touch: (URL) -> Bool = Self.list

    /// This launch asks: the app itself (in front, from its bundle, not scripted), and never before.
    func shouldRequest(presentation: Presentation, selfTest: Bool) -> Bool {
        presentation == .interactive && !selfTest && !scripted && bundleURL.pathExtension == "app"
            && !defaults.bool(forKey: Self.doneKey)
    }

    /// Lists the folders on a utility queue when `shouldRequest`, then sets the flag; returns whether it started.
    func start(presentation: Presentation, selfTest: Bool) -> Bool {
        guard shouldRequest(presentation: presentation, selfTest: selfTest) else { return false }
        let folders = folders, touch = touch, defaults = defaults
        DispatchQueue.global(qos: .utility).async {
            for folder in folders {
                let started = Trace.now()
                let readable = touch(folder)
                Trace.log(String(format: "folder access: %@ %@ after %.1f ms", folder.lastPathComponent,
                                 readable ? "readable" : "not readable", Trace.ms(since: started)))
            }
            defaults.set(true, forKey: Self.doneKey)
        }
        return true
    }

    /// Reads the names in `folder`: the access macOS asks about.
    static func list(_ folder: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil
    }
}
