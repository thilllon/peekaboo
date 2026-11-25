import CoreGraphics
import ImageIO
import IOSurface
import Metal
import UniformTypeIdentifiers
import XCTest
@testable import PeekabooCore

/// Synthetic images encoded in the test (baseline / progressive / oriented JPEG, alpha PNG, HEIC),
/// decoded at every tier: layout, alpha, orientation, dimensions and pixel values.
final class DecodeTests: XCTestCase {
    private var dir: URL!
    private var pool: PixelBufferPool!
    private let decoder = ImageIODecoder()

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        pool = PixelBufferPool(device: device)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("peekaboo-decode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: Fixtures

    /// Quadrants (in memory order, row 0 = top): red | green / blue | white, with `alpha` everywhere.
    private func quadrants(_ width: Int, _ height: Int, alpha: UInt8 = 255) throws -> CGImage {
        let info = alpha == 255 ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.last.rawValue
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let rgb: (UInt8, UInt8, UInt8)
                switch (x < width / 2, y < height / 2) {
                case (true, true): rgb = (255, 0, 0)
                case (false, true): rgb = (0, 255, 0)
                case (true, false): rgb = (0, 0, 255)
                case (false, false): rgb = (255, 255, 255)
                }
                let i = (y * width + x) * 4
                bytes[i] = rgb.0; bytes[i + 1] = rgb.1; bytes[i + 2] = rgb.2; bytes[i + 3] = alpha
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                     bytesPerRow: width * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: info),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func write(_ image: CGImage, _ name: String, type: UTType, properties: [CFString: Any] = [:]) throws -> URL {
        let url = dir.appendingPathComponent(name)
        // HEIC needs the hardware HEVC encoder, which CI virtual machines may lack.
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw XCTSkip("no \(type.identifier) encoder")
        }
        var props = properties
        if type == .jpeg || type == .heic { props[kCGImageDestinationLossyCompressionQuality] = 0.95 }
        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw XCTSkip("cannot encode \(type.identifier)") }
        return url
    }

    /// (r, g, b, a) of pixel (x, y) in memory order, whatever the layout.
    private func pixel(_ pb: PixelBuffer, _ x: Int, _ y: Int) -> (Int, Int, Int, Int) {
        if case .surface(let surface) = pb.storage { IOSurfaceLock(surface, .readOnly, nil) }
        defer { if case .surface(let surface) = pb.storage { IOSurfaceUnlock(surface, .readOnly, nil) } }
        let p = pb.baseAddress.advanced(by: y * pb.bytesPerRow + x * pb.layout.bytesPerPixel)
        func b(_ i: Int) -> Int { Int(p.load(fromByteOffset: i, as: UInt8.self)) }
        func h(_ i: Int) -> Int { Int(p.load(fromByteOffset: i * 2, as: UInt16.self)) >> 8 }
        switch pb.layout {
        case .rgba8: return (b(0), b(1), b(2), b(3))
        case .bgra8: return (b(2), b(1), b(0), b(3))
        case .argb8: return (b(1), b(2), b(3), b(0))
        case .rgba16: return (h(0), h(1), h(2), h(3))
        case .rgba16f:
            func f(_ i: Int) -> Int { Int(Float(Float16(bitPattern: p.load(fromByteOffset: i * 2, as: UInt16.self))) * 255) }
            return (f(0), f(1), f(2), f(3))
        case .bgr10a2:
            let v = Int(p.load(as: UInt32.self))
            return ((v >> 20 & 0x3ff) >> 2, (v >> 10 & 0x3ff) >> 2, (v & 0x3ff) >> 2, 255)
        }
    }

    /// Check the four quadrant colours of a decode in its stored (un-rotated) orientation.
    private func assertQuadrants(_ pb: PixelBuffer, file: StaticString = #filePath, line: UInt = #line) {
        let expect: [((Int, Int), (Int, Int, Int))] = [
            ((pb.width / 4, pb.height / 4), (255, 0, 0)), ((pb.width * 3 / 4, pb.height / 4), (0, 255, 0)),
            ((pb.width / 4, pb.height * 3 / 4), (0, 0, 255)), ((pb.width * 3 / 4, pb.height * 3 / 4), (255, 255, 255)),
        ]
        for ((x, y), rgb) in expect {
            let got = pixel(pb, x, y)
            XCTAssert(abs(got.0 - rgb.0) < 24 && abs(got.1 - rgb.1) < 24 && abs(got.2 - rgb.2) < 24,
                      "pixel (\(x),\(y)) = \(got), want \(rgb) [\(pb.layout)]", file: file, line: line)
        }
    }

    // MARK: JPEG

    func testBaselineJPEGEveryTier() throws {
        let url = try write(try quadrants(1600, 1200), "baseline.jpg", type: .jpeg)
        let info = try decoder.probe(url)
        XCTAssertEqual(info.pixelWidth, 1600)
        XCTAssertEqual(info.pixelHeight, 1200)
        XCTAssertEqual(info.orientation, .up)
        XCTAssertFalse(info.hasAlpha)
        XCTAssertFalse(info.hasGainMap)
        XCTAssertEqual(info.frameCount, 1)
        XCTAssertTrue(info.exif["format"]?.hasPrefix("JPEG baseline 4:") ?? false, "\(info.exif)")
        for tier in Tier.allCases { XCTAssertEqual(decoder.lane(for: url, info: info, tier: tier), .hardware) }
        XCTAssertEqual(decoder.lane(for: url, info: nil, tier: .screen), .hardware)

        let preview = try decoder.decode(url, tier: .preview, targetLongSide: 256, pool: pool)
        XCTAssertEqual(preview.pixels.width, 400, "smallest power-of-two subsample covering 256 px")
        XCTAssertEqual(preview.pixels.height, 300)
        let screen = try decoder.decode(url, tier: .screen, targetLongSide: 800, pool: pool)
        XCTAssertEqual(screen.pixels.width, 800)
        XCTAssertEqual(screen.pixels.height, 600)
        let full = try decoder.decode(url, tier: .full, targetLongSide: 0, pool: pool)
        XCTAssertEqual(full.pixels.width, 1600)
        XCTAssertEqual(full.pixels.height, 1200)
        for image in [preview, screen, full] {
            XCTAssertEqual(image.fullWidth, 1600)
            XCTAssertEqual(image.fullHeight, 1200)
            XCTAssertEqual(image.orientation, .up)
            XCTAssertEqual(image.pixels.alpha, .opaque)
            XCTAssertFalse(image.isHDR)
            XCTAssertGreaterThan(image.decodeNanos, 0)
            assertQuadrants(image.pixels)
        }
        if IOSurfaceSPI.isAvailable, case .surface = full.pixels.storage {
            XCTAssertEqual(full.pixels.layout, .bgra8, "IOSurface SPI hands over BGRA")
        }
    }

    func testProgressiveJPEGGoesToTurboAndDCOnlyPreview() throws {
        let props: [CFString: Any] = [kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: true]]
        let url = try write(try quadrants(1600, 1200), "progressive.jpg", type: .jpeg, properties: props)
        let info = try decoder.probe(url)
        XCTAssertTrue(info.exif["format"]?.hasPrefix("JPEG progressive") ?? false, "\(info.exif)")
        XCTAssertEqual(decoder.lane(for: url, info: info, tier: .preview), .general)
        XCTAssertEqual(decoder.lane(for: url, info: info, tier: .screen), .cpu)
        XCTAssertEqual(decoder.lane(for: url, info: info, tier: .full), .cpu)

        let preview = try decoder.decode(url, tier: .preview, targetLongSide: 100, pool: pool)
        XCTAssertEqual(preview.pixels.width, 200, "/8 DC-only decode")
        let screen = try decoder.decode(url, tier: .screen, targetLongSide: 700, pool: pool)
        XCTAssertEqual(screen.pixels.width, 800, "libjpeg-turbo 1/2 covers 700 px")
        XCTAssertEqual(screen.pixels.height, 600)
        XCTAssertEqual(screen.pixels.layout, .bgra8)
        let full = try decoder.decode(url, tier: .full, targetLongSide: 0, pool: pool)
        XCTAssertEqual(full.pixels.width, 1600)
        XCTAssertEqual(full.pixels.layout, .bgra8)
        XCTAssertEqual(full.pixels.alpha, .opaque)
        if case .metal = full.pixels.storage {} else { XCTFail("libjpeg-turbo decodes into a pooled MTLBuffer") }
        for image in [preview, screen, full] {
            XCTAssertEqual(image.fullWidth, 1600)
            XCTAssertEqual(image.orientation, .up)
            assertQuadrants(image.pixels)
        }
    }

    func testEXIFOrientationIsLeftToTheRenderer() throws {
        let url = try write(try quadrants(1600, 1200), "oriented.jpg", type: .jpeg,
                            properties: [kCGImagePropertyOrientation: 6])
        let info = try decoder.probe(url)
        XCTAssertEqual(info.orientation, .right)
        XCTAssertEqual(info.orientedWidth, 1200)
        XCTAssertEqual(info.orientedHeight, 1600)
        for (tier, target) in [(Tier.preview, 256), (.screen, 800), (.full, 0)] {
            let image = try decoder.decode(url, tier: tier, targetLongSide: target, pool: pool)
            XCTAssertEqual(image.fullWidth, 1200, "\(tier): full size is oriented")
            XCTAssertEqual(image.fullHeight, 1600)
            if image.orientation == .up {
                // Only an embedded thumbnail (ImageIO applies the transform) may arrive upright.
                XCTAssertLessThan(image.pixels.width, image.pixels.height)
            } else {
                XCTAssertEqual(image.orientation, .right, "\(tier)")
                XCTAssertGreaterThan(image.pixels.width, image.pixels.height, "stored, un-rotated pixels")
                assertQuadrants(image.pixels)
            }
        }
    }

    func testEXIFSummary() throws {
        let props: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: "Canon EOS R5"],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifFNumber: 2.8, kCGImagePropertyExifExposureTime: 0.004,
                kCGImagePropertyExifISOSpeedRatings: [400], kCGImagePropertyExifFocalLength: 35.0,
                kCGImagePropertyExifLensModel: "RF35mm F1.8 MACRO IS STM",
                kCGImagePropertyExifDateTimeOriginal: "2026:05:01 14:03:22",
            ],
        ]
        let url = try write(try quadrants(64, 48), "exif.jpg", type: .jpeg, properties: props)
        let exif = try decoder.probe(url).exif
        XCTAssertEqual(exif["camera"], "Canon EOS R5")
        XCTAssertEqual(exif["lens"], "RF35mm F1.8 MACRO IS STM")
        XCTAssertEqual(exif["focal"], "35 mm")
        XCTAssertEqual(exif["aperture"], "f/2.8")
        XCTAssertEqual(exif["shutter"], "1/250 s")
        XCTAssertEqual(exif["iso"], "ISO 400")
        XCTAssertEqual(exif["date"], "2026-05-01 14:03")
        XCTAssertNotNil(exif["format"])
    }

    /// `jpeg` with an XMP packet (APP1 "http://ns.adobe.com/xap/1.0/") after SOI; `properties` are attributes
    /// of its rdf:Description, e.g. `exif:FNumber="28/10"`. ImageIO copies XMP `exif:` values into the EXIF
    /// dictionary, as doubles, whatever their size.
    private func withXMP(_ jpeg: Data, _ properties: String) -> Data {
        let packet = "<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?><x:xmpmeta xmlns:x=\"adobe:ns:meta/\">"
            + "<rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description rdf:about=\"\" "
            + "xmlns:exif=\"http://ns.adobe.com/exif/1.0/\" \(properties)/></rdf:RDF></x:xmpmeta><?xpacket end=\"w\"?>"
        let payload = Array("http://ns.adobe.com/xap/1.0/\0".utf8) + Array(packet.utf8)
        let length = payload.count + 2
        var bytes = [UInt8](jpeg)
        bytes.insert(contentsOf: [0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)] + payload, at: 2)
        return Data(bytes)
    }

    /// XMP decimals reach the summary as doubles (ImageIO saturates huge integers at 2^63, one past Int.max):
    /// `Int(_:)` on them trapped inside `probe`, which runs for every file the pipeline touches, so one such
    /// file crashed the app as soon as its folder was opened. Implausible values are now left out.
    func testEXIFSummaryIgnoresImplausibleXMPValues() throws {
        let plain = try Data(contentsOf: try write(try quadrants(64, 48), "plain.jpg", type: .jpeg))
        let sane = dir.appendingPathComponent("sane.jpg")
        try withXMP(plain, #"exif:FNumber="28/10" exif:FocalLength="50/1" exif:ExposureTime="1/125""#).write(to: sane)
        let saneExif = try decoder.probe(sane).exif
        XCTAssertEqual(saneExif["aperture"], "f/2.8", "XMP exif: values reach the summary")
        XCTAssertEqual(saneExif["focal"], "50 mm")
        XCTAssertEqual(saneExif["shutter"], "1/125 s")

        let hostile = [
            ("aperture", #"exif:FNumber="99999999999999999999999""#),
            ("aperture", #"exif:FNumber="18446744073709551615/1""#),
            ("focal", #"exif:FocalLength="10000000000000000000""#),
            ("shutter", #"exif:ExposureTime="100000000000000000000""#),
            ("shutter", #"exif:ExposureTime="1/100000000000000000000""#),
            ("iso", #"exif:ISOSpeedRatings="99999999999999999999""#),  // capped at Int32.max by ImageIO
        ]
        for (i, (key, properties)) in hostile.enumerated() {
            let url = dir.appendingPathComponent("hostile\(i).jpg")
            try withXMP(plain, properties).write(to: url)
            let info = try decoder.probe(url)
            XCTAssertEqual(info.pixelWidth, 64, properties)
            XCTAssertNil(info.exif[key], "\(properties): \(info.exif[key] ?? "")")
            XCTAssertNotNil(info.exif["format"], properties)
        }
    }

    /// `trim` and `shutter` are total: any double formats without trapping.
    func testFormattingHandlesExtremeValues() {
        for value in [0x1p63, -0x1p63, 1e300, -1e300, .infinity, -.infinity, .nan, 0x1p-63, .leastNonzeroMagnitude, 0, -0.0] {
            XCTAssertFalse(DecodeProbe.trim(value).isEmpty, "\(value)")
            XCTAssertFalse(DecodeProbe.shutter(value).isEmpty, "\(value)")
        }
        XCTAssertEqual(DecodeProbe.trim(9e18), "9000000000000000000", "integers up to Int.max print exactly")
        XCTAssertEqual(DecodeProbe.shutter(1e-9), "1/1000000000 s")
    }

    func testFormatting() {
        XCTAssertEqual(DecodeProbe.shutter(1.0 / 250), "1/250 s")
        XCTAssertEqual(DecodeProbe.shutter(0.5), "1/2 s")
        XCTAssertEqual(DecodeProbe.shutter(2), "2 s")
        XCTAssertEqual(DecodeProbe.shutter(1.3), "1.3 s")
        XCTAssertEqual(DecodeProbe.shutter(0.37), "0.4 s")
        XCTAssertEqual(DecodeProbe.trim(8.0), "8")
        XCTAssertEqual(DecodeProbe.trim(4.5), "4.5")
        XCTAssertEqual(DecodeProbe.trim(35), "35")
        XCTAssertEqual(DecodeProbe.trim(2.8), "2.8")
        XCTAssertEqual(DecodeProbe.formatDate("2026:05:01 14:03:22"), "2026-05-01 14:03")
        XCTAssertNil(DecodeProbe.formatDate("0000:00:00 00:00:00"))
        XCTAssertEqual(ImageIODecoder.coveringSubsample(long: 5947, target: 3456), 1)
        XCTAssertEqual(ImageIODecoder.coveringSubsample(long: 8688, target: 3456), 2)
        XCTAssertEqual(ImageIODecoder.coveringSubsample(long: 22705, target: 3456), 4)
        XCTAssertEqual(ImageIODecoder.coveringSubsample(long: 22705, target: 3456, maxFactor: 2), 2)
        XCTAssertEqual(ImageIODecoder.coveringSubsample(long: 4000, target: 0), 1)
    }

    // MARK: PNG / HEIC

    func testAlphaPNG() throws {
        let url = try write(try quadrants(300, 200, alpha: 128), "alpha.png", type: .png)
        let info = try decoder.probe(url)
        XCTAssertTrue(info.hasAlpha)
        XCTAssertEqual(info.exif["format"], "PNG")
        XCTAssertEqual(decoder.lane(for: url, info: info, tier: .full), .general)
        for (tier, target) in [(Tier.preview, 150), (.screen, 300), (.full, 0)] {
            let image = try decoder.decode(url, tier: tier, targetLongSide: target, pool: pool)
            XCTAssertNotEqual(image.pixels.alpha, .opaque, "\(tier)")
            XCTAssertGreaterThanOrEqual(max(image.pixels.width, image.pixels.height), target, "\(tier)")
            let (r, g, b, a) = pixel(image.pixels, image.pixels.width / 4, image.pixels.height / 4)
            XCTAssertEqual(Double(a), 128, accuracy: 3, "\(tier) alpha")
            let expectR = image.pixels.alpha == .premultiplied ? 128 : 255
            XCTAssertEqual(Double(r), Double(expectR), accuracy: 6, "\(tier) red (\(image.pixels.alpha))")
            XCTAssertLessThan(g + b, 12)
        }
    }

    func testHEIC() throws {
        let url = try write(try quadrants(1024, 768), "image.heic", type: .heic)
        let info = try decoder.probe(url)
        XCTAssertEqual(info.typeIdentifier, "public.heic")
        XCTAssertEqual(info.exif["format"], "HEIC")
        XCTAssertEqual(decoder.lane(for: url, info: info, tier: .screen), .hardware)
        let screen = try decoder.decode(url, tier: .screen, targetLongSide: 512, pool: pool)
        XCTAssertEqual(screen.pixels.width, 512)
        XCTAssertEqual(screen.pixels.height, 384)
        let preview = try decoder.decode(url, tier: .preview, targetLongSide: 64, pool: pool)
        XCTAssertGreaterThanOrEqual(preview.pixels.width, 64)
        XCTAssertLessThanOrEqual(preview.pixels.width, 256, "a reduced decode (or a thumbnail item)")
        let full = try decoder.decode(url, tier: .full, targetLongSide: 0, pool: pool)
        XCTAssertEqual(full.pixels.width, 1024)
        for image in [preview, screen, full] {
            XCTAssertEqual(image.fullWidth, 1024)
            XCTAssertEqual(image.fullHeight, 768)
            assertQuadrants(image.pixels)
        }
    }

    func testOrientedHEICKeepsStoredPixels() throws {
        let url = try write(try quadrants(800, 600), "oriented.heic", type: .heic, properties: [kCGImagePropertyOrientation: 6])
        let info = try decoder.probe(url)
        XCTAssertEqual(info.orientation, .right)
        let full = try decoder.decode(url, tier: .full, targetLongSide: 0, pool: pool)
        XCTAssertEqual(full.fullWidth, 600)
        XCTAssertEqual(full.fullHeight, 800)
        XCTAssertEqual(full.orientation, .right)
        XCTAssertEqual(full.pixels.width, 800)
        assertQuadrants(full.pixels)
    }

    // MARK: Building blocks

    func testJPEGScanAndTurboScaling() throws {
        let url = try write(try quadrants(1000, 600), "scan.jpg", type: .jpeg)
        let scan = try XCTUnwrap(JPEGScan.scan(url: url))
        XCTAssertEqual(scan.coding, .baseline)
        XCTAssertEqual(scan.width, 1000)
        XCTAssertEqual(scan.height, 600)
        XCTAssertEqual(scan.components, 3)
        XCTAssertEqual(ImageIODecoder.jpegRoute(scan), .hardware)
        let data = try Data(contentsOf: url)
        let pixels = try data.withUnsafeBytes { try TurboJPEG.decode($0, targetLongSide: 250, pool: pool) }
        XCTAssertEqual(pixels.width, 250, "1/4 covers 250 px")
        XCTAssertEqual(pixels.height, 150)
        XCTAssertEqual(pixels.layout, .bgra8)
        XCTAssertEqual(pixels.colorSpace.name, CGColorSpace.sRGB)
        assertQuadrants(pixels)
        XCTAssertEqual(TurboJPEG.coveringScale(width: 11800, height: 8600, target: 3456).denom, 2)
        XCTAssertEqual(TurboJPEG.coveringScale(width: 5947, height: 3964, target: 3456).denom, 1)
        XCTAssertNil(JPEGScan.scan(bytes: UnsafeRawBufferPointer(start: nil, count: 0)))
    }

    func testConcurrentDecodes() throws {
        let jpeg = try write(try quadrants(1200, 900), "c.jpg", type: .jpeg)
        let props: [CFString: Any] = [kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: true]]
        let progressive = try write(try quadrants(1200, 900), "cp.jpg", type: .jpeg, properties: props)
        let png = try write(try quadrants(600, 400, alpha: 200), "c.png", type: .png)
        let files = [jpeg, progressive, png]
        let lock = NSLock()
        var failures = 0
        DispatchQueue.concurrentPerform(iterations: 24) { i in
            let tier = Tier.allCases[i % 3]
            do {
                let image = try decoder.decode(files[(i / 3) % files.count], tier: tier, targetLongSide: 300, pool: pool)
                if image.pixels.width <= 0 { throw DecodeError.outOfMemory }
            } catch {
                lock.lock(); failures += 1; lock.unlock()
            }
        }
        XCTAssertEqual(failures, 0)
    }

    /// Every decode path must hand the renderer a buffer Metal can wrap without copying, including odd widths
    /// (IOSurface rows are only 16-byte aligned).
    func testDecodedBuffersWrapAsTextures() throws {
        let device = pool.device
        let props: [CFString: Any] = [kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: true]]
        let files = [
            try write(try quadrants(1001, 601), "odd.jpg", type: .jpeg),
            try write(try quadrants(1001, 601), "oddp.jpg", type: .jpeg, properties: props),
            try write(try quadrants(333, 201, alpha: 200), "odd.png", type: .png),
            try write(try quadrants(1001, 601), "odd.heic", type: .heic),
        ]
        for url in files {
            for (tier, target) in [(Tier.preview, 128), (.screen, 400), (.full, 0)] {
                let image = try decoder.decode(url, tier: tier, targetLongSide: target, pool: pool)
                let texture = try XCTUnwrap(image.pixels.makeTexture(device: device), "\(url.lastPathComponent) \(tier)")
                XCTAssertEqual(texture.width, image.pixels.width)
                var bytes = [UInt8](repeating: 0, count: 4 * image.pixels.layout.bytesPerPixel / 4)
                let x = image.pixels.width / 4, y = image.pixels.height / 4
                texture.getBytes(&bytes, bytesPerRow: image.pixels.layout.bytesPerPixel,
                                 from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
                let direct = pixel(image.pixels, x, y)
                if image.pixels.layout == .bgra8 {
                    XCTAssertEqual(Int(bytes[2]), direct.0, "\(url.lastPathComponent) \(tier): texture aliases the pixels")
                } else if image.pixels.layout == .rgba8 {
                    XCTAssertEqual(Int(bytes[0]), direct.0, "\(url.lastPathComponent) \(tier): texture aliases the pixels")
                }
            }
        }
    }

    /// Gray and CMYK JPEG (ImageIO route), 16-bit PNG, GIF and TIFF decode at every tier with a usable layout.
    func testUnusualFormats() throws {
        let rgb = try quadrants(640, 480)
        func redraw(_ space: CGColorSpace, bits: Int, info: UInt32) throws -> CGImage {
            let ctx = try XCTUnwrap(CGContext(data: nil, width: 640, height: 480, bitsPerComponent: bits, bytesPerRow: 0,
                                              space: space, bitmapInfo: info))
            ctx.draw(rgb, in: CGRect(x: 0, y: 0, width: 640, height: 480))
            return try XCTUnwrap(ctx.makeImage())
        }
        let gray = try redraw(CGColorSpaceCreateDeviceGray(), bits: 8, info: CGImageAlphaInfo.none.rawValue)
        let cmyk = try redraw(CGColorSpaceCreateDeviceCMYK(), bits: 8, info: CGImageAlphaInfo.none.rawValue)
        let deep = try redraw(try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3)), bits: 16,
                              info: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        let files = [
            try write(gray, "gray.jpg", type: .jpeg),
            try write(cmyk, "cmyk.jpg", type: .jpeg),
            try write(deep, "deep.png", type: .png),
            try write(rgb, "image.gif", type: .gif),
            try write(rgb, "image.tiff", type: .tiff),
        ]
        for url in files {
            let info = try decoder.probe(url)
            XCTAssertEqual(info.pixelWidth, 640, url.lastPathComponent)
            for (tier, target) in [(Tier.preview, 160), (.screen, 320), (.full, 0)] {
                let image = try decoder.decode(url, tier: tier, targetLongSide: target, pool: pool)
                let p = image.pixels
                XCTAssertEqual(Double(p.width) / Double(p.height), 640.0 / 480.0, accuracy: 0.02, "\(url.lastPathComponent) \(tier)")
                XCTAssertGreaterThanOrEqual(p.width, tier == .full ? 640 : target, "\(url.lastPathComponent) \(tier)")
                XCTAssertEqual(p.colorSpace.model, .rgb, "\(url.lastPathComponent) \(tier): the renderer samples RGB only")
                XCTAssertNotNil(p.makeTexture(device: pool.device))
                if url.pathExtension == "gif" || url.pathExtension == "tiff" { assertQuadrants(p) }
                if url.lastPathComponent.hasPrefix("cmyk") || url.lastPathComponent.hasPrefix("deep") {
                    // Gamut mapping (CMYK) and P3 encoding change the values; channel order must still hold.
                    let red = pixel(p, p.width / 4, p.height / 4), green = pixel(p, p.width * 3 / 4, p.height / 4)
                    XCTAssert(red.0 > red.1 + 100 && red.0 > red.2 + 100, "\(url.lastPathComponent) \(tier) red \(red)")
                    XCTAssert(green.1 > green.0 + 40 && green.1 > green.2 + 40, "\(url.lastPathComponent) \(tier) green \(green)")
                }
            }
        }
        XCTAssertTrue(try decoder.probe(files[1]).exif["format"]?.contains("CMYK") ?? false)
        XCTAssertEqual(decoder.lane(for: files[1], info: try decoder.probe(files[1]), tier: .screen), .general)
    }

    func testProbeCacheFollowsFileVersion() throws {
        let url = try write(try quadrants(320, 240), "cached.jpg", type: .jpeg)
        let decoder = ImageIODecoder()
        XCTAssertEqual(try decoder.probe(url).pixelWidth, 320)
        XCTAssertEqual(decoder.probes.count, 1)
        _ = try decoder.decode(url, tier: .screen, targetLongSide: 100, pool: pool)
        XCTAssertEqual(decoder.probes.count, 1, "decode reuses the probe")
        // Replace the file with a different image: new size/mtime, new key.
        let replacement = try write(try quadrants(640, 200), "replacement.jpg", type: .jpeg)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)
        XCTAssertEqual(try decoder.probe(url).pixelWidth, 640)
        let image = try decoder.decode(url, tier: .full, targetLongSide: 0, pool: pool)
        XCTAssertEqual(image.pixels.width, 640)
    }

    func testUnreadableFileThrows() throws {
        let url = dir.appendingPathComponent("garbage.jpg")
        try Data("not an image".utf8).write(to: url)
        XCTAssertThrowsError(try decoder.probe(url))
        XCTAssertThrowsError(try decoder.decode(url, tier: .screen, targetLongSide: 512, pool: pool))
    }
}
