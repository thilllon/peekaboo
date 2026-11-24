import Darwin
import Foundation

/// Identity of one decode: a tier of a file.
struct JobKey: Hashable, Sendable {
    let url: URL
    let tier: Tier
}

struct DecodeJob: Sendable {
    let key: JobKey
    let file: ImageFile
    var prio: Double
    var kind: JobKind
    /// Resource the job is charged to. Planned from the metadata the pipeline holds (before a file's first decode only
    /// its extension), then settled by the worker once it has probed the file.
    var lane: DecodeLane
    let targetLongSide: Int
    /// Estimated cost (ms), for the feasibility test.
    let estimateMs: Double
    var sequence: UInt64 = 0
    /// Serve the preview from QuickLook's thumbnail cache (sweep only).
    var quickLook = false
    /// Metadata the pipeline already holds for the file; nil before its first decode (the worker probes it).
    var info: ImageInfo?
}

struct DecodeOutcome: Sendable {
    let job: DecodeJob
    let result: Result<DecodedImage, Error>
    /// Metadata of the file: the job's, or probed by the worker before the decode (nil only when that probe failed).
    let info: ImageInfo?
    let wallMs: Double
    /// Decodes running when this one started, itself included.
    let concurrency: Int
}

/// Lane limits (docs/DESIGN.md §3 "Lanes").
struct LaneLimits: Sendable, Equatable {
    /// Decode lanes (dedicated threads, QoS user-initiated; visible jobs run at user-interactive).
    var decodeLanes = 6
    /// Lanes prefetch may never occupy (kept for the visible image).
    var reservedLanes = 1
    /// Concurrent jobs per decode resource.
    var hardware = 2
    var general = 4
    /// Background sweep lanes (QoS utility: efficiency cores).
    var sweepLanes = 4

    func cap(_ lane: DecodeLane) -> Int {
        switch lane {
        case .hardware: return hardware
        case .general: return general
        case .cpu: return decodeLanes
        }
    }
}

/// Earliest-deadline-first job queue served by a fixed set of worker threads.
///
/// The main thread replaces the queued set on every replan (`submit`), which cancels queued work instantly;
/// running decodes cannot be aborted and finish normally. Workers pick the best runnable job under the lock:
/// - visible jobs may use every decode lane, including the reserved one (and one slot above the CPU/general caps);
/// - prefetch waits while any visible job is queued or running (foreground gate), never holds the reserved
///   lane and respects the per-resource caps (hardware engines ≤ 2, general ImageIO ≤ 4, CPU fills the rest);
/// - sweep jobs run on their own utility lanes only while no decode-lane work is queued or gated.
final class DecodeScheduler: @unchecked Sendable {
    private struct Active {
        var job: DecodeJob
        var running: Bool
    }

    private let condition = NSCondition()
    private var queued: [JobKey: DecodeJob] = [:]
    private var active: [JobKey: Active] = [:]
    private var visibleKeys: Set<JobKey> = []
    /// Jobs per resource on the decode lanes, and on the sweep lanes (counted apart so a starved utility thread
    /// never holds capacity the visible image's neighbours need).
    private var runningByLane: [DecodeLane: Int] = [:]
    private var sweepByLane: [DecodeLane: Int] = [:]
    private var runningPrefetch = 0
    private var runningSweep = 0
    private var runningTotal = 0
    private var sequence: UInt64 = 0
    private var stopped = false
    private let limits: LaneLimits
    private let decoder: ImageDecoder
    private let pool: PixelBufferPool
    private let deliver: @Sendable (DecodeOutcome) -> Void

    init(decoder: ImageDecoder, pool: PixelBufferPool, limits: LaneLimits,
         deliver: @escaping @Sendable (DecodeOutcome) -> Void) {
        self.decoder = decoder
        self.pool = pool
        self.limits = limits
        self.deliver = deliver
        for n in 0..<max(1, limits.decodeLanes) {
            spawn(name: "peekaboo.decode.\(n)", qos: .userInitiated, sweep: false)
        }
        for n in 0..<max(0, limits.sweepLanes) {
            spawn(name: "peekaboo.sweep.\(n)", qos: .utility, sweep: true)
        }
    }

    /// Stop the workers (they exit after their current job).
    func stop() {
        condition.lock()
        stopped = true
        queued.removeAll()
        condition.broadcast()
        condition.unlock()
    }

    // MARK: Main-thread side

    struct Snapshot {
        var busy: Set<JobKey>
        var runningWorkMs: Double
        var decodeBacklog: Bool
    }

    /// Keys running or awaiting delivery, the estimated work on the decode lanes and whether any is queued.
    func snapshot() -> Snapshot {
        condition.lock(); defer { condition.unlock() }
        var work = 0.0
        for entry in active.values where entry.running && entry.job.kind != .sweep { work += entry.job.estimateMs }
        let backlog = queued.values.contains { $0.kind != .sweep }
        return Snapshot(busy: Set(active.keys), runningWorkMs: work, decodeBacklog: backlog)
    }

    /// Replace the queued set with `jobs` (keys already running or awaiting delivery are skipped).
    /// `visible` names the visible image's tiers: while one of them runs, prefetch is gated.
    func submit(_ jobs: [DecodeJob], visible: Set<JobKey>) {
        condition.lock()
        var next: [JobKey: DecodeJob] = [:]
        next.reserveCapacity(jobs.count)
        for var job in jobs where active[job.key] == nil && next[job.key] == nil {
            if let old = queued[job.key] {
                job.sequence = old.sequence
            } else {
                sequence &+= 1
                job.sequence = sequence
            }
            next[job.key] = job
        }
        queued = next
        visibleKeys = visible
        condition.broadcast()
        condition.unlock()
    }

    /// The main thread consumed the outcome of `key`.
    func acknowledge(_ key: JobKey) {
        condition.lock()
        active[key] = nil
        condition.unlock()
    }

    var queuedCount: Int { condition.lock(); defer { condition.unlock() }; return queued.count }

    var debugState: String {
        condition.lock(); defer { condition.unlock() }
        let q = queued.values.map { "\($0.key.url.lastPathComponent):\($0.key.tier.rawValue):\($0.kind):\($0.lane)" }
        return "queued=\(q) active=\(active.count) running=\(runningTotal) lanes=\(runningByLane) sweepLanes=\(sweepByLane) prefetch=\(runningPrefetch) sweep=\(runningSweep)"
    }

    // MARK: Workers

    private func spawn(name: String, qos: QualityOfService, sweep: Bool) {
        let thread = Thread { [self] in self.workerLoop(sweep: sweep) }
        thread.name = name
        thread.qualityOfService = qos
        thread.stackSize = 1 << 20
        thread.start()
    }

    private func workerLoop(sweep: Bool) {
        while true {
            condition.lock()
            var picked: DecodeJob?
            while !stopped {
                picked = sweep ? pickSweepLocked() : pickDecodeLocked()
                if picked != nil { break }
                condition.wait()
            }
            guard !stopped, var job = picked else { condition.unlock(); return }
            queued[job.key] = nil
            active[job.key] = Active(job: job, running: true)
            chargeLocked(job, 1)
            runningTotal += 1
            if job.kind == .prefetch { runningPrefetch += 1 }
            if job.kind == .sweep { runningSweep += 1 }
            let concurrency = runningTotal
            condition.unlock()

            let outcome = run(&job, concurrency: concurrency)

            condition.lock()
            active[job.key]?.running = false
            chargeLocked(job, -1)
            runningTotal -= 1
            if job.kind == .prefetch { runningPrefetch -= 1 }
            if job.kind == .sweep { runningSweep -= 1 }
            condition.broadcast()
            condition.unlock()
            deliver(outcome)
        }
    }

    /// Count `job` in (`delta` 1) or out of (−1) its lane: the sweep lanes are counted apart.
    private func chargeLocked(_ job: DecodeJob, _ delta: Int) {
        if job.kind == .sweep {
            sweepByLane[job.lane, default: 0] += delta
        } else {
            runningByLane[job.lane, default: 0] += delta
        }
    }

    /// Move a running job to the lane its decode path uses (it may briefly exceed that lane's cap; later picks
    /// respect the corrected counts).
    private func recharge(_ job: inout DecodeJob, to lane: DecodeLane) {
        condition.lock()
        chargeLocked(job, -1)
        job.lane = lane
        chargeLocked(job, 1)
        active[job.key]?.job.lane = lane
        condition.broadcast()  // the lane it left has room now
        condition.unlock()
    }

    private func run(_ job: inout DecodeJob, concurrency: Int) -> DecodeOutcome {
        if job.kind == .visible { pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0) }
        defer { if job.kind == .visible { pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0) } }
        let url = job.key.url
        // First decode of the file: read its metadata before decoding (0.03–0.09 ms; the decode reuses the parse), so
        // the outcome carries it to the planner, and charge the job to the lane its decode path really takes. The
        // planner only knew the extension: a progressive JPEG decodes with libjpeg-turbo on a CPU lane, not on the
        // two hardware engines it would otherwise hold for 300 ms.
        if job.info == nil, let info = try? decoder.probe(url) {
            job.info = info
            if !job.quickLook {
                let lane = decoder.lane(for: url, info: info, tier: job.key.tier)
                if lane != job.lane { recharge(&job, to: lane) }
            }
        }
        let start = Trace.now()
        let tier = job.key.tier
        let interval = Trace.signposter.beginInterval("decode", id: Trace.signposter.makeSignpostID(),
                                                      "\(url.lastPathComponent) tier \(tier.rawValue)")
        let result: Result<DecodedImage, Error>
        if job.quickLook {
            // Full size for layout comes from the metadata; QuickLook applies the EXIF orientation itself.
            let preview = autoreleasepool {
                QuickLookPreview.preview(url, longSide: job.targetLongSide, info: job.info, pool: pool,
                                         timeout: job.kind == .visible ? 0.5 : 2)
            }
            result = preview.map { .success($0) } ?? .failure(QuickLookPreview.Miss())
        } else {
            result = Result {
                try autoreleasepool {
                    try decoder.decode(url, tier: job.key.tier, targetLongSide: job.targetLongSide, pool: pool)
                }
            }
        }
        Trace.signposter.endInterval("decode", interval)
        return DecodeOutcome(job: job, result: result, info: job.info, wallMs: Trace.ms(since: start),
                             concurrency: concurrency)
    }

    private var foregroundBusyLocked: Bool {
        if queued.values.contains(where: { $0.kind == .visible }) { return true }
        for key in visibleKeys where active[key]?.running == true { return true }
        return false
    }

    private func better(_ a: DecodeJob, than b: DecodeJob?) -> Bool {
        guard let b else { return true }
        return a.prio < b.prio || (a.prio == b.prio && a.sequence < b.sequence)
    }

    private func pickDecodeLocked() -> DecodeJob? {
        var best: DecodeJob?
        var gated: Bool?
        let prefetchRoom = runningPrefetch < max(0, limits.decodeLanes - limits.reservedLanes)
        for job in queued.values where job.kind != .sweep {
            let inLane = runningByLane[job.lane, default: 0]
            if job.kind == .visible {
                // The hardware engines are a hard limit (they serialise anyway); CPU-bound ImageIO and libjpeg-turbo
                // work may exceed its cap by one so the visible image never queues behind prefetch.
                guard inLane < limits.cap(job.lane) + (job.lane == .hardware ? 0 : 1) else { continue }
            } else {
                guard prefetchRoom, inLane < limits.cap(job.lane) else { continue }
                if gated == nil { gated = foregroundBusyLocked }
                if gated == true { continue }
            }
            if better(job, than: best) { best = job }
        }
        return best
    }

    private func pickSweepLocked() -> DecodeJob? {
        guard runningSweep < limits.sweepLanes else { return nil }
        var best: DecodeJob?
        for job in queued.values {
            if job.kind != .sweep { return nil }  // decode-lane work first
            // At most one sweep job on the hardware engines: they belong to the visible image and its neighbours.
            let cap = job.lane == .hardware ? 1 : limits.sweepLanes
            guard sweepByLane[job.lane, default: 0] < cap else { continue }
            if better(job, than: best) { best = job }
        }
        if best != nil, foregroundBusyLocked { return nil }
        return best
    }
}
