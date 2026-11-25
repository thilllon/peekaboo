// Decoders for the formats ImageIO has no fast path for (docs/DESIGN.md §2): PNG (system zlib, streaming inflate
// pipelined with the unfilter on a second thread) and the early rendition of progressive JPEGs (libjpeg-turbo on the
// first-pass scans only, decoded beside the exact decode).
#ifndef PEEKABOO_DECODE_H
#define PEEKABOO_DECODE_H

#include <stddef.h>
#include <stdint.h>

// MARK: PNG

typedef enum {
    PB_PNG_OK = 0,
    /// Valid, but left to ImageIO: grayscale, interlaced, animated (acTL), unknown critical chunks.
    PB_PNG_UNSUPPORTED = 1,
    /// Malformed or truncated (ImageIO decides what to show).
    PB_PNG_INVALID = 2,
    PB_PNG_MEMORY = 3,
} pb_png_status;

typedef struct {
    uint32_t width;
    uint32_t height;
    uint8_t bit_depth;
    uint8_t color_type;
    /// An alpha channel or a tRNS chunk: the output's alpha is meaningful (straight at factor 1).
    uint8_t has_alpha;
} pb_png_info;

/// Parse the header chunks (up to the first IDAT), checking their CRCs.
pb_png_status pb_png_read_info(const uint8_t *data, size_t size, pb_png_info *info);

/// Output size along one axis for a box-filter `factor` (1, 2, 4 or 8): ceil(length / factor).
static inline uint32_t pb_png_scaled(uint32_t length, unsigned factor) { return (length + factor - 1) / factor; }

/// Bytes per output pixel: 8 (RGBA, 16-bit little-endian) for 16-bit images at factor 1, else 4 (RGBA 8-bit).
static inline unsigned pb_png_output_bytes_per_pixel(const pb_png_info *info, unsigned factor) {
    return info->bit_depth == 16 && factor == 1 ? 8 : 4;
}

/// Decode into `out` (`stride` bytes per row): RGBA with the file's sample values, box-filtered by `factor`.
/// Opaque images get A = max. At factor 1 alpha stays straight (as stored); at factor > 1 the average is taken in
/// premultiplied form and the output is premultiplied. `threads` > 1 lets large images inflate on a second thread
/// while the calling thread unfilters.
pb_png_status pb_png_decode(const uint8_t *data, size_t size, unsigned factor, uint8_t *out, size_t stride,
                            int threads);

// MARK: Progressive JPEG

/// Offset just past the entropy-coded data of the scan after which every DCT coefficient of every component has
/// arrived at some precision, when refinement (successive-approximation) scans follow; 0 when the file has no such
/// point (not progressive Huffman, spectral selection only, malformed).
size_t pb_jpeg_first_pass_end(const uint8_t *data, size_t size);

/// Decode `data[0..<size]` as if the file ended there (libjpeg's memory source supplies the EOI): with `size` from
/// `pb_jpeg_first_pass_end`, the first-pass rendition of a progressive JPEG. BGRX into `out` (`stride` bytes per row),
/// DCT-scaled by 1/`denom`; the output must be `width` x `height`. Block smoothing is off: every coefficient is known
/// at that point, so it would only cost time. Returns 0, or -1 with a message.
int pb_jpeg_decode_truncated(const uint8_t *data, size_t size, int denom, int width, int height, uint8_t *out,
                             size_t stride, char *message, size_t message_size);

#endif
