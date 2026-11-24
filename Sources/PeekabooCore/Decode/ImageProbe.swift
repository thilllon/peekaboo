import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What the decoder needs to know about a file to route it, gathered in one pass over its
/// metadata (ImageIO properties 0.07–0.6 ms, RAW 1.3–2.6 ms; JPEG marker scan ~20 µs).
struct ImageProbe {
    enum Kind: Equatable {
        case jpeg(JPEGScan)
        /// HEIC / HEIF / AVIF: hardware HEVC/AV1 through ImageIO.
        case heif
        case raw(cr3: Bool)
        /// PNG, WebP, TIFF, GIF, JPEG XL, PSD, EXR, …
        case other
    }

    let source: CGImageSource
    let index: Int
    let kind: Kind
    let info: ImageInfo
    /// HEIF thumbnail item(s) listed in the container (cheap embedded preview).
    let hasThumbnailItem: Bool

    static let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary

    init(url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, Self.sourceOptions) else {
            throw DecodeError.unreadable(url.lastPathComponent)
        }
        try self.init(source: source, url: url, jpegBytes: nil)
    }

    /// `jpegBytes`: in-memory JPEG (CR3 previews) to scan instead of the file.
    init(source: CGImageSource, url: URL, jpegBytes: UnsafeRawBufferPointer?) throws {
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
        let utType = UTType(type)
        if type == UTType.jpeg.identifier {
            let scan = jpegBytes.flatMap { JPEGScan.scan(bytes: $0) } ?? JPEGScan.scan(url: url)
            if let scan {
                kind = .jpeg(scan)
                hasGainMap = scan.gainMapHint || (scan.hasMPF && Self.auxiliaryGainMap(source, index))
            }
        } else if ["public.heic", "public.heif", "public.avif", "public.heics", "public.avci", "public.avis"].contains(type) {
            kind = .heif
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
        self.kind = kind
        self.hasThumbnailItem = hasThumbnailItem
        info = ImageInfo(pixelWidth: width, pixelHeight: height, orientation: orientation, typeIdentifier: type,
                         hasAlpha: alpha, hasGainMap: hasGainMap, frameCount: CGImageSourceGetCount(source),
                         colorProfileName: profile, exif: exif)
    }

    private static func containerImage(_ source: CGImageSource, _ index: Int) -> [CFString: Any]? {
        guard let props = CGImageSourceCopyProperties(source, sourceOptions) as? [CFString: Any],
              let contents = props[kCGImagePropertyFileContentsDictionary] as? [CFString: Any],
              let images = contents[kCGImagePropertyImages] as? [[CFString: Any]] else { return nil }
        return index < images.count ? images[index] : images.first
    }

    private static func auxiliaryGainMap(_ source: CGImageSource, _ index: Int) -> Bool {
        if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, kCGImageAuxiliaryDataTypeISOGainMap) != nil { return true }
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
        if let focal = number(exif[kCGImagePropertyExifFocalLength]), focal > 0 { out["focal"] = "\(trim(focal)) mm" }
        if let f = number(exif[kCGImagePropertyExifFNumber]), f > 0 { out["aperture"] = "f/\(trim(f))" }
        if let t = number(exif[kCGImagePropertyExifExposureTime]), t > 0 { out["shutter"] = shutter(t) }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Any])?.first.flatMap(number), iso > 0 {
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

    /// 35 → "35", 2.8 → "2.8", 8.0 → "8", 4.5 → "4.5".
    static func trim(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }

    /// 0.004 → "1/250 s", 0.5 → "1/2 s", 2 → "2 s", 1.3 → "1.3 s".
    static func shutter(_ seconds: Double) -> String {
        if seconds < 1 {
            let denominator = (1 / seconds).rounded()
            if abs(1 / denominator - seconds) / seconds < 0.05 { return "1/\(Int(denominator)) s" }
            return "\(trim(seconds)) s"
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
