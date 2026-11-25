import CPeekabooDecode
import CoreGraphics
import ImageIO
import Metal
import XCTest
import zlib
@testable import PeekabooCore

/// The own PNG decoder (`CPeekabooDecode`) against ImageIO on files written in the test: every colour type and bit
/// depth it takes, every filter type, tRNS, IDAT split across chunks, odd widths, the pipelined (two-thread) path, the
/// box-filtered tiers, the hand-overs to ImageIO, and mutated files.
final class PNGDecodeTests: XCTestCase {
    private var dir: URL!
    private var pool: PixelBufferPool!
    private let decoder = ImageIODecoder()

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        pool = PixelBufferPool(device: device)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("peekaboo-png-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: Encoder

    /// A PNG of `samples` (per pixel `channels` values of `depth` bits; palette images: indices), rows filtered with
    /// the filter type `filters[y % filters.count]`, the zlib stream split into IDAT chunks of `idatSize` bytes.
    private func png(width: Int, height: Int, depth: Int, colorType: UInt8, samples: [Int], filters: [UInt8] = [0, 1, 2, 3, 4],
                     before: [(String, [UInt8])] = [], interlace: UInt8 = 0, idatSize: Int = 997) -> Data {
        let channels = [0: 1, 2: 3, 3: 1, 4: 2, 6: 4][Int(colorType)]!
        let bits = channels * depth
        let rowBytes = (width * bits + 7) / 8
        let bpp = max(1, bits / 8)
        var raw: [UInt8] = []
        var previous = [UInt8](repeating: 0, count: rowBytes)
        for y in 0..<height {
            var row = [UInt8](repeating: 0, count: rowBytes)
            for x in 0..<width {
                for c in 0..<channels {
                    let v = samples[(y * width + x) * channels + c]
                    switch depth {
                    case 16: row[(x * channels + c) * 2] = UInt8(v >> 8); row[(x * channels + c) * 2 + 1] = UInt8(v & 255)
                    case 8: row[x * channels + c] = UInt8(v)
                    default:
                        let bit = (x * channels + c) * depth
                        row[bit / 8] |= UInt8(v) << (8 - depth - bit % 8)
                    }
                }
            }
            let type = filters[y % filters.count]
            raw.append(type)
            for i in 0..<rowBytes {
                let a = i >= bpp ? Int(row[i - bpp]) : 0, b = Int(previous[i]), c = i >= bpp ? Int(previous[i - bpp]) : 0
                let predictor: Int
                switch type {
                case 1: predictor = a
                case 2: predictor = b
                case 3: predictor = (a + b) / 2
                case 4:
                    let p = a + b - c, pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                    predictor = pa <= pb && pa <= pc ? a : pb <= pc ? b : c
                default: predictor = 0
                }
                raw.append(UInt8(truncatingIfNeeded: Int(row[i]) - predictor))
            }
            previous = row
        }
        var compressed = [UInt8](repeating: 0, count: Int(compressBound(uLong(raw.count))))
        var length = uLongf(compressed.count)
        XCTAssertEqual(compress2(&compressed, &length, raw, uLong(raw.count), 6), Z_OK)
        let stream = Array(compressed[0..<Int(length)])
        var file: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        file += chunk("IHDR", be32(width) + be32(height) + [UInt8(depth), colorType, 0, 0, interlace])
        for (type, body) in before { file += chunk(type, body) }
        var offset = 0
        repeat {
            let end = min(stream.count, offset + idatSize)
            file += chunk("IDAT", Array(stream[offset..<end]))
            offset = end
        } while offset < stream.count
        file += chunk("IEND", [])
        return Data(file)
    }

    private func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }

    private func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let typed = Array(type.utf8) + body
        let crc = typed.withUnsafeBufferPointer { crc32(0, $0.baseAddress, uInt($0.count)) }
        return be32(body.count) + typed + be32(Int(crc))
    }

    /// Deterministic samples: gradients, so the filters have something to predict, plus noise, so they miss.
    private func samples(_ width: Int, _ height: Int, channels: Int, max: Int, seed: UInt64 = 1) -> [Int] {
        var state = seed
        return (0..<width * height * channels).map { i in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let pixel = i / channels, x = pixel % width, y = pixel / width
            let smooth = (x * 7 + y * 3 + (i % channels) * 50) % (max + 1)
            return (i % 5 == 0) ? Int(state >> 33) % (max + 1) : smooth
        }
    }

    private func write(_ data: Data, _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: ImageIO reference

    /// ImageIO's decode of `url` as RGBA samples (16-bit files: 16-bit values; no alpha: A = max).
    private func reference(_ url: URL) throws -> (samples: [Int], width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let bytes = try XCTUnwrap(image.dataProvider?.data) as Data
        let (w, h, stride) = (image.width, image.height, image.bytesPerRow)
        var out = [Int](repeating: 0, count: w * h * 4)
        if let space = image.colorSpace, space.model == .indexed {
            let table = try XCTUnwrap(space.colorTable)
            for y in 0..<h {
                for x in 0..<w {
                    let index = Int(bytes[y * stride + x])
                    for c in 0..<3 { out[(y * w + x) * 4 + c] = Int(table[3 * index + c]) }
                    out[(y * w + x) * 4 + 3] = 255
                }
            }
            return (out, w, h)
        }
        let wide = image.bitsPerComponent == 16
        let little = image.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue == CGBitmapInfo.byteOrder16Little.rawValue
        let channels = image.bitsPerPixel / image.bitsPerComponent
        let alpha = image.alphaInfo == .last || image.alphaInfo == .premultipliedLast
        XCTAssertNotEqual(image.alphaInfo, .premultipliedLast, "ImageIO hands PNG alpha over straight")
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<4 {
                    let value: Int
                    if c == 3 && !alpha {
                        value = wide ? 65535 : 255
                    } else if wide {
                        let i = y * stride + (x * channels + c) * 2
                        value = little ? Int(bytes[i + 1]) << 8 | Int(bytes[i]) : Int(bytes[i]) << 8 | Int(bytes[i + 1])
                    } else {
                        value = Int(bytes[y * stride + x * channels + c])
                    }
                    out[(y * w + x) * 4 + c] = value
                }
            }
        }
        return (out, w, h)
    }

    /// RGBA samples of a decoded buffer (`.rgba8` or `.rgba16`).
    private func values(_ p: PixelBuffer) -> [Int] {
        var out = [Int](repeating: 0, count: p.width * p.height * 4)
        for y in 0..<p.height {
            let row = p.baseAddress.advanced(by: y * p.bytesPerRow)
            for i in 0..<(p.width * 4) {
                out[y * p.width * 4 + i] = p.layout == .rgba16
                    ? Int(row.load(fromByteOffset: 2 * i, as: UInt16.self)) : Int(row.load(fromByteOffset: i, as: UInt8.self))
            }
        }
        return out
    }

    private func assertMatchesImageIO(_ url: URL, wide: Bool, alpha: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        let image = try decoder.decode(url, tier: .full, targetLongSide: 0, pool: pool)
        let p = image.pixels
        XCTAssertEqual(p.layout, wide ? .rgba16 : .rgba8, "own decoder (ImageIO hands over BGRA)", file: file, line: line)
        if case .metal = p.storage {} else { XCTFail("own decoder writes a pooled buffer", file: file, line: line) }
        XCTAssertEqual(p.alpha, alpha ? .straight : .opaque, file: file, line: line)
        let expected = try reference(url)
        XCTAssertEqual(p.width, expected.width, file: file, line: line)
        XCTAssertEqual(p.height, expected.height, file: file, line: line)
        let got = values(p)
        if let i = got.indices.first(where: { got[$0] != expected.samples[$0] }) {
            XCTFail("sample \(i) (pixel \(i / 4), channel \(i % 4)): \(got[i]) vs ImageIO \(expected.samples[i])", file: file, line: line)
        }
    }

    // MARK: Exactness

    func testTruecolourEveryFilterMatchesImageIO() throws {
        for (w, h) in [(1, 1), (3, 5), (61, 17), (640, 480)] {
            let rgb = try write(png(width: w, height: h, depth: 8, colorType: 2, samples: samples(w, h, channels: 3, max: 255)),
                                "rgb-\(w).png")
            try assertMatchesImageIO(rgb, wide: false, alpha: false)
            let rgba = try write(png(width: w, height: h, depth: 8, colorType: 6, samples: samples(w, h, channels: 4, max: 255)),
                                 "rgba-\(w).png")
            try assertMatchesImageIO(rgba, wide: false, alpha: true)
        }
    }

    func testSixteenBitMatchesImageIO() throws {
        let (w, h) = (97, 31)
        try assertMatchesImageIO(write(png(width: w, height: h, depth: 16, colorType: 2, samples: samples(w, h, channels: 3, max: 65535)),
                                       "rgb16.png"), wide: true, alpha: false)
        try assertMatchesImageIO(write(png(width: w, height: h, depth: 16, colorType: 6, samples: samples(w, h, channels: 4, max: 65535)),
                                       "rgba16.png"), wide: true, alpha: true)
    }

    func testPaletteEveryDepthMatchesImageIO() throws {
        for depth in [1, 2, 4, 8] {
            let entries = 1 << depth
            let palette = (0..<entries * 3).map { UInt8(($0 * 37 + depth) % 256) }
            let (w, h) = (53, 9)
            let indices = samples(w, h, channels: 1, max: entries - 1, seed: UInt64(depth))
            let plain = try write(png(width: w, height: h, depth: depth, colorType: 3, samples: indices, before: [("PLTE", palette)]),
                                  "p\(depth).png")
            try assertMatchesImageIO(plain, wide: false, alpha: false)
            let alphas = (0..<min(entries, 5)).map { UInt8($0 * 60) }
            let transparent = try write(png(width: w, height: h, depth: depth, colorType: 3, samples: indices,
                                            before: [("PLTE", palette), ("tRNS", alphas)]), "pt\(depth).png")
            try assertMatchesImageIO(transparent, wide: false, alpha: true)
        }
    }

    func testColourKeyTransparencyMatchesImageIO() throws {
        let (w, h) = (40, 12)
        var rgb = samples(w, h, channels: 3, max: 255)
        for x in stride(from: 0, to: w * h, by: 7) { rgb[3 * x] = 10; rgb[3 * x + 1] = 20; rgb[3 * x + 2] = 30 }
        let key: [UInt8] = [0, 10, 0, 20, 0, 30]
        try assertMatchesImageIO(write(png(width: w, height: h, depth: 8, colorType: 2, samples: rgb, before: [("tRNS", key)]),
                                       "key.png"), wide: false, alpha: true)
        let deep = rgb.map { $0 * 257 }
        let deepKey: [UInt8] = [10, 10, 20, 20, 30, 30]
        try assertMatchesImageIO(write(png(width: w, height: h, depth: 16, colorType: 2, samples: deep, before: [("tRNS", deepKey)]),
                                       "key16.png"), wide: true, alpha: true)
    }

    /// Large enough (≥ 1 MB of filtered rows) to inflate on the second thread, in one IDAT and in many.
    func testPipelinedDecodeMatchesImageIO() throws {
        let (w, h) = (700, 520)
        let pixels = samples(w, h, channels: 4, max: 255, seed: 7)
        try assertMatchesImageIO(write(png(width: w, height: h, depth: 8, colorType: 6, samples: pixels, idatSize: 1 << 30), "one.png"),
                                 wide: false, alpha: true)
        try assertMatchesImageIO(write(png(width: w, height: h, depth: 8, colorType: 6, samples: pixels, idatSize: 8192), "many.png"),
                                 wide: false, alpha: true)
        // ImageIO's own encoder (adaptive filters, 16 KB IDATs), as most PNGs on a Mac are written.
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(dir.appendingPathComponent("one.png") as CFURL, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let url = dir.appendingPathComponent("imageio.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try assertMatchesImageIO(url, wide: false, alpha: true)
    }

    // MARK: Reduced tiers

    func testBoxFilteredTiers() throws {
        let (w, h) = (203, 101)
        for (colorType, channels) in [(UInt8(2), 3), (6, 4)] {
            let url = try write(png(width: w, height: h, depth: 8, colorType: colorType,
                                    samples: samples(w, h, channels: channels, max: 255, seed: 3)), "box\(colorType).png")
            let full = try reference(url).samples
            for (target, factor) in [(100, 2), (50, 4), (25, 8)] {
                let image = try decoder.decode(url, tier: .screen, targetLongSide: target, pool: pool)
                let p = image.pixels
                XCTAssertEqual(p.width, (w + factor - 1) / factor, "factor \(factor)")
                XCTAssertEqual(p.height, (h + factor - 1) / factor)
                XCTAssertEqual(p.alpha, channels == 4 ? .premultiplied : .opaque)
                XCTAssertEqual(image.fullWidth, w)
                let got = values(p)
                for oy in 0..<p.height {
                    for ox in 0..<p.width {
                        var sums = [0, 0, 0, 0], n = 0
                        for y in oy * factor..<min(h, oy * factor + factor) {
                            for x in ox * factor..<min(w, ox * factor + factor) {
                                let s = Array(full[(y * w + x) * 4..<(y * w + x) * 4 + 4])
                                for c in 0..<3 { sums[c] += channels == 4 ? s[c] * s[3] : s[c] }
                                sums[3] += s[3]
                                n += 1
                            }
                        }
                        let i = (oy * p.width + ox) * 4
                        for c in 0..<3 {
                            let want = channels == 4 ? (sums[c] + 255 * n / 2) / (255 * n) : (sums[c] + n / 2) / n
                            XCTAssertEqual(got[i + c], want, "factor \(factor) pixel (\(ox),\(oy)) channel \(c)")
                        }
                        XCTAssertEqual(got[i + 3], channels == 4 ? (sums[3] + n / 2) / n : 255)
                    }
                }
            }
        }
    }

    func testPreviewOfLargePNGIsSmall() throws {
        let (w, h) = (2400, 1200)
        let url = try write(png(width: w, height: h, depth: 8, colorType: 2, samples: samples(w, h, channels: 3, max: 255)), "big.png")
        let preview = try decoder.decode(url, tier: .preview, targetLongSide: 256, pool: pool)
        XCTAssertEqual(preview.pixels.width, 300, "/8 covers 256 px")
        XCTAssertEqual(preview.pixels.height, 150)
        XCTAssertEqual(preview.fullWidth, w)
    }

    // MARK: Hand-overs to ImageIO

    func testUnsupportedShapesGoToImageIO() throws {
        let (w, h) = (32, 16)
        let gray = try write(png(width: w, height: h, depth: 8, colorType: 0, samples: samples(w, h, channels: 1, max: 255)), "gray.png")
        let grayAlpha = try write(png(width: w, height: h, depth: 8, colorType: 4, samples: samples(w, h, channels: 2, max: 255)), "ga.png")
        let rgb = samples(w, h, channels: 3, max: 255)
        let animated = try write(png(width: w, height: h, depth: 8, colorType: 2, samples: rgb,
                                     before: [("acTL", be32(1) + be32(0))]), "apng.png")
        let critical = try write(png(width: w, height: h, depth: 8, colorType: 2, samples: rgb, before: [("ABCD", [1, 2, 3])]),
                                 "critical.png")
        for url in [gray, grayAlpha, animated, critical] {
            let data = try Data(contentsOf: url)
            let status = data.withUnsafeBytes { raw -> pb_png_status in
                var info = pb_png_info()
                return pb_png_read_info(raw.baseAddress!.assumingMemoryBound(to: UInt8.self), raw.count, &info)
            }
            XCTAssertEqual(status, PB_PNG_UNSUPPORTED, url.lastPathComponent)
        }
        for url in [gray, grayAlpha, animated] {
            let image = try decoder.decode(url, tier: .full, targetLongSide: 0, pool: pool)
            XCTAssertNotEqual(image.pixels.layout, .rgba8, "\(url.lastPathComponent): ImageIO's path")
            XCTAssertEqual(image.pixels.width, w)
        }
    }

    func testMalformedFilesAreRefusedNotMisdecoded() throws {
        let (w, h) = (64, 64)
        let good = png(width: w, height: h, depth: 8, colorType: 6, samples: samples(w, h, channels: 4, max: 255), idatSize: 300)
        var badCRC = [UInt8](good)
        badCRC[good.count - 30] ^= 0x55  // inside the last IDAT's data or CRC
        let badFilter = [UInt8](png(width: w, height: h, depth: 8, colorType: 6, samples: samples(w, h, channels: 4, max: 255),
                                    filters: [7], idatSize: 1 << 20))
        let truncated = [UInt8](good.prefix(good.count / 2))
        for (name, bytes) in [("crc", badCRC), ("filter", badFilter), ("truncated", truncated)] {
            let status = decodeDirectly(bytes, factor: 1)
            XCTAssertNotEqual(status, PB_PNG_OK, name)
            let url = try write(Data(bytes), "\(name).png")
            _ = try? decoder.decode(url, tier: .full, targetLongSide: 0, pool: pool)  // ImageIO decides; no crash
        }
    }

    /// The two-thread path stops cleanly whichever side fails: a bad filter type halfway (the unfiltering side) or the
    /// data running out (the inflating side). Every call joins its inflate thread, so repeating them leaves none behind.
    func testPipelinedFailuresStopBothThreads() {
        let (w, h) = (800, 400)  // 1.28 MB of filtered rows: inflated on a second thread
        let pixels = samples(w, h, channels: 4, max: 255, seed: 11)
        var filters = [UInt8](repeating: 4, count: h)
        filters[h / 2] = 9
        XCTAssertEqual(decodeDirectly([UInt8](png(width: w, height: h, depth: 8, colorType: 6, samples: pixels, filters: filters)),
                                      factor: 1), PB_PNG_INVALID)
        let good = [UInt8](png(width: w, height: h, depth: 8, colorType: 6, samples: pixels))
        XCTAssertEqual(decodeDirectly(good, factor: 1), PB_PNG_OK)
        var truncated = Array(good.prefix(good.count * 2 / 3))
        fixCRCs(&truncated)
        XCTAssertEqual(decodeDirectly(truncated, factor: 1), PB_PNG_INVALID)
        for factor: UInt32 in [1, 2, 4, 8, 1, 2, 4, 8] { XCTAssertEqual(decodeDirectly(truncated, factor: factor), PB_PNG_INVALID) }
    }

    /// Thousands of corrupted variants (flipped bytes, truncations) of valid files: every call returns, none crashes.
    func testMutatedFilesNeverCrash() throws {
        let palette = (0..<16 * 3).map { UInt8($0 * 5) }
        let seeds: [[UInt8]] = [
            [UInt8](png(width: 33, height: 20, depth: 8, colorType: 6, samples: samples(33, 20, channels: 4, max: 255), idatSize: 200)),
            [UInt8](png(width: 41, height: 7, depth: 4, colorType: 3, samples: samples(41, 7, channels: 1, max: 15),
                        before: [("PLTE", palette), ("tRNS", [0, 99])])),
            [UInt8](png(width: 9, height: 30, depth: 16, colorType: 2, samples: samples(9, 30, channels: 3, max: 65535))),
        ]
        var state: UInt64 = 42
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(state >> 33) % max(bound, 1)
        }
        var decoded = 0
        for _ in 0..<1500 {
            var bytes = seeds[next(seeds.count)]
            for _ in 0..<(1 + next(4)) { bytes[next(bytes.count)] = UInt8(next(256)) }
            // Half the time the CRCs are fixed up, so the damage reaches the header checks, the inflate and the filters.
            if next(2) == 0 { fixCRCs(&bytes) }
            if next(4) == 0 { bytes = Array(bytes.prefix(next(bytes.count))) }
            if decodeDirectly(bytes, factor: [1, 2, 8][next(3)]) == PB_PNG_OK { decoded += 1 }
        }
        XCTAssertGreaterThan(decoded, 0, "some mutations land in ignored chunks or pixel values and still decode")
    }

    /// Recompute the CRC of every chunk whose length still fits the file.
    private func fixCRCs(_ bytes: inout [UInt8]) {
        var pos = 8
        while pos + 12 <= bytes.count {
            let length = Int(bytes[pos]) << 24 | Int(bytes[pos + 1]) << 16 | Int(bytes[pos + 2]) << 8 | Int(bytes[pos + 3])
            guard length >= 0, length <= bytes.count - pos - 12 else { return }
            let crc = bytes[(pos + 4)..<(pos + 8 + length)].withContiguousStorageIfAvailable {
                crc32(0, $0.baseAddress, uInt($0.count))
            } ?? 0
            bytes.replaceSubrange((pos + 8 + length)..<(pos + 12 + length), with: be32(Int(crc)))
            pos += 12 + length
        }
    }

    /// `pb_png_decode` into a buffer sized from the header (as `ImageIODecoder` sizes it).
    private func decodeDirectly(_ bytes: [UInt8], factor: UInt32) -> pb_png_status {
        bytes.withUnsafeBufferPointer { raw -> pb_png_status in
            guard let base = raw.baseAddress else { return PB_PNG_INVALID }
            var info = pb_png_info()
            let status = pb_png_read_info(base, raw.count, &info)
            guard status == PB_PNG_OK, info.width <= 4096, info.height <= 4096 else { return status }
            let stride = Int(pb_png_scaled(info.width, factor)) * Int(pb_png_output_bytes_per_pixel(&info, factor))
            var out = [UInt8](repeating: 0, count: stride * Int(pb_png_scaled(info.height, factor)))
            return out.withUnsafeMutableBufferPointer { pb_png_decode(base, raw.count, factor, $0.baseAddress, stride, 2) }
        }
    }
}
