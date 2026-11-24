import CoreGraphics
import Foundation
import ImageIO
import Metal
import PeekabooCore
import PeekabooRender
import QuartzCore

/// `peekaboo-bench render [image] [--frames N] [--size WxH] [--no-ar] [--png DIR]`
///
/// GPU time per frame of the PPR renderer at fit / 0.5 / 1.0 / 2.5 / 5× (settle frame = pyramid level + residual
/// Lanczos-3 into the canvas + present; canvas reuse = present only; gesture = trilinear), plus the pyramid build.
/// The default image is `$PEEKABOO_CORPUS/jpeg/jpeg_24mp_5947x3964.jpg`.
func runRenderBench(_ args: ArraySlice<String>) throws {
    var path: String?
    var frames = 20
    var noAR = false
    var pngDir: String?
    var rgba = false
    var size = (3456, 2234)
    var it = args.makeIterator()
    while let a = it.next() {
        switch a {
        case "--frames": frames = Int(it.next() ?? "") ?? frames
        case "--no-ar": noAR = true
        case "--png": pngDir = it.next()
        case "--rgba": rgba = true
        case "--size":
            let parts = (it.next() ?? "").split(separator: "x").compactMap { Int($0) }
            if parts.count == 2 { size = (parts[0], parts[1]) }
        default: path = a
        }
    }
    if path == nil, let corpus = ProcessInfo.processInfo.environment["PEEKABOO_CORPUS"] {
        path = corpus + "/jpeg/jpeg_24mp_5947x3964.jpg"
    }
    guard let path else {
        print("usage: peekaboo-bench render <image> [--frames N] [--size WxH]  (or set PEEKABOO_CORPUS)")
        return
    }
    let contextStart = Trace.now()
    let context = RenderContext.shared
    let contextMs = Trace.ms(since: contextStart)
    let pool = PixelBufferPool(device: context.device)
    let decodeStart = Trace.now()
    var image = try ImageIODecoder().decode(URL(fileURLWithPath: path), tier: .full, targetLongSide: 0, pool: pool)
    let decodeMs = Trace.ms(since: decodeStart)
    if rgba, image.pixels.layout == .bgra8, case .metal(let buffer) = image.pixels.storage {
        // Experiment: the same pixels as RGBA bytes.
        let px = image.pixels
        let p = px.baseAddress.assumingMemoryBound(to: UInt8.self)
        for y in 0..<px.height { for x in 0..<px.width { let o = y * px.bytesPerRow + x * 4; let b = p[o]; p[o] = p[o + 2]; p[o + 2] = b } }
        let swapped = PixelBuffer(width: px.width, height: px.height, bytesPerRow: px.bytesPerRow, layout: .rgba8, alpha: px.alpha,
                                  colorSpace: px.colorSpace, storage: .metal(buffer))
        image = DecodedImage(pixels: swapped, tier: .full, fullWidth: image.fullWidth, fullHeight: image.fullHeight,
                             orientation: image.orientation, isHDR: false, decodeNanos: 0)
    }
    print("image: \(URL(fileURLWithPath: path).lastPathComponent) \(image.pixels.width)x\(image.pixels.height) "
          + "(decode \(String(format: "%.1f", decodeMs)) ms, shader/pipeline init \(String(format: "%.1f", contextMs)) ms)")
    print("frame: \(size.0)x\(size.1) device px into bgra8Unorm, median of \(frames) frames, GPU time (gpuEnd - gpuStart)")

    // Pyramid build: best of 3 fresh builds.
    var builds: [(wallMs: Double, gpuMs: Double)] = []
    for _ in 0..<3 {
        let copy = DecodedImage(pixels: image.pixels, tier: .full, fullWidth: image.fullWidth, fullHeight: image.fullHeight,
                                orientation: image.orientation, isHDR: false, decodeNanos: 0)
        let probe = Renderer(layer: CAMetalLayer())
        probe.setViewSize(CGSize(width: size.0, height: size.1), backingScale: 1)
        probe.setImage(copy, key: "rebuild")
        let until = Date().addingTimeInterval(10)
        while probe.pyramidBuildTime(for: copy) == nil && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        if let t = probe.pyramidBuildTime(for: copy) { builds.append(t) }
    }
    if let best = builds.min(by: { $0.gpuMs < $1.gpuMs }) {
        print(String(format: "pyramid build (Lanczos-3, rgba16Float, ≤ 2 ms chunks), best of %d: GPU %.2f ms, wall %.2f ms",
                     builds.count, best.gpuMs, best.wallMs))
    }

    let renderer = Renderer(layer: CAMetalLayer())
    renderer.setViewSize(CGSize(width: size.0, height: size.1), backingScale: 1)
    renderer.settings.antiRinging = !noAR
    renderer.setImage(image, key: "bench")
    let deadline = Date().addingTimeInterval(10)
    while !renderer.isPyramidComplete(for: image) && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.001))
    }

    func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? .nan : s[s.count / 2] }
    func measure(_ body: () -> Void) -> Double {
        var times: [Double] = []
        for _ in 0..<frames {
            body()
            _ = renderer.renderOffscreen(format: .bgra8Unorm, reuseTarget: true)
            times.append(renderer.lastFrameGPUms)
        }
        return median(times)
    }
    // Warm up (GPU clocks ramp with load).
    for _ in 0..<30 { renderer.discardCanvas(); _ = renderer.renderOffscreen(format: .bgra8Unorm, reuseTarget: true) }
    let zooms: [(String, ZoomMode)] = [("fit", .fit), ("0.5x", .scale(0.5)), ("1.0x", .scale(1)), ("2.5x", .scale(2.5)), ("5x", .scale(5))]
    print("zoom   | settle frame ms | path       | next frame ms | path")
    for (name, mode) in zooms {
        renderer.setZoom(mode)
        let settle = measure { renderer.discardCanvas() }
        let settlePath = renderer.lastPath
        let reuse = measure {}
        let reusePath = renderer.lastPath
        if let pngDir, let frame = renderer.renderOffscreen(format: .bgra8Unorm) {
            savePNG(frame, to: "\(pngDir)/render-\(name).png")
        }
        print(name.padding(toLength: 6, withPad: " ", startingAt: 0)
              + String(format: " | %15.3f | ", settle) + settlePath.padding(toLength: 10, withPad: " ", startingAt: 0)
              + String(format: " | %13.3f | ", reuse) + reusePath)
    }
    // Gesture path: interaction in progress and the zoom just changed.
    renderer.settings.refineDelayMs = 1_000_000
    for (name, mode) in [("fit", ZoomMode.fit), ("0.5x", .scale(0.5)), ("2.5x", .scale(2.5))] {
        renderer.setZoom(mode)
        renderer.beginInteraction()
        let t = measure { renderer.zoom(by: 1.0001, anchor: CGPoint(x: size.0 / 2, y: size.1 / 2)) }
        print(String(format: "gesture %@: %.3f ms (%@)", name, t, renderer.lastPath))
        renderer.endInteraction()
    }
    // The usual fit view: the screen tier (decoded to cover the screen), treated as pyramid level k.
    let screen = try ImageIODecoder().decode(URL(fileURLWithPath: path), tier: .screen, targetLongSide: max(size.0, size.1), pool: pool)
    let tiered = Renderer(layer: CAMetalLayer())
    tiered.setViewSize(CGSize(width: size.0, height: size.1), backingScale: 1)
    tiered.setImage(screen, key: "screen")
    let until = Date().addingTimeInterval(10)
    while !tiered.isPyramidComplete(for: screen) && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
    var times: [Double] = []
    for _ in 0..<frames {
        tiered.discardCanvas()
        _ = tiered.renderOffscreen(format: .bgra8Unorm, reuseTarget: true)
        times.append(tiered.lastFrameGPUms)
    }
    print(String(format: "fit, screen tier %dx%d: settle frame %.3f ms (%@)", screen.pixels.width, screen.pixels.height,
                 median(times), tiered.lastPath))

    // Next / previous image: `prepare` pre-renders the fit canvas, so the first frame after `setImage` only presents.
    var firstFrames: [Double] = [], rasterised = 0
    for i in 0..<frames {
        let next = DecodedImage(pixels: image.pixels, tier: .full, fullWidth: image.fullWidth, fullHeight: image.fullHeight,
                                orientation: image.orientation, isHDR: false, decodeNanos: 0)
        tiered.prepare(next)
        let until = Date().addingTimeInterval(10)
        while !tiered.isPyramidComplete(for: next) && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        tiered.setImage(next, key: "next-\(i)")
        _ = tiered.renderOffscreen(format: .bgra8Unorm, reuseTarget: true)
        firstFrames.append(tiered.lastFrameGPUms)
        if tiered.lastFrameRasterised { rasterised += 1 }
    }
    print(String(format: "next image after prepare(): first frame %.3f ms (%@, %d/%d rasterised)", median(firstFrames),
                 tiered.lastPath, rasterised, frames))

    // Main-thread cost of `setImage` for an uncommon ICC profile (first sight: the probe used to run here).
    if let adobe = CGColorSpace(name: CGColorSpace.adobeRGB1998) {
        let px = image.pixels
        let pixels = PixelBuffer(width: px.width, height: px.height, bytesPerRow: px.bytesPerRow, layout: px.layout, alpha: px.alpha,
                                 colorSpace: adobe, storage: px.storage)
        let probeImage = DecodedImage(pixels: pixels, tier: .full, fullWidth: image.fullWidth, fullHeight: image.fullHeight,
                                      orientation: image.orientation, isHDR: false, decodeNanos: 0)
        let viewer = Renderer(layer: CAMetalLayer())
        viewer.setViewSize(CGSize(width: size.0, height: size.1), backingScale: 1)
        let t0 = Trace.now()
        viewer.setImage(probeImage, key: "adobe")
        let setMs = Trace.ms(since: t0)
        let t1 = Trace.now()
        viewer.render()
        let renderCPU = Trace.ms(since: t1)
        print(String(format: "setImage, Adobe RGB (1998) first sight: main thread %.3f ms (+ render encode %.3f ms)", setMs, renderCPU))
    }
}

/// Write a `bgra8Unorm` frame (Display P3 encoded) as PNG, for eyeballing the renderer's output.
private func savePNG(_ texture: MTLTexture, to path: String) {
    let w = texture.width, h = texture.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
          let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                              space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: info,
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}
