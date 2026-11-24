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
/// rename, a copy or one `setxattr`, so it returns quickly on the same volume.
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
        public init(_ message: String) { self.message = message }
        public var description: String { message }
    }

    /// Changes that can be undone, oldest first.
    public var undoStack: [Change] { undoEntries.map(\.change) }
    /// Undone changes that can be redone, oldest first.
    public var redoStack: [Change] { redoEntries.map(\.change) }
    /// Undoing a copy moves the copy to the Trash, as Finder does; false deletes it (tests).
    public var trashesUndoneCopies = true
    private let fm = FileManager.default

    /// A change plus the identity of the item that its undo (or redo) acts on, so that neither touches a
    /// file that was replaced or edited since.
    private struct Entry {
        let change: Change
        let stamp: Stamp?
    }

    private var undoEntries: [Entry] = []
    private var redoEntries: [Entry] = []

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
    /// to undo. Throws, keeping the change, when the item is gone (e.g. the Trash was emptied) or was
    /// replaced or edited since the action.
    public func undo() throws -> Change? {
        guard let entry = undoEntries.popLast() else { return nil }
        do {
            let redo: Change
            switch entry.change {
            case .trashed(let original, let trashed):
                try Self.check(entry.stamp, at: trashed, name: original.lastPathComponent,
                               missing: "is no longer in the Trash", since: "trashed")
                let restored = try Self.restore(trashed, to: original)
                redo = .trashed(original: restored, trashed: trashed)
            case .moved(let from, let to):
                try Self.check(entry.stamp, at: to, missing: "is no longer in \(to.deletingLastPathComponent().lastPathComponent)",
                               since: "moved")
                let back = try Self.restore(to, to: from)
                redo = .moved(from: back, to: to)
            case .copied(let from, let to):
                try removeCopy(to, stamp: entry.stamp)
                redo = .copied(from: from, to: to)
            case .tagged(let url, let before, let after):
                try Self.write(before, to: url)
                redo = .tagged(url, before: before, after: after)
            }
            redoEntries.append(Entry(change: redo, stamp: Self.stamp(redoing: redo)))
            return redo
        } catch {
            undoEntries.append(entry)
            throw error
        }
    }

    /// Redo the most recently undone change; returns the change as redone. Throws, keeping the change,
    /// when the file was replaced or edited since it was put back.
    public func redo() throws -> Change? {
        guard let entry = redoEntries.popLast() else { return nil }
        do {
            let redone: Change
            switch entry.change {
            case .trashed(let original, _):
                try Self.check(entry.stamp, at: original, missing: "is no longer there", since: "put back")
                redone = try performTrash(original)
            case .moved(let from, let to):
                try Self.check(entry.stamp, at: from, missing: "is no longer there", since: "moved back")
                redone = try Self.transfer(from, toFolder: to.deletingLastPathComponent(), copy: false)
            case .copied(let from, let to):
                redone = try Self.transfer(from, toFolder: to.deletingLastPathComponent(), copy: true)
            case .tagged(let url, let before, let after):
                try Self.write(after, to: url)
                redone = .tagged(url, before: before, after: after)
            }
            undoEntries.append(Entry(change: redone, stamp: Self.stamp(undoing: redone)))
            return redone
        } catch {
            redoEntries.append(entry)
            throw error
        }
    }

    /// Push a change made elsewhere (e.g. a cross-volume move finished on a background queue) onto the
    /// undo stack. Call it right after the change: it notes the identity of the file the undo will touch.
    public func record(_ change: Change) {
        undoEntries.append(Entry(change: change, stamp: Self.stamp(undoing: change)))
        redoEntries.removeAll()
    }

    private func performTrash(_ url: URL) throws -> Change {
        guard Self.itemExists(url) else { throw Failure("\(url.lastPathComponent) is no longer there") }
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
        guard itemExists(url) else { throw Failure("\(name) is no longer there") }
        if !copy, isSameDirectory(folder, url.deletingLastPathComponent()) {
            throw Failure("\(name) is already in \(folder.lastPathComponent)")
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw Failure("Cannot \(verb) \(name): cannot create the folder \(folder.lastPathComponent) (\(reason(error)))")
        }
        do {
            let target = try place(url, as: name, in: folder, mode: mode)
            return copy ? .copied(from: url, to: target) : .moved(from: url, to: target)
        } catch let failure as PlaceFailure {
            throw Failure("Cannot \(verb) \(name): \(failure.reason)")
        }
    }

    /// Put `url` back at `original` (or "name 2.ext" next to it if that name was taken meanwhile).
    private static func restore(_ url: URL, to original: URL) throws -> URL {
        let folder = original.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return try place(url, as: original.lastPathComponent, in: folder, mode: .move)
        } catch let failure as PlaceFailure {
            throw Failure("Cannot restore \(original.lastPathComponent): \(failure.reason)")
        } catch {
            throw Failure("Cannot restore \(original.lastPathComponent): \(reason(error))")
        }
    }

    private func removeCopy(_ url: URL, stamp: Stamp?) throws {
        guard Self.itemExists(url) else { return }
        // Never trash or delete a file that replaced the copy, or the copy after it was edited.
        try Self.check(stamp, at: url, missing: "is no longer there", since: "copied")
        do {
            guard trashesUndoneCopies else { throw Failure("delete") }
            try fm.trashItem(at: url, resultingItemURL: nil)
        } catch {
            do { try fm.removeItem(at: url) } catch { throw Failure("Cannot remove the copy: \(Self.reason(error))") }
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
        init(_ code: Int32, hint: String = "") { reason = String(cString: strerror(code)) + hint }
    }

    /// Move or copy `source` to `folder/name`, or to the first free "stem N.ext". Exclusive: an existing item
    /// (a dangling symbolic link included) is never replaced, not even one that appears while this runs.
    private static func place(_ source: URL, as name: String, in folder: URL, mode: Mode) throws -> URL {
        if mode == .move {
            var n = 1
            while true {
                let target = numberedURL(name, n, in: folder)
                n += 1
                if itemExists(target) { continue }
                if renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
                let code = errno
                switch code {
                case EEXIST: continue
                case EXDEV: return try place(source, as: name, in: folder, mode: .moveByCopying)
                case ENOTSUP, EINVAL:
                    // A file system without exclusive renames (some network volumes): check, then rename.
                    if itemExists(target) { continue }
                    if rename(source.path, target.path) == 0 { return target }
                    throw PlaceFailure(errno)
                default: throw PlaceFailure(code)
                }
            }
        }
        // Copy to a private name in the destination folder, then rename that exclusively into place: a failed
        // copy leaves nothing behind, and no existing file is ever written to.
        let temporary = folder.appendingPathComponent(".peekaboo-\(UUID().uuidString).tmp")
        // COPYFILE_CLONE: an instant clone on APFS, else a full copy with metadata; a link is copied as a link.
        // (It is not exclusive by itself, hence the private name.)
        if copyfile(source.path, temporary.path, nil, copyfile_flags_t(COPYFILE_CLONE)) != 0 {
            let code = errno
            unlink(temporary.path)
            throw PlaceFailure(code)
        }
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
            unlink(temporary.path)
            throw PlaceFailure(code)
        }
        guard mode == .moveByCopying else { return target }
        // The copy is complete: remove the original (`unlink` removes a link, never its target).
        if unlink(source.path) != 0 {
            let code = errno
            unlink(target.path)
            let readOnly = code == EACCES || code == EPERM || code == EROFS
            throw PlaceFailure(code, hint: readOnly ? " (its folder is read-only: copy it instead)" : "")
        }
        return target
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
    struct Stamp: Equatable {
        let device: Int64
        let inode: UInt64
        let size: Int64
        let seconds: Int
        let nanoseconds: Int

        init?(_ url: URL) {
            var st = stat()
            guard lstat(url.path, &st) == 0 else { return nil }
            device = Int64(st.st_dev)
            inode = UInt64(st.st_ino)
            size = Int64(st.st_size)
            seconds = st.st_mtimespec.tv_sec
            nanoseconds = st.st_mtimespec.tv_nsec
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
    private static func check(_ stamp: Stamp?, at url: URL, name: String? = nil, missing: String, since verb: String) throws {
        guard let stamp else { return }
        let name = name ?? url.lastPathComponent
        guard let now = Stamp(url) else { throw Failure("\(name) \(missing)") }
        if now != stamp { throw Failure("\(name) was replaced or edited since it was \(verb): left as it is") }
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

    /// The shell command for an `exec:` template: each placeholder becomes a reference to its environment
    /// variable, quoted for where it stands — `"${PEEKABOO_PATH}"` in plain text, `${PEEKABOO_PATH}` inside
    /// `"…"`, `'"${PEEKABOO_PATH}"'` inside `'…'` — so a value is always exactly one word and is never parsed
    /// as shell code. No file-derived text goes into the command: run it with `execEnvironment(…)`.
    /// `\{path}` and `${path}` are left alone. The arguments are unused (kept for source compatibility).
    public static func expand(_ template: String, file: URL, index: Int, count: Int) -> String {
        execCommand(template)
    }

    /// See `expand(_:file:index:count:)`.
    public static func execCommand(_ template: String) -> String {
        enum Context: Equatable { case plain, single, double, backtick, command(depth: Int) }
        let chars = Array(template)
        var stack: [Context] = [.plain]
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let context = stack[stack.count - 1]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if c == "{", i == 0 || chars[i - 1] != "$", let close = chars[i...].firstIndex(of: "}"),
               let variable = execVariables[String(chars[(i + 1)..<close])] {
                switch context {
                case .single: out += "'\"${\(variable)}\"'"
                case .double: out += "${\(variable)}"
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
            case .double:
                if c == "\\", let next {
                    out.append(next)
                    i += 1
                } else if c == "\"" {
                    stack.removeLast()
                } else if c == "$", next == "(" {
                    out.append("(")
                    i += 1
                    stack.append(.command(depth: 0))
                } else if c == "`" {
                    stack.append(.backtick)
                }
            case .plain, .backtick, .command:
                if c == "\\", let next {
                    out.append(next)
                    i += 1
                } else if c == "'" {
                    stack.append(.single)
                } else if c == "\"" {
                    stack.append(.double)
                } else if c == "$", next == "(" {
                    out.append("(")
                    i += 1
                    stack.append(.command(depth: 0))
                } else if c == "`" {
                    if context == .backtick { stack.removeLast() } else { stack.append(.backtick) }
                } else if case .command(let depth) = context, c == "(" || c == ")" {
                    stack.removeLast()
                    if c == "(" { stack.append(.command(depth: depth + 1)) }
                    else if depth > 0 { stack.append(.command(depth: depth - 1)) }
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
