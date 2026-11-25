import CoreGraphics
import Foundation
import ImageIO
import IOSurface
import Metal
import UniformTypeIdentifiers
import XCTest
@testable import PeekabooCore

/// `CR3Preview` on ISO-BMFF containers built in the test: hostile box sizes and PRVW property lists are
/// rejected without trapping (overflow and narrowing traps stay on in release builds, and the parser runs
/// for every CR3 that enters a prefetch window), while well-formed previews still come out. With
/// `$PEEKABOO_CORPUS`, the same damage applied to a real CR3.
final class DecodeCR3Tests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("peekaboo-cr3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: Fixtures

    private func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    private func be32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(v >> (24 - 8 * $0) & 0xFF) } }
    private func be64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(v >> (56 - 8 * UInt64($0)) & 0xFF) } }
    private func box(_ type: String, _ payload: [UInt8]) -> [UInt8] { be32(8 + payload.count) + Array(type.utf8) + payload }

    /// A box header with size field 1 and the given 64-bit `largesize`, then `payload`.
    private func largeBox(_ type: String, largesize: UInt64, _ payload: [UInt8] = []) -> [UInt8] {
        be32(1) + Array(type.utf8) + be64(largesize) + payload
    }

    private var ftyp: [UInt8] { box("ftyp", Array("crx ".utf8) + be32(1) + Array("crx isom".utf8)) }

    private static let prvwUUID: [UInt8] = [0xEA, 0xF4, 0x2B, 0x5E, 0x1C, 0x98, 0x4B, 0x88,
                                            0xB9, 0xFB, 0xB7, 0xDC, 0x40, 0x6E, 0x4D, 0x16]

    /// The PRVW `uuid` box as Canon writes it: 8 bytes, the PRVW header (u16 width @14, u16 height @16,
    /// u32 size @20), then a JPEG or the HEVC property boxes and `IMGD`.
    private func prvw(width: Int, height: Int, _ content: [UInt8]) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 24)
        header.replaceSubrange(14..<16, with: be16(width))
        header.replaceSubrange(16..<18, with: be16(height))
        header.replaceSubrange(20..<24, with: be32(content.count))
        return box("uuid", Self.prvwUUID + [UInt8](repeating: 0, count: 8) + header + content)
    }

    /// A `CRAW` sample entry: the visual sample entry fields (u16 width @32, height @34), `child` at byte 90.
    private func craw(width: Int, height: Int, _ child: [UInt8]) -> [UInt8] {
        box("CRAW", [UInt8](repeating: 0, count: 24) + be16(width) + be16(height) + [UInt8](repeating: 0, count: 54) + child)
    }

    /// A `trak` with the sample entry `entry` and one sample of `length` bytes at file offset `chunk`.
    private func trak(_ entry: [UInt8], chunk: Int, length: Int) -> [UInt8] {
        let stsd = box("stsd", be32(0) + be32(1) + entry)
        let stsz = box("stsz", be32(0) + be32(length) + be32(1))
        let co64 = box("co64", be32(0) + be32(1) + be64(UInt64(chunk)))
        return box("trak", box("mdia", box("minf", box("stbl", stsd + stsz + co64))))
    }

    private func jpegTrak(width: Int, height: Int, chunk: Int, length: Int) -> [UInt8] {
        trak(craw(width: width, height: height, box("JPEG", be32(0))), chunk: chunk, length: length)
    }

    private func jpeg(width: Int, height: Int) throws -> [UInt8] {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 1, green: 0.5, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return [UInt8](data as Data)
    }

    private func write(_ bytes: [UInt8], _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    /// ftyp, moov (a track JPEG, then `extraTraks`), the PRVW JPEG, `tail` boxes, then an `mdat` holding the
    /// track JPEG.
    private func container(extraTraks: [UInt8] = [], tail: [UInt8] = [], track: [UInt8], preview: [UInt8]) -> [UInt8] {
        func build(chunk: Int) -> [UInt8] {
            ftyp + box("moov", jpegTrak(width: 600, height: 400, chunk: chunk, length: track.count) + extraTraks)
                + prvw(width: 300, height: 200, preview) + tail
        }
        let head = build(chunk: 0)
        return build(chunk: head.count + 8) + box("mdat", track)
    }

    // MARK: Box sizes

    func testWellFormedContainerYieldsPreviewAndTrackJPEG() throws {
        let preview = try jpeg(width: 300, height: 200), track = try jpeg(width: 600, height: 400)
        let url = try write(container(track: track, preview: preview), "good.cr3")
        let candidates = CR3Preview.candidates(url: url)
        XCTAssertEqual(candidates.map { "\($0.width)x\($0.height)" }, ["300x200", "600x400"], "smallest first")
        XCTAssertEqual(CR3Preview.bytes(url: url, candidates[0]), Data(preview))
        XCTAssertEqual(CR3Preview.bytes(url: url, candidates[1]), Data(track))
    }

    /// A 64-bit `largesize` near Int.max made `offset + size` overflow: a trap, so the app died as soon as
    /// such a file came within the prefetch windows. Now the walk stops at the bad box and keeps what it
    /// found before it.
    func testHostileTopLevelBoxSizeStopsTheWalk() throws {
        let preview = try jpeg(width: 300, height: 200), track = try jpeg(width: 600, height: 400)
        for largesize in [UInt64(Int.max), UInt64(Int.max) - 100, UInt64.max, 15] {
            let hostile = largeBox("mdat", largesize: largesize, [UInt8](repeating: 0, count: 16))
            let url = try write(container(tail: hostile, track: track, preview: preview), "top.cr3")
            XCTAssertEqual(CR3Preview.candidates(url: url).map(\.width), [300, 600], "largesize \(largesize)")
        }
    }

    func testHostileChildBoxSizeStopsTheWalk() throws {
        let preview = try jpeg(width: 300, height: 200), track = try jpeg(width: 600, height: 400)
        for largesize in [UInt64(Int.max), UInt64(Int.max) - 100, UInt64.max, 15] {
            // Inside moov (after a good trak) and inside stbl of a second trak.
            let trak = largeBox("trak", largesize: largesize, [UInt8](repeating: 0, count: 8))
            let deep = box("trak", box("mdia", box("minf", box("stbl", largeBox("stsd", largesize: largesize, be32(0) + be32(1))))))
            for extra in [trak, deep] {
                let url = try write(container(extraTraks: extra, track: track, preview: preview), "child.cr3")
                XCTAssertEqual(CR3Preview.candidates(url: url).map(\.width), [300, 600], "largesize \(largesize)")
            }
        }
    }

    // MARK: PRVW HEVC property boxes

    /// `hevcPreview` appended every hvcC/colr/pixi box: 300 empty `colr` boxes (2.4 KB, inside the 4 KB window
    /// the parser reads) made `heif` convert property index 256 to UInt8 and trap. One box per property type
    /// is kept now, and `heif` refuses lists its 7-bit `ipma` indices cannot address.
    func testPRVWPropertyBoxesAreBounded() throws {
        let nal: [UInt8] = be32(12) + [0x40, 0x01, 0x0C, 0x01, 0xFF, 0xFF, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00]
        let colr = (0..<300).flatMap { _ in box("colr", []) }
        let content = box("hvcC", []) + colr + box("pixi", be32(0)) + box("colr", []) + box("IMGD", be32(nal.count) + nal)
        let url = try write(ftyp + prvw(width: 810, height: 540, content), "hevc.cr3")
        let candidate = try XCTUnwrap(CR3Preview.candidates(url: url).first)
        XCTAssertTrue(candidate.isHEVC)
        XCTAssertEqual(candidate.length, nal.count)
        XCTAssertEqual(candidate.hevcProperties?.map { String(decoding: $0[4..<8], as: UTF8.self) }, ["hvcC", "colr", "pixi"])

        let heif = [UInt8](try XCTUnwrap(CR3Preview.bytes(url: url, candidate)))
        // ipma: version/flags, entry count 1, item 1, then the associations: hvcC (essential), colr, pixi, ispe.
        let ipma = try XCTUnwrap((0..<heif.count - 4).first { heif[$0..<$0 + 4].elementsEqual("ipma".utf8) })
        XCTAssertEqual(Array(heif[ipma + 4..<ipma + 15]), [0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 4])
        XCTAssertEqual(Array(heif[ipma + 15..<ipma + 19]), [0x81, 2, 3, 4])
        XCTAssertEqual(Array(heif.suffix(nal.count)), nal, "the bitstream closes the mdat")

        let ispe = 1
        XCTAssertNotNil(CR3Preview.heif(hevc: Data(nal), properties: Array(repeating: box("colr", []), count: 127 - ispe),
                                        width: 8, height: 8), "property index 127 fits in 7 bits")
        XCTAssertNil(CR3Preview.heif(hevc: Data(nal), properties: Array(repeating: box("colr", []), count: 128 - ispe),
                                     width: 8, height: 8))
        XCTAssertNil(CR3Preview.heif(hevc: Data(nal), properties: Array(repeating: box("colr", []), count: 300),
                                     width: 8, height: 8))
    }

    // MARK: Track-1 HEVC tile grid

    /// A solid HEVC picture as ImageIO encodes it: its property boxes (`hvcC`, `colr`, `pixi`) and its bitstream
    /// (the `mdat` payload of the single-item HEIC: length-prefixed NAL units).
    private func hevcTile(width: Int, height: Int, rgb: (CGFloat, CGFloat, CGFloat)) throws
        -> (properties: [[UInt8]], bitstream: [UInt8]) {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        // HEIC needs the hardware HEVC encoder, which CI virtual machines may lack.
        guard let destination = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else {
            throw XCTSkip("no HEIC encoder")
        }
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
                                   [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw XCTSkip("cannot encode HEIC") }
        let heic = [UInt8](data as Data)
        /// The first box of `type` and its header length (ImageIO writes `mdat` with a 64-bit largesize).
        func first(_ type: String) throws -> (box: [UInt8], header: Int) {
            let at = try XCTUnwrap((4..<heic.count - 4).first { heic[$0..<$0 + 4].elementsEqual(type.utf8) }, type) - 4
            func be(_ range: Range<Int>) -> Int { heic[range].reduce(0) { $0 << 8 | Int($1) } }
            let large = be(at..<at + 4) == 1
            return (Array(heic[at..<at + (large ? be(at + 8..<at + 16) : be(at..<at + 4))]), large ? 16 : 8)
        }
        let mdat = try first("mdat")
        return ([try first("hvcC").box, try first("colr").box, try first("pixi").box], Array(mdat.box.dropFirst(mdat.header)))
    }

    /// A `trak` whose `CRAW` entry has an `HEVC` child, as HDR PQ bodies write it: a u32, `GRID` (u32, tile count,
    /// ImageGrid), `CISZ` (u32, tile width, tile height), then the property boxes.
    private func hevcTrak(width: Int, height: Int, rows: Int = 2, columns: Int = 2, tile: (Int, Int), count: Int? = nil,
                          properties: [[UInt8]], chunk: Int, length: Int) -> [UInt8] {
        let grid = box("GRID", be32(0) + be32(count ?? rows * columns) + [0, 0, UInt8(rows - 1), UInt8(columns - 1)]
                       + be16(width) + be16(height))
        let cisz = box("CISZ", be32(0) + be32(tile.0) + be32(tile.1))
        let hevc = box("HEVC", be32(1) + grid + cisz + properties.flatMap { $0 })
        return trak(craw(width: width, height: height, hevc), chunk: chunk, length: length)
    }

    /// ftyp, moov with `trak(chunk)`, then the `mdat` holding `sample` at `chunk`.
    private func file(_ trak: (Int) -> [UInt8], sample: [UInt8]) -> [UInt8] {
        func head(_ chunk: Int) -> [UInt8] { ftyp + box("moov", trak(chunk)) }
        return head(head(0).count + 8) + box("mdat", sample)
    }

    /// 2 × 2 tiles of 256 × 128 (red, green / blue, white) cropped to 500 × 250, as the EOS R5 Mark II stores 4 × 6
    /// tiles of 2048 × 960 cropped to 8192 × 5464: one candidate, whose HEIF ImageIO decodes with every tile in place.
    func testHEVCTileGridBecomesAHEIFGrid() throws {
        let colors: [(CGFloat, CGFloat, CGFloat)] = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 1)]
        let tiles = try colors.map { try hevcTile(width: 256, height: 128, rgb: $0) }
        let sample = tiles.flatMap { be32($0.bitstream.count) + $0.bitstream }
        let url = try write(file({ self.hevcTrak(width: 500, height: 250, tile: (256, 128), properties: tiles[0].properties,
                                                 chunk: $0, length: sample.count) }, sample: sample), "grid.cr3")
        let candidate = try XCTUnwrap(CR3Preview.candidates(url: url).first)
        XCTAssertEqual(candidate.grid, CR3Preview.Grid(rows: 2, columns: 2, tileWidth: 256, tileHeight: 128))
        XCTAssertEqual("\(candidate.width)x\(candidate.height)", "500x250")
        XCTAssertEqual(candidate.length, sample.count)

        let heif = try XCTUnwrap(CR3Preview.bytes(url: url, candidate))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(heif as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil))
        XCTAssertEqual("\(image.width)x\(image.height)", "500x250")
        let context = try XCTUnwrap(CGContext(data: nil, width: 500, height: 250, bitsPerComponent: 8, bytesPerRow: 2000,
                                              space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 500, height: 250))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let expect = [((125, 62), (255, 0, 0)), ((375, 62), (0, 255, 0)), ((125, 187), (0, 0, 255)), ((375, 187), (255, 255, 255))]
        for ((x, y), rgb) in expect {
            let p = pixels + y * 2000 + x * 4
            XCTAssert(abs(Int(p[0]) - rgb.0) < 24 && abs(Int(p[1]) - rgb.1) < 24 && abs(Int(p[2]) - rgb.2) < 24,
                      "(\(x), \(y)) = \(p[0]), \(p[1]), \(p[2]); want \(rgb)")
        }
    }

    /// Grid fields and tile sizes come from the file: inconsistent ones are rejected without trapping, either as
    /// a candidate or when the HEIF is built.
    func testHostileHEVCGridIsRejected() throws {
        let hvcC = box("hvcC", [1, 2, 3]), tile = [UInt8](repeating: 7, count: 16)
        let good = (0..<4).flatMap { _ in be32(tile.count) + tile }
        func candidates(tile size: (Int, Int) = (256, 128), count: Int? = nil, properties: [[UInt8]]? = nil,
                        sample: [UInt8]? = nil) throws -> (URL, [CR3Preview.Candidate]) {
            let sample = sample ?? good
            let url = try write(file({ self.hevcTrak(width: 500, height: 250, tile: size, count: count,
                                                     properties: properties ?? [hvcC], chunk: $0, length: sample.count) },
                                     sample: sample), "hostile-grid.cr3")
            return (url, CR3Preview.candidates(url: url))
        }
        let (url, found) = try candidates()
        XCTAssertNotNil(CR3Preview.bytes(url: url, try XCTUnwrap(found.first)), "the well-formed grid builds")
        // No candidate: tile count ≠ rows × columns; tiles that miss the output or overshoot a whole column; no hvcC.
        let rejected: [((Int, Int), Int?, [[UInt8]]?)] = [
            ((256, 128), 5, nil), ((100, 128), nil, nil), ((600, 128), nil, nil), ((0, 0), nil, nil),
            ((0xFFFF_FFFF, 0xFFFF_FFFF), nil, nil), ((256, 128), nil, [box("colr", [])]),
        ]
        for (size, count, properties) in rejected {
            XCTAssertTrue(try candidates(tile: size, count: count, properties: properties).1.isEmpty, "\(size) \(String(describing: count))")
        }
        // A candidate, but no HEIF: a tile running past the sample, too few tiles, an empty tile.
        for sample in [be32(Int(UInt32.max)) + tile + good, Array(good.prefix(3 * (4 + tile.count))), be32(0) + good] {
            let (url, found) = try candidates(sample: sample)
            XCTAssertNil(CR3Preview.bytes(url: url, try XCTUnwrap(found.first)))
        }
        for (rows, columns) in [(0, 2), (Int.max, Int.max), (257, 1), (128, 64)] {
            let grid = CR3Preview.Grid(rows: rows, columns: columns, tileWidth: 256, tileHeight: 128)
            XCTAssertNil(CR3Preview.heif(hevc: Data(good), properties: [hvcC], width: 500, height: 250, grid: grid), "\(rows)x\(columns)")
        }
        XCTAssertNil(CR3Preview.heif(hevc: Data(good), properties: [], width: 500, height: 250))
        XCTAssertNil(CR3Preview.heif(hevc: Data(good), properties: [hvcC], width: 1 << 16, height: 250))
    }

    // MARK: Corpus

    private func corpusCR3() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["PEEKABOO_CORPUS"], !path.isEmpty else {
            throw XCTSkip("PEEKABOO_CORPUS is not set")
        }
        let url = URL(fileURLWithPath: path).appendingPathComponent("raw/raw_canon_eosr5m2_45mp.CR3")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("no CR3 in the corpus") }
        return url
    }

    private struct Box { let type: String; let offset: Int; let size: Int; let header: Int }

    /// The boxes in [start, end) of `file`.
    private func boxes(_ file: FileHandle, _ start: Int, _ end: Int) throws -> [Box] {
        var result: [Box] = [], offset = start
        while offset + 16 <= end {
            try file.seek(toOffset: UInt64(offset))
            let head = [UInt8](try XCTUnwrap(try file.read(upToCount: 16)))
            var size = head[0..<4].reduce(0) { $0 << 8 | Int($1) }, header = 8
            if size == 1 { size = head[8..<16].reduce(0) { $0 << 8 | Int($1) }; header = 16 }
            guard size >= header, size <= end - offset else { break }
            result.append(Box(type: String(decoding: head[4..<8], as: UTF8.self), offset: offset, size: size, header: header))
            offset += size
        }
        return result
    }

    /// The real EOS R5 Mark II CR3 with its `mdat` largesize, or the header of its last `trak`, rewritten to
    /// 2^63 − 1: both trapped in `ImageIODecoder.decode` (`.preview` and `.screen`), killing the app on prefetch.
    /// They now preview from the PRVW like the original.
    func testCorpusCR3WithHostileBoxSizesStillPreviews() throws {
        let original = try corpusCR3()
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let pool = PixelBufferPool(device: device)
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: original.path)[.size] as? Int)
        let reader = try FileHandle(forReadingFrom: original)
        defer { try? reader.close() }
        let top = try boxes(reader, 0, size)
        let mdat = try XCTUnwrap(top.first { $0.type == "mdat" })
        XCTAssertEqual(mdat.header, 16, "the corpus mdat uses a 64-bit largesize")
        let moov = try XCTUnwrap(top.first { $0.type == "moov" })
        let lastTrak = try XCTUnwrap(try boxes(reader, moov.offset + moov.header, moov.offset + moov.size).last { $0.type == "trak" })

        let patches: [(String, Int, [UInt8])] = [
            ("mdat", mdat.offset + 8, be64(UInt64(Int.max))),
            ("trak", lastTrak.offset, be32(1) + Array("trak".utf8) + be64(UInt64(Int.max))),
        ]
        let decoder = ImageIODecoder()
        let reference = try decoder.decode(original, tier: .preview, targetLongSide: 512, pool: pool)
        for (name, offset, bytes) in patches {
            let url = dir.appendingPathComponent("hostile_\(name).CR3")
            try FileManager.default.copyItem(at: original, to: url)  // an APFS clone: only the patched block is copied
            let writer = try FileHandle(forWritingTo: url)
            try writer.seek(toOffset: UInt64(offset))
            try writer.write(contentsOf: bytes)
            try writer.close()
            XCTAssertEqual(try decoder.probe(url).typeIdentifier, "com.canon.cr3-raw-image", name)
            let preview = try decoder.decode(url, tier: .preview, targetLongSide: 512, pool: pool)
            XCTAssertEqual(preview.pixels.width, reference.pixels.width, "\(name): the PRVW preview")
            XCTAssertEqual(preview.pixels.height, reference.pixels.height, name)
            XCTAssertNotEqual(preview.pixels.layout, .rgba16, "\(name): no RAW decode")
        }
    }

    /// 8-bit (r, g, b) at (x, y), nil for other layouts.
    private func rgb(_ pb: PixelBuffer, _ x: Int, _ y: Int) -> (Int, Int, Int)? {
        if case .surface(let surface) = pb.storage { IOSurfaceLock(surface, .readOnly, nil) }
        defer { if case .surface(let surface) = pb.storage { IOSurfaceUnlock(surface, .readOnly, nil) } }
        let p = pb.baseAddress.advanced(by: y * pb.bytesPerRow + x * pb.layout.bytesPerPixel)
        func b(_ i: Int) -> Int { Int(p.load(fromByteOffset: i, as: UInt8.self)) }
        switch pb.layout {
        case .rgba8: return (b(0), b(1), b(2))
        case .bgra8: return (b(2), b(1), b(0))
        case .argb8: return (b(1), b(2), b(3))
        default: return nil
        }
    }

    /// The EOS R5 Mark II in HDR PQ stores its full-size rendition as 4 × 6 HEVC tiles of 2048 × 960. `.screen` now
    /// decodes it on the hardware HEVC path (M4 Pro, release: 48 ms as native YCbCr, 75 ms through ImageIO's SDR
    /// CGImage) instead of decoding the RAW (421 ms, 16-bit), and shows the same picture as the PRVW preview.
    func testCorpusCR3ScreenTierFromHEVCGrid() throws {
        let url = try corpusCR3()
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let pool = PixelBufferPool(device: device)
        let candidate = try XCTUnwrap(CR3Preview.candidates(url: url).first { $0.grid != nil })
        XCTAssertEqual(candidate.grid, CR3Preview.Grid(rows: 6, columns: 4, tileWidth: 2048, tileHeight: 960))
        XCTAssertEqual("\(candidate.width)x\(candidate.height)", "8192x5464")

        let decoder = ImageIODecoder()
        _ = try decoder.decode(url, tier: .screen, targetLongSide: 3456, pool: pool)  // HEVC decoder warm-up
        let start = Trace.now()
        let screen = try decoder.decode(url, tier: .screen, targetLongSide: 3456, pool: pool)
        let ms = Trace.ms(since: start)
        XCTAssertEqual("\(screen.pixels.width)x\(screen.pixels.height)", "4096x2732", "/2 covers 3456 px")
        XCTAssertNotEqual(screen.pixels.layout, .rgba16, "not a RAW decode")
        XCTAssertLessThan(ms, 250, "HEVC grid .screen: \(ms) ms")

        // Every tile in place: the same picture as the preview (the camera's 1620 × 1080 PRVW).
        let preview = try decoder.decode(url, tier: .preview, targetLongSide: 512, pool: pool)
        var diff = 0, samples = 0
        for fy in stride(from: 0.05, to: 1, by: 0.1) {
            for fx in stride(from: 0.05, to: 1, by: 0.1) {
                let a = try XCTUnwrap(rgb(screen.pixels, Int(fx * 4096), Int(fy * 2732)))
                let b = try XCTUnwrap(rgb(preview.pixels, Int(fx * Double(preview.pixels.width)), Int(fy * Double(preview.pixels.height))))
                diff += abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)
                samples += 3
            }
        }
        print(String(format: "HEVC grid .screen %.1f ms; mean |screen - preview| %.2f", ms, Double(diff) / Double(samples)))
        XCTAssertLessThan(Double(diff) / Double(samples), 12, "screen tier shows the preview's picture")
    }
}
