import CoreGraphics
import Foundation
import IOSurface
import Metal

/// Converts the bi-planar YCbCr IOSurfaces ImageIO's surface SPI decodes HEIF / AVIF into (`'420f'` for 8 bits when
/// asked, `'xf20'` for 10 bits, `'420f'` for the SDR rendition of a PQ / HLG image) into an RGB `PixelBuffer` with one
/// Metal compute pass, optionally reduced by a power of two: luma box-filtered over the reduction, chroma sampled
/// bilinearly at the output pixel's centre, the attachment's YCbCr matrix and range applied. 8-bit sources become
/// `.bgra8`, deeper ones `.bgr10a2` (4 bytes per pixel either way, opaque).
///
/// Measured on M4 Pro, macOS 26.6 (best of 5): ImageIO's own BGRA surface of a 12 MP / 50 MP HEIC costs 32 / 83 ms, its
/// raw YCbCr 10 / 22 ms, the pass ~1–2 ms. Reduced SPI decodes are converted and downsampled on the CPU by ImageIO
/// (12 MP /4 30 ms; 10-bit 24 MP /2…/8 36–75 ms vs 7.5 ms at /1): reductions happen here instead. For 10-bit images
/// the public path drew the CGImage into BGRA on the CPU (24 MP 115–212 ms). Compiled on first use (a decode lane).
enum YCbCrConverter {
    /// The surface layout of a convertible bi-planar YCbCr surface.
    struct Format: Equatable {
        let deep: Bool
        let fullRange: Bool
    }

    /// Bi-planar YCbCr formats (4:2:0, 4:2:2, 4:4:4; subsampling comes from the plane sizes).
    static func format(of surface: IOSurfaceRef) -> Format? {
        guard IOSurfaceGetPlaneCount(surface) == 2 else { return nil }
        let full: Bool
        switch IOSurfaceGetPixelFormat(surface) {
        case fourCC("420f"), fourCC("422f"), fourCC("444f"), fourCC("xf20"), fourCC("xf22"), fourCC("xf44"): full = true
        case fourCC("420v"), fourCC("422v"), fourCC("444v"), fourCC("x420"), fourCC("x422"), fourCC("x444"): full = false
        default: return nil
        }
        let luma = IOSurfaceGetBytesPerElementOfPlane(surface, 0)
        let chroma = IOSurfaceGetBytesPerElementOfPlane(surface, 1)
        guard (luma == 1 && chroma == 2) || (luma == 2 && chroma == 4) else { return nil }
        return Format(deep: luma == 2, fullRange: full)
    }

    static func fourCC(_ s: String) -> OSType { s.utf8.reduce(0) { $0 << 8 | OSType($1) } }

    /// Largest surface side converted (the Metal texture limit).
    static let maxSide = 16384

    /// `surface` as RGB in `colorSpace`, reduced by `scale` ∈ {1, 2, 4, 8} (output size rounded up), or nil (not a
    /// supported layout, larger than a texture, no Metal, out of memory).
    static func convert(_ surface: IOSurfaceRef, scale: Int = 1, pool: PixelBufferPool, colorSpace: CGColorSpace) -> PixelBuffer? {
        guard let format = format(of: surface), let gpu = GPU.shared(pool.device) else { return nil }
        let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
        let chromaWidth = IOSurfaceGetWidthOfPlane(surface, 1), chromaHeight = IOSurfaceGetHeightOfPlane(surface, 1)
        let scale = max(1, min(scale, 8))
        let outWidth = (width + scale - 1) / scale, outHeight = (height + scale - 1) / scale
        guard width > 0, height > 0, chromaWidth > 0, chromaHeight > 0,
              width <= maxSide, height <= maxSide else { return nil }
        let layout: PixelLayout = format.deep ? .bgr10a2 : .bgra8
        guard let pixels = pool.make(width: outWidth, height: outHeight, layout: layout, alpha: .opaque, colorSpace: colorSpace),
              case .metal(let buffer) = pixels.storage else { return nil }
        func planeTexture(_ plane: Int, _ format: MTLPixelFormat, _ w: Int, _ h: Int) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead]
            d.storageMode = .shared
            return gpu.device.makeTexture(descriptor: d, iosurface: surface, plane: plane)
        }
        let outDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: layout.metalFormat, width: outWidth,
                                                                     height: outHeight, mipmapped: false)
        outDescriptor.usage = [.shaderWrite]
        outDescriptor.storageMode = .shared
        guard let luma = planeTexture(0, format.deep ? .r16Unorm : .r8Unorm, width, height),
              let chroma = planeTexture(1, format.deep ? .rg16Unorm : .rg8Unorm, chromaWidth, chromaHeight),
              let out = buffer.makeTexture(descriptor: outDescriptor, offset: 0, bytesPerRow: pixels.bytesPerRow),
              let commands = gpu.queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else { return nil }
        var params = Params(format: format, matrix: matrix(surface), scale: scale,
                            chromaScale: SIMD2(Float(chromaWidth) / Float(width), Float(chromaHeight) / Float(height)))
        commands.label = "YCbCr → RGB"
        encoder.setComputePipelineState(gpu.pipeline)
        encoder.setTexture(luma, index: 0)
        encoder.setTexture(chroma, index: 1)
        encoder.setTexture(out, index: 2)
        encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
        encoder.dispatchThreads(MTLSize(width: outWidth, height: outHeight, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        return commands.status == .completed ? pixels : nil
    }

    /// Kr, Kb of the surface's YCbCr matrix (BT.601 when it carries none).
    static func matrix(_ surface: IOSurfaceRef) -> (kr: Float, kb: Float) {
        let name = IOSurfaceCopyValue(surface, "IOSurfaceYCbCrMatrix" as CFString) as? String ?? ""
        if name.hasPrefix("ITU_R_709") { return (0.2126, 0.0722) }
        if name.hasPrefix("ITU_R_2020") { return (0.2627, 0.0593) }
        if name.hasPrefix("SMPTE_240M") { return (0.212, 0.087) }
        return (0.299, 0.114)
    }

    /// Mirrors `struct P` in the kernel.
    struct Params {
        var r: SIMD4<Float>, g: SIMD4<Float>, b: SIMD4<Float>
        var offset: SIMD4<Float>   // y, cb, cr offsets (normalised texel values)
        var scale: SIMD4<Float>    // y, cb, cr scales
        var chromaScale: SIMD2<Float>
        var reduction: Int32
        var pad: Int32 = 0

        init(format: Format, matrix m: (kr: Float, kb: Float), scale reduction: Int, chromaScale: SIMD2<Float>) {
            let kg = 1 - m.kr - m.kb
            // Y' + matrix · (Cb, Cr) with Y' ∈ [0, 1], Cb, Cr ∈ [−½, ½].
            r = SIMD4(1, 0, 2 * (1 - m.kr), 0)
            g = SIMD4(1, -2 * m.kb * (1 - m.kb) / kg, -2 * m.kr * (1 - m.kr) / kg, 0)
            b = SIMD4(1, 2 * (1 - m.kb), 0, 0)
            // Unorm texels: 8-bit codes / 255, or 10-bit codes in the high bits of 16-bit containers / 65535.
            let code: Float = format.deep ? 65535 / 64 : 255   // texel value 1.0 as a code of the source depth
            let depthScale: Float = format.deep ? 4 : 1        // codes per 8-bit step
            let yOffset: Float = format.fullRange ? 0 : 16 * depthScale
            let yRange: Float = format.fullRange ? (format.deep ? 1023 : 255) : 219 * depthScale
            let cRange: Float = format.fullRange ? (format.deep ? 1023 : 255) : 224 * depthScale
            offset = SIMD4(yOffset / code, 128 * depthScale / code, 128 * depthScale / code, 0)
            scale = SIMD4(code / yRange, code / cRange, code / cRange, 0)
            self.chromaScale = chromaScale
            self.reduction = Int32(reduction)
        }
    }

    /// Device, queue and pipeline, created on first use.
    private final class GPU: @unchecked Sendable {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipeline: MTLComputePipelineState

        private static let lock = NSLock()
        nonisolated(unsafe) private static var instance: GPU?
        nonisolated(unsafe) private static var failed = false

        static func shared(_ device: MTLDevice) -> GPU? {
            lock.lock(); defer { lock.unlock() }
            if let instance, instance.device === device { return instance }
            guard !failed else { return nil }
            guard let made = GPU(device: device) else { failed = true; return nil }
            instance = made
            return made
        }

        private init?(device: MTLDevice) {
            let start = Trace.now()
            guard let queue = device.makeCommandQueue(),
                  let library = try? device.makeLibrary(source: Self.source, options: nil),
                  let function = library.makeFunction(name: "ycbcrToRGB"),
                  let pipeline = try? device.makeComputePipelineState(function: function) else { return nil }
            self.device = device
            self.queue = queue
            self.pipeline = pipeline
            Trace.log("YCbCr converter ready in \(String(format: "%.1f", Trace.ms(since: start))) ms")
        }

        static let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct P { float4 r, g, b, offset, scale; float2 chromaScale; int reduction, pad; };
        kernel void ycbcrToRGB(texture2d<float, access::read> luma [[texture(0)]],
                               texture2d<float, access::sample> chroma [[texture(1)]],
                               texture2d<float, access::write> out [[texture(2)]],
                               constant P& p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
            constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::linear);
            // Box filter over the reduction's block of luma texels (clipped at the right and bottom edges).
            uint2 size = uint2(luma.get_width(), luma.get_height());
            uint n = uint(p.reduction);
            uint2 origin = gid * n;
            uint2 end = min(origin + n, size);
            float y = 0.0f;
            for (uint j = origin.y; j < end.y; j++)
                for (uint i = origin.x; i < end.x; i++) y += luma.read(uint2(i, j)).r;
            y = (y / float((end.x - origin.x) * (end.y - origin.y)) - p.offset.x) * p.scale.x;
            // Chroma at the block's centre, in luma texels.
            float2 centre = (float2(origin) + float2(end)) * 0.5f;
            float2 c = (chroma.sample(s, centre * p.chromaScale).rg - p.offset.yz) * p.scale.yz;
            float3 ycc = float3(y, c.x, c.y);
            out.write(float4(saturate(float3(dot(p.r.xyz, ycc), dot(p.g.xyz, ycc), dot(p.b.xyz, ycc))), 1.0f), gid);
        }
        """
    }
}
