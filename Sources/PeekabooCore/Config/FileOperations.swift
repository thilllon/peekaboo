import Foundation

/// The file-system half of the file actions, free of AppKit so it can be tested on temp dirs:
/// trash / move / copy / Finder tags with a session-long undo stack, destination resolution
/// (slots, `~`, paths relative to the image's folder, "name 2.ext" on collisions) and `exec:`
/// templates. The app's `FileActions` adds the pasteboard, Finder and other-app parts.
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

    public private(set) var undoStack: [Change] = []
    public private(set) var redoStack: [Change] = []
    private let fm = FileManager.default

    public init() {}

    // MARK: Operations

    /// Move to the Trash (undo moves it back).
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
    /// restored location (a "name 2.ext" if the old name was taken meanwhile); nil when there is nothing to undo.
    public func undo() throws -> Change? {
        guard let change = undoStack.popLast() else { return nil }
        do {
            let redo: Change
            switch change {
            case .trashed(let original, let trashed):
                let restored = try restore(trashed, to: original)
                redo = .trashed(original: restored, trashed: trashed)
            case .moved(let from, let to):
                let back = try restore(to, to: from)
                redo = .moved(from: back, to: to)
            case .copied(let from, let to):
                try removeCopy(to)
                redo = .copied(from: from, to: to)
            case .tagged(let url, let before, let after):
                try Self.write(before, to: url)
                redo = .tagged(url, before: before, after: after)
            }
            redoStack.append(redo)
            return redo
        } catch {
            undoStack.append(change)
            throw error
        }
    }

    /// Redo the most recently undone change; returns the change as redone.
    public func redo() throws -> Change? {
        guard let change = redoStack.popLast() else { return nil }
        do {
            let redone: Change
            switch change {
            case .trashed(let original, _):
                redone = try performTrash(original)
            case .moved(let from, let to):
                redone = try Self.transfer(from, toFolder: to.deletingLastPathComponent(), copy: false)
            case .copied(let from, let to):
                redone = try Self.transfer(from, toFolder: to.deletingLastPathComponent(), copy: true)
            case .tagged(let url, let before, let after):
                try Self.write(after, to: url)
                redone = .tagged(url, before: before, after: after)
            }
            undoStack.append(redone)
            return redone
        } catch {
            redoStack.append(change)
            throw error
        }
    }

    /// Push a change made elsewhere (e.g. a cross-volume move finished on a background queue) onto the undo stack.
    public func record(_ change: Change) {
        undoStack.append(change)
        redoStack.removeAll()
    }

    private func performTrash(_ url: URL) throws -> Change {
        var resulting: NSURL?
        do {
            try fm.trashItem(at: url, resultingItemURL: &resulting)
        } catch {
            throw Failure("Cannot move \(url.lastPathComponent) to the Trash: \(Self.reason(error))")
        }
        guard let trashed = resulting as URL? else { throw Failure("The Trash did not return a location") }
        return .trashed(original: url, trashed: trashed)
    }

    /// Move or copy into `folder` without recording it (thread-safe; `record(_:)` it on the owning thread).
    public static func transfer(_ url: URL, toFolder folder: URL, copy: Bool) throws -> Change {
        let fm = FileManager.default
        let folder = folder.standardizedFileURL
        if !copy, folder.path == url.deletingLastPathComponent().standardizedFileURL.path {
            throw Failure("\(url.lastPathComponent) is already in \(folder.lastPathComponent)")
        }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = Self.availableURL(for: url.lastPathComponent, in: folder)
            if copy { try fm.copyItem(at: url, to: target) } else { try fm.moveItem(at: url, to: target) }
            return copy ? .copied(from: url, to: target) : .moved(from: url, to: target)
        } catch {
            throw Failure("Cannot \(copy ? "copy" : "move") \(url.lastPathComponent): \(reason(error))")
        }
    }

    /// Put `url` back at `original` (or "name 2.ext" next to it if that name was taken meanwhile).
    private func restore(_ url: URL, to original: URL) throws -> URL {
        guard fm.fileExists(atPath: url.path) else { throw Failure("\(url.lastPathComponent) is no longer there") }
        let folder = original.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = Self.availableURL(for: original.lastPathComponent, in: folder)
            try fm.moveItem(at: url, to: target)
            return target
        } catch {
            throw Failure("Cannot restore \(original.lastPathComponent): \(Self.reason(error))")
        }
    }

    private func removeCopy(_ url: URL) throws {
        guard fm.fileExists(atPath: url.path) else { return }
        do {
            try fm.trashItem(at: url, resultingItemURL: nil)
        } catch {
            do { try fm.removeItem(at: url) } catch { throw Failure("Cannot remove the copy: \(Self.reason(error))") }
        }
    }

    private static func reason(_ error: Error) -> String {
        let ns = error as NSError
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return String(cString: strerror(Int32(underlying.code)))
        }
        return ns.localizedFailureReason ?? ns.localizedDescription
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
    /// `~` expands; relative paths resolve against the image's folder. Nil for an unknown slot.
    public static func destination(for target: String, slots: [String: String], imageURL: URL) -> URL? {
        let raw: String
        if let slot = slots[target] { raw = slot } else if isPathLike(target) { raw = target } else { return nil }
        let expanded = (raw.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL }
        return URL(fileURLWithPath: expanded, isDirectory: true,
                   relativeTo: imageURL.deletingLastPathComponent()).absoluteURL.standardizedFileURL
    }

    /// `folder/name`, or the first free "stem 2.ext", "stem 3.ext", … (Finder's "Keep Both").
    public static func availableURL(for name: String, in folder: URL) -> URL {
        let fm = FileManager.default
        let first = folder.appendingPathComponent(name)
        guard fm.fileExists(atPath: first.path) else { return first }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
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

    /// POSIX shell single-quoting: `it's` → `'it'\''s'`.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Substitute `{path} {dir} {name} {stem} {ext} {index} {count}`, each shell-quoted. A placeholder
    /// the user already quoted (`'{path}'`, `"{path}"`) is treated as unquoted. `index` is 1-based.
    public static func expand(_ template: String, file: URL, index: Int, count: Int) -> String {
        let name = file.lastPathComponent
        let values: [String: String] = [
            "path": file.path, "dir": file.deletingLastPathComponent().path, "name": name,
            "stem": (name as NSString).deletingPathExtension, "ext": file.pathExtension,
            "index": String(index + 1), "count": String(count),
        ]
        // One pass, so text inside a substituted value is never substituted again.
        let chars = Array(template)
        var out = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "{", let close = chars[i...].firstIndex(of: "}"), let value = values[String(chars[(i + 1)..<close])] {
                var next = close + 1
                if let last = out.last, last == "'" || last == "\"", next < chars.count, chars[next] == last {
                    out.removeLast()
                    next += 1
                }
                out += shellQuote(value)
                i = next
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    /// Run `command` with `/bin/sh -c` on a background queue; stdout is discarded. `completion` gets the
    /// exit status and the tail of stderr, on an arbitrary queue.
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
}
