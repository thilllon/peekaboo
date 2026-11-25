import AppKit

/// How the app puts its windows on screen.
///
/// `.interactive` is the app: a window comes to the front and becomes key, and the app activates.
///
/// `.headless` is for tests, which drive real windows (renderer, pipeline, folder watcher): a window is ordered in, so
/// it renders and `isVisible` holds, but it stays transparent, click-through, behind other windows and off every
/// screen; it never becomes key and the app never activates. A test run therefore never shows a window or takes the
/// keyboard focus (tests also set the `.prohibited` activation policy). The window is never visible
/// (`occlusionState`), so it behaves as a hidden one: an animation does not start playing on its own. Instant full
/// screen keeps the window off screen at the screen's size; native full screen, which takes a Space on a screen, is
/// skipped.
///
/// A stored value, not an environment lookup: the launch path pays one comparison per order-in.
enum Presentation {
    case interactive
    case headless
}

extension NSWindow {
    /// `.headless`: order the window in out of sight. Its class must not constrain its frame to a screen (AppKit moves
    /// a titled window back onto one when it is ordered in): `staysOffScreen` of `ViewerWindow` and `SettingsWindow`.
    func orderInOutOfSight() {
        alphaValue = 0
        ignoresMouseEvents = true
        setFrameOrigin(Self.offScreenOrigin(for: frame.size))
        orderBack(nil)
    }

    /// Bottom-left corner of a frame of `size` that is off every screen: left of all of them.
    static func offScreenOrigin(for size: NSSize) -> NSPoint {
        let screens = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        return NSPoint(x: screens.minX - size.width - 1000, y: screens.minY)
    }
}
