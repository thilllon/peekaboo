import AppKit
import PeekabooCore

/// Wraps an `Action` for `NSMenuItem.representedObject`.
final class ActionBox: NSObject {
    let action: Action
    init(_ action: Action) { self.action = action }
}

/// Programmatic main menu (no nib), built from the live keymap: every item calls the same
/// `perform(_:)` as its key and shows the action's preferred chord. Keys never reach the
/// menu while the viewer window is key (the local key monitor consumes them first); the
/// equivalents matter for display, for mouse use, and for ⌘ shortcuts in other windows.
enum MainMenu {
    /// `target` must implement `performMenuAction(_:)`.
    static func make(keymap: Keymap, target: AnyObject) -> NSMenu {
        let selector = #selector(AppDelegate.performMenuAction(_:))
        func item(_ action: Action, _ title: String? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title ?? KeyLabels.title(action), action: selector, keyEquivalent: "")
            item.target = target
            item.representedObject = ActionBox(action)
            if let chord = KeyLabels.menuChord(for: action, in: keymap),
               let (key, mods) = KeyLabels.menuKeyEquivalent(chord) {
                item.keyEquivalent = key
                item.keyEquivalentModifierMask = mods
            }
            return item
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let menu = NSMenu(title: title)
            for item in items { menu.addItem(item) }
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            return holder
        }

        let main = NSMenu()

        let appMenu = NSMenu(title: "Peekaboo")
        appMenu.addItem(withTitle: "About Peekaboo", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(item(.config, "Settings…"))
        appMenu.addItem(item(.reloadConfig))
        appMenu.addItem(item(.makeDefault))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Peekaboo", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.option, .command]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(item(.quit, "Quit Peekaboo"))
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)

        main.addItem(submenu("File", [
            item(.open), item(.openWithChooser), .separator(),
            item(.trash), item(.reveal), .separator(),
            item(.close),
        ]))

        main.addItem(submenu("Edit", [
            item(.undo), item(.redo), .separator(),
            item(.copyImage), item(.copyPath), item(.copyName), .separator(),
            submenu("Rating", (0...5).map { item(.rate($0)) }),
            submenu("Label", Action.labels.map { item(.label($0)) }),
            submenu("Flag", ["pick", "reject", "none"].map { item(.flag($0)) }),
        ]))

        main.addItem(submenu("View", [
            item(.hud, "Cycle Info Overlay"), item(.hudHide), item(.help), .separator(),
            item(.zoomFit), item(.zoomFill), item(.zoomActual), item(.zoomSet(2)), item(.zoomIn), item(.zoomOut),
            item(.zoomToggle), item(.zoomKeep), .separator(),
            item(.rotateClockwise), item(.rotateCounterClockwise), item(.flipHorizontal), item(.flipVertical), .separator(),
            item(.background), .separator(),
            item(.fullscreen, "Enter Full Screen"), item(.fullscreenNative, "Enter Native Full Screen"),
        ]))

        let jumps = Set((keymap.bindings[.normal] ?? [:]).values.flatMap { $0 }.compactMap { action -> Int? in
            if case .jump(let n) = action { return n }
            return nil
        }).sorted()
        main.addItem(submenu("Go", [
            item(.next), item(.previous), item(.first), item(.last),
        ] + (jumps.isEmpty ? [] : [.separator()] + jumps.map { item(.jump($0)) })))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(item(.help))
        let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        helpItem.submenu = helpMenu
        main.addItem(helpItem)
        NSApp.helpMenu = helpMenu
        return main
    }
}
