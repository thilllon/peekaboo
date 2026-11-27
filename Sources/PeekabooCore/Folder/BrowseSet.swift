import Darwin
import Foundation

/// A browsing set opened from several URLs (#91): the images of every folder, each folder in Finder order, and the
/// image files among them, in the order the URLs came. One URL is `FolderScanner.browse`'s alone.
///
/// Every file has one place. A folder reached again (under any path: the same device and inode) is listed once, at its
/// first place. A file inside one of the folders is browsed with that folder, in its order and under its rules (a
/// hidden file stays out); any other file at its own place, once. The set lists item after item, so the item of a file
/// follows from its URL alone (`item(of:)`, a dictionary lookup of its path) and an item's files from two binary
/// searches: a rescan of one folder replaces that folder's files only, and an undo finds where a file goes back without
/// sorting the whole set again.
public struct BrowseSet: Sendable {
    /// One opened URL.
    public enum Item: Sendable, Equatable {
        /// A folder: its images, as `FolderScanner.scan` lists them.
        case folder(URL)
        /// One image file.
        case file(URL)

        public var url: URL {
            switch self {
            case .folder(let url), .file(let url): return url
            }
        }
    }

    public let items: [Item]
    /// Folder items Peekaboo may not list (macOS privacy protection or the folder's permissions refused it): the viewer
    /// lists them again when they may have been allowed.
    public var refused: [Int]
    /// The images come from more than one folder: the viewer names the folder of the image on screen.
    public let spansFolders: Bool
    /// The item of each folder and of each file item, by path (`URL.path`, as the URLs of the set spell it).
    private let folderItems: [String: Int]
    private let fileItems: [String: Int]
    /// Names a folder item leaves to file items of their own: files that came with a folder that could not be listed
    /// then (they keep their place when it lists).
    private let ownFiles: [Int: Set<String>]

    public init(items: [Item], refused: [Int] = []) {
        self.items = items
        self.refused = refused
        var folders: [String: Int] = [:]
        var files: [String: Int] = [:]
        for (k, item) in items.enumerated() {
            switch item {
            case .folder(let url): folders[url.path] = folders[url.path] ?? k
            case .file(let url): files[url.path] = files[url.path] ?? k
            }
        }
        var own: [Int: Set<String>] = [:]
        var places = Set(folders.keys)
        for case .file(let url) in items {
            let parent = Self.parent(url.path)
            places.insert(parent)
            if let folder = folders[parent] { own[folder, default: []].insert(url.lastPathComponent) }
        }
        folderItems = folders
        fileItems = files
        ownFiles = own
        spansFolders = places.count > 1
    }

    /// What `urls` name before anything is listed (no file-system access): a directory path is a folder.
    public init(unlisted urls: [URL]) {
        self.init(items: urls.map { $0.hasDirectoryPath ? .folder($0) : .file($0) })
    }

    /// The folder items, by item.
    public var folders: [(item: Int, url: URL)] {
        items.enumerated().compactMap { k, item in
            if case .folder(let url) = item { return (k, url) }
            return nil
        }
    }

    /// The item `url` belongs to: its own file item, else the folder item it is in; nil when it is not part of the set.
    public func item(of url: URL) -> Int? {
        let path = url.path
        if !fileItems.isEmpty, let k = fileItems[path] { return k }
        return folderItems[Self.parent(path)]
    }

    /// Where item `k`'s files are in `files`, a set laid out item after item (as every set this type lists is, and as
    /// the viewer keeps it): two binary searches, ~25 lookups for 6,000 files.
    public func range(of k: Int, in files: [ImageFile]) -> Range<Int> {
        first(atOrAfter: k, in: files)..<first(atOrAfter: k + 1, in: files)
    }

    /// The first position of `files` whose item is `k` or a later one (items never decrease along the set).
    private func first(atOrAfter k: Int, in files: [ImageFile]) -> Int {
        var low = 0
        var high = files.count
        while low < high {
            let mid = (low + high) / 2
            if (item(of: files[mid].url) ?? items.count) < k { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Position of the file at `url` in `files` (found among its item's files by name, as names are unique in a folder);
    /// nil when it is not there.
    public func index(of url: URL, in files: [ImageFile]) -> Int? {
        guard !url.hasDirectoryPath, let k = item(of: url) else { return nil }
        let name = url.lastPathComponent
        return files[range(of: k, in: files)].firstIndex { $0.name == name }
    }

    /// Where `file` (not in `files`) goes back: among its folder's files in Finder order, or at its own item's place;
    /// nil when it is not part of the set.
    public func insertionIndex(for file: ImageFile, in files: [ImageFile]) -> Int? {
        guard let k = item(of: file.url) else { return nil }
        let range = range(of: k, in: files)
        guard case .folder = items[k] else { return range.lowerBound }
        var low = range.lowerBound
        var high = range.upperBound
        while low < high {
            let mid = (low + high) / 2
            if NaturalSort.precedes(files[mid].name, file.name) { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// List folder item `k` as the set browses it (a rescan): its images, without the files that are items of their
    /// own. File-system access: never on the main thread.
    public func list(_ k: Int) -> Result<[ImageFile], Error> {
        Result { try FolderScanner.scan(items[k].url) }.map { browsed(k, $0) }
    }

    private func browsed(_ k: Int, _ listed: [ImageFile]) -> [ImageFile] {
        guard let own = ownFiles[k] else { return listed }
        return listed.filter { !own.contains($0.name) }
    }

    /// `a` and `b` list the same files in the same versions (path, size and modification time), in the same order.
    public static func sameFiles(_ a: ArraySlice<ImageFile>, _ b: [ImageFile]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { x, y in
            x.byteSize == y.byteSize && x.modified == y.modified && x.name == y.name && x.url == y.url
        }
    }

    /// Name of the folder `url` is in (the HUD's, when the set spans folders).
    public static func folderName(of url: URL) -> String { url.deletingLastPathComponent().lastPathComponent }

    /// The folder part of `path` (no file-system access).
    static func parent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }
}

// MARK: Listing

extension BrowseSet {
    /// What listing several URLs found.
    public struct Listing {
        public let set: BrowseSet
        /// The images of the set, item after item.
        public let files: [ImageFile]
        /// Folders that could not be listed, with the system's reason (`FolderScanner.posixCode`).
        public let failures: [Failure]
    }

    public struct Failure {
        public let item: Int
        public let folder: URL
        public let error: Error
    }

    /// `urls` listed whole (`FolderScanner.browse`, tests).
    public static func list(_ urls: [URL]) -> Listing {
        var lister = Lister(urls)
        return lister.finish()
    }

    /// Lists several URLs in their order, first pixel first: `firstImages()` hands over the set's first folder as soon as
    /// it is listed, `finish()` the whole set. File-system access (one `stat` per URL, `FolderScanner.scan` per folder):
    /// never on the main thread, except the first folder at launch, as one folder is.
    public struct Lister {
        private let urls: [URL]
        /// What each URL is, for the URLs looked at so far.
        private var kinds: [Kind] = []
        /// Listings of the folders listed so far, by URL.
        private var listings: [Int: Result<[ImageFile], Error>] = [:]
        private var seenFolders: Set<Identity> = []
        private var seenFolderPaths: Set<String> = []

        fileprivate struct Identity: Hashable {
            let device: Int64
            let inode: UInt64
        }

        fileprivate enum Kind {
            /// A folder seen for the first time (its identity is nil when it cannot even be stat'ed).
            case folder(Identity?)
            case file(ImageFile)
            /// A folder seen before, a file that is not an image, nothing there.
            case skipped
        }

        public init(_ urls: [URL]) { self.urls = urls }

        /// The set's first images, as soon as they are known: those of the first folder that has images, when every URL
        /// before it is a folder without any (empty, or one Peekaboo may not read). nil when an image file comes first
        /// (it may be in a folder that comes later) or no folder has images.
        public mutating func firstImages() -> [ImageFile]? {
            while kinds.count < urls.count {
                let i = kinds.count
                let kind = classify(i)
                kinds.append(kind)
                switch kind {
                case .folder:
                    if case .success(let files) = list(i), !files.isEmpty { return files }
                case .skipped:
                    continue
                case .file:
                    return nil
                }
            }
            return nil
        }

        /// The whole set.
        public mutating func finish() -> Listing {
            while kinds.count < urls.count { kinds.append(classify(kinds.count)) }
            for (i, kind) in kinds.enumerated() where listings[i] == nil {
                if case .folder = kind { _ = list(i) }
            }
            // A file inside a folder of the set that lists is browsed with that folder.
            var listed = Set<Identity>()
            for (i, kind) in kinds.enumerated() {
                if case .folder(let identity?) = kind, case .success? = listings[i] { listed.insert(identity) }
            }
            var parents: [String: Identity?] = [:]
            var seenFiles = Set<String>()
            var items: [Item] = []
            var sources: [Int] = []
            for (i, kind) in kinds.enumerated() {
                switch kind {
                case .folder:
                    items.append(.folder(urls[i]))
                    sources.append(i)
                case .file(let file):
                    if !listed.isEmpty, let parent = Self.parentIdentity(file.url, cache: &parents), listed.contains(parent) {
                        continue
                    }
                    guard seenFiles.insert(file.url.standardizedFileURL.path).inserted else { continue }
                    items.append(.file(file.url))
                    sources.append(i)
                case .skipped:
                    continue
                }
            }
            var refused: [Int] = []
            var failures: [Failure] = []
            for (k, i) in sources.enumerated() {
                guard case .failure(let error)? = listings[i] else { continue }
                failures.append(Failure(item: k, folder: urls[i], error: error))
                if let code = FolderScanner.posixCode(error), code == EPERM || code == EACCES { refused.append(k) }
            }
            let set = BrowseSet(items: items, refused: refused)
            var files: [ImageFile] = []
            files.reserveCapacity(sources.reduce(0) { total, i in
                guard case .success(let listed)? = listings[i] else { return total + 1 }
                return total + listed.count
            })
            for (k, i) in sources.enumerated() {
                if case .file(let file) = kinds[i] {
                    files.append(file)
                } else if case .success(let listed)? = listings[i] {
                    files += set.browsed(k, listed)
                }
            }
            return Listing(set: set, files: files, failures: failures)
        }

        /// What URL `i` is. One `stat` (it follows symbolic links, like the listing).
        private mutating func classify(_ i: Int) -> Kind {
            let url = urls[i]
            var info = stat()
            let found = url.withUnsafeFileSystemRepresentation { path in path.map { stat($0, &info) == 0 } ?? false }
            guard found else {
                // Not reachable (privacy protection refuses even a `stat` in a protected folder; gone): what the URL says.
                // A folder is listed, which says why it cannot be; a file shows its error when it is reached.
                if url.hasDirectoryPath {
                    return seenFolderPaths.insert(url.standardizedFileURL.path).inserted ? .folder(nil) : .skipped
                }
                return FolderScanner.isSupported(url) ? .file(Self.placeholder(url)) : .skipped
            }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                // The same folder under another path (a symbolic link, another letter case) is the same folder.
                let identity = Identity(device: Int64(info.st_dev), inode: UInt64(info.st_ino))
                let freshPath = seenFolderPaths.insert(url.standardizedFileURL.path).inserted
                return seenFolders.insert(identity).inserted && freshPath ? .folder(identity) : .skipped
            case S_IFREG:
                guard FolderScanner.isSupported(url) else { return .skipped }
                return .file(ImageFile(url: url, name: url.lastPathComponent, byteSize: Int64(info.st_size),
                                       modified: FolderScanner.seconds(info.st_mtimespec), fileID: UInt64(info.st_ino)))
            default:
                return .skipped
            }
        }

        private mutating func list(_ i: Int) -> Result<[ImageFile], Error> {
            let result = Result { try FolderScanner.scan(urls[i]) }
            listings[i] = result
            return result
        }

        /// A file that could not be stat'ed (as several files were browsed before #91: it shows its error when reached).
        private static func placeholder(_ url: URL) -> ImageFile {
            ImageFile(url: url, name: url.lastPathComponent, byteSize: 0, modified: 0, fileID: 0)
        }

        /// Identity of the folder `url` is in (one `stat` per folder, cached by path).
        private static func parentIdentity(_ url: URL, cache: inout [String: Identity?]) -> Identity? {
            let folder = url.deletingLastPathComponent()
            if let known = cache[folder.path] { return known }
            var info = stat()
            let found = folder.withUnsafeFileSystemRepresentation { path in path.map { stat($0, &info) == 0 } ?? false }
            let identity = found ? Identity(device: Int64(info.st_dev), inode: UInt64(info.st_ino)) : nil
            cache[folder.path] = .some(identity)
            return identity
        }
    }
}
