import Foundation

/// Canon CR3 embedded JPEGs. ImageIO exposes no preview for CR3 (its thumbnail call falls back to a
/// 300+ ms RAW decode), but the ISO-BMFF container carries a 1620×1080 `PRVW` JPEG and a
/// full-size JPEG in track 1 (`CRAW` sample entry with a `JPEG` child). Parsing the boxes reads
/// ~100 KB of headers.
enum CR3Preview {
    struct Candidate: Equatable {
        let offset: Int
        let length: Int
        let width: Int
        let height: Int
        /// Newer bodies (e.g. EOS R5 Mark II in HDR PQ mode) store the `PRVW` preview as HEVC:
        /// these are its property boxes (`hvcC`, `colr`, `pixi`); `bytes` wraps the bitstream in a HEIF.
        var hevcProperties: [[UInt8]]?

        var isHEVC: Bool { hevcProperties != nil }
    }

    private static let prvwUUID: [UInt8] = [0xEA, 0xF4, 0x2B, 0x5E, 0x1C, 0x98, 0x4B, 0x88,
                                            0xB9, 0xFB, 0xB7, 0xDC, 0x40, 0x6E, 0x4D, 0x16]

    /// Every embedded JPEG we can locate, smallest first.
    static func candidates(url: URL) -> [Candidate] {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return [] }
        let fileSize = Int(st.st_size)
        func read(_ offset: Int, _ count: Int) -> [UInt8]? {
            guard offset >= 0, count > 0, offset + count <= fileSize else { return nil }
            var data = [UInt8](repeating: 0, count: count)
            let n = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
            return n == count ? data : nil
        }
        guard let ftyp = read(4, 8), ftyp.starts(with: Array("ftypcrx ".utf8)) else { return [] }

        var result: [Candidate] = []
        var offset = 0
        for _ in 0..<64 {
            guard let head = read(offset, 16) else { break }
            var size = be32(head, 0)
            let type = String(decoding: head[4..<8], as: UTF8.self)
            var headerSize = 8
            if size == 1 { size = be64(head, 8); headerSize = 16 } else if size == 0 { size = fileSize - offset }
            // A 64-bit largesize can be anything up to Int.max: compare without `offset + size`, which would
            // overflow and trap (`read` above guarantees offset < fileSize).
            guard size >= headerSize, size <= fileSize - offset else { break }
            if type == "moov", size < 16 << 20, let moov = read(offset, size) {
                result += trackJPEGs(moov, from: headerSize, to: size)
            } else if type == "uuid", let uuid = read(offset + 8, 16), uuid == prvwUUID,
                      let body = read(offset + 24, min(4096, size - 24)), body.count > 32 {
                // uuid payload: 8 bytes, then the PRVW box (… u16 width @14, u16 height @16, u32 size @20),
                // then either a JPEG or HEVC property boxes followed by an `IMGD` bitstream box.
                let prvw = 8
                let width = be16(body, prvw + 14), height = be16(body, prvw + 16)
                if let soi = findSOI(Array(body.prefix(512))) {
                    let start = offset + 24 + soi
                    result.append(Candidate(offset: start, length: offset + size - start, width: width, height: height))
                } else if let hevc = hevcPreview(body, from: prvw + 24, base: offset + 24, width: width, height: height) {
                    result.append(hevc)
                }
            }
            offset += size
            if offset >= fileSize { break }
        }
        return result.sorted { $0.width * $0.height < $1.width * $1.height }
    }

    /// Read the bytes of one candidate: a JPEG, or for HEVC previews a minimal HEIF around the bitstream.
    static func bytes(url: URL, _ candidate: Candidate) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let payload: Data
        do {
            try handle.seek(toOffset: UInt64(candidate.offset))
            guard let data = try handle.read(upToCount: candidate.length), data.count == candidate.length else { return nil }
            payload = data
        } catch { return nil }
        guard let properties = candidate.hevcProperties else { return payload }
        return heif(hevc: payload, properties: properties, width: candidate.width, height: candidate.height)
    }

    /// PRVW HEVC layout: `CISZ`, `hvcC`, `colr`, `pixi`, then `IMGD` holding length-prefixed NAL units.
    private static func hevcPreview(_ body: [UInt8], from start: Int, base: Int, width: Int, height: Int) -> Candidate? {
        var properties: [[UInt8]] = []
        var offset = start
        while offset + 8 <= body.count {
            let size = be32(body, offset)
            let type = String(decoding: body[offset + 4..<offset + 8], as: UTF8.self)
            guard size >= 8 else { return nil }
            if type == "IMGD" {
                guard properties.first.map({ String(decoding: $0[4..<8], as: UTF8.self) == "hvcC" }) ?? false,
                      width > 0, height > 0, offset + 12 <= body.count else { return nil }
                // The payload starts with a u32 byte count of the NAL units that follow (4-byte length prefixed).
                let skip = be32(body, offset + 8) == size - 12 ? 12 : 8
                return Candidate(offset: base + offset + skip, length: size - skip, width: width, height: height,
                                 hevcProperties: properties)
            }
            guard offset + size <= body.count else { return nil }
            if ["hvcC", "colr", "pixi"].contains(type) { properties.append(Array(body[offset..<offset + size])) }
            offset += size
        }
        return nil
    }

    /// A single-item HEIF (`hvc1` item with the given property boxes plus `ispe`) for ImageIO's
    /// hardware HEVC decoder.
    static func heif(hevc: Data, properties: [[UInt8]], width: Int, height: Int) -> Data {
        func u16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        func u32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        func box(_ type: String, _ payload: [UInt8]) -> [UInt8] { u32(8 + payload.count) + Array(type.utf8) + payload }
        func full(_ type: String, _ version: UInt8, _ payload: [UInt8]) -> [UInt8] { box(type, [version, 0, 0, 0] + payload) }

        let ftyp = box("ftyp", Array("heic".utf8) + u32(0) + Array("mif1heic".utf8))
        let hdlr = full("hdlr", 0, u32(0) + Array("pict".utf8) + u32(0) + u32(0) + u32(0) + [0])
        let pitm = full("pitm", 0, u16(1))
        let iinf = full("iinf", 0, u16(1) + full("infe", 2, u16(1) + u16(0) + Array("hvc1".utf8) + [0]))
        let ispe = full("ispe", 0, u32(width) + u32(height))
        let props = properties + [ispe]
        let ipco = box("ipco", props.flatMap { $0 })
        let associations = (1...props.count).map { UInt8($0) | ($0 == 1 ? 0x80 : 0) }  // hvcC is essential
        let ipma = full("ipma", 0, u32(1) + u16(1) + [UInt8(props.count)] + associations)
        let iprp = box("iprp", ipco + ipma)
        func meta(dataOffset: Int) -> [UInt8] {
            let iloc = full("iloc", 0, [0x44, 0x00] + u16(1) + u16(1) + u16(0) + u16(1) + u32(dataOffset) + u32(hevc.count))
            return full("meta", 0, hdlr + pitm + iloc + iinf + iprp)
        }
        let metaSize = meta(dataOffset: 0).count
        var out = Data(ftyp + meta(dataOffset: ftyp.count + metaSize + 8))
        out.append(contentsOf: u32(8 + hevc.count) + Array("mdat".utf8))
        out.append(hevc)
        return out
    }

    // MARK: - moov / trak walking

    private static func trackJPEGs(_ moov: [UInt8], from start: Int, to end: Int) -> [Candidate] {
        var result: [Candidate] = []
        for trak in children(moov, start, end, type: "trak") {
            guard let mdia = children(moov, trak.0, trak.1, type: "mdia").first,
                  let minf = children(moov, mdia.0, mdia.1, type: "minf").first,
                  let stbl = children(moov, minf.0, minf.1, type: "stbl").first,
                  let stsd = children(moov, stbl.0, stbl.1, type: "stsd").first else { continue }
            // stsd: version/flags(4) count(4) then the first sample entry box.
            let entry = stsd.0 + 8
            guard entry + 36 <= stsd.1, String(decoding: moov[entry + 4..<entry + 8], as: UTF8.self) == "CRAW" else { continue }
            let entrySize = be32(moov, entry)
            let entryEnd = min(stsd.1, entry + entrySize)
            // A JPEG track has a `JPEG` child box inside the CRAW entry.
            guard contains(moov, entry + 8, entryEnd, fourCC: "JPEG") else { continue }
            let width = be16(moov, entry + 32), height = be16(moov, entry + 34)
            var length = 0, chunk = 0
            if let stsz = children(moov, stbl.0, stbl.1, type: "stsz").first, stsz.0 + 12 <= stsz.1 {
                length = be32(moov, stsz.0 + 4)
                if length == 0, stsz.0 + 16 <= stsz.1 { length = be32(moov, stsz.0 + 12) }
            }
            if let co64 = children(moov, stbl.0, stbl.1, type: "co64").first, co64.0 + 16 <= co64.1 {
                chunk = be64(moov, co64.0 + 8)
            } else if let stco = children(moov, stbl.0, stbl.1, type: "stco").first, stco.0 + 12 <= stco.1 {
                chunk = be32(moov, stco.0 + 8)
            }
            if length > 0, chunk > 0, width > 0, height > 0 {
                result.append(Candidate(offset: chunk, length: length, width: width, height: height))
            }
        }
        return result
    }

    /// Payload ranges (start, end) of the child boxes of `type` within [start, end).
    private static func children(_ d: [UInt8], _ start: Int, _ end: Int, type: String) -> [(Int, Int)] {
        var result: [(Int, Int)] = []
        var offset = start
        while offset + 8 <= end {
            var size = be32(d, offset)
            var header = 8
            if size == 1, offset + 16 <= end { size = be64(d, offset + 8); header = 16 } else if size == 0 { size = end - offset }
            guard size >= header, size <= end - offset else { break }  // overflow-free, as in `candidates`
            if String(decoding: d[offset + 4..<offset + 8], as: UTF8.self) == type {
                result.append((offset + header, offset + size))
            }
            offset += size
        }
        return result
    }

    private static func contains(_ d: [UInt8], _ start: Int, _ end: Int, fourCC: String) -> Bool {
        let needle = Array(fourCC.utf8)
        var i = start
        while i + 4 <= end {
            if d[i] == needle[0], d[i + 1] == needle[1], d[i + 2] == needle[2], d[i + 3] == needle[3] { return true }
            i += 1
        }
        return false
    }

    private static func findSOI(_ d: [UInt8]) -> Int? {
        var i = 0
        while i + 3 <= d.count {
            if d[i] == 0xFF, d[i + 1] == 0xD8, d[i + 2] == 0xFF { return i }
            i += 1
        }
        return nil
    }

    @inline(__always) private static func be16(_ d: [UInt8], _ o: Int) -> Int { Int(d[o]) << 8 | Int(d[o + 1]) }
    @inline(__always) private static func be32(_ d: [UInt8], _ o: Int) -> Int {
        Int(d[o]) << 24 | Int(d[o + 1]) << 16 | Int(d[o + 2]) << 8 | Int(d[o + 3])
    }
    @inline(__always) private static func be64(_ d: [UInt8], _ o: Int) -> Int { be32(d, o) << 32 | be32(d, o + 4) }
}
