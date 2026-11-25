import Foundation

/// What a folder-wide read of the picks found (`FileOperations.readPicks`).
public struct PicksRead: Sendable, Equatable {
    /// The picked files of the listing.
    public var picks: Set<URL>
    /// The listing read, with its files' sizes, dates and inodes as they were: the next read of the folder compares
    /// with it to read only what changed.
    public var listing: [ImageFile]
    /// How many files the read looked at (the others were known from an earlier read).
    public var read: Int

    public init(picks: Set<URL>, listing: [ImageFile], read: Int) {
        self.picks = picks
        self.listing = listing
        self.read = read
    }
}

/// The photos of the browsing set flagged Pick (the Finder tag "Pick" that `meta.flag:pick` writes), for the
/// picks-only view, the pick counter and copying every pick. No database: the tags live on the files. The viewer reads
/// them off the main thread once per listing (`FileOperations.readPicks`) and applies every change it makes or reads
/// at once.
///
/// A folder-wide read can predate a change made while it ran (the user picks a photo meanwhile): `beginRead()` starts
/// noting changes, and `finishRead(_:)` applies the read except to the files changed since, which keep their newer
/// state. Main thread only (a value the viewer owns).
public struct PickSet: Equatable, Sendable {
    /// The picked files.
    public private(set) var urls: Set<URL> = []
    /// Files set since the folder-wide read in flight began, with their state; nil when no read is in flight.
    private var changedDuringRead: [URL: Bool]?

    public init() {}

    public var count: Int { urls.count }
    public var isEmpty: Bool { urls.isEmpty }
    public func contains(_ file: ImageFile) -> Bool { urls.contains(file.url) }
    /// A folder-wide read is in flight: not every pick is known yet.
    public var isReading: Bool { changedDuringRead != nil }

    /// A folder-wide read starts (a later one replaces a read still in flight, whose result is then dropped).
    public mutating func beginRead() { changedDuringRead = [:] }

    /// The result of the read begun last, which replaces the picks: files set since it began keep their state.
    public mutating func finishRead(_ read: PicksRead) {
        var result = read.picks
        for (url, isPicked) in changedDuringRead ?? [:] {
            if isPicked { result.insert(url) } else { result.remove(url) }
        }
        urls = result
        changedDuringRead = nil
    }

    /// One file is picked, or no longer (as just written, read, or removed from the set). Returns whether that changed
    /// the picks.
    @discardableResult
    public mutating func set(_ url: URL, picked: Bool) -> Bool {
        changedDuringRead?[url] = picked
        return picked ? urls.insert(url).inserted : urls.remove(url) != nil
    }

    /// The picks among `files`, in their order, plus `keeping` (an un-picked photo on screen: it stays in the picks-only
    /// view until the user moves on). Hashes every file's URL: 0.75 ms for 5,000 files, 18 ms for 50,000.
    public func filter(_ files: [ImageFile], keeping: ImageFile? = nil) -> [ImageFile] {
        guard let keeping else { return files.filter { urls.contains($0.url) } }
        return files.filter { urls.contains($0.url) || $0 == keeping }
    }

    /// `filter(files, keeping:)` found through `index` (the position of a URL in `files`, e.g. the pipeline's lookup by
    /// name): it costs the picks, not the folder (0.03 ms for 100 picks of 5,000 files, 0.55 ms for 1,000 of 50,000).
    /// Falls back to `filter` when `index` does not find every pick.
    public func view(of files: [ImageFile], keeping: ImageFile?, index: (URL) -> Int?) -> [ImageFile] {
        var positions: [Int] = []
        positions.reserveCapacity(urls.count + 1)
        func add(_ url: URL) -> Bool {
            guard let i = index(url), files.indices.contains(i), files[i].url == url else { return false }
            positions.append(i)
            return true
        }
        for url in urls {
            guard add(url) else { return filter(files, keeping: keeping) }
        }
        if let keeping, !urls.contains(keeping.url), !add(keeping.url) { return filter(files, keeping: keeping) }
        positions.sort()
        return positions.map { files[$0] }
    }

    /// Put the entries of `view` (a subsequence of `all`, such as the picks-only view the pipeline browses) back into
    /// `all`, in place: the pipeline restamps a file that changed on disk, and handing it the older stamp again would make
    /// it decode the file again. Returns where each entry of `view` is in `all`. One walk, comparing names before URLs.
    @discardableResult
    public static func merge(_ view: [ImageFile], into all: inout [ImageFile]) -> [Int] {
        var positions: [Int] = []
        positions.reserveCapacity(view.count)
        var i = 0
        while i < all.count, positions.count < view.count {
            let entry = view[positions.count]
            if all[i].name == entry.name, all[i] == entry {
                if all[i].byteSize != entry.byteSize || all[i].modified != entry.modified { all[i] = entry }
                positions.append(i)
            }
            i += 1
        }
        return positions
    }
}
