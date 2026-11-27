import AppKit
import XCTest
@testable import PeekabooApp
@testable import PeekabooCore

/// Several folders dropped together browse as one set (#91): navigation, the HUD, picks, file operations and undo,
/// the folder watchers and a folder Peekaboo may not read, on a headless viewer.
final class SeveralFoldersTests: ViewerTestCase {
    private func directory(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }

    /// `Folder/name` of each file of the browsing set.
    private func places(_ viewer: ViewerWindowController) -> [String] {
        viewer.pipeline.files.map { "\($0.url.deletingLastPathComponent().lastPathComponent)/\($0.name)" }
    }

    private func hudLine(_ viewer: ViewerWindowController) -> String {
        let content: HUDContent? = property(hud(viewer), "content")
        return content?.line ?? ""
    }

    private func hudStarts(_ viewer: ViewerWindowController, _ parts: [String], line: UInt = #line) {
        let shown = hudLine(viewer).components(separatedBy: "  ·  ")
        XCTAssertEqual(Array(shown.prefix(parts.count)), parts, hudLine(viewer), line: line)
    }

    /// Flag `urls` Pick on disk, as `meta.flag:pick` does.
    private func pick(_ urls: [URL]) throws {
        let ops = FileOperations()
        for url in urls { try ops.setTags(FileOperations.flag("pick", in: FileOperations.tags(of: url)), of: url) }
        guard urls.allSatisfy(FileOperations.isPicked) else { throw XCTSkip("volume does not store Finder tags") }
    }

    private func waitForPicks(_ viewer: ViewerWindowController, _ count: Int, line: UInt = #line) {
        let done = spin(10) {
            let picks: PickSet? = self.property(viewer, "picks")
            return picks?.isReading == false && self.hudLine(viewer).components(separatedBy: "  ·  ").contains("Picks \(count)")
        }
        XCTAssertTrue(done, "the picks were not read: \(hudLine(viewer))", line: line)
    }

    func testSeveralFoldersBrowseOneAfterAnother() throws {
        let viewer = try makeViewer()
        // The same names in both folders: each file is its own.
        let trip = writeSequence(3, in: directory("Trip"))
        let home = writeSequence(2, in: directory("Home"))
        openAndWait(viewer, [directory("Trip"), directory("Home")], file: "img00.jpg")
        XCTAssertEqual(places(viewer), ["Trip/img00.jpg", "Trip/img01.jpg", "Trip/img02.jpg", "Home/img00.jpg", "Home/img01.jpg"])
        XCTAssertEqual(viewer.displayedFile?.url, trip[0])
        hudStarts(viewer, ["Trip › img00.jpg", "1/5"])
        viewer.perform(.jump(3))
        hudStarts(viewer, ["Home › img00.jpg", "4/5"])
        XCTAssertTrue(spin(5) { viewer.displayedFile?.url == home[0] }, "\(viewer.displayedFile?.url.path ?? "nothing") on screen")
        viewer.perform(.next)
        viewer.perform(.next)
        XCTAssertEqual(toastText(viewer), "Last image")
        XCTAssertEqual(viewer.pipeline.currentFile?.url, home[1])
        viewer.perform(.previous)
        viewer.perform(.previous)
        XCTAssertEqual(viewer.pipeline.currentFile?.url, trip[2], "← from a folder's first image goes to the folder before")
        XCTAssertTrue(spin(1) { viewer.window?.title == "Trip › img02.jpg — 3/5" }, viewer.window?.title ?? "")

        // Finder opens a file of one of the folders: it shows within the set, which stays as it is.
        viewer.open([home[1]])
        XCTAssertEqual(viewer.pipeline.files.count, 5)
        XCTAssertEqual(viewer.pipeline.currentFile?.url, home[1])
        XCTAssertFalse(viewer.isListingPendingForTests)
    }

    /// First pixel first: the first folder's first image is on its way while a large folder after it is still listed.
    func testTheFirstFolderShowsBeforeTheRestIsListed() throws {
        let viewer = try makeViewer()
        let first = writeSequence(2, in: directory("First"), prefix: "f")
        let large = directory("Large")
        try FileManager.default.createDirectory(at: large, withIntermediateDirectories: true)
        for i in 0..<15_000 {
            FileManager.default.createFile(atPath: large.appendingPathComponent(String(format: "x%05d.jpg", i)).path, contents: nil)
        }
        viewer.open([directory("First"), large])
        var firstWhileListing = false
        let done = spin(30) {
            if viewer.isListingPendingForTests, viewer.pipeline.files.count == 2, viewer.pipeline.currentFile?.url == first[0] {
                firstWhileListing = true
            }
            return !viewer.isListingPendingForTests && viewer.displayedFile?.url == first[0]
        }
        XCTAssertTrue(done, "\(viewer.displayedFile?.name ?? "nothing") on screen")
        XCTAssertTrue(firstWhileListing, "the first image waited for the whole set")
        XCTAssertEqual(viewer.pipeline.files.count, 15_002)
        XCTAssertEqual(viewer.pipeline.index, 0)
    }

    /// At launch (AppKit services the main queue only once it has launched), the first folder is listed in the launch's
    /// turn, as one folder is, and its first image presented from there; the rest follows off the main thread.
    func testAtLaunchTheFirstFolderIsListedInTheLaunchsTurn() throws {
        let viewer = try makeViewer()
        let trip = writeSequence(2, in: directory("Trip"))
        writeSequence(3, in: directory("Home"))
        viewer.presentsSynchronously = true
        viewer.open([directory("Trip"), directory("Home")])
        viewer.presentsSynchronously = false
        XCTAssertEqual(places(viewer), ["Trip/img00.jpg", "Trip/img01.jpg"], "the first folder was not listed in this turn")
        XCTAssertTrue(viewer.isListingPendingForTests, "the rest was listed on the main thread")
        XCTAssertEqual(viewer.pipeline.currentFile?.url, trip[0])
        XCTAssertTrue(spin(10) { !viewer.isListingPendingForTests && viewer.displayedFile?.url == trip[0] })
        XCTAssertEqual(viewer.pipeline.files.count, 5)
    }

    /// A file moved away while the rest of the set is listed does not come back with that listing, and the image on
    /// screen stays.
    func testAFileMovedWhileTheSetIsListedStaysOut() throws {
        let viewer = try makeViewer()
        let first = writeSequence(3, in: directory("First"), prefix: "f")
        let large = directory("Large")
        try FileManager.default.createDirectory(at: large, withIntermediateDirectories: true)
        for i in 0..<15_000 {
            FileManager.default.createFile(atPath: large.appendingPathComponent(String(format: "x%05d.jpg", i)).path, contents: nil)
        }
        viewer.open([directory("First"), large])
        XCTAssertTrue(spin(10) { viewer.pipeline.currentFile?.url == first[0] })
        guard viewer.isListingPendingForTests else { throw XCTSkip("the set was listed before the first folder showed") }
        viewer.perform(.next)
        viewer.perform(.move("./_keep"))
        XCTAssertEqual(viewer.pipeline.currentFile?.url, first[2])
        XCTAssertTrue(spin(30) { !viewer.isListingPendingForTests }, "the set was never listed")
        XCTAssertFalse(places(viewer).contains("First/f01.jpg"), "the moved file came back with the listing")
        XCTAssertEqual(viewer.pipeline.files.count, 15_002)
        XCTAssertEqual(viewer.pipeline.currentFile?.url, first[2], "the listing took another image on screen")
        XCTAssertEqual(viewer.pipeline.index, 1)
    }

    /// A file opened first that is in one of the folders opened with it is browsed with that folder, at its place there,
    /// and stays on screen when the set is listed.
    func testAFileOpenedFirstInALaterFolderStaysOnScreenInItsFolder() throws {
        let viewer = try makeViewer()
        let trip = writeSequence(3, in: directory("Trip"), prefix: "t")
        writeSequence(2, in: directory("Home"), prefix: "h")
        viewer.open([trip[2], directory("Home"), directory("Trip")])
        XCTAssertEqual(viewer.pipeline.currentFile?.url, trip[2], "the file is not the first thing decoded")
        XCTAssertTrue(spin(10) { !viewer.isListingPendingForTests && viewer.displayedFile?.url == trip[2] })
        XCTAssertEqual(places(viewer), ["Home/h00.jpg", "Home/h01.jpg", "Trip/t00.jpg", "Trip/t01.jpg", "Trip/t02.jpg"])
        XCTAssertEqual(viewer.pipeline.index, 4)
        hudStarts(viewer, ["Trip › t02.jpg", "5/5"])
    }

    /// An image file opened first decodes before anything is listed, and keeps its place among the folders.
    func testAFileOpenedFirstShowsFirstAndKeepsItsPlace() throws {
        let viewer = try makeViewer()
        try FileManager.default.createDirectory(at: directory("Desk"), withIntermediateDirectories: true)
        let loose = writeImage(directory("Desk").appendingPathComponent("loose.jpg"), width: 900, height: 600, gray: 0.3)
        writeSequence(2, in: directory("Trip"))
        viewer.open([loose, directory("Trip")])
        XCTAssertEqual(viewer.pipeline.currentFile?.url, loose, "the file is not the first thing decoded")
        XCTAssertTrue(spin(10) { !viewer.isListingPendingForTests && viewer.displayedFile?.url == loose })
        XCTAssertEqual(places(viewer), ["Desk/loose.jpg", "Trip/img00.jpg", "Trip/img01.jpg"])
        hudStarts(viewer, ["Desk › loose.jpg", "1/3"])
    }

    func testPicksWorkAcrossTheFolders() throws {
        let selects = root.appendingPathComponent("selects")
        let viewer = try makeViewer(toml: "[slots]\nselects = \"\(selects.path)\"\n")
        let trip = writeSequence(4, in: directory("Trip"))
        let home = writeSequence(4, in: directory("Home"), width: 1000, height: 700)  // other bytes than Trip's
        try pick([trip[1], home[2]])
        openAndWait(viewer, [directory("Trip"), directory("Home")], file: "img00.jpg")
        waitForPicks(viewer, 2)

        viewer.perform(.picksOnly)
        XCTAssertEqual(places(viewer), ["Trip/img00.jpg", "Trip/img01.jpg", "Home/img02.jpg"])
        viewer.perform(.next)
        viewer.perform(.next)
        XCTAssertEqual(viewer.pipeline.currentFile?.url, home[2])
        hudStarts(viewer, ["Home › img02.jpg", "Picks 2/2"])
        viewer.perform(.picksOnly)
        XCTAssertEqual(viewer.pipeline.files.count, 8)
        XCTAssertEqual(viewer.pipeline.currentFile?.url, home[2])
        hudStarts(viewer, ["Home › img02.jpg", "7/8", "Picks 2"])
        viewer.perform(.next)
        viewer.perform(.flag("pick"))
        hudStarts(viewer, ["Home › img03.jpg", "8/8", "Picks 3"])

        // ⇧C: every pick of the set, in its order; a name two folders share is copied under a number, never replaced.
        try pick([home[1]])
        viewer.perform(.copyPicks("selects"))
        XCTAssertTrue(spin(10) { self.toastText(viewer)?.hasPrefix("Copied") == true }, toastText(viewer) ?? "no toast")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: selects.path).sorted(),
                       ["img01 2.jpg", "img01.jpg", "img02.jpg", "img03.jpg"])
        XCTAssertEqual(try Data(contentsOf: selects.appendingPathComponent("img01.jpg")), try Data(contentsOf: trip[1]))
        XCTAssertTrue(hudLine(viewer).contains("Picks 4"), "the copy's own read of the tags: \(hudLine(viewer))")
    }

    /// A move takes the file out of the set, and its undo puts it back into its folder's place (not sorted among all).
    func testAFileOperationAndItsUndoKeepEveryFolderInPlace() throws {
        let viewer = try makeViewer()
        writeSequence(3, in: directory("Trip"), prefix: "t")
        let home = writeSequence(3, in: directory("Home"), prefix: "h")
        // Trip first: sorted by name, Home's images would come before Trip's.
        openAndWait(viewer, [directory("Trip"), directory("Home")], file: "t00.jpg")
        viewer.perform(.jump(4))
        XCTAssertEqual(viewer.pipeline.currentFile?.url, home[1])
        viewer.perform(.move("./_keep"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory("Home").appendingPathComponent("_keep/h01.jpg").path),
                      "a relative slot is the folder of the image on screen")
        XCTAssertEqual(places(viewer), ["Trip/t00.jpg", "Trip/t01.jpg", "Trip/t02.jpg", "Home/h00.jpg", "Home/h02.jpg"])
        XCTAssertEqual(viewer.pipeline.currentFile?.url, home[2])
        viewer.perform(.undo)
        XCTAssertEqual(places(viewer), ["Trip/t00.jpg", "Trip/t01.jpg", "Trip/t02.jpg", "Home/h00.jpg", "Home/h01.jpg", "Home/h02.jpg"])
        XCTAssertEqual(viewer.pipeline.currentFile?.url, home[1])
        hudStarts(viewer, ["Home › h01.jpg", "5/6"])
        // The watchers' rescans of the move and the undo change nothing.
        spin(1)
        XCTAssertEqual(places(viewer).count, 6)

        // The undo stack outlives a set: undoing a move made in another folder leaves this set alone.
        let elsewhere = writeSequence(2, in: directory("Elsewhere"), prefix: "e")
        openAndWait(viewer, [elsewhere[0]])
        viewer.perform(.move("./_out"))
        openAndWait(viewer, [directory("Trip"), directory("Home")], file: "t00.jpg")
        viewer.perform(.undo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere[0].path), "the undo was not applied")
        XCTAssertEqual(places(viewer).count, 6, "a file of another folder was injected: \(places(viewer))")
    }

    /// The watcher of each folder: a change in one folder updates that folder's place in the set, and the image on
    /// screen stays.
    func testAChangeInOneFolderUpdatesItsPlaceInTheSet() throws {
        let viewer = try makeViewer()
        let trip = writeSequence(3, in: directory("Trip"), prefix: "t")
        writeSequence(3, in: directory("Home"), prefix: "h")
        openAndWait(viewer, [directory("Trip"), directory("Home")], file: "t00.jpg")
        viewer.perform(.next)
        let watchers: [Int: FolderWatcher] = try XCTUnwrap(property(viewer, "folderWatchers"))
        XCTAssertEqual(watchers.count, 2)
        writeImage(directory("Home").appendingPathComponent("h01b.jpg"), width: 900, height: 600, gray: 0.7)
        // The rescan runs on a utility queue: slow to get a core on a loaded CI machine.
        XCTAssertTrue(spin(30) { self.places(viewer).contains("Home/h01b.jpg") }, "\(places(viewer))")
        XCTAssertEqual(places(viewer), ["Trip/t00.jpg", "Trip/t01.jpg", "Trip/t02.jpg",
                                        "Home/h00.jpg", "Home/h01.jpg", "Home/h01b.jpg", "Home/h02.jpg"])
        XCTAssertEqual(viewer.pipeline.currentFile?.url, trip[1])
        try FileManager.default.removeItem(at: trip[2])
        XCTAssertTrue(spin(30) { !self.places(viewer).contains("Trip/t02.jpg") }, "\(places(viewer))")
        XCTAssertEqual(viewer.pipeline.currentFile?.url, trip[1])
        hudStarts(viewer, ["Trip › t01.jpg", "2/6"])
    }

    /// Several files alone (no folder): that set, in its order, also across folders; an undo puts a file back at its
    /// own place.
    func testSeveralFilesBrowseExactlyThatSet() throws {
        let viewer = try makeViewer()
        let trip = writeSequence(3, in: directory("Trip"), prefix: "t")
        let home = writeSequence(2, in: directory("Home"), prefix: "h")
        openAndWait(viewer, [trip[2], home[0], trip[0]], file: "t02.jpg")
        XCTAssertEqual(places(viewer), ["Trip/t02.jpg", "Home/h00.jpg", "Trip/t00.jpg"])
        hudStarts(viewer, ["Trip › t02.jpg", "1/3"])
        viewer.perform(.next)
        viewer.perform(.move("./_keep"))
        XCTAssertEqual(places(viewer), ["Trip/t02.jpg", "Trip/t00.jpg"])
        viewer.perform(.undo)
        XCTAssertEqual(places(viewer), ["Trip/t02.jpg", "Home/h00.jpg", "Trip/t00.jpg"])
        // From one folder: no folder in the HUD.
        openAndWait(viewer, [trip[1], trip[0]], file: "t01.jpg")
        hudStarts(viewer, ["t01.jpg", "1/2"])
    }
}

/// A folder of the set Peekaboo may not read: the others are browsed and a toast says why and how to allow it; once
/// allowed, the folder joins the set when the window becomes key.
final class SeveralFoldersRefusedTests: ViewerTestCase {
    private func places(_ viewer: ViewerWindowController) -> [String] {
        viewer.pipeline.files.map { "\($0.url.deletingLastPathComponent().lastPathComponent)/\($0.name)" }
    }

    /// `count` images in a folder that then lists no more (-wx--x--x: EACCES). Skipped where permissions are not
    /// enforced.
    private func refusedFolder(_ name: String, _ count: Int) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        writeSequence(count, in: url, prefix: String(name.lowercased().prefix(1)))
        XCTAssertEqual(chmod(url.path, 0o311), 0)
        addTeardownBlock { _ = chmod(url.path, 0o755) }
        let fd = open(url.path, O_RDONLY | O_DIRECTORY)
        if fd >= 0 { close(fd) }
        guard fd < 0 else { throw XCTSkip("permissions are not enforced for this user") }
        return url
    }

    private func becomeKey(_ viewer: ViewerWindowController) {
        viewer.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: viewer.window))
    }

    func testAFolderThatCannotBeReadSaysSoWhileTheOthersAreBrowsed() throws {
        let viewer = try makeViewer()
        let trip = root.appendingPathComponent("Trip", isDirectory: true)
        writeSequence(3, in: trip, prefix: "t")
        let locked = try refusedFolder("Locked", 2)
        let refusal = try XCTUnwrap(ViewerWindowController.accessDeniedToast(POSIXError(.EACCES), folder: locked))
        openAndWait(viewer, [trip, locked], file: "t00.jpg")
        XCTAssertEqual(places(viewer), ["Trip/t00.jpg", "Trip/t01.jpg", "Trip/t02.jpg"])
        XCTAssertEqual(toastText(viewer), refusal)
        XCTAssertNil(hudMessage(viewer))
        // The others browse as usual, to their ends.
        viewer.perform(.last)
        viewer.perform(.next)
        XCTAssertEqual(toastText(viewer), "Last image")

        XCTAssertEqual(chmod(locked.path, 0o755), 0)
        becomeKey(viewer)
        XCTAssertTrue(spin(10) { self.places(viewer).count == 5 }, "the allowed folder did not join: \(places(viewer))")
        XCTAssertEqual(places(viewer), ["Trip/t00.jpg", "Trip/t01.jpg", "Trip/t02.jpg", "Locked/l00.jpg", "Locked/l01.jpg"])
        XCTAssertEqual(viewer.pipeline.currentFile?.name, "t02.jpg")
        let watchers: [Int: FolderWatcher] = try XCTUnwrap(property(viewer, "folderWatchers"))
        XCTAssertEqual(watchers.count, 2, "the allowed folder is not watched")
    }

    func testFoldersThatCannotBeReadSayHowToAllowThemInTheMessage() throws {
        let viewer = try makeViewer()
        let first = try refusedFolder("Locked", 2)
        let second = try refusedFolder("Shut", 1)
        let refusal = try XCTUnwrap(ViewerWindowController.accessDeniedToast(POSIXError(.EACCES), folder: first))
        viewer.open([first, second])
        XCTAssertTrue(spin(5) { !viewer.isListingPendingForTests && self.hudMessage(viewer) != nil })
        XCTAssertEqual(hudMessage(viewer), refusal)
        XCTAssertEqual(viewer.pipeline.files.count, 0)

        XCTAssertEqual(chmod(second.path, 0o755), 0)
        becomeKey(viewer)
        XCTAssertTrue(spin(10) { viewer.displayedFile?.name == "s00.jpg" }, "\(viewer.displayedFile?.name ?? "nothing")")
        XCTAssertNil(hudMessage(viewer))
    }

    /// Empty folders say so, by name for one, by count for more.
    func testEmptyFoldersSayTheyHaveNoImages() throws {
        let viewer = try makeViewer()
        let a = root.appendingPathComponent("A", isDirectory: true)
        let b = root.appendingPathComponent("B", isDirectory: true)
        for url in [a, b] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        viewer.open([a, b])
        XCTAssertTrue(spin(5) { !viewer.isListingPendingForTests && self.hudMessage(viewer) != nil })
        XCTAssertEqual(hudMessage(viewer), "No images in these 2 folders\nDrop images here or press ⌘O")
        // An image arrives in one of them: its watcher lists it.
        writeImage(b.appendingPathComponent("new.jpg"), width: 900, height: 600, gray: 0.5)
        XCTAssertTrue(spin(30) { viewer.displayedFile?.name == "new.jpg" }, "no rescan (utility queue)")
        XCTAssertNil(hudMessage(viewer))
    }
}
