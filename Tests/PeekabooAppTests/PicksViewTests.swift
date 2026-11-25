import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import PeekabooApp
@testable import PeekabooCore

/// Culling with picks (#76): the picks-only view, the pick counter in the HUD and copying every pick, on a headless
/// viewer.
final class PicksViewTests: ViewerTestCase {
    private func hudLine(_ viewer: ViewerWindowController) -> String {
        let content: HUDContent? = property(hud(viewer), "content")
        return content?.line ?? ""
    }

    /// The parts of the HUD line (name, position, counter, then dimensions and zoom once the photo is decoded).
    private func hudParts(_ viewer: ViewerWindowController) -> [String] {
        hudLine(viewer).components(separatedBy: "  ·  ")
    }

    private func hudStarts(_ viewer: ViewerWindowController, _ parts: [String], line: UInt = #line) {
        XCTAssertEqual(Array(hudParts(viewer).prefix(parts.count)), parts, hudLine(viewer), line: line)
    }

    private func hudHas(_ viewer: ViewerWindowController, _ part: String) -> Bool { hudParts(viewer).contains(part) }

    private func names(_ viewer: ViewerWindowController) -> [String] { viewer.pipeline.files.map(\.name) }

    /// Flag `urls` Pick on disk, as `meta.flag:pick` does.
    private func pick(_ urls: [URL]) throws {
        let ops = FileOperations()
        for url in urls { try ops.setTags(FileOperations.flag("pick", in: FileOperations.tags(of: url)), of: url) }
        guard urls.allSatisfy(FileOperations.isPicked) else { throw XCTSkip("volume does not store Finder tags") }
    }

    /// Until the folder's tags are read (the counter shows `count` picks, none: no counter).
    private func waitForPicks(_ viewer: ViewerWindowController, _ count: Int, line: UInt = #line) {
        let done = spin(10) {
            let picks: PickSet? = self.property(viewer, "picks")
            return picks?.isReading == false && (count == 0 ? !self.hudLine(viewer).contains("Picks")
                : self.hudHas(viewer, "Picks \(count)"))
        }
        XCTAssertTrue(done, "the picks were not read: \(hudLine(viewer))", line: line)
    }

    func testThePicksOnlyViewBrowsesThePicksInFolderOrderAndPrefetchesThem() throws {
        let viewer = try makeViewer()
        let urls = writeSequence(40)
        try pick([urls[1], urls[20], urls[39]])
        openAndWait(viewer, [urls[0]])
        waitForPicks(viewer, 3)
        hudStarts(viewer, ["img00.jpg", "1/40", "Picks 3"])

        // The photo on screen stays, though it is not a pick, until the user moves on: → goes to the next pick.
        viewer.perform(.picksOnly)
        XCTAssertTrue(viewer.isPicksOnly)
        XCTAssertEqual(viewer.displayedFile?.name, "img00.jpg")
        XCTAssertEqual(names(viewer), ["img00.jpg", "img01.jpg", "img20.jpg", "img39.jpg"])
        hudStarts(viewer, ["img00.jpg", "Not a pick", "Picks 3"])
        viewer.perform(.next)
        XCTAssertEqual(viewer.pipeline.currentFile?.name, "img01.jpg")
        XCTAssertEqual(names(viewer), ["img01.jpg", "img20.jpg", "img39.jpg"])
        hudStarts(viewer, ["img01.jpg", "Picks 1/3"])

        // Prefetch follows the view: the next pick, 19 photos further on in the folder, gets its screen tier.
        let next = viewer.pipeline.files[1]
        XCTAssertTrue(spin(10) { viewer.pipeline.cachedTiers(for: next).contains(.screen) }, "the next pick was not prefetched")
        viewer.perform(.next)
        XCTAssertEqual(viewer.displayedFile?.name, "img20.jpg", "a prefetched pick shows in the frame of the key press")
        viewer.perform(.last)
        hudStarts(viewer, ["img39.jpg", "Picks 3/3"])
        viewer.perform(.next)
        XCTAssertEqual(toastText(viewer), "Last pick")
        viewer.perform(.first)
        XCTAssertEqual(viewer.pipeline.currentFile?.name, "img01.jpg")
        viewer.perform(.jump(10))
        XCTAssertEqual(viewer.pipeline.currentFile?.name, "img39.jpg")

        // Back to every photo, on the one on screen.
        viewer.perform(.picksOnly)
        XCTAssertFalse(viewer.isPicksOnly)
        XCTAssertEqual(viewer.pipeline.files.count, 40)
        XCTAssertEqual(viewer.pipeline.currentFile?.name, "img39.jpg")
        hudStarts(viewer, ["img39.jpg", "40/40", "Picks 3"])
        XCTAssertEqual(toastText(viewer), "All photos: 40")
        XCTAssertTrue(spin(10) { viewer.displayedFile?.name == "img39.jpg" }, "\(viewer.displayedFile?.name ?? "nothing") on screen")
    }

    func testThePickCounterFollowsEveryMark() throws {
        let viewer = try makeViewer()
        let urls = writeSequence(5)
        openAndWait(viewer, [urls[0]])
        waitForPicks(viewer, 0)
        viewer.perform(.flag("pick"))
        XCTAssertTrue(hudHas(viewer, "Picks 1"), "the counter follows in the same frame: \(hudLine(viewer))")
        viewer.perform(.next)
        viewer.perform(.flag("pick"))
        XCTAssertTrue(hudHas(viewer, "Picks 2"), hudLine(viewer))
        viewer.perform(.flag("reject"))
        XCTAssertTrue(hudHas(viewer, "Picks 1"), "a reject is no pick: \(hudLine(viewer))")
        viewer.perform(.undo)
        XCTAssertTrue(hudHas(viewer, "Picks 2"), "undo brings the pick back: \(hudLine(viewer))")
        XCTAssertTrue(FileOperations.isPicked(urls[0]) && FileOperations.isPicked(urls[1]), "the picks are Finder tags")

        // A pick moved out of the folder no longer counts; undo brings it back with its tag.
        viewer.perform(.move("./_out"))
        XCTAssertEqual(viewer.pipeline.currentFile?.name, "img02.jpg")
        XCTAssertTrue(hudHas(viewer, "Picks 1"), hudLine(viewer))
        viewer.perform(.undo)
        XCTAssertEqual(viewer.pipeline.currentFile?.name, "img01.jpg")
        XCTAssertTrue(spin(10) { self.hudHas(viewer, "Picks 2") }, hudLine(viewer))
        // The folder watcher's rescans (the move, the undo) leave the count as it is.
        spin(1)
        XCTAssertTrue(hudHas(viewer, "Picks 2"), hudLine(viewer))

        viewer.perform(.flag("none"))
        viewer.perform(.previous)
        viewer.perform(.flag("none"))
        XCTAssertFalse(hudLine(viewer).contains("Picks"), "no picks, no counter: \(hudLine(viewer))")
    }

    func testAnUnpickedPhotoStaysUntilTheUserMovesOn() throws {
        let viewer = try makeViewer()
        let urls = writeSequence(8)
        try pick([urls[2], urls[4], urls[6]])
        openAndWait(viewer, [urls[2]])
        waitForPicks(viewer, 3)
        viewer.perform(.picksOnly)
        XCTAssertEqual(names(viewer), ["img02.jpg", "img04.jpg", "img06.jpg"])
        XCTAssertTrue(hudHas(viewer, "Picks 1/3"), hudLine(viewer))
        viewer.perform(.next)
        XCTAssertTrue(spin(5) { viewer.displayedFile?.name == "img04.jpg" })
        viewer.perform(.flag("none"))
        XCTAssertEqual(viewer.displayedFile?.name, "img04.jpg", "an un-picked photo stays on screen")
        XCTAssertEqual(viewer.pipeline.currentFile?.name, "img04.jpg")
        XCTAssertEqual(names(viewer), ["img02.jpg", "img04.jpg", "img06.jpg"])
        hudStarts(viewer, ["img04.jpg", "Not a pick", "Picks 2"])
        // Picked again before moving on: it is a pick of the view again.
        viewer.perform(.flag("pick"))
        XCTAssertTrue(hudHas(viewer, "Picks 2/3"), hudLine(viewer))
        viewer.perform(.flag("reject"))
        viewer.perform(.next)
        XCTAssertEqual(viewer.pipeline.currentFile?.name, "img06.jpg")
        XCTAssertEqual(names(viewer), ["img02.jpg", "img06.jpg"], "the rejected photo left the view when the user moved on")
        XCTAssertTrue(hudHas(viewer, "Picks 2/2"), hudLine(viewer))
        viewer.perform(.previous)
        XCTAssertEqual(viewer.pipeline.currentFile?.name, "img02.jpg")
        // shift+u: clear the flag and advance, in one key press.
        guard case .actions(let clearAndNext) = Keymap.default.resolve(try KeyChord.parseSequence("shift+u"), context: .normal)
        else { return XCTFail("shift+u is unbound") }
        for action in clearAndNext { viewer.perform(action) }
        XCTAssertEqual(names(viewer), ["img06.jpg"])
        XCTAssertTrue(hudHas(viewer, "Picks 1/1"), hudLine(viewer))
        // Undoing that un-pick brings img02 back into the view; the photo on screen stays.
        viewer.perform(.undo)
        XCTAssertEqual(names(viewer), ["img02.jpg", "img06.jpg"])
        XCTAssertEqual(viewer.pipeline.currentFile?.name, "img06.jpg")
        XCTAssertTrue(hudHas(viewer, "Picks 2/2"), hudLine(viewer))
        XCTAssertFalse(FileOperations.isPicked(urls[4]))
    }

    func testTogglingKeepsThePhotoOnScreen() throws {
        let viewer = try makeViewer()
        let urls = writeSequence(8)
        try pick([urls[1], urls[6]])
        openAndWait(viewer, [urls[4]])
        waitForPicks(viewer, 2)
        // Into the view and straight back, on a photo that is not a pick: the same photo, at its place in the folder.
        viewer.perform(.picksOnly)
        XCTAssertEqual(viewer.displayedFile?.name, "img04.jpg")
        XCTAssertEqual(names(viewer), ["img01.jpg", "img04.jpg", "img06.jpg"])
        viewer.perform(.picksOnly)
        XCTAssertEqual(viewer.pipeline.files.count, 8)
        XCTAssertEqual(viewer.pipeline.index, 4)
        XCTAssertEqual(viewer.displayedFile?.name, "img04.jpg")
        // ← from there goes to the pick before it.
        viewer.perform(.picksOnly)
        viewer.perform(.previous)
        XCTAssertEqual(viewer.pipeline.currentFile?.name, "img01.jpg")
        XCTAssertEqual(names(viewer), ["img01.jpg", "img06.jpg"])
        // Finder opens a photo the view leaves out: every photo again, on that one.
        viewer.open([urls[3]])
        XCTAssertFalse(viewer.isPicksOnly)
        XCTAssertEqual(viewer.pipeline.currentFile?.name, "img03.jpg")
        XCTAssertEqual(viewer.pipeline.files.count, 8)
    }

    func testThereIsNoPicksOnlyViewWithoutPicks() throws {
        let viewer = try makeViewer()
        let urls = writeSequence(3)
        openAndWait(viewer, [urls[0]])
        waitForPicks(viewer, 0)
        viewer.perform(.picksOnly)
        XCTAssertFalse(viewer.isPicksOnly)
        XCTAssertEqual(toastText(viewer), "No picks yet: P picks the photo on screen")
        viewer.perform(.copyPicks("ask"))
        XCTAssertEqual(toastText(viewer), "No picks to copy yet: P picks the photo on screen")
    }

    func testPicksAreOffWithoutFinderTagStorage() throws {
        let viewer = try makeViewer(toml: "[rating]\nstorage = \"none\"\n")
        let urls = writeSequence(3)
        try pick([urls[0]])
        openAndWait(viewer, [urls[0]])
        spin(0.3)
        XCTAssertFalse(hudLine(viewer).contains("Picks"), hudLine(viewer))
        viewer.perform(.picksOnly)
        XCTAssertFalse(viewer.isPicksOnly)
        XCTAssertEqual(toastText(viewer), "Picks are off ([rating] storage = \"none\")")
    }

    func testCopyingEveryPickNeverOverwritesAndReportsWhatItDid() throws {
        let selects = root.appendingPathComponent("selects")
        let viewer = try makeViewer(toml: "[slots]\nselects = \"\(selects.path)\"\n")
        let urls = writeSequence(6)
        try pick([urls[1], urls[3], urls[5]])
        // Another photo has one of the names already.
        try FileManager.default.createDirectory(at: selects, withIntermediateDirectories: true)
        let other = writeImage(selects.appendingPathComponent("img03.jpg"), width: 300, height: 200, gray: 0.9)
        let otherBytes = try Data(contentsOf: other)
        openAndWait(viewer, [urls[0]])
        waitForPicks(viewer, 3)

        viewer.perform(.copyPicks("selects"))
        XCTAssertTrue(spin(10) { self.toastText(viewer)?.hasPrefix("Copied") == true }, toastText(viewer) ?? "no toast")
        XCTAssertEqual(toastText(viewer),
                       "Copied 3 picks to selects · 1 saved under a new name (img03 2.jpg) · ⌘Z won't remove the copies")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: selects.path).sorted(),
                       ["img01.jpg", "img03 2.jpg", "img03.jpg", "img05.jpg"])
        XCTAssertEqual(try Data(contentsOf: other), otherBytes, "the photo that had the name was replaced")
        XCTAssertEqual(try Data(contentsOf: selects.appendingPathComponent("img03 2.jpg")), try Data(contentsOf: urls[3]))

        // Copying again (to the last folder) copies only what is new: one pick less, one more.
        viewer.perform(.next)
        viewer.perform(.flag("none"))
        viewer.perform(.jump(3))
        viewer.perform(.flag("pick"))
        viewer.perform(.copyPicks("last"))
        XCTAssertTrue(spin(10) { self.toastText(viewer)?.hasPrefix("Copied") == true }, toastText(viewer) ?? "no toast")
        XCTAssertEqual(toastText(viewer),
                       "Copied 1 of 3 picks to selects · 2 already there · ⌘Z won't remove the copies")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: selects.path).sorted(),
                       ["img01.jpg", "img03 2.jpg", "img03.jpg", "img04.jpg", "img05.jpg"])

        // In the picks-only view, the photo on screen that was just un-picked is no pick to copy.
        viewer.perform(.picksOnly)
        XCTAssertEqual(viewer.pipeline.currentFile?.name, "img04.jpg")
        viewer.perform(.flag("none"))
        viewer.perform(.copyPicks("selects"))
        XCTAssertTrue(spin(10) { self.toastText(viewer)?.hasPrefix("All") == true }, toastText(viewer) ?? "no toast")
        XCTAssertEqual(toastText(viewer), "All 2 picks are already in selects")
    }

    func testMovingTheLastPickAwayEndsThePicksOnlyView() throws {
        let viewer = try makeViewer()
        let urls = writeSequence(5)
        try pick([urls[2]])
        openAndWait(viewer, [urls[2]])
        waitForPicks(viewer, 1)
        viewer.perform(.picksOnly)
        XCTAssertEqual(names(viewer), ["img02.jpg"])
        viewer.perform(.move("./_out"))
        XCTAssertFalse(viewer.isPicksOnly)
        XCTAssertEqual(viewer.pipeline.currentFile?.name, "img03.jpg")
        XCTAssertEqual(viewer.pipeline.files.count, 4)
        XCTAssertTrue(toastText(viewer)?.hasSuffix(" · no picks left") == true, toastText(viewer) ?? "no toast")
        XCTAssertFalse(hudLine(viewer).contains("Picks"), hudLine(viewer))
    }

    /// Another app adds a picked photo to the folder: the rescan reads its tags and it joins the view.
    func testAPickAddedToTheFolderJoinsTheView() throws {
        let viewer = try makeViewer()
        let urls = writeSequence(4)
        try pick([urls[0], urls[2]])
        openAndWait(viewer, [urls[0]])
        waitForPicks(viewer, 2)
        viewer.perform(.picksOnly)
        let incoming = writeImage(root.appendingPathComponent("incoming.jpg"), width: 900, height: 600, gray: 0.3)
        try pick([incoming])
        try FileManager.default.moveItem(at: incoming, to: folder.appendingPathComponent("img01b.jpg"))
        // The rescan runs on a utility queue: slow to get a core on a loaded CI machine.
        XCTAssertTrue(spin(30) { self.names(viewer) == ["img00.jpg", "img01b.jpg", "img02.jpg"] }, "\(names(viewer))")
        XCTAssertEqual(viewer.pipeline.currentFile?.name, "img00.jpg")
        XCTAssertTrue(hudHas(viewer, "Picks 1/3"), hudLine(viewer))
    }

    /// A pick moved out of the folder and put back by another app (Finder, Put Back) counts again; a pick another app
    /// saves anew without its tags no longer counts.
    func testThePicksFollowFilesThatComeBackOrAreRewritten() throws {
        let viewer = try makeViewer()
        let urls = writeSequence(6)
        try pick([urls[1], urls[3]])
        openAndWait(viewer, [urls[3]])
        waitForPicks(viewer, 2)
        viewer.perform(.move("./_out"))
        XCTAssertTrue(hudHas(viewer, "Picks 1"), hudLine(viewer))
        // The folder watcher's rescan of the move changes nothing.
        spin(1)
        try FileManager.default.moveItem(at: folder.appendingPathComponent("_out/img03.jpg"), to: urls[3])
        XCTAssertTrue(spin(30) { self.hudHas(viewer, "Picks 2") }, "the returning pick was not read again: \(hudLine(viewer))")

        // Saved anew by an editor: a new file renamed over it, without the tags.
        atomicallyReplace(urls[3], width: 1200, height: 800, gray: 0.7, type: .jpeg)
        XCTAssertFalse(FileOperations.isPicked(urls[3]))
        XCTAssertTrue(spin(30) { self.hudHas(viewer, "Picks 1") }, "the rewritten photo still counts: \(hudLine(viewer))")
    }

    /// Copying every pick copies what the files say, though another app changed the tags since they were read; the
    /// counter and the view follow that read.
    func testCopyingThePicksReadsTheirTagsAgain() throws {
        let selects = root.appendingPathComponent("selects")
        let viewer = try makeViewer(toml: "[slots]\nselects = \"\(selects.path)\"\n")
        let urls = writeSequence(6)
        try pick([urls[1], urls[3]])
        openAndWait(viewer, [urls[1]])
        waitForPicks(viewer, 2)
        viewer.perform(.picksOnly)
        XCTAssertEqual(names(viewer), ["img01.jpg", "img03.jpg"])
        // Finder moves the pick from img03 to img05 (a tag change raises no folder event).
        let ops = FileOperations()
        try ops.setTags(FileOperations.flag("none", in: FileOperations.tags(of: urls[3])), of: urls[3])
        try pick([urls[5]])
        viewer.perform(.copyPicks("selects"))
        XCTAssertTrue(spin(10) { self.toastText(viewer)?.hasPrefix("Copied") == true }, toastText(viewer) ?? "no toast")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: selects.path).sorted(), ["img01.jpg", "img05.jpg"])
        XCTAssertEqual(names(viewer), ["img01.jpg", "img05.jpg"])
        hudStarts(viewer, ["img01.jpg", "Picks 1/2"])
    }

    /// The undo stack outlives a folder: undoing a flag change of the folder browsed before leaves this one's picks.
    func testAnUndoInAnotherFolderLeavesThisFoldersPicksAlone() throws {
        let viewer = try makeViewer()
        let urls = writeSequence(3)
        openAndWait(viewer, [urls[0]])
        waitForPicks(viewer, 0)
        viewer.perform(.flag("pick"))
        viewer.perform(.flag("none"))
        let other = writeSequence(3, in: root.appendingPathComponent("other"), prefix: "oth")
        openAndWait(viewer, [other[0]])
        waitForPicks(viewer, 0)
        viewer.perform(.undo)
        XCTAssertTrue(FileOperations.isPicked(urls[0]), "the undo was not applied")
        spin(0.3)
        XCTAssertFalse(hudLine(viewer).contains("Picks"), hudLine(viewer))
        viewer.perform(.picksOnly)
        XCTAssertFalse(viewer.isPicksOnly)
    }

    /// Another app deletes the last pick, which is on screen: the view ends there, on the photo after it.
    func testARescanThatTakesTheLastPickEndsTheViewInPlace() throws {
        let viewer = try makeViewer()
        let urls = writeSequence(10)
        try pick([urls[7]])
        openAndWait(viewer, [urls[7]])
        waitForPicks(viewer, 1)
        viewer.perform(.picksOnly)
        try FileManager.default.removeItem(at: urls[7])
        XCTAssertTrue(spin(30) { !viewer.isPicksOnly }, "the view did not end")
        XCTAssertEqual(viewer.pipeline.currentFile?.name, "img08.jpg")
        XCTAssertEqual(viewer.pipeline.files.count, 9)
        XCTAssertEqual(toastText(viewer), "No picks left: all photos")
    }

    /// Until the folder's first tag read lands, the counter shows nothing rather than the picks seen so far (the photo
    /// on screen, whose own tags are read first).
    func testTheCounterWaitsForTheFolderRead() throws {
        let viewer = try makeViewer()
        let photo = writeImage(folder.appendingPathComponent("IMG_2000.jpg"), width: 600, height: 400, gray: 0.4)
        try pick([photo])
        for i in 0..<4000 {
            let url = folder.appendingPathComponent(String(format: "IMG_%04d.jpg", i < 2000 ? i : i + 1))
            FileManager.default.createFile(atPath: url.path, contents: nil)
            if i % 100 == 0 { try pick([url]) }
        }
        viewer.open([photo])
        var counters = Set<String>()
        let read = spin(30) {
            counters.formUnion(self.hudParts(viewer).filter { $0.hasPrefix("Picks") })
            let picks: PickSet? = self.property(viewer, "picks")
            return picks?.isReading == false && self.hudHas(viewer, "Picks 41")
        }
        XCTAssertTrue(read, hudLine(viewer))
        XCTAssertEqual(counters, ["Picks 41"])
    }

    /// Un-picking the only pick of the view leaves a view without picks: the next move goes on among every photo.
    func testUnpickingTheLastPickOfTheViewLetsTheUserMoveOn() throws {
        let viewer = try makeViewer()
        let urls = writeSequence(5)
        try pick([urls[2]])
        openAndWait(viewer, [urls[2]])
        waitForPicks(viewer, 1)
        viewer.perform(.picksOnly)
        viewer.perform(.flag("none"))
        hudStarts(viewer, ["img02.jpg", "Not a pick", "No picks left"])
        viewer.perform(.next)
        XCTAssertFalse(viewer.isPicksOnly)
        XCTAssertEqual(viewer.pipeline.currentFile?.name, "img03.jpg")
        XCTAssertEqual(toastText(viewer), "No picks left: all photos")
        hudStarts(viewer, ["img03.jpg", "4/5"])
    }

    /// After a long look at the photo (past the 2.5 s prefetch horizon), toggling the view still prefetches the photo
    /// the next key press shows: the next pick on the way in, the next photo of the folder on the way out.
    func testTogglingAfterALongLookPrefetchesTheNextPhoto() throws {
        let viewer = try makeViewer()
        let urls = writeSequence(40)
        try pick(stride(from: 0, to: 40, by: 10).map { urls[$0] })
        openAndWait(viewer, [urls[10]])
        waitForPicks(viewer, 4)
        spin(3)
        viewer.perform(.picksOnly)
        let nextPick = viewer.pipeline.files[2]
        XCTAssertEqual(nextPick.name, "img20.jpg")
        XCTAssertTrue(spin(10) { viewer.pipeline.cachedTiers(for: nextPick).contains(.screen) }, "the next pick was not prefetched")
        spin(3)
        viewer.perform(.picksOnly)
        let next = viewer.pipeline.files[11]
        XCTAssertTrue(spin(10) { viewer.pipeline.cachedTiers(for: next).contains(.screen) }, "the next photo was not prefetched")
    }

    /// A copy's progress toasts never cover another toast, and stop once the user moves on to another photo (the
    /// summary still comes).
    func testProgressToastsNeverCoverAnotherToast() throws {
        let viewer = try makeViewer()
        let urls = writeSequence(3)
        openAndWait(viewer, [urls[0]])
        viewer.perform(.flag("pick"))
        let actions: FileActions = try XCTUnwrap(property(viewer, "$__lazy_storage_$_fileActions"))
        func report(_ text: String, _ progress: FileActionResult.ProgressToast) {
            actions.onLateResult?(FileActionResult(toast: text, progress: progress))
        }
        report("Copying 3 picks to selects…", .start)
        report("Copying picks to selects: 1 of 3…", .update)
        XCTAssertEqual(toastText(viewer), "Copying picks to selects: 1 of 3…")
        viewer.perform(.flag("reject"))
        report("Copying picks to selects: 2 of 3…", .update)
        XCTAssertEqual(toastText(viewer), "Reject")
        report("Copying 3 picks to selects…", .start)
        viewer.perform(.next)
        report("Copying picks to selects: 1 of 3…", .update)
        XCTAssertEqual(toastText(viewer), "Copying 3 picks to selects…")
        actions.onLateResult?(FileActionResult(toast: "Copied 3 picks to selects"))
        XCTAssertEqual(toastText(viewer), "Copied 3 picks to selects")
    }

    /// The help overlay and the menu show the picks actions with their keys (the Settings editor: `SettingsWindowTests`).
    func testThePicksActionsShowTheirKeys() throws {
        let section = try XCTUnwrap(KeyLabels.helpSections(Keymap.default).first { $0.title == "Rate, Label & Pick" })
        XCTAssertTrue(section.lines.contains { $0.keys == "V" && $0.title == "Show Picks Only" }, "\(section.lines)")
        XCTAssertTrue(section.lines.contains { $0.keys == "⇧C" && $0.title == "Copy All Picks to…" }, "\(section.lines)")
        XCTAssertEqual(KeyLabels.menuChord(for: .picksOnly, in: Keymap.default), KeyChord(key: "v"))
        XCTAssertEqual(KeyLabels.menuChord(for: .copyPicks("ask"), in: Keymap.default), KeyChord(key: "c", modifiers: .shift))
        XCTAssertEqual(KeyLabels.title(.copyPicks("keep")), "Copy All Picks to keep")
    }

    /// Rule #1: a navigation costs the main thread the same in the picks-only view as in the whole folder.
    func testNavigationCostsTheSameInThePicksOnlyView() throws {
        let viewer = try makeViewer()
        let urls = writeSequence(60, width: 1600, height: 1067)
        try pick(stride(from: 0, to: 60, by: 2).map { urls[$0] })
        openAndWait(viewer, [urls[0]])
        waitForPicks(viewer, 30)
        func measure() -> Double {
            spin(1)
            var times: [Double] = []
            for action in [Action.next, .previous] {
                for _ in 0..<20 {
                    let started = Trace.now()
                    viewer.perform(action)
                    times.append(Trace.ms(since: started))
                    spin(0.15)
                }
            }
            return times.sorted()[times.count / 2]
        }
        let all = measure()
        viewer.perform(.picksOnly)
        let picksOnly = measure()
        print(String(format: "navigation main thread (median): %.3f ms in the folder, %.3f ms in the picks-only view",
                     all, picksOnly))
        XCTAssertLessThan(picksOnly, max(2 * all, all + 1), "a navigation in the picks-only view costs more")
    }
}
