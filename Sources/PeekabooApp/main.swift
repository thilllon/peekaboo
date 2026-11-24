import AppKit
import PeekabooCore
import PeekabooRender

LaunchClock.mainWall = LaunchClock.wallNow()
// Programmatic entry point: no storyboard, no nib, no SwiftUI — nothing to
// unarchive before the first window can appear. GPU setup (device + shader
// compile) starts first, on a background thread, hidden behind AppKit init.
RenderContext.prewarm()
// The folder listing filters names by ImageIO's types: build that table off the main thread now, not in the first listing.
DispatchQueue.global(qos: .userInitiated).async { _ = FolderScanner.supportedExtensions }
let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.run()
