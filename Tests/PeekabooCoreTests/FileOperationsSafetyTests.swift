import XCTest
@testable import PeekabooCore

/// Security and safety of the file actions: `exec:` templates with hostile file names, symbolic links,
/// collisions, undo after outside changes, read-only folders, moves across volumes, and messages.
final class FileOperationsSafetyTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("peekaboo-safety-\(UUID().uuidString)").resolvingSymlinksInPath()
        try fm.createDirectory(at: root.appendingPathComponent("shoot"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        FileOperations.afterCopyingForMove = nil
        FileOperations.movesByCopying = false
        // Read-only folders left by a failed test would stop the removal.
        if let walker = fm.enumerator(atPath: root.path) {
            for case let relative as String in walker {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent(relative).path)
            }
        }
        try? fm.removeItem(at: root)
    }

    @discardableResult
    private func make(_ relative: String, _ contents: String = "pixels") throws -> URL {
        let url = root.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func exists(_ url: URL) -> Bool { FileOperations.itemExists(url) }

    private func listing(_ relative: String) throws -> [String] {
        try fm.contentsOfDirectory(atPath: root.appendingPathComponent(relative).path).sorted()
    }

    // MARK: exec

    /// Run `template` for `file` the way the app does (values only in the environment), in `root`.
    private func runExec(_ template: String, file: URL) throws {
        let command = "cd \"$PEEKABOO_TEST_ROOT\" && " + FileOperations.execCommand(template)
        var environment = FileOperations.execEnvironment(file: file, index: 0, count: 1)
        environment["PEEKABOO_TEST_ROOT"] = root.path
        let done = expectation(description: template)
        FileOperations.run(command, environment: environment) { status, stderr in
            XCTAssertEqual(status, 0, "\(template): \(stderr)")
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
    }

    func testExecNeverRunsCodeFromFileNames() throws {
        let names = ["$(touch PWNED).jpg", "a\"b.jpg", "it's.jpg", "semi;colon.jpg", "`touch PWNED`.jpg",
                     "x'; touch PWNED; '.jpg", "x\"; touch PWNED; \".jpg", "$HOME *.jpg", "-n.jpg", "two  spaces\tand tab.jpg"]
        for name in names {
            let file = try make("shoot/\(name)")
            let out = root.appendingPathComponent("out")
            try runExec("echo {path} > out", file: file)
            XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), file.path + "\n", name)
            try runExec("echo \"x {path}\" > out", file: file)
            XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "x " + file.path + "\n", name)
            try runExec("printf %s {name} > out", file: file)
            XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), name, name)
            try runExec("printf '%s|' '{stem}' 'in {ext} quotes' \"$(basename {path})\" > out", file: file)
            let stem = (name as NSString).deletingPathExtension
            XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "\(stem)|in jpg quotes|\(name)|", name)
            try fm.removeItem(at: file)
        }
        XCTAssertEqual(try listing("."), ["out", "shoot"], "no PWNED file")
        XCTAssertFalse(fm.fileExists(atPath: fm.currentDirectoryPath + "/PWNED"))
    }

    func testExecCommandsHoldNoFileText() {
        XCTAssertEqual(FileOperations.execCommand("open -R {path}"), #"open -R "${PEEKABOO_PATH}""#)
        XCTAssertEqual(FileOperations.execCommand(#"echo "x {path}" > out"#), #"echo "x ${PEEKABOO_PATH}" > out"#)
        XCTAssertEqual(FileOperations.execCommand("printf %s {name} > out"), #"printf %s "${PEEKABOO_NAME}" > out"#)
        XCTAssertEqual(FileOperations.execCommand("echo {dir} {stem}.{ext} {index}/{count}"),
                       #"echo "${PEEKABOO_DIR}" "${PEEKABOO_STEM}"."${PEEKABOO_EXT}" "${PEEKABOO_INDEX}"/"${PEEKABOO_COUNT}""#)
        // Inside single quotes the quote is closed around the reference; already-quoted placeholders still work.
        XCTAssertEqual(FileOperations.execCommand(#"cp '{path}' "{dir}"/b {other}"#),
                       #"cp ''"${PEEKABOO_PATH}"'' "${PEEKABOO_DIR}"/b {other}"#)
        XCTAssertEqual(FileOperations.execCommand("open -a 'Pixelmator Pro' {path}"), #"open -a 'Pixelmator Pro' "${PEEKABOO_PATH}""#)
        // Command substitutions start a new quoting context, also inside double quotes.
        XCTAssertEqual(FileOperations.execCommand(#"echo "$(basename {path})" `echo {name}`"#),
                       #"echo "$(basename "${PEEKABOO_PATH}")" `echo "${PEEKABOO_NAME}"`"#)
        // Escaped braces, shell parameters and comments are left alone; `~/` still expands.
        XCTAssertEqual(FileOperations.execCommand(#"echo \{path} ${path} ~/Desktop/{name} # {name}'s"#),
                       #"echo \{path} ${path} ~/Desktop/"${PEEKABOO_NAME}" # {name}'s"#)
        // The deprecated entry point gives the same command whatever the file.
        XCTAssertEqual(FileOperations.expand("cp {path} x", file: URL(fileURLWithPath: "/a/$(rm -rf ~).jpg"), index: 0, count: 1),
                       #"cp "${PEEKABOO_PATH}" x"#)
        let environment = FileOperations.execEnvironment(file: URL(fileURLWithPath: "/Photos/Trip/IMG_0042.HEIC"), index: 41, count: 120)
        XCTAssertEqual(environment, [
            "PEEKABOO_PATH": "/Photos/Trip/IMG_0042.HEIC", "PEEKABOO_DIR": "/Photos/Trip", "PEEKABOO_NAME": "IMG_0042.HEIC",
            "PEEKABOO_STEM": "IMG_0042", "PEEKABOO_EXT": "HEIC", "PEEKABOO_INDEX": "42", "PEEKABOO_COUNT": "120",
        ])
        XCTAssertEqual(Set(FileOperations.execVariables.values), Set(environment.keys))
    }

    // MARK: Symbolic links

    func testSymbolicLinksMoveCopyAndTrashAsLinks() throws {
        let target = try make("elsewhere/real.jpg", "real")
        let link = root.appendingPathComponent("shoot/link.jpg")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        let ops = FileOperations()
        ops.trashesUndoneCopies = false

        let moved = try ops.move(link, toFolder: root.appendingPathComponent("keep"))
        guard case .moved(_, let to) = moved else { return XCTFail("\(moved)") }
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: to.path), target.path, "the link moved")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "real", "the target stayed")
        XCTAssertEqual(try listing("elsewhere"), ["real.jpg"])
        _ = try ops.undo()
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), target.path)

        let copied = try ops.copy(link, toFolder: root.appendingPathComponent("copies"))
        guard case .copied(_, let copy) = copied else { return XCTFail("\(copied)") }
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: copy.path), target.path, "a link is copied as a link")

        // A move to another volume (copy, then delete) also carries the link.
        let carried = try FileOperations.transfer(link, toFolder: root.appendingPathComponent("card"), mode: .moveByCopying)
        guard case .moved(_, let onCard) = carried else { return XCTFail("\(carried)") }
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: onCard.path), target.path)
        XCTAssertFalse(exists(link))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "real")

        // The Trash takes the link, not the target; undo brings the link back.
        let trashed: FileOperations.Change
        do {
            trashed = try ops.trash(onCard)
        } catch {
            throw XCTSkip("no Trash on this machine: \(error)")
        }
        guard case .trashed(_, let inTrash) = trashed else { return XCTFail("\(trashed)") }
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: inTrash.path), target.path)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "real")
        _ = try ops.undo()
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: onCard.path), target.path)
    }

    // MARK: Collisions

    func testNeverReplacesAnExistingItemNotEvenADanglingLink() throws {
        let photo = try make("shoot/c.jpg", "mine")
        let keep = root.appendingPathComponent("keep")
        try fm.createDirectory(at: keep, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: keep.appendingPathComponent("c.jpg").path, withDestinationPath: "/nonexistent/c.jpg")
        XCTAssertEqual(FileOperations.availableURL(for: "c.jpg", in: keep).lastPathComponent, "c 2.jpg")
        let ops = FileOperations()
        ops.trashesUndoneCopies = false
        XCTAssertEqual(try ops.move(photo, toFolder: keep), .moved(from: photo, to: keep.appendingPathComponent("c 2.jpg")))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: keep.appendingPathComponent("c.jpg").path), "/nonexistent/c.jpg")
        // Copies (into the same folder, and over a taken name) get the next number too.
        let again = keep.appendingPathComponent("c 2.jpg")
        XCTAssertEqual(try ops.copy(again, toFolder: keep), .copied(from: again, to: keep.appendingPathComponent("c 2 2.jpg")))
        try make("keep/sub/c 2.jpg", "older")
        XCTAssertEqual(try FileOperations.transfer(again, toFolder: keep.appendingPathComponent("sub"), mode: .moveByCopying),
                       .moved(from: again, to: keep.appendingPathComponent("sub/c 2 2.jpg")))
        XCTAssertEqual(try String(contentsOf: keep.appendingPathComponent("c 2 2.jpg"), encoding: .utf8), "mine")
        XCTAssertEqual(try String(contentsOf: keep.appendingPathComponent("sub/c 2.jpg"), encoding: .utf8), "older")
        XCTAssertEqual(try listing("keep"), ["c 2 2.jpg", "c.jpg", "sub"], "no temporary files left")
        XCTAssertEqual(try listing("keep/sub"), ["c 2 2.jpg", "c 2.jpg"])
    }

    // MARK: Undo after outside changes

    func testUndoRefusesAFileReplacedOrEditedSinceTheAction() throws {
        let photo = try make("shoot/d.jpg", "original")
        let out = root.appendingPathComponent("out")
        let ops = FileOperations()
        ops.trashesUndoneCopies = false
        try ops.move(photo, toFolder: out)
        // Another file takes its place in out/: undo must not move that one into shoot/.
        try fm.removeItem(at: out.appendingPathComponent("d.jpg"))
        try make("out/d.jpg", "an impostor")
        XCTAssertThrowsError(try ops.undo()) { error in
            XCTAssertEqual("\(error)", "d.jpg was replaced or edited since it was moved: left as it is")
        }
        XCTAssertFalse(exists(photo))
        XCTAssertEqual(ops.undoStack.count, 0, "a change that can never be undone is dropped")

        // A copy edited since: undo leaves it alone instead of deleting the edit.
        let other = try make("shoot/e.jpg", "e")
        try ops.copy(other, toFolder: out)
        let copy = out.appendingPathComponent("e.jpg")
        let handle = try FileHandle(forWritingTo: copy)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" edited".utf8))
        try handle.close()
        XCTAssertThrowsError(try ops.undo()) { error in
            XCTAssertEqual("\(error)", "e.jpg was replaced or edited since it was copied: left as it is")
        }
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "e edited")

        // Redo refuses a file that replaced the one put back.
        let f = try make("shoot/f.jpg", "f")
        let ops2 = FileOperations()
        try ops2.move(f, toFolder: out)
        _ = try ops2.undo()
        try fm.removeItem(at: f)
        try make("shoot/f.jpg", "newer f")
        XCTAssertThrowsError(try ops2.redo()) { error in
            XCTAssertEqual("\(error)", "f.jpg was replaced or edited since it was moved back: left as it is")
        }
        XCTAssertTrue(exists(f))
        XCTAssertEqual(ops2.redoStack.count, 0)

        // Renames and tag changes are not edits: undo still works.
        let g = try make("shoot/g.jpg", "g")
        let ops3 = FileOperations()
        let moved = try ops3.move(g, toFolder: out)
        guard case .moved(_, let gOut) = moved else { return XCTFail("\(moved)") }
        _ = setxattr(gOut.path, "com.example.test", "x", 1, 0, 0)
        _ = try ops3.undo()
        XCTAssertTrue(exists(g))
    }

    func testUndoTrashAfterTheTrashWasEmptied() throws {
        let name = "emptied-\(UUID().uuidString.prefix(8)).jpg"
        let photo = try make("shoot/\(name)")
        let earlier = try make("shoot/earlier.jpg")
        let ops = FileOperations()
        try ops.move(earlier, toFolder: root.appendingPathComponent("keep"))
        let change: FileOperations.Change
        do {
            change = try ops.trash(photo)
        } catch {
            throw XCTSkip("no Trash on this machine: \(error)")
        }
        guard case .trashed(_, let trashed) = change else { return XCTFail("\(change)") }
        try fm.removeItem(at: trashed) // what emptying the Trash does
        XCTAssertThrowsError(try ops.undo()) { error in
            XCTAssertEqual("\(error)", "\(name) is no longer in the Trash")
        }
        XCTAssertFalse(exists(photo))
        // The trash can never be undone now: the next undo reaches the move before it.
        XCTAssertEqual(ops.undoStack.count, 1)
        _ = try ops.undo()
        XCTAssertTrue(exists(earlier))
    }

    func testUndoDropsChangesThatCanNeverBeUndoneAndKeepsOnesThatMaySucceedLater() throws {
        let ops = FileOperations()
        ops.trashesUndoneCopies = false
        let keep = root.appendingPathComponent("keep")
        var moved: [URL] = []
        for n in 1...3 {
            moved.append(try make("shoot/m\(n).jpg"))
            try ops.move(moved[n - 1], toFolder: keep)
        }
        // Moved, then deleted in Finder; a tag change on a file deleted since; a copy edited since.
        try ops.move(try make("shoot/gone.jpg"), toFolder: keep)
        try fm.removeItem(at: keep.appendingPathComponent("gone.jpg"))
        let tagged = try make("shoot/tagged.jpg")
        try ops.setTags(FileOperations.Tags(names: ["Pick"]), of: tagged)
        try fm.removeItem(at: tagged)
        let copied = try make("shoot/copied.jpg")
        try ops.copy(copied, toFolder: keep)
        try Data("edited".utf8).write(to: keep.appendingPathComponent("copied.jpg"))
        XCTAssertEqual(ops.undoStack.count, 6)

        // Each failure is reported once; then undo goes on to the older changes instead of failing forever.
        for message in ["copied.jpg was replaced or edited since it was copied: left as it is",
                        "tagged.jpg is no longer there", "gone.jpg is no longer in keep"] {
            XCTAssertThrowsError(try ops.undo()) { error in XCTAssertEqual("\(error)", message) }
        }
        XCTAssertEqual(ops.undoStack.count, 3)
        XCTAssertEqual(try String(contentsOf: keep.appendingPathComponent("copied.jpg"), encoding: .utf8), "edited")

        // A failure that may pass later (a read-only folder) keeps the change for another try.
        guard getuid() != 0 else { throw XCTSkip("root ignores permissions") }
        let shoot = root.appendingPathComponent("shoot")
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: shoot.path)
        XCTAssertThrowsError(try ops.undo()) { error in
            XCTAssertEqual("\(error)", "Cannot restore m3.jpg: Permission denied")
        }
        XCTAssertEqual(ops.undoStack.count, 3)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shoot.path)
        for photo in moved.reversed() {
            _ = try ops.undo()
            XCTAssertTrue(exists(photo))
        }
        XCTAssertEqual(ops.undoStack.count, 0)

        // Redo drops what can never be redone in the same way.
        XCTAssertEqual(ops.redoStack.count, 3)
        try fm.removeItem(at: moved[0])
        XCTAssertThrowsError(try ops.redo()) { error in XCTAssertEqual("\(error)", "m1.jpg is no longer there") }
        XCTAssertEqual(ops.redoStack.count, 2)
        _ = try ops.redo()
        XCTAssertFalse(exists(moved[1]))
        XCTAssertTrue(exists(keep.appendingPathComponent("m2.jpg")))
    }

    func testUndoNeverDeletesACopyWhenTheTrashIsUnavailable() throws {
        let photo = try make("shoot/backup.jpg", "only copy")
        let share = root.appendingPathComponent("share")
        let ops = FileOperations()
        // A network share without a Trash.
        ops.trashCopy = { _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP)) }
        try ops.copy(photo, toFolder: share)
        try fm.removeItem(at: photo) // the card is formatted: the copy is the only one left
        XCTAssertThrowsError(try ops.undo()) { error in
            XCTAssertEqual("\(error)", "Cannot move the copy to the Trash: Operation not supported")
        }
        XCTAssertEqual(try String(contentsOf: share.appendingPathComponent("backup.jpg"), encoding: .utf8), "only copy")
        XCTAssertEqual(ops.undoStack.count, 1, "the change stays for another try")
        // Once the Trash can take it, undo goes ahead.
        var trashed: [String] = []
        ops.trashCopy = { url in
            trashed.append(url.lastPathComponent)
            try FileManager.default.removeItem(at: url)
        }
        _ = try ops.undo()
        XCTAssertEqual(trashed, ["backup.jpg"])
        XCTAssertEqual(try listing("share"), [])
    }

    // MARK: Read-only folders and volumes

    func testReadOnlyFoldersFailCleanlyWithoutPathsInMessages() throws {
        guard getuid() != 0 else { throw XCTSkip("root ignores permissions") }
        let photo = try make("locked/f.jpg", "f")
        let locked = root.appendingPathComponent("locked")
        let out = root.appendingPathComponent("out")
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        let ops = FileOperations()
        ops.trashesUndoneCopies = false

        XCTAssertThrowsError(try ops.move(photo, toFolder: out)) { error in
            XCTAssertEqual("\(error)", "Cannot move f.jpg: Permission denied")
        }
        XCTAssertTrue(exists(photo))
        // Across volumes the copy comes first; it is removed again when the original cannot be.
        XCTAssertThrowsError(try FileOperations.transfer(photo, toFolder: out, mode: .moveByCopying)) { error in
            XCTAssertEqual("\(error)", "Cannot move f.jpg: Permission denied (its folder is read-only: copy it instead)")
        }
        XCTAssertTrue(exists(photo))
        XCTAssertEqual(try listing("out"), [], "the copy and its temporary file are gone")
        // Copying out of a read-only folder works, and its undo removes only the copy.
        XCTAssertEqual(try ops.copy(photo, toFolder: out), .copied(from: photo, to: out.appendingPathComponent("f.jpg")))
        _ = try ops.undo()
        XCTAssertEqual(try listing("out"), [])

        // Into a read-only folder: nothing moves, nothing is recorded.
        let g = try make("shoot/g.jpg")
        let readOnly = root.appendingPathComponent("readonly")
        try fm.createDirectory(at: readOnly, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        for copy in [false, true] {
            XCTAssertThrowsError(try FileOperations.transfer(g, toFolder: readOnly, copy: copy)) { error in
                XCTAssertEqual("\(error)", "Cannot \(copy ? "copy" : "move") g.jpg: Permission denied")
                XCTAssertFalse("\(error)".contains(self.root.path))
            }
        }
        XCTAssertThrowsError(try FileOperations.transfer(g, toFolder: readOnly.appendingPathComponent("new"), copy: false)) { error in
            XCTAssertTrue("\(error)".hasPrefix("Cannot move g.jpg: cannot create the folder new"), "\(error)")
            XCTAssertFalse("\(error)".contains(self.root.path), "\(error)")
        }
        XCTAssertTrue(exists(g))
        XCTAssertEqual(ops.undoStack, [])
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path)
        XCTAssertEqual(try listing("readonly"), [])
    }

    func testMoveAcrossVolumesCopiesThenRemovesTheOriginal() throws {
        let photo = try make("shoot/h.jpg", "h")
        try make("card/h.jpg", "taken")
        let card = root.appendingPathComponent("card")
        let change = try FileOperations.transfer(photo, toFolder: card, mode: .moveByCopying)
        XCTAssertEqual(change, .moved(from: photo, to: card.appendingPathComponent("h 2.jpg")))
        XCTAssertFalse(exists(photo))
        XCTAssertEqual(try String(contentsOf: card.appendingPathComponent("h 2.jpg"), encoding: .utf8), "h")
        XCTAssertEqual(try String(contentsOf: card.appendingPathComponent("h.jpg"), encoding: .utf8), "taken")
        let ops = FileOperations()
        ops.record(change)
        _ = try ops.undo()
        XCTAssertEqual(try String(contentsOf: photo, encoding: .utf8), "h")
        XCTAssertEqual(try listing("card"), ["h.jpg"])
    }

    /// What another app does when it saves a new version of `url`: write a temporary file, rename it over.
    private func saveNewVersion(_ contents: String, over url: URL) {
        let saved = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).sb-save")
        XCTAssertNoThrow(try Data(contents.utf8).write(to: saved))
        XCTAssertEqual(rename(saved.path, url.path), 0)
    }

    func testMoveAcrossVolumesNeverRemovesAnOriginalThatChangedDuringTheCopy() throws {
        let card = root.appendingPathComponent("card")
        // Replaced by a new version while it was copied: the new version stays, the copy holds the old one.
        let photo = try make("shoot/a.jpg", "version 1")
        FileOperations.afterCopyingForMove = { source in
            if source == photo { self.saveNewVersion("version 2", over: source) }
        }
        let change = try FileOperations.transfer(photo, toFolder: card, mode: .moveByCopying)
        XCTAssertEqual(change, .copied(from: photo, to: card.appendingPathComponent("a.jpg")), "it ends as a copy")
        XCTAssertEqual(try String(contentsOf: photo, encoding: .utf8), "version 2")
        XCTAssertEqual(try String(contentsOf: card.appendingPathComponent("a.jpg"), encoding: .utf8), "version 1")
        // Its undo removes the copy only.
        let ops = FileOperations()
        ops.trashesUndoneCopies = false
        ops.record(change)
        _ = try ops.undo()
        XCTAssertEqual(try listing("card"), [])
        XCTAssertEqual(try String(contentsOf: photo, encoding: .utf8), "version 2")

        // Written to while it was copied: the copy may be torn, so it goes again and nothing moves.
        let edited = try make("shoot/b.jpg", "b")
        FileOperations.afterCopyingForMove = { source in
            guard source == edited, let handle = try? FileHandle(forWritingTo: source) else { return }
            handle.seekToEndOfFile()
            handle.write(Data(" more".utf8))
            try? handle.close()
        }
        XCTAssertThrowsError(try FileOperations.transfer(edited, toFolder: card, mode: .moveByCopying)) { error in
            XCTAssertEqual("\(error)", "Cannot move b.jpg: it changed while it was being copied (left as it is)")
        }
        XCTAssertEqual(try String(contentsOf: edited, encoding: .utf8), "b more")
        XCTAssertEqual(try listing("card"), [], "no copy and no temporary file")

        // Removed meanwhile: the copy stays, as it may now be the only one.
        let removed = try make("shoot/c.jpg", "c")
        FileOperations.afterCopyingForMove = { source in
            if source == removed { try? FileManager.default.removeItem(at: source) }
        }
        XCTAssertEqual(try FileOperations.transfer(removed, toFolder: card, mode: .moveByCopying),
                       .copied(from: removed, to: card.appendingPathComponent("c.jpg")))
        XCTAssertEqual(try String(contentsOf: card.appendingPathComponent("c.jpg"), encoding: .utf8), "c")
    }

    func testUndoAndRedoAcrossVolumesNeverRemoveAFileThatChangedDuringTheCopy() throws {
        FileOperations.movesByCopying = true
        let card = root.appendingPathComponent("card")
        let ops = FileOperations()
        ops.trashesUndoneCopies = false
        // Undo copies the file back from the card; a version saved on the card meanwhile stays there.
        let photo = try make("shoot/d.jpg", "d1")
        try ops.move(photo, toFolder: card)
        let onCard = card.appendingPathComponent("d.jpg")
        FileOperations.afterCopyingForMove = { source in
            if source == onCard { self.saveNewVersion("d2", over: source) }
        }
        XCTAssertThrowsError(try ops.undo()) { error in
            XCTAssertEqual("\(error)", "d.jpg changed while it was being moved back: both versions kept")
        }
        XCTAssertEqual(try String(contentsOf: photo, encoding: .utf8), "d1")
        XCTAssertEqual(try String(contentsOf: onCard, encoding: .utf8), "d2")
        XCTAssertEqual(ops.undoStack.count, 0, "it cannot be undone any more")

        // Redo copies it to the card again; a version saved in the shoot folder meanwhile stays there.
        let other = try make("shoot/e.jpg", "e1")
        FileOperations.afterCopyingForMove = nil
        try ops.move(other, toFolder: card)
        _ = try ops.undo()
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "e1")
        FileOperations.afterCopyingForMove = { source in
            if source == other { self.saveNewVersion("e2", over: source) }
        }
        XCTAssertEqual(try ops.redo(), .copied(from: other, to: card.appendingPathComponent("e.jpg")))
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "e2")
        XCTAssertEqual(try String(contentsOf: card.appendingPathComponent("e.jpg"), encoding: .utf8), "e1")
        XCTAssertEqual(try listing("card"), ["d.jpg", "e.jpg"])
    }

    func testMissingSourcesAndSameFolderMoves() throws {
        let ops = FileOperations()
        XCTAssertThrowsError(try ops.move(root.appendingPathComponent("shoot/gone.jpg"), toFolder: root)) { error in
            XCTAssertEqual("\(error)", "gone.jpg is no longer there")
        }
        // The same folder through a symbolic link is still the same folder.
        let photo = try make("shoot/same.jpg")
        let alias = root.appendingPathComponent("alias")
        try fm.createSymbolicLink(atPath: alias.path, withDestinationPath: root.appendingPathComponent("shoot").path)
        XCTAssertThrowsError(try ops.move(photo, toFolder: alias)) { error in
            XCTAssertEqual("\(error)", "same.jpg is already in alias")
        }
        XCTAssertEqual(try listing("shoot"), ["same.jpg"])
    }

    // MARK: Destinations

    func testDestinationsAreAbsoluteAndNormalised() {
        let photo = root.appendingPathComponent("shoot/IMG_1.jpg")
        let parent = root.deletingLastPathComponent().path
        XCTAssertEqual(FileOperations.destination(for: "../../x/../y", slots: [:], imageURL: photo)?.path, parent + "/y")
        XCTAssertEqual(FileOperations.destination(for: "./a/./b/..", slots: [:], imageURL: photo)?.path,
                       root.appendingPathComponent("shoot/a").path)
        XCTAssertEqual(FileOperations.destination(for: "up", slots: ["up": " ../Selects "], imageURL: photo)?.path,
                       root.appendingPathComponent("Selects").path)
        XCTAssertEqual(FileOperations.destination(for: "/tmp/../var/x", slots: [:], imageURL: photo)?.path, "/var/x")
        // A defined slot name is only a key; an undefined one is not a path unless it looks like one.
        XCTAssertEqual(FileOperations.destination(for: "..", slots: ["..": "~/Keep"], imageURL: photo)?.path,
                       fm.homeDirectoryForCurrentUser.appendingPathComponent("Keep").path)
        XCTAssertNil(FileOperations.destination(for: "keep", slots: [:], imageURL: photo))
        XCTAssertNil(FileOperations.destination(for: "blank", slots: ["blank": "  "], imageURL: photo))
        XCTAssertNil(FileOperations.destination(for: "", slots: [:], imageURL: photo))
    }
}
