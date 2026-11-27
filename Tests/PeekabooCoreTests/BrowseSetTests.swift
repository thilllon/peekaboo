import XCTest
@testable import PeekabooCore

/// Several URLs opened together (#91): one browsing set of every folder's images and the files among them.
final class BrowseSetTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-set-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A folder of `names` (3-byte files) under the test's root, as a directory URL.
    @discardableResult
    private func folder(_ name: String, _ names: [String] = []) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for file in names { try Data([0xFF, 0xD8, 0xFF]).write(to: url.appendingPathComponent(file)) }
        return url
    }

    private func file(_ folder: URL, _ name: String) -> URL { folder.appendingPathComponent(name, isDirectory: false) }

    /// `Folder/name` of each file.
    private func places(_ files: [ImageFile]) -> [String] {
        files.map { "\($0.url.deletingLastPathComponent().lastPathComponent)/\($0.name)" }
    }

    /// Lists, as `browse` does; the folder without read permission is skipped where permissions are not enforced.
    private func lockedFolder(_ name: String, _ names: [String]) throws -> URL {
        let url = try folder(name, names)
        XCTAssertEqual(chmod(url.path, 0o311), 0)  // -wx--x--x: files open by name, the folder does not list
        addTeardownBlock { _ = chmod(url.path, 0o755) }
        let fd = open(url.path, O_RDONLY | O_DIRECTORY)
        if fd >= 0 { close(fd) }
        guard fd < 0 else { throw XCTSkip("permissions are not enforced for this user") }
        return url
    }

    func testFoldersBrowseInTheirOrderEachInFinderOrder() throws {
        let a = try folder("A", ["b 10.jpg", "b 9.jpg", "a.png", "notes.txt", ".hidden.jpg", "clip.mov"])
        let b = try folder("B", ["z.jpg", "c.jpg"])
        let c = try folder("C", ["x.heic"])
        let browsed = try FolderScanner.browse([b, a, c])
        XCTAssertEqual(places(browsed.files), ["B/c.jpg", "B/z.jpg", "A/a.png", "A/b 9.jpg", "A/b 10.jpg", "C/x.heic"])
        XCTAssertEqual(browsed.index, 0)
        // Each folder's files are what scanning it alone lists (sizes, dates, inodes included).
        let alone = try FolderScanner.scan(a)
        XCTAssertEqual(browsed.files[2..<5].map(\.version), alone.map(\.version))
        XCTAssertEqual(browsed.files[2..<5].map(\.fileID), alone.map(\.fileID))
        let listing = BrowseSet.list([b, a, c])
        XCTAssertEqual(listing.set.items, [.folder(b), .folder(a), .folder(c)])
        XCTAssertTrue(listing.set.spansFolders)
        XCTAssertEqual(listing.failures.count, 0)
    }

    func testFilesAmongFoldersKeepTheirPlace() throws {
        let a = try folder("A", ["a1.jpg", "a2.jpg"])
        let b = try folder("B", ["b1.jpg"])
        let other = try folder("Other", ["x.jpg", "y.png", "readme.txt"])
        let listing = BrowseSet.list([a, file(other, "x.jpg"), b, file(other, "readme.txt"), file(other, "y.png"),
                                      file(other, "missing.txt")])
        XCTAssertEqual(places(listing.files), ["A/a1.jpg", "A/a2.jpg", "Other/x.jpg", "B/b1.jpg", "Other/y.png"])
        XCTAssertEqual(listing.set.items, [.folder(a), .file(file(other, "x.jpg")), .folder(b), .file(file(other, "y.png"))])
        // A dropped file is stat'ed like a listed one.
        XCTAssertEqual(listing.files[2].byteSize, 3)
        XCTAssertNotEqual(listing.files[2].fileID, 0)
        // Several files alone browse exactly that set, in their order, and from one folder they span none.
        let files = BrowseSet.list([file(other, "y.png"), file(other, "x.jpg")])
        XCTAssertEqual(places(files.files), ["Other/y.png", "Other/x.jpg"])
        XCTAssertFalse(files.set.spansFolders)
        // An image that cannot be stat'ed is browsed as it was before: it shows its error when it is reached.
        XCTAssertEqual(places(BrowseSet.list([a, file(other, "gone.jpg")]).files), ["A/a1.jpg", "A/a2.jpg", "Other/gone.jpg"])
    }

    func testEachFileIsListedOnce() throws {
        let a = try folder("A", ["a1.jpg", "a2.jpg", "a3.jpg"])
        let b = try folder("B", ["a1.jpg"])
        let other = try folder("Other", ["x.jpg"])
        // The same folder twice, a file of it before or after it: the folder's images once, in its order.
        XCTAssertEqual(places(BrowseSet.list([a, a]).files), ["A/a1.jpg", "A/a2.jpg", "A/a3.jpg"])
        XCTAssertEqual(places(BrowseSet.list([a, file(a, "a2.jpg")]).files), ["A/a1.jpg", "A/a2.jpg", "A/a3.jpg"])
        let fileFirst = BrowseSet.list([file(a, "a3.jpg"), b, a])
        XCTAssertEqual(places(fileFirst.files), ["B/a1.jpg", "A/a1.jpg", "A/a2.jpg", "A/a3.jpg"])
        XCTAssertEqual(fileFirst.set.items, [.folder(b), .folder(a)])
        // A file twice.
        XCTAssertEqual(places(BrowseSet.list([file(other, "x.jpg"), a, file(other, "x.jpg")]).files),
                       ["Other/x.jpg", "A/a1.jpg", "A/a2.jpg", "A/a3.jpg"])
        // The same folder through a symbolic link, and a file reached through it.
        let link = root.appendingPathComponent("Link to A", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a)
        XCTAssertEqual(places(BrowseSet.list([a, link]).files), ["A/a1.jpg", "A/a2.jpg", "A/a3.jpg"])
        XCTAssertEqual(places(BrowseSet.list([file(link, "a1.jpg"), a]).files), ["A/a1.jpg", "A/a2.jpg", "A/a3.jpg"])
        // The same name in two folders: two files.
        XCTAssertEqual(places(BrowseSet.list([b, a]).files), ["B/a1.jpg", "A/a1.jpg", "A/a2.jpg", "A/a3.jpg"])
    }

    /// Hidden files: a folder's rules apply to the files dropped with it; a hidden file elsewhere is browsed as dropped.
    func testHiddenFilesFollowTheirFolder() throws {
        let a = try folder("A", ["a.jpg", ".h.jpg"])
        let other = try folder("Other", [".o.jpg"])
        XCTAssertEqual(places(BrowseSet.list([a, file(a, ".h.jpg")]).files), ["A/a.jpg"])
        XCTAssertEqual(places(BrowseSet.list([file(other, ".o.jpg"), a]).files), ["Other/.o.jpg", "A/a.jpg"])
    }

    func testEmptyAndUnreadableFolders() throws {
        let empty = try folder("Empty", ["notes.txt"])
        let a = try folder("A", ["a1.jpg"])
        let locked = try lockedFolder("Locked", ["l1.jpg"])
        let b = try folder("B", ["b1.jpg"])
        let listing = BrowseSet.list([empty, a, locked, b])
        XCTAssertEqual(places(listing.files), ["A/a1.jpg", "B/b1.jpg"])
        XCTAssertEqual(listing.set.items, [.folder(empty), .folder(a), .folder(locked), .folder(b)])
        XCTAssertEqual(listing.failures.map(\.item), [2])
        XCTAssertEqual(listing.failures.first.flatMap { FolderScanner.posixCode($0.error) }, EACCES)
        XCTAssertEqual(listing.set.refused, [2], "a folder refused for its permissions is listed again when allowed")
        XCTAssertNoThrow(try FolderScanner.browse([empty, a, locked]))
        // Nothing else to browse: the reason is what `browse` throws (empty folders alone throw nothing).
        XCTAssertThrowsError(try FolderScanner.browse([empty, locked])) {
            XCTAssertEqual(FolderScanner.posixCode($0), EACCES, "\($0)")
        }
        XCTAssertEqual(try FolderScanner.browse([empty, try folder("Empty 2")]).files.count, 0)
        // A folder that is not there fails, but is no refusal.
        let gone = BrowseSet.list([root.appendingPathComponent("Gone", isDirectory: true), a])
        XCTAssertEqual(places(gone.files), ["A/a1.jpg"])
        XCTAssertEqual(gone.failures.first.flatMap { FolderScanner.posixCode($0.error) }, ENOENT)
        XCTAssertEqual(gone.set.refused, [])
    }

    /// The first images come as soon as the first folder that has any is listed, when nothing can come before them.
    func testTheFirstImagesComeWithTheFirstFolderThatHasAny() throws {
        let empty = try folder("Empty")
        let a = try folder("A", ["a2.jpg", "a1.jpg"])
        let b = try folder("B", ["b1.jpg"])
        let other = try folder("Other", ["x.jpg"])
        var lister = BrowseSet.Lister([a, b])
        XCTAssertEqual(lister.firstImages().map(places), ["A/a1.jpg", "A/a2.jpg"])
        XCTAssertEqual(places(lister.finish().files), ["A/a1.jpg", "A/a2.jpg", "B/b1.jpg"])

        var afterEmpty = BrowseSet.Lister([empty, root.appendingPathComponent("Gone", isDirectory: true), b, a])
        XCTAssertEqual(afterEmpty.firstImages().map(places), ["B/b1.jpg"])
        XCTAssertEqual(places(afterEmpty.finish().files), ["B/b1.jpg", "A/a1.jpg", "A/a2.jpg"])

        // A file first may be in a folder that comes later: only the whole listing says where it goes.
        var fileFirst = BrowseSet.Lister([file(other, "x.jpg"), a])
        XCTAssertNil(fileFirst.firstImages())
        XCTAssertEqual(places(fileFirst.finish().files), ["Other/x.jpg", "A/a1.jpg", "A/a2.jpg"])
        var nothing = BrowseSet.Lister([empty, file(other, "notes.txt")])
        XCTAssertNil(nothing.firstImages())
        XCTAssertEqual(nothing.finish().files.count, 0)
    }

    /// Each file's place follows from its URL: its item, its item's files, where it goes back.
    func testTheItemOfAFileAndWhereItGoesBack() throws {
        let a = try folder("A", ["a1.jpg", "a3.jpg"])
        let b = try folder("B", ["b1.jpg", "b3.jpg"])
        let other = try folder("Other", ["x.jpg"])
        let listing = BrowseSet.list([a, file(other, "x.jpg"), b])
        let set = listing.set
        var files = listing.files
        XCTAssertEqual(places(files), ["A/a1.jpg", "A/a3.jpg", "Other/x.jpg", "B/b1.jpg", "B/b3.jpg"])
        XCTAssertEqual(files.map { set.item(of: $0.url) }, [0, 0, 1, 2, 2])
        XCTAssertEqual(set.item(of: file(a, "new.jpg")), 0, "a file of a folder of the set, not listed yet")
        XCTAssertNil(set.item(of: file(other, "y.jpg")), "another file of a dropped file's folder")
        XCTAssertNil(set.item(of: root.appendingPathComponent("elsewhere.jpg")))
        XCTAssertEqual([0, 1, 2].map { set.range(of: $0, in: files) }, [0..<2, 2..<3, 3..<5])
        XCTAssertEqual(set.index(of: file(b, "b3.jpg"), in: files), 4)
        XCTAssertEqual(set.index(of: file(other, "x.jpg"), in: files), 2)
        XCTAssertNil(set.index(of: file(b, "b2.jpg"), in: files))
        XCTAssertNil(set.index(of: b, in: files), "a folder is no file of the set")

        // Back among its folder's files in Finder order, or at its own place.
        XCTAssertEqual(set.insertionIndex(for: FileOperations.imageFile(at: file(a, "a2.jpg")), in: files), 1)
        XCTAssertEqual(set.insertionIndex(for: FileOperations.imageFile(at: file(b, "b2.jpg")), in: files), 4)
        XCTAssertEqual(set.insertionIndex(for: FileOperations.imageFile(at: file(b, "b0.jpg")), in: files), 3)
        XCTAssertEqual(set.insertionIndex(for: FileOperations.imageFile(at: file(b, "b9.jpg")), in: files), 5)
        let x = files.remove(at: 2)
        XCTAssertEqual(set.insertionIndex(for: x, in: files), 2)
        XCTAssertNil(set.insertionIndex(for: FileOperations.imageFile(at: file(other, "y.jpg")), in: files))
        // Empty items find their place too.
        files.removeSubrange(0..<2)
        XCTAssertEqual(set.insertionIndex(for: FileOperations.imageFile(at: file(a, "a1.jpg")), in: files), 0)
        XCTAssertEqual(set.insertionIndex(for: x, in: files), 0)
    }

    /// A rescan lists one folder as the set browses it, and tells whether anything changed.
    func testARescanListsOneFolder() throws {
        let a = try folder("A", ["a1.jpg"])
        let b = try folder("B", ["b1.jpg"])
        let listing = BrowseSet.list([a, b])
        try Data([1, 2, 3, 4]).write(to: file(b, "b2.jpg"))
        let relisted = try listing.set.list(1).get()
        XCTAssertEqual(places(relisted), ["B/b1.jpg", "B/b2.jpg"])
        let range = listing.set.range(of: 1, in: listing.files)
        XCTAssertFalse(BrowseSet.sameFiles(listing.files[range], relisted))
        XCTAssertTrue(BrowseSet.sameFiles(listing.files[listing.set.range(of: 0, in: listing.files)], try listing.set.list(0).get()))
        // Rewritten in place (another size): another version of the same files.
        try Data([9, 9]).write(to: file(a, "a1.jpg"))
        XCTAssertFalse(BrowseSet.sameFiles(listing.files[0..<1], try listing.set.list(0).get()))
    }

    /// A file that came with a folder Peekaboo could not list keeps its own place once the folder lists.
    func testAFileOfAFolderThatListsLaterKeepsItsPlace() throws {
        let a = try folder("A", ["a1.jpg"])
        let locked = try lockedFolder("Locked", ["l1.jpg", "l2.jpg"])
        let listing = BrowseSet.list([locked, a, file(locked, "l2.jpg")])
        XCTAssertEqual(places(listing.files), ["A/a1.jpg", "Locked/l2.jpg"])
        XCTAssertEqual(listing.set.refused, [0])
        XCTAssertEqual(chmod(locked.path, 0o755), 0)
        let relisted = try listing.set.list(0).get()
        XCTAssertEqual(places(relisted), ["Locked/l1.jpg"], "the dropped file stays at its own place")
        XCTAssertEqual(listing.set.item(of: file(locked, "l2.jpg")), 2)
        XCTAssertEqual(listing.set.item(of: file(locked, "l1.jpg")), 0)
    }

    /// Before the listing: what the URLs name, from their shape alone.
    func testTheSetBeforeItIsListed() {
        let a = root.appendingPathComponent("A", isDirectory: true)
        let x = root.appendingPathComponent("Other/x.jpg", isDirectory: false)
        let set = BrowseSet(unlisted: [a, x, a])
        XCTAssertEqual(set.items, [.folder(a), .file(x), .folder(a)])
        XCTAssertEqual(set.item(of: a.appendingPathComponent("a1.jpg")), 0)
        XCTAssertEqual(set.item(of: x), 1)
        XCTAssertTrue(set.spansFolders)
        XCTAssertEqual(BrowseSet.folderName(of: x), "Other")
        XCTAssertFalse(BrowseSet(unlisted: [x, root.appendingPathComponent("Other/y.jpg")]).spansFolders)
    }
}
