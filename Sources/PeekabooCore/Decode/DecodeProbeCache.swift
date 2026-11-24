import Foundation

/// Probe results keyed by file identity and version (path, size, modification time), so the
/// pipeline's `probe` and the following `decode` calls of every tier parse metadata once.
/// A changed file has a new key; entries are small (~1 KB), the cache is bounded.
final class DecodeProbeCache: @unchecked Sendable {
    struct Key: Hashable {
        let path: String
        let size: Int64
        let seconds: Int
        let nanoseconds: Int
    }

    private var entries: [Key: DecodeProbe.Facts] = [:]
    private let lock = NSLock()
    private let capacity: Int

    init(capacity: Int = 2048) {
        self.capacity = capacity
    }

    /// `stat` the file (~2 µs); nil when it cannot be stat'ed.
    static func key(_ url: URL) -> Key? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return Key(path: url.path, size: Int64(st.st_size), seconds: st.st_mtimespec.tv_sec,
                   nanoseconds: st.st_mtimespec.tv_nsec)
    }

    subscript(key: Key) -> DecodeProbe.Facts? {
        get {
            lock.lock(); defer { lock.unlock() }
            return entries[key]
        }
        set {
            lock.lock(); defer { lock.unlock() }
            if entries.count >= capacity, entries[key] == nil { entries.removeAll(keepingCapacity: true) }
            entries[key] = newValue
        }
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
}
