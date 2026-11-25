import Foundation

/// Hand-made animated GIF and APNG files with explicit disposal, blending, sub-rectangles, transparency, delays and
/// loop counts, so the tests know exactly what every composited frame must look like.
enum GIFWriter {
    struct Frame {
        var x = 0, y = 0, width: Int, height: Int
        /// Palette indices, row-major.
        var pixels: [UInt8]
        /// Centiseconds.
        var delay = 10
        /// 1 keep, 2 restore to background, 3 restore to previous.
        var disposal = 1
        var transparentIndex: Int?
    }

    /// `loopCount`: the NETSCAPE2.0 repeat count (0 = forever); nil writes no extension (plays once).
    static func make(width: Int, height: Int, palette: [(UInt8, UInt8, UInt8)], loopCount: Int?, frames: [Frame]) -> Data {
        var d = Data("GIF89a".utf8)
        func u16(_ v: Int) { d.append(UInt8(v & 0xff)); d.append(UInt8(v >> 8 & 0xff)) }
        u16(width); u16(height)
        d.append(0xF7)  // global colour table of 256 entries
        d.append(0); d.append(0)
        for i in 0..<256 {
            let c = i < palette.count ? palette[i] : (0, 0, 0)
            d.append(c.0); d.append(c.1); d.append(c.2)
        }
        if let loopCount {
            d.append(contentsOf: [0x21, 0xFF, 0x0B] + Array("NETSCAPE2.0".utf8) + [0x03, 0x01])
            u16(loopCount)
            d.append(0)
        }
        for f in frames {
            d.append(contentsOf: [0x21, 0xF9, 0x04, UInt8((f.disposal & 7) << 2 | (f.transparentIndex == nil ? 0 : 1))])
            u16(f.delay)
            d.append(UInt8(f.transparentIndex ?? 0)); d.append(0)
            d.append(0x2C); u16(f.x); u16(f.y); u16(f.width); u16(f.height); d.append(0)
            // LZW with 9-bit codes only: a clear code every 254 literals keeps the code width from growing.
            d.append(8)
            var codes = [256]
            for (i, p) in f.pixels.enumerated() {
                codes.append(Int(p))
                if i % 254 == 253 { codes.append(256) }
            }
            codes.append(257)
            var bytes: [UInt8] = []
            var acc = 0, n = 0
            for code in codes {
                acc |= code << n
                n += 9
                while n >= 8 { bytes.append(UInt8(acc & 0xff)); acc >>= 8; n -= 8 }
            }
            if n > 0 { bytes.append(UInt8(acc & 0xff)) }
            var i = 0
            while i < bytes.count {
                let chunk = min(255, bytes.count - i)
                d.append(UInt8(chunk)); d.append(contentsOf: bytes[i..<(i + chunk)]); i += chunk
            }
            d.append(0)
        }
        d.append(0x3B)
        return d
    }
}

enum APNGWriter {
    struct Frame {
        var x = 0, y = 0, width: Int, height: Int
        /// RGBA, row-major.
        var rgba: [UInt8]
        var delayNum = 1, delayDen = 10
        /// 0 none, 1 background (transparent), 2 previous.
        var dispose = 0
        /// 0 source, 1 over.
        var blend = 0
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private static func crc(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xff)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    /// A zlib stream of stored (uncompressed) deflate blocks.
    private static func zlib(_ raw: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01]
        var i = 0
        repeat {
            let n = min(65535, raw.count - i)
            out += [i + n >= raw.count ? 1 : 0, UInt8(n & 0xff), UInt8(n >> 8), UInt8(~n & 0xff), UInt8(~n >> 8 & 0xff)]
            out += raw[i..<(i + n)]
            i += n
        } while i < raw.count
        var a: UInt32 = 1, b: UInt32 = 0
        for x in raw { a = (a + UInt32(x)) % 65521; b = (b + a) % 65521 }
        let adler = b << 16 | a
        return out + [UInt8(adler >> 24), UInt8(adler >> 16 & 0xff), UInt8(adler >> 8 & 0xff), UInt8(adler & 0xff)]
    }

    static func make(width: Int, height: Int, plays: Int, frames: [Frame]) -> Data {
        var d = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
        func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
        func chunk(_ type: String, _ body: [UInt8]) {
            let t = Array(type.utf8)
            d.append(contentsOf: be32(body.count) + t + body + be32(Int(crc(t + body))))
        }
        chunk("IHDR", be32(width) + be32(height) + [8, 6, 0, 0, 0])
        chunk("acTL", be32(frames.count) + be32(plays))
        var sequence = 0
        for (i, f) in frames.enumerated() {
            chunk("fcTL", be32(sequence) + be32(f.width) + be32(f.height) + be32(f.x) + be32(f.y)
                  + be16(f.delayNum) + be16(f.delayDen) + [UInt8(f.dispose), UInt8(f.blend)])
            sequence += 1
            var raw: [UInt8] = []
            for y in 0..<f.height { raw.append(0); raw += f.rgba[(y * f.width * 4)..<((y + 1) * f.width * 4)] }
            if i == 0 {
                chunk("IDAT", zlib(raw))
            } else {
                chunk("fdAT", be32(sequence) + zlib(raw))
                sequence += 1
            }
        }
        chunk("IEND", [])
        return d
    }
}

enum AnimationFixtures {
    /// Palette: 0 black, 1 red, 2 blue, 3 green, 4 white, 5 the transparent index.
    static let palette: [(UInt8, UInt8, UInt8)] = [(0, 0, 0), (255, 0, 0), (0, 0, 255), (0, 255, 0), (255, 255, 255), (255, 0, 255)]

    /// 8×8: red (0 cs), a blue top-left 4×4 restored to background (1 cs), a green/transparent checker bottom-right
    /// restored to previous (5 cs), a white 2×2 at (2, 2) (20 cs).
    static func gif(loopCount: Int?) -> Data {
        GIFWriter.make(width: 8, height: 8, palette: palette, loopCount: loopCount, frames: [
            .init(width: 8, height: 8, pixels: [UInt8](repeating: 1, count: 64), delay: 0, disposal: 1),
            .init(x: 0, y: 0, width: 4, height: 4, pixels: [UInt8](repeating: 2, count: 16), delay: 1, disposal: 2),
            .init(x: 4, y: 4, width: 4, height: 4, pixels: (0..<16).map { $0 % 2 == 0 ? 3 : 5 }, delay: 5, disposal: 3,
                  transparentIndex: 5),
            .init(x: 2, y: 2, width: 2, height: 2, pixels: [UInt8](repeating: 4, count: 4), delay: 20, disposal: 1),
        ])
    }

    /// The same composition as `gif` as APNG: dispose background / previous, blend over; delays 0, 1/100, 5/100, 20/100.
    static func apng(plays: Int) -> Data {
        func solid(_ w: Int, _ h: Int, _ c: [UInt8]) -> [UInt8] { (0..<(w * h)).flatMap { _ in c } }
        return APNGWriter.make(width: 8, height: 8, plays: plays, frames: [
            .init(width: 8, height: 8, rgba: solid(8, 8, [255, 0, 0, 255]), delayNum: 0, delayDen: 100),
            .init(width: 4, height: 4, rgba: solid(4, 4, [0, 0, 255, 255]), delayNum: 1, delayDen: 100, dispose: 1),
            .init(x: 4, y: 4, width: 4, height: 4, rgba: (0..<16).flatMap { $0 % 2 == 0 ? [0, 255, 0, 255] : [0, 0, 0, 0] },
                  delayNum: 5, delayDen: 100, dispose: 2, blend: 1),
            .init(x: 2, y: 2, width: 2, height: 2, rgba: solid(2, 2, [255, 255, 255, 255]), delayNum: 20, delayDen: 100),
        ])
    }

    /// Animated WebP (16×16, made with libwebp 1.6 `webpmux`, loop count 3): red (0 ms, keep); blue 8×8 at (0, 0)
    /// (10 ms, dispose to background); green/transparent checker 8×8 at (8, 8) (50 ms, blended); white 4×4 at (4, 4)
    /// (200 ms, not blended).
    static let webp = Data([
        0x52, 0x49, 0x46, 0x46, 0xea, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x58, 0x0a, 0x00, 0x00, 0x00,
        0x12, 0x00, 0x00, 0x00, 0x0f, 0x00, 0x00, 0x0f, 0x00, 0x00, 0x41, 0x4e, 0x49, 0x4d, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x03, 0x00, 0x41, 0x4e, 0x4d, 0x46, 0x28, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0f, 0x00,
        0x00, 0x0f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x56, 0x50, 0x38, 0x4c, 0x0f, 0x00, 0x00, 0x00, 0x2f, 0x0f, 0xc0, 0x03,
        0x00, 0x07, 0x10, 0xfd, 0x8f, 0xfe, 0x07, 0x22, 0xa2, 0xff, 0x01, 0x00, 0x41, 0x4e, 0x4d, 0x46, 0x28, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x07, 0x00, 0x00, 0x0a, 0x00, 0x00, 0x03, 0x56, 0x50, 0x38, 0x4c,
        0x0f, 0x00, 0x00, 0x00, 0x2f, 0x07, 0xc0, 0x01, 0x00, 0x07, 0x10, 0xd1, 0xff, 0xfe, 0x07, 0x22, 0xa2, 0xff, 0x01, 0x00,
        0x41, 0x4e, 0x4d, 0x46, 0x2c, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x04, 0x00, 0x00, 0x07, 0x00, 0x00, 0x07, 0x00, 0x00,
        0x32, 0x00, 0x00, 0x00, 0x56, 0x50, 0x38, 0x4c, 0x13, 0x00, 0x00, 0x00, 0x2f, 0x07, 0xc0, 0x01, 0x10, 0x0f, 0x30, 0xff,
        0x11, 0xf3, 0x1f, 0x8c, 0x57, 0xa9, 0x46, 0xf4, 0x3f, 0x54, 0x01, 0x00, 0x41, 0x4e, 0x4d, 0x46, 0x2a, 0x00, 0x00, 0x00,
        0x02, 0x00, 0x00, 0x02, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x00, 0xc8, 0x00, 0x00, 0x02, 0x56, 0x50, 0x38, 0x4c,
        0x11, 0x00, 0x00, 0x00, 0x2f, 0x03, 0xc0, 0x00, 0x00, 0x07, 0xd0, 0xff, 0xfe, 0xf7, 0xbf, 0xff, 0x81, 0x88, 0xe8, 0x7f,
        0x00, 0x00,
    ])
}
