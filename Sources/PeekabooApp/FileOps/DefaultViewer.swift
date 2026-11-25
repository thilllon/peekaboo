import AppKit
import UniformTypeIdentifiers

/// Peekaboo as the default viewer of its image types: `app.make_default` (all of them) and Settings › General (one
/// type at a time, with the app that opens each type now). Only ever on an explicit request.
enum DefaultViewer {
    /// The image types of the bundle's document types (Info.plist), without the folder and generic image entries.
    static var contentTypes: [String] {
        let documentTypes = Bundle.main.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        return documentTypes.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
            .filter { $0 != "public.folder" && $0 != "public.image" }
    }

    /// The bundle id when running as Peekaboo.app (a bare executable cannot be a default app).
    static var bundleID: String? {
        Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleIdentifier : nil
    }

    /// The app that opens `type` by default (a LaunchServices query: call it off the main thread).
    static func currentApp(for type: String) -> URL? {
        UTType(type).flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
    }

    /// Make Peekaboo the viewer of `types` off the main thread; `completion` (main thread) gets the types that failed.
    static func make(_ types: [String], completion: @escaping ([String]) -> Void) {
        guard let bundleID else {
            completion(types)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let setter: DefaultHandlerSetter = LaunchServicesDefaults()
            let failed = types.filter { setter.setViewer(bundleID, for: $0) != noErr }
            DispatchQueue.main.async { completion(failed) }
        }
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
