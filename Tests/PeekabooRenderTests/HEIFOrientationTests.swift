import CoreGraphics
import ImageIO
import Metal
import QuartzCore
import XCTest
@testable import PeekabooCore
@testable import PeekabooRender

/// HEIC orientation end to end: ImageIO writes `irot` / `imir` plus the EXIF tag, reports the orientation from the
/// transform properties and decodes stored pixels; embedded thumbnails arrive rotated. Every tier, rendered, must show
/// what ImageIO's oriented thumbnail shows, in all 8 orientations, with and without a thumbnail item — and when the
/// EXIF tag disagrees with `irot` (libheif writes EXIF 1), `irot` wins as in ImageIO.
final class HEIFOrientationTests: XCTestCase {
    private var dir: URL!
    private var pool: PixelBufferPool!

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        pool = PixelBufferPool(device: device)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("peekaboo-heif-o-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    /// Quadrants red | green / blue | white, row 0 on top.
    private func quadrants(_ w: Int, _ h: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let c: (UInt8, UInt8, UInt8)
                switch (x < w / 2, y < h / 2) {
                case (true, true): c = (255, 0, 0)
                case (false, true): c = (0, 255, 0)
                case (true, false): c = (0, 0, 255)
                case (false, false): c = (255, 255, 255)
                }
                let i = (y * w + x) * 4
                bytes[i] = c.0; bytes[i + 1] = c.1; bytes[i + 2] = c.2; bytes[i + 3] = 255
            }
        }
        return try XCTUnwrap(CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                     space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                     provider: try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData)), decode: nil,
                                     shouldInterpolate: false, intent: .defaultIntent))
    }

    private func classify(_ r: Double, _ g: Double, _ b: Double) -> Character {
        if r > 0.6 && g > 0.6 && b > 0.6 { return "W" }
        if r > g + 0.3 && r > b + 0.3 { return "R" }
        if g > r + 0.3 && g > b + 0.3 { return "G" }
        if b > r + 0.3 && b > g + 0.3 { return "B" }
        return "?"
    }

    private static let centres = [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)]

    /// Quadrant colours of ImageIO's oriented thumbnail, and its size.
    private func reference(_ url: URL) throws -> (String, Int, Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let thumb = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 640,
        ] as CFDictionary))
        let w = thumb.width, h = thumb.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let context = try XCTUnwrap(CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                              space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(thumb, in: CGRect(x: 0, y: 0, width: w, height: h))
        let s = String(Self.centres.map { fx, fy in
            let i = (Int(Double(h) * fy) * w + Int(Double(w) * fx)) * 4
            return classify(Double(px[i]) / 255, Double(px[i + 1]) / 255, Double(px[i + 2]) / 255)
        })
        return (s, w, h)
    }

    /// Quadrant colours of `image` rendered at its oriented full size.
    private func rendered(_ image: DecodedImage) throws -> String {
        let r = Renderer(layer: CAMetalLayer(), monitorsMemoryPressure: false)
        let w = image.fullWidth, h = image.fullHeight
        r.setViewSize(CGSize(width: w, height: h), backingScale: 1)
        r.setImage(image, key: "heif")
        let deadline = Date().addingTimeInterval(5)
        while !r.isPyramidComplete(for: image) && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
        let texture = try XCTUnwrap(r.renderOffscreen(format: .rgba16Float))
        var halfs = [Float16](repeating: 0, count: w * h * 4)
        halfs.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0) }
        func encode(_ v: Float16) -> Double {
            let x = min(max(Double(v), 0), 1)
            return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        }
        return String(Self.centres.map { fx, fy in
            let i = (Int(Double(h) * fy) * w + Int(Double(w) * fx)) * 4
            return classify(encode(halfs[i]), encode(halfs[i + 1]), encode(halfs[i + 2]))
        })
    }

    private func write(_ name: String, orientation: Int, thumbnail: Bool) throws -> URL {
        let url = dir.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.heic" as CFString, 1, nil) else {
            throw XCTSkip("no HEIC encoder")
        }
        CGImageDestinationAddImage(destination, try quadrants(640, 480), [
            kCGImagePropertyOrientation: orientation, kCGImageDestinationEmbedThumbnail: thumbnail,
            kCGImageDestinationLossyCompressionQuality: 0.9,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw XCTSkip("cannot encode HEIC") }
        return url
    }

    private func check(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let (want, w, h) = try reference(url)
        XCTAssertFalse(want.contains("?"), "reference \(want)", file: file, line: line)
        let decoder = ImageIODecoder()
        for (tier, target) in [(Tier.preview, 160), (.screen, 320), (.full, 0)] {
            let image = try decoder.decode(url, tier: tier, targetLongSide: target, pool: pool)
            XCTAssertEqual(image.fullWidth, w, "\(url.lastPathComponent) \(tier)", file: file, line: line)
            XCTAssertEqual(image.fullHeight, h, "\(url.lastPathComponent) \(tier)", file: file, line: line)
            XCTAssertEqual(try rendered(image), want, "\(url.lastPathComponent) \(tier) (\(image.pixels.width)×\(image.pixels.height), "
                           + "orientation \(image.orientation.rawValue))", file: file, line: line)
        }
    }

    func testEveryOrientationWithAndWithoutAThumbnail() throws {
        for thumbnail in [false, true] {
            for orientation in 1...8 {
                try check(try write("o\(orientation)\(thumbnail ? "-thumb" : "").heic", orientation: orientation, thumbnail: thumbnail))
            }
        }
    }

    /// libheif and others carry the orientation in `irot` / `imir` only and write EXIF orientation 1: ImageIO follows
    /// the transform properties, and so does every tier.
    func testTransformPropertiesWinOverTheEXIFTag() throws {
        for orientation in [3, 6, 8, 2] {
            let url = try write("x\(orientation).heic", orientation: orientation, thumbnail: false)
            var bytes = [UInt8](try Data(contentsOf: url))
            guard let tag = Self.exifOrientationValue(bytes) else { throw XCTSkip("no EXIF orientation tag found") }
            bytes[tag] = 0; bytes[tag + 1] = 1   // big-endian SHORT 1
            try Data(bytes).write(to: url)
            XCTAssertEqual(try ImageIODecoder().probe(url).orientation.rawValue, UInt32(orientation))
            try check(url)
        }
    }

    /// Offset of the EXIF orientation value (big-endian SHORT in a "MM" TIFF header) in the file.
    private static func exifOrientationValue(_ d: [UInt8]) -> Int? {
        var i = 0
        while i + 8 < d.count {
            if d[i] == 0x4D, d[i + 1] == 0x4D, d[i + 2] == 0, d[i + 3] == 0x2A {
                let ifd = i + (Int(d[i + 4]) << 24 | Int(d[i + 5]) << 16 | Int(d[i + 6]) << 8 | Int(d[i + 7]))
                guard ifd + 2 < d.count else { return nil }
                let n = Int(d[ifd]) << 8 | Int(d[ifd + 1])
                for e in 0..<n {
                    let p = ifd + 2 + e * 12
                    guard p + 12 <= d.count else { return nil }
                    if d[p] == 0x01, d[p + 1] == 0x12 { return p + 8 }
                }
                return nil
            }
            i += 1
        }
        return nil
    }
}
