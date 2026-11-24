import AppKit

// Programmatic entry point: no storyboard, no nib, no SwiftUI — nothing to
// unarchive before the first window can appear.
let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.run()
