import AppKit
import PeekabooCore
import UniformTypeIdentifiers

// MARK: General

/// Default viewer per image type, the config file, the version.
final class GeneralPane: SettingsForm, SettingsPane {
    private let openConfigFile: () -> Void
    private var statuses: [String: NSTextField] = [:]
    private var makeButtons: [String: NSButton] = [:]
    private var result: NSTextField?
    private(set) lazy var view: NSView = build()

    init(model: SettingsModel, openConfigFile: @escaping () -> Void) {
        self.openConfigFile = openConfigFile
        super.init(model: model)
    }

    /// Short names of the document types (Info.plist); others by their identifier's last part.
    private static let typeNames = [
        "public.jpeg": "JPEG", "public.png": "PNG", "public.apng": "APNG", "public.heic": "HEIC",
        "public.heics": "HEIC sequence", "public.heif": "HEIF", "public.heifs": "HEIF sequence", "public.avci": "AVCI",
        "public.avif": "AVIF", "public.avis": "AVIF sequence", "org.webmproject.webp": "WebP", "public.jpeg-xl": "JPEG XL",
        "public.tiff": "TIFF", "com.compuserve.gif": "GIF",
        "com.microsoft.bmp": "BMP", "com.adobe.photoshop-image": "Photoshop", "com.adobe.raw-image": "DNG",
        "public.camera-raw-image": "Camera RAW", "com.ilm.openexr-image": "OpenEXR", "public.jpeg-2000": "JPEG 2000",
    ]

    private func build() -> NSView {
        section("Default viewer")
        let types = DefaultViewer.contentTypes
        let canChange = DefaultViewer.bundleID != nil
        for type in types {
            let status = NSTextField(labelWithString: "…")
            status.textColor = .secondaryLabelColor
            status.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
            let make = button("Make Default") { [weak self] in self?.makeDefault([type]) }
            make.controlSize = .small
            make.isEnabled = false
            statuses[type] = status
            makeButtons[type] = make
            row(Self.typeNames[type] ?? type.split(separator: ".").last.map { $0.uppercased() } ?? type, status, make)
        }
        let all = button("Make Peekaboo the Default for All Types") { [weak self] in self?.makeDefault(types) }
        all.isEnabled = canChange && !types.isEmpty
        row("", all)
        result = note(canChange ? "Peekaboo is always in Finder's Open With menu; this makes it what a double-click opens."
            : "Run Peekaboo.app (not a development build) to change the default viewer.")

        section("Configuration file")
        let path = NSTextField(labelWithString: abbreviatedPath(model.store.url.path))
        path.isSelectable = true
        path.lineBreakMode = .byTruncatingMiddle
        row("File:", path)
        let reveal = button("Show in Finder") { [weak self] in
            guard let url = self?.model.store.url else { return }
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                NSWorkspace.shared.open(url.deletingLastPathComponent())
            }
        }
        let reload = button("Reload") { [weak self] in self?.model.store.load() }
        row("", button("Open config.toml") { [weak self] in self?.openConfigFile() }, reveal, reload)
        note("Changes here are written to config.toml at once, keeping its comments; edits saved in an editor show here.")

        section("About")
        row("Version:", NSTextField(labelWithString: BuildInfo.versionLine))
        return makeView()
    }

    override func refresh() {
        super.refresh()
        loadStatuses()
    }

    /// Which app opens each type: LaunchServices queries, off the main thread.
    private func loadStatuses() {
        let types = Array(statuses.keys)
        let canChange = DefaultViewer.bundleID != nil
        let own = Bundle.main.bundleIdentifier
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = types.map { type -> (String, String, Bool) in
                guard let app = DefaultViewer.currentApp(for: type) else { return (type, "No app", false) }
                let isOwn = own != nil && Bundle(url: app)?.bundleIdentifier == own
                let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
                return (type, isOwn ? "Peekaboo ✓" : name, isOwn)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                for (type, text, isOwn) in found {
                    self.statuses[type]?.stringValue = text
                    self.statuses[type]?.textColor = isOwn ? .systemGreen : .secondaryLabelColor
                    self.makeButtons[type]?.isEnabled = canChange && !isOwn
                }
            }
        }
    }

    private func makeDefault(_ types: [String]) {
        DefaultViewer.make(types) { [weak self] failed in
            self?.result?.stringValue = failed.isEmpty
                ? "Peekaboo now opens \(types.count == 1 ? "these files" : "\(types.count) image types")."
                : "Could not change: \(failed.joined(separator: ", "))"
            self?.loadStatuses()
        }
    }
}

// MARK: Viewer

final class ViewerPane: SettingsForm, SettingsPane {
    private(set) lazy var view: NSView = build()

    private func build() -> NSView {
        section("Display")
        row("Background:", popup([("Black", "black"), ("Gray", "gray"), ("Checkerboard", "checker")],
                                 "view", "background", default: "black"))
        note("b cycles it while viewing.")
        row("Info overlay:", popup([("Off", "off"), ("Minimal", "minimal"), ("Full (EXIF details)", "full")],
                                   "hud", "mode", default: "minimal"))
        note("i cycles it while viewing.")
        section("Full screen")
        row("Mode:", popup([("Instant (no Space animation)", "instant"), ("Native (its own Space)", "native")],
                           "fullscreen", "mode", default: "instant"))
        row("", checkbox("Keep the image below the camera housing on notched displays", "fullscreen", "avoid_notch",
                         default: true))
        section("Zoom")
        row("", checkbox("Keep zoom and position when moving to another image", "view", "keep_zoom", default: false))
        note("⇧Z toggles it while viewing.")
        row("Zoom step:", number("view", "zoom_step", default: 1.25, range: 1.01...8, step: 0.05, integer: false,
                                 unit: "× per zoom in / out"))
        row("Refine after:", number("view", "refine_delay_ms", default: 90, range: 0...2000, step: 10, integer: true,
                                    unit: "ms (high-quality re-render after a zoom gesture)"))
        return makeView()
    }
}

// MARK: Files

/// Move/copy destinations, open-with apps, ratings.
final class FilesPane: SettingsForm, SettingsPane {
    private var slotList: NamedValueList!
    private var appList: NamedValueList!
    private(set) lazy var view: NSView = build()

    private func build() -> NSView {
        section("Move and copy destinations")
        slotList = NamedValueList(model: model, table: "slots", valuePlaceholder: "~/Pictures/Keep or ./_keep",
                                  addTitle: "Add Destination…", choose: Self.chooseFolder, newName: { names in
            (1...9).map(String.init).first { !names.contains($0) } ?? "slot\(names.count + 1)"
        })
        row("", slotList.view)
        note("file.move:<name> and file.copy:<name>; ⌥1…⌥9 move and ⌥⇧1…⌥⇧9 copy to the slots named 1…9. A relative path (./_keep) is next to the current image.")

        section("Open with")
        appList = NamedValueList(model: model, table: "apps", valuePlaceholder: "a bundle id, an app name or a path",
                                 addTitle: "Add App…", choose: Self.chooseApp, newName: { names in
            names.contains("editor") ? "app\(names.count + 1)" : "editor"
        })
        row("", appList.view)
        note("file.open_with:<name>; e opens the one named editor.")

        section("Ratings")
        row("Store ratings:", popup([("As Finder tags", "finder-tags"), ("Off", "none")], "rating", "storage",
                                    default: "finder-tags"))
        row("Star character:", text("rating", "star", default: "★", width: 40) { $0.count == 1 })
        note("3 stars is the Finder tag ★★★ (searchable in Spotlight: tag:★★★).")
        row("", checkbox("Plain rating keys also go to the next image", "rating", "auto_advance", default: false))
        note("0–9, p, x and u rate, label or flag; with ⇧ they always advance.")
        return makeView()
    }

    override func refresh() {
        super.refresh()
        slotList.refresh(model.config.slots)
        appList.refresh(model.config.apps)
    }

    private static func chooseFolder(_ window: NSWindow?, _ done: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url { done(abbreviatedPath(url.path)) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }

    /// An app by its bundle id (stays valid when the app moves), else by its path.
    private static func chooseApp(_ window: NSWindow?, _ done: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Choose"
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            done(Bundle(url: url)?.bundleIdentifier ?? abbreviatedPath(url.path))
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }
}

/// The entries of `[slots]` or `[apps]`: a name and a value per row, a picker for the value, add and remove.
/// Renaming writes the removal and the new entry as one edit (a binding that uses the old name makes it fail, and
/// the banner says so).
final class NamedValueList: NSObject {
    let view = NSStackView()
    private let model: SettingsModel
    private let table: String
    private let valuePlaceholder: String
    private let choose: (NSWindow?, @escaping (String) -> Void) -> Void
    private let newName: (Set<String>) -> String
    private let rows = NSStackView()
    private var shown: [String: String]?
    private var keepAlive: [AnyObject] = []

    init(model: SettingsModel, table: String, valuePlaceholder: String, addTitle: String,
         choose: @escaping (NSWindow?, @escaping (String) -> Void) -> Void, newName: @escaping (Set<String>) -> String) {
        self.model = model
        self.table = table
        self.valuePlaceholder = valuePlaceholder
        self.choose = choose
        self.newName = newName
        super.init()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6
        let add = NSButton(title: addTitle, target: self, action: #selector(addEntry))
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 8
        view.addArrangedSubview(rows)
        view.addArrangedSubview(add)
    }

    /// Rebuild the rows when the entries changed, unless one of them is being edited.
    func refresh(_ entries: [String: String]) {
        guard entries != shown else { return }
        if rows.arrangedSubviews.contains(where: { ($0 as? NSStackView)?.arrangedSubviews.contains { ($0 as? NSTextField)?.currentEditor() != nil } == true }) {
            return
        }
        shown = entries
        keepAlive.removeAll()
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for name in entries.keys.sorted(by: Self.order) { rows.addArrangedSubview(makeRow(name, entries[name] ?? "")) }
    }

    /// Numbers first, in numeric order, then names.
    private static func order(_ a: String, _ b: String) -> Bool {
        switch (Int(a), Int(b)) {
        case let (x?, y?): return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        default: return a < b
        }
    }

    /// The entry a row edits. The rows are not rebuilt while one of their fields is being edited, so a row follows its
    /// own rename here, and takes the value from the file when it renames.
    private final class Entry {
        var name: String
        init(_ name: String) { self.name = name }
    }

    private func makeRow(_ name: String, _ value: String) -> NSView {
        let entry = Entry(name)
        let nameField = NSTextField(string: name)
        nameField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let renamer = FieldCommitter { [weak self] newName in
            guard let self else { return false }
            let trimmed = newName.trimmingCharacters(in: .whitespaces)
            let old = entry.name
            if trimmed == old { return true }
            guard !trimmed.isEmpty, self.shown?[trimmed] == nil else { return false }
            let table = self.table
            self.model.edit({ editor in
                // The value as written now: the value field of this row may have changed it since the row was built.
                let current = editor.value(old, in: table) ?? .string(value)
                try editor.remove(old, in: table)
                try editor.set(trimmed, in: table, to: current)
            }, done: { entry.name = trimmed })
            return true
        }
        nameField.delegate = renamer
        let valueField = NSTextField(string: value)
        valueField.placeholderString = valuePlaceholder
        valueField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        valueField.lineBreakMode = .byTruncatingMiddle
        let writer = FieldCommitter { [weak self] text in
            guard let self, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            self.model.set(entry.name, in: self.table, to: .string(text))
            return true
        }
        valueField.delegate = writer
        let chooseAction = ControlAction { [weak self, weak valueField] control in
            guard let self else { return }
            self.choose(control.window) { chosen in
                valueField?.stringValue = chosen
                self.model.set(entry.name, in: self.table, to: .string(chosen))
            }
        }
        let chooseButton = NSButton(title: "Choose…", target: chooseAction, action: #selector(ControlAction.fire(_:)))
        let removeAction = ControlAction { [weak self] _ in
            guard let self else { return }
            self.model.remove(entry.name, in: self.table)
        }
        let removeButton = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")!,
                                    target: removeAction, action: #selector(ControlAction.fire(_:)))
        removeButton.bezelStyle = .smallSquare
        removeButton.toolTip = "Remove \(name)"
        keepAlive += [renamer, writer, chooseAction, removeAction]
        return SettingsForm.hstack([nameField, valueField, chooseButton, removeButton], spacing: 6)
    }

    /// Pick the value first (an entry needs one), under the first free name.
    @objc private func addEntry(_ sender: NSButton) {
        let names = Set(shown?.keys.map { $0 } ?? [])
        let name = newName(names)
        choose(sender.window) { [weak self] value in
            guard let self else { return }
            self.model.set(name, in: self.table, to: .string(value))
        }
    }
}

// MARK: Performance

/// Cache budget and the decode / trace switches (once environment variables only).
final class PerformancePane: SettingsForm, SettingsPane {
    private var memoryPopup: NSPopUpButton!
    private var memoryField: NSView!
    private(set) lazy var view: NSView = build()

    /// The automatic budget (`PipelineConfig`'s default: a ninth of installed memory, as `ImagePipeline` derives it).
    private static var automaticMB: Int { Int(PipelineConfig().memoryBudget >> 20) }

    private func build() -> NSView {
        section("Memory")
        let automatic = ByteCountFormatter.string(fromByteCount: Int64(Self.automaticMB) << 20, countStyle: .memory)
        memoryPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        memoryPopup.addItems(withTitles: ["Automatic (\(automatic) on this Mac)", "Custom"])
        let target = ControlAction { [weak self] control in
            guard let self, let popup = control as? NSPopUpButton else { return }
            if popup.indexOfSelectedItem == 0 {
                self.model.set("memory_mb", in: "cache", to: .string("auto"), default: .string("auto"))
            } else {
                self.model.set("memory_mb", in: "cache", to: .integer(Self.automaticMB))
            }
        }
        retain(target)
        memoryPopup.target = target
        memoryPopup.action = #selector(ControlAction.fire(_:))
        // Written when editing ends: a budget applies at once, and one typed on the way (409 of 4096) would evict
        // decoded images that navigation then has to decode again.
        memoryField = number("cache", "memory_mb", default: Double(Self.automaticMB), range: 64...1_048_576, step: 256,
                             integer: true, unit: "MB", live: false)
        row("Decoded images:", memoryPopup, memoryField)
        note("Pixels kept for instant next / previous. More memory keeps more images ready; macOS memory pressure always trims it.")
        onRefresh { [weak self] in
            guard let self else { return }
            let custom: Bool
            if case .integer? = self.model.value("memory_mb", in: "cache") { custom = true } else { custom = false }
            self.memoryPopup.selectItem(at: custom ? 1 : 0)
            self.memoryField.isHidden = !custom
        }

        section("Decoding")
        let hdr = checkbox("Decode HDR photos in HDR (gain maps, PQ / HLG)", "decode", "hdr", default: false)
        row("", hdr)
        note(ImageIODecoder.hdrForcedByEnvironment ? "On for this session: PEEKABOO_HDR is set."
            : "Photos with a gain map (iPhone) and 10-bit PQ / HLG files (cameras, HDR AVIF) show their full brightness on HDR displays; off, they are tone-mapped to SDR. Costs 10–15× the decode time of the SDR picture.")
        let fast = checkbox("Use the fast decode path (ImageIO IOSurface)", "decode", "fast_path", default: true)
        row("", fast)
        note(!ImageIODecoder.fastPathAvailable ? "Not available: PEEKABOO_NO_IOSURFACE_SPI is set, or this macOS lacks it."
            : "Decodes straight into GPU memory, on both hardware JPEG engines. Turn it off only to compare or to work around a decoding problem.")

        section("Diagnostics")
        row("", checkbox("Trace logging (timestamped lines on stderr)", "debug", "trace", default: false))
        note(Trace.forcedByEnvironment ? "On for this session: PEEKABOO_TRACE is set."
            : "Decode paths and times, scheduling, frames: for measuring. Run from a terminal to see it.")
        onRefresh {
            if ImageIODecoder.hdrForcedByEnvironment { hdr.state = .on; hdr.isEnabled = false }
            if !ImageIODecoder.fastPathAvailable { fast.state = .off; fast.isEnabled = false }
        }
        return makeView()
    }
}

// MARK: Updates

/// `[updates]` (the updater applies it on every load of the file), Check Now and the updater's status line. The
/// updater (`Updater`, Peekaboo.app only) is reached through its notifications: Check Now posts `checkNowNotification`,
/// and every status it posts shows here.
final class UpdatesPane: SettingsForm, SettingsPane {
    /// The updater's status now (`AppDelegate.updateStatus`), nil while there is no updater.
    private let currentStatus: () -> String?
    let status = NSTextField(labelWithString: "")
    private(set) var checkNow: NSButton?
    private var observer: NSObjectProtocol?
    private(set) lazy var view: NSView = build()

    /// Without an updater: a development build, or Peekaboo.app in its first second (its first status replaces this).
    static let noUpdater = "Only Peekaboo.app checks for updates (not a development build)"

    init(model: SettingsModel, status currentStatus: @escaping () -> String?) {
        self.currentStatus = currentStatus
        super.init(model: model)
        observer = NotificationCenter.default.addObserver(forName: Updater.statusNotification, object: nil, queue: .main) {
            [weak self] note in
            if let text = note.userInfo?["status"] as? String { self?.show(text) }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private func build() -> NSView {
        section("Updates")
        row("", checkbox("Check for updates automatically", "updates", "check", default: true))
        row("", checkbox("Install updates automatically", "updates", "auto_install", default: true))
        note("Checks run in the background, never during launch and at most once an hour; an update installs when Peekaboo quits.")
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        let checkNow = button("Check Now") { NotificationCenter.default.post(name: Updater.checkNowNotification, object: nil) }
        self.checkNow = checkNow
        row("", checkNow, status)
        row("Version:", NSTextField(labelWithString: BuildInfo.versionLine))
        return makeView()
    }

    override func refresh() {
        super.refresh()
        if let text = currentStatus() {
            show(text)
        } else if status.stringValue.isEmpty || status.stringValue == Self.noUpdater {
            status.stringValue = Self.noUpdater
            status.toolTip = nil
            checkNow?.isEnabled = false
        }
    }

    private func show(_ text: String) {
        status.stringValue = text
        status.toolTip = text  // a long status is truncated
        checkNow?.isEnabled = true
    }
}
