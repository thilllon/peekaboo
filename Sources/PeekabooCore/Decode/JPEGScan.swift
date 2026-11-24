import Foundation

/// Facts read from a JPEG's marker segments without decoding any pixels: a handful of
/// `pread`s over the header (tens of microseconds). Drives routing between the hardware
/// engines, libjpeg-turbo and ImageIO.
struct JPEGScan: Equatable {
    enum Coding: Equatable {
        /// SOF0 / SOF1 Huffman, sequential: hardware-decodable.
        case baseline
        case progressive
        case lossless
        case arithmetic
    }

    var coding: Coding
    var width: Int
    var height: Int
    var components: Int
    /// Luma (first component) sampling factors relative to the others.
    var lumaH = 1
    var lumaV = 1
    /// APP14 "Adobe" colour transform (0 = none / RGB or CMYK, 1 = YCbCr, 2 = YCCK).
    var adobeTransform: Int?
    /// EXIF IFD1 holds a JPEG thumbnail (JPEGInterchangeFormat/Length).
    var hasEXIFThumbnail = false
    /// APP2 "MPF" (multi-picture: large previews, gain maps).
    var hasMPF = false
    /// XMP or APP2 metadata announcing an HDR gain map (Ultra HDR `hdrgm`, ISO 21496-1, Apple).
    var gainMapHint = false

    var isCMYK: Bool { components == 4 }

    /// "4:2:0", "4:4:4", … for YCbCr, "gray", "CMYK" or "YCCK".
    var chroma: String {
        switch components {
        case 1: return "gray"
        case 4: return adobeTransform == 2 ? "YCCK" : "CMYK"
        default:
            switch (lumaH, lumaV) {
            case (1, 1): return "4:4:4"
            case (2, 1): return "4:2:2"
            case (1, 2): return "4:4:0"
            case (2, 2): return "4:2:0"
            case (4, 1): return "4:1:1"
            case (4, 2): return "4:1:0"
            default: return "\(lumaH)x\(lumaV)"
            }
        }
    }

    /// Human-readable coding, e.g. "JPEG baseline 4:2:0", "JPEG progressive 4:4:4".
    var formatName: String {
        switch coding {
        case .baseline: return "JPEG baseline \(chroma)"
        case .progressive: return "JPEG progressive \(chroma)"
        case .lossless: return "JPEG lossless"
        case .arithmetic: return "JPEG arithmetic \(chroma)"
        }
    }

    /// Scan the file at `url`. Returns nil when it is not a parsable JPEG.
    static func scan(url: URL) -> JPEGScan? {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return scan { offset, count in
            var data = [UInt8](repeating: 0, count: count)
            let n = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
            return n == count ? data : (n > 0 ? Array(data[0..<n]) : nil)
        }
    }

    /// Scan JPEG bytes held in memory.
    static func scan(bytes: UnsafeRawBufferPointer) -> JPEGScan? {
        scan { offset, count in
            guard offset >= 0, offset < bytes.count else { return nil }
            let end = min(bytes.count, offset + count)
            return Array(bytes[offset..<end])
        }
    }

    /// Marker walk over a random-access reader `read(offset, count) -> bytes`.
    static func scan(_ read: (Int, Int) -> [UInt8]?) -> JPEGScan? {
        guard let soi = read(0, 2), soi == [0xFF, 0xD8] else { return nil }
        var result = JPEGScan(coding: .baseline, width: 0, height: 0, components: 0)
        var offset = 2
        var sawFrame = false
        for _ in 0..<512 {
            guard let head = read(offset, 4), head.count == 4 else { break }
            guard head[0] == 0xFF else { break }
            let marker = head[1]
            if marker == 0xFF { offset += 1; continue }  // fill byte
            if marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD7) || marker == 0x01 { offset += 2; continue }
            if marker == 0xD9 || marker == 0xDA { break }  // EOI / SOS: header is over
            let length = Int(head[2]) << 8 | Int(head[3])
            guard length >= 2 else { break }
            let body = offset + 4
            switch marker {
            case 0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF:
                guard let sof = read(body, length - 2), sof.count >= 6 else { return nil }
                result.height = Int(sof[1]) << 8 | Int(sof[2])
                result.width = Int(sof[3]) << 8 | Int(sof[4])
                result.components = Int(sof[5])
                if sof.count >= 9, result.components > 0 {
                    result.lumaH = Int(sof[7] >> 4)
                    result.lumaV = Int(sof[7] & 0x0F)
                    // Normalise against the largest chroma factors (usually 1x1).
                    if result.components >= 3, sof.count >= 6 + 3 * 3 {
                        let ch = Int(sof[10] >> 4), cv = Int(sof[10] & 0x0F)
                        if ch > 0, cv > 0 { result.lumaH /= ch; result.lumaV /= cv }
                    }
                }
                switch marker {
                case 0xC0, 0xC1: result.coding = .baseline
                case 0xC2: result.coding = .progressive
                case 0xC3, 0xC7, 0xCB, 0xCF: result.coding = .lossless
                default: result.coding = .arithmetic
                }
                if marker == 0xCA { result.coding = .arithmetic }
                sawFrame = true
            case 0xE1:
                if let seg = read(body, min(length - 2, 65_533)) { parseAPP1(seg, into: &result) }
            case 0xE2:
                if let seg = read(body, min(length - 2, 64)) {
                    if seg.starts(with: Array("MPF\0".utf8)) { result.hasMPF = true }
                    if seg.starts(with: Array("urn:iso:std:iso:ts:21496:-1".utf8)) { result.gainMapHint = true }
                }
            case 0xEE:
                if let seg = read(body, min(length - 2, 12)), seg.count >= 12, seg.starts(with: Array("Adobe".utf8)) {
                    result.adobeTransform = Int(seg[11])
                }
            default:
                break
            }
            offset = body + length - 2
        }
        guard sawFrame, result.width > 0, result.height > 0 else { return nil }
        return result
    }

    private static func parseAPP1(_ seg: [UInt8], into result: inout JPEGScan) {
        let exif = Array("Exif\0\0".utf8)
        if seg.starts(with: exif) {
            result.hasEXIFThumbnail = exifHasThumbnail(Array(seg[6...]))
            return
        }
        let xmp = Array("http://ns.adobe.com/xap/1.0/\0".utf8)
        if seg.starts(with: xmp) {
            // Ultra HDR / ISO gain map namespace, Apple's HDR gain map tags (memmem: microseconds for 64 KB).
            if contains(seg, "hdrgm:") || contains(seg, "HDRGainMap") { result.gainMapHint = true }
        }
    }

    private static func contains(_ haystack: [UInt8], _ needle: String) -> Bool {
        let pattern = Array(needle.utf8)
        return haystack.withUnsafeBytes { h in
            pattern.withUnsafeBytes { n in memmem(h.baseAddress, h.count, n.baseAddress, n.count) != nil }
        }
    }

    /// True when IFD1 of the TIFF structure in an EXIF APP1 points at a non-empty JPEG thumbnail.
    static func exifHasThumbnail(_ tiff: [UInt8]) -> Bool {
        guard tiff.count >= 8 else { return false }
        let little: Bool
        if tiff[0] == 0x49, tiff[1] == 0x49 { little = true } else if tiff[0] == 0x4D, tiff[1] == 0x4D { little = false } else { return false }
        func u16(_ o: Int) -> Int? {
            guard o >= 0, o + 2 <= tiff.count else { return nil }
            return little ? Int(tiff[o]) | Int(tiff[o + 1]) << 8 : Int(tiff[o]) << 8 | Int(tiff[o + 1])
        }
        func u32(_ o: Int) -> Int? {
            guard o >= 0, o + 4 <= tiff.count else { return nil }
            let b = (Int(tiff[o]), Int(tiff[o + 1]), Int(tiff[o + 2]), Int(tiff[o + 3]))
            return little ? b.0 | b.1 << 8 | b.2 << 16 | b.3 << 24 : b.0 << 24 | b.1 << 16 | b.2 << 8 | b.3
        }
        guard let ifd0 = u32(4), let count0 = u16(ifd0) else { return false }
        guard let ifd1 = u32(ifd0 + 2 + count0 * 12), ifd1 > 0, let count1 = u16(ifd1), count1 < 512 else { return false }
        var offset = 0, length = 0
        for i in 0..<count1 {
            let entry = ifd1 + 2 + i * 12
            guard let tag = u16(entry) else { return false }
            if tag == 0x0201 { offset = u32(entry + 8) ?? 0 }
            if tag == 0x0202 { length = u32(entry + 8) ?? 0 }
        }
        return offset > 0 && length > 0
    }
}
