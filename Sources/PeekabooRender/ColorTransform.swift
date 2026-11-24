import CoreGraphics
import Foundation
import simd

/// Source colour space -> linear Display P3 (the working space), applied on the GPU:
/// transfer function per channel, then a 3×3 matrix in linear light. Derived once per colour space and cached.
struct ColorTransform {
    enum Curve: Int32 {
        /// Values are already linear.
        case linear = 0
        /// IEC 61966-2-1 sRGB curve (also Display P3), sign-symmetric for extended ranges.
        case srgb = 1
        /// Sampled curve (`lut`, values at i / (n − 1)).
        case table = 2
    }

    /// Rows of the linear source -> linear Display P3 matrix.
    var rows: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)
    var curve: Curve
    var lut: [Float]

    static let identityRows = (SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1))
    /// Linear sRGB (D65) -> linear Display P3 (D65).
    static let srgbToP3Rows = (SIMD3<Float>(0.8224621, 0.1775380, 0.0000000),
                               SIMD3<Float>(0.0331941, 0.9668058, 0.0000000),
                               SIMD3<Float>(0.0170827, 0.0723974, 0.9105199))

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [AnyHashable: ColorTransform] = [:]
    /// Probes of uncommon profiles run here, never on the main thread (1–3 ms each).
    static let probeQueue = DispatchQueue(label: "com.thilllon.peekaboo.icc-probe", qos: .userInitiated)

    private static func key(_ space: CGColorSpace) -> AnyHashable {
        (space.name as String?).map { AnyHashable($0) }
            ?? space.copyICCData().map { AnyHashable($0 as Data) } ?? AnyHashable("unknown")
    }

    /// The cached transform for `space` (probing unknown profiles once: ~1–3 ms). May block: call it off the main
    /// thread for spaces `cached(_:)` does not know.
    static func forSpace(_ space: CGColorSpace) -> ColorTransform {
        if let hit = cached(space) { return hit }
        let made = probe(space) ?? ColorTransform(rows: srgbToP3Rows, curve: .srgb, lut: [])
        lock.lock(); cache[key(space)] = made; lock.unlock()
        return made
    }

    /// The transform for `space` if it needs no probe (named sRGB / Display P3 / linear spaces, or a profile probed
    /// before); nil otherwise. Cheap enough for the main thread (a name compare or an ICC-data hash lookup).
    static func cached(_ space: CGColorSpace) -> ColorTransform? {
        if let made = known(space) { return made }
        let k = key(space)
        lock.lock(); defer { lock.unlock() }
        return cache[k]
    }

    /// Stand-in while `space` is probed: the sRGB curve with sRGB or (wide-gamut profiles) Display P3 primaries.
    static func fallback(for space: CGColorSpace) -> ColorTransform {
        ColorTransform(rows: space.isWideGamutRGB ? identityRows : srgbToP3Rows, curve: .srgb, lut: [])
    }

    private static func known(_ space: CGColorSpace) -> ColorTransform? {
        guard let name = space.name else { return nil }
        switch name {
        case CGColorSpace.sRGB, CGColorSpace.extendedSRGB:
            return ColorTransform(rows: srgbToP3Rows, curve: .srgb, lut: [])
        case CGColorSpace.displayP3, CGColorSpace.extendedDisplayP3:
            return ColorTransform(rows: identityRows, curve: .srgb, lut: [])
        case CGColorSpace.linearSRGB, CGColorSpace.extendedLinearSRGB:
            return ColorTransform(rows: srgbToP3Rows, curve: .linear, lut: [])
        case CGColorSpace.linearDisplayP3, CGColorSpace.extendedLinearDisplayP3:
            return ColorTransform(rows: identityRows, curve: .linear, lut: [])
        default:
            return nil
        }
    }

    /// Converts probe colours (a 1024-step grey ramp and the three primaries) from `space` into extended linear
    /// Display P3 with one CoreGraphics draw: the ramp gives the transfer curve, the primaries the matrix columns.
    static func probe(_ space: CGColorSpace) -> ColorTransform? {
        guard space.model == .rgb, let target = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else { return nil }
        let ramp = 1024, count = ramp + 3
        var src = [UInt16](repeating: 0, count: count * 4)
        for i in 0..<ramp {
            let v = UInt16((Double(i) / Double(ramp - 1) * 65535).rounded())
            src[i * 4] = v; src[i * 4 + 1] = v; src[i * 4 + 2] = v; src[i * 4 + 3] = 65535
        }
        for j in 0..<3 { src[(ramp + j) * 4 + j] = 65535; src[(ramp + j) * 4 + 3] = 65535 }
        let data = src.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: count, height: 1, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: count * 8,
                                  space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                                                           | CGBitmapInfo.byteOrder16Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .relativeColorimetric)
        else { return nil }
        var out = [Float](repeating: 0, count: count * 4)
        let ok: Bool = out.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: count, height: 1, bitsPerComponent: 32, bytesPerRow: count * 16,
                                      space: target,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            ctx.interpolationQuality = .none
            ctx.setBlendMode(.copy)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: count, height: 1))
            return true
        }
        guard ok else { return nil }
        let white = max(out[(ramp - 1) * 4 + 1], 1e-6)
        let lut = (0..<ramp).map { out[$0 * 4 + 1] / white }
        func column(_ j: Int) -> SIMD3<Float> {
            let b = (ramp + j) * 4
            return SIMD3(out[b], out[b + 1], out[b + 2]) / white
        }
        let c0 = column(0), c1 = column(1), c2 = column(2)
        let rows = (SIMD3<Float>(c0.x, c1.x, c2.x), SIMD3<Float>(c0.y, c1.y, c2.y), SIMD3<Float>(c0.z, c1.z, c2.z))
        // A ramp that is linear to within 1e-3 needs no curve.
        let isLinear = (0..<ramp).allSatisfy { abs(lut[$0] - Float($0) / Float(ramp - 1)) < 1e-3 }
        if isLinear { return ColorTransform(rows: rows, curve: .linear, lut: []) }
        // Embedded sRGB / Display P3 profiles (most photos: cameras embed sRGB IEC61966-2.1, phones Display P3) are
        // unnamed spaces, but their curve is the sRGB curve: say so, so that 8-bit textures use `_srgb` views and the
        // HQ pass takes its fast path (the LUT path cost 4.1 of the 5.7 ms full-tier fit frame).
        if matchesSRGBCurve(lut) {
            func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool { simd_reduce_max(simd_abs(a - b)) < 2e-3 }
            let srgb = srgbToP3Rows, p3 = identityRows
            let snapped: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)
            if near(rows.0, srgb.0) && near(rows.1, srgb.1) && near(rows.2, srgb.2) { snapped = srgb }
            else if near(rows.0, p3.0) && near(rows.1, p3.1) && near(rows.2, p3.2) { snapped = p3 }
            else { snapped = rows }
            return ColorTransform(rows: snapped, curve: .srgb, lut: [])
        }
        return ColorTransform(rows: rows, curve: .table, lut: lut)
    }

    /// Whether a probed ramp (values at i / (n − 1)) is the IEC 61966-2-1 curve: within 0.2 % relative error plus
    /// 2·10⁻⁵ absolute (well under half an 8-bit step anywhere on the curve).
    static func matchesSRGBCurve(_ lut: [Float]) -> Bool {
        let n = lut.count
        guard n > 1 else { return false }
        return (0..<n).allSatisfy { i in
            let v = Double(i) / Double(n - 1)
            let s = v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            return abs(Double(lut[i]) - s) <= 2e-5 + 2e-3 * s
        }
    }

    /// Whether the transfer curve is the sRGB curve (then 8-bit textures can use `_srgb` formats for free decoding).
    var usesSRGBCurve: Bool { curve == .srgb }
}
