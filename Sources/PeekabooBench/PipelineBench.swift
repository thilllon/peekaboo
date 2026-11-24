import Foundation
import Metal
import PeekabooCore

/// `peekaboo-bench pipeline [--corpus DIR] [--trace steady|burst|ab|random|all] [--screen PX] [--quick] [--cold]
/// [--all-previews]`
///
/// `--cold` starts each trace right after the first image is sharp, without the background preview sweep (as when
/// the user starts browsing a folder at once): first-pixel latency is then measured instead of hidden by a warm
/// preview cache. `--all-previews` restores the old planner rule that also prefetched expensive previews inside the
/// screen-tier window (A/B against the default).
///
/// Replays navigation traces against the real decoder and reports, per trace, the share of navigations that found
/// the sharp tier cached (hit rate), time-to-first-pixel and time-to-sharp percentiles, decode/waste counts and the
/// main-thread cost of `navigate`. The corpus defaults to `$PEEKABOO_CORPUS` (its `nav` subfolder when present).
func runPipelineBench(_ args: ArraySlice<String>) throws {
    var corpus = ProcessInfo.processInfo.environment["PEEKABOO_CORPUS"]
    var traceName = "all"
    var screen = 3456
    var quick = false
    var options = ReplayOptions()
    var listing: Int?
    var rest = args
    while let arg = rest.popFirst() {
        switch arg {
        case "--corpus": corpus = rest.popFirst()
        case "--trace": traceName = rest.popFirst() ?? "all"
        case "--screen": screen = Int(rest.popFirst() ?? "") ?? screen
        case "--quick": quick = true
        case "--cold": options.cold = true
        case "--all-previews": options.allPreviews = true
        case "--listing": listing = Int(rest.popFirst() ?? "") ?? 10_000
        default: throw BenchError.usage("unknown option \(arg)")
        }
    }
    if let listing { return try runListingBench(count: listing) }
    guard let corpus else { throw BenchError.usage("pass --corpus DIR or set PEEKABOO_CORPUS") }
    var folder = URL(fileURLWithPath: corpus)
    if FileManager.default.fileExists(atPath: folder.appendingPathComponent("nav").path) {
        folder = folder.appendingPathComponent("nav")
    }
    guard let device = MTLCreateSystemDefaultDevice() else { throw BenchError.usage("no Metal device") }

    // Folder listing (getattrlistbulk + natural keys), warm.
    _ = try FolderScanner.scan(folder)
    var scanTimes: [Double] = []
    var files: [ImageFile] = []
    for _ in 0..<5 {
        let start = Trace.now()
        files = try FolderScanner.scan(folder)
        scanTimes.append(Trace.ms(since: start))
    }
    guard files.count >= 8 else { throw BenchError.usage("need at least 8 images in \(folder.lastPathComponent)") }
    print("pipeline bench: \(files.count) files, screen \(screen) px, scan median \(fmt(median(scanTimes))) ms"
          + (options.cold ? ", cold (no sweep, no settle)" : "") + (options.allPreviews ? ", all previews" : ""))

    let traces = makeTraces(count: files.count, quick: quick).filter { traceName == "all" || $0.name == traceName }
    guard !traces.isEmpty else { throw BenchError.usage("unknown trace \(traceName)") }
    print("trace    events  hit%  px@0%  first-pixel p50/p90/p99 ms  sharp p50/p90/p99 ms   decodes wasted  nav() p50/p99 µs")
    for trace in traces {
        let result = replay(trace, files: files, device: device, screen: screen, options: options)
        print(result.line(trace.name))
    }
}

private enum BenchError: Error, CustomStringConvertible {
    case usage(String)
    var description: String { if case .usage(let m) = self { return m }; return "" }
}

private struct NavEvent {
    let atMs: Double
    let index: Int
    let isRepeat: Bool
    /// The user stops here (time-to-sharp is measured only for such events).
    let dwell: Bool
}

private struct NavTrace {
    let name: String
    let events: [NavEvent]
    let tailMs: Double
}

private func makeTraces(count: Int, quick: Bool) -> [NavTrace] {
    let scale = quick ? 0.5 : 1.0
    var traces: [NavTrace] = []
    // Steady 1/s forward.
    let steadySteps = min(count - 1, Int(15 * scale))
    traces.append(NavTrace(name: "steady", events: (1...steadySteps).map {
        NavEvent(atMs: Double($0) * 1000, index: $0, isRepeat: false, dwell: true)
    }, tailMs: 1500))
    // Key repeat at 30/s for 2 s, then a dwell; twice.
    var burst: [NavEvent] = []
    var t = 500.0, i = 0
    for _ in 0..<2 {
        for step in 0..<60 where i + 1 < count {
            i += 1
            t += 33.3
            burst.append(NavEvent(atMs: t, index: i, isRepeat: step > 0, dwell: false))
        }
        if let last = burst.popLast() { burst.append(NavEvent(atMs: last.atMs, index: last.index, isRepeat: last.isRepeat, dwell: true)) }
        t += 1500
    }
    traces.append(NavTrace(name: "burst", events: burst, tailMs: 1500))
    // A/B toggling every 700 ms.
    let a = count / 2
    traces.append(NavTrace(name: "ab", events: (1...Int(12 * scale)).map {
        NavEvent(atMs: Double($0) * 700, index: $0 % 2 == 1 ? a + 1 : a, isRepeat: false, dwell: true)
    }, tailMs: 1000))
    // Random jumps with an 800 ms dwell (deterministic LCG).
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    var randomEvents: [NavEvent] = []
    for n in 1...Int(15 * scale) {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        randomEvents.append(NavEvent(atMs: Double(n) * 800, index: Int(seed >> 33) % count, isRepeat: false, dwell: true))
    }
    traces.append(NavTrace(name: "random", events: randomEvents, tailMs: 1200))
    return traces
}

private struct ReplayResult {
    var events = 0
    var hits = 0
    var pixelAtArrival = 0
    var firstPixel: [Double] = []
    var sharp: [Double] = []
    var censoredSharp = 0
    var decodes = 0
    var wasted = 0
    var navigateMicros: [Double] = []

    func line(_ name: String) -> String {
        func pct(_ values: [Double]) -> String {
            values.isEmpty ? "—" : [0.5, 0.9, 0.99].map { fmt(percentile(values, $0)) }.joined(separator: "/")
        }
        let hitRate = events == 0 ? 0 : 100 * Double(hits) / Double(events)
        let pixelRate = events == 0 ? 0 : 100 * Double(pixelAtArrival) / Double(events)
        let censored = censoredSharp > 0 ? " (+\(censoredSharp) not sharp)" : ""
        return name.padding(toLength: 9, withPad: " ", startingAt: 0)
            + String(format: "%6d %5.0f %6.0f  ", events, hitRate, pixelRate)
            + pct(firstPixel).padding(toLength: 26, withPad: " ", startingAt: 0)
            + (pct(sharp) + censored).padding(toLength: 23, withPad: " ", startingAt: 0)
            + String(format: "%7d %6d  ", decodes, wasted)
            + "\(fmt(percentile(navigateMicros, 0.5)))/\(fmt(percentile(navigateMicros, 0.99)))"
    }
}

private struct ReplayOptions {
    var cold = false
    var allPreviews = false
}

private func replay(_ trace: NavTrace, files: [ImageFile], device: MTLDevice, screen: Int,
                    options: ReplayOptions) -> ReplayResult {
    var config = PipelineConfig(screenLongSide: screen)
    config.monitorsMemoryPressure = false
    if options.cold {
        config.sweepLanes = 0
        config.quickLookSweep = false
        config.tuning.sweepEnabled = false
    }
    if options.allPreviews { config.tuning.screenWindowCheapPreviewsOnly = false }
    let pipeline = ImagePipeline(decoder: ImageIODecoder(), pool: PixelBufferPool(device: device), config: config)
    var result = ReplayResult()
    // Measurement of the navigation in progress.
    var target: ImageFile?
    var navigatedAt: UInt64 = 0
    var firstPixelAt: UInt64?
    var sharpAt: UInt64?
    var measureSharp = false
    pipeline.onDecoded = { file, image in
        guard file == target else { return }
        let now = Trace.now()
        if firstPixelAt == nil { firstPixelAt = now }
        if image.tier >= .screen && sharpAt == nil { sharpAt = now }
    }
    func finish() {
        guard target != nil else { return }
        if let firstPixelAt { result.firstPixel.append(Double(firstPixelAt &- navigatedAt) / 1e6) }
        if measureSharp {
            if let sharpAt { result.sharp.append(Double(sharpAt &- navigatedAt) / 1e6) } else { result.censoredSharp += 1 }
        }
    }

    // Open the first image of the trace and let the cache settle, as after opening a file.
    let startIndex = max(0, (trace.events.first?.index ?? 1) - 1)
    pipeline.setFiles(files, index: trace.name == "ab" ? trace.events[0].index : startIndex)
    let current = pipeline.currentFile!
    spinRunLoop(until: Date().addingTimeInterval(5)) { pipeline.best(for: current).map { $0.tier >= .screen } == true }
    if !options.cold { spinRunLoop(until: Date().addingTimeInterval(0.8)) { false } }
    let decodesBefore = pipeline.stats.decodes, wastedBefore = pipeline.stats.wasted

    let origin = Trace.now()
    for event in trace.events {
        let due = origin + UInt64(event.atMs * 1e6)
        while Trace.now() < due {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(min(0.001, Double(due &- Trace.now()) / 1e9)))
        }
        finish()
        let file = files[event.index]
        let start = Trace.now()
        pipeline.navigate(to: event.index, isRepeat: event.isRepeat)
        result.navigateMicros.append(Double(Trace.now() &- start) / 1e3)
        target = file
        navigatedAt = start
        measureSharp = event.dwell
        firstPixelAt = nil
        sharpAt = nil
        if let best = pipeline.best(for: file) {
            firstPixelAt = start
            result.pixelAtArrival += 1
            if best.tier >= .screen {
                sharpAt = start
                result.hits += 1
            }
        }
        result.events += 1
    }
    spinRunLoop(until: Date().addingTimeInterval(trace.tailMs / 1000)) { false }
    finish()
    result.decodes = pipeline.stats.decodes - decodesBefore
    result.wasted = pipeline.stats.wasted - wastedBefore
    return result
}

private func spinRunLoop(until deadline: Date, _ done: () -> Bool) {
    while !done() && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.001)) }
}

private func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
}

private func median(_ values: [Double]) -> Double { percentile(values, 0.5) }

private func fmt(_ value: Double) -> String {
    if value.isNaN { return "—" }
    return value < 10 ? String(format: "%.1f", value) : String(format: "%.0f", value)
}

/// `--listing N`: folder listing and Finder-order sorting on N synthetic files in a temporary directory.
private func runListingBench(count: Int) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("peekaboo-listing-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let stems = ["IMG_", "DSC0", "photo (", "Screenshot 2026-11-24 at ", "스크린샷 2026-11-24 오후 ", "P10", "_MG_"]
    for i in 0..<count {
        let stem = stems[i % stems.count]
        let name = stem.hasSuffix("(") ? "\(stem)\(i)).jpg" : "\(stem)\(i).\(i % 5 == 0 ? "heic" : "jpg")"
        FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: nil)
    }
    func measure(_ label: String, _ body: () throws -> Int) rethrows {
        var times: [Double] = []
        var n = 0
        _ = try body()
        for _ in 0..<7 {
            let start = Trace.now()
            n = try body()
            times.append(Trace.ms(since: start))
        }
        print("\(label.padding(toLength: 46, withPad: " ", startingAt: 0)) n=\(n)  median \(fmt(median(times))) ms")
    }
    print("listing bench: \(count) files")
    try measure("getattrlistbulk (name, type, mtime, flags, id)") { try FolderScanner.listBulk(directory)?.count ?? -1 }
    try measure("FileManager + lstat (fallback)") { try FolderScanner.listWithFileManager(directory).count }
    let names = try FolderScanner.listBulk(directory)!.map(\.name).shuffled()
    measure("natural keys: build only") { names.reduce(0) { $0 + (NaturalSort.key($1)?.count ?? 0) } }
    let unsupported = names.filter { NaturalSort.key($0) == nil }
    if !unsupported.isEmpty { print("names without a fast key: \(unsupported.count), e.g. \(unsupported.prefix(2))") }
    measure("sort: precomputed natural keys") { NaturalSort.sort(names, by: { $0 }).count }
    measure("sort: localizedStandardCompare") { names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.count }
    try measure("FolderScanner.scan (list + filter + sort)") { try FolderScanner.scan(directory).count }
    let same = NaturalSort.sort(names, by: { $0 }) == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    print("natural keys agree with localizedStandardCompare: \(same)")
}
