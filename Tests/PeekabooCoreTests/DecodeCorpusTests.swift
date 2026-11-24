import CoreGraphics
import Metal
import XCTest
@testable import PeekabooCore

/// Every file of the benchmark corpus (`$PEEKABOO_CORPUS`, skipped when unset) at every tier.
final class DecodeCorpusTests: XCTestCase {
    private func corpus() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["PEEKABOO_CORPUS"], !path.isEmpty else {
            throw XCTSkip("PEEKABOO_CORPUS is not set")
        }
        return URL(fileURLWithPath: path)
    }

    private func files(_ root: URL) -> [URL] {
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var result: [URL] = []
        while let url = walker?.nextObject() as? URL {
            guard !url.pathComponents.contains("nav"), !["md", "json", "txt", ""].contains(url.pathExtension.lowercased()) else { continue }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue { result.append(url) }
        }
        return result.sorted { $0.path < $1.path }
    }

    func testEveryFileDecodesAtEveryTier() throws {
        let root = try corpus()
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let pool = PixelBufferPool(device: device)
        let decoder = ImageIODecoder()
        let list = files(root)
        XCTAssertFalse(list.isEmpty)
        for url in list {
            let name = url.lastPathComponent
            let info = try decoder.probe(url)
            XCTAssertNotNil(info.exif["format"], name)
            let fullAspect = Double(info.orientedWidth) / Double(info.orientedHeight)
            for (tier, target) in [(Tier.preview, 512), (.screen, 3456), (.full, 0)] {
                try autoreleasepool {
                    let image = try decoder.decode(url, tier: tier, targetLongSide: target, pool: pool)
                    let p = image.pixels
                    XCTAssertEqual(image.fullWidth, info.orientedWidth, "\(name) \(tier)")
                    XCTAssertEqual(image.fullHeight, info.orientedHeight, "\(name) \(tier)")
                    XCTAssertGreaterThan(p.width, 0)
                    XCTAssertGreaterThanOrEqual(p.bytesPerRow, p.width * p.layout.bytesPerPixel)
                    let swaps = image.orientation.rawValue >= 5
                    let (w, h) = swaps ? (p.height, p.width) : (p.width, p.height)
                    XCTAssertEqual(Double(w) / Double(h), fullAspect, accuracy: fullAspect * 0.02, "\(name) \(tier) aspect")
                    let long = max(w, h), fullLong = max(info.orientedWidth, info.orientedHeight)
                    switch tier {
                    case .full:
                        XCTAssertEqual(w, info.orientedWidth, "\(name) full width")
                        XCTAssertEqual(h, info.orientedHeight, "\(name) full height")
                    case .screen:
                        XCTAssertGreaterThanOrEqual(long, min(target, fullLong), "\(name) screen covers the target")
                    case .preview:
                        XCTAssertLessThanOrEqual(long, max(2 * target, 1100), "\(name) preview stays small")
                    }
                }
            }
        }
    }

    func testRAWPreviewsComeFromEmbeddedJPEGs() throws {
        let root = try corpus().appendingPathComponent("raw")
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let pool = PixelBufferPool(device: device)
        let decoder = ImageIODecoder()
        for url in files(root) where url.pathExtension.uppercased() != "CR3" {
            let start = Trace.now()
            let image = try decoder.decode(url, tier: .preview, targetLongSide: 512, pool: pool)
            let ms = Trace.ms(since: start)
            // A demosaic would produce 16-bit pixels and take 0.2–1.4 s.
            XCTAssertNotEqual(image.pixels.layout, .rgba16, url.lastPathComponent)
            XCTAssertLessThan(ms, 150, "\(url.lastPathComponent): \(ms) ms")
        }
    }

    func testGainMapDetection() throws {
        let root = try corpus()
        let decoder = ImageIODecoder()
        let hdr = root.appendingPathComponent("hdr/jpeg_apple_gainmap_new_small.jpg")
        guard FileManager.default.fileExists(atPath: hdr.path) else { throw XCTSkip("no gain-map sample") }
        XCTAssertTrue(try decoder.probe(hdr).hasGainMap)
        let plain = root.appendingPathComponent("jpeg/jpeg_12mp_4000x3000.jpg")
        if FileManager.default.fileExists(atPath: plain.path) {
            let info = try decoder.probe(plain)
            XCTAssertFalse(info.hasGainMap)
            XCTAssertEqual(info.exif["format"], "JPEG baseline 4:2:0")
        }
    }
}
