import Foundation

/// The file-system half of the file actions, free of AppKit so it can be tested on temp dirs:
/// trash / move / copy / Finder tags with a session-long undo stack, destination resolution
/// (slots, `~`, paths relative to the image's folder, "name 2.ext" on collisions) and `exec:`
/// templates. The app's `FileActions` adds the pasteboard, Finder and other-app parts.
///
/// Safety rules: an existing item is never replaced (a taken name becomes "name 2.ext", decided
/// atomically by an exclusive rename); a symbolic link is moved, copied or trashed as the link, never
/// its target; undo and redo refuse to touch a file that was replaced or edited since the action;
/// and failure messages name files, not their full paths.
///
/// Not thread-safe: use it from one thread (the main thread in the app). Every operation is a
/// rename, a copy or one `setxattr`, so it returns quickly on the same volume; what copies across
/// volumes runs elsewhere through `transfer` + `record`, and `takeSlowUndo`/`takeSlowRedo` + `perform` +
/// `finish`.
public final class FileOperations {
    /// One undoable change.
    public enum Change: Equatable, Sendable {
        case trashed(original: URL, trashed: URL)
        case moved(from: URL, to: URL)
        case copied(from: URL, to: URL)
        case tagged(URL, before: Tags, after: Tags)
    }

    /// Finder tag names plus the colour label number (0 none, 1 gray, 2 green, 3 purple, 4 blue,
    /// 5 yellow, 6 red, 7 orange).
    public struct Tags: Equatable, Sendable {
        public var names: [String]
        public var label: Int
        /// Finder colour (label number) of the tags that have one, e.g. `["Red": 6]`.
        public var colors: [String: Int]
        public init(names: [String] = [], label: Int = 0, colors: [String: Int] = [:]) {
            self.names = names
            self.label = label
            self.colors = colors
        }
    }

    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let message: String
        /// Trying again cannot succeed (the file is gone, or was replaced or edited): undo and redo drop the change.
        let permanent: Bool
        public init(_ message: String) { self.init(message, permanent: false) }
        init(_ message: String, permanent: Bool) {
            self.message = message
            self.permanent = permanent
        }
        public var description: String { message }
    }

    /// Changes that can be undone, oldest first.
    public var undoStack: [Change] { undoEntries.map(\.change) }
    /// Undone changes that can be redone, oldest first.
    public var redoStack: [Change] { redoEntries.map(\.change) }
    /// Undoing a copy moves the copy to the Trash, as Finder does; false deletes it (tests).
    public var trashesUndoneCopies = true
    /// How undo puts a copy in the Trash (tests stand in a volume without one).
    var trashCopy: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    /// Tests: runs right after a move across volumes copied `source`, before the original is checked and
    /// removed (stands in for another app saving the file meanwhile).
    nonisolated(unsafe) static var afterCopyingForMove: ((_ source: URL) -> Void)?
    /// Tests: every move, undo and redo included, copies and then deletes, as across volumes.
    nonisolated(unsafe) static var movesByCopying = false
    private let fm = FileManager.default

    /// A change plus the identity of the item that its undo (or redo) acts on, so that neither touches a
    /// file that was replaced or edited since.
    fileprivate struct Entry: Sendable {
        let change: Change
        let stamp: Stamp?
    }

    private var undoEntries: [Entry] = []
    private var redoEntries: [Entry] = []
    /// How many changes `record(_:)` has pushed (`finish(_:with:)` tells which came while it ran).
    private var recordedCount = 0

    public init() {}

    // MARK: Operations

    /// Move to the Trash (undo moves it back). A symbolic link is trashed itself, never its target.
    @discardableResult
    public func trash(_ url: URL) throws -> Change {
        let change = try performTrash(url)
        record(change)
        return change
    }

    /// Move into `folder` (created if missing); a name collision becomes "name 2.ext".
    @discardableResult
    public func move(_ url: URL, toFolder folder: URL) throws -> Change {
        let change = try Self.transfer(url, toFolder: folder, copy: false)
        record(change)
        return change
    }

    /// Copy into `folder` (created if missing); a name collision becomes "name 2.ext".
    @discardableResult
    public func copy(_ url: URL, toFolder folder: URL) throws -> Change {
        let change = try Self.transfer(url, toFolder: folder, copy: true)
        record(change)
        return change
    }

    /// Replace the Finder tags and colour label.
    @discardableResult
    public func setTags(_ tags: Tags, of url: URL) throws -> Change {
        let before = Self.tags(of: url)
        try Self.write(tags, to: url)
        let change = Change.tagged(url, before: before, after: tags)
        record(change)
        return change
    }

    /// Undo the most recent change. Returns the change as it now sits on the redo stack, with the
    /// restored location (a "name 2.ext" if the old name was taken meanwhile); nil when there is nothing
    /// to undo. Throws when it cannot: a change whose item is gone (e.g. the Trash was emptied) or was
    /// replaced or edited since the action is dropped, so that the next undo reaches the older changes;
    /// any other failure (a read-only folder, a full disk) keeps it for another try.
    public func undo() throws -> Change? {
        guard let entry = undoEntries.popLast() else { return nil }
        let result = Result<Entry, Error> {
            let redo: Change
            switch entry.change {
            case .trashed(let original, let trashed):
                try Self.check(entry.stamp, at: trashed, name: original.lastPathComponent,
                               missing: "is no longer in the Trash", since: "trashed")
                let restored = try Self.restore(trashed, to: original)
                redo = .trashed(original: restored, trashed: trashed)
            case .moved(let from, let to):
                redo = try Self.undoMove(from: from, to: to, stamp: entry.stamp)
            case .copied(let from, let to):
                try removeCopy(to, stamp: entry.stamp)
                redo = .copied(from: from, to: to)
            case .tagged(let url, let before, let after):
                try Self.requireItem(url)
                try Self.write(before, to: url)
                redo = .tagged(url, before: before, after: after)
            }
            return Entry(change: redo, stamp: Self.stamp(redoing: redo))
        }
        return try settle(entry, undo: true, result)
    }

    /// Redo the most recently undone change; returns the change as redone. Throws when it cannot, dropping
    /// the change when its file is gone or was replaced or edited since it was put back (as `undo()` does).
    public func redo() throws -> Change? {
        guard let entry = redoEntries.popLast() else { return nil }
        let result = Result<Entry, Error> {
            let redone: Change
            switch entry.change {
            case .trashed(let original, _):
                try Self.check(entry.stamp, at: original, missing: "is no longer there", since: "put back")
                redone = try performTrash(original)
            case .moved, .copied:
                redone = try Self.redoTransfer(entry.change, stamp: entry.stamp)
            case .tagged(let url, let before, let after):
                try Self.requireItem(url)
                try Self.write(after, to: url)
                redone = .tagged(url, before: before, after: after)
            }
            return Entry(change: redone, stamp: Self.stamp(undoing: redone))
        }
        return try settle(entry, undo: false, result)
    }

    /// Push a change made elsewhere (e.g. a cross-volume move finished on a background queue) onto the
    /// undo stack. Call it right after the change: it notes the identity of the file the undo will touch.
    public func record(_ change: Change) {
        undoEntries.append(Entry(change: change, stamp: Self.stamp(undoing: change)))
        redoEntries.removeAll()
        recordedCount += 1
    }

    /// The file work of undoing a move (thread-safe: no stacks).
    private static func undoMove(from: URL, to: URL, stamp: Stamp?) throws -> Change {
        try check(stamp, at: to, missing: "is no longer in \(to.deletingLastPathComponent().lastPathComponent)", since: "moved")
        let back = try restore(to, to: from)
        return .moved(from: back, to: to)
    }

    /// The file work of redoing a move or a copy (thread-safe: no stacks).
    private static func redoTransfer(_ change: Change, stamp: Stamp?) throws -> Change {
        switch change {
        case .moved(let from, let to):
            try check(stamp, at: from, missing: "is no longer there", since: "moved back")
            return try transfer(from, toFolder: to.deletingLastPathComponent(), copy: false)
        case .copied(let from, let to):
            return try transfer(from, toFolder: to.deletingLastPathComponent(), copy: true)
        case .trashed, .tagged:
            throw Failure("Cannot redo this change here")
        }
    }

    /// Put the result of undoing (or redoing) `entry` where it belongs: the resulting entry on the other
    /// stack, or `entry` back on its own after a failure that may pass. A change that can never be undone
    /// (its file is gone, or was replaced or edited) is dropped instead, so that the next undo reaches the
    /// older changes rather than failing on it for the rest of the session. `recordedSince` changes were
    /// recorded while the work ran (`finish(_:with:)`): they stay above it, and an undone change can no
    /// longer be redone.
    private func settle(_ entry: Entry, undo: Bool, _ result: Result<Entry, Error>, recordedSince: Int = 0) throws -> Change {
        switch result {
        case .success(let done):
            if !undo {
                undoEntries.insert(done, at: max(0, undoEntries.count - recordedSince))
            } else if recordedSince == 0 {
                redoEntries.append(done)
            }
            return done.change
        case .failure(let error):
            if let failure = error as? Failure, failure.permanent { throw failure }
            if undo {
                undoEntries.insert(entry, at: max(0, undoEntries.count - recordedSince))
            } else if recordedSince == 0 {
                redoEntries.append(entry)
            }
            throw error
        }
    }

    // MARK: Undo and redo off the main thread

    /// An undo or redo that copies a file across volumes (seconds for a large file on a card or a network
    /// share), taken off its stack so that it can run off the main thread: `perform(_:)` it on any thread,
    /// then hand the result to `finish(_:with:)` on the owning one.
    public struct SlowChange: Sendable {
        fileprivate let entry: Entry
        public let isUndo: Bool
        fileprivate let recordedBefore: Int
        /// The change as it stood on its stack.
        public var change: Change { entry.change }
    }

    /// Take the next undo off the stack if it copies the file back across volumes; nil when the next
    /// undo is quick (use `undo()`) or there is none.
    public func takeSlowUndo() -> SlowChange? {
        guard let entry = undoEntries.last, case .moved(let from, let to) = entry.change,
              Self.movesByCopying || Self.crossesVolumes(to, from.deletingLastPathComponent()) else { return nil }
        undoEntries.removeLast()
        return SlowChange(entry: entry, isUndo: true, recordedBefore: recordedCount)
    }

    /// Take the next redo off the stack if it copies (a move across volumes, or a copy); nil otherwise.
    public func takeSlowRedo() -> SlowChange? {
        guard let entry = redoEntries.last else { return nil }
        switch entry.change {
        case .moved(let from, let to):
            guard Self.movesByCopying || Self.crossesVolumes(from, to.deletingLastPathComponent()) else { return nil }
        case .copied: break
        case .trashed, .tagged: return nil
        }
        redoEntries.removeLast()
        return SlowChange(entry: entry, isUndo: false, recordedBefore: recordedCount)
    }

    /// What `perform(_:)` did, for `finish(_:with:)`.
    public struct SlowResult: Sendable {
        /// The entry for the other stack, with the identity of the item that its next undo or redo acts on,
        /// read off the main thread too (a lookup on a card or a share can take milliseconds).
        fileprivate let result: Result<Entry, Error>
    }

    /// The file work of a taken undo or redo. Thread-safe: it touches no stack.
    public static func perform(_ slow: SlowChange) -> SlowResult {
        SlowResult(result: Result {
            if slow.isUndo, case .moved(let from, let to) = slow.entry.change {
                let redo = try undoMove(from: from, to: to, stamp: slow.entry.stamp)
                return Entry(change: redo, stamp: stamp(redoing: redo))
            }
            let redone = try redoTransfer(slow.entry.change, stamp: slow.entry.stamp)
            return Entry(change: redone, stamp: stamp(undoing: redone))
        })
    }

    /// Settle a taken undo or redo as `undo()` and `redo()` do, on the owning thread. Changes recorded while
    /// it ran stay above it on the undo stack.
    @discardableResult
    public func finish(_ slow: SlowChange, with done: SlowResult) throws -> Change {
        try settle(slow.entry, undo: slow.isUndo, done.result, recordedSince: recordedCount - slow.recordedBefore)
    }

    private func performTrash(_ url: URL) throws -> Change {
        try Self.requireItem(url)
        var resulting: NSURL?
        do {
            // Moves the directory entry itself: a symbolic link goes to the Trash, its target stays.
            try fm.trashItem(at: url, resultingItemURL: &resulting)
        } catch {
            throw Failure("Cannot move \(url.lastPathComponent) to the Trash: \(Self.reason(error))")
        }
        guard let trashed = resulting as URL? else { throw Failure("The Trash did not return a location") }
        return .trashed(original: url, trashed: trashed)
    }

    /// Move or copy into `folder` without recording it (thread-safe; `record(_:)` it on the owning thread).
    /// Never replaces an existing item (a taken name becomes "name 2.ext"), never follows a symbolic link
    /// (a link is moved or copied as a link), and a move to another volume removes the original only
    /// once the copy is complete, putting things back as they were when it cannot.
    ///
    /// A move to another volume removes the original only if it is still the file that was copied. When
    /// another app replaced it meanwhile (saved a new version over it) or it was renamed or removed, the
    /// result is `.copied`: the copy holds the version that was copied and the original is left as it is.
    /// When it was edited in place, the copy may be torn: it is removed again, and the move fails.
    public static func transfer(_ url: URL, toFolder folder: URL, copy: Bool) throws -> Change {
        try transfer(url, toFolder: folder, mode: copy ? .copy : .move)
    }

    enum Mode {
        case move, copy
        /// A move done as copy-then-delete, as across volumes (tests force it on one volume).
        case moveByCopying
    }

    static func transfer(_ url: URL, toFolder folder: URL, mode: Mode) throws -> Change {
        let copy = mode == .copy
        let verb = copy ? "copy" : "move"
        let name = url.lastPathComponent
        let folder = folder.standardizedFileURL
        try requireItem(url)
        if !copy, isSameDirectory(folder, url.deletingLastPathComponent()) {
            throw Failure("\(name) is already in \(folder.lastPathComponent)")
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw Failure("Cannot \(verb) \(name): cannot create the folder \(folder.lastPathComponent) (\(reason(error)))")
        }
        do {
            switch try place(url, as: name, in: folder, mode: mode) {
            case .moved(let target): return .moved(from: url, to: target)
            case .copied(let target): return .copied(from: url, to: target)
            }
        } catch let failure as PlaceFailure {
            throw Failure("Cannot \(verb) \(name): \(failure.reason)", permanent: failure.changed)
        }
    }

    /// Put `url` back at `original` (or "name 2.ext" next to it if that name was taken meanwhile).
    private static func restore(_ url: URL, to original: URL) throws -> URL {
        let folder = original.deletingLastPathComponent()
        let name = original.lastPathComponent
        let placed: Placed
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            placed = try place(url, as: name, in: folder, mode: .move)
        } catch let failure as PlaceFailure {
            throw Failure("Cannot restore \(name): \(failure.reason)", permanent: failure.changed)
        } catch {
            throw Failure("Cannot restore \(name): \(reason(error))")
        }
        switch placed {
        case .moved(let back): return back
        case .copied:
            // Changed by another app while it was copied back across volumes: both versions are kept.
            throw Failure("\(name) changed while it was being moved back: both versions kept", permanent: true)
        }
    }

    private func removeCopy(_ url: URL, stamp: Stamp?) throws {
        guard Self.itemExists(url) else { return }
        // Never trash or delete a file that replaced the copy, or the copy after it was edited.
        try Self.check(stamp, at: url, missing: "is no longer there", since: "copied")
        // The copy of a locked file is locked too: unlock it to remove it, and lock it again if that fails.
        let flags = Self.flags(url) ?? 0
        let locked = flags & Self.lockFlags != 0
        if locked { lchflags(url.path, flags & ~Self.lockFlags) }
        do {
            if trashesUndoneCopies {
                do {
                    try trashCopy(url)
                } catch {
                    // Never delete it instead (a network share has no Trash): the copy may be the only one left.
                    throw Failure("Cannot move the copy to the Trash: \(Self.reason(error))")
                }
            } else {
                do { try fm.removeItem(at: url) } catch { throw Failure("Cannot remove the copy: \(Self.reason(error))") }
            }
        } catch {
            if locked { lchflags(url.path, flags) }
            throw error
        }
    }

    private static func reason(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return String(cString: strerror(Int32(ns.code))) }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return String(cString: strerror(Int32(underlying.code)))
        }
        return ns.localizedFailureReason ?? ns.localizedDescription
    }

    // MARK: Placing files safely

    private struct PlaceFailure: Error {
        let reason: String
        /// The item changed while it was being moved: trying again cannot move the version that was meant.
        var changed = false
        init(_ code: Int32, hint: String = "") { reason = String(cString: strerror(code)) + hint }
        init(changed reason: String) {
            self.reason = reason
            changed = true
        }
    }

    /// Where `place` put the item.
    private enum Placed {
        case moved(URL)
        /// Copied (a copy, or a move across volumes whose original changed meanwhile and was left as it is).
        case copied(URL)
    }

    /// Move or copy `source` to `folder/name`, or to the first free "stem N.ext". Exclusive: an existing item
    /// (a dangling symbolic link included) is never replaced, not even one that appears while this runs.
    private static func place(_ source: URL, as name: String, in folder: URL, mode requested: Mode) throws -> Placed {
        let mode = requested == .move && movesByCopying ? .moveByCopying : requested
        if mode == .move {
            var n = 1
            while true {
                let target = numberedURL(name, n, in: folder)
                n += 1
                if itemExists(target) { continue }
                if renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 { return .moved(target) }
                let code = errno
                switch code {
                case EEXIST: continue
                case EXDEV: return try place(source, as: name, in: folder, mode: .moveByCopying)
                case ENOTSUP, EINVAL:
                    // A file system without exclusive renames (some network volumes): check, then rename.
                    if itemExists(target) { continue }
                    if rename(source.path, target.path) == 0 { return .moved(target) }
                    throw renameFailure(errno, source)
                default: throw renameFailure(code, source)
                }
            }
        }
        // What a move must find again after the copy before it may remove the original.
        let original = mode == .moveByCopying ? Snapshot(source) : nil
        // A locked file cannot be removed, so it cannot be moved (as it cannot be renamed): say so before copying.
        if let original, original.flags & (lockFlags | systemLockFlags) != 0 {
            throw PlaceFailure(EPERM, hint: " (it is locked)")
        }
        // Copy to a private name in the destination folder, then rename that exclusively into place: a failed
        // copy leaves nothing behind, and no existing file is ever written to.
        let temporary = folder.appendingPathComponent(".peekaboo-\(UUID().uuidString).tmp")
        // COPYFILE_CLONE: an instant clone on APFS, else a full copy with metadata; a link is copied as a link.
        // (It is not exclusive by itself, hence the private name.)
        if copyfile(source.path, temporary.path, nil, copyfile_flags_t(COPYFILE_CLONE)) != 0 {
            let code = errno
            discard(temporary)
            throw PlaceFailure(code)
        }
        if mode == .moveByCopying { afterCopyingForMove?(source) }
        // The copy of a locked file is locked too, and could be neither renamed into place nor removed:
        // unlock it until it is in place, then lock it like the original.
        let copiedFlags = flags(temporary) ?? 0
        let locked = copiedFlags & lockFlags != 0
        if locked { lchflags(temporary.path, copiedFlags & ~lockFlags) }
        var n = 1
        var target: URL
        while true {
            target = numberedURL(name, n, in: folder)
            n += 1
            if itemExists(target) { continue }
            if renamex_np(temporary.path, target.path, UInt32(RENAME_EXCL)) == 0 { break }
            let code = errno
            if code == EEXIST { continue }
            if code == ENOTSUP || code == EINVAL, !itemExists(target), rename(temporary.path, target.path) == 0 { break }
            discard(temporary)
            throw PlaceFailure(code)
        }
        if locked { lchflags(target.path, copiedFlags) }
        guard mode == .moveByCopying else { return .copied(target) }
        // The copy is complete. Remove the original only if it is still the item that was copied, unchanged:
        // another app may have saved a new version meanwhile (a temporary file renamed over it), and removing
        // that would lose it. (`unlink` removes a link, never its target.)
        let now = Snapshot(source)
        if let original, now == original {
            if unlink(source.path) == 0 { return .moved(target) }
            let code = errno
            discard(target)
            let readOnly = code == EACCES || code == EPERM || code == EROFS
            throw PlaceFailure(code, hint: readOnly ? " (its folder is read-only: copy it instead)" : "")
        }
        if let original, let now, now.isSameItem(as: original) {
            // Written to while it was copied: the copy may hold parts of two versions. Keep only the original.
            discard(target)
            throw PlaceFailure(changed: "it changed while it was being copied (left as it is)")
        }
        // Replaced, renamed or removed meanwhile: the copy holds the version that was copied; leave the rest alone.
        return .copied(target)
    }

    /// Finder's "Locked" and append-only: a file with either can be neither renamed nor removed.
    private static let lockFlags = UInt32(UF_IMMUTABLE | UF_APPEND)
    /// The same set by the system, which no app can clear.
    private static let systemLockFlags = UInt32(SF_IMMUTABLE | SF_APPEND)

    /// The BSD flags of the item at `url` (not following a symbolic link).
    private static func flags(_ url: URL) -> UInt32? {
        var st = stat()
        return lstat(url.path, &st) == 0 ? st.st_flags : nil
    }

    private static func isLocked(_ url: URL) -> Bool { (flags(url) ?? 0) & (lockFlags | systemLockFlags) != 0 }

    /// Remove an item this code made (a temporary file, a copy), unlocking it first: the copy of a locked
    /// file is locked too, and `unlink` alone would leave it behind.
    private static func discard(_ url: URL) {
        if let flags = flags(url), flags & lockFlags != 0 { lchflags(url.path, flags & ~lockFlags) }
        unlink(url.path)
    }

    /// The failure of renaming `source`, saying so when it is locked.
    private static func renameFailure(_ code: Int32, _ source: URL) -> PlaceFailure {
        PlaceFailure(code, hint: code == EPERM && isLocked(source) ? " (it is locked)" : "")
    }

    /// `folder/name` for n = 1, else "stem n.ext".
    private static func numberedURL(_ name: String, _ n: Int, in folder: URL) -> URL {
        guard n > 1 else { return folder.appendingPathComponent(name) }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        return folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
    }

    /// Whether anything has this name, without following a symbolic link (a dangling link counts).
    static func itemExists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    /// Whether two paths name the same directory (also through symbolic links or a different letter case).
    static func isSameDirectory(_ a: URL, _ b: URL) -> Bool {
        var sa = stat(), sb = stat()
        if stat(a.path, &sa) == 0, stat(b.path, &sb) == 0 { return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino }
        return a.standardizedFileURL.path == b.standardizedFileURL.path
    }

    // MARK: Change detection

    /// Identity and version of the item at a path (not following a symbolic link): another file, or the
    /// same file after an edit, has a different stamp. Renames and tag changes keep it.
    // Every field is read by the synthesized ==, which is all a stamp is for (periphery reports them as assign-only).
    struct Stamp: Equatable {
        let device: Int64
        let inode: UInt64
        let size: Int64
        let seconds: Int
        let nanoseconds: Int

        init?(_ url: URL) {
            var st = stat()
            guard lstat(url.path, &st) == 0 else { return nil }
            self.init(st)
        }

        init(_ st: stat) {
            device = Int64(st.st_dev)
            inode = UInt64(st.st_ino)
            size = Int64(st.st_size)
            seconds = st.st_mtimespec.tv_sec
            nanoseconds = st.st_mtimespec.tv_nsec
        }
    }

    /// The item at a path exactly as it is: its `Stamp` plus the status-change time, which also moves on a
    /// write that keeps the size and modification time, and on tag, permission and lock changes.
    // Every field is read by the synthesized == (periphery reports them as assign-only).
    private struct Snapshot: Equatable {
        let stamp: Stamp
        let changeSeconds: Int
        let changeNanoseconds: Int
        /// BSD file flags (`UF_IMMUTABLE` is Finder's "Locked").
        let flags: UInt32

        init?(_ url: URL) {
            var st = stat()
            guard lstat(url.path, &st) == 0 else { return nil }
            stamp = Stamp(st)
            changeSeconds = st.st_ctimespec.tv_sec
            changeNanoseconds = st.st_ctimespec.tv_nsec
            flags = st.st_flags
        }

        /// The same file (volume and inode), whether or not it changed.
        func isSameItem(as other: Snapshot) -> Bool {
            stamp.device == other.stamp.device && stamp.inode == other.stamp.inode
        }
    }

    /// The item an undo of `change` acts on.
    private static func stamp(undoing change: Change) -> Stamp? {
        switch change {
        case .trashed(_, let trashed): return Stamp(trashed)
        case .moved(_, let to), .copied(_, let to): return Stamp(to)
        case .tagged: return nil
        }
    }

    /// The item a redo of `change` acts on (a redone copy copies the original as it is then).
    private static func stamp(redoing change: Change) -> Stamp? {
        switch change {
        case .trashed(let original, _): return Stamp(original)
        case .moved(let from, _): return Stamp(from)
        case .copied, .tagged: return nil
        }
    }

    /// Throws unless the item at `url` is the one `stamp` describes. Messages say `name`, never a path.
    /// The failures are permanent: that item cannot come back.
    private static func check(_ stamp: Stamp?, at url: URL, name: String? = nil, missing: String, since verb: String) throws {
        guard let stamp else { return }
        let name = name ?? url.lastPathComponent
        guard let now = Stamp(url) else { throw Failure("\(name) \(missing)", permanent: true) }
        if now != stamp {
            throw Failure("\(name) was replaced or edited since it was \(verb): left as it is", permanent: true)
        }
    }

    /// Throws (permanently) when nothing has the name `url` any more, e.g. before tagging it.
    private static func requireItem(_ url: URL) throws {
        guard itemExists(url) else { throw Failure("\(url.lastPathComponent) is no longer there", permanent: true) }
    }

    // MARK: Destinations

    /// Whether moving `url` into `folder` crosses volumes (a copy plus delete rather than a rename).
    /// A folder that does not exist yet is judged by its nearest existing parent.
    public static func crossesVolumes(_ url: URL, _ folder: URL) -> Bool {
        func volume(_ start: URL) -> NSObject? {
            var probe = start.standardizedFileURL
            while true {
                if let id = (try? probe.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject { return id }
                let parent = probe.deletingLastPathComponent()
                if parent.path == probe.path { return nil }
                probe = parent
            }
        }
        guard let a = volume(url), let b = volume(folder) else { return false }
        return !a.isEqual(b)
    }

    /// A target is a path (rather than a slot name) when it contains "/" or starts with "~" or ".".
    public static func isPathLike(_ target: String) -> Bool {
        target.contains("/") || target.hasPrefix("~") || target.hasPrefix(".")
    }

    /// The folder for a `file.move:` / `file.copy:` target: a slot name (looked up in `slots`) or a path.
    /// `~` expands; relative paths resolve against the image's folder. The result is absolute with every
    /// `.` and `..` resolved. Nil for an unknown slot or an empty target.
    public static func destination(for target: String, slots: [String: String], imageURL: URL) -> URL? {
        let raw: String
        if let slot = slots[target] { raw = slot } else if isPathLike(target) { raw = target } else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL }
        return URL(fileURLWithPath: expanded, isDirectory: true,
                   relativeTo: imageURL.deletingLastPathComponent()).absoluteURL.standardizedFileURL
    }

    /// `folder/name`, or the first free "stem 2.ext", "stem 3.ext", … (Finder's "Keep Both"). A dangling
    /// symbolic link counts as taken. Moves and copies re-check atomically, so this is only a forecast.
    public static func availableURL(for name: String, in folder: URL) -> URL {
        var n = 1
        while true {
            let candidate = numberedURL(name, n, in: folder)
            if !itemExists(candidate) { return candidate }
            n += 1
        }
    }

    /// Stat a file into an `ImageFile` (for files that come back through undo).
    public static func imageFile(at url: URL) -> ImageFile {
        var st = stat()
        let ok = stat(url.path, &st) == 0
        return ImageFile(url: url, name: url.lastPathComponent, byteSize: ok ? Int64(st.st_size) : 0,
                         modified: ok ? Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9 : 0,
                         fileID: ok ? UInt64(st.st_ino) : 0)
    }

    // MARK: Finder tags

    /// English Finder label names by label number; the app passes the localized ones.
    public static let englishLabelNames = ["None", "Gray", "Green", "Purple", "Blue", "Yellow", "Red", "Orange"]
    /// `meta.label` colour → Finder label number.
    public static let labelNumbers = ["none": 0, "gray": 1, "green": 2, "purple": 3, "blue": 4, "yellow": 5,
                                      "red": 6, "orange": 7]
    public static let pickTag = "Pick"
    public static let rejectTag = "Reject"

    /// Finder keeps tags in this extended attribute: a binary plist of `"name\n<colour>"` strings.
    static let tagAttribute = "com.apple.metadata:_kMDItemUserTags"

    /// Tags with their colours (read from the attribute: `URLResourceValues.tagNames` drops colours)
    /// plus the legacy Finder label number.
    public static func tags(of url: URL) -> Tags {
        var tags = Tags()
        let path = url.path
        let size = getxattr(path, tagAttribute, nil, 0, 0, 0)
        if size > 0 {
            var buffer = [UInt8](repeating: 0, count: size)
            if getxattr(path, tagAttribute, &buffer, size, 0, 0) == size,
               let entries = try? PropertyListSerialization.propertyList(from: Data(buffer), format: nil) as? [String] {
                for entry in entries {
                    let parts = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                    let name = String(parts[0])
                    guard !name.isEmpty, !tags.names.contains(name) else { continue }
                    tags.names.append(name)
                    if parts.count > 1, let color = Int(parts[1]), color > 0 { tags.colors[name] = color }
                }
            }
        }
        var fresh = url
        fresh.removeAllCachedResourceValues() // URLs cache resource values within a run-loop pass
        tags.label = (try? fresh.resourceValues(forKeys: [.labelNumberKey]))?.labelNumber ?? 0
        return tags
    }

    /// Write the tag attribute the way Finder does (so colour tags show their colour), then the label number.
    static func write(_ tags: Tags, to url: URL) throws {
        let path = url.path
        if tags.names.isEmpty {
            if removexattr(path, tagAttribute, 0) != 0, errno != ENOATTR {
                throw Failure("Cannot tag \(url.lastPathComponent): \(String(cString: strerror(errno)))")
            }
        } else {
            let entries = tags.names.map { "\($0)\n\(tags.colors[$0] ?? 0)" }
            let data: Data
            do {
                data = try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
            } catch {
                throw Failure("Cannot tag \(url.lastPathComponent): \(reason(error))")
            }
            let result = data.withUnsafeBytes { setxattr(path, tagAttribute, $0.baseAddress, data.count, 0, 0) }
            if result != 0 { throw Failure("Cannot tag \(url.lastPathComponent): \(String(cString: strerror(errno)))") }
        }
        do {
            try (url as NSURL).setResourceValue(tags.label, forKey: .labelNumberKey)
        } catch {
            throw Failure("Cannot label \(url.lastPathComponent): \(reason(error))")
        }
    }

    /// Rating `stars` (0 clears) as one tag of that many `star` characters, replacing any previous rating tag.
    public static func rating(_ stars: Int, star: String, in tags: Tags) -> Tags {
        var out = tags
        out.names.removeAll { isRatingTag($0, star: star) }
        if stars > 0 { out.names.append(String(repeating: star, count: stars)) }
        return out
    }

    /// The rating stored in `tags` (0 when none).
    public static func rating(of tags: Tags, star: String) -> Int {
        tags.names.first { isRatingTag($0, star: star) }?.count ?? 0
    }

    static func isRatingTag(_ name: String, star: String) -> Bool {
        !name.isEmpty && (name.allSatisfy { String($0) == star } || name.allSatisfy { $0 == "★" })
    }

    /// Colour label (`none` clears), as the label number plus the (localized) colour tag name.
    public static func label(_ color: String, in tags: Tags, labelNames: [String] = englishLabelNames) -> Tags {
        var out = tags
        let colorNames = Set((labelNames.dropFirst() + englishLabelNames.dropFirst()).map { $0.lowercased() })
        out.names.removeAll { colorNames.contains($0.lowercased()) }
        out.colors = out.colors.filter { out.names.contains($0.key) }
        let number = labelNumbers[color] ?? 0
        if number > 0 {
            let name = number < labelNames.count ? labelNames[number] : englishLabelNames[number]
            out.names.append(name)
            out.colors[name] = number
        }
        out.label = number
        return out
    }

    /// `pick` / `reject` as the tags "Pick" / "Reject" (mutually exclusive); `none` clears both.
    public static func flag(_ flag: String, in tags: Tags) -> Tags {
        var out = tags
        out.names.removeAll { $0 == pickTag || $0 == rejectTag }
        if flag == "pick" { out.names.append(pickTag) }
        if flag == "reject" { out.names.append(rejectTag) }
        return out
    }

    // MARK: exec templates

    /// `exec:` placeholders and the environment variables that carry their values.
    public static let execVariables: [String: String] = [
        "path": "PEEKABOO_PATH", "dir": "PEEKABOO_DIR", "name": "PEEKABOO_NAME", "stem": "PEEKABOO_STEM",
        "ext": "PEEKABOO_EXT", "index": "PEEKABOO_INDEX", "count": "PEEKABOO_COUNT",
    ]

    /// POSIX shell single-quoting: `it's` → `'it'\''s'`.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// The values of the placeholders for the image `file` (the `index`-th, 0-based, of `count`), keyed by
    /// environment variable: `PEEKABOO_PATH`, `_DIR`, `_NAME`, `_STEM`, `_EXT`, `_INDEX` (1-based), `_COUNT`.
    public static func execEnvironment(file: URL, index: Int, count: Int) -> [String: String] {
        let name = file.lastPathComponent
        return [
            "PEEKABOO_PATH": file.path, "PEEKABOO_DIR": file.deletingLastPathComponent().path, "PEEKABOO_NAME": name,
            "PEEKABOO_STEM": (name as NSString).deletingPathExtension, "PEEKABOO_EXT": file.pathExtension,
            "PEEKABOO_INDEX": String(index + 1), "PEEKABOO_COUNT": String(count),
        ]
    }

    /// The placeholders whose values are digits only, so they may stand bare in `$((…))`.
    private static let numericExecVariables: Set<String> = ["PEEKABOO_INDEX", "PEEKABOO_COUNT"]

    /// The shell command for an `exec:` template: each placeholder becomes a reference to its environment
    /// variable, quoted for where it stands — `"${PEEKABOO_PATH}"` in plain text, `${PEEKABOO_PATH}` inside
    /// `"…"`, `'"${PEEKABOO_PATH}"'` inside `'…'`, `'"${PEEKABOO_PATH}"$'` inside bash's `$'…'` — so a value is
    /// always exactly one word and is never parsed as shell code. In `$((…))`, where quotes are a syntax error,
    /// `{index}` and `{count}` (digits only) stand bare and the others stay quoted, so the shell refuses them
    /// rather than evaluate file names as arithmetic. No file-derived text goes into the command: run it with
    /// `execEnvironment(…)`. `\{path}` and `${path}` are left alone.
    public static func execCommand(_ template: String) -> String {
        enum Context: Equatable {
            case plain, single, double, backtick, command(depth: Int)
            /// bash's `$'…'`: `\` escapes the next character, `'` ends it.
            case ansi
            /// `$((…))`; `depth` counts the parentheses open inside it.
            case arithmetic(depth: Int)
        }
        let chars = Array(template)
        var stack: [Context] = [.plain]
        var out = ""
        var i = 0
        /// At the "(" after a "$": `$((` opens an arithmetic expansion, `$(` a command substitution.
        func openSubstitution() {
            if i + 1 < chars.count, chars[i + 1] == "(" {
                out += "(("
                i += 2
                stack.append(.arithmetic(depth: 0))
            } else {
                out.append("(")
                i += 1
                stack.append(.command(depth: 0))
            }
        }
        while i < chars.count {
            let c = chars[i]
            let context = stack[stack.count - 1]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if c == "{", i == 0 || chars[i - 1] != "$", let close = chars[i...].firstIndex(of: "}"),
               let variable = execVariables[String(chars[(i + 1)..<close])] {
                switch context {
                case .single: out += "'\"${\(variable)}\"'"
                case .ansi: out += "'\"${\(variable)}\"$'"
                case .double: out += "${\(variable)}"
                case .arithmetic where numericExecVariables.contains(variable): out += "${\(variable)}"
                default: out += "\"${\(variable)}\""
                }
                i = close + 1
                continue
            }
            out.append(c)
            i += 1
            switch context {
            case .single:
                if c == "'" { stack.removeLast() }
            case .ansi:
                if c == "\\", let next {
                    out.append(next)
                    i += 1
                } else if c == "'" {
                    stack.removeLast()
                }
            case .double:
                if c == "\\", let next {
                    out.append(next)
                    i += 1
                } else if c == "\"" {
                    stack.removeLast()
                } else if c == "$", next == "(" {
                    openSubstitution()
                } else if c == "`" {
                    stack.append(.backtick)
                }
            case .plain, .backtick, .command, .arithmetic:
                if c == "\\", let next {
                    out.append(next)
                    i += 1
                } else if c == "'" {
                    stack.append(.single)
                } else if c == "\"" {
                    stack.append(.double)
                } else if c == "$", next == "'" {
                    out.append("'")
                    i += 1
                    stack.append(.ansi)
                } else if c == "$", next == "(" {
                    openSubstitution()
                } else if c == "`" {
                    if context == .backtick { stack.removeLast() } else { stack.append(.backtick) }
                } else if case .command(let depth) = context, c == "(" || c == ")" {
                    stack.removeLast()
                    if c == "(" { stack.append(.command(depth: depth + 1)) }
                    else if depth > 0 { stack.append(.command(depth: depth - 1)) }
                } else if case .arithmetic(let depth) = context {
                    if c == "(" || c == ")" { stack.removeLast() }
                    if c == "(" {
                        stack.append(.arithmetic(depth: depth + 1))
                    } else if c == ")", depth > 0 {
                        stack.append(.arithmetic(depth: depth - 1))
                    } else if c == ")", next == ")" {
                        out.append(")")
                        i += 1
                    }
                    // Here `#` separates a base from its digits (16#ff); it never starts a comment.
                } else if c == "#", i == 1 || " \t\n;&|(".contains(chars[i - 2]) {
                    // A comment runs to the end of the line.
                    while i < chars.count, chars[i] != "\n" {
                        out.append(chars[i])
                        i += 1
                    }
                }
            }
        }
        return out
    }

    /// Run `command` with `/bin/sh -c` on a background queue; stdout is discarded. `environment` is added
    /// to the app's environment. `completion` gets the exit status and the tail of stderr, on an arbitrary queue.
    public static func run(_ command: String, environment: [String: String] = [:],
                           completion: (@Sendable (Int32, String) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            let errors = Pipe()
            process.standardError = errors
            do {
                try process.run()
            } catch {
                completion?(-1, "\(error)")
                return
            }
            let stderr = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let tail = String(decoding: stderr.suffix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            completion?(process.terminationStatus, tail)
        }
    }

    /// Run an `exec:` template for the image `file` (the `index`-th, 0-based, of `count`): the command
    /// from `execCommand`, the values in the environment. Returns the command (for logs: it holds no file names).
    @discardableResult
    public static func runExec(_ template: String, file: URL, index: Int, count: Int,
                               completion: (@Sendable (Int32, String) -> Void)? = nil) -> String {
        let command = execCommand(template)
        run(command, environment: execEnvironment(file: file, index: index, count: count), completion: completion)
        return command
    }
}
