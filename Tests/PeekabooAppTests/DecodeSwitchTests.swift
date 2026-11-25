import AppKit
import ImageIO
import XCTest
@testable import PeekabooApp
@testable import PeekabooCore
@testable import PeekabooRender

/// `[decode]` and `[debug]` apply live: the process-wide switches follow every config apply, and turning HDR on or off
/// decodes the gain-map image on screen again.
final class DecodeSwitchTests: ViewerTestCase {
    override func tearDown() {
        // Process-wide: leave them as the next test expects.
        ImageIODecoder.decodeHDR = ImageIODecoder.hdrForcedByEnvironment
        ImageIODecoder.usesFastPath = true
        Trace.enabled = Trace.forcedByEnvironment
        super.tearDown()
    }

    func testTurningHDROnAndOffDecodesTheImageOnScreenAgain() throws {
        guard let corpus = ProcessInfo.processInfo.environment["PEEKABOO_CORPUS"], !corpus.isEmpty else {
            throw XCTSkip("PEEKABOO_CORPUS is not set")
        }
        let source = URL(fileURLWithPath: corpus).appendingPathComponent("hdr/jpeg_apple_gainmap_new_small.jpg")
        guard FileManager.default.fileExists(atPath: source.path), !ImageIODecoder.hdrForcedByEnvironment else {
            throw XCTSkip("no gain-map photo in the corpus, or PEEKABOO_HDR is set")
        }
        let url = folder.appendingPathComponent("gainmap.jpg")
        try FileManager.default.copyItem(at: source, to: url)
        let viewer = try makeViewer()
        openAndWait(viewer, [url])
        XCTAssertTrue(spin(5) { (self.renderer(viewer).image?.tier ?? .preview) > .preview })
        XCTAssertEqual(renderer(viewer).image?.isHDR, false)

        var config = AppConfig.default
        config.decodeHDR = true
        viewer.apply(config)
        XCTAssertTrue(ImageIODecoder.decodeHDR)
        XCTAssertTrue(spin(5) { self.renderer(viewer).image?.isHDR == true }, "the image on screen was decoded again in HDR")
        viewer.apply(.default)
        XCTAssertFalse(ImageIODecoder.decodeHDR)
        XCTAssertTrue(spin(5) { self.renderer(viewer).image?.isHDR == false }, "and back to SDR")
        XCTAssertEqual(viewer.displayedFile?.name, "gainmap.jpg")
    }

    /// PQ / HLG files (camera HDR HIF) follow the switch like gain-map photos: their tone-mapped SDR rendition by
    /// default, HDR when it is on. No corpus needed: ImageIO writes the file.
    func testTurningHDROnAndOffDecodesAPQImageOnScreenAgain() throws {
        guard !ImageIODecoder.hdrForcedByEnvironment else { throw XCTSkip("PEEKABOO_HDR is set") }
        let url = try writePQHEIC(folder.appendingPathComponent("pq.heic"))
        guard try ImageIODecoder().probe(url).hasHDRRendition else { throw XCTSkip("ImageIO wrote no BT.2100 transfer") }
        let viewer = try makeViewer()
        openAndWait(viewer, [url])
        XCTAssertTrue(spin(5) { (self.renderer(viewer).image?.tier ?? .preview) > .preview })
        XCTAssertEqual(renderer(viewer).image?.isHDR, false, "the SDR rendition")

        var config = AppConfig.default
        config.decodeHDR = true
        viewer.apply(config)
        XCTAssertTrue(spin(5) { self.renderer(viewer).image?.isHDR == true }, "the image on screen was decoded again in HDR")
        viewer.apply(.default)
        XCTAssertTrue(spin(5) { self.renderer(viewer).image?.isHDR == false }, "and back to SDR")
        XCTAssertEqual(viewer.displayedFile?.name, "pq.heic")
    }

    /// A 640×480 16-bit BT.2100 PQ HEIC: ImageIO writes it 10-bit with the PQ transfer, like a camera's HDR HIF.
    private func writePQHEIC(_ url: URL) throws -> URL {
        let (width, height) = (640, 480)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.itur_2100_PQ))
        var data = Data(count: width * height * 8)
        data.withUnsafeMutableBytes { raw in
            for i in stride(from: 0, to: width * height * 4, by: 4) {
                for (k, v) in [0.6, 0.5, 0.4, 1.0].enumerated() {
                    raw.storeBytes(of: UInt16(v * 65535).littleEndian, toByteOffset: (i + k) * 2, as: UInt16.self)
                }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let info = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64,
                                          bytesPerRow: width * 8, space: space, bitmapInfo: CGBitmapInfo(rawValue: info),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.heic" as CFString, 1, nil) else {
            throw XCTSkip("no HEIC encoder")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw XCTSkip("cannot encode HEIC") }
        return url
    }

    func testFastPathAndTraceFollowTheConfig() throws {
        let viewer = try makeViewer()
        var config = AppConfig.default
        config.fastPath = false
        config.trace = true
        viewer.apply(config)
        XCTAssertFalse(ImageIODecoder.usesFastPath)
        XCTAssertFalse(IOSurfaceSPI.isAvailable, "no decode takes the private path")
        XCTAssertTrue(Trace.enabled)
        XCTAssertTrue(viewer.tracksFrames)
        viewer.apply(.default)
        XCTAssertTrue(ImageIODecoder.usesFastPath)
        XCTAssertEqual(Trace.enabled, Trace.forcedByEnvironment)
        XCTAssertEqual(viewer.tracksFrames, Trace.forcedByEnvironment)
    }
}
