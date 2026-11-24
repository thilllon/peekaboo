import Darwin
import Foundation

/// Size and content modification time of a file as `stat` reports them: what the folder listing records and what
/// every write changes. Decodes are checked against the file on disk with it rather than against the listing, which
/// goes stale while a file is written in place (that raises no event on the directory).
struct FileStamp: Equatable, Sendable {
    let size: Int64
    /// Seconds since 1970, like `ImageFile.modified`.
    let modified: Double

    init(size: Int64, modified: Double) {
        self.size = size
        self.modified = modified
    }

    /// The stamp the listing recorded; nil when it did not stat the file (opened before its folder was listed).
    init?(_ file: ImageFile) {
        guard file.byteSize != 0 || file.modified != 0 else { return nil }
        self.init(size: file.byteSize, modified: file.modified)
    }

    /// `stat` the file (~2 µs; follows symbolic links, like the listing). Nil when it cannot be stat'ed.
    static func read(_ url: URL) -> FileStamp? {
        var st = stat()
        let found = url.withUnsafeFileSystemRepresentation { path in path.map { stat($0, &st) == 0 } ?? false }
        guard found else { return nil }
        return FileStamp(size: Int64(st.st_size), modified: FolderScanner.seconds(st.st_mtimespec))
    }

    /// Written within the last `seconds` by the wall clock `now`. A modification time more than 2 s ahead of the
    /// clock was not written here just now (a camera's clock, a copy that kept its times): it counts as old.
    func written(within seconds: Double, now: Double) -> Bool {
        let age = now - modified
        return age > -2 && age < seconds
    }
}

extension ImageFile {
    /// The same file with the size and modification time seen on disk.
    func restamped(_ stamp: FileStamp) -> ImageFile {
        ImageFile(url: url, name: name, byteSize: stamp.size, modified: stamp.modified, fileID: fileID)
    }
}
