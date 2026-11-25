import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What the decoder needs to know about a file to route it, gathered in one pass over its
/// metadata (ImageIO properties 0.07–0.6 ms, RAW 1.3–2.6 ms; JPEG marker scan ~20 µs).
struct DecodeProbe {
    enum Kind: Equatable {
        case jpeg(JPEGScan)
        /// HEIC / HEIF / AVIF: hardware HEVC/AV1 through ImageIO.
        case heif
        case raw(cr3: Bool)
        /// PNG, WebP, TIFF, GIF, JPEG XL, PSD, EXR, …
        case other
    }

    /// Everything the probe learned except the (per-call) source, cached across calls.
    struct Facts {
        let index: Int
        let kind: Kind
        let info: ImageInfo
        let hasThumbnailItem: Bool
        let bitDepth: Int
        let nclxMatrix: Int?
    }

    let source: CGImageSource
    let index: Int
    let kind: Kind
    let info: ImageInfo
    /// HEIF thumbnail item(s) listed in the container (cheap embedded preview).
    let hasThumbnailItem: Bool
    /// `ImageInfo.hdrTransfer`: shown through ImageIO's tone-mapped SDR rendition, or decoded to HDR with `decodeHDR`.
    var hdrTransfer: Bool { info.hdrTransfer }
    /// Bits per component as stored (`kCGImagePropertyDepth`; 8 when absent).
    let bitDepth: Int
    /// HEIF / AVIF: the YCbCr matrix the file declares (`HEIFColour`), nil when it declares none.
    let nclxMatrix: Int?

    var facts: Facts {
        Facts(index: index, kind: kind, info: info, hasThumbnailItem: hasThumbnailItem, bitDepth: bitDepth,
              nclxMatrix: nclxMatrix)
    }

    static let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary

    /// A fresh source for a file whose metadata was already parsed (`CreateWithURL` reads nothing).
    init(source: CGImageSource, facts: Facts) {
        self.source = source
        index = facts.index
        kind = facts.kind
        info = facts.info
        hasThumbnailItem = facts.hasThumbnailItem
        bitDepth = facts.bitDepth
        nclxMatrix = facts.nclxMatrix
    }

    init(url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, Self.sourceOptions) else {
            throw DecodeError.unreadable(url.lastPathComponent)
        }
        try self.init(source: source, url: url, bytes: nil)
    }

    /// `bytes`: the file in memory (CR3 previews: a JPEG, or a HEIF around HEVC tiles), read instead of `url`.
    init(source: CGImageSource, url: URL, bytes: UnsafeRawBufferPointer?) throws {
        self.source = source
        let type = (CGImageSourceGetType(source) as String?) ?? ""
        guard !type.isEmpty else { throw DecodeError.unsupported(url.lastPathComponent) }
        index = CGImageSourceGetPrimaryImageIndex(source)
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, Self.sourceOptions) as? [CFString: Any] else {
            throw DecodeError.unreadable(url.lastPathComponent)
        }
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0 else { throw DecodeError.unsupported(url.lastPathComponent) }
        let rawOrientation = props[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) ?? .up

        var kind = Kind.other
        var hasThumbnailItem = false
        var hasGainMap = false
        var nclxMatrix: Int?
        let utType = UTType(type)
        if type == UTType.jpeg.identifier {
            let scan = bytes.flatMap { JPEGScan.scan(bytes: $0) } ?? JPEGScan.scan(url: url)
            if let scan {
                kind = .jpeg(scan)
                hasGainMap = scan.gainMapHint || (scan.hasMPF && Self.auxiliaryGainMap(source, index))
            }
        } else if ["public.heic", "public.heif", "public.avif", "public.heics", "public.avci", "public.avis"].contains(type) {
            kind = .heif
            nclxMatrix = bytes.map { HEIFColour.matrixCoefficients(file: $0) } ?? HEIFColour.matrixCoefficients(url: url)
            let container = Self.containerImage(source, index)
            hasThumbnailItem = !((container?[kCGImagePropertyThumbnailImages] as? [Any])?.isEmpty ?? true)
            if let aux = container?[kCGImagePropertyAuxiliaryData] as? [[CFString: Any]] {
                hasGainMap = aux.contains { ($0[kCGImagePropertyAuxiliaryDataType] as? String)?.contains("GainMap") ?? false }
            } else {
                hasGainMap = Self.auxiliaryGainMap(source, index)
            }
        } else if utType?.conforms(to: .rawImage) ?? false || type.hasSuffix("raw-image") {
            kind = .raw(cr3: type == "com.canon.cr3-raw-image")
        }

        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exifProps = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let profile = props[kCGImagePropertyProfileName] as? String
        var exif = Self.exifSummary(tiff: tiff, exif: exifProps,
                                    aux: props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:])
        if let profile { exif["profile"] = profile }
        exif["format"] = Self.formatName(kind: kind, type: type, make: tiff[kCGImagePropertyTIFFMake] as? String)

        let alpha = props[kCGImagePropertyHasAlpha] as? Bool ?? false
        // Only deep images can carry PQ / HLG; the colour space comes from the lazy, header-only CGImage (not for RAW:
        // creating one there sets up the RAW pipeline).
        bitDepth = props[kCGImagePropertyDepth] as? Int ?? 8
        var hdrTransfer = false
        if bitDepth > 8, kind == .heif || kind == .other,
           let image = CGImageSourceCreateImageAtIndex(source, index, Self.sourceOptions), let space = image.colorSpace {
            hdrTransfer = CGColorSpaceUsesITUR_2100TF(space)
        }
        self.nclxMatrix = nclxMatrix
        self.kind = kind
        self.hasThumbnailItem = hasThumbnailItem
        info = ImageInfo(pixelWidth: width, pixelHeight: height, orientation: orientation, typeIdentifier: type,
                         hasAlpha: alpha, hasGainMap: hasGainMap, hdrTransfer: hdrTransfer,
                         frameCount: CGImageSourceGetCount(source), colorProfileName: profile, exif: exif)
    }

    /// Probe through `cache`: ImageIO's metadata parse (`CopyPropertiesAtIndex`, 0.1–3 ms on XMP-heavy
    /// files) then runs once per file version instead of once per tier; the decode paths themselves
    /// only need a fresh source.
    static func make(url: URL, cache: DecodeProbeCache) throws -> DecodeProbe {
        let key = DecodeProbeCache.key(url)
        if let key, let facts = cache[key] {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
                throw DecodeError.unreadable(url.lastPathComponent)
            }
            return DecodeProbe(source: source, facts: facts)
        }
        let probe = try DecodeProbe(url: url)
        if let key { cache[key] = probe.facts }
        return probe
    }

    private static func containerImage(_ source: CGImageSource, _ index: Int) -> [CFString: Any]? {
        guard let props = CGImageSourceCopyProperties(source, sourceOptions) as? [CFString: Any],
              let contents = props[kCGImagePropertyFileContentsDictionary] as? [CFString: Any],
              let images = contents[kCGImagePropertyImages] as? [[CFString: Any]] else { return nil }
        return index < images.count ? images[index] : images.first
    }

    private static func auxiliaryGainMap(_ source: CGImageSource, _ index: Int) -> Bool {
        // ISO 21496-1 gain maps: ImageIO reads them from macOS 15; older systems only know Apple's.
        if #available(macOS 15, *),
           CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, kCGImageAuxiliaryDataTypeISOGainMap) != nil { return true }
        return CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
    }

    // MARK: - Formatting

    static func formatName(kind: Kind, type: String, make: String?) -> String {
        if case .jpeg(let scan) = kind { return scan.formatName }
        switch type {
        case "public.jpeg": return "JPEG"
        case "public.heic", "public.heics": return "HEIC"
        case "public.heif": return "HEIF"
        case "public.avif", "public.avis": return "AVIF"
        case "public.avci": return "AVCI"
        case "public.png": return "PNG"
        case "org.webmproject.webp": return "WebP"
        case "public.tiff": return "TIFF"
        case "com.compuserve.gif": return "GIF"
        case "public.jpeg-xl": return "JPEG XL"
        case "public.jpeg-2000": return "JPEG 2000"
        case "com.adobe.photoshop-image": return "PSD"
        case "com.ilm.openexr-image": return "OpenEXR"
        case "public.radiance": return "Radiance HDR"
        case "com.microsoft.bmp": return "BMP"
        case "com.microsoft.ico": return "ICO"
        case "com.apple.icns": return "ICNS"
        case "com.truevision.tga-image": return "TGA"
        case "com.sony.arw-raw-image": return "Sony ARW"
        case "com.sony.raw-image": return "Sony SRF"
        case "com.sony.sr2-raw-image": return "Sony SR2"
        case "com.canon.cr3-raw-image": return "Canon CR3"
        case "com.canon.cr2-raw-image": return "Canon CR2"
        case "com.canon.crw-raw-image": return "Canon CRW"
        case "com.nikon.raw-image": return "Nikon NEF"
        case "com.nikon.nrw-raw-image": return "Nikon NRW"
        case "com.fuji.raw-image": return "Fujifilm RAF"
        case "com.olympus.raw-image", "com.olympus.or-raw-image": return "Olympus ORF"
        case "com.panasonic.raw-image", "com.panasonic.rw2-raw-image": return "Panasonic RW2"
        case "com.pentax.raw-image": return "Pentax PEF"
        case "com.leica.raw-image", "com.leica.rwl-raw-image": return "Leica RAW"
        case "com.hasselblad.fff-raw-image", "com.hasselblad.3fr-raw-image": return "Hasselblad RAW"
        case "com.adobe.raw-image": return make?.trimmingCharacters(in: .whitespaces) == "Apple" ? "Apple ProRAW DNG" : "DNG"
        default:
            if let ext = UTType(type)?.preferredFilenameExtension { return ext.uppercased() }
            return type
        }
    }

    static func exifSummary(tiff: [CFString: Any], exif: [CFString: Any], aux: [CFString: Any]) -> [String: String] {
        var out: [String: String] = [:]
        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !make.isEmpty || !model.isEmpty {
            let firstWord = make.split(separator: " ").first.map(String.init) ?? make
            if model.isEmpty { out["camera"] = make } else if make.isEmpty || model.lowercased().hasPrefix(firstWord.lowercased()) {
                out["camera"] = model
            } else {
                out["camera"] = "\(make) \(model)"
            }
        }
        if let lens = (exif[kCGImagePropertyExifLensModel] as? String) ?? (aux[kCGImagePropertyExifAuxLensModel] as? String),
           !lens.trimmingCharacters(in: .whitespaces).isEmpty {
            out["lens"] = lens.trimmingCharacters(in: .whitespaces)
        }
        // XMP `exif:` values arrive as doubles of any size (ImageIO saturates huge integers at 2^63). Values
        // beyond any camera (focal length 100 m, f/10000, exposures outside 1 ns … ~4 months, ISO 10^8) are
        // corrupt or crafted: leave them out.
        if let focal = number(exif[kCGImagePropertyExifFocalLength]), focal > 0, focal <= 100_000 {
            out["focal"] = "\(trim(focal)) mm"
        }
        if let f = number(exif[kCGImagePropertyExifFNumber]), f > 0, f <= 10_000 { out["aperture"] = "f/\(trim(f))" }
        if let t = number(exif[kCGImagePropertyExifExposureTime]), t >= 1e-9, t <= 1e7 { out["shutter"] = shutter(t) }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Any])?.first.flatMap(number), iso > 0, iso <= 1e8 {
            out["iso"] = "ISO \(Int(iso.rounded()))"
        }
        if let date = (exif[kCGImagePropertyExifDateTimeOriginal] as? String) ?? (tiff[kCGImagePropertyTIFFDateTime] as? String),
           let formatted = formatDate(date) {
            out["date"] = formatted
        }
        return out
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let d = value as? Double { return d }
        return nil
    }

    /// 35 → "35", 2.8 → "2.8", 8.0 → "8", 4.5 → "4.5". Total: `Int(exactly:)` declines values beyond
    /// Int's range and non-finite ones (where `Int(_:)` traps), which then print as "%.1f".
    static func trim(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if let whole = Int(exactly: rounded) { return String(whole) }
        return String(format: "%.1f", rounded)
    }

    /// 0.004 → "1/250 s", 0.5 → "1/2 s", 2 → "2 s", 1.3 → "1.3 s". Total, like `trim`.
    static func shutter(_ seconds: Double) -> String {
        if seconds < 1 {
            let denominator = (1 / seconds).rounded()
            if let whole = Int(exactly: denominator), abs(1 / denominator - seconds) / seconds < 0.05 { return "1/\(whole) s" }
        }
        return "\(trim(seconds)) s"
    }

    /// EXIF "2026:05:01 14:03:22" → "2026-05-01 14:03".
    static func formatDate(_ exifDate: String) -> String? {
        let chars = Array(exifDate.trimmingCharacters(in: .whitespaces))
        guard chars.count >= 16 else { return nil }
        let date = String(chars[0..<10]).replacingOccurrences(of: ":", with: "-")
        let time = String(chars[11..<16])
        guard date.count == 10, date != "0000-00-00" else { return nil }
        return "\(date) \(time)"
    }
}
