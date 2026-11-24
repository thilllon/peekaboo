import Foundation

/// Decode-cost estimates per (format family, megapixel bucket, tier): an EWMA (weight 0.3) of measured
/// durations normalised by concurrency, seeded from the measurements in docs/DESIGN.md §2.
/// Main-thread only (written when results are delivered, read by the planner).
struct CostModel {
    enum Family: Int, CaseIterable {
        case jpeg, heic, avif, png, webp, tiff, gif, raw, other
    }

    private struct Key: Hashable {
        let family: Family
        let bucket: Int8
        let tier: Tier
    }

    private var ewma: [Key: Double] = [:]
    private var familyEWMA: [Key: Double] = [:]
    var alpha = 0.12

    static let rawExtensions: Set<String> = [
        "arw", "cr2", "cr3", "crw", "nef", "nrw", "raf", "dng", "orf", "rw2", "pef", "srw", "3fr", "iiq",
        "erf", "mef", "mos", "mrw", "x3f", "rwl", "srf", "sr2", "kdc", "dcr",
    ]

    static func family(of url: URL) -> Family {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "jpe", "jfif", "jif": return .jpeg
        case "heic", "heif", "hif", "heics": return .heic
        case "avif", "avifs": return .avif
        case "png", "apng": return .png
        case "webp": return .webp
        case "tif", "tiff": return .tiff
        case "gif": return .gif
        case let ext where rawExtensions.contains(ext): return .raw
        default: return .other
        }
    }

    /// Seed costs (ms) for a 24 MP image: preview, screen, full (docs/DESIGN.md §2 measurements; previews assume an
    /// embedded thumbnail and are corrected by the first measurement).
    private static func seed(_ family: Family) -> (Double, Double, Double) {
        switch family {
        case .jpeg: return (4, 45, 50)
        case .heic: return (3, 35, 50)
        case .avif: return (48, 60, 70)
        case .png: return (277, 270, 280)
        case .webp: return (303, 290, 290)
        case .tiff: return (23, 100, 150)
        case .gif: return (10, 20, 20)
        case .raw: return (25, 80, 500)
        case .other: return (50, 100, 200)
        }
    }

    private static func bucket(megapixels: Double?) -> Int8 {
        guard let mp = megapixels else { return -1 }
        switch mp {
        case ..<13: return 0
        case ..<25: return 1
        case ..<37: return 2
        case ..<51: return 3
        default: return 4
        }
    }

    static func megapixels(_ info: ImageInfo?) -> Double? {
        guard let info, info.pixelWidth > 0, info.pixelHeight > 0 else { return nil }
        return Double(info.pixelWidth) * Double(info.pixelHeight) / 1e6
    }

    func estimate(url: URL, info: ImageInfo?, tier: Tier) -> Double {
        estimate(family: Self.family(of: url), megapixels: Self.megapixels(info), tier: tier)
    }

    func estimate(family: Family, megapixels mp: Double?, tier: Tier) -> Double {
        if let value = ewma[Key(family: family, bucket: Self.bucket(megapixels: mp), tier: tier)] { return value }
        if let value = familyEWMA[Key(family: family, bucket: -1, tier: tier)] { return value }
        let seed = Self.seed(family)
        let base = tier == .preview ? seed.0 : tier == .screen ? seed.1 : seed.2
        // Embedded previews do not scale with the image; decodes do (roughly linearly in pixels).
        guard tier != .preview, let mp else { return base }
        return base * min(max(mp / 24, 0.25), 6)
    }

    /// Record a measured decode. `concurrency` = decodes running when it started (including itself).
    mutating func record(url: URL, info: ImageInfo?, tier: Tier, ms: Double, concurrency: Int) {
        record(family: Self.family(of: url), megapixels: Self.megapixels(info), tier: tier, ms: ms, concurrency: concurrency)
    }

    mutating func record(family: Family, megapixels: Double?, tier: Tier, ms: Double, concurrency: Int) {
        let normalised = ms / (1 + alpha * Double(max(0, concurrency - 1)))
        let key = Key(family: family, bucket: Self.bucket(megapixels: megapixels), tier: tier)
        ewma[key] = ewma[key].map { 0.7 * $0 + 0.3 * normalised } ?? normalised
        let fkey = Key(family: family, bucket: -1, tier: tier)
        familyEWMA[fkey] = familyEWMA[fkey].map { 0.7 * $0 + 0.3 * normalised } ?? normalised
    }
}
