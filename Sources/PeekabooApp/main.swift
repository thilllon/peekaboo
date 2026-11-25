import AppKit
import PeekabooCore
import PeekabooRender

// `Peekaboo --install-update …`: the update installer, started by a quitting app (no window, no GPU).
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == UpdateInstaller.helperFlag {
    exit(UpdateInstaller.runHelper(Array(CommandLine.arguments.dropFirst())))
}
LaunchClock.mainWall = LaunchClock.wallNow()
// Programmatic entry point: no storyboard, no nib, no SwiftUI — nothing to
// unarchive before the first window can appear. GPU setup (device + shader
// compile) starts first, on a background thread, hidden behind AppKit init.
RenderContext.prewarm()
// The folder listing filters names by ImageIO's types: build that table off the main thread now, not in the first listing.
// Then let a 16 px HEIC take the first HEVC decode's ~50 ms wait for the hardware decoder, behind AppKit's start, at
// utility QoS: queued once the table is built, so ImageIO's one-time setup has run at userInitiated and no decode waits
// for it on the slower thread. A HEIC opened at launch shows ~50 ms sooner, a JPEG launch is unchanged (docs/DESIGN.md §2).
DispatchQueue.global(qos: .userInitiated).async {
    _ = FolderScanner.supportedExtensions
    DispatchQueue.global(qos: .utility).async { HEVCWarmUp.run() }
}
let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.run()
