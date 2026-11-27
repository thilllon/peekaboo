import Foundation
import PeekabooCore

/// First launch: let macOS ask for Desktop, Documents and Downloads right after installation (#74).
///
/// macOS asks "Peekaboo would like to access files in your Downloads folder" the first time the app reads each of
/// these folders, which would otherwise be the first time a folder there is browsed, in the middle of work. So at
/// first launch Peekaboo lists each of them once. macOS keeps each answer for the app's signature (a Developer ID
/// release keeps it across updates); browsing a folder that stays refused says how to allow it
/// (`ViewerWindowController.accessDeniedToast`).
///
/// Nothing of it runs on the launch path: the app delegate starts it a second after launch, behind the first frame,
/// next to the updater. The main thread reads one flag (at first launch it also builds three paths and hops to a
/// queue: < 0.1 ms). The folders are listed one after another on a utility queue, because a prompt blocks the thread
/// that touched its folder until it is answered. Only when LaunchServices started the app from its bundle: never in
/// tests (`.headless`), the self-test, scripted runs (`PEEKABOO_ACTIONS` set, even empty), a run from a shell or
/// outside an app bundle.
///
/// Each prompt is a window of UserNotificationCenter, which comes to the front with it and keeps the keyboard; after
/// the last one it stays in front with no window, so a key pressed then (⌘O to open a folder) reaches no app (#92).
/// `start` therefore says on the main thread when the listing has ended, and the app delegate takes the front back.
struct FolderAccessRequest {
    /// Set once every folder was listed, whatever the answers: later launches ask nothing.
    static let doneKey = "PeekabooFolderAccessRequested"

    /// In the order macOS asks for them (built when asked for: a later launch only reads the flag). Their Files &
    /// Folders switches are "Desktop Folder", "Documents Folder" and "Downloads Folder".
    static var folders: [URL] {
        [FileManager.SearchPathDirectory.desktopDirectory, .documentDirectory, .downloadsDirectory]
            .compactMap { FileManager.default.urls(for: $0, in: .userDomainMask).first }
    }

    /// The flag in the app's defaults, read on the main thread and set on the listing queue. Tests keep their own in
    /// memory: a defaults domain of a test would stay behind as a file in ~/Library/Preferences.
    var isDone: () -> Bool = { UserDefaults.standard.bool(forKey: FolderAccessRequest.doneKey) }
    var markDone: () -> Void = { UserDefaults.standard.set(true, forKey: FolderAccessRequest.doneKey) }
    /// Folder of the running bundle: Peekaboo.app, not `swift run` or a test runner.
    var bundleURL = Bundle.main.bundleURL
    /// LaunchServices started the app (Finder, the Dock, `open`, the updater's relaunch): launchd is its parent. macOS
    /// charges what a process started from a shell, Xcode or a debugger reads to that tool, so a run of the bundle's
    /// executable from a terminal (`PEEKABOO_TRACE=1 …/Peekaboo.app/Contents/MacOS/Peekaboo`) would ask for the
    /// terminal, or nothing, and set the flag that Peekaboo.app shares.
    var launchedByLaunchServices = getppid() == 1
    /// A scripted run (smoke runs, screenshots).
    var scripted = getenv("PEEKABOO_ACTIONS") != nil
    /// Reads one folder and returns whether it could; blocks while macOS asks. Tests pass their own: a test never
    /// shows a prompt.
    var touch: (URL) -> Bool = Self.list

    /// This launch asks: the app itself (in front, started by LaunchServices from its bundle, not scripted), and never
    /// before.
    func shouldRequest(presentation: Presentation, selfTest: Bool) -> Bool {
        presentation == .interactive && !selfTest && !scripted && launchedByLaunchServices
            && bundleURL.pathExtension == "app" && !isDone()
    }

    /// Lists the folders on a utility queue when `shouldRequest`, then sets the flag and calls `finished` on the main
    /// queue (every prompt has been answered by then); returns whether it started.
    func start(presentation: Presentation, selfTest: Bool, finished: @escaping () -> Void = {}) -> Bool {
        guard shouldRequest(presentation: presentation, selfTest: selfTest) else { return false }
        let folders = Self.folders, touch = touch, markDone = markDone
        DispatchQueue.global(qos: .utility).async {
            for folder in folders {
                let started = Trace.now()
                let readable = touch(folder)
                Trace.log(String(format: "folder access: %@ %@ after %.1f ms", folder.lastPathComponent,
                                 readable ? "readable" : "not readable", Trace.ms(since: started)))
            }
            markDone()
            DispatchQueue.main.async(execute: finished)
        }
        return true
    }

    /// What the app does once the listing has ended (`start`'s `finished`): take the front back only from
    /// UserNotificationCenter (the prompts' app, left in front with no window) or from itself, never from an app the
    /// user went to meanwhile; and with nothing opened yet, show the open panel, which is what the first launch was
    /// for (the user may have pressed ⌘O while a prompt had the keyboard).
    static func afterListing(frontmost: String?, ownIdentifier: String?, openedSomething: Bool)
        -> (activate: Bool, openPanel: Bool) {
        let mayActivate = frontmost == nil || frontmost == "com.apple.UserNotificationCenter" || frontmost == ownIdentifier
        return (mayActivate, mayActivate && !openedSomething)
    }

    /// Reads the names in `folder`: the access macOS asks about.
    static func list(_ folder: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil
    }
}
