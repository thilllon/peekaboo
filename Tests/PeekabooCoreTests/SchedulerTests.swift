import XCTest
@testable import PeekabooCore

/// The pure planner and navigation model (deterministic: synthetic clocks, closures for the cache).
final class SchedulerTests: XCTestCase {
    private let ms: UInt64 = 1_000_000

    /// A model that arrived at `cursor` by unit steps of `intervalMs`; returns the model and the time of the last step.
    private func steady(_ cursor: Int, steps: Int = 8, intervalMs: Double, direction: Int = 1,
                        isRepeat: Bool = false, count: Int = 2000) -> (NavModel, UInt64) {
        var nav = NavModel()
        var now: UInt64 = 10_000 * ms
        var position = cursor - direction * steps
        nav.navigate(to: position, now: now, count: count, isRepeat: false)
        for _ in 0..<steps {
            now += UInt64(intervalMs * 1e6)
            position += direction
            nav.navigate(to: position, now: now, count: count, isRepeat: isRepeat)
        }
        return (nav, now)
    }

    private func context(count: Int = 2000, cached: Set<Int> = [], costs: [Tier: Double] = [.preview: 4, .screen: 30, .full: 60],
                         sweepSlots: Int = 0) -> PlanContext {
        PlanContext(count: count, listingReady: true,
                    cached: { j, t in t == .screen && cached.contains(j) }, busy: { _, _ in false },
                    estimate: { _, t in costs[t]! }, cheapPreview: { _ in true }, fullRequested: false,
                    runningWorkMs: 0, decodeBacklog: false, sweepSlots: sweepSlots, sweepPaused: false,
                    decodeLanes: 6, reservedLanes: 1)
    }

    private func offsets(_ plan: Plan, _ tier: Tier, cursor: Int, kind: JobKind = .prefetch) -> [Int] {
        plan.jobs.filter { $0.tier == tier && $0.kind == kind }.map { $0.index - cursor }
    }

    func testSteadyWindows() {
        let (nav, now) = steady(100, intervalMs: 1000)
        XCTAssertEqual(nav.emaIntervalMs, 1000, accuracy: 1)
        let plan = planPrefetch(nav, now: now + ms, tuning: PrefetchTuning(), context: context())
        // Visible image: preview then screen, both ahead of all prefetch.
        XCTAssertEqual(plan.jobs.filter { $0.kind == .visible }.map(\.tier), [.preview, .screen])
        // I_eff = 1 s: screen ahead K1 = 3 but ETA ≤ 2.5 s keeps +1, +2; behind −1 (1.6 s); preview +1 (1 s ≤ 1.5 s).
        XCTAssertEqual(Set(offsets(plan, .screen, cursor: 100)), [1, 2, -1])
        XCTAssertEqual(Set(offsets(plan, .preview, cursor: 100)), [1])
    }

    /// An expensive preview (a reduced hardware decode, as costly as the screen tier) is not prefetched for a neighbour
    /// whose screen tier is planned: it would land after it and take an engine slot. Outside the screen window, and
    /// while skimming, previews stay; `screenWindowCheapPreviewsOnly = false` restores the old rule.
    func testExpensivePreviewsAreNotPrefetchedInsideTheScreenWindow() {
        let (nav, now) = steady(100, steps: 12, intervalMs: 150)
        var c = context()
        c.cheapPreview = { _ in false }
        let plan = planPrefetch(nav, now: now + ms, tuning: PrefetchTuning(), context: c)
        let screen = Set(offsets(plan, .screen, cursor: 100))
        let previews = Set(offsets(plan, .preview, cursor: 100))
        XCTAssertFalse(screen.isEmpty)
        XCTAssertTrue(previews.isDisjoint(with: screen), "previews \(previews) overlap screen \(screen)")
        XCTAssertFalse(previews.isEmpty, "previews beyond the screen window are still prefetched")

        var legacy = PrefetchTuning()
        legacy.screenWindowCheapPreviewsOnly = false
        let old = planPrefetch(nav, now: now + ms, tuning: legacy, context: c)
        XCTAssertTrue(Set(offsets(old, .preview, cursor: 100)).isSuperset(of: screen.filter { $0 > 0 }))

        // Skimming: the preview is what will be shown, expensive or not.
        let (skimNav, skimNow) = steady(100, steps: 12, intervalMs: 33, isRepeat: true)
        let skim = planPrefetch(skimNav, now: skimNow + ms, tuning: PrefetchTuning(), context: c)
        XCTAssertTrue(offsets(skim, .preview, cursor: 100).contains(1))
    }

    func testFastWindowsGrowWithVelocity() {
        let (nav, now) = steady(100, steps: 12, intervalMs: 150)
        let plan = planPrefetch(nav, now: now + ms, tuning: PrefetchTuning(), context: context())
        let ie = nav.iEff(now: now + ms)
        let k1 = min(max(2 + Int((250 / ie).rounded(.up)), 2), 12)
        let k0 = min(max(4 + Int((1000 / ie).rounded(.up)), 4), 48)
        let screenAhead = offsets(plan, .screen, cursor: 100).filter { $0 > 0 }
        let previewAhead = offsets(plan, .preview, cursor: 100).filter { $0 > 0 }
        // Windows are bounded by count (K1/K0) and by the ETA horizons (2.5 s / 1.5 s).
        XCTAssertEqual(screenAhead.max(), min(k1, Int(2500 / ie)))
        XCTAssertEqual(previewAhead.max(), min(k0, Int(1500 / ie)))
        XCTAssertGreaterThan(k0, 4)
        XCTAssertLessThanOrEqual(offsets(plan, .screen, cursor: 100).filter { $0 < 0 }.count, 2)
        XCTAssertLessThanOrEqual(offsets(plan, .preview, cursor: 100).filter { $0 < 0 }.count, 4)
    }

    func testEarliestDeadlineFirstPreviewBeforeScreen() {
        let (nav, now) = steady(100, steps: 12, intervalMs: 150)
        let plan = planPrefetch(nav, now: now + ms, tuning: PrefetchTuning(), context: context())
        let prefetch = plan.jobs.filter { $0.kind == .prefetch }
        XCTAssertEqual(prefetch.map(\.prio), prefetch.map(\.prio).sorted(), "prefetch must be deadline ordered")
        for job in prefetch where job.tier == .screen {
            guard let preview = prefetch.firstIndex(where: { $0.index == job.index && $0.tier == .preview }) else { continue }
            XCTAssertLessThan(preview, prefetch.firstIndex(of: job)!, "preview of \(job.index) must precede its screen tier")
        }
    }

    func testSkimmingDefersVisibleScreenUntilDwell() {
        let (nav, now) = steady(100, steps: 20, intervalMs: 33, isRepeat: true)
        let tuning = PrefetchTuning()
        XCTAssertTrue(nav.isSkimming(now: now + 5 * ms, tuning: tuning))
        let during = planPrefetch(nav, now: now + 5 * ms, tuning: tuning, context: context())
        XCTAssertEqual(during.jobs.filter { $0.kind == .visible }.map(\.tier), [.preview], "skimming shows previews only")
        let dwell = tuning.dwellMs(ema: nav.emaIntervalMs)
        XCTAssertEqual(dwell, min(max(1.5 * nav.emaIntervalMs, 40), 120), accuracy: 0.001)
        XCTAssertEqual(during.wakeAfterMs ?? 0, dwell - 5, accuracy: 0.5)
        let after = planPrefetch(nav, now: now + UInt64((dwell + 1) * 1e6), tuning: tuning, context: context())
        XCTAssertTrue(after.jobs.contains { $0.kind == .visible && $0.tier == .screen })
    }

    func testFeasibilityLeadsTheTarget() {
        // 30/s with a 150 ms screen tier: the next images are passed before their decode could finish.
        let (nav, now) = steady(100, steps: 20, intervalMs: 33, isRepeat: true)
        let plan = planPrefetch(nav, now: now + 5 * ms, tuning: PrefetchTuning(),
                                context: context(costs: [.preview: 10, .screen: 150, .full: 400]))
        let screen = offsets(plan, .screen, cursor: 100).filter { $0 > 0 }.sorted()
        XCTAssertFalse(screen.contains(1))
        XCTAssertFalse(screen.contains(2))
        XCTAssertFalse(screen.isEmpty, "screen tier should aim at images reached as their decode finishes")
        XCTAssertGreaterThanOrEqual(screen.first ?? 0, 4)
        // Previews still cover the whole fast window.
        XCTAssertGreaterThan(offsets(plan, .preview, cursor: 100).filter { $0 > 0 }.count, 20)
    }

    func testABToggleDetectionAndPartnerETA() {
        var nav = NavModel()
        var now: UInt64 = 1000 * ms
        nav.navigate(to: 5, now: now, count: 100, isRepeat: false)
        for target in [6, 5, 6, 5] {
            now += 700 * ms
            nav.navigate(to: target, now: now, count: 100, isRepeat: false)
        }
        XCTAssertTrue(nav.isAB)
        XCTAssertEqual(nav.abPartner, 6)
        XCTAssertEqual(nav.eta(6, now: now, tuning: PrefetchTuning()), nav.iEff(now: now), accuracy: 0.001)
    }

    func testJumpResetsVelocity() {
        var (nav, now) = steady(100, intervalMs: 50)
        XCTAssertLessThan(nav.emaIntervalMs, 100)
        now += 50 * ms
        nav.navigate(to: 500, now: now, count: 2000, isRepeat: false)
        XCTAssertEqual(nav.emaIntervalMs, 1000)
        XCTAssertTrue(nav.history.isEmpty)
        nav.navigate(to: 1999, now: now + ms, count: 2000, isRepeat: false)
        XCTAssertEqual(nav.direction, -1, "End jumps travel backwards")
    }

    func testBehindETAIncludesReversalPenalty() {
        let (nav, now) = steady(100, intervalMs: 1000)
        let tuning = PrefetchTuning()
        XCTAssertEqual(nav.eta(101, now: now, tuning: tuning), 1000, accuracy: 1)
        XCTAssertEqual(nav.eta(99, now: now, tuning: tuning), 1600, accuracy: 1)
    }

    func testSweepRingOrderAndPausedWhileSkimming() {
        let (nav, now) = steady(100, intervalMs: 1000)
        let plan = planPrefetch(nav, now: now + 30 * ms, tuning: PrefetchTuning(), context: context(sweepSlots: 10))
        let sweep = plan.jobs.filter { $0.kind == .sweep }
        XCTAssertEqual(sweep.count, 10)
        XCTAssertTrue(sweep.allSatisfy { $0.tier == .preview })
        let distances = sweep.map { abs($0.index - 100) }
        XCTAssertEqual(distances, distances.sorted(), "ring order around the cursor")
        let (fast, fastNow) = steady(100, steps: 20, intervalMs: 33, isRepeat: true)
        let skim = planPrefetch(fast, now: fastNow + ms, tuning: PrefetchTuning(), context: context(sweepSlots: 10))
        XCTAssertTrue(skim.jobs.allSatisfy { $0.kind != .sweep }, "sweep pauses while skimming")
    }

    /// The ring scan visits up to 2×1024 files; the pass that answers a key press leaves it out, a wake runs it.
    func testSweepWaitsForThePassAfterTheNavigation() {
        let (nav, now) = steady(100, intervalMs: 1000)
        let tuning = PrefetchTuning()
        let atKey = planPrefetch(nav, now: now + ms, tuning: tuning, context: context(sweepSlots: 10))
        XCTAssertTrue(atKey.jobs.allSatisfy { $0.kind != .sweep }, "the key press waits for the sweep's ring scan")
        XCTAssertFalse(atKey.sweepScanned)
        XCTAssertEqual(atKey.wakeAfterMs ?? .infinity, tuning.sweepAfterNavMs - 1, accuracy: 0.5)
        let later = planPrefetch(nav, now: now + UInt64(tuning.sweepAfterNavMs + 1) * ms, tuning: tuning,
                                 context: context(sweepSlots: 10))
        XCTAssertEqual(later.jobs.filter { $0.kind == .sweep }.count, 10)
    }

    /// In a large folder where almost no preview qualifies (expensive previews, no QuickLook), every pass used to walk
    /// the whole ring again. A scan that reached its radius is reused: its jobs are planned without scanning.
    func testExhaustedSweepScanIsReused() {
        let (nav, now) = steady(5000, intervalMs: 1000, count: 10_000)
        var examined = 0
        var c = context(count: 10_000, sweepSlots: 24)
        c.cheapPreview = { j in examined += 1; return j == 5300 || j == 4800 }
        let first = planPrefetch(nav, now: now + 30 * ms, tuning: PrefetchTuning(), context: c)
        let found = first.jobs.filter { $0.kind == .sweep }
        XCTAssertEqual(Set(found.map(\.index)), [5300, 4800])
        XCTAssertTrue(first.sweepScanned)
        XCTAssertTrue(first.sweepExhausted, "two jobs for a batch of 24: the whole ring was scanned")
        XCTAssertGreaterThan(examined, 2000)
        examined = 0
        c.sweepReuse = found
        let again = planPrefetch(nav, now: now + 40 * ms, tuning: PrefetchTuning(), context: c)
        XCTAssertEqual(again.jobs.filter { $0.kind == .sweep }.map(\.index), found.map(\.index))
        XCTAssertFalse(again.sweepScanned)
        XCTAssertLessThan(examined, 10, "the ring was scanned again")
        // A job that got cached meanwhile is not planned again.
        let cached = context(count: 10_000, cached: [5300], sweepSlots: 24)
        var reuse = c
        reuse.cached = cached.cached
        XCTAssertEqual(planPrefetch(nav, now: now + 40 * ms, tuning: PrefetchTuning(), context: reuse).jobs
                        .filter { $0.kind == .sweep }.map(\.index), [4800])
    }

    func testSpeculativeFullAfterDwellWhenCheap() {
        // Just opened (no rhythm yet): the fixed dwell.
        var nav = NavModel()
        let now: UInt64 = 10_000 * ms
        nav.navigate(to: 100, now: now, count: 2000, isRepeat: false)
        let tuning = PrefetchTuning()
        let early = planPrefetch(nav, now: now + 100 * ms, tuning: tuning, context: context(cached: [100]))
        XCTAssertFalse(early.jobs.contains { $0.tier == .full })
        XCTAssertEqual(early.wakeAfterMs ?? 0, 300, accuracy: 1)
        let late = planPrefetch(nav, now: now + 401 * ms, tuning: tuning, context: context(cached: [100]))
        XCTAssertTrue(late.jobs.contains { $0.tier == .full && $0.index == 100 })
        let costly = planPrefetch(nav, now: now + 401 * ms, tuning: tuning,
                                  context: context(cached: [100], costs: [.preview: 4, .screen: 30, .full: 900]))
        XCTAssertFalse(costly.jobs.contains { $0.tier == .full }, "expensive full resolution waits for zoom intent")
    }

    /// Stepping at ~420 ms per image, a fixed 400 ms dwell started a full decode just before every key press (all of
    /// them wasted). While the user steps at a rhythm, the full tier is speculated once they stay clearly longer.
    func testSpeculativeFullFollowsTheRhythm() {
        let tuning = PrefetchTuning()
        let (nav, now) = steady(100, intervalMs: 420)
        let dwell = tuning.fullDwellMs(for: nav)
        XCTAssertEqual(dwell, 1.5 * nav.emaIntervalMs, accuracy: 0.001)
        let usual = planPrefetch(nav, now: now + 401 * ms, tuning: tuning, context: context(cached: [100]))
        XCTAssertFalse(usual.jobs.contains { $0.tier == .full }, "speculated before the user usually leaves")
        XCTAssertEqual(usual.wakeAfterMs ?? 0, dwell - 401, accuracy: 0.5)
        let lingering = planPrefetch(nav, now: now + UInt64((dwell + 1) * 1e6), tuning: tuning, context: context(cached: [100]))
        XCTAssertTrue(lingering.jobs.contains { $0.tier == .full && $0.index == 100 })
        // Slow browsing: capped.
        let (slow, _) = steady(100, intervalMs: 2000)
        XCTAssertEqual(tuning.fullDwellMs(for: slow), 1500, accuracy: 0.001)
        // A/B toggling keeps both full tiers pinned: the fixed dwell.
        var ab = NavModel()
        var t: UInt64 = 1000 * ms
        ab.navigate(to: 5, now: t, count: 100, isRepeat: false)
        for target in [6, 5, 6, 5] {
            t += 300 * ms
            ab.navigate(to: target, now: t, count: 100, isRepeat: false)
        }
        XCTAssertTrue(ab.isAB)
        XCTAssertEqual(tuning.fullDwellMs(for: ab), tuning.fullDwellMs)
    }

    func testCostModelLearnsAndScales() {
        var costs = CostModel()
        let url = URL(fileURLWithPath: "/x/a.png")
        XCTAssertGreaterThan(costs.estimate(url: url, info: nil, tier: .preview), 100, "PNG previews are not cheap")
        costs.record(url: url, info: nil, tier: .preview, ms: 2, concurrency: 1)
        XCTAssertEqual(costs.estimate(url: url, info: nil, tier: .preview), 2, accuracy: 0.001)
        costs.record(url: url, info: nil, tier: .preview, ms: 12, concurrency: 1)
        XCTAssertEqual(costs.estimate(url: url, info: nil, tier: .preview), 0.7 * 2 + 0.3 * 12, accuracy: 0.001)
        XCTAssertEqual(CostModel.family(of: URL(fileURLWithPath: "/x/b.CR3")), .raw)
    }
}
