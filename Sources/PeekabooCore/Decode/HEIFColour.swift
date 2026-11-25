import Foundation

/// The YCbCr matrix a HEIF / AVIF file declares for its primary image: `matrix_coefficients` (ISO/IEC 23091-2) of the
/// `colr` (`nclx`) item property, or of the first tile's when the primary is a grid without one. ImageIO decodes with
/// that matrix (it overrides the codec's own colour description), and its surface SPI hands the YCbCr over in it — but
/// tags every bi-planar surface `ITU_R_601_4` whatever the file says, so `YCbCrConverter` takes the matrix from here.
/// Reads the file's first 16 KB (where `meta` follows `ftyp`), more only for a larger `meta` (bounded at 4 MB): one
/// `pread` of the page-cached header ImageIO has just parsed, 10–20 µs.
enum HEIFColour {
    private static let maxMeta = 4 << 20
    private static let headBytes = 16 << 10

    /// The primary image's `matrix_coefficients`, nil when the file declares none (or is not ISO-BMFF).
    static func matrixCoefficients(url: URL) -> Int? {
        let fd = url.withUnsafeFileSystemRepresentation { $0.map { open($0, O_RDONLY | O_CLOEXEC) } ?? -1 }
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var count = 0
        let head = [UInt8](unsafeUninitializedCapacity: headBytes) { buffer, initialized in
            count = max(pread(fd, buffer.baseAddress, buffer.count, 0), 0)
            initialized = count
        }
        guard count >= 16 else { return nil }
        return head.withUnsafeBytes { d -> Int? in
            // `meta` follows `ftyp` (sometimes after a `free` or `uuid` box): a few top-level boxes at most.
            var offset = 0
            for _ in 0..<8 where offset + 16 <= d.count {
                var size = be32(d, offset), header = 8
                if size == 1 { size = be32(d, offset + 8) << 32 | be32(d, offset + 12); header = 16 }
                guard size >= header else { return nil }   // 0 (to the end of the file) never precedes `meta`
                if be32(d, offset + 4) == fourCC("meta") {
                    guard size - header <= maxMeta else { return nil }
                    if offset + size <= d.count {
                        return matrixCoefficients(meta: UnsafeRawBufferPointer(rebasing: d[(offset + header)..<(offset + size)]))
                    }
                    let body = [UInt8](unsafeUninitializedCapacity: size - header) { buffer, initialized in
                        initialized = max(pread(fd, buffer.baseAddress, buffer.count, off_t(offset + header)), 0)
                    }
                    guard body.count == size - header else { return nil }
                    return body.withUnsafeBytes { matrixCoefficients(meta: $0) }
                }
                guard size <= d.count - offset else { return nil }
                offset += size
            }
            return nil
        }
    }

    /// The same from a whole file in memory.
    static func matrixCoefficients(file d: UnsafeRawBufferPointer) -> Int? {
        guard let meta = boxes(d, 0, d.count).first(where: { $0.type == fourCC("meta") }) else { return nil }
        return matrixCoefficients(meta: UnsafeRawBufferPointer(rebasing: d[meta.body]))
    }

    /// `d`: the payload of a `meta` box (a full box: version and flags first).
    static func matrixCoefficients(meta d: UnsafeRawBufferPointer) -> Int? {
        var primary: Int?
        var properties: [(type: UInt32, body: Range<Int>)] = []
        var associations: [Int: [Int]] = [:]
        var tiles: [Int: Int] = [:]   // grid item → its first tile (`dimg`)
        for box in boxes(d, 4, d.count) {
            let s = box.body.lowerBound, e = box.body.upperBound
            switch box.type {
            case fourCC("pitm"):
                guard e - s >= 6 else { break }
                primary = d[s] == 0 ? be16(d, s + 4) : (e - s >= 8 ? be32(d, s + 4) : nil)
            case fourCC("iref"):
                guard e - s >= 4 else { break }
                let wide = d[s] != 0
                for reference in boxes(d, s + 4, e) where reference.type == fourCC("dimg") {
                    let r = reference.body.lowerBound, n = wide ? 4 : 2
                    guard reference.body.count >= 2 * n + 2 else { continue }
                    let from = wide ? be32(d, r) : be16(d, r)
                    if be16(d, r + n) > 0, tiles[from] == nil { tiles[from] = wide ? be32(d, r + n + 2) : be16(d, r + n + 2) }
                }
            case fourCC("iprp"):
                for child in boxes(d, s, e) {
                    if child.type == fourCC("ipco") { properties = boxes(d, child.body.lowerBound, child.body.upperBound) }
                    if child.type == fourCC("ipma") { readAssociations(d, child.body, into: &associations) }
                }
            default:
                break
            }
        }
        func nclx(of item: Int) -> Int? {
            for index in associations[item] ?? [] where properties.indices.contains(index - 1) {
                let property = properties[index - 1]
                let p = property.body.lowerBound
                // colour_type 'nclx', colour_primaries, transfer_characteristics, matrix_coefficients, full_range_flag
                if property.type == fourCC("colr"), property.body.count >= 11, be32(d, p) == fourCC("nclx") {
                    return be16(d, p + 8)
                }
            }
            return nil
        }
        guard let primary else { return nil }
        return nclx(of: primary) ?? tiles[primary].flatMap(nclx(of:))
    }

    /// Item → property indices (1-based) of an `ipma` payload.
    private static func readAssociations(_ d: UnsafeRawBufferPointer, _ body: Range<Int>, into map: inout [Int: [Int]]) {
        guard body.count >= 8 else { return }
        let version = d[body.lowerBound], wideIndex = d[body.lowerBound + 3] & 1 != 0
        let count = be32(d, body.lowerBound + 4)
        var p = body.lowerBound + 8
        for _ in 0..<count {
            let idBytes = version < 1 ? 2 : 4
            guard p + idBytes + 1 <= body.upperBound else { return }
            let item = idBytes == 2 ? be16(d, p) : be32(d, p)
            let n = Int(d[p + idBytes])
            p += idBytes + 1
            let entryBytes = wideIndex ? 2 : 1
            guard p + n * entryBytes <= body.upperBound else { return }
            map[item, default: []] += (0..<n).map { k in
                wideIndex ? be16(d, p + 2 * k) & 0x7FFF : Int(d[p + k] & 0x7F)
            }
            p += n * entryBytes
        }
    }

    /// The boxes in `d[start..<end]` (stops at the first malformed one).
    private static func boxes(_ d: UnsafeRawBufferPointer, _ start: Int, _ end: Int) -> [(type: UInt32, body: Range<Int>)] {
        var result: [(type: UInt32, body: Range<Int>)] = []
        var i = start
        while i + 8 <= end {
            var size = be32(d, i), header = 8
            if size == 1 {
                guard i + 16 <= end else { break }
                size = be32(d, i + 8) << 32 | be32(d, i + 12)
                header = 16
            } else if size == 0 {
                size = end - i
            }
            guard size >= header, size <= end - i else { break }
            result.append((UInt32(truncatingIfNeeded: be32(d, i + 4)), (i + header)..<(i + size)))
            i += size
        }
        return result
    }

    private static func fourCC(_ s: StaticString) -> UInt32 {
        s.withUTF8Buffer { $0.reduce(0) { $0 << 8 | UInt32($1) } }
    }

    private static func be16(_ d: UnsafeRawBufferPointer, _ o: Int) -> Int { Int(d[o]) << 8 | Int(d[o + 1]) }
    private static func be32(_ d: UnsafeRawBufferPointer, _ o: Int) -> Int {
        Int(d[o]) << 24 | Int(d[o + 1]) << 16 | Int(d[o + 2]) << 8 | Int(d[o + 3])
    }
}
