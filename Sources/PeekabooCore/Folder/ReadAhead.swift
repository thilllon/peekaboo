import Darwin
import Foundation

/// Asynchronous page-cache warm-up with `F_RDADVISE` (no copy, near-zero CPU): the SSD reads overlap decoding.
/// Calls are batched onto a utility queue so the main thread never touches the file system.
enum ReadAhead {
    /// Bytes advised for files entering the preview window: header, EXIF/MPF thumbnail, preview directory.
    static let headBytes = 256 << 10

    private static let queue = DispatchQueue(label: "peekaboo.readahead", qos: .utility)

    /// Advise the kernel to read `length` bytes (nil = whole file) of each URL soon.
    static func advise(_ requests: [(url: URL, length: Int?)]) {
        guard !requests.isEmpty else { return }
        queue.async {
            for request in requests { adviseNow(request.url, length: request.length) }
        }
    }

    /// Synchronous variant (call off the main thread).
    @discardableResult
    static func adviseNow(_ url: URL, length: Int?) -> Bool {
        let fd = url.withUnsafeFileSystemRepresentation { path in path.map { open($0, O_RDONLY | O_CLOEXEC) } ?? -1 }
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var size = length ?? 0
        if length == nil {
            var info = stat()
            guard fstat(fd, &info) == 0 else { return false }
            size = Int(info.st_size)
        }
        guard size > 0 else { return true }
        var advisory = radvisory(ra_offset: 0, ra_count: Int32(clamping: size))
        return fcntl(fd, F_RDADVISE, &advisory) != -1
    }
}
