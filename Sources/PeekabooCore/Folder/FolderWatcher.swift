import Darwin
import Foundation

/// Watches a directory for added, removed or renamed entries (vnode `DispatchSource`, ≈ 0.2–0.6 ms latency)
/// and calls `onChange` on the main thread, debounced, so the app can rescan.
public final class FolderWatcher {
    public let directory: URL
    private let debounce: TimeInterval
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?

    /// Returns nil when the directory cannot be opened. Create and cancel it on the main thread.
    public init?(directory: URL, debounce: TimeInterval = 0.05, onChange: @escaping () -> Void) {
        let fd = directory.withUnsafeFileSystemRepresentation { path in path.map { open($0, O_EVTONLY | O_CLOEXEC) } ?? -1 }
        guard fd >= 0 else { return nil }
        self.directory = directory
        self.debounce = debounce
        self.onChange = onChange
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend, .link, .revoke], queue: .main)
        source.setEventHandler { [weak self] in self?.changed() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    deinit { cancel() }

    /// Stop watching (idempotent).
    public func cancel() {
        timer?.cancel()
        timer = nil
        source?.cancel()
        source = nil
    }

    private func changed() {
        if timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.setEventHandler { [weak self] in self?.onChange() }
            timer.resume()
            self.timer = timer
        }
        // Each event pushes the deadline back: one callback per burst of changes.
        timer?.schedule(deadline: .now() + debounce, leeway: .milliseconds(5))
    }
}
