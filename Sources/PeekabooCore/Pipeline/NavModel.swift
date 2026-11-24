import Foundation

/// Constants of the P4 predictive scheduler (docs/DESIGN.md §3; research a2 §9).
public struct PrefetchTuning: Sendable, Equatable {
    /// `I_eff` below this is skimming (≈ 8 images/s).
    public var skimIntervalMs = 120.0
    /// Adaptive dwell before the visible screen tier starts while skimming: clamp(k·EMA, min, max).
    public var dwellMinMs = 40.0
    public var dwellMaxMs = 120.0
    public var dwellK = 1.5
    /// Screen-tier window ahead: clamp(2 + ⌈lookMs / I_eff⌉, 2, max); behind: fixed.
    public var screenLookMs = 250.0
    public var screenMaxAhead = 12
    public var screenBehind = 2
    /// Preview window ahead: clamp(4 + ⌈lookMs / I_eff⌉, 4, max); behind: fixed.
    public var previewLookMs = 1000.0
    public var previewMaxAhead = 48
    public var previewBehind = 4
    /// Prefetch horizons: candidates with a larger ETA are not scheduled.
    public var screenHorizonMs = 2500.0
    public var previewHorizonMs = 1500.0
    /// Extra ETA of images behind the direction of travel (reversal cost); behind images use I ≥ 300 ms.
    public var reversalMs = 600.0
    public var behindMinIntervalMs = 300.0
    /// Speculative full resolution for the current image after this dwell, if estimated ≤ `fullMaxCostMs`. While the
    /// user steps at a steady rhythm the dwell is `fullDwellRhythm`·EMA instead (at most `fullDwellMaxMs`): it must
    /// mean "stays longer than usual", or every image's full tier is decoded just before the user leaves it.
    public var fullDwellMs = 400.0
    public var fullMaxCostMs = 150.0
    public var fullDwellRhythm = 1.5
    public var fullDwellMaxMs = 1500.0
    /// Processor-sharing slowdown per extra concurrent decode (measured).
    public var alpha = 0.12
    /// Folder-wide background preview sweep (E-cores), in ring order around the cursor.
    public var sweepEnabled = true
    public var sweepBatch = 24
    public var sweepRadius = Int.max
    /// The ring scan (up to 2×1024 files) is left out of the passes within this long after a navigation, so the key
    /// press does not wait for it, and is not repeated within `sweepRescanMs` once a scan from the same cursor found
    /// everything there was to add (its jobs are planned again instead).
    public var sweepAfterNavMs = 20.0
    public var sweepRescanMs = 250.0
    /// A preview counts as cheap (sweepable, worth decoding before the screen tier) when its estimate is at most
    /// this many ms or at most `cheapPreviewRatio` of the screen-tier estimate.
    public var cheapPreviewMs = 8.0
    public var cheapPreviewRatio = 0.25
    /// Inside the screen-tier window, prefetch a neighbour's preview only when it is cheap (false = always, the
    /// previous behaviour; kept for A/B runs of `peekaboo-bench pipeline --all-previews`).
    public var screenWindowCheapPreviewsOnly = true
    /// Files on disk change without a directory event while written in place (a copy in progress, an editor saving
    /// over the file). A file written less than `settleMs` before it was decoded is rechecked every `recheckMs` until
    /// it is unchanged and that old; its failures are retried rather than reported meanwhile. Changed tiers are
    /// decoded again once nothing has been written for `quietMs`.
    public var settleMs = 2000.0
    public var quietMs = 500.0
    public var recheckMs = 500.0

    public init() {}

    /// Adaptive dwell for an interval EMA.
    public func dwellMs(ema: Double) -> Double { min(max(dwellK * ema, dwellMinMs), dwellMaxMs) }

    /// Dwell on the current image before its speculative full decode. Relative to the rhythm while the user steps
    /// through the folder; `fullDwellMs` after a jump (no rhythm yet) and while toggling A/B (both full tiers stay
    /// pinned, so they are never wasted).
    public func fullDwellMs(for nav: NavModel) -> Double {
        guard !nav.history.isEmpty, !nav.isAB else { return fullDwellMs }
        return min(max(fullDwellMs, fullDwellRhythm * nav.emaIntervalMs), max(fullDwellMs, fullDwellMaxMs))
    }
}

/// Navigation model: cursor, direction, EMA of the inter-navigation interval and A/B toggle detection.
///
/// `I_eff = max(EMA, now − lastNav)`: the longer the user dwells, the slower they are assumed to move.
public struct NavModel: Sendable, Equatable {
    public private(set) var cursor = 0
    /// +1 forward, −1 backward.
    public private(set) var direction = 1
    public private(set) var emaIntervalMs = 1000.0
    /// `Trace.now()` of the last navigation (0 = never navigated).
    public private(set) var lastNav: UInt64 = 0
    /// Last unit steps (±1), newest last, at most 6.
    public private(set) var history: [Int8] = []
    /// The last navigation came from key auto-repeat.
    public private(set) var lastWasRepeat = false
    /// Increments on every navigation (generation counter of the visible image).
    public private(set) var epoch: UInt64 = 0

    public init() {}

    public mutating func navigate(to j: Int, now: UInt64, count: Int, isRepeat: Bool) {
        let step = j - cursor
        if lastNav != 0 && abs(step) == 1 {
            direction = step
            let interval = min(Double(now &- lastNav) / 1e6, 2000)
            emaIntervalMs = 0.5 * emaIntervalMs + 0.5 * interval
            history.append(Int8(step))
            if history.count > 6 { history.removeFirst() }
        } else if step != 0 || lastNav == 0 {
            // Home/End, random jump or first open: unknown velocity.
            emaIntervalMs = 1000
            direction = (count > 1 && j == count - 1) ? -1 : 1
            history.removeAll()
        }
        cursor = j
        lastNav = now
        lastWasRepeat = isRepeat
        epoch &+= 1
    }

    /// Same image, new index (the browsing set changed around it).
    public mutating func reindex(to j: Int) { cursor = j }

    public func msSinceNav(now: UInt64) -> Double { lastNav == 0 ? .infinity : Double(now &- lastNav) / 1e6 }

    public func iEff(now: UInt64) -> Double { max(emaIntervalMs, msSinceNav(now: now)) }

    /// Skimming: fast navigation (or key auto-repeat that has not paused).
    public func isSkimming(now: UInt64, tuning: PrefetchTuning) -> Bool {
        let since = msSinceNav(now: now)
        return max(emaIntervalMs, since) < tuning.skimIntervalMs || (lastWasRepeat && since < tuning.skimIntervalMs)
    }

    public var isAB: Bool {
        let n = history.count
        return n >= 3 && history[n - 1] == -history[n - 2] && history[n - 2] == -history[n - 3]
    }

    /// The other image of an A/B toggle.
    public var abPartner: Int? {
        guard isAB, let last = history.last else { return nil }
        return cursor - Int(last)
    }

    /// Predicted milliseconds until the user arrives at image `j`.
    public func eta(_ j: Int, now: UInt64, tuning: PrefetchTuning) -> Double {
        let distance = abs(j - cursor)
        if distance == 0 { return 0 }
        let ie = iEff(now: now)
        if let partner = abPartner, j == partner { return ie }
        if (j - cursor).signum() == direction { return Double(distance) * ie }
        return Double(distance) * max(ie, tuning.behindMinIntervalMs) + tuning.reversalMs
    }
}

/// Which pool of lanes a job runs on and how it is gated.
enum JobKind: Int, Sendable, Comparable {
    /// The visible image (any of the decode lanes, including the reserved one; gates prefetch).
    case visible = 0
    /// Prefetch inside the velocity windows (decode lanes minus the reserved one).
    case prefetch = 1
    /// Folder-wide background preview sweep (utility QoS lanes).
    case sweep = 2

    static func < (a: JobKind, b: JobKind) -> Bool { a.rawValue < b.rawValue }
}

struct PlannedJob: Sendable, Hashable {
    let index: Int
    let tier: Tier
    /// Deadline in ms (earliest first); negative for the visible image.
    let prio: Double
    let kind: JobKind
    /// Sweep job served from QuickLook's thumbnail cache instead of our own (expensive) preview decode.
    var quickLook = false
}

struct Plan: Sendable {
    var jobs: [PlannedJob] = []
    /// Milliseconds from now at which the plan changes by itself (dwell end, skim end, full-res dwell).
    var wakeAfterMs: Double?
    /// Indices that entered the preview / screen windows (read-ahead hints).
    var previewWindow: [Int] = []
    var screenWindow: [Int] = []
    /// The sweep's ring scan ran this pass, and it reached its radius before the batch filled (its jobs are then all
    /// there is to add from this cursor).
    var sweepScanned = false
    var sweepExhausted = false

    mutating func wake(after ms: Double) {
        let ms = max(ms, 1)
        wakeAfterMs = min(wakeAfterMs ?? ms, ms)
    }
}

/// Inputs of one planning pass, as closures over the pipeline's main-thread state.
struct PlanContext {
    var count: Int
    var listingReady: Bool
    /// Tier is in the cache (a cached `.full` also satisfies `.screen`).
    var cached: (Int, Tier) -> Bool
    /// Tier is running, awaiting delivery, or failed before: do not plan it again.
    var busy: (Int, Tier) -> Bool
    var estimate: (Int, Tier) -> Double
    var cheapPreview: (Int) -> Bool
    /// QuickLook may serve this file's preview (its own preview is not cheap): the sweep and the visible image ask it.
    var quickLookSweep: (Int) -> Bool = { _ in false }
    /// The view asked for full resolution of the current image.
    var fullRequested: Bool
    /// Sum of the estimates of decodes running on the decode lanes.
    var runningWorkMs: Double
    /// Decode-lane work is queued (the sweep yields to it).
    var decodeBacklog: Bool
    /// Upper bound on sweep jobs this pass (preview budget headroom).
    var sweepSlots: Int
    var sweepPaused: Bool
    var decodeLanes: Int
    var reservedLanes: Int
    /// Sweep jobs of an exhausted scan from this cursor moments ago: plan them again instead of scanning.
    var sweepReuse: [PlannedJob]? = nil
}

/// The pure body of the P4 scheduler's replan (research a2 §4): what should be queued right now.
/// Earliest deadline first; a preview runs just before the screen tier of the same image.
func planPrefetch(_ nav: NavModel, now: UInt64, tuning t: PrefetchTuning, context c: PlanContext) -> Plan {
    var plan = Plan()
    guard c.count > 0 else { return plan }
    let i = min(max(nav.cursor, 0), c.count - 1)
    let since = nav.msSinceNav(now: now)
    let ie = max(nav.iEff(now: now), 1)
    let skim = nav.isSkimming(now: now, tuning: t)
    let inRange = { (j: Int) in j >= 0 && j < c.count }
    let sharp = { (j: Int) in c.cached(j, .screen) || c.cached(j, .full) }

    // Visible image.
    if !sharp(i) {
        if !c.cached(i, .preview) && !c.busy(i, .preview) {
            if c.cheapPreview(i) {
                plan.jobs.append(PlannedJob(index: i, tier: .preview, prio: -3, kind: .visible))
            } else if c.quickLookSweep(i) {
                // Our own preview would cost about as much as the screen tier: probe QuickLook's cache in parallel
                // (a hit is ≈ 1 ms, for files seen before, even by other apps).
                plan.jobs.append(PlannedJob(index: i, tier: .preview, prio: -3, kind: .visible, quickLook: true))
            }
        }
        if !c.busy(i, .screen) && !c.busy(i, .full) {
            let dwell = t.dwellMs(ema: nav.emaIntervalMs)
            if !skim || since >= dwell {
                plan.jobs.append(PlannedJob(index: i, tier: .screen, prio: -2, kind: .visible))
            } else {
                plan.wake(after: dwell - since)
            }
        }
    }
    if skim && since.isFinite { plan.wake(after: t.skimIntervalMs - since) }
    // Zoom intent: full resolution first among prefetch work (it does not gate the neighbours).
    if c.fullRequested && !c.cached(i, .full) && !c.busy(i, .full) {
        plan.jobs.append(PlannedJob(index: i, tier: .full, prio: -1, kind: .prefetch))
    }
    guard c.listingReady else { return plan }

    // Speculative full resolution for cheap formats once the user dwells (longer than their rhythm).
    let fullDwell = t.fullDwellMs(for: nav)
    if !skim && !c.fullRequested && c.estimate(i, .full) <= t.fullMaxCostMs {
        if since >= fullDwell {
            if !c.cached(i, .full) && !c.busy(i, .full) {
                plan.jobs.append(PlannedJob(index: i, tier: .full, prio: t.fullDwellMs, kind: .prefetch))
            }
            if let p = nav.abPartner, inRange(p), !c.cached(p, .full), !c.busy(p, .full),
               c.estimate(p, .full) <= t.fullMaxCostMs {
                plan.jobs.append(PlannedJob(index: p, tier: .full, prio: t.fullDwellMs + 50, kind: .prefetch))
            }
        } else if since.isFinite {
            plan.wake(after: fullDwell - since)
        }
    }

    // Velocity-scaled windows, deadline ordered.
    let k1 = min(max(2 + Int((t.screenLookMs / ie).rounded(.up)), 2), t.screenMaxAhead)
    let k0 = min(max(4 + Int((t.previewLookMs / ie).rounded(.up)), 4), t.previewMaxAhead)
    var candidates: [(eta: Double, j: Int, tier: Tier)] = []
    candidates.reserveCapacity(2 * (k0 + k1))
    let reach = max(k0, k1, t.previewBehind, t.screenBehind)
    if reach >= 1 {
        for k in 1...reach {
            for (j, behind) in [(i + nav.direction * k, false), (i - nav.direction * k, true)] where inRange(j) {
                let e = nav.eta(j, now: now, tuning: t)
                let inScreen = k <= (behind ? t.screenBehind : k1) && e <= t.screenHorizonMs
                let inPreview = k <= (behind ? t.previewBehind : k0) && e <= t.previewHorizonMs
                if inScreen { plan.screenWindow.append(j) } else if inPreview { plan.previewWindow.append(j) }
                if inScreen && !sharp(j) && !c.busy(j, .screen) { candidates.append((e, j, .screen)) }
                // Inside the screen window a preview only helps when it is cheap (embedded thumbnail): an expensive
                // one (a reduced hardware decode) costs as much as the screen tier, lands after it and takes the
                // engine slot another neighbour's screen tier needed. While skimming the preview is what is shown.
                let previewWorthIt = !inScreen || skim || !t.screenWindowCheapPreviewsOnly || c.cheapPreview(j)
                if inPreview && previewWorthIt && !sharp(j) && !c.cached(j, .preview) && !c.busy(j, .preview) {
                    candidates.append((e - 0.01, j, .preview))
                }
            }
        }
    }
    candidates.sort { $0.eta < $1.eta || ($0.eta == $1.eta && $0.j < $1.j) }
    var work = c.runningWorkMs
    let lanes = Double(max(1, c.decodeLanes - c.reservedLanes))
    let slow = 1 + t.alpha * Double(max(0, c.decodeLanes - 1))
    for candidate in candidates {
        let cost = c.estimate(candidate.j, candidate.tier)
        // Feasibility: a screen tier that would land after the user has passed the image is waste.
        if candidate.tier == .screen && skim && work / lanes + cost * slow > candidate.eta + ie { continue }
        work += cost
        plan.jobs.append(PlannedJob(index: candidate.j, tier: candidate.tier, prio: candidate.eta, kind: .prefetch))
    }

    // Folder-wide preview sweep on the utility lanes, ring order, cheap previews only.
    if t.sweepEnabled && !skim && !c.decodeBacklog && !c.sweepPaused && c.sweepSlots > 0 {
        let limit = min(t.sweepBatch, c.sweepSlots)
        let planned = Set(plan.jobs.lazy.filter { $0.tier == .preview }.map(\.index))
        let open = { (j: Int) in !planned.contains(j) && !sharp(j) && !c.cached(j, .preview) && !c.busy(j, .preview) }
        if since < t.sweepAfterNavMs {
            plan.wake(after: t.sweepAfterNavMs - since)
        } else if let reuse = c.sweepReuse {
            for job in reuse.prefix(limit) where inRange(job.index) && open(job.index) { plan.jobs.append(job) }
        } else {
            plan.sweepScanned = true
            var added = 0, r = 1
            // Bounded ring scan keeps the pass O(1) on huge folders (the preview budget is far smaller anyway).
            let radius = min(t.sweepRadius, 1024)
            while added < limit && r < c.count && r <= radius {
                for j in [i + nav.direction * r, i - nav.direction * r] where inRange(j) && added < limit {
                    guard open(j) else { continue }
                    if c.cheapPreview(j) {
                        plan.jobs.append(PlannedJob(index: j, tier: .preview, prio: 1e6 + Double(r), kind: .sweep))
                    } else if c.quickLookSweep(j) {
                        plan.jobs.append(PlannedJob(index: j, tier: .preview, prio: 1e6 + Double(r), kind: .sweep,
                                                    quickLook: true))
                    } else {
                        continue
                    }
                    added += 1
                }
                r += 1
            }
            plan.sweepExhausted = added < limit
        }
    }
    return plan
}
