import Foundation

/// Tunables of the decode/prefetch pipeline.
public struct PipelineConfig: Sendable, Equatable {
    /// Long side, in device pixels, that the `.screen` tier must cover (largest attached display).
    public var screenLongSide: Int
    /// Long side of the `.preview` tier.
    public var previewLongSide: Int
    /// Bytes of decoded pixels the cache may keep resident (all tiers together).
    public var memoryBudget: Int

    /// Per-tier budgets (bytes). Defaults: screen 2 GB, preview 256 MB, full 1 GB on a 48 GB Mac, scaled with RAM.
    public var screenBudget = PipelineConfig.scaledToRAM(2 << 30)
    public var previewBudget = PipelineConfig.scaledToRAM(256 << 20)
    public var fullBudget = PipelineConfig.scaledToRAM(1 << 30)
    /// Decode lanes (P-cores), of which `reservedLanes` are kept for the visible image.
    public var decodeLanes = 6
    public var reservedLanes = 1
    /// Concurrent decodes per resource: hardware JPEG/HEVC engines, other ImageIO work. CPU decodes fill the rest.
    public var hardwareLanes = 2
    public var generalLanes = 4
    /// Background preview-sweep lanes (QoS utility, efficiency cores). 0 disables the sweep threads.
    public var sweepLanes = 4
    /// `F_RDADVISE` read-ahead for files entering the prefetch windows.
    public var readAhead = true
    /// Let the background sweep take previews from QuickLook's persistent thumbnail cache for files whose own
    /// preview decode is expensive.
    public var quickLookSweep = true
    /// Listen to system memory pressure (`DispatchSource`) and trim automatically.
    public var monitorsMemoryPressure = true
    /// Scheduler constants (windows, skim threshold, dwell, horizons, sweep).
    public var tuning = PrefetchTuning()

    public init(screenLongSide: Int = 3456, previewLongSide: Int = 512,
                memoryBudget: Int = Int(ProcessInfo.processInfo.physicalMemory / 11)) {
        self.screenLongSide = screenLongSide
        self.previewLongSide = previewLongSide
        self.memoryBudget = memoryBudget
    }

    /// `bytesAt48GB` scaled linearly with physical memory (factor clamped to 1/6…2).
    public static func scaledToRAM(_ bytesAt48GB: Int, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        let factor = min(max(Double(physicalMemory) / Double(48 << 30), 1.0 / 6), 2)
        return Int(Double(bytesAt48GB) * factor)
    }

    /// Budget of one tier.
    public func budget(for tier: Tier) -> Int {
        switch tier {
        case .preview: return previewBudget
        case .screen: return screenBudget
        case .full: return fullBudget
        }
    }

    var laneLimits: LaneLimits {
        LaneLimits(decodeLanes: max(1, decodeLanes), reservedLanes: max(0, min(reservedLanes, decodeLanes - 1)),
                   hardware: max(1, hardwareLanes), general: max(1, generalLanes), sweepLanes: max(0, sweepLanes))
    }
}

public struct PipelineStats: Sendable, Equatable {
    /// Navigations that found a sharp tier (screen or full) cached.
    public var hits = 0
    /// Navigations that did not.
    public var misses = 0
    /// Successful decodes (all tiers, all lanes).
    public var decodes = 0
    /// Bytes of decoded pixels currently cached.
    public var cachedBytes = 0
    /// Misses that still had a preview to show immediately.
    public var previewHits = 0
    /// Decodes whose result was no longer wanted when it arrived (running decodes cannot be aborted).
    public var wasted = 0
    public var failures = 0
    public var evictions = 0
    /// Decodes done by the background preview sweep.
    public var sweepDecodes = 0
    /// Sweep previews served by QuickLook's thumbnail cache.
    public var quickLookPreviews = 0
    public init() {}
}

/// Decodes, caches and prefetches the images of one browsing session.
///
/// Threading contract: every public member is main-thread only; decoding runs on
/// background lanes and results are delivered through `onDecoded` on the main thread.
///
/// Scheduling is the "P4" predictive policy of docs/DESIGN.md §3: every (image, tier) gets a deadline from the
/// navigation model's ETA, velocity-scaled windows feed an earliest-deadline-first queue, skimming shows previews
/// only, the visible image gates prefetch, and retention evicts by ETA (not LRU) within per-tier budgets.
public final class ImagePipeline {
    public let decoder: ImageDecoder
    public let pool: PixelBufferPool
    public private(set) var config: PipelineConfig
    public private(set) var files: [ImageFile] = []
    public private(set) var index = 0
    public private(set) var stats = PipelineStats()
    /// Navigation model (cursor, direction, velocity, A/B toggle).
    public private(set) var navigation = NavModel()

    /// A tier of `file` finished decoding (main thread). Fires for prefetched files too.
    public var onDecoded: ((ImageFile, DecodedImage) -> Void)?
    /// Decoding `file` failed (main thread).
    public var onFailed: ((ImageFile, Error) -> Void)?

    /// Per-file state, parallel to `files` (index-based so planning never hashes URLs).
    private struct Slot {
        var preview: DecodedImage?
        var screen: DecodedImage?
        var full: DecodedImage?
        /// `ImageFile.version` the pixels were decoded from (nil = unknown, e.g. opened before the folder listing).
        var version: String?
        var info: ImageInfo?
        var family: CostModel.Family?
        /// Tiers that failed (bit per tier): never retried.
        var failed: UInt8 = 0
        /// Read-ahead issued: 1 = head, 2 = whole file.
        var advised: UInt8 = 0
        /// QuickLook had no thumbnail: the sweep does not ask again.
        var quickLookMissed = false
        var lanes: [DecodeLane?] = [nil, nil, nil]

        subscript(tier: Tier) -> DecodedImage? {
            get { tier == .preview ? preview : tier == .screen ? screen : full }
            set {
                switch tier {
                case .preview: preview = newValue
                case .screen: screen = newValue
                case .full: full = newValue
                }
            }
        }

        var hasPixels: Bool { preview != nil || screen != nil || full != nil }
        var hasState: Bool { hasPixels || info != nil || failed != 0 || advised != 0 }
    }

    private var slots: [Slot] = []
    /// Indices whose slot holds pixels (eviction and pressure scan only these).
    private var cachedIndices: Set<Int> = []
    private var tierBytes = [0, 0, 0]
    private var position: [URL: Int] = [:]
    private var fullRequested: URL?
    private var costs = CostModel()
    private let infos = InfoStore()
    private var scheduler: DecodeScheduler!
    private var wakeTimer: DispatchSourceTimer?
    private var pressureSource: DispatchSourceMemoryPressure?
    /// Budgets are halved and the sweep paused until this time (`Trace.now()` nanos).
    private var pressureUntil: UInt64 = 0
    private var replanQueued = false
    private var averagePreviewBytes = 1 << 20
    /// Finished decodes waiting for the main thread (drained by a main-queue hop, or synchronously by `waitForCurrent`).
    private let inbox = OutcomeInbox()

    public init(decoder: ImageDecoder, pool: PixelBufferPool, config: PipelineConfig = PipelineConfig()) {
        self.decoder = decoder
        self.pool = pool
        self.config = config
        costs.alpha = config.tuning.alpha
        let box = WeakPipeline()
        let inbox = self.inbox
        scheduler = DecodeScheduler(decoder: decoder, pool: pool, infos: infos, limits: config.laneLimits) { outcome in
            inbox.push(outcome)
            DispatchQueue.main.async { box.pipeline?.drainInbox() }
        }
        box.pipeline = self
        if config.monitorsMemoryPressure { startPressureMonitoring() }
    }

    deinit {
        scheduler.stop()
        wakeTimer?.cancel()
        pressureSource?.cancel()
    }

    public var currentFile: ImageFile? { files.indices.contains(index) ? files[index] : nil }

    /// Replace the browsing set (e.g. after the folder scan, a sort change or a deletion).
    /// Cached tiers, metadata and running decodes of files that survive are kept.
    public func setFiles(_ files: [ImageFile], index: Int) {
        let previous = currentFile
        let oldFiles = self.files
        var oldSlots = self.slots
        self.files = files
        position = Dictionary(files.enumerated().map { ($1.url, $0) }, uniquingKeysWith: { first, _ in first })
        slots = [Slot](repeating: Slot(), count: files.count)
        cachedIndices.removeAll(keepingCapacity: true)
        tierBytes = [0, 0, 0]
        for i in oldSlots.indices where oldSlots[i].hasState {
            guard let j = position[oldFiles[i].url] else { continue }  // removed: pixels are released
            var slot = oldSlots[i]
            oldSlots[i] = Slot()
            if let version = Self.knownVersion(files[j]) {
                if let cached = slot.version, cached != version {
                    slot = Slot()  // changed on disk: decode again
                    infos.remove(files[j].url)
                }
                slot.version = version
            }
            slots[j] = slot
            if slot.hasPixels {
                cachedIndices.insert(j)
                for tier in Tier.allCases { if let image = slot[tier] { tierBytes[tier.rawValue] += image.pixels.allocatedBytes } }
            }
        }
        if let url = fullRequested, position[url] == nil { fullRequested = nil }
        recountBytes()
        guard !files.isEmpty else {
            self.index = 0
            scheduler.submit([], visible: [])
            return
        }
        let target = min(max(index, 0), files.count - 1)
        if let previous, files[target] == previous, navigation.lastNav != 0 {
            self.index = target
            navigation.reindex(to: target)
            replan()
        } else {
            navigate(to: target, isRepeat: false)
        }
    }

    /// The user moved to `index`. `isRepeat` is true for key auto-repeat (skimming).
    public func navigate(to index: Int, isRepeat: Bool) {
        guard !files.isEmpty else { return }
        let target = min(max(index, 0), files.count - 1)
        let now = Trace.now()
        if files[target].url != currentFile?.url { fullRequested = nil }
        navigation.navigate(to: target, now: now, count: files.count, isRepeat: isRepeat)
        self.index = target
        if isCached(target, .screen) {
            stats.hits += 1
        } else {
            stats.misses += 1
            if isCached(target, .preview) { stats.previewHits += 1 }
        }
        replan()
    }

    /// The view needs more than the screen tier (zoom beyond fit) for the current image: decode `.full` next, ahead of
    /// all prefetch. Ignored until the screen tier is cached (a preview on screen always "wants" more pixels; the view
    /// asks again when the screen tier is shown).
    public func requestFullResolution() {
        guard let file = currentFile, isCached(index, .screen), !isCached(index, .full), fullRequested != file.url else { return }
        fullRequested = file.url
        replan()
    }

    /// Launch fast path: block the main thread for at most `timeout` until a tier of the current file is decoded and
    /// deliver it (with every other finished decode) synchronously through `onDecoded`, instead of waiting for a
    /// main-queue turn (during `NSApplication.finishLaunching` that turn comes ~70 ms late). Returns true when the
    /// current file has pixels; false on timeout, failure or an empty set.
    @discardableResult
    public func waitForCurrent(timeout: TimeInterval) -> Bool {
        guard let file = currentFile else { return false }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while true {
            drainInbox()
            guard let i = slotIndex(of: file), currentFile == file else { return false }
            if slots[i].hasPixels { return true }
            if slots[i].failed & (1 << Tier.screen.rawValue) != 0 { return false }
            guard inbox.wait(until: deadline) else { return slots[i].hasPixels }
        }
    }

    /// Best tier decoded so far for `file`.
    public func best(for file: ImageFile) -> DecodedImage? {
        guard let i = slotIndex(of: file) else { return nil }
        return slots[i].full ?? slots[i].screen ?? slots[i].preview
    }

    /// Metadata of `file`, probed alongside its first decode (nil until then).
    public func info(for file: ImageFile) -> ImageInfo? {
        if let i = slotIndex(of: file), let info = slots[i].info { return info }
        return infos.get(file.url)
    }

    public func updateConfig(_ config: PipelineConfig) {
        self.config = config
        enforceBudgets()
        scheduleReplan()
    }

    /// Trim the cache. `.warning`: drop full resolution of other images, keep screen tiers within ±4 and previews
    /// within ±128, pause the sweep and halve the budgets for 60 s. `.critical`: keep only the current image's
    /// sharp tiers and previews within ±32.
    public func handleMemoryPressure(critical: Bool) {
        let partner = navigation.abPartner
        for i in Array(cachedIndices) {
            let distance = abs(i - index)
            for tier in Tier.allCases where slots[i][tier] != nil {
                let keep: Bool
                switch (critical, tier) {
                case (true, .preview): keep = distance <= 32
                case (true, _): keep = i == index
                case (false, .preview): keep = distance <= 128
                case (false, .screen): keep = distance <= 4 || i == partner
                case (false, .full): keep = i == index
                }
                if !keep { evict(i, tier) }
            }
        }
        pressureUntil = Trace.now() + 60_000_000_000
        pool.drain()
        enforceBudgets()
        Trace.log("memory pressure \(critical ? "critical" : "warning"): cached \(stats.cachedBytes >> 20) MB")
        scheduleReplan()
    }

    // MARK: Introspection (tests, bench, HUD)

    /// Tiers of `file` currently cached.
    public func cachedTiers(for file: ImageFile) -> [Tier] {
        guard let i = slotIndex(of: file) else { return [] }
        return Tier.allCases.filter { slots[i][$0] != nil }
    }

    /// Bytes cached per tier.
    public func cachedBytes(for tier: Tier) -> Int { tierBytes[tier.rawValue] }

    /// The user is skimming (fast navigation or key repeat): only previews are decoded for the visible image.
    public var isSkimming: Bool { navigation.isSkimming(now: Trace.now(), tuning: config.tuning) }

    /// Decodes queued but not started.
    public var queuedDecodes: Int { scheduler.queuedCount }

    var schedulerState: String { scheduler.debugState }

    /// Files whose cache entries are never evicted by budget: the current image and its A/B partner.
    public var pinnedFiles: [ImageFile] {
        var result: [ImageFile] = []
        if let file = currentFile { result.append(file) }
        if let p = navigation.abPartner, files.indices.contains(p) { result.append(files[p]) }
        return result
    }

    // MARK: Planning

    private func slotIndex(of file: ImageFile) -> Int? {
        if files.indices.contains(index), files[index].url == file.url { return index }
        return position[file.url]
    }

    private func scheduleReplan() {
        guard !replanQueued else { return }
        replanQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.replanQueued else { return }
            self.replan()
        }
    }

    private func replan() {
        replanQueued = false
        guard !files.isEmpty else { scheduler.submit([], visible: []); return }
        let now = Trace.now()
        let tuning = config.tuning
        let snapshot = scheduler.snapshot()
        // Running / undelivered keys as index → tier bits (a handful of URL lookups per pass).
        var busyBits: [Int: UInt8] = [:]
        for key in snapshot.busy { if let i = position[key.url] { busyBits[i, default: 0] |= 1 << key.tier.rawValue } }
        let underPressure = now < pressureUntil
        let previewHeadroom = budget(.preview) - tierBytes[Tier.preview.rawValue]
        let windowReserve = tuning.previewMaxAhead + tuning.previewBehind
        let sweepSlots = config.sweepLanes > 0 ? max(0, previewHeadroom / max(averagePreviewBytes, 1) - windowReserve) : 0
        let context = PlanContext(
            count: files.count, listingReady: true,
            cached: { [unowned self] j, tier in self.isCached(j, tier) },
            busy: { [unowned self] j, tier in
                let bit: UInt8 = 1 << tier.rawValue
                return (busyBits[j] ?? 0) & bit != 0 || self.slots[j].failed & bit != 0
            },
            estimate: { [unowned self] j, tier in self.estimate(j, tier) },
            cheapPreview: { [unowned self] j in self.isCheapPreview(j) },
            quickLookSweep: { [unowned self] j in self.config.quickLookSweep && !self.slots[j].quickLookMissed },
            fullRequested: fullRequested == files[index].url,
            runningWorkMs: snapshot.runningWorkMs, decodeBacklog: snapshot.decodeBacklog,
            sweepSlots: sweepSlots, sweepPaused: underPressure,
            decodeLanes: config.laneLimits.decodeLanes, reservedLanes: config.laneLimits.reservedLanes)
        let plan = planPrefetch(navigation, now: now, tuning: tuning, context: context)

        var jobs: [DecodeJob] = []
        jobs.reserveCapacity(plan.jobs.count)
        let current = files[index].url
        let visible: Set<JobKey> = [JobKey(url: current, tier: .preview), JobKey(url: current, tier: .screen)]
        for planned in plan.jobs {
            let j = planned.index
            let file = files[j]
            let target: Int
            switch planned.tier {
            case .preview: target = config.previewLongSide
            case .screen: target = config.screenLongSide
            case .full: target = slots[j].info.map { max($0.pixelWidth, $0.pixelHeight) } ?? config.screenLongSide
            }
            jobs.append(DecodeJob(
                key: JobKey(url: file.url, tier: planned.tier), file: file, prio: planned.prio, kind: planned.kind,
                lane: planned.quickLook ? .general : lane(j, planned.tier), targetLongSide: target,
                estimateMs: estimate(j, planned.tier), quickLook: planned.quickLook))
        }
        scheduler.submit(jobs, visible: visible)
        armWake(afterMs: plan.wakeAfterMs)
        if config.readAhead { issueReadAhead(plan, skimming: navigation.isSkimming(now: now, tuning: tuning)) }
        if Trace.enabled {
            Trace.log("plan cursor=\(index) skim=\(navigation.isSkimming(now: now, tuning: tuning)) jobs=\(jobs.count) "
                      + "visible=\(plan.jobs.filter { $0.kind == .visible }.map { $0.tier.rawValue }) "
                      + "ms=\(String(format: "%.3f", Trace.ms(since: now)))")
        }
    }

    private func lane(_ j: Int, _ tier: Tier) -> DecodeLane {
        if let lane = slots[j].lanes[tier.rawValue] { return lane }
        let lane = decoder.lane(for: files[j].url, info: slots[j].info, tier: tier)
        if slots[j].info != nil { slots[j].lanes[tier.rawValue] = lane }  // stable once metadata is known
        return lane
    }

    /// Whole files for the screen window, the first 256 KB for the preview window. While skimming most screen tiers
    /// are skipped, so the screen window only gets the head too (no gigabytes of RAW read-ahead at 30 images/s).
    private func issueReadAhead(_ plan: Plan, skimming: Bool) {
        var requests: [(url: URL, length: Int?)] = []
        let headOnly = skimming ? plan.screenWindow + plan.previewWindow : plan.previewWindow
        if !skimming {
            for j in plan.screenWindow where slots[j].advised < 2 {
                slots[j].advised = 2
                requests.append((files[j].url, nil))
            }
        }
        for j in headOnly where slots[j].advised < 1 {
            slots[j].advised = 1
            requests.append((files[j].url, ReadAhead.headBytes))
        }
        ReadAhead.advise(requests)
    }

    private func armWake(afterMs ms: Double?) {
        guard let ms else { wakeTimer?.schedule(deadline: .distantFuture); return }
        if wakeTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.setEventHandler { [weak self] in self?.replan() }
            timer.resume()
            wakeTimer = timer
        }
        wakeTimer?.schedule(deadline: .now() + .microseconds(Int(ms * 1000) + 200), leeway: .microseconds(500))
    }

    // MARK: Results

    private func drainInbox() {
        for outcome in inbox.take() { handle(outcome) }
    }

    private func handle(_ outcome: DecodeOutcome) {
        let key = outcome.job.key
        scheduler.acknowledge(key)
        defer { scheduleReplan() }
        guard let i = position[key.url] else { stats.wasted += 1; return }
        let file = files[i]
        // The file changed on disk while decoding.
        if let decodedFrom = Self.knownVersion(outcome.job.file), let now = Self.knownVersion(file), decodedFrom != now {
            stats.wasted += 1
            return
        }
        if slots[i].info == nil, let info = outcome.info ?? infos.get(key.url) {
            slots[i].info = info
            slots[i].lanes = [nil, nil, nil]  // lanes may depend on the metadata
        }
        switch outcome.result {
        case .success(let image):
            stats.decodes += 1
            if outcome.job.kind == .sweep { stats.sweepDecodes += 1 }
            // QuickLook's latency is not our decoder's cost: keep it out of the cost model.
            if !outcome.job.quickLook {
                costs.record(family: family(i), megapixels: CostModel.megapixels(slots[i].info), tier: key.tier,
                             ms: outcome.wallMs, concurrency: outcome.concurrency)
            }
            guard keep(i, key.tier) else { stats.wasted += 1; return }
            if outcome.job.quickLook { stats.quickLookPreviews += 1 }
            insert(image, at: i, tier: key.tier)
            onDecoded?(file, image)
        case .failure(_) where outcome.job.quickLook:
            slots[i].quickLookMissed = true
        case .failure(let error):
            stats.failures += 1
            slots[i].failed |= 1 << key.tier.rawValue
            if key.tier == .screen { slots[i].failed |= 1 << Tier.full.rawValue }
            Trace.log("decode failed \(file.name) tier=\(key.tier): \(error)")
            // A failed preview is silent: the screen tier may still succeed.
            if key.tier != .preview { onFailed?(file, error) }
        }
    }

    /// Late results are cached only if still useful (research a2 §4 `keep`).
    private func keep(_ j: Int, _ tier: Tier) -> Bool {
        let pinned = isPinned(j)
        switch tier {
        case .preview:
            return !isCached(j, .screen) || pinned
        case .screen:
            if pinned || abs(j - index) <= 3 { return true }
            return navigation.eta(j, now: Trace.now(), tuning: config.tuning) <= 2 * config.tuning.screenHorizonMs
        case .full:
            return pinned
        }
    }

    // MARK: Cache

    private static func knownVersion(_ file: ImageFile) -> String? {
        file.byteSize == 0 && file.modified == 0 ? nil : file.version
    }

    private static func isFullResolution(_ image: DecodedImage) -> Bool {
        max(image.pixels.width, image.pixels.height) >= max(image.fullWidth, image.fullHeight)
    }

    /// `.screen` is satisfied by a cached `.full`, and `.full` by a screen tier that is already full resolution.
    private func isCached(_ j: Int, _ tier: Tier) -> Bool {
        let slot = slots[j]
        switch tier {
        case .preview: return slot.preview != nil
        case .screen: return slot.screen != nil || slot.full != nil
        case .full: return slot.full != nil || slot.screen.map(Self.isFullResolution) == true
        }
    }

    private func isPinned(_ j: Int) -> Bool { j == index || j == navigation.abPartner }

    private func budget(_ tier: Tier) -> Int {
        let base = config.budget(for: tier)
        return Trace.now() < pressureUntil ? base / 2 : base
    }

    private func family(_ j: Int) -> CostModel.Family {
        if let family = slots[j].family { return family }
        let family = CostModel.family(of: files[j].url)
        slots[j].family = family
        return family
    }

    private func estimate(_ j: Int, _ tier: Tier) -> Double {
        costs.estimate(family: family(j), megapixels: CostModel.megapixels(slots[j].info), tier: tier)
    }

    private func isCheapPreview(_ j: Int) -> Bool {
        let tuning = config.tuning
        return estimate(j, .preview) <= max(tuning.cheapPreviewMs, tuning.cheapPreviewRatio * estimate(j, .screen))
    }

    private func insert(_ image: DecodedImage, at j: Int, tier: Tier) {
        if slots[j].version == nil { slots[j].version = Self.knownVersion(files[j]) }
        if let old = slots[j][tier] { tierBytes[tier.rawValue] -= old.pixels.allocatedBytes }
        slots[j][tier] = image
        cachedIndices.insert(j)
        let bytes = image.pixels.allocatedBytes
        tierBytes[tier.rawValue] += bytes
        if tier == .preview { averagePreviewBytes = (averagePreviewBytes * 7 + bytes) / 8 }
        enforceBudgets()
    }

    private func evict(_ j: Int, _ tier: Tier) {
        guard let image = slots[j][tier] else { return }
        tierBytes[tier.rawValue] -= image.pixels.allocatedBytes
        slots[j][tier] = nil
        if !slots[j].hasPixels { cachedIndices.remove(j) }
        stats.evictions += 1
        recountBytes()
    }

    private func recountBytes() { stats.cachedBytes = tierBytes.reduce(0, +) }

    /// Evict by ETA (largest first) until every tier and the total fit; the pinned images are never evicted.
    private func enforceBudgets() {
        let now = Trace.now()
        let tuning = config.tuning
        let partner = navigation.abPartner
        func victim(_ tier: Tier?) -> (Int, Tier)? {
            var best: (j: Int, tier: Tier, eta: Double)?
            for j in cachedIndices where j != index && j != partner {
                let eta = navigation.eta(j, now: now, tuning: tuning)
                for t in Tier.allCases where (tier == nil || tier == t) && slots[j][t] != nil {
                    // Among equal ETAs drop the most expensive tier first.
                    if best == nil || eta > best!.eta || (eta == best!.eta && t > best!.tier) { best = (j, t, eta) }
                }
            }
            return best.map { ($0.j, $0.tier) }
        }
        for tier in Tier.allCases {
            let limit = budget(tier)
            while tierBytes[tier.rawValue] > limit, let (j, t) = victim(tier) { evict(j, t) }
        }
        let total = Trace.now() < pressureUntil ? config.memoryBudget / 2 : config.memoryBudget
        while tierBytes.reduce(0, +) > total, let (j, t) = victim(nil) { evict(j, t) }
        recountBytes()
    }

    private func startPressureMonitoring() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let event = source?.data else { return }
            if event.contains(.critical) {
                self.handleMemoryPressure(critical: true)
            } else if event.contains(.warning) {
                self.handleMemoryPressure(critical: false)
            }
        }
        source.resume()
        pressureSource = source
    }
}

/// Decode outcomes handed from the worker threads to the main thread, in completion order.
private final class OutcomeInbox: @unchecked Sendable {
    private let condition = NSCondition()
    private var outcomes: [DecodeOutcome] = []

    func push(_ outcome: DecodeOutcome) {
        condition.lock()
        outcomes.append(outcome)
        condition.broadcast()
        condition.unlock()
    }

    func take() -> [DecodeOutcome] {
        condition.lock(); defer { condition.unlock() }
        let taken = outcomes
        outcomes.removeAll()
        return taken
    }

    /// Wait until an outcome is pending; false when `deadline` passed first.
    func wait(until deadline: Date) -> Bool {
        condition.lock(); defer { condition.unlock() }
        while outcomes.isEmpty {
            if !condition.wait(until: deadline) { return !outcomes.isEmpty }
        }
        return true
    }
}

/// Lets worker threads reach the (main-thread) pipeline without keeping it alive; only dereferenced on main.
private final class WeakPipeline: @unchecked Sendable {
    weak var pipeline: ImagePipeline?
}
