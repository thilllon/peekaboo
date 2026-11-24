import AppKit
import PeekabooCore

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
/// Walking-skeleton implementation (handles nothing yet); the config/file-actions
/// workstream implements it, keeping this API.
final class FileActions {
    private let config: () -> AppConfig

    init(config: @escaping () -> AppConfig) {
        self.config = config
    }

    /// Whether `perform` implements `action` (the viewer handles everything else).
    func handles(_ action: Action) -> Bool { false }

    func perform(_ action: Action, context: FileActionContext) -> FileActionResult { FileActionResult() }

    func undo() -> FileActionResult { FileActionResult() }

    func redo() -> FileActionResult { FileActionResult() }
}
