import Metal
import XCTest
@testable import PeekabooCore

/// Real decoder on real photos (`PEEKABOO_CORPUS/nav`): steady browsing must be served from the prefetch cache.
final class NavigationTests: PipelineTestCase {
    private func corpusNav() throws -> URL {
        guard let corpus = ProcessInfo.processInfo.environment["PEEKABOO_CORPUS"] else {
            throw XCTSkip("set PEEKABOO_CORPUS to run corpus navigation tests")
        }
        let nav = URL(fileURLWithPath: corpus).appendingPathComponent("nav")
        guard FileManager.default.fileExists(atPath: nav.path) else { throw XCTSkip("no nav folder in the corpus") }
        return nav
    }

    func testSteadyBrowsingHitsPrefetchedScreenTier() throws {
        let folder = try corpusNav()
        let files = try FolderScanner.scan(folder)
        XCTAssertGreaterThanOrEqual(files.count, 20)
        var config = PipelineConfig(screenLongSide: 3456)
        config.monitorsMemoryPressure = false
        let pipeline = ImagePipeline(decoder: ImageIODecoder(), pool: PixelBufferPool(device: device), config: config)
        pipeline.setFiles(files, index: 0)
        XCTAssertTrue(spin(timeout: 5) { self.has(pipeline, files[0], .screen) })
        spin(for: 0.6)
        var sharpOnArrival = 0
        let steps = 12
        for i in 1...steps {
            pipeline.navigate(to: i, isRepeat: false)
            if pipeline.best(for: files[i]).map({ $0.tier >= .screen }) == true { sharpOnArrival += 1 }
            spin(for: 0.7)
        }
        XCTAssertGreaterThanOrEqual(Double(sharpOnArrival) / Double(steps), 0.75,
                                    "steady 1.4/s browsing should be served from the prefetch cache")
        XCTAssertNotNil(pipeline.info(for: files[1]))
    }

    func testFolderListingOfCorpusMatchesFinderOrder() throws {
        let folder = try corpusNav()
        let files = try FolderScanner.scan(folder)
        let names = files.map(\.name)
        XCTAssertEqual(names, names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        let reference = try FolderScanner.listWithFileManager(folder).filter { FolderScanner.isSupported($0.url) }
        XCTAssertEqual(Set(names), Set(reference.map(\.name)))
    }
}
