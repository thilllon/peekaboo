import CoreGraphics
import Foundation
import ImageIO

/// One image file of the folder being browsed.
///
/// Identity is the file URL: two values for the same path are equal even when one
/// was created before the file was stat'ed. Cache validity uses `version`.
public struct ImageFile: Hashable, Sendable {
    public let url: URL
    public let name: String
    public let byteSize: Int64
    /// Content modification time (seconds since 1970); part of cache keys.
    public let modified: Double
    /// File identity (inode); stays stable across renames.
    public let fileID: UInt64

    public init(url: URL, name: String, byteSize: Int64, modified: Double, fileID: UInt64) {
        self.url = url
        self.name = name
        self.byteSize = byteSize
        self.modified = modified
        self.fileID = fileID
    }

    /// Changes whenever the file's contents may have changed (size or modification time).
    public var version: String { "\(byteSize)-\(modified)" }

    public static func == (a: ImageFile, b: ImageFile) -> Bool { a.url == b.url }
    public func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

/// Progressive quality tiers. Lower tiers arrive first and are replaced by higher ones.
public enum Tier: Int, Comparable, Sendable, CaseIterable {
    /// Tiny, near-instant pixels (embedded preview / 1/8 DCT decode), long side ~256–512 px.
    case preview = 0
    /// Decoded to (at least) the pixel size of the largest screen's fit rectangle.
    case screen = 1
    /// Full resolution (needed only when zooming beyond the screen tier).
    case full = 2

    public static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
}

/// Cheap metadata read without decoding pixels.
public struct ImageInfo: Sendable {
    /// Stored pixel size (before EXIF orientation).
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let orientation: CGImagePropertyOrientation
    public let typeIdentifier: String
    public let hasAlpha: Bool
    public let hasGainMap: Bool
    public let frameCount: Int
    public let colorProfileName: String?
    public let exif: [String: String]

    public init(pixelWidth: Int, pixelHeight: Int, orientation: CGImagePropertyOrientation,
                typeIdentifier: String, hasAlpha: Bool, hasGainMap: Bool, frameCount: Int,
                colorProfileName: String?, exif: [String: String]) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.orientation = orientation
        self.typeIdentifier = typeIdentifier
        self.hasAlpha = hasAlpha
        self.hasGainMap = hasGainMap
        self.frameCount = frameCount
        self.colorProfileName = colorProfileName
        self.exif = exif
    }

    /// Whether the orientation swaps width and height (EXIF 5–8).
    public var swapsAxes: Bool { orientation.rawValue >= 5 && orientation.rawValue <= 8 }
    /// Displayed (oriented) size.
    public var orientedWidth: Int { swapsAxes ? pixelHeight : pixelWidth }
    public var orientedHeight: Int { swapsAxes ? pixelWidth : pixelHeight }
}

/// Pixels of one tier of one image, ready for the GPU.
public struct DecodedImage: @unchecked Sendable {
    public let pixels: PixelBuffer
    public let tier: Tier
    /// Oriented size of the full-resolution image, so lower tiers can be laid out at final size.
    public let fullWidth: Int
    public let fullHeight: Int
    /// Orientation the renderer must still apply (`.up` when the decoder already applied it).
    public let orientation: CGImagePropertyOrientation
    /// Values may exceed 1.0 (HDR / EDR content).
    public let isHDR: Bool
    /// Wall time spent decoding, for tracing and the scheduler's cost model.
    public let decodeNanos: UInt64
    /// An early rendition of `tier` (same geometry, fewer bits: the first-pass scans of a progressive JPEG) delivered
    /// through a `PartialSink` while the exact decode continues. Never cached; the exact tier replaces it.
    public let isApproximate: Bool

    public init(pixels: PixelBuffer, tier: Tier, fullWidth: Int, fullHeight: Int,
                orientation: CGImagePropertyOrientation, isHDR: Bool, decodeNanos: UInt64, isApproximate: Bool = false) {
        self.pixels = pixels
        self.tier = tier
        self.fullWidth = fullWidth
        self.fullHeight = fullHeight
        self.orientation = orientation
        self.isHDR = isHDR
        self.decodeNanos = decodeNanos
        self.isApproximate = isApproximate
    }
}

/// Where a decoder hands an early, approximate rendition of the tier it is decoding (`DecodedImage.isApproximate`),
/// from any thread, before the exact one is returned.
public struct PartialSink: Sendable {
    /// Whether an early rendition is still worth its cost (the image is on screen and this tier not yet decoded).
    public let wanted: @Sendable () -> Bool
    public let deliver: @Sendable (DecodedImage) -> Void

    public init(wanted: @escaping @Sendable () -> Bool, deliver: @escaping @Sendable (DecodedImage) -> Void) {
        self.wanted = wanted
        self.deliver = deliver
    }
}

public enum DecodeError: Error, Equatable {
    case unreadable(String)
    case unsupported(String)
    case outOfMemory
}

/// Which shared resource a decode occupies, so the scheduler can bound concurrency per
/// resource: the hardware JPEG/HEVC engines (≈2 concurrent jobs), CPU decoders
/// (libjpeg-turbo, one core each) and everything else ImageIO does.
public enum DecodeLane: Sendable, Hashable, CaseIterable {
    case hardware
    case cpu
    case general
}

/// A decoder backend. Implementations must be thread-safe: the scheduler calls
/// them concurrently from several worker threads. A decode cannot be aborted once
/// started, so callers cancel before starting rather than during.
public protocol ImageDecoder: Sendable {
    func probe(_ url: URL) throws -> ImageInfo
    /// Decode one tier. `targetLongSide` bounds the output long side for `.preview`/`.screen`
    /// (the decoder may return up to ~2x larger when that is cheaper); ignored for `.full`.
    func decode(_ url: URL, tier: Tier, targetLongSide: Int, pool: PixelBufferPool) throws -> DecodedImage
    /// `decode`, handing `partial` an early rendition first when the file allows a cheap one (progressive JPEG).
    func decode(_ url: URL, tier: Tier, targetLongSide: Int, pool: PixelBufferPool, partial: PartialSink?) throws
        -> DecodedImage
    /// The lane `decode` would use for this file and tier (cheap; `info` may be nil before probing).
    func lane(for url: URL, info: ImageInfo?, tier: Tier) -> DecodeLane
}

public extension ImageDecoder {
    func lane(for url: URL, info: ImageInfo?, tier: Tier) -> DecodeLane { .general }

    func decode(_ url: URL, tier: Tier, targetLongSide: Int, pool: PixelBufferPool, partial: PartialSink?) throws
        -> DecodedImage {
        try decode(url, tier: tier, targetLongSide: targetLongSide, pool: pool)
    }
}
