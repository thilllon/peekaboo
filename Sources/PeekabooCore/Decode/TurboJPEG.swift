import CTurboJPEG
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
}
