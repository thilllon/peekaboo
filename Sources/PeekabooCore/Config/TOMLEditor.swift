import Foundation

/// Minimal, formatting-preserving edits of a TOML text: how the Settings window writes `config.toml`.
///
/// Only the edited entry's bytes change. An existing `key = value` keeps its key spelling, indentation and trailing
/// comment (which keeps its column when the new value fits); every other line stays byte-identical. A key the file
/// lacks goes below the last entry of its table. A table that exists only as a commented-out header (`# [view]`, as
/// in the starter file) is uncommented, and — where `reuseCommentedLine` allows it — a commented-out line of the
/// key (`# background = "black"   # black | gray | checker`) is replaced in place, keeping its comment. A table the
/// file lacks is appended.
///
/// Every candidate edit is parsed back: it must give the new value and leave every other entry and table as it was,
/// otherwise the next candidate is tried (appending a table, or inserting below its last entry, always qualifies).
/// So an edit never changes another setting, whatever the file's layout.
struct TOMLEditor {
    private(set) var text: String

    init(_ text: String) { self.text = text }

    /// The value at `path` (nil when absent); throws when the text is not valid TOML.
    func value(at path: [String]) throws -> TOMLValue? {
        try TOMLDocument(parsing: text).value(path)
    }

    /// Set `key` of `table` to `value`. `quoteKey` always quotes a new key (chords: `"k" = …`); otherwise it is bare
    /// when it can be. `reuseCommentedLine`: a commented-out line of the key may become the entry (tables of fixed
    /// settings, whose commented lines document the key; not example entries of `[slots]` or `[keys]`). `comment` goes
    /// after a new line (at the column of the file Peekaboo writes).
    mutating func set(_ value: TOMLValue, key: String, in table: [String], quoteKey: Bool = false,
                      reuseCommentedLine: Bool = true, comment: String? = nil) throws {
        let bytes = Array(text.utf8)
        let document = try TOMLDocument(parsing: text)
        let path = table + [key]
        var candidates: [[UInt8]] = []
        if let entry = document.entries.first(where: { $0.path == path }) {
            guard !Self.same(entry.value, value) else { return }
            candidates.append(Self.replacingValue(in: bytes, entry.valueStart..<entry.valueEnd, with: value.tomlText))
        } else {
            let scan = Scan(bytes, document)
            let line = Array(ConfigFile.commented(Self.spelling(key: key, quoted: quoteKey) + " = " + value.tomlText, comment).utf8)
            if let header = document.tables.first(where: { $0.path == table }) {
                let headerLine = scan.lineIndex(at: header.start)
                if reuseCommentedLine, let ghost = scan.commentedEntry([key], inSectionBelow: headerLine) {
                    candidates.append(scan.apply([scan.uncommenting(ghost, value: value.tomlText)]))
                }
                let below = document.entries.filter { Array($0.path.dropLast()) == table }
                    .map { scan.lineIndex(at: max($0.valueEnd - 1, $0.keyStart)) }.max() ?? headerLine
                candidates.append(scan.apply([scan.inserting(line, below: below)]))
            } else if let ghostHeader = scan.commentedHeader(table) {
                var edits = [scan.uncommentingHeader(ghostHeader)]
                if reuseCommentedLine, let ghost = scan.commentedEntry([key], inSectionBelow: ghostHeader) {
                    edits.append(scan.uncommenting(ghost, value: value.tomlText))
                } else {
                    edits.append(scan.inserting(line, below: ghostHeader))
                }
                candidates.append(scan.apply(edits))
            }
            candidates.append(scan.appending(table: table, line: line))
        }
        for candidate in candidates where Self.verify(candidate, against: document, path: path, value: value, table: table) {
            text = String(decoding: candidate, as: UTF8.self)
            return
        }
        throw TOMLEditError("cannot set \(path.joined(separator: ".")) without changing other lines")
    }

    /// Remove the entry at `path` (every line it spans, with its trailing comment). Nothing happens when it is absent.
    mutating func remove(_ path: [String]) throws {
        let bytes = Array(text.utf8)
        let document = try TOMLDocument(parsing: text)
        guard let entry = document.entries.first(where: { $0.path == path }) else { return }
        let scan = Scan(bytes, document)
        let first = scan.lines[scan.lineIndex(at: entry.keyStart)]
        let last = scan.lines[scan.lineIndex(at: max(entry.valueEnd - 1, entry.keyStart))]
        var result = bytes
        result.removeSubrange(first.start..<last.next)
        guard Self.verify(result, against: document, path: path, value: nil, table: nil) else {
            throw TOMLEditError("cannot remove \(path.joined(separator: ".")) without changing other lines")
        }
        text = String(decoding: result, as: UTF8.self)
    }

    /// Replace the sections of `tables` with `replacement`, at the end of the text. A section is the header line and
    /// every line below it up to the next header, less the comment lines right above that header (no blank line
    /// between: they are its own). Throws, changing nothing, when that would change an entry of another table (a
    /// dotted key of these tables written under another one, say).
    mutating func replaceSections(_ tables: Set<[String]>, with replacement: String) throws {
        let bytes = Array(text.utf8)
        let document = try TOMLDocument(parsing: text)
        let scan = Scan(bytes, document)
        let headers = document.tables.map { (path: $0.path, line: scan.lineIndex(at: $0.start)) }.sorted { $0.line < $1.line }
        var keep = Array(repeating: true, count: scan.lines.count)
        for (index, header) in headers.enumerated() where tables.contains(header.path) {
            var end = scan.lines.count
            if index + 1 < headers.count {
                end = headers[index + 1].line
                while end - 1 > header.line, scan.isComment(end - 1) { end -= 1 }
            }
            for n in header.line..<end { keep[n] = false }
        }
        // The lines kept, without blank lines at the end, then one blank line and the new sections.
        let kept = scan.lines.indices.filter { keep[$0] }
        let lastContent = kept.last { !scan.isBlank($0) } ?? -1
        var result: [UInt8] = []
        for n in kept where n <= lastContent {
            let line = scan.lines[n]
            result += bytes[line.start..<line.next]
            if line.next == line.end { result += scan.newline }  // the last line, without its newline
        }
        if !result.isEmpty { result += scan.newline }
        result += Array((scan.newline == [0x0A] ? replacement : replacement.replacingOccurrences(of: "\n", with: "\r\n")).utf8)
        // Every entry of the other tables as it was, and exactly the replacement's entries in these tables.
        let added = try TOMLDocument(parsing: replacement)
        guard let edited = try? TOMLDocument(parsing: String(decoding: result, as: UTF8.self)) else {
            throw TOMLEditError("cannot reset \(tables.map { $0.joined(separator: ".") }.sorted().joined(separator: ", "))")
        }
        func entries(_ document: TOMLDocument, inside: Bool) -> [String] {
            document.entries.filter { tables.contains(Array($0.path.dropLast())) == inside }.map { "\($0.path)=\($0.value)" }
        }
        guard entries(edited, inside: false) == entries(document, inside: false),
              entries(edited, inside: true) == entries(added, inside: true) else {
            throw TOMLEditError("cannot reset \(tables.map { $0.joined(separator: ".") }.sorted().joined(separator: ", ")) without changing other lines")
        }
        text = String(decoding: result, as: UTF8.self)
    }

    // MARK: Spelling

    /// A bare key when it is made of letters, digits, `_` and `-` (and `quoted` is false), else a basic string.
    static func spelling(key: String, quoted: Bool) -> String {
        let bare = !key.isEmpty && key.utf8.allSatisfy { c in
            (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x5F || c == 0x2D
        }
        return bare && !quoted ? key : TOMLValue.string(key).tomlText
    }

    // MARK: Verification

    /// `candidate` parses, has `value` at `path` (nil: no entry there) and otherwise the same entries as `original`;
    /// its tables are the original's, plus `table` at most.
    private static func verify(_ candidate: [UInt8], against original: TOMLDocument, path: [String], value: TOMLValue?,
                               table: [String]?) -> Bool {
        guard let document = try? TOMLDocument(parsing: String(decoding: candidate, as: UTF8.self)) else { return false }
        func values(_ document: TOMLDocument) -> [[String]: String] {
            var map: [[String]: String] = [:]
            for entry in document.entries where entry.path != path { map[entry.path] = "\(entry.value)" }
            return map
        }
        let found = document.value(path)
        guard found.map({ "\($0)" }) == value.map({ "\($0)" }), values(document) == values(original) else { return false }
        let before = Set(original.tables.map(\.path)), after = Set(document.tables.map(\.path))
        return after == before || (table.map { after == before.union([$0]) } ?? false)
    }

    /// Value equality that treats NaN as equal to itself (an unchanged `nan` is not a change).
    private static func same(_ a: TOMLValue, _ b: TOMLValue) -> Bool { "\(a)" == "\(b)" }

    // MARK: Byte edits

    /// `bytes` with the value at `range` replaced. A comment after a single-line value keeps its column when the new
    /// value leaves room (at least one space stays).
    private static func replacingValue(in bytes: [UInt8], _ range: Range<Int>, with value: String) -> [UInt8] {
        var end = range.upperBound
        var result = Array(bytes[..<range.lowerBound]) + Array(value.utf8)
        let multiLine = bytes[range].contains(0x0A)
        var gapEnd = end
        while gapEnd < bytes.count, bytes[gapEnd] == 0x20 || bytes[gapEnd] == 0x09 { gapEnd += 1 }
        if !multiLine, gapEnd < bytes.count, bytes[gapEnd] == UInt8(ascii: "#"), gapEnd > end {
            var lineStart = range.lowerBound
            while lineStart > 0, bytes[lineStart - 1] != 0x0A { lineStart -= 1 }
            let column = columns(bytes[lineStart..<gapEnd])
            let used = columns(bytes[lineStart..<range.lowerBound]) + value.count
            result += Array(repeating: 0x20, count: max(1, column - used))
            end = gapEnd
        }
        return result + Array(bytes[end...])
    }

    private static func columns(_ bytes: ArraySlice<UInt8>) -> Int { String(decoding: bytes, as: UTF8.self).count }

    /// The text split into lines, which lines hold real headers and entries, and the commented-out headers and entries
    /// among the others.
    private struct Scan {
        struct Line {
            /// First byte, the byte after the content (before `\r\n` / `\n`), and the first byte of the next line.
            let start: Int, end: Int, next: Int
        }

        /// A commented-out line that parses as one table header or one entry.
        struct Commented {
            let line: Int
            /// Where its `#` is, and where the TOML text after `#` (and one space) starts.
            let hash: Int, content: Int
            /// Header path, or the entry's key path relative to its table.
            let path: [String]
            let isHeader: Bool
            /// The entry's value span, as offsets into the whole text.
            let valueRange: Range<Int>?
        }

        struct Edit {
            let range: Range<Int>
            let bytes: [UInt8]
        }

        let bytes: [UInt8]
        let lines: [Line]
        let newline: [UInt8]
        /// Per line: a real header or entry is on it (or an entry's array spans it).
        private var real: [Bool]
        /// Per line: the commented header or entry on it.
        private var commented: [Int: Commented] = [:]
        /// Per line: the line index of the header (real or commented) whose section it is in.
        private var section: [Int?]

        init(_ bytes: [UInt8], _ document: TOMLDocument) {
            self.bytes = bytes
            var lines: [Line] = []
            var start = 0
            var i = 0
            while i < bytes.count {
                if bytes[i] == 0x0A {
                    let end = i > start && bytes[i - 1] == 0x0D ? i - 1 : i
                    lines.append(Line(start: start, end: end, next: i + 1))
                    start = i + 1
                }
                i += 1
            }
            if start < bytes.count || lines.isEmpty { lines.append(Line(start: start, end: bytes.count, next: bytes.count)) }
            self.lines = lines
            newline = bytes.contains(0x0D) ? [0x0D, 0x0A] : [0x0A]
            real = Array(repeating: false, count: lines.count)
            section = Array(repeating: nil, count: lines.count)
            var headers = Set<Int>()
            for table in document.tables {
                let n = Self.index(lines, at: table.start)
                real[n] = true
                headers.insert(n)
            }
            for entry in document.entries {
                let first = Self.index(lines, at: entry.keyStart), last = Self.index(lines, at: max(entry.valueEnd - 1, entry.keyStart))
                for n in first...last { real[n] = true }
            }
            var current: Int?
            for n in lines.indices {
                if headers.contains(n) {
                    current = n
                } else if !real[n], let found = Self.commented(bytes, lines[n], line: n) {
                    commented[n] = found
                    if found.isHeader { current = n }
                }
                section[n] = current
            }
        }

        private static func index(_ lines: [Line], at offset: Int) -> Int {
            var low = 0, high = lines.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if lines[mid].start <= offset { low = mid } else { high = mid - 1 }
            }
            return low
        }

        func lineIndex(at offset: Int) -> Int { Self.index(lines, at: offset) }

        /// Line `n` holds only spaces and tabs.
        func isBlank(_ n: Int) -> Bool { bytes[lines[n].start..<lines[n].end].allSatisfy { $0 == 0x20 || $0 == 0x09 } }

        /// Line `n` is a comment (no header or entry on it, `#` after optional spaces).
        func isComment(_ n: Int) -> Bool {
            !real[n] && bytes[lines[n].start..<lines[n].end].first { $0 != 0x20 && $0 != 0x09 } == UInt8(ascii: "#")
        }

        /// `# [table]` or `# key = value` (one optional space after `#`; anything that is not exactly one header or one
        /// entry, such as prose, is not commented-out TOML).
        private static func commented(_ bytes: [UInt8], _ line: Line, line n: Int) -> Commented? {
            var hash = line.start
            while hash < line.end, bytes[hash] == 0x20 || bytes[hash] == 0x09 { hash += 1 }
            guard hash < line.end, bytes[hash] == UInt8(ascii: "#") else { return nil }
            var content = hash + 1
            if content < line.end, bytes[content] == 0x20 { content += 1 }
            guard content < line.end, bytes[content] != UInt8(ascii: "#"),
                  let document = try? TOMLDocument(parsing: String(decoding: bytes[content..<line.end], as: UTF8.self))
            else { return nil }
            if document.tables.count == 1, document.entries.isEmpty {
                return Commented(line: n, hash: hash, content: content, path: document.tables[0].path, isHeader: true,
                                 valueRange: nil)
            }
            if document.tables.isEmpty, document.entries.count == 1, let entry = document.entries.first {
                return Commented(line: n, hash: hash, content: content, path: entry.path, isHeader: false,
                                 valueRange: (content + entry.valueStart)..<(content + entry.valueEnd))
            }
            return nil
        }

        /// The first commented-out header of `table` (nil when the file has none).
        func commentedHeader(_ table: [String]) -> Int? {
            commented.values.filter { $0.isHeader && $0.path == table }.map(\.line).min()
        }

        /// A commented-out entry at `path` (relative to the table) in the section of the header on line `header`,
        /// before the next header (real or commented).
        func commentedEntry(_ path: [String], inSectionBelow header: Int) -> Int? {
            var n = header + 1
            while n < lines.count, section[n] == header {
                if let found = commented[n], !found.isHeader, found.path == path { return n }
                n += 1
            }
            return nil
        }

        /// The commented line `n` without its `#`, with `value` in place of its value.
        func uncommenting(_ n: Int, value: String) -> Edit {
            guard let found = commented[n], let valueRange = found.valueRange else { return uncommentingHeader(n) }
            let line = lines[n]
            // The line as it reads without `# `, then its value replaced (comment column kept).
            let plain = Array(bytes[line.start..<found.hash]) + Array(bytes[found.content..<line.end])
            let shift = found.content - found.hash
            let range = (valueRange.lowerBound - line.start - shift)..<(valueRange.upperBound - line.start - shift)
            return Edit(range: line.start..<line.end, bytes: TOMLEditor.replacingValue(in: plain, range, with: value))
        }

        /// The commented header on line `n` without its `#`.
        func uncommentingHeader(_ n: Int) -> Edit {
            let line = lines[n]
            guard let found = commented[n] else { return Edit(range: line.start..<line.start, bytes: []) }
            return Edit(range: line.start..<line.end, bytes: Array(bytes[line.start..<found.hash]) + Array(bytes[found.content..<line.end]))
        }

        /// `content` as a new line below line `n`.
        func inserting(_ content: [UInt8], below n: Int) -> Edit {
            let line = lines[n]
            // The last line may lack its newline: end it first.
            if line.next == line.end { return Edit(range: line.end..<line.end, bytes: newline + content + newline) }
            return Edit(range: line.next..<line.next, bytes: content + newline)
        }

        /// The text with `[table]` and `content` appended, after a blank line.
        func appending(table: [String], line content: [UInt8]) -> [UInt8] {
            var result = bytes
            if let last = lines.last, !bytes.isEmpty {
                if last.next == last.end { result += newline }  // end the last line
                if !bytes[last.start..<last.end].allSatisfy({ $0 == 0x20 || $0 == 0x09 }) { result += newline }  // blank line
            }
            let header = "[" + table.map { TOMLEditor.spelling(key: $0, quoted: false) }.joined(separator: ".") + "]"
            return result + Array(header.utf8) + newline + content + newline
        }

        /// `edits` (non-overlapping) applied, last first so earlier offsets stay valid.
        func apply(_ edits: [Edit]) -> [UInt8] {
            var result = bytes
            for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
                result.replaceSubrange(edit.range, with: edit.bytes)
            }
            return result
        }
    }
}

struct TOMLEditError: Error, Equatable, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

extension TOMLValue {
    /// The value spelled as TOML: basic strings with escapes, `1.25`, `2.0` (a float stays a float), `["a", "b"]`.
    var tomlText: String {
        switch self {
        case .string(let s):
            var out = "\""
            for scalar in s.unicodeScalars {
                switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\t": out += "\\t"
                case "\r": out += "\\r"
                default:
                    if scalar.value < 0x20 || scalar.value == 0x7F {
                        out += String(format: "\\u%04X", scalar.value)
                    } else {
                        out.unicodeScalars.append(scalar)
                    }
                }
            }
            return out + "\""
        case .integer(let n): return String(n)
        case .float(let f):
            if f.isNaN { return "nan" }
            if f.isInfinite { return f < 0 ? "-inf" : "inf" }
            let text = "\(f)"
            return text.contains(".") || text.contains("e") ? text : text + ".0"
        case .bool(let b): return b ? "true" : "false"
        case .array(let items): return "[" + items.map(\.tomlText).joined(separator: ", ") + "]"
        }
    }
}
