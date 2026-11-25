import Foundation
import Metal
import PeekabooCore

/// `peekaboo-bench anim [file …] [--loops N] [--hz N] [--budget-mb N]`
///
/// Plays animations headless with the app's `AnimationPlayer` (default: every file in `$PEEKABOO_CORPUS/anim`). A timer
/// on the main queue stands in for the display link: every `--hz` refresh (default 120) asks the player for the frame
/// due at that refresh, as the app does. Per file: how long each frame stayed on screen (refresh that replaced it
/// minus the one that showed it) against its declared delay, frames shown late (not decoded by their deadline),
/// decode time per frame, the decoded frames kept, and the process footprint before and after.
func runAnimBench(_ args: ArraySlice<String>) throws {
    var files: [URL] = []
    var loops = 3
    var hz = 120.0
    var budgetMB = 256
    var it = args.makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--loops": loops = Int(it.next() ?? "") ?? loops
        case "--hz": hz = Double(it.next() ?? "") ?? hz
        case "--budget-mb": budgetMB = Int(it.next() ?? "") ?? budgetMB
        default: files.append(URL(fileURLWithPath: arg))
        }
    }
    if files.isEmpty, let corpus = ProcessInfo.processInfo.environment["PEEKABOO_CORPUS"] {
        let dir = URL(fileURLWithPath: corpus).appendingPathComponent("anim")
        files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.path < $1.path }
    }
    guard !files.isEmpty, let device = MTLCreateSystemDefaultDevice() else {
        print("usage: peekaboo-bench anim <file …> [--loops N] [--hz N] [--budget-mb N]  (or set PEEKABOO_CORPUS; needs Metal)")
        return
    }
    let pool = PixelBufferPool(device: device)
    let decoder = ImageIODecoder()
    print("headless playback: \(Int(hz)) Hz refreshes on a main-queue timer, \(loops) loops, budget \(budgetMB) MB")
    for url in files {
        let info = try decoder.probe(url)
        guard info.isAnimated else {
            print("\(url.lastPathComponent): not an animation")
            continue
        }
        let before = footprint()
        let result = play(url, info: info, pool: pool, loops: loops, hz: hz, budget: budgetMB << 20)
        let after = footprint()
        guard let timing = result.timing else { print("\(url.lastPathComponent): no timing"); continue }
        let declared = Set(timing.delays.map { String(format: "%.0f", $0 * 1000) }).sorted().joined(separator: "/")
        // Error of every on-screen duration against the declared delay of the frame shown.
        let errors = zip(result.shown, result.shown.dropFirst()).map { a, b in (b.at - a.at - timing.delays[a.index]) * 1000 }
        let absolute = errors.map(abs).sorted()
        func pct(_ p: Double) -> Double { absolute.isEmpty ? .nan : absolute[Int((p * Double(absolute.count - 1)).rounded())] }
        let mean = errors.isEmpty ? .nan : errors.reduce(0, +) / Double(errors.count)
        let decodes = result.decodeMs.sorted()
        func dpct(_ p: Double) -> Double { decodes.isEmpty ? .nan : decodes[Int((p * Double(decodes.count - 1)).rounded())] }
        print("\(url.lastPathComponent): \(info.pixelWidth)×\(info.pixelHeight), \(timing.frameCount) frames, declared \(declared) ms, "
              + "loop count \(timing.loopCount == 0 ? "forever" : String(timing.loopCount))")
        print(String(format: "  on-screen duration − declared: mean %+.2f ms, |err| p50 %.2f p95 %.2f max %.2f ms over %d frames; late %d",
                     mean, pct(0.5), pct(0.95), absolute.last ?? .nan, errors.count, result.late))
        print(String(format: "  decode per frame: p50 %.2f p95 %.2f max %.2f ms (%d decodes)", dpct(0.5), dpct(0.95),
                     decodes.last ?? .nan, result.decodes))
        print(String(format: "  frames kept: %.1f MB (%@), footprint %.1f → %.1f MB", Double(result.resident) / 1048576,
                     result.keepsAll ? "every frame" : "a window", Double(before) / 1048576, Double(after) / 1048576))
    }
}

private struct PlaybackResult {
    var timing: AnimationTiming?
    /// Frame index and the refresh target time it was shown at.
    var shown: [(index: Int, at: Double)] = []
    var late = 0
    var decodeMs: [Double] = []
    var decodes = 0
    var resident = 0
    var keepsAll = false
}

/// Play `loops` loops on a simulated display link; frame 0 counts as shown at the start, like the app's still.
private func play(_ url: URL, info: ImageInfo, pool: PixelBufferPool, loops: Int, hz: Double, budget: Int) -> PlaybackResult {
    var result = PlaybackResult()
    let player = AnimationPlayer(url: url, info: info, device: pool.device, budgetBytes: budget)
    var seen = Set<Int>()
    player.onFrameDecoded = { i in
        if let ms = player.frame(i).map({ Double($0.decodeNanos) / 1e6 }), !seen.contains(i) || !player.keepsAllFrames {
            result.decodeMs.append(ms)
            seen.insert(i)
        }
    }
    let clock = { Double(Trace.now()) / 1e9 }
    let period = 1 / hz
    let start = clock()
    player.start(at: start)
    result.shown.append((0, start))
    let target = loops * max(info.frameCount, 1)
    var refresh = 0
    let timer = DispatchSource.makeTimerSource(queue: .main)
    var done = false
    timer.setEventHandler {
        // Refreshes on an ideal grid (the display link's target timestamps), whatever the timer's own jitter.
        refresh = max(refresh + 1, Int(((clock() - start) / period).rounded(.up)))
        let at = start + Double(refresh) * period
        let due = player.deadline
        if player.advance(to: at, tolerance: period / 2) != nil {
            if let due, at - due > period { result.late += 1 }
            result.shown.append((player.index, at))
        }
        if result.shown.count > target || player.isFinished || clock() - start > 120 { done = true }
    }
    timer.schedule(deadline: .now(), repeating: period, leeway: .microseconds(100))
    timer.resume()
    while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
    timer.cancel()
    result.timing = player.timing
    result.decodes = player.decodedFrames
    result.resident = player.residentBytes
    result.keepsAll = player.keepsAllFrames
    player.stop()
    return result
}

/// The process's physical footprint (what Activity Monitor shows as memory).
private func footprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return status == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}
