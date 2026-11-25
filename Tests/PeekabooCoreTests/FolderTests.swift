import XCTest
@testable import PeekabooCore

final class FolderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("peekaboo-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func touch(_ name: String, bytes: Int = 3) throws {
        try Data(repeating: 0xAB, count: bytes).write(to: directory.appendingPathComponent(name))
    }

    private func finderOrder(_ names: [String]) -> [String] {
        names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: Natural sort

    private static let tricky = [
        "IMG_0001.jpg", "IMG_0002.jpg", "IMG_0010.jpg", "IMG_10.jpg", "img_9.jpg", "img-9.jpg", "img 9.jpg",
        "img9.jpg", "img09.jpg", "img009.jpg", "Img9b.jpg", "img9a.jpg", "a.jpg", "A.jpg", "ab.jpg", "a b.jpg",
        "a-b.jpg", "a_b.jpg", "a.b.jpg", "a(1).jpg", "a (2).jpg", "a (10).jpg", "a [3].jpg", "a{4}.jpg", "a~.jpg",
        "a$.jpg", "a@.jpg", "a#1.jpg", "a+1.jpg", "a=1.jpg", "a&b.jpg", "a,b.jpg", "a;b.jpg", "a'b.jpg", "a!b.jpg",
        "file1.png", "file01.png", "file001.png", "file2.png", "file10.png", "file100.png", "file1000.png",
        "x99999999999999999999999.jpg", "x100000000000000000000000.jpg", "v1.2.9.jpg", "v1.2.10.jpg", "v1.10.1.jpg",
        "2024-01-02 10.00.00.jpg", "2024-01-02 9.59.59.jpg", "0.jpg", "00.jpg", "000.jpg", "1.jpg", "10.jpg",
        "café.jpg", "cafe.jpg", "cafè.jpg", "Cafe.jpg", "résumé 2.jpg", "resume 10.jpg", "Zebra.jpg", "zebra.jpg",
        "émile.jpg", "Ångström.jpg", "angstrom.jpg", "naïve.jpg", "über.jpg", "uber 2.jpg",
        "스크린샷 2026-11-24 오후 11.00.00.png", "스크린샷 2026-11-24 오후 9.00.00.png", "가.jpg", "나.jpg",
        "각.jpg", "가가.jpg", "힣.jpg", "사진 2.jpg", "사진 10.jpg", "사진10.jpg", "abc 사진.jpg", "_hidden-ish.jpg",
        "-dash.jpg", "~tilde.jpg", "(paren).jpg", "[bracket].jpg",
    ]

    func testNaturalKeysMatchFinderOrderOnTrickyNames() {
        let names = Self.tricky
        XCTAssertEqual(NaturalSort.sort(names.shuffled(), by: { $0 }), finderOrder(names))
        for a in names {
            for b in names where a != b {
                XCTAssertEqual(NaturalSort.precedes(a, b), a.localizedStandardCompare(b) == .orderedAscending, "\(a) vs \(b)")
            }
        }
        XCTAssertNotNil(NaturalSort.key("스크린샷 2026-11-24 오후 11.00.00.png"), "Hangul names use the fast key")
        let decomposed = "스크린샷 2.png".decomposedStringWithCanonicalMapping
        XCTAssertEqual(NaturalSort.key(decomposed), NaturalSort.key("스크린샷 2.png"), "NFD names from the file system")
    }

    func testNaturalKeysMatchFinderOrderOnRandomNames() {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("aAbBzZ09 _-.()~é가나0123456789")
        var names = Set<String>()
        while names.count < 600 {
            let length = Int.random(in: 1...10, using: &generator)
            names.insert(String((0..<length).map { _ in alphabet.randomElement(using: &generator)! }))
        }
        let list = Array(names)
        XCTAssertEqual(NaturalSort.sort(list, by: { $0 }), finderOrder(list))
    }

    func testUnsupportedCharactersFallBackToLocalizedCompare() {
        let names = ["日本 2.jpg", "日本 10.jpg", "Привет.jpg", "emoji 😀.jpg", "a.jpg", "Ω.jpg"]
        XCTAssertNil(NaturalSort.key("日本 2.jpg"))
        XCTAssertEqual(NaturalSort.sort(names, by: { $0 }), finderOrder(names))
    }

    // MARK: Listing

    func testBulkListingEqualsFileManagerListing() throws {
        let names = Self.tricky + ["UPPER.JPG", "noext", "video.mov", "e\u{301}cole.jpg", "space .jpg", "#hash.jpg"]
        for (i, name) in names.enumerated() { try touch(name, bytes: i + 1) }
        try touch(".hidden.jpg")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("sub.jpg"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("link.jpg"),
                                                   withDestinationURL: directory.appendingPathComponent("a.jpg"))
        let flagged = directory.appendingPathComponent("flagged-hidden.jpg")
        try touch(flagged.lastPathComponent)
        var values = URLResourceValues()
        values.isHidden = true
        var mutable = flagged
        try mutable.setResourceValues(values)

        let bulk = try XCTUnwrap(FolderScanner.listBulk(directory))
        let reference = try FolderScanner.listWithFileManager(directory)
        func describe(_ files: [ImageFile]) -> [String] {
            files.map { "\($0.name)|\($0.byteSize)|\($0.fileID)|\(Int($0.modified * 1000))|\($0.url.path)" }.sorted()
        }
        XCTAssertEqual(describe(bulk), describe(reference))
        let listed = Set(bulk.map(\.name))
        XCTAssertFalse(listed.contains(".hidden.jpg"))
        XCTAssertFalse(listed.contains("flagged-hidden.jpg"), "UF_HIDDEN files are skipped like Finder")
        XCTAssertFalse(listed.contains("sub.jpg"), "directories are not images")
        XCTAssertTrue(listed.contains("link.jpg"), "symlinks to files are browsable")
        // APFS is case-insensitive: "a.jpg" and "A.jpg" are one file.
        let distinct = Set(names.map { $0.precomposedStringWithCanonicalMapping.lowercased() }).count
        XCTAssertEqual(bulk.count, distinct + 1)
    }

    /// The decode workers' `stat` and the listing agree to the bit (size and modification time), or every rescan
    /// would take decoded files for changed ones and decode them again.
    func testListingStampsMatchStat() throws {
        try touch("a.jpg", bytes: 10)
        try touch("b.jpg", bytes: 2000)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("link.jpg"),
                                                   withDestinationURL: directory.appendingPathComponent("b.jpg"))
        let bulk = try XCTUnwrap(FolderScanner.listBulk(directory))
        for file in bulk + (try FolderScanner.listWithFileManager(directory)) {
            XCTAssertEqual(FileStamp.read(file.url), FileStamp(file), file.name)
        }
        XCTAssertEqual(bulk.count, 3)
    }

    func testScanFiltersAndSortsLikeFinder() throws {
        let names = ["b.jpg", "a10.png", "a9.heic", "notes.txt", "A1.JPG", "clip.mov", "x.webp"]
        for name in names { try touch(name) }
        let scanned = try FolderScanner.scan(directory).map(\.name)
        let expected = finderOrder(names.filter { FolderScanner.isSupported(URL(fileURLWithPath: $0)) })
        XCTAssertEqual(scanned, expected)
        XCTAssertFalse(scanned.contains("notes.txt"))
        let browse = try FolderScanner.browse([directory.appendingPathComponent("a10.png")])
        XCTAssertEqual(browse.files[browse.index].name, "a10.png")
    }

    /// `Peekaboo ~/Pictures/dsc_0042.jpg` for a file stored as `DSC_0042.JPG` (APFS ignores case): that file is shown,
    /// not the folder's first image.
    func testBrowseFindsTheOpenedFileWhateverTheLetterCase() throws {
        for name in ["a.jpg", "DSC_0042.JPG", "z.jpg"] { try touch(name) }
        let browse = try FolderScanner.browse([directory.appendingPathComponent("dsc_0042.jpg")])
        XCTAssertEqual(browse.files.map(\.name), ["a.jpg", "DSC_0042.JPG", "z.jpg"])
        XCTAssertEqual(browse.files[browse.index].name, "DSC_0042.JPG")
        let decomposed = "Cafe\u{301} 2.jpg"
        try touch("Café 2.jpg")
        let nfd = try FolderScanner.browse([directory.appendingPathComponent(decomposed)])
        XCTAssertEqual(nfd.files[nfd.index].name.precomposedStringWithCanonicalMapping, "Café 2.jpg")
    }

    /// An opened file the listing leaves out (hidden) is browsed at its Finder position.
    func testBrowseKeepsAnOpenedHiddenFile() throws {
        for name in ["a.jpg", "m.jpg", "z.jpg"] { try touch(name) }
        let hidden = directory.appendingPathComponent("m2.jpg")
        try touch(hidden.lastPathComponent)
        var values = URLResourceValues()
        values.isHidden = true
        var mutable = hidden
        try mutable.setResourceValues(values)
        let browse = try FolderScanner.browse([hidden])
        XCTAssertEqual(browse.files.map(\.name), ["a.jpg", "m.jpg", "m2.jpg", "z.jpg"])
        XCTAssertEqual(browse.index, 2)
        XCTAssertEqual(browse.files[2].byteSize, 3)
    }

    /// A folder that may not be listed (here: no read permission, EACCES; macOS privacy protection refuses with
    /// EPERM) throws the system's reason, not "no such file", so the viewer can say how to allow it.
    func testAFolderThatCannotBeListedThrowsTheSystemsReason() throws {
        try touch("a.jpg")
        XCTAssertEqual(chmod(directory.path, 0o311), 0)  // -wx--x--x: files open by name, the folder does not list
        defer { chmod(directory.path, 0o755) }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY)
        if fd >= 0 { close(fd) }
        guard fd < 0 else { throw XCTSkip("permissions are not enforced for this user") }

        XCTAssertThrowsError(try FolderScanner.scan(directory)) {
            XCTAssertEqual(FolderScanner.posixCode($0), EACCES, "\($0)")
        }
        XCTAssertThrowsError(try FolderScanner.browse([directory.appendingPathComponent("a.jpg")])) {
            XCTAssertEqual(FolderScanner.posixCode($0), EACCES, "\($0)")
        }
        // The FileManager fallback's error carries the POSIX reason underneath.
        XCTAssertThrowsError(try FolderScanner.listWithFileManager(directory)) {
            XCTAssertEqual(($0 as NSError).code, CocoaError.fileReadNoPermission.rawValue, "\($0)")
            XCTAssertEqual(FolderScanner.posixCode($0), EACCES, "\($0)")
        }
        XCTAssertThrowsError(try FolderScanner.scan(directory.appendingPathComponent("missing"))) {
            XCTAssertEqual(FolderScanner.posixCode($0), ENOENT, "\($0)")
        }
    }

    func testPOSIXCodeOfAPrivacyRefusal() {
        // What FileManager reports for a folder macOS privacy protection refuses: 257 over "Operation not permitted".
        let refused = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoPermission.rawValue,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        XCTAssertEqual(FolderScanner.posixCode(refused), EPERM)
        XCTAssertEqual(FolderScanner.posixCode(POSIXError(.EPERM)), EPERM)
        XCTAssertNil(FolderScanner.posixCode(CocoaError(.fileReadUnknown)))
    }

    func testScanOfLargeFolderIsFast() throws {
        for i in 0..<2000 { try touch("photo \(i).jpg", bytes: 1) }
        let start = Trace.now()
        let files = try FolderScanner.scan(directory)
        let elapsed = Trace.ms(since: start)
        XCTAssertEqual(files.count, 2000)
        XCTAssertEqual(files.prefix(3).map(\.name), ["photo 0.jpg", "photo 1.jpg", "photo 2.jpg"])
        XCTAssertLessThan(elapsed, 500)
    }

    // MARK: Watching and read-ahead

    func testFolderWatcherFiresOnceDebouncedOnMain() throws {
        var fired = 0
        let watcher = try XCTUnwrap(FolderWatcher(directory: directory) {
            XCTAssertTrue(Thread.isMainThread)
            fired += 1
        })
        for i in 0..<5 { try touch("new\(i).jpg") }
        let deadline = Date().addingTimeInterval(1)
        while fired == 0 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(fired, 1, "a burst of changes yields one callback")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("new0.jpg"))
        let second = Date().addingTimeInterval(1)
        while fired == 1 && Date() < second { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        XCTAssertEqual(fired, 2)
        watcher.cancel()
    }

    func testReadAheadAdvisesExistingFiles() throws {
        try touch("r.jpg", bytes: 300_000)
        XCTAssertTrue(ReadAhead.adviseNow(directory.appendingPathComponent("r.jpg"), length: ReadAhead.headBytes))
        XCTAssertTrue(ReadAhead.adviseNow(directory.appendingPathComponent("r.jpg"), length: nil))
        XCTAssertFalse(ReadAhead.adviseNow(directory.appendingPathComponent("missing.jpg"), length: nil))
    }
}
