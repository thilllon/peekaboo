import CoreGraphics
import CoreVideo
import ImageIO
import IOSurface
import Metal
import UniformTypeIdentifiers
import XCTest
@testable import PeekabooCore

/// HEIC / HEIF / AVIF variants written by ImageIO in the test: 10-bit (Display P3, PQ, HLG), multi-image files whose
/// primary is not the first image, sequences vs collections, depth and matte auxiliaries, lying and unusual file
/// extensions. (Orientation is checked end to end in `PeekabooRenderTests`.) Skipped where the HEVC encoder is missing.
final class DecodeHEIFTests: XCTestCase {
    private var dir: URL!
    private var pool: PixelBufferPool!
    private let decoder = ImageIODecoder()

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        pool = PixelBufferPool(device: device)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("peekaboo-heif-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: Fixtures

    /// Quadrants red | green / blue | white (row 0 on top), 8 or 16 bits per component, scaled by `level`.
    private func quadrants(_ width: Int, _ height: Int, space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!,
                           bits: Int = 8, level: Double = 1) throws -> CGImage {
        let bytes = bits / 8
        var data = Data(count: width * height * 4 * bytes)
        data.withUnsafeMutableBytes { raw in
            for y in 0..<height {
                for x in 0..<width {
                    let c: [Double]
                    switch (x < width / 2, y < height / 2) {
                    case (true, true): c = [1, 0, 0]
                    case (false, true): c = [0, 1, 0]
                    case (true, false): c = [0, 0, 1]
                    case (false, false): c = [1, 1, 1]
                    }
                    let values = c.map { $0 * level } + [1]
                    for (k, v) in values.enumerated() {
                        let i = ((y * width + x) * 4 + k) * bytes
                        if bytes == 1 {
                            raw[i] = UInt8(v * 255)
                        } else {
                            raw.storeBytes(of: UInt16(v * 65535).littleEndian, toByteOffset: i, as: UInt16.self)
                        }
                    }
                }
            }
        }
        var info = CGImageAlphaInfo.noneSkipLast.rawValue
        if bits == 16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: bits, bitsPerPixel: bits * 4,
                                     bytesPerRow: width * 4 * bytes, space: space, bitmapInfo: CGBitmapInfo(rawValue: info),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func write(_ images: [CGImage], _ name: String, type: String = "public.heic",
                       properties: [CFString: Any] = [:], fileProperties: [CFString: Any] = [:]) throws -> URL {
        let url = dir.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, images.count, nil) else {
            throw XCTSkip("no \(type) encoder")
        }
        if !fileProperties.isEmpty { CGImageDestinationSetProperties(destination, fileProperties as CFDictionary) }
        var props = properties
        props[kCGImageDestinationLossyCompressionQuality] = 0.9
        for image in images { CGImageDestinationAddImage(destination, image, props as CFDictionary) }
        guard CGImageDestinationFinalize(destination) else { throw XCTSkip("cannot encode \(type)") }
        return url
    }

    /// (r, g, b) in 0…255 at (x, y) of a decoded buffer, any 8-bit or 10-bit layout.
    private func rgb(_ pb: PixelBuffer, _ x: Int, _ y: Int) -> (Int, Int, Int) {
        if case .surface(let surface) = pb.storage { IOSurfaceLock(surface, .readOnly, nil) }
        defer { if case .surface(let surface) = pb.storage { IOSurfaceUnlock(surface, .readOnly, nil) } }
        let p = pb.baseAddress.advanced(by: y * pb.bytesPerRow + x * pb.layout.bytesPerPixel)
        func b(_ i: Int) -> Int { Int(p.load(fromByteOffset: i, as: UInt8.self)) }
        switch pb.layout {
        case .rgba8: return (b(0), b(1), b(2))
        case .bgra8: return (b(2), b(1), b(0))
        case .argb8: return (b(1), b(2), b(3))
        case .bgr10a2:
            let v = Int(p.load(as: UInt32.self))
            return ((v >> 20 & 0x3ff) >> 2, (v >> 10 & 0x3ff) >> 2, (v & 0x3ff) >> 2)
        case .rgba16, .rgba16f: return (-1, -1, -1)
        }
    }

    private func mean(_ pb: PixelBuffer) -> Double {
        var sum = 0
        var n = 0
        for y in stride(from: 0, to: pb.height, by: max(1, pb.height / 16)) {
            for x in stride(from: 0, to: pb.width, by: max(1, pb.width / 16)) {
                let c = rgb(pb, x, y)
                sum += c.0 + c.1 + c.2
                n += 3
            }
        }
        return Double(sum) / Double(max(n, 1))
    }

    private func assertQuadrants(_ pb: PixelBuffer, file: StaticString = #filePath, line: UInt = #line) {
        let expect: [((Double, Double), (Int, Int, Int))] = [
            ((0.25, 0.25), (255, 0, 0)), ((0.75, 0.25), (0, 255, 0)), ((0.25, 0.75), (0, 0, 255)), ((0.75, 0.75), (255, 255, 255)),
        ]
        for ((fx, fy), want) in expect {
            let got = rgb(pb, Int(Double(pb.width) * fx), Int(Double(pb.height) * fy))
            XCTAssert(abs(got.0 - want.0) < 40 && abs(got.1 - want.1) < 40 && abs(got.2 - want.2) < 40,
                      "(\(fx), \(fy)) = \(got), want \(want) [\(pb.layout)]", file: file, line: line)
        }
    }

    // MARK: Native YCbCr

    /// 8-bit HEIC / AVIF ask the surface SPI for their native YCbCr (`'420f'`) and are converted, and reduced, on the
    /// GPU (ImageIO's BGRA conversion and its reductions run on the CPU: 12 MP 32 vs 10 ms).
    func testEightBitHEIFDecodesToNativeYCbCrOnTheGPU() throws {
        guard IOSurfaceSPI.canRequestFormat else { throw XCTSkip("no surface format request") }
        for (type, ext) in [("public.heic", "heic"), ("public.avif", "avif")] {
            let url = try write([try quadrants(1600, 1200)], "eight.\(ext)", type: type)
            for (tier, target, width) in [(Tier.preview, 150, 200), (.screen, 700, 800), (.full, 0, 1600)] {
                let image = try decoder.decode(url, tier: tier, targetLongSide: target, pool: pool)
                XCTAssertEqual(image.pixels.width, width, "\(ext) \(tier): /\(1600 / width) on the GPU")
                XCTAssertEqual(image.pixels.layout, .bgra8)
                XCTAssertEqual(image.pixels.alpha, .opaque)
                if case .metal = image.pixels.storage {} else { XCTFail("\(ext) \(tier): converted into a pooled buffer") }
                assertQuadrants(image.pixels)
            }
        }
        // Alpha has no plane in YCbCr: such images keep ImageIO's BGRA surface (straight alpha).
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(try quadrants(400, 300), in: CGRect(x: 0, y: 0, width: 400, height: 300))
        context.clear(CGRect(x: 0, y: 0, width: 100, height: 100))
        let alpha = try write([try XCTUnwrap(context.makeImage())], "alpha.heic")
        let image = try decoder.decode(alpha, tier: .full, targetLongSide: 0, pool: pool)
        XCTAssertNotEqual(image.pixels.alpha, .opaque)
        if case .surface = image.pixels.storage {} else { XCTFail("an alpha HEIC keeps the BGRA surface") }
    }

    // MARK: 10-bit

    /// The surface SPI hands 10-bit HEIC / AVIF over as bi-planar YCbCr ('xf20'): converted on the GPU into 10-bit RGB,
    /// not drawn on the CPU (24 MP: 115 ms before, 8 ms + ~1 ms now).
    func testTenBitHEIFIsConvertedOnTheGPU() throws {
        guard IOSurfaceSPI.isAvailable else { throw XCTSkip("no IOSurface SPI") }
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        for type in ["public.heic", "public.avif"] {
            let url = try write([try quadrants(1024, 768, space: p3, bits: 16)], "deep.\(type == "public.heic" ? "heic" : "avif")", type: type)
            let info = try decoder.probe(url)
            XCTAssertEqual(info.colorProfileName, "Display P3")
            for (tier, target) in [(Tier.preview, 256), (.screen, 512), (.full, 0)] {
                let image = try decoder.decode(url, tier: tier, targetLongSide: target, pool: pool)
                XCTAssertEqual(image.pixels.layout, .bgr10a2, "\(type) \(tier)")
                XCTAssertEqual(image.pixels.alpha, .opaque)
                XCTAssertEqual(image.pixels.colorSpace.name, CGColorSpace.displayP3, "\(type) \(tier)")
                if case .metal = image.pixels.storage {} else { XCTFail("converted into a pooled buffer") }
                XCTAssertNotNil(image.pixels.makeTexture(device: pool.device))
                assertQuadrants(image.pixels)
            }
        }
    }

    /// PQ / HLG images (camera HIF, HDR AVIF) are shown through ImageIO's tone-mapped SDR rendition in Display P3. The
    /// default decode used to keep PQ code values in a PQ space, which the renderer showed at a sixth of the brightness.
    func testPQAndHLGShowTheirSDRRendition() throws {
        for (name, space) in [("pq", CGColorSpace.itur_2100_PQ), ("hlg", CGColorSpace.itur_2100_HLG)] {
            let url = try write([try quadrants(800, 600, space: try XCTUnwrap(CGColorSpace(name: space)), bits: 16, level: 0.7)],
                                "\(name).heic")
            let probe = try DecodeProbe(url: url)
            XCTAssertTrue(probe.hdrTransfer, name)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let sdr = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToSDR] as CFDictionary))
            let reference = try NativeImage.pixels(sdr, pool: pool, opaque: true)
            for (tier, target) in [(Tier.preview, 200), (.screen, 800), (.full, 0)] {
                let image = try decoder.decode(url, tier: tier, targetLongSide: target, pool: pool)
                XCTAssertEqual(image.pixels.colorSpace.name, CGColorSpace.displayP3, "\(name) \(tier)")
                XCTAssertFalse(image.isHDR)
                XCTAssertEqual(mean(image.pixels), mean(reference), accuracy: mean(reference) * 0.05, "\(name) \(tier)")
            }
            // The rendition's YCbCr is BT.2020 (tagged BT.601 like every surface): its colours, not only its brightness.
            let full = try decoder.decode(url, tier: .full, targetLongSide: 0, pool: pool)
            assertMatchesImageIO(full.pixels, try imageIORendition(url, space: full.pixels.colorSpace, request: kCGImageSourceDecodeToSDR),
                                 "\(name) SDR rendition")
        }
        // 8-bit images are never probed for an HDR transfer function.
        XCTAssertFalse(try DecodeProbe(url: try write([try quadrants(64, 48)], "sdr.heic")).hdrTransfer)
    }

    // MARK: YCbCr matrix

    /// (r, g, b) at (x, y) of ImageIO's own rendering of `url` (`request`: `kCGImageSourceDecodeRequest`) drawn into
    /// `space`.
    private func imageIORendition(_ url: URL, space: CGColorSpace, request: CFString? = nil) throws -> (Int, Int) -> (Int, Int, Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let options = request.map { [kCGImageSourceDecodeRequest: $0] as CFDictionary }
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, options))
        let (w, h) = (image.width, image.height)
        let context = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let pixels = Array(UnsafeBufferPointer(start: data, count: w * h * 4))
        return { x, y in let o = (y * w + x) * 4; return (Int(pixels[o]), Int(pixels[o + 1]), Int(pixels[o + 2])) }
    }

    private func assertMatchesImageIO(_ pb: PixelBuffer, _ reference: (Int, Int) -> (Int, Int, Int), tolerance: Int = 3,
                                      _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        for (fx, fy) in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)] {
            let x = Int(Double(pb.width) * fx), y = Int(Double(pb.height) * fy)
            let got = rgb(pb, x, y), want = reference(x, y)
            XCTAssert(abs(got.0 - want.0) <= tolerance && abs(got.1 - want.1) <= tolerance && abs(got.2 - want.2) <= tolerance,
                      "\(label) (\(fx), \(fy)) = \(got), ImageIO \(want)", file: file, line: line)
        }
    }

    /// Rewrite `matrix_coefficients` of the file's first `colr` `nclx` box; false when it has none.
    private func relabelMatrix(_ url: URL, to matrix: Int) throws -> Bool {
        var bytes = [UInt8](try Data(contentsOf: url))
        guard let colr = Self.box(bytes, "colr"), colr + 11 <= bytes.count, Array(bytes[colr..<(colr + 4)]) == Array("nclx".utf8) else {
            return false
        }
        bytes[colr + 8] = UInt8(matrix >> 8)
        bytes[colr + 9] = UInt8(matrix & 0xff)
        try Data(bytes).write(to: url)
        return true
    }

    /// ImageIO's surfaces keep the file's YCbCr matrix but are all tagged BT.601, so the converter reads the matrix
    /// from the file's `nclx` (ImageIO follows that label too): files relabelled BT.709 / BT.2020 decode to ImageIO's
    /// own colours. Saturated quadrants: converted as BT.601 a BT.709 red reads (255, 0, 0) where ImageIO shows
    /// (255, 25, 0). A matrix the converter lacks (YCgCo) is left to ImageIO's BGRA conversion.
    func testYCbCrMatrixComesFromTheFile() throws {
        guard IOSurfaceSPI.canRequestFormat else { throw XCTSkip("no surface format request") }
        XCTAssertEqual(try DecodeProbe(url: try write([try quadrants(64, 48)], "plain.heic")).nclxMatrix, 6, "ImageIO writes BT.601")
        for (matrix, name) in [(1, "bt709"), (9, "bt2020"), (8, "ycgco")] {
            let url = try write([try quadrants(512, 384)], "\(name).heic")
            guard try relabelMatrix(url, to: matrix) else { throw XCTSkip("ImageIO wrote no nclx colour box") }
            XCTAssertEqual(try DecodeProbe(url: url).nclxMatrix, matrix)
            let image = try decoder.decode(url, tier: .full, targetLongSide: 0, pool: pool)
            if YCbCrConverter.matrix(coefficients: matrix) == nil {
                if case .surface = image.pixels.storage {} else { XCTFail("\(name): ImageIO's BGRA surface") }
            } else {
                if case .metal = image.pixels.storage {} else { XCTFail("\(name): converted on the GPU") }
            }
            assertMatchesImageIO(image.pixels, try imageIORendition(url, space: image.pixels.colorSpace), name)
        }
    }

    /// The matrix is read from the `meta` box without trusting its sizes: truncated and corrupted headers give nil.
    func testNCLXParserSurvivesMalformedHeaders() throws {
        let url = try write([try quadrants(64, 48)], "parse.heic")
        let bytes = [UInt8](try Data(contentsOf: url))
        XCTAssertEqual(bytes.withUnsafeBytes { HEIFColour.matrixCoefficients(file: $0) }, 6)
        XCTAssertEqual(HEIFColour.matrixCoefficients(url: url), 6)
        let head = Array(bytes.prefix(1024))
        var generator = SystemRandomNumberGenerator()
        for length in stride(from: 0, through: head.count, by: 3) {
            _ = Array(head.prefix(length)).withUnsafeBytes { HEIFColour.matrixCoefficients(file: $0) }
            var flipped = head
            for _ in 0..<4 { flipped[Int.random(in: 0..<flipped.count, using: &generator)] = .random(in: 0...255, using: &generator) }
            _ = flipped.withUnsafeBytes { HEIFColour.matrixCoefficients(file: $0) }
        }
        let truncated = dir.appendingPathComponent("truncated.heic")
        try Data(head.prefix(200)).write(to: truncated)
        XCTAssertNil(HEIFColour.matrixCoefficients(url: truncated))
        XCTAssertNil(HEIFColour.matrixCoefficients(url: dir.appendingPathComponent("missing.heic")))
        // A `meta` larger than the first read (a 20 KB `free` box appended to it) is read in full.
        let ftyp = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        let metaSize = Int(bytes[ftyp]) << 24 | Int(bytes[ftyp + 1]) << 16 | Int(bytes[ftyp + 2]) << 8 | Int(bytes[ftyp + 3])
        guard Array(bytes[(ftyp + 4)..<(ftyp + 8)]) == Array("meta".utf8) else { throw XCTSkip("meta does not follow ftyp") }
        let padding = 20 << 10, grown = metaSize + padding
        var large = Array(bytes[0..<ftyp]) + [UInt8(grown >> 24 & 0xff), UInt8(grown >> 16 & 0xff), UInt8(grown >> 8 & 0xff), UInt8(grown & 0xff)]
        large += bytes[(ftyp + 4)..<(ftyp + metaSize)]
        large += [UInt8(padding >> 24 & 0xff), UInt8(padding >> 16 & 0xff), UInt8(padding >> 8 & 0xff), UInt8(padding & 0xff)]
            + Array("free".utf8) + [UInt8](repeating: 0, count: padding - 8)
        large += bytes[(ftyp + metaSize)...]
        let largeURL = dir.appendingPathComponent("large-meta.heic")
        try Data(large).write(to: largeURL)
        XCTAssertEqual(HEIFColour.matrixCoefficients(url: largeURL), 6)
    }

    // MARK: Containers

    /// ImageIO's writer always makes the first image primary; patch `pitm` to the third. The decoder follows the
    /// primary index in every tier.
    func testMultiImageFileDecodesItsPrimary() throws {
        let url = try write([try quadrants(640, 480), try quadrants(320, 240), try quadrants(900, 300)], "multi.heic")
        var bytes = [UInt8](try Data(contentsOf: url))
        let items = Self.itemIDs(bytes, type: "hvc1")
        guard items.count == 3, let pitm = Self.box(bytes, "pitm") else { throw XCTSkip("unexpected HEIF layout") }
        bytes[pitm + 4] = UInt8(items[2] >> 8)
        bytes[pitm + 5] = UInt8(items[2] & 0xff)
        try Data(bytes).write(to: url)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        guard CGImageSourceGetPrimaryImageIndex(source) == 2 else { throw XCTSkip("ImageIO ignores the patched pitm") }
        let info = try decoder.probe(url)
        XCTAssertEqual(info.pixelWidth, 900)
        XCTAssertEqual(info.frameCount, 3)
        XCTAssertFalse(info.isAnimated, "a HEIC collection is a still")
        for (tier, target) in [(Tier.preview, 128), (.screen, 450), (.full, 0)] {
            let image = try decoder.decode(url, tier: tier, targetLongSide: target, pool: pool)
            XCTAssertEqual(Double(image.pixels.width) / Double(image.pixels.height), 3, accuracy: 0.05, "\(tier)")
            XCTAssertEqual(image.fullWidth, 900)
        }
    }

    func testSequencesAnimateAndKeepTheirTiming() throws {
        let frames = try (0..<3).map { _ in try quadrants(320, 240) }
        let url = try write(frames, "seq.heics", type: "public.heics",
                            properties: [kCGImagePropertyHEICSDictionary: [kCGImagePropertyHEICSDelayTime: 0.25]])
        let info = try decoder.probe(url)
        XCTAssertEqual(info.typeIdentifier, "public.heics")
        XCTAssertTrue(info.isAnimated)
        let animation = try AnimationDecoder(url: url, info: info)
        XCTAssertEqual(animation.timing.delays, [0.25, 0.25, 0.25])
        assertQuadrants(try animation.frame(2, pool: pool))
        // The same sequence named .heic is still a sequence (ImageIO reads the brand).
        let renamed = dir.appendingPathComponent("seq.heic")
        try FileManager.default.copyItem(at: url, to: renamed)
        XCTAssertTrue(try decoder.probe(renamed).isAnimated)
    }

    func testDepthAndMatteAuxiliariesLeaveThePrimaryAlone() throws {
        let url = dir.appendingPathComponent("portrait.heic")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.heic" as CFString, 1, nil) else {
            throw XCTSkip("no HEIC encoder")
        }
        CGImageDestinationAddImage(destination, try quadrants(800, 600), nil)
        let (w, h) = (160, 120)
        let depth = Data(count: w * h * 2), matte = Data(count: w * h)
        CGImageDestinationAddAuxiliaryDataInfo(destination, kCGImageAuxiliaryDataTypeDisparity, [
            kCGImageAuxiliaryDataInfoData: depth,
            kCGImageAuxiliaryDataInfoDataDescription: [kCGImagePropertyWidth: w, kCGImagePropertyHeight: h,
                                                       kCGImagePropertyBytesPerRow: w * 2,
                                                       kCGImagePropertyPixelFormat: kCVPixelFormatType_DisparityFloat16],
        ] as CFDictionary)
        CGImageDestinationAddAuxiliaryDataInfo(destination, kCGImageAuxiliaryDataTypePortraitEffectsMatte, [
            kCGImageAuxiliaryDataInfoData: matte,
            kCGImageAuxiliaryDataInfoDataDescription: [kCGImagePropertyWidth: w, kCGImagePropertyHeight: h,
                                                       kCGImagePropertyBytesPerRow: w,
                                                       kCGImagePropertyPixelFormat: kCVPixelFormatType_OneComponent8],
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw XCTSkip("cannot encode auxiliaries") }
        let info = try decoder.probe(url)
        XCTAssertEqual(info.pixelWidth, 800)
        XCTAssertFalse(info.isAnimated)
        for (tier, target) in [(Tier.preview, 200), (.screen, 800), (.full, 0)] {
            let image = try decoder.decode(url, tier: tier, targetLongSide: target, pool: pool)
            XCTAssertEqual(image.fullWidth, 800, "\(tier)")
            assertQuadrants(image.pixels)
        }
    }

    /// `.HEIC`, `.heif` and `.hif` (Canon, Fujifilm) are listed; a HEIC named `.jpg` and a JPEG named `.heic` decode by
    /// their content, orientation included.
    func testExtensionsAndLyingNames() throws {
        let heic = try write([try quadrants(800, 600)], "src.heic", properties: [kCGImagePropertyOrientation: 6])
        let jpeg = try write([try quadrants(800, 600)], "src.jpg", type: "public.jpeg", properties: [kCGImagePropertyOrientation: 6])
        for (source, name, type) in [(heic, "IMG.HEIC", "public.heic"), (heic, "camera.hif", "public.heic"),
                                     // A compatible name hints the type: HEIC content named .heif reads as HEIF.
                                     (heic, "a.heif", "public.heif"), (heic, "lie.jpg", "public.heic"), (jpeg, "lie.heic", "public.jpeg")] {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.copyItem(at: source, to: url)
            XCTAssertTrue(FolderScanner.isSupported(url), name)
            let info = try decoder.probe(url)
            XCTAssertEqual(info.typeIdentifier, type, name)
            XCTAssertEqual(info.orientation, .right, name)
            let image = try decoder.decode(url, tier: .full, targetLongSide: 0, pool: pool)
            XCTAssertEqual(image.fullWidth, 600, name)
            XCTAssertEqual(image.orientation, .right, name)
            assertQuadrants(image.pixels)
        }
        XCTAssertTrue(FolderScanner.isSupported(dir.appendingPathComponent("x.avifs")))
    }

    func testWarmUpImageDecodes() throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(Data(HEVCWarmUp.tinyHEIC) as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.heic")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary))
        XCTAssertEqual(image.width, 16)
        HEVCWarmUp.run()
    }

    // MARK: ISO-BMFF helpers

    /// Offset of the payload (after the full-box header's size and type) of the first `type` box inside `meta`.
    private static func box(_ d: [UInt8], _ type: String) -> Int? {
        let t = Array(type.utf8)
        var i = 0
        while i + 8 <= d.count {
            if Array(d[(i + 4)..<(i + 8)]) == t { return i + 8 }
            i += 1
        }
        return nil
    }

    /// Item IDs of `infe` entries (version 2) of `type`, in file order.
    private static func itemIDs(_ d: [UInt8], type: String) -> [Int] {
        let infe = Array("infe".utf8), t = Array(type.utf8)
        var ids: [Int] = []
        var i = 0
        while i + 20 <= d.count {
            if Array(d[(i + 4)..<(i + 8)]) == infe, d[i + 8] == 2, Array(d[(i + 16)..<(i + 20)]) == t {
                ids.append(Int(d[i + 12]) << 8 | Int(d[i + 13]))
            }
            i += 1
        }
        return ids
    }
}
