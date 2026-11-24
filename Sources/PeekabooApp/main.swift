import AppKit
import PeekabooRender

// Programmatic entry point: no storyboard, no nib, no SwiftUI — nothing to
// unarchive before the first window can appear. GPU setup (device + shader
// compile) starts first, on a background thread, hidden behind AppKit init.
RenderContext.prewarm()
let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.run()
