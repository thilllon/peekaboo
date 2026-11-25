import Foundation
import ImageIO

public extension ImageInfo {
    /// The file is an animation Peekaboo plays: GIF, APNG, animated WebP, HEIC or AVIF sequences, with more than one
    /// frame. Other multi-image files (HEIC collections such as dynamic wallpapers, TIFF pages, ICO sizes) are stills.
    var isAnimated: Bool { frameCount > 1 && AnimationTiming.animatedTypes.contains(typeIdentifier) }
}

/// How long each frame of an animation stays on screen, and how often it plays.
public struct AnimationTiming: Sendable, Equatable {
    /// Seconds per frame, clamped like browsers (`clamp`).
    public let delays: [Double]
    /// Number of plays; 0 = forever. ImageIO reports every format this way (a GIF's NETSCAPE repeat count + 1, an APNG's
    /// `num_plays`, a WebP's loop count; a GIF without the extension plays once).
    public let loopCount: Int

    public init(delays: [Double], loopCount: Int) {
        self.delays = delays
        self.loopCount = max(0, loopCount)
    }

    public var frameCount: Int { delays.count }

    /// Type identifiers whose multi-image files are animations.
    public static let animatedTypes: Set<String> = [
        "com.compuserve.gif", "public.png", "org.webmproject.webp", "public.heics", "public.avis",
    ]

    /// Browsers show a frame declared at ≤ 10 ms (0 means "as fast as possible" to most encoders) for 100 ms.
    /// Rounded to whole microseconds (ImageIO stores some delays as 32-bit floats: 0.05 reads 0.0500000007).
    public static func clamp(_ seconds: Double?) -> Double {
        guard let seconds, seconds.isFinite, seconds > 0.010 else { return 0.1 }
        return (min(seconds, 3600) * 1e6).rounded() / 1e6
    }

    /// The animation dictionary (`{GIF}`, `{PNG}`, `{WebP}`, `{HEICS}`, `{AVIS}`) of container or frame properties.
    /// Every format uses the same key strings ("FrameInfo", "UnclampedDelayTime", "DelayTime", "LoopCount").
    static func animationDictionary(_ properties: [CFString: Any]) -> [CFString: Any]? {
        let keys = [kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary, kCGImagePropertyWebPDictionary,
                    kCGImagePropertyHEICSDictionary, kCGImagePropertyAVISDictionary]
        return keys.lazy.compactMap { properties[$0] as? [CFString: Any] }.first
    }

    static func seconds(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
}
