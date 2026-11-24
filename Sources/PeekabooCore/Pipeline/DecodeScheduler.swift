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
    let lane: DecodeLane
    let targetLongSide: Int
    /// Estimated cost (ms), for the feasibility test.
    let estimateMs: Double
    var sequence: UInt64 = 0
}

struct DecodeOutcome: Sendable {
    let job: DecodeJob
    let result: Result<DecodedImage, Error>
    /// Metadata probed alongside the first decode of the file (nil when already known).
    let info: ImageInfo?
    let wallMs: Double
    /// Decodes running when this one started, itself included.
    let concurrency: Int
}

/// Thread-safe metadata cache shared by the main thread and the decode workers.
final class InfoStore: @unchecked Sendable {
    private var infos: [URL: ImageInfo] = [:]
    private let lock = NSLock()

    func get(_ url: URL) -> ImageInfo? { lock.lock(); defer { lock.unlock() }; return infos[url] }
    func set(_ url: URL, _ info: ImageInfo) { lock.lock(); infos[url] = info; lock.unlock() }
    func remove(_ url: URL) { lock.lock(); infos[url] = nil; lock.unlock() }
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
/// - visible jobs may use every decode lane (one more than the per-resource cap: the engines queue internally);
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
    private var runningByLane: [DecodeLane: Int] = [:]
    private var runningPrefetch = 0
    private var runningSweep = 0
    private var runningTotal = 0
    private var sequence: UInt64 = 0
    private var stopped = false
    private let limits: LaneLimits
    private let decoder: ImageDecoder
    private let pool: PixelBufferPool
    private let infos: InfoStore
    private let deliver: @Sendable (DecodeOutcome) -> Void

    init(decoder: ImageDecoder, pool: PixelBufferPool, infos: InfoStore, limits: LaneLimits,
         deliver: @escaping @Sendable (DecodeOutcome) -> Void) {
        self.decoder = decoder
        self.pool = pool
        self.infos = infos
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
            guard !stopped, let job = picked else { condition.unlock(); return }
            queued[job.key] = nil
            active[job.key] = Active(job: job, running: true)
            runningByLane[job.lane, default: 0] += 1
            runningTotal += 1
            if job.kind == .prefetch { runningPrefetch += 1 }
            if job.kind == .sweep { runningSweep += 1 }
            let concurrency = runningTotal
            condition.unlock()

            let outcome = run(job, concurrency: concurrency)

            condition.lock()
            active[job.key]?.running = false
            runningByLane[job.lane, default: 1] -= 1
            runningTotal -= 1
            if job.kind == .prefetch { runningPrefetch -= 1 }
            if job.kind == .sweep { runningSweep -= 1 }
            condition.broadcast()
            condition.unlock()
            deliver(outcome)
        }
    }

    private func run(_ job: DecodeJob, concurrency: Int) -> DecodeOutcome {
        if job.kind == .visible { pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0) }
        defer { if job.kind == .visible { pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0) } }
        let url = job.key.url
        let start = Trace.now()
        let interval = Trace.signposter.beginInterval("decode", id: Trace.signposter.makeSignpostID(),
                                                      "\(url.lastPathComponent) tier \(job.key.tier.rawValue)")
        let result = Result<DecodedImage, Error> {
            try autoreleasepool {
                try decoder.decode(url, tier: job.key.tier, targetLongSide: job.targetLongSide, pool: pool)
            }
        }
        Trace.signposter.endInterval("decode", interval)
        let wallMs = Trace.ms(since: start)
        // Metadata rides along with the first decode of a file (cheap: 0.07–0.6 ms; the source is warm).
        var info: ImageInfo?
        if infos.get(url) == nil, case .success = result, let probed = try? decoder.probe(url) {
            infos.set(url, probed)
            info = probed
        }
        return DecodeOutcome(job: job, result: result, info: info, wallMs: wallMs, concurrency: concurrency)
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
                guard inLane < limits.cap(job.lane) + 1 else { continue }
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
            guard runningByLane[job.lane, default: 0] < limits.cap(job.lane) else { continue }
            if better(job, than: best) { best = job }
        }
        if best != nil, foregroundBusyLocked { return nil }
        return best
    }
}
