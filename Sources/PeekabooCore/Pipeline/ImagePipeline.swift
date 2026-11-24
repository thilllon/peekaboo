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

    private struct Entry {
        var tiers: [DecodedImage?] = [nil, nil, nil]
        /// `ImageFile.version` the pixels were decoded from (nil = unknown, e.g. opened before the folder listing).
        var version: String?

        subscript(tier: Tier) -> DecodedImage? {
            get { tiers[tier.rawValue] }
            set { tiers[tier.rawValue] = newValue }
        }

        var isEmpty: Bool { tiers.allSatisfy { $0 == nil } }
    }

    private var cache: [URL: Entry] = [:]
    private var tierBytes = [0, 0, 0]
    private var position: [URL: Int] = [:]
    private var failed: Set<JobKey> = []
    private var fullRequested: URL?
    private var costs = CostModel()
    private let infos = InfoStore()
    private var scheduler: DecodeScheduler!
    private var wakeTimer: DispatchSourceTimer?
    private var pressureSource: DispatchSourceMemoryPressure?
    /// Budgets are halved and the sweep paused until this time (`Trace.now()` nanos).
    private var pressureUntil: UInt64 = 0
    /// Read-ahead already issued per file: 1 = head, 2 = whole file.
    private var advised: [URL: UInt8] = [:]
    private var replanQueued = false
    private var averagePreviewBytes = 1 << 20

    public init(decoder: ImageDecoder, pool: PixelBufferPool, config: PipelineConfig = PipelineConfig()) {
        self.decoder = decoder
        self.pool = pool
        self.config = config
        costs.alpha = config.tuning.alpha
        let box = WeakPipeline()
        scheduler = DecodeScheduler(decoder: decoder, pool: pool, infos: infos, limits: config.laneLimits) { outcome in
            DispatchQueue.main.async { box.pipeline?.handle(outcome) }
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
    /// Cached tiers and running decodes of files that survive are kept.
    public func setFiles(_ files: [ImageFile], index: Int) {
        let previous = currentFile
        self.files = files
        position = Dictionary(files.enumerated().map { ($1.url, $0) }, uniquingKeysWith: { first, _ in first })
        for (url, entry) in cache {
            guard let i = position[url] else { remove(url); continue }
            let version = Self.knownVersion(files[i])
            if let version, let cached = entry.version, version != cached {
                remove(url)  // changed on disk
                infos.remove(url)
            } else if entry.version == nil, let version {
                cache[url]?.version = version
            }
        }
        failed = failed.filter { position[$0.url] != nil }
        advised = advised.filter { position[$0.key] != nil }
        if fullRequested.map({ position[$0] == nil }) ?? false { fullRequested = nil }
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
        let file = files[target]
        if file.url != currentFile?.url { fullRequested = nil }
        navigation.navigate(to: target, now: now, count: files.count, isRepeat: isRepeat)
        self.index = target
        if isCached(file.url, .screen) {
            stats.hits += 1
        } else {
            stats.misses += 1
            if isCached(file.url, .preview) { stats.previewHits += 1 }
        }
        replan()
    }

    /// The view needs more than the screen tier (zoom beyond fit) for the current image.
    public func requestFullResolution() {
        guard let file = currentFile, !isCached(file.url, .full), fullRequested != file.url else { return }
        fullRequested = file.url
        replan()
    }

    /// Best tier decoded so far for `file`.
    public func best(for file: ImageFile) -> DecodedImage? {
        guard let entry = cache[file.url] else { return nil }
        return entry[.full] ?? entry[.screen] ?? entry[.preview]
    }

    /// Metadata of `file`, probed alongside its first decode (nil until then).
    public func info(for file: ImageFile) -> ImageInfo? { infos.get(file.url) }

    public func updateConfig(_ config: PipelineConfig) {
        self.config = config
        enforceBudgets()
        scheduleReplan()
    }

    /// Trim the cache. `.warning`: drop full resolution of other images, keep screen tiers within ±4 and previews
    /// within ±128, pause the sweep and halve the budgets for 60 s. `.critical`: keep only the current image's
    /// sharp tiers and previews within ±32.
    public func handleMemoryPressure(critical: Bool) {
        let current = currentFile?.url
        let partner = navigation.abPartner.flatMap { files.indices.contains($0) ? files[$0].url : nil }
        for (url, entry) in cache {
            let distance = position[url].map { abs($0 - index) } ?? .max
            for tier in Tier.allCases where entry[tier] != nil {
                let keep: Bool
                switch (critical, tier) {
                case (true, .preview): keep = distance <= 32
                case (true, _): keep = url == current
                case (false, .preview): keep = distance <= 128
                case (false, .screen): keep = distance <= 4 || url == partner
                case (false, .full): keep = url == current
                }
                if !keep { evict(url, tier) }
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
        guard let entry = cache[file.url] else { return [] }
        return Tier.allCases.filter { entry[$0] != nil }
    }

    /// Bytes cached per tier.
    public func cachedBytes(for tier: Tier) -> Int { tierBytes[tier.rawValue] }

    /// The user is skimming (fast navigation or key repeat): only previews are decoded for the visible image.
    public var isSkimming: Bool { navigation.isSkimming(now: Trace.now(), tuning: config.tuning) }

    /// Decodes queued but not started.
    public var queuedDecodes: Int { scheduler.queuedCount }

    /// Files whose cache entries are never evicted by budget: the current image and its A/B partner.
    public var pinnedFiles: [ImageFile] {
        var result: [ImageFile] = []
        if let file = currentFile { result.append(file) }
        if let p = navigation.abPartner, files.indices.contains(p) { result.append(files[p]) }
        return result
    }

    // MARK: Planning

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
        let underPressure = now < pressureUntil
        let previewHeadroom = budget(.preview) - tierBytes[Tier.preview.rawValue]
        let windowReserve = tuning.previewMaxAhead + tuning.previewBehind
        let sweepSlots = config.sweepLanes > 0 ? max(0, previewHeadroom / max(averagePreviewBytes, 1) - windowReserve) : 0
        let files = self.files
        let failed = self.failed
        let busy: (Int, Tier) -> Bool = { j, tier in
            let key = JobKey(url: files[j].url, tier: tier)
            return snapshot.busy.contains(key) || failed.contains(key)
        }
        let context = PlanContext(
            count: files.count, listingReady: true,
            cached: { [unowned self] j, tier in self.isCached(files[j].url, tier) },
            busy: busy,
            estimate: { [unowned self] j, tier in self.estimate(files[j], tier) },
            cheapPreview: { [unowned self] j in self.isCheapPreview(files[j]) },
            fullRequested: fullRequested == files[index].url,
            runningWorkMs: snapshot.runningWorkMs, decodeBacklog: snapshot.decodeBacklog,
            sweepSlots: sweepSlots, sweepPaused: underPressure,
            decodeLanes: config.laneLimits.decodeLanes, reservedLanes: config.laneLimits.reservedLanes)
        let plan = planPrefetch(navigation, now: now, tuning: tuning, context: context)

        var jobs: [DecodeJob] = []
        jobs.reserveCapacity(plan.jobs.count)
        var visible: Set<JobKey> = []
        let current = files[index].url
        for tier in [Tier.preview, .screen] { visible.insert(JobKey(url: current, tier: tier)) }
        if fullRequested == current { visible.insert(JobKey(url: current, tier: .full)) }
        for planned in plan.jobs {
            let file = files[planned.index]
            let info = infos.get(file.url)
            let target: Int
            switch planned.tier {
            case .preview: target = config.previewLongSide
            case .screen: target = config.screenLongSide
            case .full: target = info.map { max($0.pixelWidth, $0.pixelHeight) } ?? config.screenLongSide
            }
            jobs.append(DecodeJob(
                key: JobKey(url: file.url, tier: planned.tier), file: file, prio: planned.prio, kind: planned.kind,
                lane: decoder.lane(for: file.url, info: info, tier: planned.tier), targetLongSide: target,
                estimateMs: estimate(file, planned.tier)))
        }
        scheduler.submit(jobs, visible: visible)
        armWake(afterMs: plan.wakeAfterMs)
        if config.readAhead { issueReadAhead(plan) }
        Trace.log("plan cursor=\(index) skim=\(navigation.isSkimming(now: now, tuning: tuning)) jobs=\(jobs.count) "
                  + "visible=\(plan.jobs.filter { $0.kind == .visible }.map { $0.tier.rawValue }) "
                  + "ms=\(String(format: "%.3f", Trace.ms(since: now)))")
    }

    private func issueReadAhead(_ plan: Plan) {
        var requests: [(url: URL, length: Int?)] = []
        for j in plan.screenWindow {
            let url = files[j].url
            if advised[url, default: 0] < 2 { advised[url] = 2; requests.append((url, nil)) }
        }
        for j in plan.previewWindow {
            let url = files[j].url
            if advised[url, default: 0] < 1 { advised[url] = 1; requests.append((url, ReadAhead.headBytes)) }
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
        switch outcome.result {
        case .success(let image):
            stats.decodes += 1
            if outcome.job.kind == .sweep { stats.sweepDecodes += 1 }
            costs.record(url: key.url, info: infos.get(key.url), tier: key.tier, ms: outcome.wallMs,
                         concurrency: outcome.concurrency)
            guard keep(i, key.tier, image) else { stats.wasted += 1; return }
            insert(image, for: file, tier: key.tier)
            onDecoded?(file, image)
        case .failure(let error):
            stats.failures += 1
            failed.insert(key)
            if key.tier == .screen { failed.insert(JobKey(url: key.url, tier: .full)) }
            Trace.log("decode failed \(file.name) tier=\(key.tier): \(error)")
            // A failed preview is silent: the screen tier may still succeed.
            if key.tier != .preview { onFailed?(file, error) }
        }
    }

    /// Late results are cached only if still useful (research a2 §4 `keep`).
    private func keep(_ j: Int, _ tier: Tier, _ image: DecodedImage) -> Bool {
        let url = files[j].url
        let pinned = isPinned(url)
        switch tier {
        case .preview:
            return !isCached(url, .screen) || pinned
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
    private func isCached(_ url: URL, _ tier: Tier) -> Bool {
        guard let entry = cache[url] else { return false }
        switch tier {
        case .preview: return entry[.preview] != nil
        case .screen: return entry[.screen] != nil || entry[.full] != nil
        case .full: return entry[.full] != nil || entry[.screen].map(Self.isFullResolution) == true
        }
    }

    private func isPinned(_ url: URL) -> Bool {
        if url == currentFile?.url { return true }
        if let p = navigation.abPartner, files.indices.contains(p), files[p].url == url { return true }
        return false
    }

    private func budget(_ tier: Tier) -> Int {
        let base = config.budget(for: tier)
        return Trace.now() < pressureUntil ? base / 2 : base
    }

    private func estimate(_ file: ImageFile, _ tier: Tier) -> Double {
        costs.estimate(url: file.url, info: infos.get(file.url), tier: tier)
    }

    private func isCheapPreview(_ file: ImageFile) -> Bool {
        let preview = estimate(file, .preview)
        let tuning = config.tuning
        return preview <= max(tuning.cheapPreviewMs, tuning.cheapPreviewRatio * estimate(file, .screen))
    }

    private func insert(_ image: DecodedImage, for file: ImageFile, tier: Tier) {
        var entry = cache[file.url] ?? Entry(version: Self.knownVersion(file))
        if let old = entry[tier] { tierBytes[tier.rawValue] -= old.pixels.allocatedBytes }
        entry[tier] = image
        let bytes = image.pixels.allocatedBytes
        tierBytes[tier.rawValue] += bytes
        cache[file.url] = entry
        if tier == .preview { averagePreviewBytes = (averagePreviewBytes * 7 + bytes) / 8 }
        enforceBudgets()
    }

    private func evict(_ url: URL, _ tier: Tier) {
        guard var entry = cache[url], let image = entry[tier] else { return }
        tierBytes[tier.rawValue] -= image.pixels.allocatedBytes
        entry[tier] = nil
        cache[url] = entry.isEmpty ? nil : entry
        stats.evictions += 1
        recountBytes()
    }

    private func remove(_ url: URL) {
        guard let entry = cache.removeValue(forKey: url) else { return }
        for tier in Tier.allCases { if let image = entry[tier] { tierBytes[tier.rawValue] -= image.pixels.allocatedBytes } }
    }

    private func recountBytes() { stats.cachedBytes = tierBytes.reduce(0, +) }

    /// Evict by ETA (largest first) until every tier and the total fit; the pinned images are never evicted.
    private func enforceBudgets() {
        let now = Trace.now()
        let tuning = config.tuning
        let current = currentFile?.url
        let partner = navigation.abPartner.flatMap { files.indices.contains($0) ? files[$0].url : nil }
        func victim(_ tier: Tier?) -> (URL, Tier)? {
            var best: (url: URL, tier: Tier, eta: Double)?
            for (url, entry) in cache where url != current && url != partner {
                let eta = position[url].map { navigation.eta($0, now: now, tuning: tuning) } ?? .infinity
                for t in Tier.allCases where (tier == nil || tier == t) && entry[t] != nil {
                    // Among equal ETAs drop the most expensive tier first.
                    if best == nil || eta > best!.eta || (eta == best!.eta && t > best!.tier) { best = (url, t, eta) }
                }
            }
            return best.map { ($0.url, $0.tier) }
        }
        for tier in Tier.allCases {
            let limit = budget(tier)
            while tierBytes[tier.rawValue] > limit, let (url, t) = victim(tier) { evict(url, t) }
        }
        let total = Trace.now() < pressureUntil ? config.memoryBudget / 2 : config.memoryBudget
        while tierBytes.reduce(0, +) > total, let (url, t) = victim(nil) { evict(url, t) }
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

/// Lets worker threads reach the (main-thread) pipeline without keeping it alive; only dereferenced on main.
private final class WeakPipeline: @unchecked Sendable {
    weak var pipeline: ImagePipeline?
}
