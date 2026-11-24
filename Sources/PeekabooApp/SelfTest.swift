import AppKit
import Darwin
import PeekabooCore
import QuartzCore

/// Wall-clock reference points for launch latency.
enum LaunchClock {
    /// Wall time at the top of `main()`.
    static var mainWall: Double = 0

    static func wallNow() -> Double {
        var tv = timeval()
        gettimeofday(&tv, nil)
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6
    }

    /// Kernel start time of this process (`kinfo_proc.kp_proc.p_starttime`), wall clock.
    static func processStartWall() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
        let tv = info.kp_proc.p_un.__p_starttime
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6
    }

    /// `CACurrentMediaTime`-based timestamp → `Trace.now()` nanoseconds (same mach time base).
    static func traceNanos(fromMediaTime t: CFTimeInterval) -> UInt64 {
        let offset = Double(Trace.now()) / 1e9 - CACurrentMediaTime()
        return UInt64(max(t + offset, 0) * 1e9)
    }
}

/// `--selftest <folder>`: opens the folder, measures launch → first frame on glass and
/// action → frame-presented latency for synthetic navigation, prints one JSON line, exits 0.
///
/// (a) process start (sysctl `p_starttime`) → first presented frame that shows an image
///     (`CAMetalDrawable` presented handler attached through the view's layer).
/// (b) 40 × `nav.next` at 3/s, then 20 × at 30/s (auto-repeat, like a held key). For each
///     step: latency from the `perform` call to the presentation of the first frame showing
///     the target; `stale` counts steps whose target had no pixels at the action (the previous
///     image stayed on screen), `never_shown` steps whose target never reached the glass.
final class SelfTest {
    private struct Step {
        let start: UInt64
        let target: ImageFile
        /// Target pixels were on screen in the frame rendered by the action itself.
        let immediate: Bool
        /// Main-thread time spent inside `perform(.next)` (key handling → frame committed).
        let mainThreadMs: Double
        var committed: UInt64?
        var presented: UInt64?
        var tier: Tier?
    }

    private let folder: URL
    private unowned let viewer: ViewerWindowController
    private var firstCommitWall: Double?
    private var firstPresent: (wall: Double, tier: Tier?)?
    private var droppedFrames = 0
    private var redraws = 0
    private var presentedFrames = 0
    private var phase = "launch"
    private var steps: [Step] = []
    private var results: [String: Any] = [:]

    init(folder: URL, viewer: ViewerWindowController) {
        self.folder = folder
        self.viewer = viewer
    }

    func start() {
        viewer.tracksFrames = true
        viewer.onFrameCommitted = { [weak self] record in self?.committed(record) }
        viewer.onFramePresented = { [weak self] record, time in self?.presented(record, time) }
        viewer.open([folder])
        // Wait for the first image on glass (or give up after 5 s), then for the listing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.phase == "launch" else { return }
            self.phase = "wait-listing"
            self.waitForListing()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.finish(timedOut: true) }
    }

    private func committed(_ record: FrameRecord) {
        if firstCommitWall == nil, record.file != nil { firstCommitWall = LaunchClock.wallNow() }
        guard let file = record.file else { return }
        for i in steps.indices where steps[i].committed == nil && steps[i].target == file && record.committed >= steps[i].start {
            steps[i].committed = record.committed
        }
    }

    private func presented(_ record: FrameRecord, _ time: CFTimeInterval) {
        guard time > 0 else {
            droppedFrames += 1
            // The first image frame was dropped: draw it again (a few times at most) so (a)
            // measures a frame on glass. Nothing is ever presented while the display sleeps.
            if firstPresent == nil, record.file != nil, redraws < 3 {
                redraws += 1
                viewer.redraw()
            }
            return
        }
        presentedFrames += 1
        guard let file = record.file else { return }
        if firstPresent == nil {
            let wall = LaunchClock.wallNow() - (CACurrentMediaTime() - time)
            firstPresent = (wall, record.tier)
            if phase == "launch" {
                phase = "wait-listing"
                waitForListing()
            }
        }
        let at = LaunchClock.traceNanos(fromMediaTime: time)
        for i in steps.indices where steps[i].presented == nil && steps[i].target == file && record.committed >= steps[i].start {
            steps[i].presented = at
            steps[i].tier = record.tier
        }
    }

    private func waitForListing() {
        if viewer.pipeline.files.count > 1 {
            // Let the prefetcher react to the open, as a user would take a moment before the first key.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.runNavigation() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.waitForListing() }
        }
    }

    private func runNavigation() {
        recordLaunch()
        phase = "nav_3hz"
        run(count: 40, interval: 1.0 / 3, isRepeat: false) { [weak self] in
            guard let self else { return }
            self.results["nav_3hz"] = self.summarize()
            self.steps.removeAll()
            self.phase = "nav_30hz"
            self.run(count: 20, interval: 1.0 / 30, isRepeat: true) { [weak self] in
                guard let self else { return }
                self.results["nav_30hz"] = self.summarize()
                self.finish(timedOut: false)
            }
        }
    }

    private func run(count: Int, interval: Double, isRepeat: Bool, then: @escaping () -> Void) {
        var done = 0
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard done < count, self.viewer.pipeline.index + 1 < self.viewer.pipeline.files.count else {
                timer.invalidate()
                // Give the last targets time to land.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { then() }
                return
            }
            let start = Trace.now()
            self.viewer.perform(.next, isRepeat: isRepeat && done > 0)
            let mainThread = Trace.ms(since: start)
            guard let target = self.viewer.pipeline.currentFile else { return }
            self.steps.append(Step(start: start, target: target, immediate: self.viewer.displayedFile == target,
                                   mainThreadMs: mainThread))
            // A frame committed inside perform() was reported before the step existed.
            if let last = self.viewer.lastCommittedFrame, last.file == target, last.committed >= start {
                self.steps[self.steps.count - 1].committed = last.committed
            }
            done += 1
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func recordLaunch() {
        let start = LaunchClock.processStartWall()
        func ms(_ wall: Double?) -> Any { wall.map { SelfTest.number(($0 - start) * 1000, digits: 1) } ?? NSNull() }
        results["launch_to_main_ms"] = ms(LaunchClock.mainWall)
        results["launch_to_first_commit_ms"] = ms(firstCommitWall)
        results["launch_to_first_frame_ms"] = ms(firstPresent?.wall)
        results["first_frame_tier"] = firstPresent?.tier.map { "\($0)" } ?? NSNull()
    }

    private func summarize() -> [String: Any] {
        func percentile(_ values: [Double], _ p: Double) -> Any {
            guard !values.isEmpty else { return NSNull() }
            let sorted = values.sorted()
            let rank = Int((p * Double(sorted.count - 1)).rounded())
            return SelfTest.number(sorted[rank])
        }
        let latencies = steps.compactMap { s in s.presented.map { Double($0 &- s.start) / 1e6 } }
        let commits = steps.compactMap { s in s.committed.map { Double($0 &- s.start) / 1e6 } }
        let immediate = steps.filter(\.immediate)
        let immediateLatencies = immediate.compactMap { s in s.presented.map { Double($0 &- s.start) / 1e6 } }
        var tiers: [String: Int] = [:]
        for step in steps { if let tier = step.tier { tiers["\(tier)", default: 0] += 1 } }
        return [
            "steps": steps.count,
            "presented": latencies.count,
            "stale": steps.count - immediate.count,
            "never_shown": steps.filter { $0.presented == nil }.count,
            "p50_ms": percentile(latencies, 0.5),
            "p95_ms": percentile(latencies, 0.95),
            "max_ms": latencies.max().map { SelfTest.number($0) } ?? NSNull(),
            "main_thread_p50_ms": percentile(steps.map(\.mainThreadMs), 0.5),
            "main_thread_max_ms": steps.map(\.mainThreadMs).max().map { SelfTest.number($0, digits: 3) } ?? NSNull(),
            "hit_p50_ms": percentile(immediateLatencies, 0.5),
            "commit_p50_ms": percentile(commits, 0.5),
            "first_tier": tiers,
        ]
    }

    /// Fixed-precision JSON number (JSONSerialization prints Doubles with binary noise).
    static func number(_ value: Double, digits: Int = 2) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.\(digits)f", value))
    }

    private func finish(timedOut: Bool) {
        guard phase != "done" else { return }
        if firstCommitWall != nil, results["launch_to_main_ms"] == nil { recordLaunch() }
        phase = "done"
        let stats = viewer.pipeline.stats
        results["selftest"] = "peekaboo"
        results["timed_out"] = timedOut
        results["files"] = viewer.pipeline.files.count
        results["frames_presented"] = presentedFrames
        results["frames_dropped"] = droppedFrames
        // Presentation needs an awake, unlocked display with the window on screen.
        results["display_awake"] = CGDisplayIsAsleep(CGMainDisplayID()) == 0
        results["window_visible"] = viewer.window?.occlusionState.contains(.visible) ?? false
        results["pipeline"] = ["hits": stats.hits, "misses": stats.misses, "decodes": stats.decodes,
                               "cached_mb": stats.cachedBytes >> 20]
        if let data = try? JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) {
            print(line)
        }
        fflush(stdout)
        exit(0)
    }
}
