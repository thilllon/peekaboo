import Foundation

/// Tunables of the decode/prefetch pipeline.
public struct PipelineConfig: Sendable, Equatable {
    /// Long side, in device pixels, that the `.screen` tier must cover (largest attached display).
    public var screenLongSide: Int
    /// Long side of the `.preview` tier.
    public var previewLongSide: Int
    /// Bytes of decoded pixels the cache may keep resident.
    public var memoryBudget: Int

    public init(screenLongSide: Int = 3456, previewLongSide: Int = 512,
                memoryBudget: Int = Int(ProcessInfo.processInfo.physicalMemory / 11)) {
        self.screenLongSide = screenLongSide
        self.previewLongSide = previewLongSide
        self.memoryBudget = memoryBudget
    }
}

public struct PipelineStats: Sendable, Equatable {
    public var hits = 0
    public var misses = 0
    public var decodes = 0
    public var cachedBytes = 0
    public init() {}
}

/// Decodes, caches and prefetches the images of one browsing session.
///
/// Threading contract: every public member is main-thread only; decoding runs on
/// background lanes and results are delivered through `onDecoded` on the main thread.
///
/// Walking-skeleton implementation: one serial lane, current image + next image only.
/// The prefetch workstream replaces the internals with the predictive (ETA-deadline)
/// scheduler while keeping this public API.
public final class ImagePipeline {
    public let decoder: ImageDecoder
    public let pool: PixelBufferPool
    public private(set) var config: PipelineConfig
    public private(set) var files: [ImageFile] = []
    public private(set) var index = 0
    public private(set) var stats = PipelineStats()

    /// A tier of `file` finished decoding (main thread). Fires for prefetched files too.
    public var onDecoded: ((ImageFile, DecodedImage) -> Void)?
    /// Decoding `file` failed (main thread).
    public var onFailed: ((ImageFile, Error) -> Void)?

    private var cache: [URL: [Tier: DecodedImage]] = [:]
    private var infos: [URL: ImageInfo] = [:]
    private var inFlight: Set<String> = []
    private var generation = 0
    private let lane = DispatchQueue(label: "peekaboo.decode", qos: .userInitiated)

    public init(decoder: ImageDecoder, pool: PixelBufferPool, config: PipelineConfig = PipelineConfig()) {
        self.decoder = decoder
        self.pool = pool
        self.config = config
    }

    public var currentFile: ImageFile? { files.indices.contains(index) ? files[index] : nil }

    /// Replace the browsing set (e.g. after the folder scan, a sort change or a deletion).
    public func setFiles(_ files: [ImageFile], index: Int) {
        self.files = files
        let live = Set(files.map(\.url))
        cache = cache.filter { live.contains($0.key) }
        navigate(to: index, isRepeat: false)
    }

    /// The user moved to `index`. `isRepeat` is true for key auto-repeat (skimming).
    public func navigate(to index: Int, isRepeat: Bool) {
        guard !files.isEmpty else { return }
        self.index = min(max(index, 0), files.count - 1)
        generation += 1
        let file = files[self.index]
        if cache[file.url]?[.screen] != nil { stats.hits += 1 } else { stats.misses += 1 }
        schedule(file, .preview)
        if !isRepeat { schedule(file, .screen) }
        if !isRepeat, self.index + 1 < files.count { schedule(files[self.index + 1], .screen) }
    }

    /// The view needs more than the screen tier (zoom beyond fit) for the current image.
    public func requestFullResolution() {
        guard let file = currentFile else { return }
        schedule(file, .full)
    }

    /// Best tier decoded so far for `file`.
    public func best(for file: ImageFile) -> DecodedImage? {
        guard let tiers = cache[file.url] else { return nil }
        return tiers[.full] ?? tiers[.screen] ?? tiers[.preview]
    }

    public func info(for file: ImageFile) -> ImageInfo? { infos[file.url] }

    public func updateConfig(_ config: PipelineConfig) { self.config = config }

    /// Drop everything except the current image.
    public func handleMemoryPressure(critical: Bool) {
        let keep = currentFile?.url
        cache = cache.filter { $0.key == keep }
        pool.drain()
        recount()
    }

    private func schedule(_ file: ImageFile, _ tier: Tier) {
        if cache[file.url]?[tier] != nil { return }
        let key = "\(tier.rawValue)|\(file.url.path)"
        guard inFlight.insert(key).inserted else { return }
        let generation = self.generation
        let target = tier == .preview ? config.previewLongSide : config.screenLongSide
        let decoder = self.decoder, pool = self.pool
        lane.async { [weak self] in
            let stale = DispatchQueue.main.sync { self.map { $0.generation - generation > 2 } ?? true }
            if stale {
                DispatchQueue.main.async { self?.inFlight.remove(key) }
                return
            }
            let info = try? decoder.probe(file.url)
            let result = Result { try autoreleasepool { try decoder.decode(file.url, tier: tier, targetLongSide: target, pool: pool) } }
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(key)
                if let info { self.infos[file.url] = info }
                switch result {
                case .success(let image):
                    self.cache[file.url, default: [:]][tier] = image
                    self.stats.decodes += 1
                    self.evictIfNeeded()
                    self.onDecoded?(file, image)
                case .failure(let error):
                    self.onFailed?(file, error)
                }
            }
        }
    }

    private func evictIfNeeded() {
        recount()
        guard stats.cachedBytes > config.memoryBudget, let current = currentFile else { return }
        let position = Dictionary(uniqueKeysWithValues: files.enumerated().map { ($1.url, $0) })
        let byDistance = cache.keys.sorted {
            abs((position[$0] ?? .max / 2) - index) > abs((position[$1] ?? .max / 2) - index)
        }
        for url in byDistance where url != current.url && stats.cachedBytes > config.memoryBudget {
            cache[url] = nil
            recount()
        }
    }

    private func recount() {
        stats.cachedBytes = cache.values.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.pixels.allocatedBytes } }
    }
}
