import AppKit
import Carbon.HIToolbox
import XCTest
@testable import PeekabooApp
@testable import PeekabooCore

/// The Settings window: built only on first use, quickly; its controls write config.toml (a temporary file, never
/// the user's) and follow the file; the shortcut editor records keys and moves taken ones on a second press.
final class SettingsWindowTests: ViewerTestCase {
    private var store: ConfigStore!
    private var controller: SettingsWindowController?
    private var configURL: URL { root.appendingPathComponent("config.toml") }

    override func tearDown() {
        controller?.window?.close()
        controller = nil
        store = nil
        super.tearDown()
    }

    /// `updateStatus`: what `AppDelegate.updateStatus` would say (nil: no updater, as in a development build).
    private func makeController(toml: String? = nil, updateStatus: @escaping () -> String? = { nil }) throws
        -> SettingsWindowController {
        if let toml { try Data(toml.utf8).write(to: configURL) }
        store = ConfigStore(url: configURL)
        store.load()
        let controller = SettingsWindowController(store: store, updateStatus: updateStatus, presentation: .headless) {}
        self.controller = controller
        return controller
    }

    private func fileText() -> String { (try? String(contentsOf: configURL, encoding: .utf8)) ?? "" }

    /// Every control of `type` below `view`.
    private func controls<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { ($0 as? T).map { [$0] } ?? [] } + view.subviews.flatMap { controls(type, in: $0) }
    }

    private func checkbox(_ title: String, in view: NSView) throws -> NSButton {
        try XCTUnwrap(controls(NSButton.self, in: view).first { $0.title == title }, "no checkbox “\(title)”")
    }

    private func key(_ window: NSWindow?, _ keyCode: Int, _ characters: String,
                     modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: UInt16(keyCode))!
    }

    // MARK: Launch cost and opening time

    /// Launch builds no part of the window; ⌘, builds it then, in well under 100 ms on an idle Mac (the bound here is
    /// loose: the test machine may be busy).
    func testTheWindowIsBuiltOnFirstUseOnlyAndOpensFast() throws {
        try Data("[view]\nbackground = \"gray\"\n".utf8).write(to: configURL)
        let previous = ProcessInfo.processInfo.environment["PEEKABOO_CONFIG"]
        setenv("PEEKABOO_CONFIG", configURL.path, 1)
        defer { if let previous { setenv("PEEKABOO_CONFIG", previous, 1) } else { unsetenv("PEEKABOO_CONFIG") } }
        let arguments = CommandLine.arguments
        CommandLine.arguments = [arguments.first ?? "Peekaboo"]
        defer { CommandLine.arguments = arguments }
        let delegate = AppDelegate()
        delegate.presentation = .headless
        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let viewer: ViewerWindowController = try XCTUnwrap(property(delegate, "viewer"))
        defer {
            spin(0.05)  // the drop hint the launch queued, which would show the viewer again after it is closed
            delegate.settings?.window?.close()
            viewer.window?.close()
            spin(0.05)
        }
        XCTAssertNil(delegate.settings, "nothing of the Settings window exists after launch")

        let started = Trace.now()
        viewer.perform(.config)
        let firstMs = Trace.ms(since: started)
        let settings = try XCTUnwrap(delegate.settings, "app.config opens the Settings window")
        XCTAssertTrue(settings.window?.isVisible == true)
        XCTAssertEqual(settings.model.store.url.path, configURL.path)
        settings.window?.close()
        let again = Trace.now()
        delegate.showSettings()
        let secondMs = Trace.ms(since: again)
        var paneMs: [String] = []
        for pane in SettingsWindowController.Pane.allCases {
            let t = Trace.now()
            settings.select(pane)
            settings.window?.displayIfNeeded()
            paneMs.append("\(pane.rawValue) \(String(format: "%.1f", Trace.ms(since: t)))")
        }
        print(String(format: "settings window: first open %.1f ms, re-open %.1f ms; panes: %@", firstMs, secondMs,
                     paneMs.joined(separator: ", ")))
        XCTAssertLessThan(firstMs, 400)
        XCTAssertLessThan(secondMs, 100)
    }

    /// General and Updates show the version line the About panel uses (`BuildInfo.versionLine`, from Info.plist).
    func testTheWindowShowsTheVersion() throws {
        let controller = try makeController()
        for pane in [SettingsWindowController.Pane.general, .updates] {
            controller.select(pane)
            let labels = controls(NSTextField.self, in: controller.pane(pane).view).map(\.stringValue)
            XCTAssertTrue(labels.contains(BuildInfo.versionLine), "\(pane): \(labels)")
        }
    }

    // MARK: Writing and following the file

    func testControlsWriteTheFileAndFollowItsChanges() throws {
        let controller = try makeController(toml: "# mine\n[view]\nbackground = \"gray\"   # keep\n")
        controller.select(.performance)
        let view = controller.pane(.performance).view
        let hdr = try checkbox("Decode HDR photos in HDR (gain maps, PQ / HLG)", in: view)
        XCTAssertEqual(hdr.state, .off)
        hdr.performClick(nil)
        XCTAssertTrue(spin(3) { self.store.config.decodeHDR }, "the click was written and applied")
        XCTAssertEqual(fileText(), "# mine\n[view]\nbackground = \"gray\"   # keep\n\n[decode]\nhdr = true\n")

        // A save in another editor shows in the window.
        try Data("# mine\n[decode]\nhdr = false\n[debug]\ntrace = true\n".utf8).write(to: configURL)
        store.load()
        XCTAssertEqual(hdr.state, .off)
        XCTAssertEqual(try checkbox("Trace logging (timestamped lines on stderr)", in: view).state, .on)

        // Viewer pane: a pop-up writes its key.
        controller.select(.viewer)
        let popup = try XCTUnwrap(controls(NSPopUpButton.self, in: controller.pane(.viewer).view).first { $0.itemTitles.contains("Checkerboard") })
        popup.selectItem(withTitle: "Checkerboard")
        _ = popup.target?.perform(popup.action, with: popup)
        XCTAssertTrue(spin(3) { self.store.config.background == "checker" })
        XCTAssertTrue(fileText().contains("[view]\nbackground = \"checker\"\n"), fileText())
    }

    func testAFileWithAnErrorShowsItAndEditsWait() throws {
        let broken = "[view]\nbackground = \"pink\"\n"
        let controller = try makeController(toml: broken)
        XCTAssertNotNil(store.lastError)
        XCTAssertNotNil(controller.model.problem)
        controller.select(.viewer)
        let banner = controls(NSTextField.self, in: try XCTUnwrap(controller.window?.contentView))
            .first { $0.stringValue.contains("view.background must be one of") }
        XCTAssertNotNil(banner, "the error is shown above the panes")
        controller.model.set("keep_zoom", in: "view", to: .bool(true))
        XCTAssertTrue(spin(3) { controller.model.problem?.contains("view.background") == true && self.fileText() == broken })
        spin(0.2)
        XCTAssertEqual(fileText(), broken, "not written while the file has an error")
    }

    /// A refused edit wrote nothing, so its control shows the file's value again; fixing the file clears the banner.
    func testARefusedEditRevertsItsControlAndTheFixedFileClearsTheBanner() throws {
        let controller = try makeController(toml: "[view]\nbackground = \"pink\"\n")
        controller.select(.viewer)
        let keep = try checkbox("Keep zoom and position when moving to another image", in: controller.pane(.viewer).view)
        keep.performClick(nil)
        XCTAssertEqual(keep.state, .on, "clicked")
        XCTAssertTrue(spin(3) { keep.state == .off }, "the edit was refused: the checkbox shows the file's value again")
        try Data("[view]\nbackground = \"gray\"\n".utf8).write(to: configURL)
        store.load()
        XCTAssertNil(controller.model.problem)

        // A refusal of a valid file (the slot does not exist) is shown until the file loads again.
        controller.model.edit { try $0.bind([KeyChord(key: "y")], to: [.move("nowhere")], context: .normal) }
        XCTAssertTrue(spin(3) { controller.model.problem?.contains("unknown slot") == true }, "\(String(describing: controller.model.problem))")
        XCTAssertTrue(controller.model.problem?.hasPrefix("This change was not saved") == true)
        try Data("[view]\nbackground = \"checker\"\n".utf8).write(to: configURL)
        store.load()
        XCTAssertNil(controller.model.problem, "no stale message once the file loaded")
    }

    /// While a Settings text field is being edited, the menu leaves it the keys text editing uses: ⌘⌫ deletes text
    /// there instead of trashing the image in the viewer, ⌘↑ moves the caret instead of going to the first image.
    func testTypingInSettingsKeepsTheViewersMenuKeysAway() throws {
        let viewer = try makeViewer()
        openAndWait(viewer, [writeImage(folder.appendingPathComponent("a.jpg"), width: 900, height: 600, gray: 0.4)])
        let controller = try makeController()
        controller.select(.files)
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(viewer.canPerform(.trash, plainKeyEquivalent: false, keyWindow: window), "nothing is being typed")
        let field = try XCTUnwrap(controls(NSTextField.self, in: controller.pane(.files).view).first { $0.isEditable })
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertTrue(window.firstResponder is NSText, "the field is being edited")
        XCTAssertFalse(viewer.canPerform(.trash, plainKeyEquivalent: false, keyWindow: window))
        XCTAssertFalse(viewer.canPerform(.first, plainKeyEquivalent: false, keyWindow: window))
        XCTAssertTrue(viewer.canPerform(.quit, plainKeyEquivalent: false, keyWindow: window))
        XCTAssertTrue(viewer.canPerform(.config, plainKeyEquivalent: false, keyWindow: window))
        XCTAssertTrue(viewer.canPerform(.trash, plainKeyEquivalent: false, keyWindow: viewer.window), "the viewer in front")
    }

    /// The rows of [slots] are not rebuilt while one of their fields is being edited: a rename keeps the value just
    /// written in the same row, and the row then edits the renamed entry.
    func testRenamingASlotKeepsTheValueJustWritten() throws {
        let controller = try makeController(toml: "[slots]\n1 = \"~/A\"\n")
        controller.select(.files)
        let view = controller.pane(.files).view
        func field(_ text: String) throws -> NSTextField {
            try XCTUnwrap(controls(NSTextField.self, in: view).first { $0.isEditable && $0.stringValue == text }, text)
        }
        func commit(_ field: NSTextField, _ text: String) throws {
            field.stringValue = text
            try XCTUnwrap(field.delegate as? FieldCommitter)
                .controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        }
        let name = try field("1")
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.makeFirstResponder(name), "a field of the rows is being edited")
        try commit(field("~/A"), "~/B")
        XCTAssertTrue(spin(3) { self.store.config.slots == ["1": "~/B"] })
        window.makeFirstResponder(nil)  // the name field ends editing unchanged: nothing loads, the rows stay
        try commit(name, "keep")
        XCTAssertTrue(spin(3) { self.store.config.slots["keep"] != nil })
        XCTAssertEqual(store.config.slots, ["keep": "~/B"], "the rename kept the new value")
        try commit(field("~/B"), "~/C")
        XCTAssertTrue(spin(3) { self.store.config.slots == ["keep": "~/C"] }, "\(store.config.slots)")
    }

    /// The memory budget applies at once: it is written when editing ends, never a value typed on the way.
    func testTheMemoryFieldWritesWhenEditingEnds() throws {
        let controller = try makeController(toml: "[cache]\nmemory_mb = 4096\n")
        controller.select(.performance)
        let field = try XCTUnwrap(controls(NSTextField.self, in: controller.pane(.performance).view)
            .first { $0.isEditable && $0.stringValue == "4096" })
        let committer = try XCTUnwrap(field.delegate as? FieldCommitter)
        field.stringValue = "409"
        committer.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        spin(0.9)
        XCTAssertEqual(store.config.cacheBudgetMB, 4096, "not written while typing")
        committer.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        XCTAssertTrue(spin(3) { self.store.config.cacheBudgetMB == 409 })
    }

    /// `[updates]` is read like every table (no unknown-key warning); the pane shows the updater's status when it opens
    /// and each one it posts after, and Check Now asks the updater through its notification.
    func testUpdatesPaneFollowsTheUpdater() throws {
        let controller = try makeController(toml: "", updateStatus: { "Peekaboo 20261125-000025 · checks for updates automatically" })
        controller.select(.updates)
        let pane = try XCTUnwrap(controller.pane(.updates) as? UpdatesPane)
        XCTAssertEqual(pane.status.stringValue, "Peekaboo 20261125-000025 · checks for updates automatically", "the status now")
        try checkbox("Check for updates automatically", in: pane.view).performClick(nil)
        XCTAssertTrue(spin(3) { !self.store.config.updates.check }, "written and applied")
        XCTAssertEqual(fileText(), "[updates]\ncheck = false\n")
        XCTAssertNil(store.lastWarning)
        XCTAssertEqual(try checkbox("Check for updates automatically", in: pane.view).state, .off)
        let checked = expectation(forNotification: Updater.checkNowNotification, object: nil)
        let checkNow = try XCTUnwrap(pane.checkNow)
        XCTAssertTrue(checkNow.isEnabled)
        checkNow.performClick(nil)
        wait(for: [checked], timeout: 1)
        NotificationCenter.default.post(name: Updater.statusNotification, object: nil, userInfo: ["status": "Up to date (20261125-000025)"])
        XCTAssertEqual(pane.status.stringValue, "Up to date (20261125-000025)")
    }

    /// Without an updater (a development build) Check Now is off; the updater's first status turns it on (it starts a
    /// second after launch, so the window may have opened before it).
    func testWithoutAnUpdaterCheckNowWaits() throws {
        let controller = try makeController(toml: "")
        controller.select(.updates)
        let pane = try XCTUnwrap(controller.pane(.updates) as? UpdatesPane)
        XCTAssertEqual(pane.status.stringValue, UpdatesPane.noUpdater)
        XCTAssertEqual(pane.checkNow?.isEnabled, false)
        NotificationCenter.default.post(name: Updater.statusNotification, object: nil, userInfo: ["status": "Checking for updates…"])
        XCTAssertEqual(pane.status.stringValue, "Checking for updates…")
        XCTAssertEqual(pane.checkNow?.isEnabled, true)
        controller.select(.general)
        controller.select(.updates)
        XCTAssertEqual(pane.status.stringValue, "Checking for updates…", "a status heard stays")
    }

    /// Settings › Updates against a real updater (a fake Peekaboo.app and a manifest file, no network): the status when
    /// the pane opens, Check Now, and the outcome.
    func testCheckNowRunsTheUpdatersCheck() throws {
        try publishManifest(in: root, version: releaseVersion(25))
        defer { unsetenv("PEEKABOO_UPDATE_URL") }
        let updater = try XCTUnwrap(Updater(settings: AppConfig.Updates(check: false), bundle: try fakePeekabooApp(in: root, version: releaseVersion(25)),
                                            cache: root.appendingPathComponent("cache")))
        let updates = UpdateController(updater: updater) { nil }
        let controller = try makeController(toml: "[updates]\ncheck = false\n", updateStatus: { updater.status })
        controller.select(.updates)
        let pane = try XCTUnwrap(controller.pane(.updates) as? UpdatesPane)
        XCTAssertEqual(pane.status.stringValue, "Peekaboo 20261125-000025 · automatic update checks are off")
        try XCTUnwrap(pane.checkNow).performClick(nil)
        XCTAssertTrue(spin(10) { pane.status.stringValue == "Up to date (20261125-000025)" }, pane.status.stringValue)
        XCTAssertEqual(updater.phase, .upToDate)
        withExtendedLifetime(updates) {}
    }

    // MARK: Shortcut editor

    private func shortcuts(_ controller: SettingsWindowController) -> ShortcutsPane {
        controller.select(.keyboard)
        return controller.pane(.keyboard) as! ShortcutsPane
    }

    /// "Keys in use are named; pressing them again moves them."
    func testATakenKeyIsNamedAndMovesOnTheSecondPress() throws {
        let controller = try makeController(toml: "")
        let pane = shortcuts(controller)
        pane.record([.copyName])
        let f = key(controller.window, kVK_ANSI_F, "f")
        pane.recorded(f)
        XCTAssertEqual(pane.pendingMove?.sequence, [KeyChord(key: "f")])
        XCTAssertTrue(pane.status.stringValue.contains("F is used by “Full Screen”"), pane.status.stringValue)
        XCTAssertEqual(store.config.keymap.resolve([KeyChord(key: "f")], context: .normal), .actions([.fullscreen]), "nothing moved yet")
        pane.recorded(f)
        XCTAssertNil(pane.recording)
        XCTAssertTrue(spin(3) { self.store.config.keymap.resolve([KeyChord(key: "f")], context: .normal) == .actions([.copyName]) })
        XCTAssertEqual(fileText(), "[keys]\n\"f\" = \"file.copy_name\"\n")
        XCTAssertTrue(pane.status.stringValue.contains("moved from “Full Screen”"), pane.status.stringValue)
        XCTAssertEqual(store.config.keymap.resolve([KeyChord(key: "return")], context: .normal), .actions([.fullscreen]))
    }

    func testAFreeKeyIsBoundAtOnceAndEscCancels() throws {
        let controller = try makeController(toml: "")
        let pane = shortcuts(controller)
        pane.record([.copyName])
        pane.recorded(key(controller.window, kVK_Escape, "\u{1b}"))
        XCTAssertNil(pane.recording, "Esc cancels")
        pane.record([.copyName])
        pane.recorded(key(controller.window, kVK_ANSI_Y, "y", modifiers: [.command, .shift]))
        XCTAssertTrue(spin(3) { self.store.config.keymap.resolve(try! KeyChord.parseSequence("cmd+shift+y"), context: .normal) == .actions([.copyName]) })
        XCTAssertTrue(fileText().contains("\"cmd+shift+y\" = \"file.copy_name\"\n"), fileText())
        // The row lists it, marked as changed.
        let row = try XCTUnwrap(pane.rows().first { $0.actions == [.copyName] })
        XCTAssertEqual(row.sequences, [try KeyChord.parseSequence("cmd+shift+y")])
        XCTAssertTrue(row.modified)
        // Reset gives the action its built-in keys (none) again.
        pane.reset(row)
        XCTAssertTrue(spin(3) { self.store.config.keymap == Keymap.default })
    }

    func testRemovingABuiltInKeyWritesNone() throws {
        let controller = try makeController(toml: "")
        let pane = shortcuts(controller)
        let row = try XCTUnwrap(pane.rows().first { $0.actions == [.hudHide] })
        XCTAssertEqual(row.sequences, [[KeyChord(key: "tab")]])
        pane.remove([KeyChord(key: "tab")], from: row)
        XCTAssertTrue(spin(3) { self.store.config.keymap.resolve([KeyChord(key: "tab")], context: .normal) == .unbound })
        XCTAssertTrue(fileText().contains("\"tab\" = \"none\"\n"), fileText())
    }

    /// The file Peekaboo writes lists the keymap: its untouched lines are not "changed", removing a key deletes it from
    /// its line, Change… puts the new key in the old one's place, ↺ and Reset All write the default lines back.
    func testTheShortcutEditorEditsAFileThatListsTheKeymapInPlace() throws {
        let controller = try makeController(toml: ConfigFile.defaultText)
        let pane = shortcuts(controller)
        XCTAssertEqual(pane.rows().filter(\.modified).map(\.id), [], "the defaults as written are the built-in keys")
        let hide = try XCTUnwrap(pane.rows().first { $0.actions == [.hudHide] })
        pane.remove([KeyChord(key: "tab")], from: hide)
        XCTAssertTrue(spin(3) { self.store.config.keymap.resolve([KeyChord(key: "tab")], context: .normal) == .unbound })
        XCTAssertEqual(fileText(), ConfigFile.defaultText.replacingOccurrences(of: "\"view.hud_hide\" = \"tab\"\n", with: ""))
        XCTAssertTrue(try XCTUnwrap(pane.rows().first { $0.actions == [.hudHide] }).modified)

        pane.record([.fullscreen], replacing: [KeyChord(key: "f")])
        pane.recorded(key(controller.window, kVK_ANSI_G, "g"))
        XCTAssertTrue(spin(3) { self.store.config.keymap.resolve([KeyChord(key: "g")], context: .normal) == .actions([.fullscreen]) })
        XCTAssertTrue(fileText().contains("\"view.fullscreen\" = [\"g\", \"return\", \"ctrl+cmd+f\"]\n"), fileText())
        XCTAssertEqual(store.config.keymap.resolve([KeyChord(key: "f")], context: .normal), .unbound)

        pane.reset(try XCTUnwrap(pane.rows().first { $0.actions == [.fullscreen] }))
        XCTAssertTrue(spin(3) { self.fileText().contains("\"view.fullscreen\" = [\"f\", \"return\", \"ctrl+cmd+f\"]\n") }, fileText())
        controller.model.edit { try $0.resetBindings() }
        XCTAssertTrue(spin(3) { self.fileText() == ConfigFile.defaultText && self.store.config.keymap == Keymap.default }, fileText())
    }

    /// Rows are every parameterless action plus whatever the keymap binds (parameterized ones, action lists), so new
    /// actions appear without a hard-coded list.
    func testRowsListEveryActionDynamically() throws {
        let controller = try makeController(toml: "[keys]\n\"ctrl+x o\" = \"exec:open -a Preview {path}\"\n")
        let rows = shortcuts(controller).rows()
        let ids = Set(rows.map(\.id))
        for id in Action.simpleIDs where id != "none" { XCTAssertTrue(ids.contains(id), id) }
        XCTAssertTrue(ids.contains("nav.jump:+10"))
        XCTAssertTrue(ids.contains("meta.rate:3 + nav.next"))
        let exec = try XCTUnwrap(rows.first { $0.id == "exec:open -a Preview {path}" })
        XCTAssertEqual(exec.group, "exec")
        XCTAssertEqual(exec.sequences, [try KeyChord.parseSequence("ctrl+x o")])
        XCTAssertEqual(ShortcutsPane.label(exec.sequences[0]), "⌃X O")
    }

    /// The animation actions are listed under View with their built-in keys, and a key they use is named when it is
    /// recorded for another action.
    func testAnimationActionsAreListedWithTheirKeys() throws {
        let controller = try makeController(toml: "")
        let pane = shortcuts(controller)
        for (action, key) in [(Action.playPause, "k"), (.frameNext, "."), (.framePrevious, ",")] {
            let row = try XCTUnwrap(pane.rows().first { $0.actions == [action] }, action.id)
            XCTAssertEqual(row.group, "view", action.id)
            XCTAssertEqual(row.title, KeyLabels.title(action))
            XCTAssertEqual(row.sequences, [try KeyChord.parseSequence(key)], action.id)
            XCTAssertFalse(row.modified, action.id)
        }
        pane.record([.copyName])
        pane.recorded(key(controller.window, kVK_ANSI_K, "k"))
        XCTAssertTrue(pane.status.stringValue.contains("K is used by “Play / Pause Animation”"), pane.status.stringValue)
        pane.cancelRecording()
    }

    /// The picks actions (#76) are listed with their built-in keys: the view under View, copying every pick under Files.
    func testPicksActionsAreListedWithTheirKeys() throws {
        let controller = try makeController(toml: "")
        let pane = shortcuts(controller)
        for (action, group, key) in [(Action.picksOnly, "view", "v"), (.copyPicks("ask"), "file", "shift+c")] {
            let row = try XCTUnwrap(pane.rows().first { $0.actions == [action] }, action.id)
            XCTAssertEqual(row.group, group, action.id)
            XCTAssertEqual(row.title, KeyLabels.title(action))
            XCTAssertEqual(row.sequences, [try KeyChord.parseSequence(key)], action.id)
            XCTAssertFalse(row.modified, action.id)
        }
    }

    /// The window handles text editing shortcuts itself (the app menu has no Edit › Paste), and ⌘W closes it rather
    /// than the viewer.
    func testCommandWClosesTheSettingsWindow() throws {
        let controller = try makeController()
        controller.show()
        let window = try XCTUnwrap(controller.window as? SettingsWindow)
        XCTAssertTrue(window.performKeyEquivalent(with: key(window, kVK_ANSI_W, "w", modifiers: .command)))
        XCTAssertFalse(window.isVisible)
    }
}
