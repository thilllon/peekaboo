import XCTest
@testable import PeekabooCore

/// `FileOperations` (the file-system half of `FileActions`) on temporary directories.
final class ConfigFileOpsTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("peekaboo-fileops-\(UUID().uuidString)").resolvingSymlinksInPath()
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

    private func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    func testTrashAndUndoRedo() throws {
        let photo = try make("shoot/IMG_0001.jpg")
        let ops = FileOperations()
        let change: FileOperations.Change
        do {
            change = try ops.trash(photo)
        } catch {
            throw XCTSkip("no Trash on this machine: \(error)")
        }
        guard case .trashed(let original, let trashed) = change else { return XCTFail("\(change)") }
        XCTAssertEqual(original, photo)
        XCTAssertFalse(exists(photo))
        XCTAssertTrue(exists(trashed))

        let undone = try XCTUnwrap(try ops.undo())
        guard case .trashed(let restored, _) = undone else { return XCTFail("\(undone)") }
        XCTAssertEqual(restored.path, photo.path)
        XCTAssertTrue(exists(photo))
        XCTAssertFalse(exists(trashed))
        XCTAssertNil(try ops.undo())

        // Redo trashes it again; undo once more so nothing is left in the Trash.
        _ = try ops.redo()
        XCTAssertFalse(exists(photo))
        _ = try ops.undo()
        XCTAssertTrue(exists(photo))
    }

    func testMoveCopyCollisionsAndUndo() throws {
        let photo = try make("shoot/IMG_0002.jpg", "original")
        try make("keep/IMG_0002.jpg", "older")
        try make("keep/IMG_0002 2.jpg", "older too")
        let keep = root.appendingPathComponent("keep")
        let ops = FileOperations()
        ops.trashesUndoneCopies = false // keep test files out of the user's Trash

        let moved = try ops.move(photo, toFolder: keep)
        XCTAssertEqual(moved, .moved(from: photo, to: keep.appendingPathComponent("IMG_0002 3.jpg")))
        XCTAssertFalse(exists(photo))
        XCTAssertEqual(try String(contentsOf: keep.appendingPathComponent("IMG_0002 3.jpg"), encoding: .utf8), "original")
        XCTAssertEqual(try String(contentsOf: keep.appendingPathComponent("IMG_0002.jpg"), encoding: .utf8), "older",
                       "never overwrites")

        _ = try ops.undo()
        XCTAssertTrue(exists(photo))
        XCTAssertFalse(exists(keep.appendingPathComponent("IMG_0002 3.jpg")))

        // Copy into a folder that does not exist yet; undo removes only the copy.
        let fresh = root.appendingPathComponent("new/sub")
        let copied = try ops.copy(photo, toFolder: fresh)
        XCTAssertEqual(copied, .copied(from: photo, to: fresh.appendingPathComponent("IMG_0002.jpg")))
        XCTAssertTrue(exists(photo))
        XCTAssertTrue(exists(fresh.appendingPathComponent("IMG_0002.jpg")))
        _ = try ops.undo()
        XCTAssertTrue(exists(photo))
        XCTAssertFalse(exists(fresh.appendingPathComponent("IMG_0002.jpg")))
        // Redo copies again.
        _ = try ops.redo()
        XCTAssertTrue(exists(fresh.appendingPathComponent("IMG_0002.jpg")))
        try fm.removeItem(at: fresh.appendingPathComponent("IMG_0002.jpg"))

        XCTAssertThrowsError(try ops.move(photo, toFolder: photo.deletingLastPathComponent())) { error in
            XCTAssertTrue("\(error)".contains("already in shoot"), "\(error)")
        }
    }

    func testUndoRestoresBesideATakenName() throws {
        let photo = try make("shoot/a.jpg", "first")
        let ops = FileOperations()
        try ops.move(photo, toFolder: root.appendingPathComponent("out"))
        try make("shoot/a.jpg", "newcomer")
        let undone = try XCTUnwrap(try ops.undo())
        XCTAssertEqual(undone, .moved(from: root.appendingPathComponent("shoot/a 2.jpg"), to: root.appendingPathComponent("out/a.jpg")))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("shoot/a 2.jpg"), encoding: .utf8), "first")
    }

    func testUndoDropsTheChangeWhenItsFileIsGone() throws {
        let photo = try make("shoot/b.jpg")
        let ops = FileOperations()
        try ops.move(photo, toFolder: root.appendingPathComponent("out"))
        try fm.removeItem(at: root.appendingPathComponent("out/b.jpg"))
        XCTAssertThrowsError(try ops.undo())
        XCTAssertEqual(ops.undoStack.count, 0)
    }

    func testDestinationsSlotsAndRelativePaths() throws {
        let photo = root.appendingPathComponent("shoot/IMG_1.jpg")
        let slots = ["1": "~/Pictures/Keep", "rejects": "./_rejects", "abs": "/Volumes/Card/Out", "up": "../Selects"]
        let home = fm.homeDirectoryForCurrentUser.path
        XCTAssertEqual(FileOperations.destination(for: "1", slots: slots, imageURL: photo)?.path, home + "/Pictures/Keep")
        XCTAssertEqual(FileOperations.destination(for: "rejects", slots: slots, imageURL: photo)?.path,
                       root.appendingPathComponent("shoot/_rejects").path)
        XCTAssertEqual(FileOperations.destination(for: "up", slots: slots, imageURL: photo)?.path,
                       root.appendingPathComponent("Selects").path)
        XCTAssertEqual(FileOperations.destination(for: "abs", slots: slots, imageURL: photo)?.path, "/Volumes/Card/Out")
        XCTAssertEqual(FileOperations.destination(for: "./_keep", slots: [:], imageURL: photo)?.path,
                       root.appendingPathComponent("shoot/_keep").path)
        XCTAssertEqual(FileOperations.destination(for: "~/x", slots: [:], imageURL: photo)?.path, home + "/x")
        XCTAssertNil(FileOperations.destination(for: "2", slots: slots, imageURL: photo))
        XCTAssertNil(FileOperations.destination(for: "keep", slots: slots, imageURL: photo))

        // A relative slot moves the file into a subfolder next to it.
        let real = try make("shoot/IMG_9.jpg")
        let ops = FileOperations()
        let folder = try XCTUnwrap(FileOperations.destination(for: "rejects", slots: slots, imageURL: real))
        try ops.move(real, toFolder: folder)
        XCTAssertTrue(exists(root.appendingPathComponent("shoot/_rejects/IMG_9.jpg")))
    }

    func testBackgroundTransferJoinsTheUndoStack() throws {
        let photo = try make("shoot/bg.jpg")
        let folder = root.appendingPathComponent("elsewhere")
        XCTAssertFalse(FileOperations.crossesVolumes(photo, folder), "same volume, folder not created yet")
        let ops = FileOperations()
        let change = try FileOperations.transfer(photo, toFolder: folder, copy: false)
        XCTAssertTrue(ops.undoStack.isEmpty)
        ops.record(change)
        _ = try ops.undo()
        XCTAssertTrue(exists(photo))
        XCTAssertFalse(exists(folder.appendingPathComponent("bg.jpg")))
    }

    func testAvailableNames() throws {
        let folder = root.appendingPathComponent("shoot")
        XCTAssertEqual(FileOperations.availableURL(for: "x.jpg", in: folder).lastPathComponent, "x.jpg")
        try make("shoot/x.jpg")
        XCTAssertEqual(FileOperations.availableURL(for: "x.jpg", in: folder).lastPathComponent, "x 2.jpg")
        try make("shoot/noext")
        XCTAssertEqual(FileOperations.availableURL(for: "noext", in: folder).lastPathComponent, "noext 2")
        try make("shoot/archive.tar.gz")
        XCTAssertEqual(FileOperations.availableURL(for: "archive.tar.gz", in: folder).lastPathComponent, "archive.tar 2.gz")
    }

    func testExecTemplatesReferenceQuotedVariables() {
        let file = URL(fileURLWithPath: "/Photos/It's a \"trip\"/IMG $1 `x`.HEIC")
        XCTAssertEqual(FileOperations.shellQuote("it's"), #"'it'\''s'"#)
        // The command never contains the file's text, only quoted variable references.
        XCTAssertEqual(FileOperations.execCommand("open -R {path}"), #"open -R "${PEEKABOO_PATH}""#)
        XCTAssertEqual(FileOperations.execCommand("echo {dir} {name} {stem} {ext} {index}/{count}"),
                       #"echo "${PEEKABOO_DIR}" "${PEEKABOO_NAME}" "${PEEKABOO_STEM}" "${PEEKABOO_EXT}" "${PEEKABOO_INDEX}"/"${PEEKABOO_COUNT}""#)
        XCTAssertEqual(FileOperations.execEnvironment(file: file, index: 4, count: 120)["PEEKABOO_DIR"], #"/Photos/It's a "trip""#)
        // Already-quoted placeholders work; unknown braces stay.
        XCTAssertEqual(FileOperations.execCommand("cp '{path}' \"{dir}\"/b {other}"),
                       #"cp ''"${PEEKABOO_PATH}"'' "${PEEKABOO_DIR}"/b {other}"#)
        // A placeholder spelled in a value is never expanded: values are not in the command at all.
        XCTAssertEqual(FileOperations.execEnvironment(file: URL(fileURLWithPath: "/a/{path}.jpg"), index: 0, count: 1)["PEEKABOO_NAME"],
                       "{path}.jpg")
    }

    func testExecRunsThroughTheShellOffTheMainThread() throws {
        let file = try make("shoot/name with 'quotes' $HOME.jpg")
        let out = root.appendingPathComponent("out.txt")
        let template = "printf '%s|%s|%s' {name} \"$PEEKABOO_INDEX\" {count} > " + FileOperations.shellQuote(out.path)
        let done = expectation(description: "ran")
        let command = FileOperations.runExec(template, file: file, index: 2, count: 7) { status, _ in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(status, 0)
            done.fulfill()
        }
        XCTAssertFalse(command.contains("quotes"), command)
        wait(for: [done], timeout: 5)
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "name with 'quotes' $HOME.jpg|3|7")

        let failed = expectation(description: "failed")
        FileOperations.run("echo oops >&2; exit 3") { status, stderr in
            XCTAssertEqual(status, 3)
            XCTAssertEqual(stderr, "oops")
            failed.fulfill()
        }
        wait(for: [failed], timeout: 5)
    }

    func testTagSchemes() {
        var tags = FileOperations.Tags(names: ["Project", "★★"], label: 0)
        tags = FileOperations.rating(4, star: "★", in: tags)
        XCTAssertEqual(tags.names, ["Project", "★★★★"])
        XCTAssertEqual(FileOperations.rating(of: tags, star: "★"), 4)
        tags = FileOperations.rating(0, star: "★", in: tags)
        XCTAssertEqual(tags.names, ["Project"])
        XCTAssertEqual(FileOperations.rating(3, star: "*", in: FileOperations.Tags(names: ["***", "★"])).names, ["***"])

        tags = FileOperations.label("red", in: tags)
        XCTAssertEqual(tags, FileOperations.Tags(names: ["Project", "Red"], label: 6, colors: ["Red": 6]))
        tags = FileOperations.label("blue", in: tags, labelNames: ["없음", "회색", "초록색", "보라색", "파란색", "노란색", "빨간색", "주황색"])
        XCTAssertEqual(tags, FileOperations.Tags(names: ["Project", "파란색"], label: 4, colors: ["파란색": 4]))
        tags = FileOperations.label("none", in: tags, labelNames: ["없음", "회색", "초록색", "보라색", "파란색", "노란색", "빨간색", "주황색"])
        XCTAssertEqual(tags, FileOperations.Tags(names: ["Project"], label: 0))

        tags = FileOperations.flag("pick", in: tags)
        XCTAssertEqual(tags.names, ["Project", "Pick"])
        tags = FileOperations.flag("reject", in: tags)
        XCTAssertEqual(tags.names, ["Project", "Reject"])
        tags = FileOperations.flag("none", in: tags)
        XCTAssertEqual(tags.names, ["Project"])
    }

    func testFinderTagsRoundTripWithUndo() throws {
        let photo = try make("shoot/tagged.jpg")
        let ops = FileOperations()
        let rated = FileOperations.rating(3, star: "★", in: FileOperations.tags(of: photo))
        try ops.setTags(FileOperations.label("green", in: FileOperations.flag("pick", in: rated)), of: photo)
        var tags = FileOperations.tags(of: URL(fileURLWithPath: photo.path))
        guard !tags.names.isEmpty else { throw XCTSkip("volume does not store Finder tags") }
        XCTAssertEqual(Set(tags.names), ["★★★", "Pick", "Green"])
        XCTAssertEqual(tags.colors, ["Green": 2])
        XCTAssertEqual(tags.label, 2)
        // Finder's own API agrees on the names.
        XCTAssertEqual(Set(try URL(fileURLWithPath: photo.path).resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []),
                       ["★★★", "Pick", "Green"])
        _ = try ops.undo()
        tags = FileOperations.tags(of: URL(fileURLWithPath: photo.path))
        XCTAssertEqual(tags, FileOperations.Tags())
        _ = try ops.redo()
        XCTAssertEqual(FileOperations.tags(of: URL(fileURLWithPath: photo.path)).label, 2)
    }

    func testSequentialTagChangesOnTheSameURLSeeEachOther() throws {
        let photo = try make("shoot/list.jpg")
        let ops = FileOperations()
        // An action list such as ["meta.rate:3", "meta.flag:pick"] runs within one run-loop pass.
        try ops.setTags(FileOperations.rating(3, star: "★", in: FileOperations.tags(of: photo)), of: photo)
        try ops.setTags(FileOperations.flag("pick", in: FileOperations.tags(of: photo)), of: photo)
        let names = FileOperations.tags(of: photo).names
        guard !names.isEmpty else { throw XCTSkip("volume does not store Finder tags") }
        XCTAssertEqual(Set(names), ["★★★", "Pick"])
    }

    func testKeepsTheColoursOfOtherTags() throws {
        let photo = try make("shoot/colours.jpg")
        let entries = ["Project\n3", "Draft"]
        let data = try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
        let written = data.withUnsafeBytes { setxattr(photo.path, FileOperations.tagAttribute, $0.baseAddress, data.count, 0, 0) }
        guard written == 0 else { throw XCTSkip("volume does not store extended attributes") }
        let ops = FileOperations()
        try ops.setTags(FileOperations.rating(2, star: "★", in: FileOperations.tags(of: photo)), of: photo)
        let tags = FileOperations.tags(of: photo)
        XCTAssertEqual(tags.names, ["Project", "Draft", "★★"])
        XCTAssertEqual(tags.colors, ["Project": 3])
        _ = try ops.undo()
        XCTAssertEqual(FileOperations.tags(of: photo), FileOperations.Tags(names: ["Project", "Draft"], colors: ["Project": 3]))
    }

    func testImageFileStat() throws {
        let photo = try make("shoot/s.jpg", "12345")
        let file = FileOperations.imageFile(at: photo)
        XCTAssertEqual(file.byteSize, 5)
        XCTAssertGreaterThan(file.modified, 0)
        XCTAssertGreaterThan(file.fileID, 0)
        XCTAssertEqual(file.name, "s.jpg")
    }
}
