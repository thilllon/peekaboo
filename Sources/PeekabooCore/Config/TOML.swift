import Foundation

/// A value of the TOML subset the config uses: strings, integers, floats, booleans and arrays.
public enum TOMLValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case float(Double)
    case bool(Bool)
    case array([TOMLValue])

    /// Type name for error messages ("string", "integer", …).
    var typeName: String {
        switch self {
        case .string: return "string"
        case .integer: return "integer"
        case .float: return "float"
        case .bool: return "boolean"
        case .array: return "array"
        }
    }
}

/// A parse or validation error at a 1-based line and column.
struct TOMLError: Error, Equatable, Sendable, CustomStringConvertible {
    let line: Int
    let column: Int
    let message: String

    init(line: Int, column: Int, message: String) {
        self.line = line
        self.column = column
        self.message = message
    }

    var description: String { "\(line):\(column): \(message)" }
}

/// One `key = value` pair: the full key path (table header + dotted key) and where it was written.
struct TOMLEntry: Equatable, Sendable {
    let path: [String]
    let value: TOMLValue
    let line: Int
    let column: Int
    /// UTF-8 offsets in the text: the key's first byte, the value's first byte and the byte after the value
    /// (`TOMLEditor` rewrites exactly that span).
    let keyStart: Int
    let valueStart: Int
    let valueEnd: Int
}

/// A `[table]` header and where it was written.
struct TOMLTable: Equatable, Sendable {
    let path: [String]
    let line: Int
    /// UTF-8 offset of its `[`.
    let start: Int
}

/// Parsed document: entries in file order.
///
/// Dependency-free parser for the TOML subset of `docs/CONFIG.md`: `#` comments, `[a.b]` table headers,
/// bare/quoted/dotted keys, basic strings (`\" \\ \b \t \n \f \r \e \uXXXX \UXXXXXXXX`), literal strings,
/// integers (`_` separators, `0x`/`0o`/`0b`), floats (`inf`, `nan`), booleans and arrays (may span lines,
/// trailing comma, comments inside, nested up to 32 deep). Duplicate keys and tables are errors. Not
/// supported (reported as errors): multi-line strings, inline tables, arrays of tables and dates.
struct TOMLDocument: Equatable, Sendable {
    let entries: [TOMLEntry]
    let tables: [TOMLTable]

    init(parsing text: String) throws {
        var parser = TOMLParser(Array(text.utf8))
        try parser.parseDocument()
        entries = parser.entries
        tables = parser.tables
    }

    /// The value at a dotted path, e.g. `value(["hud", "mode"])`.
    func value(_ path: [String]) -> TOMLValue? {
        entries.first { $0.path == path }?.value
    }
}

private struct TOMLParser {
    private enum Kind { case value, implicitTable, table }

    let bytes: [UInt8]
    var i = 0
    var line = 1
    var lineStart = 0
    var entries: [TOMLEntry] = []
    var tables: [TOMLTable] = []
    private var defined: [[String]: Kind] = [:]
    private var currentTable: [String] = []

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    // MARK: Scanning helpers

    private var atEnd: Bool { i >= bytes.count }
    private var peek: UInt8? { i < bytes.count ? bytes[i] : nil }

    private func error(_ message: String, at position: Int? = nil) -> TOMLError {
        let p = min(position ?? i, bytes.count)
        let column = String(decoding: bytes[lineStart..<max(lineStart, p)], as: UTF8.self).count + 1
        return TOMLError(line: line, column: column, message: message)
    }

    private mutating func skipSpaces() {
        while let c = peek, c == 0x20 || c == 0x09 { i += 1 }
    }

    private mutating func skipComment() {
        guard peek == UInt8(ascii: "#") else { return }
        while let c = peek, c != 0x0A { i += 1 }
    }

    /// Consume a newline (LF or CRLF) if present.
    @discardableResult
    private mutating func newline() -> Bool {
        if peek == 0x0D, i + 1 < bytes.count, bytes[i + 1] == 0x0A { i += 1 }
        guard peek == 0x0A else { return false }
        i += 1
        line += 1
        lineStart = i
        return true
    }

    /// Spaces, comments and newlines (inside arrays).
    private mutating func skipWhitespaceCommentsAndNewlines() {
        while true {
            skipSpaces()
            skipComment()
            if !newline() { return }
        }
    }

    private mutating func expectEndOfLine(after what: String) throws {
        skipSpaces()
        skipComment()
        if atEnd { return }
        if peek == 0x0D, i + 1 < bytes.count, bytes[i + 1] == 0x0A { newline(); return }
        guard newline() else { throw error("expected the end of the line after \(what)") }
    }

    // MARK: Document

    mutating func parseDocument() throws {
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3; lineStart = 3 }
        while true {
            skipSpaces()
            guard let c = peek else { return }
            switch c {
            case UInt8(ascii: "#"): skipComment()
            case 0x0A, 0x0D:
                guard newline() else { throw error("unexpected carriage return") }
                continue
            case UInt8(ascii: "["): try parseTableHeader()
            default: try parseKeyValue()
            }
            try expectEndOfLine(after: c == UInt8(ascii: "[") ? "the table header" : "the value")
        }
    }

    private mutating func parseTableHeader() throws {
        let headerLine = line
        let start = i
        i += 1
        if peek == UInt8(ascii: "[") { throw error("arrays of tables ([[…]]) are not supported", at: start) }
        skipSpaces()
        var path: [String] = []
        try parseKey(into: &path)
        skipSpaces()
        guard peek == UInt8(ascii: "]") else { throw error("expected ']' to close the table header") }
        i += 1
        for n in 1..<path.count {
            let prefix = Array(path.prefix(n))
            if defined[prefix] == .value { throw error("\"\(prefix.joined(separator: "."))\" is a value, not a table", at: start) }
            if defined[prefix] == nil { defined[prefix] = .implicitTable }
        }
        switch defined[path] {
        case .value?: throw error("\"\(path.joined(separator: "."))\" is already a value", at: start)
        case .table?: throw error("duplicate table [\(path.joined(separator: "."))]", at: start)
        default: break
        }
        defined[path] = .table
        currentTable = path
        tables.append(TOMLTable(path: path, line: headerLine, start: start))
    }

    private mutating func parseKeyValue() throws {
        let start = i
        let keyLine = line
        let column = start == lineStart ? 1 : error("", at: start).column
        // The table's path, then the key's parts: one array.
        var path = currentTable
        try parseKey(into: &path)
        let keyEnd = i
        skipSpaces()
        guard peek == UInt8(ascii: "=") else {
            if i == keyEnd, let c = peek, c != 0x0A, c != 0x0D {
                throw error("invalid character '\(Character(Unicode.Scalar(c)))' in key (quote keys such as \"cmd+k\" = …)")
            }
            throw error("expected '=' after the key")
        }
        i += 1
        skipSpaces()
        for n in (currentTable.count + 1)..<path.count {
            let prefix = Array(path.prefix(n))
            if defined[prefix] == .value { throw error("\"\(prefix.joined(separator: "."))\" is a value, not a table", at: start) }
            if defined[prefix] == nil { defined[prefix] = .implicitTable }
        }
        // Defined before its value is parsed: a value that fails to parse ends the whole document anyway.
        if defined.updateValue(.value, forKey: path) != nil {
            throw TOMLError(line: keyLine, column: column, message: "duplicate key \"\(path.joined(separator: "."))\"")
        }
        let valueStart = i
        let value = try parseValue()
        entries.append(TOMLEntry(path: path, value: value, line: keyLine, column: column, keyStart: start,
                                 valueStart: valueStart, valueEnd: i))
    }

    // MARK: Keys

    /// A key's parts (`a."b.c".d`), appended to `parts`.
    private mutating func parseKey(into parts: inout [String]) throws {
        parts.append(try parseSimpleKey())
        while true {
            let save = i
            skipSpaces()
            guard peek == UInt8(ascii: ".") else { i = save; return }
            i += 1
            skipSpaces()
            parts.append(try parseSimpleKey())
        }
    }

    private static func isBareKeyByte(_ c: UInt8) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x5F || c == 0x2D
    }

    private mutating func parseSimpleKey() throws -> String {
        switch peek {
        case UInt8(ascii: "\"")?: return try parseBasicString()
        case UInt8(ascii: "'")?: return try parseLiteralString()
        case let c? where Self.isBareKeyByte(c):
            let start = i
            while let c = peek, Self.isBareKeyByte(c) { i += 1 }
            return String(decoding: bytes[start..<i], as: UTF8.self)
        case nil, 0x0A?, 0x0D?: throw error("expected a key")
        default: throw error("invalid character in key (quote keys such as \"cmd+,\")")
        }
    }

    // MARK: Values

    /// Arrays nest by recursion, so the depth is capped: a pasted `[[[[…]]]]` must be an error, not a crash
    /// of the parsing thread (the config needs flat arrays of strings).
    static let maxArrayDepth = 32

    private mutating func parseValue(depth: Int = 0) throws -> TOMLValue {
        guard let c = peek else { throw error("expected a value") }
        switch c {
        case UInt8(ascii: "\""): return .string(try parseBasicString())
        case UInt8(ascii: "'"): return .string(try parseLiteralString())
        case UInt8(ascii: "["): return try parseArray(depth: depth + 1)
        case UInt8(ascii: "{"): throw error("inline tables ({…}) are not supported; use a [table]")
        case 0x0A, 0x0D, UInt8(ascii: "#"): throw error("expected a value")
        default: return try parseScalar()
        }
    }

    private mutating func parseArray(depth: Int) throws -> TOMLValue {
        guard depth <= Self.maxArrayDepth else {
            throw error("arrays nested more than \(Self.maxArrayDepth) deep are not supported")
        }
        let openLine = line
        let openColumn = error("").column
        i += 1
        var items: [TOMLValue] = []
        while true {
            skipWhitespaceCommentsAndNewlines()
            guard let c = peek else {
                throw TOMLError(line: openLine, column: openColumn, message: "unterminated array")
            }
            if c == UInt8(ascii: "]") { i += 1; return .array(items) }
            items.append(try parseValue(depth: depth))
            skipWhitespaceCommentsAndNewlines()
            if peek == UInt8(ascii: ",") { i += 1; continue }
            if peek == UInt8(ascii: "]") { i += 1; return .array(items) }
            if atEnd { throw TOMLError(line: openLine, column: openColumn, message: "unterminated array") }
            throw error("expected ',' or ']' in the array")
        }
    }

    private mutating func parseScalar() throws -> TOMLValue {
        let start = i
        while let c = peek, Self.isBareKeyByte(c) || c == UInt8(ascii: "+") || c == UInt8(ascii: ".")
                || c == UInt8(ascii: ":") { i += 1 }
        let token = String(decoding: bytes[start..<i], as: UTF8.self)
        if token == "true" { return .bool(true) }
        if token == "false" { return .bool(false) }
        if let number = Self.number(token) { return number }
        if token.isEmpty { throw error("expected a value", at: start) }
        if token.first?.isNumber == true, token.contains("-") || token.contains(":") {
            throw error("dates and times are not supported", at: start)
        }
        if token.first?.isLetter == true {
            throw error("invalid value \(token) (strings need quotes: \"\(token)\")", at: start)
        }
        throw error("invalid number \(token)", at: start)
    }

    private static func number(_ token: String) -> TOMLValue? {
        var body = Substring(token)
        var sign = ""
        if let first = body.first, first == "+" || first == "-" { sign = first == "-" ? "-" : ""; body = body.dropFirst() }
        guard !body.isEmpty else { return nil }
        switch body {
        case "inf": return .float(sign == "-" ? -.infinity : .infinity)
        case "nan": return .float(.nan)
        default: break
        }
        // Underscores only between digits.
        let chars = Array(body)
        for (n, ch) in chars.enumerated() where ch == "_" {
            guard n > 0, n < chars.count - 1, chars[n - 1].isHexDigit, chars[n + 1].isHexDigit else { return nil }
        }
        let digits = body.replacingOccurrences(of: "_", with: "")
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where digits.hasPrefix(prefix) {
            guard sign.isEmpty, let n = Int(digits.dropFirst(2), radix: radix) else { return nil }
            return .integer(n)
        }
        guard digits.first?.isNumber == true else { return nil }
        if digits.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }) {
            // TOML requires digits on both sides of the point.
            if let dot = digits.firstIndex(of: ".") {
                let after = digits.index(after: dot)
                guard after < digits.endIndex, digits[after].isNumber else { return nil }
            }
            guard digits.allSatisfy({ $0.isNumber || "eE+-.".contains($0) }), let f = Double(sign + digits) else { return nil }
            return .float(f)
        }
        guard digits.allSatisfy(\.isNumber) else { return nil }
        if digits.count > 1, digits.hasPrefix("0") { return nil }
        return Int(sign + digits).map(TOMLValue.integer)
    }

    // MARK: Strings

    private mutating func parseBasicString() throws -> String {
        let open = i
        if i + 2 < bytes.count, bytes[i + 1] == 0x22, bytes[i + 2] == 0x22 {
            throw error("multi-line strings (\"\"\"…\"\"\") are not supported", at: open)
        }
        i += 1
        // Most strings (keys, chords, action ids) have no escape: the bytes up to the closing quote are the string.
        var end = i
        while end < bytes.count {
            let c = bytes[end]
            if c == 0x22 {
                let string = String(decoding: bytes[i..<end], as: UTF8.self)
                i = end + 1
                return string
            }
            if c == 0x5C || c < 0x20 || c == 0x7F { break }  // an escape, a tab, a line end, a control character
            end += 1
        }
        var out: [UInt8] = []
        while true {
            guard let c = peek, c != 0x0A, c != 0x0D else { throw error("unterminated string", at: open) }
            i += 1
            switch c {
            case UInt8(ascii: "\""):
                return String(decoding: out, as: UTF8.self)
            case UInt8(ascii: "\\"):
                guard let e = peek else { throw error("unterminated string", at: open) }
                i += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "e"): out.append(0x1B)
                case UInt8(ascii: "u"), UInt8(ascii: "U"):
                    let count = e == UInt8(ascii: "u") ? 4 : 8
                    guard i + count <= bytes.count,
                          let code = UInt32(String(decoding: bytes[i..<(i + count)], as: UTF8.self), radix: 16),
                          let scalar = Unicode.Scalar(code) else {
                        throw error("invalid unicode escape", at: i - 2)
                    }
                    i += count
                    out.append(contentsOf: Array(String(Character(scalar)).utf8))
                default:
                    throw error("invalid escape \\\(Character(Unicode.Scalar(e)))", at: i - 2)
                }
            default:
                if c < 0x20 && c != 0x09 || c == 0x7F { throw error("control character in string", at: i - 1) }
                out.append(c)
            }
        }
    }

    private mutating func parseLiteralString() throws -> String {
        let open = i
        if i + 2 < bytes.count, bytes[i + 1] == 0x27, bytes[i + 2] == 0x27 {
            throw error("multi-line strings ('''…''') are not supported", at: open)
        }
        i += 1
        let start = i
        while true {
            guard let c = peek, c != 0x0A, c != 0x0D else { throw error("unterminated string", at: open) }
            if c == UInt8(ascii: "'") {
                let s = String(decoding: bytes[start..<i], as: UTF8.self)
                i += 1
                return s
            }
            i += 1
        }
    }
}
