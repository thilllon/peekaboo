import Foundation

/// Precomputed sort keys that reproduce Finder order (`localizedStandardCompare`: case-insensitive, numeric runs
/// compared by value, punctuation before digits before letters) as plain byte comparisons.
///
/// The weights of the printable ASCII characters (and the position of Hangul syllables) are measured once from
/// `localizedStandardCompare` itself, so the keys follow the current locale. Keys tie when names differ only in
/// case, diacritics or leading zeros; ties are broken with `localizedStandardCompare`. Names with characters the
/// key cannot order return `nil`, and `sort` then falls back to `localizedStandardCompare` for the whole set.
public enum NaturalSort {
    private struct Table {
        /// Primary weight per ASCII byte (0 = not an orderable printable character; digits use `digit`).
        var ascii = [UInt8](repeating: 0, count: 128)
        var digit: UInt8 = 0
        /// Weight class of Hangul syllables (U+AC00…U+D7A3), nil when they cannot be placed.
        var hangul: UInt8?
    }

    private static let table: Table = {
        var table = Table()
        var probes: [String] = []
        for value in 0x20...0x7E {
            let scalar = UnicodeScalar(UInt8(value))
            if CharacterSet.uppercaseLetters.contains(scalar) { continue }  // same primary weight as lowercase
            if value > 0x30 && value <= 0x39 { continue }                    // digits: one class ('0')
            probes.append(String(Character(scalar)))
        }
        func ordered(_ a: String, _ b: String) -> ComparisonResult { ("a" + a + "b").localizedStandardCompare("a" + b + "b") }
        probes.sort { ordered($0, $1) == .orderedAscending }
        // Group equal primaries; weights are even so an extra class (Hangul) can slot in between.
        var groups: [[String]] = []
        for probe in probes {
            if let last = groups.last?.last, ordered(last, probe) == .orderedSame {
                groups[groups.count - 1].append(probe)
            } else {
                groups.append([probe])
            }
        }
        for (rank, group) in groups.enumerated() {
            let weight = UInt8(min(2 * (rank + 1), 250))
            for probe in group {
                let byte = probe.utf8.first!
                if byte == 0x30 {
                    table.digit = weight
                } else {
                    table.ascii[Int(byte)] = weight
                    if byte >= 0x61 && byte <= 0x7A { table.ascii[Int(byte) - 0x20] = weight }  // A–Z
                }
            }
        }
        // Hangul: one class placed among the ASCII groups, ordered by code point within (as in the UCA).
        let hangulProbe = "가"
        if ordered(hangulProbe, "힣") == .orderedAscending {
            var slot = groups.count
            for (rank, group) in groups.enumerated() where ordered(hangulProbe, group[0]) == .orderedAscending {
                slot = rank
                break
            }
            table.hangul = UInt8(min(2 * (slot + 1) - 1, 251))
        }
        return table
    }()

    private static let asciiWeights = table.ascii
    private static let digitWeight = table.digit

    /// Sort key of `name`, or nil when it contains characters the key cannot order.
    public static func key(_ name: String) -> [UInt8]? {
        let fast: [UInt8]?? = name.utf8.withContiguousStorageIfAvailable { asciiKey($0) }
        if let fast, let key = fast { return key }
        return unicodeKey(name)
    }

    /// Fast path for ASCII names (nil on the first non-ASCII byte or unorderable character).
    private static func asciiKey(_ bytes: UnsafeBufferPointer<UInt8>) -> [UInt8]? {
        asciiWeights.withUnsafeBufferPointer { weights -> [UInt8]? in
            var out: [UInt8] = []
            out.reserveCapacity(bytes.count + 8)
            let n = bytes.count
            var i = 0
            while i < n {
                let b = bytes[i]
                if b >= 0x80 { return nil }
                if b >= 0x30 && b <= 0x39 {
                    var end = i + 1
                    while end < n && bytes[end] >= 0x30 && bytes[end] <= 0x39 { end += 1 }
                    var start = i
                    while start < end - 1 && bytes[start] == 0x30 { start += 1 }
                    out.append(digitWeight)
                    out.append(UInt8(min(end - start, 255)))
                    out.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[start..<end]))
                    i = end
                    continue
                }
                let weight = weights[Int(b)]
                if weight == 0 { return nil }
                out.append(weight)
                i += 1
            }
            return out
        }
    }

    private static func unicodeKey(_ raw: String) -> [UInt8]? {
        // Names read back from the file system are often decomposed (NFD: Hangul as conjoining jamo).
        let name = raw.precomposedStringWithCanonicalMapping
        let t = table
        var out: [UInt8] = []
        out.reserveCapacity(name.utf8.count + 8)
        var digits: [UInt8] = []
        func flushDigits() {
            guard !digits.isEmpty else { return }
            var start = 0
            while start < digits.count - 1 && digits[start] == 0x30 { start += 1 }
            let significant = digits.count - start
            out.append(t.digit)
            out.append(UInt8(min(significant, 255)))
            out.append(contentsOf: digits[start...])
            digits.removeAll(keepingCapacity: true)
        }
        for scalar in name.unicodeScalars {
            let v = scalar.value
            if v >= 0x30 && v <= 0x39 {
                digits.append(UInt8(v))
                continue
            }
            flushDigits()
            if v < 0x80 {
                let weight = t.ascii[Int(v)]
                guard weight != 0 else { return nil }
                out.append(weight)
            } else if v >= 0xAC00 && v <= 0xD7A3, let hangul = t.hangul {
                let offset = v - 0xAC00
                out.append(hangul)
                out.append(UInt8(offset >> 8))
                out.append(UInt8(offset & 0xFF))
            } else if v >= 0x300 && v <= 0x36F {
                continue  // combining diacritic (decomposed names): ignorable at the primary level
            } else {
                // Accented Latin letters fold to their base letter at the primary level.
                let folded = String(Character(scalar)).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                guard !folded.isEmpty else { return nil }
                for b in folded.utf8 {
                    guard b >= 0x61 && b <= 0x7A else { return nil }
                    out.append(t.ascii[Int(b)])
                }
            }
        }
        flushDigits()
        return out
    }

    /// `true` when `a` sorts before `b` in Finder order.
    public static func precedes(_ a: String, _ b: String) -> Bool {
        if let ka = key(a), let kb = key(b) {
            let order = compare(ka, kb)
            if order != 0 { return order < 0 }
        }
        return a.localizedStandardCompare(b) == .orderedAscending
    }

    /// memcmp order of two keys (−1, 0, 1).
    @inline(__always)
    static func compare(_ a: [UInt8], _ b: [UInt8]) -> Int {
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                let n = min(pa.count, pb.count)
                if n > 0 {
                    let c = memcmp(pa.baseAddress!, pb.baseAddress!, n)
                    if c != 0 { return c < 0 ? -1 : 1 }
                }
                return pa.count == pb.count ? 0 : (pa.count < pb.count ? -1 : 1)
            }
        }
    }

    /// Sort `items` by `name` in Finder order.
    public static func sort<T>(_ items: [T], by name: (T) -> String) -> [T] {
        var keys: [[UInt8]] = []
        keys.reserveCapacity(items.count)
        for item in items {
            guard let key = key(name(item)) else {
                return items.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
            }
            keys.append(key)
        }
        var order = Array(items.indices)
        order.sort { i, j in
            let c = compare(keys[i], keys[j])
            if c != 0 { return c < 0 }
            return name(items[i]).localizedStandardCompare(name(items[j])) == .orderedAscending
        }
        return order.map { items[$0] }
    }
}
