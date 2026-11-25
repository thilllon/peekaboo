import CoreGraphics
import CWebP
import Foundation

/// The frames of an animated WebP, composited by libwebp's `WebPAnimDecoder` one after another.
///
/// ImageIO composites frame i of a WebP from the first frame again on every call: frame 20 of a 44-frame 400×400 file
/// took 86 ms against 6 ms for frame 0, so playback slowed down with every frame. libwebp keeps the canvas and adds
/// only the next frame. Its rules are ImageIO's (disposal to transparent, alpha blending or replacing);
/// `AnimationTests` checks them against hand-made files and against ImageIO's frames.
///
/// Not thread-safe: `AnimationDecoder` owns it on one serial queue. Frames in order cost one frame's decode each, the
/// frame just returned again a copy, and a jump back starts over from the first frame.
final class WebPFrames {
    let canvasWidth: Int
    let canvasHeight: Int
    let frameCount: Int
    /// The file, mapped: libwebp reads every frame from these bytes while the decoder lives.
    private let file: NSData
    private let decoder: OpaquePointer
    /// The file's ICC profile (`ICCP` chunk), else sRGB: libwebp does no colour management, ImageIO tags frames so.
    private let colorSpace: CGColorSpace
    /// Index of the frame `WebPAnimDecoderGetNext` returns next, and the canvas of the one before it (valid until the
    /// next call).
    private var next = 0
    private var canvas: UnsafeMutablePointer<UInt8>?

    init(url: URL) throws {
        file = try NSData(contentsOf: url, options: .alwaysMapped)
        var options = WebPAnimDecoderOptions()
        guard WebPAnimDecoderOptionsInit(&options) != 0 else { throw DecodeError.unsupported(url.lastPathComponent) }
        options.color_mode = MODE_bgrA  // premultiplied BGRA: PixelLayout.bgra8
        options.use_threads = 0
        var data = WebPData(bytes: file.bytes.assumingMemoryBound(to: UInt8.self), size: file.length)
        guard let decoder = WebPAnimDecoderNew(&data, &options) else { throw DecodeError.unsupported(url.lastPathComponent) }
        var info = WebPAnimInfo()
        guard WebPAnimDecoderGetInfo(decoder, &info) != 0, info.frame_count > 0 else {
            WebPAnimDecoderDelete(decoder)
            throw DecodeError.unsupported(url.lastPathComponent)
        }
        self.decoder = decoder
        canvasWidth = Int(info.canvas_width)
        canvasHeight = Int(info.canvas_height)
        frameCount = Int(info.frame_count)
        colorSpace = Self.profile(decoder).flatMap { CGColorSpace(iccData: $0 as CFData) }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
    }

    deinit { WebPAnimDecoderDelete(decoder) }

    /// Frame `index`, composited at canvas size (premultiplied BGRA).
    func frame(_ index: Int, pool: PixelBufferPool) throws -> PixelBuffer {
        guard (0..<frameCount).contains(index) else { throw DecodeError.unsupported("frame \(index)") }
        if index != next - 1 {
            if index < next {
                WebPAnimDecoderReset(decoder)
                next = 0
            }
            var timestamp: Int32 = 0
            while next <= index {
                canvas = nil
                guard WebPAnimDecoderGetNext(decoder, &canvas, &timestamp) != 0 else {
                    throw DecodeError.unsupported("frame \(next)")
                }
                next += 1
            }
        }
        guard let canvas else { throw DecodeError.unsupported("frame \(index)") }
        guard let pixels = pool.make(width: canvasWidth, height: canvasHeight, layout: .bgra8, alpha: .premultiplied,
                                     colorSpace: colorSpace) else { throw DecodeError.outOfMemory }
        let rowBytes = canvasWidth * 4
        if pixels.bytesPerRow == rowBytes {
            memcpy(pixels.baseAddress, canvas, rowBytes * canvasHeight)
        } else {
            for y in 0..<canvasHeight {
                memcpy(pixels.baseAddress + y * pixels.bytesPerRow, canvas + y * rowBytes, rowBytes)
            }
        }
        return pixels
    }

    /// The `ICCP` chunk, if the file has one.
    private static func profile(_ decoder: OpaquePointer) -> Data? {
        guard let demux = WebPAnimDecoderGetDemuxer(decoder) else { return nil }
        var chunk = WebPChunkIterator()
        guard WebPDemuxGetChunk(demux, "ICCP", 1, &chunk) != 0 else { return nil }
        defer { WebPDemuxReleaseChunkIterator(&chunk) }
        guard let bytes = chunk.chunk.bytes, chunk.chunk.size > 0 else { return nil }
        return Data(bytes: bytes, count: chunk.chunk.size)
    }
}
