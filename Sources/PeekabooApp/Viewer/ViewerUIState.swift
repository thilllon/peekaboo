import Foundation

/// Window state the viewer keeps across launches, such as whether the image list is open: in the app's defaults
/// (`UserDefaults`), never in config.toml, which holds what the user configured. Read once when the viewer is built (one
/// flag of the defaults AppKit has loaded by then), written when it changes.
///
/// Tests keep their own in memory (`inMemory`), and so does every headless viewer unless it is given one: a defaults
/// domain written by a test would stay behind as a file in ~/Library/Preferences.
struct ViewerUIState {
    static let imageListKey = "PeekabooImageListOpen"

    var isImageListOpen: () -> Bool
    var setImageListOpen: (Bool) -> Void

    /// The app's defaults (`defaults read com.thilllon.Peekaboo PeekabooImageListOpen`).
    static var standard: ViewerUIState {
        ViewerUIState(isImageListOpen: { UserDefaults.standard.bool(forKey: imageListKey) },
                      setImageListOpen: { UserDefaults.standard.set($0, forKey: imageListKey) })
    }

    /// State that lives as long as the value (and its copies): one launch of a test.
    static func inMemory(imageListOpen: Bool = false) -> ViewerUIState {
        final class Box { var imageListOpen: Bool; init(_ open: Bool) { imageListOpen = open } }
        let box = Box(imageListOpen)
        return ViewerUIState(isImageListOpen: { box.imageListOpen }, setImageListOpen: { box.imageListOpen = $0 })
    }
}
