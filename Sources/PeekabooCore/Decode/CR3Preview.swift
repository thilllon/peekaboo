import Foundation

/// Canon CR3 embedded renditions. ImageIO exposes no preview for CR3 (its thumbnail call falls back to
/// a 300+ ms RAW decode), but the ISO-BMFF container carries a 1620×1080 `PRVW` JPEG and a full-size
/// JPEG in track 1 (`CRAW` sample entry with a `JPEG` child). Bodies shooting HDR PQ (e.g. EOS R5
/// Mark II) store both as HEVC instead, track 1 as a grid of tiles. Parsing the boxes reads ~100 KB
/// of headers.
enum CR3Preview {
    struct Candidate: Equatable {
        let offset: Int
        let length: Int
        let width: Int
        let height: Int
        /// HEVC renditions: their property boxes (`hvcC`, `colr`, `pixi`); `bytes` wraps the bitstream
        /// in a HEIF.
        var hevcProperties: [[UInt8]]?
        /// Track-1 HEVC: the tile grid of the sample.
        var grid: Grid?

        var isHEVC: Bool { hevcProperties != nil }
    }

    /// Tiles stored row-major, each as a u32 byte count and its length-prefixed NAL units.
    struct Grid: Equatable {
        let rows: Int
        let columns: Int
        let tileWidth: Int
        let tileHeight: Int

        /// As a HEIF `ImageGrid` requires: the tiles cover the output, the last row and column only partly.
        func covers(width: Int, height: Int) -> Bool {
            tileWidth > 0 && tileHeight > 0 && (columns - 1) * tileWidth < width && columns * tileWidth >= width
                && (rows - 1) * tileHeight < height && rows * tileHeight >= height
        }
    }

    private static let prvwUUID: [UInt8] = [0xEA, 0xF4, 0x2B, 0x5E, 0x1C, 0x98, 0x4B, 0x88,
                                            0xB9, 0xFB, 0xB7, 0xDC, 0x40, 0x6E, 0x4D, 0x16]

    /// Every embedded rendition we can locate, smallest first.
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
                result += trackImages(moov, from: headerSize, to: size)
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

    /// Read the bytes of one candidate: a JPEG, or for HEVC renditions a minimal HEIF around the bitstream.
    static func bytes(url: URL, _ candidate: Candidate) -> Data? {
        // Renditions are a few MB (EOS R5 Mark II full-size HEVC: 10.5 MB); sizes come from the file.
        guard candidate.length > 0, candidate.length <= 256 << 20,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let payload: Data
        do {
            try handle.seek(toOffset: UInt64(candidate.offset))
            guard let data = try handle.read(upToCount: candidate.length), data.count == candidate.length else { return nil }
            payload = data
        } catch { return nil }
        guard let properties = candidate.hevcProperties else { return payload }
        return heif(hevc: payload, properties: properties, width: candidate.width, height: candidate.height,
                    grid: candidate.grid)
    }

    /// PRVW HEVC layout: `CISZ`, `hvcC`, `colr`, `pixi`, then `IMGD` holding length-prefixed NAL units.
    /// The first box of each property type is kept: cameras write one of each, and the 4 KB window could
    /// otherwise hold ~500 empty ones, more than the HEIF's 7-bit property indices address.
    private static func hevcPreview(_ body: [UInt8], from start: Int, base: Int, width: Int, height: Int) -> Candidate? {
        var properties: [[UInt8]] = []
        var types: Set<String> = []
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
            if ["hvcC", "colr", "pixi"].contains(type), types.insert(type).inserted {
                properties.append(Array(body[offset..<offset + size]))
            }
            offset += size
        }
        return nil
    }

    /// A HEIF for ImageIO's hardware HEVC decoder: one `hvc1` item over `hevc`, or with `grid` a `grid` item
    /// (the primary) over hidden `hvc1` tiles cut from `hevc`. Image items carry `properties` (`hvcC` first,
    /// essential) and `ispe`. Nil when the tiles do not fill the grid, or `ipma` (flags 0: 7-bit indices)
    /// cannot address every property.
    static func heif(hevc: Data, properties: [[UInt8]], width: Int, height: Int, grid: Grid? = nil) -> Data? {
        guard !properties.isEmpty, hevc.count <= 1 << 30, width <= 0xFFFF, height <= 0xFFFF else { return nil }
        // Image items as (offset, length) in `hevc`.
        var extents = [(0, hevc.count)]
        var tile = (width: width, height: height)
        if let grid {
            let count = grid.rows * grid.columns
            guard (1...256).contains(grid.rows), (1...256).contains(grid.columns), count <= 4096 else { return nil }
            extents = []
            var at = 0
            while extents.count < count, hevc.count - at >= 4 {
                let size = (0..<4).reduce(0) { $0 << 8 | Int(hevc[hevc.startIndex + at + $1]) }
                guard size > 0, size <= hevc.count - at - 4 else { return nil }
                extents.append((at + 4, size))
                at += 4 + size
            }
            guard extents.count == count else { return nil }
            tile = (grid.tileWidth, grid.tileHeight)
        }
        let props = properties + [full("ispe", 0, u32(tile.width) + u32(tile.height))]
            + (grid == nil ? [] : [full("ispe", 0, u32(width) + u32(height))])
        guard props.count <= 127 else { return nil }
        let n = properties.count
        let images = Array(1...extents.count), gridID = extents.count + 1  // item IDs
        let items = images.count + (grid == nil ? 0 : 1)

        let ftyp = box("ftyp", Array("heic".utf8) + u32(0) + Array("mif1heic".utf8))
        let hdlr = full("hdlr", 0, u32(0) + Array("pict".utf8) + u32(0) + u32(0) + u32(0) + [0])
        let pitm = full("pitm", 0, u16(grid == nil ? 1 : gridID))
        var infe = images.flatMap { full("infe", 2, flags: grid == nil ? 0 : 1, u16($0) + u16(0) + Array("hvc1".utf8) + [0]) }
        if grid != nil { infe += full("infe", 2, u16(gridID) + u16(0) + Array("grid".utf8) + [0]) }
        let iinf = full("iinf", 0, u16(items) + infe)
        let iref = grid == nil ? [] : full("iref", 0, box("dimg", u16(gridID) + u16(images.count) + images.flatMap(u16)))
        let ipco = box("ipco", props.flatMap { $0 })
        let imageProperties = (1...n + 1).map { UInt8($0) | ($0 == 1 ? 0x80 : 0) }  // properties + ispe; hvcC is essential
        var entries = images.flatMap { u16($0) + [UInt8(imageProperties.count)] + imageProperties }
        if grid != nil {
            let gridProperties = [UInt8(n + 2)] + (2..<n + 1).map { UInt8($0) }  // output ispe, then colr / pixi
            entries += u16(gridID) + [UInt8(gridProperties.count)] + gridProperties
        }
        let iprp = box("iprp", ipco + full("ipma", 0, u32(items) + entries))
        // mdat: `hevc`, then for a grid its ImageGrid (version 0, flags 0: 16-bit size; rows − 1, columns − 1).
        let imageGrid = grid.map { [0, 0, UInt8($0.rows - 1), UInt8($0.columns - 1)] + u16(width) + u16(height) } ?? []
        func meta(dataOffset: Int) -> [UInt8] {
            var locations = extents.map { (dataOffset + $0.0, $0.1) }
            if grid != nil { locations.append((dataOffset + hevc.count, imageGrid.count)) }
            let iloc = locations.enumerated().flatMap { u16($0.offset + 1) + u16(0) + u16(1) + u32($0.element.0) + u32($0.element.1) }
            return full("meta", 0, hdlr + pitm + full("iloc", 0, [0x44, 0x00] + u16(locations.count) + iloc) + iinf + iref + iprp)
        }
        let metaSize = meta(dataOffset: 0).count
        var out = Data(ftyp + meta(dataOffset: ftyp.count + metaSize + 8))
        out.append(contentsOf: u32(8 + hevc.count + imageGrid.count) + Array("mdat".utf8))
        out.append(hevc)
        out.append(contentsOf: imageGrid)
        return out
    }

    private static func u16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    private static func u32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    private static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] { u32(8 + payload.count) + Array(type.utf8) + payload }
    private static func full(_ type: String, _ version: UInt8, flags: UInt8 = 0, _ payload: [UInt8]) -> [UInt8] {
        box(type, [version, 0, 0, flags] + payload)
    }

    // MARK: - moov / trak walking

    private static func trackImages(_ moov: [UInt8], from start: Int, to end: Int) -> [Candidate] {
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
            let width = be16(moov, entry + 32), height = be16(moov, entry + 34)
            // A JPEG track has a `JPEG` child box inside the CRAW entry, an HEVC one an `HEVC` child.
            var hevc: (properties: [[UInt8]], grid: Grid)?
            if !contains(moov, entry + 8, entryEnd, fourCC: "JPEG") {
                guard let tiles = hevcGrid(moov, entry, entryEnd, width: width, height: height) else { continue }
                hevc = tiles
            }
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
                result.append(Candidate(offset: chunk, length: length, width: width, height: height,
                                        hevcProperties: hevc?.properties, grid: hevc?.grid))
            }
        }
        return result
    }

    /// The `HEVC` child of the CRAW sample entry at `entry` (child boxes start 90 bytes in, after the visual
    /// sample entry fields): a u32, `GRID` (u32, u32 tile count, a HEIF `ImageGrid`), `CISZ` (u32, u32 tile
    /// width, u32 tile height), then the `hvcC`, `colr`, `pixi` property boxes.
    private static func hevcGrid(_ d: [UInt8], _ entry: Int, _ end: Int, width: Int, height: Int)
        -> (properties: [[UInt8]], grid: Grid)? {
        guard let hevc = children(d, entry + 90, end, type: "HEVC").first,
              let gridBox = children(d, hevc.0 + 4, hevc.1, type: "GRID").first, gridBox.1 - gridBox.0 >= 16,
              let cisz = children(d, hevc.0 + 4, hevc.1, type: "CISZ").first, cisz.1 - cisz.0 >= 12 else { return nil }
        let imageGrid = gridBox.0 + 8
        let grid = Grid(rows: Int(d[imageGrid + 2]) + 1, columns: Int(d[imageGrid + 3]) + 1,
                        tileWidth: be32(d, cisz.0 + 4), tileHeight: be32(d, cisz.0 + 8))
        // ImageGrid version 0 with 16-bit output sizes, the size of the sample entry, as many tiles as announced.
        guard d[imageGrid] == 0, d[imageGrid + 1] & 1 == 0, be16(d, imageGrid + 4) == width, be16(d, imageGrid + 6) == height,
              be32(d, gridBox.0 + 4) == grid.rows * grid.columns, grid.covers(width: width, height: height) else { return nil }
        let properties = ["hvcC", "colr", "pixi"].compactMap { type in
            children(d, hevc.0 + 4, hevc.1, type: type).first.map { box(type, Array(d[$0.0..<$0.1])) }
        }
        guard properties.first?[4..<8].elementsEqual("hvcC".utf8) ?? false else { return nil }
        return (properties, grid)
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
