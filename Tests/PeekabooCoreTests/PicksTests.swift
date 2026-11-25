import XCTest
@testable import PeekabooCore

/// Picks (the Finder tag "Pick"): reading them for a folder, keeping them current (`PickSet`), and copying them all
/// (`FileOperations.copyAll`), on temporary directories.
final class PicksTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("peekaboo-picks-\(UUID().uuidString)").resolvingSymlinksInPath()
        try fm.createDirectory(at: root.appendingPathComponent("shoot"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    @discardableResult
    private func make(_ relative: String, _ contents: String = "pixels") throws -> URL {
        let url = root.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// Writes the tag attribute as Finder does (a binary plist of `"name\n<colour>"` strings, or bare names).
    private func tag(_ url: URL, _ entries: [String]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
        let written = data.withUnsafeBytes { setxattr(url.path, FileOperations.tagAttribute, $0.baseAddress, data.count, 0, 0) }
        guard written == 0 else { throw XCTSkip("volume does not store extended attributes") }
    }

    private func file(_ url: URL) -> ImageFile { FileOperations.imageFile(at: url) }

    // MARK: Reading

    func testAPickIsTheTagPickWhateverElseTheFileCarries() throws {
        let plain = try make("shoot/a.jpg")
        let picked = try make("shoot/b.jpg")
        let colouredAndRated = try make("shoot/c.jpg")
        let bare = try make("shoot/d.jpg")
        let lookalike = try make("shoot/e.jpg")
        let rejected = try make("shoot/f.jpg")
        try tag(picked, ["Pick\n0"])
        try tag(colouredAndRated, ["★★★\n0", "Green\n2", "Pick\n0"])
        try tag(bare, ["Pick"])
        try tag(lookalike, ["Picky\n0", "Pick up\n0"])
        try tag(rejected, ["Reject\n0"])
        // Hundreds of tags do not fit the first read's buffer.
        let crowded = try make("shoot/g.jpg")
        try tag(crowded, (0..<300).map { "Project \($0)\n0" } + ["Pick\n0"])

        XCTAssertFalse(FileOperations.isPicked(plain))
        XCTAssertTrue(FileOperations.isPicked(picked))
        XCTAssertTrue(FileOperations.isPicked(colouredAndRated))
        XCTAssertTrue(FileOperations.isPicked(bare))
        XCTAssertFalse(FileOperations.isPicked(lookalike))
        XCTAssertFalse(FileOperations.isPicked(rejected))
        XCTAssertTrue(FileOperations.isPicked(crowded))
        XCTAssertFalse(FileOperations.isPicked(root.appendingPathComponent("shoot/missing.jpg")))
        // What `meta.flag:pick` writes is read back as a pick, and the tag reader still sees every tag.
        try FileOperations().setTags(FileOperations.flag("pick", in: FileOperations.tags(of: plain)), of: plain)
        XCTAssertTrue(FileOperations.isPicked(plain))
        XCTAssertEqual(FileOperations.tags(of: crowded).names.count, 301)

        let all = [plain, picked, colouredAndRated, bare, lookalike, rejected, crowded].map(file)
        XCTAssertEqual(FileOperations.picked(all), Set([plain, picked, colouredAndRated, bare, crowded]))
        XCTAssertEqual(FileOperations.picked([]), [])
    }

    /// A new listing of the folder reads only the files that are new or changed since the last read; the others keep
    /// what is known of them.
    func testANewListingReadsOnlyTheNewAndChangedFiles() throws {
        let a = try make("shoot/a.jpg"), b = try make("shoot/b.jpg"), c = try make("shoot/c.jpg")
        try tag(b, ["Pick\n0"])
        let first = FileOperations.readPicks(of: [a, b, c].map(file))
        XCTAssertEqual(first.picks, [b])
        XCTAssertEqual(first.read, 3)
        XCTAssertEqual(first.listing.map(\.url), [a, b, c])

        // c is tagged behind the viewer's back (a tag write changes neither size, date nor inode): it keeps what is
        // known of it. A new file d is read.
        try tag(c, ["Pick\n0"])
        let d = try make("shoot/d.jpg")
        try tag(d, ["Pick\n0"])
        let listing = [a, b, c, d].map(file)
        XCTAssertEqual(listing[2], first.listing[2])
        XCTAssertEqual(listing[2].modified, first.listing[2].modified, "a tag write changed the modification time")
        let second = FileOperations.readPicks(of: listing, previous: first.listing, known: first.picks)
        XCTAssertEqual(second.picks, [b, d])
        XCTAssertEqual(second.read, 1)

        // Another app saves b anew (a new file renamed over it, without its tags): b is read again and is no pick.
        let saved = try make("shoot/.saving-b.jpg", "b, edited")
        XCTAssertEqual(rename(saved.path, b.path), 0)
        let third = FileOperations.readPicks(of: [a, b, c, d].map(file), previous: second.listing, known: second.picks)
        XCTAssertEqual(third.picks, [d])
        XCTAssertEqual(third.read, 1)

        // A file the viewer moved away and that came back is read again (here: d, un-tagged meanwhile).
        try tag(d, [])
        let fourth = FileOperations.readPicks(of: [a, b, c, d].map(file), previous: third.listing, known: third.picks,
                                              unknown: [d])
        XCTAssertEqual(fourth.picks, [])
        XCTAssertEqual(fourth.read, 1)
    }

    func testReadingFiveThousandFilesIsQuick() throws {
        var files: [ImageFile] = []
        for i in 0..<5000 {
            let url = root.appendingPathComponent(String(format: "shoot/IMG_%04d.JPG", i))
            fm.createFile(atPath: url.path, contents: nil)
            if i % 50 == 0 { try tag(url, ["Pick\n0"]) }
            files.append(ImageFile(url: url, name: url.lastPathComponent, byteSize: 0, modified: 0, fileID: 0))
        }
        _ = FileOperations.picked(files)
        var times: [Double] = []
        var read = PicksRead(picks: [], listing: [], read: 0)
        for _ in 0..<3 {
            let started = Trace.now()
            read = FileOperations.readPicks(of: files)
            times.append(Trace.ms(since: started))
        }
        print(String(format: "picks of 5000 files: %.1f ms (best of 3), %d picks", times.min()!, read.picks.count))
        XCTAssertEqual(read.picks.count, 100)
        XCTAssertEqual(read.listing.count, 5000)
        // Generous for a loaded CI machine: the expectation is tens of milliseconds.
        XCTAssertLessThan(times.min()!, 2000)
    }

    // MARK: Keeping them current

    func testChangesDuringAReadKeepTheirState() {
        let a = URL(fileURLWithPath: "/shoot/a.jpg"), b = URL(fileURLWithPath: "/shoot/b.jpg")
        let c = URL(fileURLWithPath: "/shoot/c.jpg"), gone = URL(fileURLWithPath: "/shoot/gone.jpg")
        var picks = PickSet()
        picks.set(gone, picked: true)
        XCTAssertFalse(picks.isReading)
        picks.beginRead()
        XCTAssertTrue(picks.isReading)
        // While the folder is read the user picks a and un-picks b (the read saw them before that). A pick of the set
        // before that the read did not find (it left the folder) is no pick any more.
        XCTAssertTrue(picks.set(a, picked: true))
        XCTAssertFalse(picks.set(b, picked: false))
        picks.finishRead(PicksRead(picks: [b, c], listing: [], read: 3))
        XCTAssertEqual(picks.urls, [a, c])
        XCTAssertFalse(picks.isReading)
        XCTAssertEqual(picks.count, 2)
        // With no read in flight, a change is just applied.
        XCTAssertTrue(picks.set(b, picked: true))
        XCTAssertFalse(picks.set(b, picked: true))
        XCTAssertTrue(picks.set(a, picked: false))
        XCTAssertEqual(picks.urls, [b, c])
    }

    func testTheViewIsThePicksInOrderPlusThePhotoOnScreen() {
        let files = (0..<6).map { ImageFile(url: URL(fileURLWithPath: "/shoot/\($0).jpg"), name: "\($0).jpg", byteSize: 1,
                                            modified: 1, fileID: UInt64($0)) }
        var picks = PickSet()
        for i in [4, 1] { picks.set(files[i].url, picked: true) }
        XCTAssertEqual(picks.filter(files).map(\.name), ["1.jpg", "4.jpg"])
        XCTAssertEqual(picks.filter(files, keeping: files[2]).map(\.name), ["1.jpg", "2.jpg", "4.jpg"])
        XCTAssertEqual(picks.filter(files, keeping: files[4]).map(\.name), ["1.jpg", "4.jpg"])
        XCTAssertTrue(picks.contains(files[4]))
        XCTAssertFalse(picks.contains(files[2]))

        // Through a lookup of each pick's position (the pipeline's), the same view; one the lookup misses (a pick the
        // listing no longer has, a lookup of another list) falls back to filtering.
        let index = { (url: URL) in files.firstIndex { $0.url == url } }
        XCTAssertEqual(picks.view(of: files, keeping: files[2], index: index), picks.filter(files, keeping: files[2]))
        XCTAssertEqual(picks.view(of: files, keeping: files[4], index: index).map(\.name), ["1.jpg", "4.jpg"])
        XCTAssertEqual(picks.view(of: files, keeping: nil, index: { _ in 0 }).map(\.name), ["1.jpg", "4.jpg"])
        picks.set(URL(fileURLWithPath: "/shoot/gone.jpg"), picked: true)
        XCTAssertEqual(picks.view(of: files, keeping: files[0], index: index).map(\.name), ["0.jpg", "1.jpg", "4.jpg"])
    }

    /// The pipeline restamps a file of the view that changed on disk: leaving the view puts the newer stamp back.
    func testTheViewGoesBackIntoTheFolderWithItsNewerStamps() {
        func file(_ name: String, _ size: Int64, at folder: String = "/shoot") -> ImageFile {
            ImageFile(url: URL(fileURLWithPath: "\(folder)/\(name)"), name: name, byteSize: size, modified: 1, fileID: 0)
        }
        var all = ["a", "b", "c", "d", "e"].map { file("\($0).jpg", 1) }
        let view = [file("b.jpg", 1), file("d.jpg", 2)]
        XCTAssertEqual(PickSet.merge(view, into: &all), [1, 3])
        XCTAssertEqual(all.map(\.byteSize), [1, 1, 1, 2, 1])
        // A set opened from several folders can hold a name twice: the URL decides.
        var mixed = [file("x.jpg", 1, at: "/a"), file("x.jpg", 1, at: "/b"), file("y.jpg", 1, at: "/a")]
        XCTAssertEqual(PickSet.merge([file("x.jpg", 5, at: "/b")], into: &mixed), [1])
        XCTAssertEqual(mixed.map(\.byteSize), [1, 5, 1])
    }

    // MARK: Copying them all

    func testCopyingAllPicksNeverOverwritesAndSkipsWhatIsThere() throws {
        let a = try make("shoot/a.jpg", "a pixels"), b = try make("shoot/b.jpg", "b pixels")
        let c = try make("shoot/c.jpg", "c pixels")
        let selects = root.appendingPathComponent("selects")
        // Another photo named a.jpg is there already: it is never replaced.
        try make("selects/a.jpg", "another a")
        var progress: [Int] = []
        let first = FileOperations.copyAll([a, b, c], toFolder: selects) { progress.append($0) }
        XCTAssertEqual(progress, [1, 2, 3])
        XCTAssertEqual(first.copied, 2)
        XCTAssertEqual(first.renamed, 1)
        XCTAssertEqual(first.firstRenamed, "a 2.jpg")
        XCTAssertEqual(first.alreadyThere, 0)
        XCTAssertEqual(first.failures, [])
        func contents(_ name: String) -> String? {
            (try? Data(contentsOf: selects.appendingPathComponent(name))).map { String(decoding: $0, as: UTF8.self) }
        }
        XCTAssertEqual(contents("a.jpg"), "another a")
        XCTAssertEqual(contents("a 2.jpg"), "a pixels")
        XCTAssertEqual(contents("b.jpg"), "b pixels")
        XCTAssertEqual(contents("c.jpg"), "c pixels")
        XCTAssertTrue(fm.fileExists(atPath: a.path), "a copy leaves the original")

        // Again, with one more pick: only that one is copied (a's copy is found under its numbered name).
        let d = try make("shoot/d.jpg", "d pixels")
        let again = FileOperations.copyAll([a, b, c, d], toFolder: selects)
        XCTAssertEqual(again.copied, 1)
        XCTAssertEqual(again.renamed, 0)
        XCTAssertEqual(again.alreadyThere, 3)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: selects.path).sorted(),
                       ["a 2.jpg", "a.jpg", "b.jpg", "c.jpg", "d.jpg"])

        // A photo edited since it was copied is copied again, under a new name; the older copy stays.
        try Data("b edited".utf8).write(to: b)
        let edited = FileOperations.copyAll([b], toFolder: selects)
        XCTAssertEqual(edited.renamed, 1)
        XCTAssertEqual(contents("b.jpg"), "b pixels")
        XCTAssertEqual(contents("b 2.jpg"), "b edited")
    }

    /// What tells a copy made earlier on a volume that keeps file times coarser than APFS (HFS+, FAT, exFAT, SMB).
    func testACopyIsRecognisedAtTheTimePrecisionOfItsVolume() {
        func status(_ seconds: Int, _ nanoseconds: Int, type: mode_t = S_IFREG, size: off_t = 1000) -> stat {
            var st = stat()
            st.st_mode = type | 0o644
            st.st_size = size
            st.st_mtimespec = timespec(tv_sec: seconds, tv_nsec: nanoseconds)
            return st
        }
        let source = status(1_795_630_876, 978_563_625)
        XCTAssertEqual(FileOperations.copyMatch(source: source, candidate: source), .same, "APFS keeps nanoseconds")
        for (volume, kept) in [("HFS+", status(1_795_630_876, 0)), ("FAT", status(1_795_630_876, 0)),
                               ("FAT, rounded up", status(1_795_630_878, 0)), ("exFAT", status(1_795_630_876, 970_000_000)),
                               ("SMB", status(1_795_630_876, 978_563_600))] {
            XCTAssertEqual(FileOperations.copyMatch(source: source, candidate: kept), .likely, volume)
        }
        // Another size or type, a time more than 2 s off, or a full-precision time that differs: another file.
        XCTAssertEqual(FileOperations.copyMatch(source: source, candidate: status(1_795_630_876, 0, size: 999)), .different)
        XCTAssertEqual(FileOperations.copyMatch(source: source, candidate: status(1_795_630_876, 0, type: S_IFLNK)), .different)
        XCTAssertEqual(FileOperations.copyMatch(source: source, candidate: status(1_795_630_873, 0)), .different)
        XCTAssertEqual(FileOperations.copyMatch(source: source, candidate: status(1_795_630_876, 978_563_601)), .different)
        // A link is only ever the same, never likely.
        let link = status(1_795_630_876, 978_563_625, type: S_IFLNK)
        XCTAssertEqual(FileOperations.copyMatch(source: link, candidate: status(1_795_630_876, 0, type: S_IFLNK)), .different)
    }

    /// Copying again onto a volume that cut the copies' times (simulated here: the copies' times set to whole seconds)
    /// skips them once their contents match; another photo of the same name, size and time is copied, under a number.
    func testCopyingAgainOntoACoarseVolumeSkipsCopiesByTheirContents() throws {
        let photos = try (0..<3).map { try make("shoot/IMG_000\($0).jpg", String(repeating: "pixels \($0) ", count: 20_000)) }
        let card = root.appendingPathComponent("card")
        XCTAssertEqual(FileOperations.copyAll(photos, toFolder: card).copied, 3)
        /// The copy of `photo` gets the photo's modification time cut to the second, as HFS+ stores it.
        func cutTime(of photo: URL) {
            var st = stat()
            XCTAssertEqual(lstat(photo.path, &st), 0)
            var times = [st.st_atimespec, timespec(tv_sec: st.st_mtimespec.tv_sec, tv_nsec: 0)]
            XCTAssertEqual(utimensat(AT_FDCWD, card.appendingPathComponent(photo.lastPathComponent).path, &times, 0), 0)
        }
        for photo in photos { cutTime(of: photo) }
        // IMG_0001's copy is replaced by another photo of its name, size and time (another camera's, say).
        let impostor = card.appendingPathComponent("IMG_0001.jpg")
        var bytes = try Data(contentsOf: impostor)
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: impostor)
        cutTime(of: photos[1])
        let again = FileOperations.copyAll(photos, toFolder: card)
        XCTAssertEqual(again.alreadyThere, 2)
        XCTAssertEqual(again.renamed, 1)
        XCTAssertEqual(again.firstRenamed, "IMG_0001 2.jpg")
        XCTAssertEqual(try Data(contentsOf: card.appendingPathComponent("IMG_0001 2.jpg")), try Data(contentsOf: photos[1]))
    }

    func testCopyingAllPicksReportsFailuresAndSkipsTheirOwnFolder() throws {
        let a = try make("shoot/a.jpg"), gone = root.appendingPathComponent("shoot/gone.jpg")
        let result = FileOperations.copyAll([a, gone], toFolder: root.appendingPathComponent("selects"))
        XCTAssertEqual(result.copied, 1)
        XCTAssertEqual(result.failures, ["gone.jpg is no longer there"])
        // The picks' own folder holds them already: nothing is duplicated there.
        let home = FileOperations.copyAll([a], toFolder: root.appendingPathComponent("shoot"))
        XCTAssertEqual(home.alreadyThere, 1)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("shoot").path), ["a.jpg"])
    }
}
