import CoreGraphics
import ImageIO
import Metal
import UniformTypeIdentifiers
import XCTest
@testable import PeekabooCore

/// The image list's thumbnails (`Thumbnail.make`): from the embedded preview where there is one, small, turned like the
/// photo, in the layout Core Animation shows as it is.
final class ThumbnailTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("peekaboo-thumbs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// A `width`×`height` image: one colour per quarter (top left red, top right green, bottom left blue, bottom right
    /// white), so a turn or a mirror shows.
    private func quarters(_ width: Int, _ height: Int, alpha: Bool = false) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: info)!
        let w = CGFloat(width) / 2, h = CGFloat(height) / 2
        // CoreGraphics' origin is the bottom left: the top row is y = height.
        for (rect, rgb) in [(CGRect(x: 0, y: h, width: w, height: h), [1.0, 0, 0]), (CGRect(x: w, y: h, width: w, height: h), [0, 1.0, 0]),
                            (CGRect(x: 0, y: 0, width: w, height: h), [0, 0, 1.0]), (CGRect(x: w, y: 0, width: w, height: h), [1.0, 1, 1])] {
            context.setFillColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
            context.fill(rect)
        }
        if alpha { context.clear(CGRect(x: 0, y: 0, width: 1, height: 1)) }
        return context.makeImage()!
    }

    @discardableResult
    private func write(_ image: CGImage, _ name: String, type: UTType = .jpeg, orientation: Int = 1,
                       embedThumbnail: Bool = false) -> URL {
        let url = directory.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        if type == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = 0.95 }
        if embedThumbnail { properties[kCGImageDestinationEmbedThumbnail] = true }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    /// The colour (r, g, b) of the shown pixel at fractions (`x`, `y`) of `image`, from the top left.
    private func colour(_ image: CGImage, _ x: Double, _ y: Double) -> [Int] {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let px = min(Int(x * Double(image.width)), image.width - 1), row = min(Int(y * Double(image.height)), image.height - 1)
        let p = (row * image.width + px) * 4
        return [Int(bytes[p]), Int(bytes[p + 1]), Int(bytes[p + 2])]
    }

    /// Which quarter colour the pixel is closest to.
    private func quarter(_ image: CGImage, _ x: Double, _ y: Double) -> String {
        let c = colour(image, x, y)
        let names: [(String, [Int])] = [("red", [255, 0, 0]), ("green", [0, 255, 0]), ("blue", [0, 0, 255]), ("white", [255, 255, 255])]
        return names.min { a, b in
            zip(a.1, c).map { abs($0 - $1) }.reduce(0, +) < zip(b.1, c).map { abs($0 - $1) }.reduce(0, +)
        }!.0
    }

    private func assertLayout(_ image: CGImage, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(image.bitsPerComponent, 8, file: file, line: line)
        XCTAssertEqual(image.bitsPerPixel, 32, file: file, line: line)
        XCTAssertEqual(image.alphaInfo, .premultipliedFirst, file: file, line: line)
        XCTAssertEqual(image.bitmapInfo.intersection(.byteOrderMask), .byteOrder32Little, file: file, line: line)
        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.displayP3, file: file, line: line)
    }

    func testAJPEGWithAnEmbeddedThumbnailUsesIt() throws {
        let url = write(quarters(3000, 2000), "embedded.jpg", embedThumbnail: true)
        let made = try XCTUnwrap(Thumbnail.make(url, maxPixelSize: 96))
        XCTAssertEqual(made.source, .embedded)
        XCTAssertLessThanOrEqual(max(made.image.width, made.image.height), 96)
        XCTAssertEqual(Double(made.image.width) / Double(made.image.height), 1.5, accuracy: 0.03)
        assertLayout(made.image)
        XCTAssertEqual(quarter(made.image, 0.1, 0.1), "red")
        XCTAssertEqual(quarter(made.image, 0.9, 0.9), "white")
    }

    /// A HEIC's thumbnail item is its embedded preview; without one the image is decoded.
    func testAHEICUsesItsThumbnailItem() throws {
        guard (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(UTType.heic.identifier) else {
            throw XCTSkip("no HEIC encoder")
        }
        for embed in [true, false] {
            let url = write(quarters(1200, 800), "photo-\(embed).heic", type: .heic, embedThumbnail: embed)
            let made = try XCTUnwrap(Thumbnail.make(url, maxPixelSize: 96))
            XCTAssertEqual(made.source, embed ? .embedded : .image)
            XCTAssertEqual([made.image.width, made.image.height], [96, 64])
            assertLayout(made.image)
            XCTAssertEqual(quarter(made.image, 0.9, 0.1), "green")
        }
    }

    func testAnImageWithoutAThumbnailIsMadeFromTheImage() throws {
        for (name, type) in [("plain.jpg", UTType.jpeg), ("plain.png", .png)] {
            let url = write(quarters(1200, 800), name, type: type)
            let made = try XCTUnwrap(Thumbnail.make(url, maxPixelSize: 96), name)
            XCTAssertEqual(made.source, .image, name)
            XCTAssertEqual(made.image.width, 96, name)
            XCTAssertEqual(made.image.height, 64, name)
            assertLayout(made.image)
            XCTAssertEqual(quarter(made.image, 0.1, 0.9), "blue", name)
        }
        // Smaller than asked for: kept at its size.
        let small = write(quarters(40, 20), "small.png", type: .png)
        let made = try XCTUnwrap(Thumbnail.make(small, maxPixelSize: 96))
        XCTAssertEqual([made.image.width, made.image.height], [40, 20])
        XCTAssertNil(Thumbnail.make(directory.appendingPathComponent("missing.jpg"), maxPixelSize: 96))
        let garbage = directory.appendingPathComponent("garbage.jpg")
        try Data("not an image".utf8).write(to: garbage)
        XCTAssertNil(Thumbnail.make(garbage, maxPixelSize: 96))
    }

    /// Turned like the photo (EXIF orientation 6: shown rotated a quarter turn clockwise), from the embedded thumbnail
    /// and from the image alike.
    func testTheThumbnailIsTurnedLikeThePhoto() throws {
        for embed in [true, false] {
            let url = write(quarters(1200, 800), "turned-\(embed).jpg", orientation: 6, embedThumbnail: embed)
            let made = try XCTUnwrap(Thumbnail.make(url, maxPixelSize: 96))
            XCTAssertEqual(made.source, embed ? .embedded : .image)
            XCTAssertLessThan(made.image.width, made.image.height, "not turned (embedded: \(embed))")
            // A quarter turn clockwise puts the stored top left (red) at the top right.
            XCTAssertEqual(quarter(made.image, 0.9, 0.1), "red", "embedded: \(embed)")
            XCTAssertEqual(quarter(made.image, 0.1, 0.9), "white", "embedded: \(embed)")
        }
    }

    /// `redraw` turns pixels for each of the 8 EXIF orientations exactly as ImageIO's own transform does (it turns the
    /// renditions of a CR3, which carry no orientation of their own).
    func testRedrawTurnsLikeImageIOForEveryOrientation() throws {
        let image = quarters(60, 40)
        for orientation in 1...8 {
            let url = write(image, "o\(orientation).tiff", type: .tiff, orientation: orientation)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: 60]
            let reference = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary))
            let stored = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let turned = try XCTUnwrap(Thumbnail.redraw(stored, maxPixelSize: 60,
                                                         orientation: CGImagePropertyOrientation(rawValue: UInt32(orientation))!))
            XCTAssertEqual([turned.width, turned.height], [reference.width, reference.height], "orientation \(orientation)")
            for (x, y) in [(0.2, 0.2), (0.8, 0.2), (0.2, 0.8), (0.8, 0.8)] {
                XCTAssertEqual(quarter(turned, x, y), quarter(reference, x, y), "orientation \(orientation) at \(x), \(y)")
            }
        }
    }

    /// Cameras letterbox the 160×120 EXIF thumbnail of a 3:2 photo with black bars: the middle is kept, at the photo's
    /// aspect ratio (turned photos too).
    func testALetterboxedEXIFThumbnailIsTrimmed() throws {
        // ImageIO hands over the thumbnail turned like the photo: 120×160 for a photo shown upright.
        for (orientation, bars, expected) in [(1, quarters(160, 120), [160, 107]), (6, quarters(120, 160), [107, 160])] {
            let photo = write(quarters(300, 200), "photo-\(orientation).jpg", orientation: orientation)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(photo as CFURL, nil))
            let trimmed = Thumbnail.trimmed(bars, source: source, index: 0)
            XCTAssertEqual([trimmed.width, trimmed.height], expected, "orientation \(orientation)")
        }
        // A thumbnail of the photo's own shape is kept as it is.
        let photo = write(quarters(300, 200), "fits.jpg")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(photo as CFURL, nil))
        let fitting = quarters(150, 100)
        XCTAssertTrue(Thumbnail.trimmed(fitting, source: source, index: 0) === fitting)
    }

    /// The viewer's preview of a file (a `PixelBuffer`, in each 8- and 16-bit layout the decoders hand over) makes the
    /// thumbnail without the file, turned by its orientation; the padding byte of an opaque buffer is ignored. HDR
    /// pixels make none (the file then does).
    func testThePreviewOfTheViewerMakesTheThumbnail() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let pool = PixelBufferPool(device: device)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let image = quarters(64, 40)
        for layout in [PixelLayout.rgba8, .bgra8, .argb8, .rgba16] {
            let pixels = try XCTUnwrap(pool.make(width: 64, height: 40, layout: layout, alpha: .opaque, colorSpace: space))
            let context = try XCTUnwrap(pixels.makeContext(), "\(layout)")
            context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 40))
            // Opaque: whatever the fourth component holds is padding.
            let base = pixels.baseAddress.assumingMemoryBound(to: UInt8.self)
            for y in 0..<40 {
                for x in 0..<64 {
                    let p = y * pixels.bytesPerRow + x * layout.bytesPerPixel
                    switch layout {
                    case .argb8: base[p] = 0
                    case .rgba16: base[p + 6] = 0; base[p + 7] = 0
                    default: base[p + 3] = 0
                    }
                }
            }
            for orientation in [CGImagePropertyOrientation.up, .right] {
                let decoded = DecodedImage(pixels: pixels, tier: .preview, fullWidth: 64, fullHeight: 40,
                                           orientation: orientation, isHDR: false, decodeNanos: 0)
                let made = try XCTUnwrap(Thumbnail.make(from: decoded, maxPixelSize: 96), "\(layout)")
                assertLayout(made)
                let turned = orientation == .right
                XCTAssertEqual([made.width, made.height], turned ? [40, 64] : [64, 40], "\(layout)")
                XCTAssertEqual(quarter(made, turned ? 0.8 : 0.2, 0.2), "red", "\(layout) \(orientation)")
                XCTAssertEqual(quarter(made, turned ? 0.2 : 0.8, 0.8), "white", "\(layout) \(orientation)")
            }
        }
        let hdr = try XCTUnwrap(pool.make(width: 8, height: 8, layout: .rgba16f, alpha: .opaque,
                                          colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!))
        XCTAssertNil(Thumbnail.make(from: DecodedImage(pixels: hdr, tier: .preview, fullWidth: 8, fullHeight: 8, orientation: .up,
                                                       isHDR: true, decodeNanos: 0), maxPixelSize: 96))
    }

    /// A CR3 has no preview ImageIO exposes: its container's rendition is used (the corpus CR3, when it is there).
    func testACR3UsesItsContainerRendition() throws {
        let corpus = ProcessInfo.processInfo.environment["PEEKABOO_CORPUS"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/peekaboo-corpus").path
        let raw = URL(fileURLWithPath: corpus).appendingPathComponent("raw")
        guard let name = (try? FileManager.default.contentsOfDirectory(atPath: raw.path))?.first(where: { $0.lowercased().hasSuffix(".cr3") })
        else { throw XCTSkip("no CR3 in the corpus (mise run corpus)") }
        let started = Trace.now()
        let made = try XCTUnwrap(Thumbnail.make(raw.appendingPathComponent(name), maxPixelSize: 96))
        print(String(format: "CR3 thumbnail: %dx%d from its %@ in %.1f ms", made.image.width, made.image.height,
                     made.source.rawValue, Trace.ms(since: started)))
        XCTAssertEqual(made.source, .container)
        XCTAssertEqual(max(made.image.width, made.image.height), 96)
        assertLayout(made.image)
    }
}
