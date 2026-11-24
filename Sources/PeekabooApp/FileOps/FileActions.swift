import AppKit
import ImageIO
import PeekabooCore
import UniformTypeIdentifiers

/// What a file action did to the browsing set, so the viewer can update its list.
enum FileActionOutcome: Equatable {
    case unchanged
    /// The file left the browsing set (trashed, moved away, deleted).
    case removed(ImageFile)
    /// Undo brought a file back to its original location.
    case restored(ImageFile)
    /// Metadata changed (tags, rating): refresh the HUD.
    case changed(ImageFile)
}

struct FileActionResult: Equatable {
    var outcome: FileActionOutcome = .unchanged
    /// Short confirmation for the toast, e.g. "Moved to Trash · ⌘Z".
    var toast: String?
}

struct FileActionContext {
    let file: ImageFile
    let index: Int
    let count: Int
    weak var window: NSWindow?
}

/// Executes the actions that touch the file system or other apps (`file.*`, `meta.*`,
/// `exec:`, `app.undo/redo/config/reload_config/make_default`) and owns their undo stack.
///
/// The file-system work (trash/move/copy/tags, undo, destinations, `exec:` templates) lives in
/// `PeekabooCore.FileOperations`; this class adds the pasteboard, Finder, other apps and pickers.
/// Every result carries a toast. Work that finishes later (an `exec:` failure, open-with errors,
/// `app.make_default`) reports through `onLateResult`.
final class FileActions {
    private let config: () -> AppConfig
    private let operations = FileOperations()
    /// The last move/copy destination (`file.move:last`, and the default of the `ask` picker).
    private var lastDestination: URL?
    /// Kept alive while the pasteboard may still ask for image data.
    private var imageProvider: ImageDataProvider?
    /// Main thread: results of work that completes after `perform` returned.
    var onLateResult: ((FileActionResult) -> Void)?

    init(config: @escaping () -> AppConfig) {
        self.config = config
    }

    /// Whether `perform` implements `action` (the viewer handles everything else).
    func handles(_ action: Action) -> Bool {
        switch action {
        case .trash, .delete, .reveal, .copyPath, .copyName, .copyImage, .openWithChooser, .move, .copy, .openWith,
             .rate, .label, .flag, .undo, .redo, .config, .reloadConfig, .makeDefault, .exec:
            return true
        default:
            return false
        }
    }

    func perform(_ action: Action, context: FileActionContext) -> FileActionResult {
        let started = Trace.now()
        let result = run(action, context: context)
        Trace.log("file action \(action.id): \(result.toast ?? "-") in \(String(format: "%.2f", Trace.ms(since: started))) ms")
        return result
    }

    func undo() -> FileActionResult {
        if let busy = slowInFlight { return Self.busyResult(busy) }
        if let slow = operations.takeSlowUndo() { return runInBackground(slow) }
        do {
            guard let change = try operations.undo() else { return FileActionResult(toast: "Nothing to undo") }
            return describe(change, undo: true)
        } catch {
            return FileActionResult(toast: "Undo failed: \(error)")
        }
    }

    func redo() -> FileActionResult {
        if let busy = slowInFlight { return Self.busyResult(busy) }
        if let slow = operations.takeSlowRedo() { return runInBackground(slow) }
        do {
            guard let change = try operations.redo() else { return FileActionResult(toast: "Nothing to redo") }
            return describe(change, undo: false)
        } catch {
            return FileActionResult(toast: "Redo failed: \(error)")
        }
    }

    /// An undo or redo that copies a file across volumes, running in the background; further undos and redos
    /// wait for it, so that the stacks stay in order.
    private var slowInFlight: FileOperations.SlowChange?

    private static func busyResult(_ slow: FileOperations.SlowChange) -> FileActionResult {
        FileActionResult(toast: "Still \(slow.isUndo ? "undoing" : "redoing") the last change: wait for it to finish")
    }

    /// Like the forward move and copy: the bytes move off the main thread, the viewer updates at once where it
    /// can (a redone move takes the file out of the list), the result comes as a late result, and a failure
    /// puts the file back in the list.
    private func runInBackground(_ slow: FileOperations.SlowChange) -> FileActionResult {
        slowInFlight = slow
        let verb = slow.isUndo ? "Undo" : "Redo"
        // The file a redone move takes out of the browsing set.
        let leaving: ImageFile?
        let started: FileActionResult
        switch slow.change {
        case .moved(_, let to) where slow.isUndo:
            leaving = nil
            started = FileActionResult(toast: "\(verb): moving \(to.lastPathComponent) back…")
        case .moved(let from, let to):
            let file = FileOperations.imageFile(at: from)
            leaving = file
            started = FileActionResult(outcome: .removed(file),
                                       toast: "\(verb): moving to \(to.deletingLastPathComponent().lastPathComponent)…")
        case .copied(_, let to):
            leaving = nil
            started = FileActionResult(toast: "\(verb): copying to \(to.deletingLastPathComponent().lastPathComponent)…")
        case .trashed, .tagged:
            leaving = nil
            started = FileActionResult()
        }
        let owner = WeakFileActions(self)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = FileOperations.perform(slow)
            DispatchQueue.main.async {
                guard let actions = owner.value else { return }
                actions.slowInFlight = nil
                do {
                    let change = try actions.operations.finish(slow, with: result)
                    var finished = actions.describe(change, undo: slow.isUndo)
                    // A redone move that ended as a copy (the file changed meanwhile) left the file where it was.
                    if let leaving, case .copied = change, FileManager.default.fileExists(atPath: leaving.url.path) {
                        finished.outcome = .restored(FileOperations.imageFile(at: leaving.url))
                    }
                    actions.onLateResult?(finished)
                } catch {
                    var outcome = FileActionOutcome.unchanged
                    if let leaving, FileManager.default.fileExists(atPath: leaving.url.path) { outcome = .restored(leaving) }
                    actions.onLateResult?(FileActionResult(outcome: outcome, toast: "\(verb) failed: \(error)"))
                }
            }
        }
        return started
    }

    // MARK: Dispatch

    private func run(_ action: Action, context: FileActionContext) -> FileActionResult {
        let url = context.file.url
        switch action {
        case .undo: return undo()
        case .redo: return redo()
        case .trash:
            do {
                try operations.trash(url)
                return FileActionResult(outcome: .removed(context.file), toast: "Moved to Trash · ⌘Z")
            } catch {
                return FileActionResult(toast: "\(error)")
            }
        case .delete: return deletePermanently(context)
        case .move(let target): return transfer(target, copy: false, context: context)
        case .copy(let target): return transfer(target, copy: true, context: context)
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return FileActionResult(toast: "Shown in Finder")
        case .copyPath:
            copyString(url.path)
            return FileActionResult(toast: "Copied path")
        case .copyName:
            copyString(url.lastPathComponent)
            return FileActionResult(toast: "Copied name")
        case .copyImage:
            copyImage(url)
            return FileActionResult(toast: "Copied image")
        case .openWith(let app): return openWith(app, context: context)
        case .openWithChooser: return chooseApp(context)
        case .rate(let stars):
            return tag(context, done: stars > 0 ? String(repeating: config().starCharacter, count: stars) : "Rating cleared") {
                FileOperations.rating(stars, star: self.config().starCharacter, in: $0)
            }
        case .label(let color):
            return tag(context, done: color == "none" ? "Label cleared" : "Label: \(color.capitalized)") {
                FileOperations.label(color, in: $0, labelNames: NSWorkspace.shared.fileLabels)
            }
        case .flag(let flag):
            let done = ["pick": "Pick", "reject": "Reject"][flag] ?? "Flag cleared"
            return tag(context, done: done) { FileOperations.flag(flag, in: $0) }
        case .exec(let template): return exec(template, context: context)
        case .config: return openConfig()
        case .reloadConfig: return reloadConfig()
        case .makeDefault: return makeDefault()
        default: return FileActionResult()
        }
    }

    private func describe(_ change: FileOperations.Change, undo: Bool) -> FileActionResult {
        let verb = undo ? "Undo" : "Redo"
        switch change {
        case .trashed(let original, _):
            return undo
                ? FileActionResult(outcome: .restored(FileOperations.imageFile(at: original)), toast: "\(verb): Move to Trash")
                : FileActionResult(outcome: .removed(FileOperations.imageFile(at: original)), toast: "\(verb): Move to Trash")
        case .moved(let from, let to):
            let name = to.deletingLastPathComponent().lastPathComponent
            return undo
                ? FileActionResult(outcome: .restored(FileOperations.imageFile(at: from)), toast: "\(verb): Move to \(name)")
                : FileActionResult(outcome: .removed(FileOperations.imageFile(at: from)), toast: "\(verb): Move to \(name)")
        case .copied(_, let to):
            return FileActionResult(toast: "\(verb): Copy to \(to.deletingLastPathComponent().lastPathComponent)")
        case .tagged(let url, _, _):
            return FileActionResult(outcome: .changed(FileOperations.imageFile(at: url)), toast: "\(verb): Tags")
        }
    }

    // MARK: Trash, delete, move, copy

    private func deletePermanently(_ context: FileActionContext) -> FileActionResult {
        let alert = NSAlert()
        alert.messageText = "Delete “\(context.file.name)” permanently?"
        alert.informativeText = "This cannot be undone. Use Move to Trash (⌘⌫) to keep the option."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return FileActionResult() }
        do {
            try FileManager.default.removeItem(at: context.file.url)
            return FileActionResult(outcome: .removed(context.file), toast: "Deleted \(context.file.name)")
        } catch {
            return FileActionResult(toast: "Cannot delete \(context.file.name): \(error.localizedDescription)")
        }
    }

    private func transfer(_ target: String, copy: Bool, context: FileActionContext) -> FileActionResult {
        let folder: URL
        switch target {
        case "ask":
            guard let chosen = askDestination(copy: copy, context: context) else { return FileActionResult() }
            folder = chosen
        case "last":
            guard let last = lastDestination else { return FileActionResult(toast: "No previous destination yet") }
            folder = last
        default:
            guard let resolved = FileOperations.destination(for: target, slots: config().slots, imageURL: context.file.url) else {
                return FileActionResult(toast: "Slot \(target) is not set: add it under [slots] in config.toml")
            }
            folder = resolved
        }
        let existed = FileManager.default.fileExists(atPath: folder.path)
        let file = context.file
        func toast(for change: FileOperations.Change) -> String {
            var renamed = ""
            var endedAsCopy = false
            switch change {
            case .moved(_, let to), .copied(_, let to):
                if to.lastPathComponent != file.name { renamed = " as \(to.lastPathComponent)" }
                // A move whose original another app changed meanwhile (saved a new version) ends as a copy.
                if case .copied = change { endedAsCopy = !copy }
            default: break
            }
            let text = endedAsCopy
                ? "\(file.name) changed during the move: copied to \(folder.lastPathComponent)\(renamed), original left as it is"
                : "\(copy ? "Copied" : "Moved") to \(folder.lastPathComponent)\(renamed)"
            return text + (existed ? "" : " (new folder)") + " · ⌘Z"
        }
        /// The result of a finished move. One that ended as a copy leaves the original in its folder, so the
        /// viewer keeps its entry (or gets it back, when it dropped the file as the move began).
        func moved(_ change: FileOperations.Change, viewerDroppedIt: Bool) -> FileActionResult {
            var stays = false
            if case .copied = change { stays = FileManager.default.fileExists(atPath: file.url.path) }
            let outcome: FileActionOutcome = viewerDroppedIt
                ? (stays ? .restored(FileOperations.imageFile(at: file.url)) : .unchanged)
                : (stays ? .unchanged : .removed(file))
            return FileActionResult(outcome: outcome, toast: toast(for: change))
        }
        // A copy, or a move to another volume, moves bytes: do it off the main thread. The viewer advances
        // at once; the change joins the undo stack when it completes, and a failure puts the file back.
        if copy || FileOperations.crossesVolumes(file.url, folder) {
            lastDestination = folder
            let owner = WeakFileActions(self)
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try FileOperations.transfer(file.url, toFolder: folder, copy: copy) }
                DispatchQueue.main.async {
                    guard let actions = owner.value else { return }
                    switch result {
                    case .success(let change):
                        actions.operations.record(change)
                        if !copy { actions.onLateResult?(moved(change, viewerDroppedIt: true)) }
                    case .failure(let error):
                        actions.onLateResult?(FileActionResult(outcome: copy ? .unchanged : .restored(file), toast: "\(error)"))
                    }
                }
            }
            return FileActionResult(outcome: copy ? .unchanged : .removed(file),
                                    toast: copy ? "Copied to \(folder.lastPathComponent) · ⌘Z" : "Moving to \(folder.lastPathComponent)…")
        }
        do {
            let change = try operations.move(file.url, toFolder: folder)
            lastDestination = folder
            return moved(change, viewerDroppedIt: false)
        } catch {
            return FileActionResult(toast: "\(error)")
        }
    }

    /// Slot picker: 1–9 (or the slot's key) choose, Return repeats the last destination.
    private func askDestination(copy: Bool, context: FileActionContext) -> URL? {
        let slots = config().slots
        let names = slots.keys.sorted { a, b in
            switch (Int(a), Int(b)) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a < b
            }
        }
        let picker = MenuPicker()
        let menu = NSMenu(title: copy ? "Copy to" : "Move to")
        menu.autoenablesItems = false
        let header = menu.addItem(withTitle: copy ? "Copy to…" : "Move to…", action: nil, keyEquivalent: "")
        header.isEnabled = false
        var choices: [URL] = []
        func add(_ title: String, _ url: URL, key: String) {
            let item = menu.addItem(withTitle: title, action: #selector(MenuPicker.pick(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = []
            item.target = picker
            item.tag = choices.count
            item.toolTip = url.path
            choices.append(url)
        }
        if let last = lastDestination { add("Last: \(last.lastPathComponent)", last, key: "\r") }
        for name in names {
            guard let url = FileOperations.destination(for: name, slots: slots, imageURL: context.file.url) else { continue }
            add("\(name)   \(url.lastPathComponent)  (\(slots[name]!))", url, key: name.count == 1 ? name : "")
        }
        menu.addItem(.separator())
        let other = menu.addItem(withTitle: "Other Folder…", action: #selector(MenuPicker.pick(_:)),
                                 keyEquivalent: slots["o"] == nil ? "o" : "")
        other.keyEquivalentModifierMask = []
        other.target = picker
        other.tag = -1
        guard let view = context.window?.contentView else { return chooseFolder(copy: copy) }
        guard let tag = picker.run(menu, in: view) else { return nil }
        return tag >= 0 ? choices[tag] : chooseFolder(copy: copy)
    }

    private func chooseFolder(copy: Bool) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = copy ? "Copy Here" : "Move Here"
        if let last = lastDestination { panel.directoryURL = last }
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: Tags

    private func tag(_ context: FileActionContext, done: String,
                     _ change: (FileOperations.Tags) -> FileOperations.Tags) -> FileActionResult {
        guard config().ratingStorage == .finderTags else {
            return FileActionResult(toast: "Ratings are off ([rating] storage = \"none\")")
        }
        let url = context.file.url
        do {
            try operations.setTags(change(FileOperations.tags(of: url)), of: url)
            return FileActionResult(outcome: .changed(context.file), toast: done)
        } catch {
            return FileActionResult(toast: "\(error)")
        }
    }

    // MARK: Pasteboard

    private func copyString(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    /// The file URL plus lazily encoded image data: ⌘C is O(1); pixels are produced only if an app pastes them.
    private func copyImage(_ url: URL) {
        let provider = ImageDataProvider(url: url)
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        var types: [NSPasteboard.PasteboardType] = [.png, .tiff]
        if let original = provider.originalType, original != .png, original != .tiff { types.insert(original, at: 0) }
        item.setDataProvider(provider, forTypes: types)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        imageProvider = provider
    }

    // MARK: Other apps

    /// An app slot, bundle id, app name or path → the app's URL.
    private func appURL(for spec: String) -> URL? {
        let spec = config().apps[spec] ?? spec
        let fm = FileManager.default
        if spec.contains("/") {
            let path = (spec as NSString).expandingTildeInPath
            return fm.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: spec) { return url }
        let name = spec.hasSuffix(".app") ? spec : spec + ".app"
        let folders = ["/Applications", "/System/Applications", "/Applications/Utilities",
                       "/System/Applications/Utilities", "~/Applications"]
        for folder in folders {
            let path = ((folder as NSString).expandingTildeInPath as NSString).appendingPathComponent(name)
            if fm.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    private func openWith(_ spec: String, context: FileActionContext) -> FileActionResult {
        guard let app = appURL(for: spec) else {
            return FileActionResult(toast: config().apps[spec] == nil
                ? "No app “\(spec)”: set it under [apps] in config.toml"
                : "App not found: \(config().apps[spec]!)")
        }
        return open(context.file.url, with: app)
    }

    private func open(_ url: URL, with app: URL) -> FileActionResult {
        let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                self?.onLateResult?(FileActionResult(toast: "Cannot open in \(name): \(error.localizedDescription)"))
            }
        }
        return FileActionResult(toast: "Opening in \(name)")
    }

    /// "Open With" menu of the apps that can open the file, plus "Other…".
    private func chooseApp(_ context: FileActionContext) -> FileActionResult {
        let url = context.file.url
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: url).filter { $0 != Bundle.main.bundleURL }
        let picker = MenuPicker()
        let menu = NSMenu(title: "Open With")
        menu.autoenablesItems = false
        for (n, app) in apps.prefix(30).enumerated() {
            let title = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
            let item = menu.addItem(withTitle: title, action: #selector(MenuPicker.pick(_:)), keyEquivalent: "")
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            item.target = picker
            item.tag = n
        }
        menu.addItem(.separator())
        let other = menu.addItem(withTitle: "Other…", action: #selector(MenuPicker.pick(_:)), keyEquivalent: "")
        other.target = picker
        other.tag = -1
        let chosen = context.window?.contentView.map { picker.run(menu, in: $0) } ?? -1
        guard let tag = chosen else { return FileActionResult() }
        if tag >= 0 { return open(url, with: apps[tag]) }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let app = panel.url else { return FileActionResult() }
        return open(url, with: app)
    }

    // MARK: exec

    /// The placeholders become quoted references to `PEEKABOO_*` variables and the file's values travel in
    /// the child's environment, so no file name is ever parsed as shell code.
    private func exec(_ template: String, context: FileActionContext) -> FileActionResult {
        let owner = WeakFileActions(self)
        let command = FileOperations.runExec(template, file: context.file.url, index: context.index,
                                             count: context.count) { status, stderr in
            guard status != 0 else { return }
            DispatchQueue.main.async {
                let detail = stderr.isEmpty ? "exit status \(status)" : stderr
                owner.value?.onLateResult?(FileActionResult(toast: "Command failed: \(detail)"))
            }
        }
        Trace.log("exec: \(command)")
        let shown = template.count > 48 ? String(template.prefix(47)) + "…" : template
        return FileActionResult(toast: "Ran \(shown)")
    }

    // MARK: App

    private func openConfig() -> FileActionResult {
        let store = ConfigStore.current ?? ConfigStore()
        do {
            let url = try store.createDefaultFileIfMissing()
            let editor = NSWorkspace.shared.urlForApplication(toOpen: url)
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")
            if let editor {
                NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.open(url)
            }
            return FileActionResult(toast: "Opened \((url.path as NSString).abbreviatingWithTildeInPath)")
        } catch {
            return FileActionResult(toast: "Cannot create the config file: \(error.localizedDescription)")
        }
    }

    private func reloadConfig() -> FileActionResult {
        guard let store = ConfigStore.current else { return FileActionResult(toast: "No config loaded") }
        store.load()
        return FileActionResult(toast: store.lastError ?? store.lastWarning.map { "Config reloaded · \($0)" } ?? "Config reloaded")
    }

    /// Register Peekaboo as the default viewer for the image types of its Info.plist (explicit action only).
    private func makeDefault() -> FileActionResult {
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "app", let bundleID = bundle.bundleIdentifier else {
            return FileActionResult(toast: "Run Peekaboo.app to make it the default viewer")
        }
        let documentTypes = bundle.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        let types = documentTypes.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
            .filter { $0 != "public.folder" && $0 != "public.image" }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let setter: DefaultHandlerSetter = LaunchServicesDefaults()
            let failed = types.filter { setter.setViewer(bundleID, for: $0) != noErr }
            let toast = failed.isEmpty ? "Peekaboo is now the default viewer for \(types.count) image types"
                : "Default viewer set for \(types.count - failed.count) of \(types.count) types (failed: \(failed.joined(separator: ", ")))"
            DispatchQueue.main.async { self?.onLateResult?(FileActionResult(toast: toast)) }
        }
        return FileActionResult(toast: "Making Peekaboo the default image viewer…")
    }
}

/// Lets background completions reach the (main-thread) owner; only dereferenced on the main queue.
private struct WeakFileActions: @unchecked Sendable {
    weak var value: FileActions?
    init(_ value: FileActions) { self.value = value }
}

/// Runs a picker menu and reports the chosen item's tag. Items use `pick(_:)` as their action; the
/// highlighted item is the fallback in case AppKit delivers the action after `popUp` returns.
private final class MenuPicker: NSObject, NSMenuDelegate {
    private var chosen: Int?
    private var highlighted: Int?

    @objc func pick(_ sender: NSMenuItem) { chosen = sender.tag }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        highlighted = item.flatMap { $0.action == #selector(pick(_:)) ? $0.tag : nil }
    }

    /// Pop the menu up near the middle of `view`; nil when it was dismissed.
    func run(_ menu: NSMenu, in view: NSView) -> Int? {
        menu.delegate = self
        let selected = menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.midX - 120, y: view.bounds.midY + 80), in: view)
        return chosen ?? (selected ? highlighted : nil)
    }
}

/// Encodes the image only when another app asks for pixels.
private final class ImageDataProvider: NSObject, NSPasteboardItemDataProvider {
    let url: URL
    /// The file's own type (e.g. public.jpeg), served as the raw file bytes.
    let originalType: NSPasteboard.PasteboardType?

    init(url: URL) {
        self.url = url
        originalType = UTType(filenameExtension: url.pathExtension).map { NSPasteboard.PasteboardType($0.identifier) }
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        if type == originalType, let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            item.setData(data, forType: type)
            return
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        // Full size with the EXIF orientation applied.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return }
        let data = NSMutableData()
        let uti = (type == .png ? UTType.png : UTType.tiff).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(data, uti, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        if CGImageDestinationFinalize(destination) { item.setData(data as Data, forType: type) }
    }
}

/// `LSSetDefaultRoleHandlerForContentType` is deprecated but is the only synchronous, consent-free call;
/// calling it through a protocol keeps the build free of deprecation warnings.
private protocol DefaultHandlerSetter {
    func setViewer(_ bundleID: String, for contentType: String) -> OSStatus
}

private struct LaunchServicesDefaults: DefaultHandlerSetter {
    @available(macOS, deprecated: 12.0)
    func setViewer(_ bundleID: String, for contentType: String) -> OSStatus {
        LSSetDefaultRoleHandlerForContentType(contentType as CFString, .viewer, bundleID as CFString)
    }
}
