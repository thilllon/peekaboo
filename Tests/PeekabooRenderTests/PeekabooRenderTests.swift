import CoreGraphics
import ImageIO
import Metal
import QuartzCore
import XCTest
@testable import PeekabooCore
@testable import PeekabooRender

// Offscreen tests of the PPR renderer. Synthetic images only (no corpus needed).

private func srgbToLinear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
private func linearToSRGB(_ v: Double) -> Double {
    let x = min(max(v, 0), 1)
    return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
}

/// RGBA float image (linear or encoded, as documented at each use).
private struct Img {
    var width: Int, height: Int
    var px: [SIMD4<Double>]
    subscript(x x: Int, y y: Int) -> SIMD4<Double> { px[y * width + x] }
}

final class PeekabooRenderTests: XCTestCase {
    var device: MTLDevice!
    var pool: PixelBufferPool!

    override func setUpWithError() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        self.device = device
        pool = PixelBufferPool(device: device)
    }

    func testMetalDeviceAvailable() { XCTAssertNotNil(PeekabooRenderInfo.defaultDevice()) }

    // MARK: Helpers

    /// An sRGB 8-bit image in `layout`; `fill` returns encoded RGBA in 0...255 (straight alpha).
    private func makeImage(width: Int, height: Int, layout: PixelLayout = .bgra8, alpha: AlphaMode = .opaque,
                           space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!,
                           tier: Tier = .full, fullWidth: Int? = nil, fullHeight: Int? = nil,
                           orientation: CGImagePropertyOrientation = .up,
                           fill: (Int, Int) -> SIMD4<UInt8>) -> DecodedImage {
        let pixels = pool.make(width: width, height: height, layout: layout, alpha: alpha, colorSpace: space)!
        let base = pixels.baseAddress.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                var c = fill(x, y)
                if alpha == .premultiplied {
                    let a = Double(c.w) / 255
                    c = SIMD4(UInt8((Double(c.x) * a).rounded()), UInt8((Double(c.y) * a).rounded()), UInt8((Double(c.z) * a).rounded()), c.w)
                }
                let o = y * pixels.bytesPerRow + x * 4
                switch layout {
                case .bgra8: base[o] = c.z; base[o + 1] = c.y; base[o + 2] = c.x; base[o + 3] = c.w
                case .rgba8: base[o] = c.x; base[o + 1] = c.y; base[o + 2] = c.z; base[o + 3] = c.w
                case .argb8: base[o] = c.w; base[o + 1] = c.x; base[o + 2] = c.y; base[o + 3] = c.z
                default: XCTFail("unsupported test layout")
                }
            }
        }
        let swaps = orientation.rawValue >= 5
        return DecodedImage(pixels: pixels, tier: tier,
                            fullWidth: fullWidth ?? (swaps ? height : width), fullHeight: fullHeight ?? (swaps ? width : height),
                            orientation: orientation, isHDR: false, decodeNanos: 0)
    }

    private func makeRenderer(width: Int, height: Int) -> Renderer {
        let layer = CAMetalLayer()
        let r = Renderer(layer: layer)
        r.setViewSize(CGSize(width: width, height: height), backingScale: 1)
        return r
    }

    /// Spin the main run loop until the pyramid of `image` is complete (it publishes on the main queue).
    private func waitForPyramid(_ r: Renderer, _ image: DecodedImage, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while !r.isPyramidComplete(for: image) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
        }
        XCTAssertTrue(r.isPyramidComplete(for: image), "pyramid did not finish")
    }

    /// Linear float RGBA readback of an `rgba16Float` texture.
    private func read(_ texture: MTLTexture) -> Img {
        let w = texture.width, h = texture.height
        var halfs = [Float16](repeating: 0, count: w * h * 4)
        halfs.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        var px = [SIMD4<Double>](repeating: .zero, count: w * h)
        for i in 0..<(w * h) {
            px[i] = SIMD4(Double(halfs[i * 4]), Double(halfs[i * 4 + 1]), Double(halfs[i * 4 + 2]), Double(halfs[i * 4 + 3]))
        }
        return Img(width: w, height: h, px: px)
    }

    private func render(_ r: Renderer) -> Img {
        guard let tex = r.renderOffscreen(format: .rgba16Float) else { XCTFail("render failed"); return Img(width: 0, height: 0, px: []) }
        return read(tex)
    }

    /// Deterministic photo-like test pattern (encoded sRGB 0...255): smooth gradients, sinusoids, edges, noise.
    private func pattern(_ x: Int, _ y: Int) -> SIMD4<UInt8> {
        var seed = UInt64(x &* 73856093 ^ y &* 19349663) &* 0x9E3779B97F4A7C15
        seed ^= seed >> 29
        let noise = Double(seed % 1000) / 1000 - 0.5
        let fx = Double(x), fy = Double(y)
        let r = 0.5 + 0.35 * sin(fx * 0.11) * cos(fy * 0.07) + 0.08 * noise
        let g = ((x / 23 + y / 17) % 2 == 0 ? 0.75 : 0.25) + 0.05 * noise
        let b = 0.5 + 0.4 * sin((fx + fy) * 0.045) + 0.1 * noise
        func q(_ v: Double) -> UInt8 { UInt8(min(max(v, 0), 1) * 255 + 0.5) }
        return SIMD4(q(r), q(g), q(b), 255)
    }

    // MARK: Basic

    func testSolidColourIsColourManaged() {
        let image = makeImage(width: 64, height: 48) { _, _ in SIMD4(200, 100, 50, 255) }
        let r = makeRenderer(width: 64, height: 48)
        r.setImage(image, key: "solid")
        let out = render(r)
        let lin = SIMD3(srgbToLinear(200 / 255), srgbToLinear(100 / 255), srgbToLinear(50 / 255))
        // sRGB -> Display P3 (linear)
        let p3 = SIMD3(0.8224621 * lin.x + 0.1775380 * lin.y,
                       0.0331941 * lin.x + 0.9668058 * lin.y,
                       0.0170827 * lin.x + 0.0723974 * lin.y + 0.9105199 * lin.z)
        let c = out[x: 32, y: 24]
        XCTAssertEqual(c.x, p3.x, accuracy: 2e-3)
        XCTAssertEqual(c.y, p3.y, accuracy: 2e-3)
        XCTAssertEqual(c.z, p3.z, accuracy: 2e-3)
    }

    // MARK: Exactness

    func testExactCopyAtOneToOne() {
        let w = 160, h = 120
        let image = makeImage(width: w, height: h, space: CGColorSpace(name: CGColorSpace.displayP3)!, fill: pattern)
        let r = makeRenderer(width: w, height: h)
        r.setImage(image, key: "exact")
        r.setZoom(.scale(1))
        let out = render(r)
        XCTAssertEqual(r.lastPath, "exact")
        var maxErr = 0.0
        var worst = ""
        for y in 0..<h {
            for x in 0..<w {
                let e = pattern(x, y)
                let want = SIMD3(srgbToLinear(Double(e.x) / 255), srgbToLinear(Double(e.y) / 255), srgbToLinear(Double(e.z) / 255))
                let got = out[x: x, y: y]
                for c in 0..<3 {
                    // Exactness in 8-bit levels: the copy must reproduce the source bytes.
                    let err: Double = abs(linearToSRGB(got[c]) * 255 - Double(e[c]))
                    if err > maxErr { maxErr = err; worst = "(\(x),\(y)) c\(c) enc \(e[c]) want \(want[c]) got \(got[c])" }
                }
            }
        }
        XCTAssertLessThan(maxErr, 0.5, "1:1 must reproduce the source bytes (round trip): \(worst)")
    }

    // MARK: Geometry

    /// Every EXIF orientation shows the same picture as a pre-rotated `.up` image, at 1:1 and when resampled.
    func testAllEightOrientations() {
        let ow = 48, oh = 32   // oriented size
        // Oriented (displayed) picture: asymmetric so every orientation is distinguishable.
        func oriented(_ x: Int, _ y: Int) -> SIMD4<UInt8> {
            SIMD4(UInt8(x * 255 / (ow - 1)), UInt8(y * 255 / (oh - 1)), (x < 10 && y < 6) ? 255 : 40, 255)
        }
        let orientations: [CGImagePropertyOrientation] = [.up, .upMirrored, .down, .downMirrored, .leftMirrored, .right, .rightMirrored, .left]
        let reference = makeImage(width: ow, height: oh, fill: oriented)
        for scale in [1.0, 0.7, 1.6] {
            let rr = makeRenderer(width: 80, height: 60)
            rr.setImage(reference, key: "ref")
            rr.setZoom(.scale(scale))
            let want = render(rr)
            for o in orientations {
                let swaps = o.rawValue >= 5
                let sw = swaps ? oh : ow, sh = swaps ? ow : oh
                // stored pixel (x, y) -> oriented pixel
                func toOriented(_ x: Int, _ y: Int) -> (Int, Int) {
                    switch o {
                    case .up: return (x, y)
                    case .upMirrored: return (sw - 1 - x, y)
                    case .down: return (sw - 1 - x, sh - 1 - y)
                    case .downMirrored: return (x, sh - 1 - y)
                    case .leftMirrored: return (y, x)
                    case .right: return (sh - 1 - y, x)
                    case .rightMirrored: return (sh - 1 - y, sw - 1 - x)
                    case .left: return (y, sw - 1 - x)
                    @unknown default: return (x, y)
                    }
                }
                let stored = makeImage(width: sw, height: sh, fullWidth: ow, fullHeight: oh, orientation: o) { x, y in
                    let (u, v) = toOriented(x, y)
                    return oriented(u, v)
                }
                let r = makeRenderer(width: 80, height: 60)
                r.setImage(stored, key: "o\(o.rawValue)")
                r.setZoom(.scale(scale))
                let got = render(r)
                var maxErr = 0.0
                for i in 0..<got.px.count { maxErr = max(maxErr, abs(got.px[i].x - want.px[i].x), abs(got.px[i].y - want.px[i].y), abs(got.px[i].z - want.px[i].z)) }
                XCTAssertLessThan(maxErr, 4e-3, "orientation \(o.rawValue) at scale \(scale): max error \(maxErr)")
            }
        }
    }

    /// User rotation + flips compose with EXIF orientation (rotating a `.right` image back counter-clockwise
    /// equals the stored picture).
    func testUserRotationComposesWithOrientation() {
        let sw = 40, sh = 24
        let stored = makeImage(width: sw, height: sh, orientation: .right, fill: pattern)
        let plain = makeImage(width: sw, height: sh, fill: pattern)
        let a = makeRenderer(width: 64, height: 64), b = makeRenderer(width: 64, height: 64)
        a.setImage(stored, key: "a"); a.rotate(clockwise: false); a.setZoom(.scale(1))
        b.setImage(plain, key: "b"); b.setZoom(.scale(1))
        let ga = render(a), gb = render(b)
        var maxErr = 0.0
        for i in 0..<ga.px.count { maxErr = max(maxErr, abs(ga.px[i].x - gb.px[i].x)) }
        XCTAssertLessThan(maxErr, 2e-3)
    }

    // MARK: Tier swap

    /// A lower tier maps onto the same full-resolution coordinates: swapping tiers never shifts the picture,
    /// and the same key keeps zoom and pan.
    func testTierSwapDoesNotShift() {
        let fw = 400, fh = 300
        // A bright square at a known place on a dark background.
        func square(_ x: Double, _ y: Double) -> Bool { x >= 148 && x < 228 && y >= 88 && y < 168 }
        let full = makeImage(width: fw, height: fh, tier: .full) { x, y in
            square(Double(x) + 0.5, Double(y) + 0.5) ? SIMD4(255, 255, 255, 255) : SIMD4(20, 20, 20, 255)
        }
        let screen = makeImage(width: fw / 2, height: fh / 2, tier: .screen, fullWidth: fw, fullHeight: fh) { x, y in
            square(Double(x) * 2 + 1, Double(y) * 2 + 1) ? SIMD4(255, 255, 255, 255) : SIMD4(20, 20, 20, 255)
        }
        let preview = makeImage(width: fw / 4, height: fh / 4, tier: .preview, fullWidth: fw, fullHeight: fh) { x, y in
            square(Double(x) * 4 + 2, Double(y) * 4 + 2) ? SIMD4(255, 255, 255, 255) : SIMD4(20, 20, 20, 255)
        }
        let r = makeRenderer(width: 300, height: 240)
        func centroid(_ img: Img) -> SIMD2<Double> {
            var s = 0.0, cx = 0.0, cy = 0.0
            for y in 0..<img.height { for x in 0..<img.width {
                let v = max(0, img[x: x, y: y].y - 0.05)
                s += v; cx += v * (Double(x) + 0.5); cy += v * (Double(y) + 0.5)
            } }
            return SIMD2(cx / s, cy / s)
        }
        r.setImage(preview, key: "file")
        r.setZoom(.scale(1.3), anchor: CGPoint(x: 120, y: 100))
        r.pan(by: CGVector(dx: 7.25, dy: -3.5))
        let scale = r.effectiveScale
        let a = centroid(render(r))
        r.setImage(screen, key: "file")
        XCTAssertEqual(r.effectiveScale, scale, "same key keeps the zoom")
        let b = centroid(render(r))
        r.setImage(full, key: "file")
        let c = centroid(render(r))
        XCTAssertEqual(a.x, c.x, accuracy: 0.35); XCTAssertEqual(a.y, c.y, accuracy: 0.35)
        XCTAssertEqual(b.x, c.x, accuracy: 0.2); XCTAssertEqual(b.y, c.y, accuracy: 0.2)
        // A new key resets the view.
        r.setImage(full, key: "other")
        XCTAssertEqual(r.zoomMode, .fit)
    }

    // MARK: Alpha

    func testAlphaCompositingOverBackground() {
        for alpha in [AlphaMode.premultiplied, .straight] {
            for layout in [PixelLayout.bgra8, .rgba8, .argb8] {
                let image = makeImage(width: 32, height: 32, layout: layout, alpha: alpha) { _, _ in SIMD4(255, 0, 0, 128) }
                let r = makeRenderer(width: 32, height: 32)
                r.settings.background = .gray
                r.setImage(image, key: "a")
                let c = render(r)[x: 16, y: 16]
                let a = 128.0 / 255
                let bg = srgbToLinear(0.5)
                // straight red in sRGB -> linear P3 red channel 0.8224621, green 0.0331941, blue 0.0170827
                XCTAssertEqual(c.x, 0.8224621 * a + bg * (1 - a), accuracy: 6e-3, "\(alpha) \(layout)")
                XCTAssertEqual(c.y, 0.0331941 * a + bg * (1 - a), accuracy: 6e-3, "\(alpha) \(layout)")
                XCTAssertEqual(c.z, 0.0170827 * a + bg * (1 - a), accuracy: 6e-3, "\(alpha) \(layout)")
            }
        }
    }

    func testOpaqueIgnoresGarbageAlpha() {
        let image = makeImage(width: 16, height: 16, alpha: .opaque) { _, _ in SIMD4(0, 255, 0, 0) }
        let r = makeRenderer(width: 16, height: 16)
        r.settings.background = .gray
        r.setImage(image, key: "g")
        let c = render(r)[x: 8, y: 8]
        XCTAssertEqual(c.y, 0.9668058, accuracy: 3e-3)
    }

    // MARK: Quality

    /// CPU float64 direct Lanczos-3 (kernel stretched by 1/s when reducing; sigmoidal light when enlarging).
    private func reference(_ src: Img, scale s: Double, drawable: (Int, Int), crop: (Int, Int, Int, Int)) -> Img {
        let f = 1 / s, k = max(1, f), R = 3 * k
        let cx = Double(src.width) / 2, cy = Double(src.height) / 2
        let sigmoid = s > 1
        func sigFwd(_ x: Double) -> Double {
            let c = 0.75, sl = 6.5
            let s0 = 1 / (1 + exp(sl * c)), s1 = 1 / (1 + exp(sl * (c - 1)))
            return c - log(1 / (min(max(x, 0), 1) * (s1 - s0) + s0) - 1) / sl
        }
        func sigInv(_ y: Double) -> Double {
            let c = 0.75, sl = 6.5
            let s0 = 1 / (1 + exp(sl * c)), s1 = 1 / (1 + exp(sl * (c - 1)))
            return (1 / (1 + exp(sl * (c - y))) - s0) / (s1 - s0)
        }
        func taps(_ out: Int, _ centre: Double, _ d: Int, _ n: Int) -> (Int, [Double]) {
            let p = centre + (Double(out) + 0.5 - Double(d) / 2) * f - 0.5
            let i0 = Int(ceil(p - R)), i1 = Int(floor(p + R))
            var w = (i0...i1).map { lanczos3((Double($0) - p) / k) }
            let sum = w.reduce(0, +); w = w.map { $0 / sum }
            return (i0, w)
        }
        let (x0, y0, cw, ch) = crop
        var out = Img(width: cw, height: ch, px: Array(repeating: .zero, count: cw * ch))
        let tx = (0..<cw).map { taps(x0 + $0, cx, drawable.0, src.width) }
        let ty = (0..<ch).map { taps(y0 + $0, cy, drawable.1, src.height) }
        func light(_ v: SIMD4<Double>) -> SIMD4<Double> { sigmoid ? SIMD4(sigFwd(v.x), sigFwd(v.y), sigFwd(v.z), v.w) : v }
        for j in 0..<ch {
            let (r0, wy) = ty[j]
            for i in 0..<cw {
                let (c0, wx) = tx[i]
                var a = SIMD4<Double>.zero
                for (dy, wv) in wy.enumerated() {
                    let yy = min(max(r0 + dy, 0), src.height - 1)
                    var row = SIMD4<Double>.zero
                    for (dx, wh) in wx.enumerated() {
                        let xx = min(max(c0 + dx, 0), src.width - 1)
                        row += wh * light(src[x: xx, y: yy])
                    }
                    a += wv * row
                }
                if sigmoid { a = SIMD4(sigInv(a.x), sigInv(a.y), sigInv(a.z), a.w) }
                out.px[j * cw + i] = a
            }
        }
        return out
    }

    private func psnr(_ a: Img, _ b: Img) -> Double {
        var mse = 0.0
        for i in 0..<a.px.count {
            for c in 0..<3 {
                let d = linearToSRGB(a.px[i][c]) - linearToSRGB(b.px[i][c])
                mse += d * d
            }
        }
        mse /= Double(a.px.count * 3)
        return 10 * log10(1 / max(mse, 1e-12))
    }

    func testPSNRAgainstCPULanczos3() {
        let w = 640, h = 480
        let image = makeImage(width: w, height: h, space: CGColorSpace(name: CGColorSpace.displayP3)!, fill: pattern)
        // Linear source (Display P3 = working space, so no matrix).
        var src = Img(width: w, height: h, px: Array(repeating: .zero, count: w * h))
        for y in 0..<h { for x in 0..<w {
            let e = pattern(x, y)
            src.px[y * w + x] = SIMD4(srgbToLinear(Double(e.x) / 255), srgbToLinear(Double(e.y) / 255), srgbToLinear(Double(e.z) / 255), 1)
        } }
        let dw = 256, dh = 200
        for scale in [0.3, 0.5, 0.73, 2.5] {
            let r = makeRenderer(width: dw, height: dh)
            r.settings.antiRinging = false
            r.setImage(image, key: "q")
            waitForPyramid(r, image)
            r.setZoom(.scale(scale))
            let out = render(r)
            XCTAssertEqual(r.lastPath, "canvas", "scale \(scale) must use the HQ path")
            let crop = (dw / 2 - 24, dh / 2 - 24, 48, 48)
            let ref = reference(src, scale: scale, drawable: (dw, dh), crop: crop)
            var got = Img(width: crop.2, height: crop.3, px: [])
            for y in 0..<crop.3 { for x in 0..<crop.2 { got.px.append(out[x: crop.0 + x, y: crop.1 + y]) } }
            let p = psnr(got, ref)
            print("PPR vs CPU Lanczos-3 at \(scale): \(String(format: "%.2f", p)) dB")
            XCTAssertGreaterThan(p, 40, "scale \(scale)")
        }
    }

    // MARK: HDR

    /// Extended-range half-float pixels keep values above 1.0 through the HQ path into the EDR (float) output,
    /// and the layer switches to the EDR configuration.
    func testHDRKeepsExtendedRange() {
        let w = 64, h = 48
        let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let pixels = pool.make(width: w, height: h, layout: .rgba16f, alpha: .opaque, colorSpace: space)!
        let base = pixels.baseAddress.assumingMemoryBound(to: Float16.self)
        for y in 0..<h { for x in 0..<w {
            let o = y * pixels.bytesPerRow / 2 + x * 4
            base[o] = 3.0; base[o + 1] = 0.5; base[o + 2] = 0.25; base[o + 3] = 1
        } }
        let image = DecodedImage(pixels: pixels, tier: .full, fullWidth: w, fullHeight: h, orientation: .up, isHDR: true, decodeNanos: 0)
        let layer = CAMetalLayer()
        let r = Renderer(layer: layer)
        r.setViewSize(CGSize(width: 50, height: 40), backingScale: 1)
        r.setImage(image, key: "hdr")
        XCTAssertEqual(layer.pixelFormat, .rgba16Float)
        XCTAssertTrue(layer.wantsExtendedDynamicRangeContent)
        let c = render(r)[x: 25, y: 20]
        XCTAssertEqual(c.x, 3.0, accuracy: 0.01)
        XCTAssertEqual(c.y, 0.5, accuracy: 0.01)
        XCTAssertEqual(r.lastPath, "canvas")
        // Back to SDR for an SDR image.
        r.setImage(makeImage(width: 8, height: 8) { _, _ in SIMD4(1, 2, 3, 255) }, key: "sdr")
        XCTAssertEqual(layer.pixelFormat, .bgra8Unorm)
    }

    // MARK: Robustness

    func testHugeImageDoesNotCrash() {
        let w = 20000, h = 600
        let image = makeImage(width: w, height: h) { x, _ in x < 10000 ? SIMD4(255, 0, 0, 255) : SIMD4(0, 0, 255, 255) }
        let r = makeRenderer(width: 1000, height: 300)
        r.setImage(image, key: "huge")
        _ = render(r)                       // before the pyramid exists
        waitForPyramid(r, image)
        let out = render(r)                 // fit: pyramid level 4
        XCTAssertGreaterThan(out[x: 250, y: 150].x, 0.5)
        XCTAssertGreaterThan(out[x: 750, y: 150].z, 0.5)
        r.setZoom(.scale(1), anchor: CGPoint(x: 500, y: 150))   // level 0 across the tile seam at x = 16384
        let near = render(r)
        XCTAssertEqual(r.lastPath, "exact")
        XCTAssertGreaterThan(near[x: 500, y: 150].x + near[x: 500, y: 150].z, 0.5)
        r.setZoom(.scale(0.8))
        _ = render(r)                       // L = 0 residual pass over tiles
        r.setZoom(.scale(5))
        _ = render(r)                       // sharp bilinear
    }

    func testGestureThenRefine() {
        let image = makeImage(width: 800, height: 600, fill: pattern)
        let r = makeRenderer(width: 200, height: 150)
        r.settings.refineDelayMs = 30
        r.setImage(image, key: "g")
        waitForPyramid(r, image)
        var refined = false
        r.onNeedsDisplay = { refined = true }
        r.beginInteraction()
        r.zoom(by: 1.1, anchor: CGPoint(x: 100, y: 75))
        _ = render(r)
        XCTAssertEqual(r.lastPath, "trilinear")
        r.endInteraction()
        let deadline = Date().addingTimeInterval(2)
        while !refined && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        XCTAssertTrue(refined, "refinement requested after the delay")
        _ = render(r)
        XCTAssertEqual(r.lastPath, "canvas")
        // Panning at a fixed zoom reuses the canvas.
        r.setZoom(.scale(1.5))
        _ = render(r)
        r.pan(by: CGVector(dx: 3, dy: 2))
        _ = render(r)
        XCTAssertEqual(r.lastPath, "canvas")
    }
}
