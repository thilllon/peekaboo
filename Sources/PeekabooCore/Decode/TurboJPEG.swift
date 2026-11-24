import CTurboJPEG
import CoreGraphics
import Foundation

/// Thin wrapper over libjpeg-turbo's TurboJPEG 3 API.
enum TurboJPEG {
    struct Header: Equatable {
        let width: Int
        let height: Int
        let progressive: Bool
        /// TJSAMP_* chroma subsampling.
        let subsampling: Int32
        /// TJCS_* colour space (CMYK/YCCK JPEGs must go through ImageIO).
        let colorspace: Int32
    }

    /// Parse the header of an in-memory JPEG without decoding pixels.
    static func header(_ data: UnsafeRawBufferPointer) -> Header? {
        guard let handle = pb_tj3Init(Int32(TJINIT_DECOMPRESS.rawValue)) else { return nil }
        defer { tj3Destroy(handle) }
        guard let base = data.baseAddress?.assumingMemoryBound(to: UInt8.self),
              tj3DecompressHeader(handle, base, data.count) == 0 else { return nil }
        func get(_ param: TJPARAM) -> Int32 { tj3Get(handle, Int32(param.rawValue)) }
        return Header(width: Int(get(TJPARAM_JPEGWIDTH)), height: Int(get(TJPARAM_JPEGHEIGHT)),
                      progressive: get(TJPARAM_PROGRESSIVE) == 1, subsampling: get(TJPARAM_SUBSAMP),
                      colorspace: get(TJPARAM_COLORSPACE))
    }

    /// Scaling factors (num/denom) supported by the decompressor, largest first.
    static let scalingFactors: [(num: Int, denom: Int)] = {
        var count: Int32 = 0
        guard let list = tj3GetScalingFactors(&count) else { return [(1, 1)] }
        var factors = (0..<Int(count)).map { (num: Int(list[$0].num), denom: Int(list[$0].denom)) }
        factors.sort { Double($0.num) / Double($0.denom) > Double($1.num) / Double($1.denom) }
        return factors
    }()

    /// `TJSCALED`: ceil(dimension * num / denom).
    @inline(__always) static func scaled(_ dimension: Int, _ factor: (num: Int, denom: Int)) -> Int {
        (dimension * factor.num + factor.denom - 1) / factor.denom
    }

    /// The smallest DCT scaling factor whose output long side still covers `target` (`target <= 0`
    /// means full size). Only 1/2, 1/4 and 1/8 are used: they have SIMD reduced-size IDCTs, while
    /// the odd M/8 factors run plain C and measured slower than a full decode (101 MP progressive:
    /// 3/8 759 ms vs full 686 ms).
    static func coveringScale(width: Int, height: Int, target: Int) -> (num: Int, denom: Int) {
        let long = max(width, height)
        guard target > 0, target < long else { return (1, 1) }
        var best = (num: 1, denom: 1)
        for factor in scalingFactors where factor.num == 1 && [2, 4, 8].contains(factor.denom) {
            if scaled(long, factor) >= target { best = factor } else { break }
        }
        return best
    }

    enum Failure: Error { case header, cmyk, decode(String), memory }

    /// Decode an in-memory JPEG straight into a pooled `.bgra8` (opaque) buffer, DCT-scaled to the
    /// smallest supported factor that covers `targetLongSide` (`<= 0`: full size).
    /// The buffer's colour space is the embedded ICC profile, sRGB when absent.
    static func decode(_ data: UnsafeRawBufferPointer, targetLongSide: Int, pool: PixelBufferPool) throws -> PixelBuffer {
        guard let handle = pb_tj3Init(Int32(TJINIT_DECOMPRESS.rawValue)) else { throw Failure.memory }
        defer { tj3Destroy(handle) }
        guard let base = data.baseAddress?.assumingMemoryBound(to: UInt8.self) else { throw Failure.header }
        _ = tj3Set(handle, Int32(TJPARAM_SAVEMARKERS.rawValue), 2)  // ICC only
        guard tj3DecompressHeader(handle, base, data.count) == 0 else { throw Failure.header }
        let colorspace = tj3Get(handle, Int32(TJPARAM_COLORSPACE.rawValue))
        if colorspace == Int32(TJCS_CMYK.rawValue) || colorspace == Int32(TJCS_YCCK.rawValue) { throw Failure.cmyk }
        let width = Int(tj3Get(handle, Int32(TJPARAM_JPEGWIDTH.rawValue)))
        let height = Int(tj3Get(handle, Int32(TJPARAM_JPEGHEIGHT.rawValue)))
        guard width > 0, height > 0 else { throw Failure.header }
        let factor = coveringScale(width: width, height: height, target: targetLongSide)
        if factor.num != factor.denom {
            _ = tj3SetScalingFactor(handle, tjscalingfactor(num: Int32(factor.num), denom: Int32(factor.denom)))
        }
        let outW = scaled(width, factor), outH = scaled(height, factor)
        let space = iccColorSpace(handle) ?? sRGB
        guard let pixels = pool.make(width: outW, height: outH, layout: .bgra8, alpha: .opaque, colorSpace: space) else {
            throw Failure.memory
        }
        let dst = pixels.baseAddress.assumingMemoryBound(to: UInt8.self)
        let status = tj3Decompress8(handle, base, data.count, dst, Int32(pixels.bytesPerRow), Int32(TJPF_BGRX.rawValue))
        if status != 0, tj3GetErrorCode(handle) == Int32(TJERR_FATAL.rawValue) {
            throw Failure.decode(String(cString: tj3GetErrorStr(handle)))
        }
        return pixels
    }

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// The ICC profile extracted by `tj3DecompressHeader` (with SAVEMARKERS 2) as an RGB colour space.
    private static func iccColorSpace(_ handle: tjhandle) -> CGColorSpace? {
        var buffer: UnsafeMutablePointer<UInt8>?
        var size = 0
        guard tj3GetICCProfile(handle, &buffer, &size) == 0, let buffer, size > 0 else { return nil }
        defer { tj3Free(buffer) }
        return ICCColorSpaceCache.shared.space(icc: UnsafeRawBufferPointer(start: buffer, count: size))
    }
}

/// Interns colour spaces by ICC bytes: parsing a profile costs more than hashing it, and most
/// folders use one or two profiles.
final class ICCColorSpaceCache: @unchecked Sendable {
    static let shared = ICCColorSpaceCache()
    private var spaces: [Data: CGColorSpace] = [:]
    private let lock = NSLock()

    func space(icc: UnsafeRawBufferPointer) -> CGColorSpace? {
        let key = Data(icc)
        lock.lock()
        if let hit = spaces[key] { lock.unlock(); return hit }
        lock.unlock()
        guard let space = CGColorSpace(iccData: key as CFData), space.model == .rgb else { return nil }
        lock.lock(); defer { lock.unlock() }
        if spaces.count > 32 { spaces.removeAll() }
        spaces[key] = space
        return space
    }
}
