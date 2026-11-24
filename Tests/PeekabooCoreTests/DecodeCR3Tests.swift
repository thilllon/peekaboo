import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
import XCTest
@testable import PeekabooCore

/// `CR3Preview` on ISO-BMFF containers built in the test: hostile box sizes are rejected without trapping
/// (overflow traps stay on in release builds, and the parser runs for every CR3 that enters a prefetch
/// window), while well-formed previews still come out. With `$PEEKABOO_CORPUS`, the same damage applied
/// to a real CR3.
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

    /// A `trak` whose `CRAW` sample entry has a `JPEG` child: one sample of `length` bytes at file offset `chunk`.
    private func jpegTrak(width: Int, height: Int, chunk: Int, length: Int) -> [UInt8] {
        let craw = box("CRAW", [UInt8](repeating: 0, count: 24) + be16(width) + be16(height)
                       + [UInt8](repeating: 0, count: 50) + box("JPEG", be32(0)))
        let stsd = box("stsd", be32(0) + be32(1) + craw)
        let stsz = box("stsz", be32(0) + be32(length) + be32(1))
        let co64 = box("co64", be32(0) + be32(1) + be64(UInt64(chunk)))
        return box("trak", box("mdia", box("minf", box("stbl", stsd + stsz + co64))))
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
}
