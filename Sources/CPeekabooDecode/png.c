// PNG decoder for the shapes ImageIO decodes slowest: truecolour and palette images, 8 or 16 bits, non-interlaced.
// Everything else (grayscale, Adam7, APNG, unknown critical chunks, malformed files) returns PB_PNG_UNSUPPORTED or
// PB_PNG_INVALID and is decoded by ImageIO instead.
//
// Cost model (24 MP RGB photo, M4 Pro): inflate 115–127 ms (system zlib ≈ libdeflate), unfilter 62 ms (branchless
// scalar Paeth; libpng-style NEON is 89 ms because the per-pixel dependency chain is longer), RGB → RGBA ~10 ms.
// Large images therefore inflate on a second thread into a ring of rows while the calling thread unfilters and
// converts, so the decode costs about as much as the inflate alone.
#include "PeekabooDecode.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>
#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif

// MARK: - Header

typedef struct {
    pb_png_info info;
    /// Bytes of one filtered row (without its filter-type byte) and of one complete pixel (≥ 1) for the filters.
    size_t row_bytes;
    unsigned bpp;
    /// Palette as RGBA words (bytes R, G, B, A); entries past the PLTE length are opaque black.
    uint32_t palette[256];
    int palette_size;
    int has_key;
    uint16_t key[3];
    /// Offset of the first IDAT chunk.
    size_t idat;
} png_t;

static const uint8_t signature[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'};

static inline uint32_t be32(const uint8_t *p) {
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

static inline uint16_t be16(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }

static int is_type(const uint8_t *type, const char *name) { return memcmp(type, name, 4) == 0; }

/// CRC of a chunk's type and data, compared with the stored one.
static int crc_ok(const uint8_t *chunk, uint32_t length) {
    uLong crc = crc32(0L, chunk + 4, (uInt)length + 4);
    return crc == be32(chunk + 8 + length);
}

/// The chunk at `pos`: its data length, or -1 when it does not fit in the file.
static int64_t chunk_length(const uint8_t *data, size_t size, size_t pos) {
    if (pos > size || size - pos < 12) return -1;
    uint32_t length = be32(data + pos);
    if (length > 0x7FFFFFFFu || length > size - pos - 12) return -1;
    for (int i = 4; i < 8; i++) {
        uint8_t c = data[pos + i];
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'))) return -1;
    }
    return length;
}

static pb_png_status parse(const uint8_t *data, size_t size, png_t *png) {
    memset(png, 0, sizeof *png);
    if (size < 8 + 25 || memcmp(data, signature, 8) != 0) return PB_PNG_INVALID;
    size_t pos = 8;
    int saw_header = 0, saw_palette = 0, saw_transparency = 0;
    pb_png_status deferred = PB_PNG_OK;
    for (;;) {
        int64_t length = chunk_length(data, size, pos);
        if (length < 0) return PB_PNG_INVALID;
        const uint8_t *chunk = data + pos, *type = chunk + 4, *body = chunk + 8;
        if (!saw_header && !is_type(type, "IHDR")) return PB_PNG_INVALID;
        if (is_type(type, "IDAT")) {
            if (png->info.color_type == 3 && !saw_palette) return PB_PNG_INVALID;
            if (deferred != PB_PNG_OK) return deferred;
            png->idat = pos;
            return PB_PNG_OK;
        }
        if (is_type(type, "IHDR")) {
            if (saw_header || length != 13 || !crc_ok(chunk, 13)) return PB_PNG_INVALID;
            saw_header = 1;
            uint32_t w = be32(body), h = be32(body + 4);
            uint8_t depth = body[8], ct = body[9];
            if (w == 0 || h == 0 || w > 0x7FFFFFFFu || h > 0x7FFFFFFFu) return PB_PNG_INVALID;
            if (body[10] != 0 || body[11] != 0 || body[12] > 1) return PB_PNG_INVALID;
            int depth_ok;
            switch (ct) {
            case 0: depth_ok = depth == 1 || depth == 2 || depth == 4 || depth == 8 || depth == 16; break;
            case 3: depth_ok = depth == 1 || depth == 2 || depth == 4 || depth == 8; break;
            case 2: case 4: case 6: depth_ok = depth == 8 || depth == 16; break;
            default: depth_ok = 0;
            }
            if (!depth_ok) return PB_PNG_INVALID;
            png->info.width = w;
            png->info.height = h;
            png->info.bit_depth = depth;
            png->info.color_type = ct;
            // Grayscale goes through ImageIO's gray colour space and a converting draw; Adam7 is rare for large images.
            if (ct == 0 || ct == 4 || body[12] == 1) deferred = PB_PNG_UNSUPPORTED;
            unsigned channels = ct == 2 ? 3 : ct == 6 ? 4 : ct == 4 ? 2 : 1;
            unsigned bits = channels * depth;
            png->row_bytes = ((size_t)w * bits + 7) / 8;
            png->bpp = bits >= 8 ? bits / 8 : 1;
            // zlib counts output in 32-bit units; rows this long are ImageIO's to refuse.
            if (png->row_bytes > (1u << 24)) deferred = PB_PNG_UNSUPPORTED;
            png->info.has_alpha = ct == 6 || ct == 4;
            for (int i = 0; i < 256; i++) png->palette[i] = 0xFF000000u;
        } else if (is_type(type, "PLTE")) {
            if (saw_palette || length % 3 != 0 || length == 0 || length > 768 || !crc_ok(chunk, (uint32_t)length)) {
                return PB_PNG_INVALID;
            }
            saw_palette = 1;
            if (png->info.color_type == 3) {
                png->palette_size = (int)(length / 3);
                if (png->palette_size > (1 << png->info.bit_depth)) png->palette_size = 1 << png->info.bit_depth;
                for (int i = 0; i < png->palette_size; i++) {
                    const uint8_t *e = body + 3 * i;
                    png->palette[i] = (uint32_t)e[0] | (uint32_t)e[1] << 8 | (uint32_t)e[2] << 16 | 0xFF000000u;
                }
            }
        } else if (is_type(type, "tRNS")) {
            if (saw_transparency || !crc_ok(chunk, (uint32_t)length)) return PB_PNG_INVALID;
            saw_transparency = 1;
            if (png->info.color_type == 3) {
                if (!saw_palette || length > (int64_t)png->palette_size) return PB_PNG_INVALID;
                for (int i = 0; i < length; i++) {
                    png->palette[i] = (png->palette[i] & 0x00FFFFFFu) | (uint32_t)body[i] << 24;
                    if (body[i] != 255) png->info.has_alpha = 1;
                }
            } else if (png->info.color_type == 2) {
                if (length != 6) return PB_PNG_INVALID;
                png->has_key = 1;
                png->info.has_alpha = 1;
                for (int i = 0; i < 3; i++) png->key[i] = be16(body + 2 * i);
            }
            // Gray keys are left to ImageIO with the rest of grayscale; tRNS beside an alpha channel is ignored.
        } else if (is_type(type, "acTL")) {
            deferred = PB_PNG_UNSUPPORTED;  // APNG: the animation is ImageIO's
        } else if (is_type(type, "IEND")) {
            return PB_PNG_INVALID;  // no image data
        } else if (!(type[0] & 0x20)) {
            deferred = PB_PNG_UNSUPPORTED;  // an unknown critical chunk
        }
        pos += 12 + (size_t)length;
    }
}

pb_png_status pb_png_read_info(const uint8_t *data, size_t size, pb_png_info *info) {
    png_t png;
    pb_png_status status = parse(data, size, &png);
    if (status == PB_PNG_OK) *info = png.info;
    return status;
}

// MARK: - Inflate

typedef struct {
    z_stream zs;
    const uint8_t *data;
    size_t size;
    /// Next chunk to read image data from.
    size_t next;
    int ended;
} inflater;

/// Point the stream at the next IDAT chunk's data. 0 when the image data is over (or a chunk is malformed).
static int next_idat(inflater *in) {
    for (;;) {
        int64_t length = chunk_length(in->data, in->size, in->next);
        if (length < 0 || !is_type(in->data + in->next + 4, "IDAT")) return 0;
        const uint8_t *chunk = in->data + in->next;
        if (!crc_ok(chunk, (uint32_t)length)) return 0;
        in->next += 12 + (size_t)length;
        if (length == 0) continue;
        in->zs.next_in = (Bytef *)(chunk + 8);
        in->zs.avail_in = (uInt)length;
        return 1;
    }
}

/// Inflate exactly `length` bytes (< 4 GB) into `out`. 0 on success.
static int inflate_exactly(inflater *in, uint8_t *out, size_t length) {
    in->zs.next_out = out;
    in->zs.avail_out = (uInt)length;
    while (in->zs.avail_out > 0) {
        if (in->ended) return -1;  // the stream ended before the last row
        if (in->zs.avail_in == 0 && !next_idat(in)) return -1;
        int r = inflate(&in->zs, Z_NO_FLUSH);
        if (r == Z_STREAM_END) {
            in->ended = 1;
        } else if (r != Z_OK) {
            return -1;
        }
    }
    return 0;
}

/// After the last row: read on to the end of the zlib stream so its checksum is verified. Extra data past the rows
/// is ignored (libpng's benign "too much image data"), within bounds.
static int inflate_finish(inflater *in) {
    uint8_t scratch[1024];
    for (int rounds = 0; !in->ended && rounds < 4096; rounds++) {
        if (in->zs.avail_in == 0 && !next_idat(in)) return -1;
        in->zs.next_out = scratch;
        in->zs.avail_out = sizeof scratch;
        int r = inflate(&in->zs, Z_NO_FLUSH);
        if (r == Z_STREAM_END) in->ended = 1;
        else if (r != Z_OK) return -1;
    }
    return in->ended ? 0 : -1;
}

// MARK: - Unfilter

static inline uint8_t paeth(int a, int b, int c) {
    int pa = abs(b - c), pb = abs(a - c), pc = abs(a + b - 2 * c);
    int bc = pb <= pc ? b : c;
    return (uint8_t)((pa <= pb && pa <= pc) ? a : bc);
}

// The left neighbour stays in a register per byte of the pixel (no store-to-load forwarding in the chain), which
// keeps `bpp` independent chains in flight: 62 ms for a 24 MP RGB Paeth image vs 151 ms branchy, 89 ms NEON.
#define DEFINE_UNFILTER(N)                                                                                          \
    static void unfilter_##N(int type, const uint8_t *in, uint8_t *out, const uint8_t *prev, size_t n) {            \
        uint8_t a[N];                                                                                               \
        switch (type) {                                                                                             \
        case 1:                                                                                                     \
            for (int k = 0; k < N; k++) a[k] = out[k] = in[k];                                                     \
            for (size_t i = N; i < n; i += N)                                                                       \
                for (int k = 0; k < N; k++) a[k] = out[i + k] = (uint8_t)(in[i + k] + a[k]);                       \
            break;                                                                                                  \
        case 3:                                                                                                     \
            for (int k = 0; k < N; k++) a[k] = out[k] = (uint8_t)(in[k] + (prev[k] >> 1));                         \
            for (size_t i = N; i < n; i += N)                                                                       \
                for (int k = 0; k < N; k++) a[k] = out[i + k] = (uint8_t)(in[i + k] + ((a[k] + prev[i + k]) >> 1)); \
            break;                                                                                                  \
        case 4:                                                                                                     \
            for (int k = 0; k < N; k++) a[k] = out[k] = (uint8_t)(in[k] + prev[k]);                                \
            for (size_t i = N; i < n; i += N)                                                                       \
                for (int k = 0; k < N; k++)                                                                         \
                    a[k] = out[i + k] = (uint8_t)(in[i + k] + paeth(a[k], prev[i + k], prev[i + k - N]));          \
            break;                                                                                                  \
        }                                                                                                           \
    }

DEFINE_UNFILTER(3)
DEFINE_UNFILTER(4)
DEFINE_UNFILTER(6)
DEFINE_UNFILTER(8)

static void unfilter_any(int type, const uint8_t *in, uint8_t *out, const uint8_t *prev, size_t n, unsigned bpp) {
    for (size_t i = 0; i < n; i++) {
        int a = i >= bpp ? out[i - bpp] : 0, b = prev[i], c = i >= bpp ? prev[i - bpp] : 0;
        uint8_t predictor;
        switch (type) {
        case 1: predictor = (uint8_t)a; break;
        case 3: predictor = (uint8_t)((a + b) >> 1); break;
        default: predictor = paeth(a, b, c); break;
        }
        out[i] = (uint8_t)(in[i] + predictor);
    }
}

/// Undo the filter of one row (`in` excludes the type byte) into `out`, given the previous unfiltered row. 0 on
/// success, -1 for an unknown filter type.
static int unfilter(int type, const uint8_t *in, uint8_t *out, const uint8_t *prev, size_t n, unsigned bpp) {
    switch (type) {
    case 0: memcpy(out, in, n); return 0;
    case 2:
        for (size_t i = 0; i < n; i++) out[i] = (uint8_t)(in[i] + prev[i]);
        return 0;
    case 1: case 3: case 4: break;
    default: return -1;
    }
    if (n % bpp != 0) {
        unfilter_any(type, in, out, prev, n, bpp);
        return 0;
    }
    switch (bpp) {
    case 3: unfilter_3(type, in, out, prev, n); break;
    case 4: unfilter_4(type, in, out, prev, n); break;
    case 6: unfilter_6(type, in, out, prev, n); break;
    case 8: unfilter_8(type, in, out, prev, n); break;
    default: unfilter_any(type, in, out, prev, n, bpp); break;
    }
    return 0;
}

// MARK: - Convert

/// One unfiltered row as RGBA, 8-bit (`out` 4 bytes per pixel).
static void row_rgba8(const png_t *png, const uint8_t *row, uint8_t *out) {
    const uint32_t w = png->info.width;
    const uint8_t depth = png->info.bit_depth;
    switch (png->info.color_type) {
    case 2:
        if (depth == 8) {
            uint32_t x = 0;
#if defined(__ARM_NEON)
            if (!png->has_key) {
                uint8x16_t opaque = vdupq_n_u8(255);
                for (; x + 16 <= w; x += 16) {
                    uint8x16x3_t rgb = vld3q_u8(row + 3 * x);
                    uint8x16x4_t rgba = {{rgb.val[0], rgb.val[1], rgb.val[2], opaque}};
                    vst4q_u8(out + 4 * x, rgba);
                }
            }
#endif
            for (; x < w; x++) {
                const uint8_t *p = row + 3 * x;
                uint8_t *o = out + 4 * x;
                o[0] = p[0]; o[1] = p[1]; o[2] = p[2];
                o[3] = png->has_key && p[0] == png->key[0] && p[1] == png->key[1] && p[2] == png->key[2] ? 0 : 255;
            }
        } else {
            for (uint32_t x = 0; x < w; x++) {
                const uint8_t *p = row + 6 * x;
                uint16_t r = be16(p), g = be16(p + 2), b = be16(p + 4);
                uint8_t *o = out + 4 * x;
                o[0] = (uint8_t)((r + 128) / 257); o[1] = (uint8_t)((g + 128) / 257); o[2] = (uint8_t)((b + 128) / 257);
                o[3] = png->has_key && r == png->key[0] && g == png->key[1] && b == png->key[2] ? 0 : 255;
            }
        }
        break;
    case 6:
        if (depth == 8) {
            memcpy(out, row, (size_t)w * 4);
        } else {
            for (size_t i = 0; i < (size_t)w * 4; i++) out[i] = (uint8_t)((be16(row + 2 * i) + 128) / 257);
        }
        break;
    case 3: {
        uint32_t *o = (uint32_t *)out;
        if (depth == 8) {
            for (uint32_t x = 0; x < w; x++) o[x] = png->palette[row[x]];
        } else {
            const unsigned per_byte = 8 / depth, mask = (1u << depth) - 1;
            for (uint32_t x = 0; x < w; x++) {
                unsigned shift = 8 - depth * (x % per_byte + 1);
                o[x] = png->palette[(row[x / per_byte] >> shift) & mask];
            }
        }
        break;
    }
    }
}

/// One unfiltered row of a 16-bit image as RGBA, 16-bit little-endian (`out` 8 bytes per pixel).
static void row_rgba16(const png_t *png, const uint8_t *row, uint16_t *out) {
    const uint32_t w = png->info.width;
    if (png->info.color_type == 6) {
        for (size_t i = 0; i < (size_t)w * 4; i++) out[i] = be16(row + 2 * i);
        return;
    }
    for (uint32_t x = 0; x < w; x++) {
        const uint8_t *p = row + 6 * x;
        uint16_t r = be16(p), g = be16(p + 2), b = be16(p + 4);
        uint16_t *o = out + 4 * x;
        o[0] = r; o[1] = g; o[2] = b;
        o[3] = png->has_key && r == png->key[0] && g == png->key[1] && b == png->key[2] ? 0 : 0xFFFF;
    }
}

// MARK: - Decode

typedef struct {
    const png_t *png;
    unsigned factor, shift;
    uint8_t *out;
    size_t stride;
    uint32_t out_width, out_height;
    /// Unfiltered current and previous rows (raw sample layout); the previous one starts as zeros.
    uint8_t *cur, *prev;
    /// Factor > 1: the row as RGBA 8-bit, and per source pixel the sums over the block's rows so far of R·A, G·A, B·A
    /// and A (opaque: R, G, B, A). Summing down the columns first keeps the per-row work vectorizable; each block's
    /// rows are folded across once, in `flush_block`.
    uint8_t *rgba;
    uint32_t *columns;
    uint32_t y;
} consumer;

static void flush_block(consumer *c, uint32_t rows) {
    const png_t *png = c->png;
    uint8_t *o = c->out + (size_t)(c->y / c->factor) * c->stride;
    const uint32_t f = c->factor, w = png->info.width;
    const int alpha = png->info.has_alpha;
    const unsigned square_shift = 2 * c->shift;
    for (uint32_t x = 0; x < c->out_width; x++, o += 4) {
        uint32_t first = x * f, cols = x + 1 < c->out_width ? f : w - first;
        uint32_t s[4] = {0, 0, 0, 0};
        const uint32_t *q = c->columns + 4 * (size_t)first;
        for (uint32_t i = 0; i < cols; i++, q += 4) {
            s[0] += q[0]; s[1] += q[1]; s[2] += q[2]; s[3] += q[3];
        }
        uint32_t n = cols * rows;
        if (alpha) {
            // Premultiplied average: Σ(c·a) / (255 n), Σa / n.
            for (int k = 0; k < 3; k++) o[k] = (uint8_t)((s[k] + 255u * n / 2) / (255u * n));
            o[3] = (uint8_t)((s[3] + n / 2) / n);
        } else if (n == f * f) {
            for (int k = 0; k < 3; k++) o[k] = (uint8_t)((s[k] + (n >> 1)) >> square_shift);
            o[3] = 255;
        } else {
            for (int k = 0; k < 3; k++) o[k] = (uint8_t)((s[k] + n / 2) / n);
            o[3] = 255;
        }
    }
}

/// Unfilter and convert the next row (`filtered` starts with the filter-type byte). 0 on success.
static int consume(consumer *c, const uint8_t *filtered) {
    const png_t *png = c->png;
    if (unfilter(filtered[0], filtered + 1, c->cur, c->prev, png->row_bytes, png->bpp) != 0) return -1;
    if (c->factor == 1) {
        uint8_t *o = c->out + (size_t)c->y * c->stride;
        if (png->info.bit_depth == 16) row_rgba16(png, c->cur, (uint16_t *)o);
        else row_rgba8(png, c->cur, o);
    } else {
        row_rgba8(png, c->cur, c->rgba);
        const size_t n = (size_t)png->info.width * 4;
        const uint8_t *p = c->rgba;
        uint32_t *col = c->columns;
        const uint32_t in_block = c->y % c->factor + 1;
        if (png->info.has_alpha) {
            for (size_t i = 0; i < n; i += 4) {
                uint32_t a = p[i + 3];
                uint32_t r = p[i] * a, g = p[i + 1] * a, b = p[i + 2] * a;
                if (in_block == 1) {
                    col[i] = r; col[i + 1] = g; col[i + 2] = b; col[i + 3] = a;
                } else {
                    col[i] += r; col[i + 1] += g; col[i + 2] += b; col[i + 3] += a;
                }
            }
        } else if (in_block == 1) {
            for (size_t i = 0; i < n; i++) col[i] = p[i];
        } else {
            for (size_t i = 0; i < n; i++) col[i] += p[i];
        }
        if (in_block == c->factor || c->y + 1 == png->info.height) flush_block(c, in_block);
    }
    uint8_t *t = c->cur; c->cur = c->prev; c->prev = t;
    c->y++;
    return 0;
}

/// The inflate thread's side of the pipeline: rows land in a ring of `capacity` slots; `produced` and `released`
/// count rows (released = rows the consumer has copied out of the ring).
typedef struct {
    inflater *in;
    uint8_t *ring;
    size_t slot;
    uint32_t capacity, batch, height;
    pthread_mutex_t lock;
    pthread_cond_t changed;
    uint32_t produced, released;
    int failed, cancelled;
} pipeline;

static void *produce(void *arg) {
    pipeline *p = arg;
    for (uint32_t y = 0; y < p->height;) {
        uint32_t n = p->height - y < p->batch ? p->height - y : p->batch;
        pthread_mutex_lock(&p->lock);
        while (!p->cancelled && y + n - p->released > p->capacity) pthread_cond_wait(&p->changed, &p->lock);
        int cancelled = p->cancelled;
        pthread_mutex_unlock(&p->lock);
        if (cancelled) return NULL;
        // The batch may wrap around the end of the ring.
        uint32_t start = y % p->capacity, first = p->capacity - start < n ? p->capacity - start : n;
        int bad = inflate_exactly(p->in, p->ring + (size_t)start * p->slot, (size_t)first * p->slot) != 0
            || (first < n && inflate_exactly(p->in, p->ring, (size_t)(n - first) * p->slot) != 0);
        if (!bad && y + n == p->height) bad = inflate_finish(p->in) != 0;
        pthread_mutex_lock(&p->lock);
        if (bad) p->failed = 1; else p->produced = y + n;
        pthread_cond_broadcast(&p->changed);
        pthread_mutex_unlock(&p->lock);
        if (bad) return NULL;
        y += n;
    }
    return NULL;
}

static pb_png_status run_pipelined(consumer *c, inflater *in, int *started) {
    const png_t *png = c->png;
    pipeline p;
    memset(&p, 0, sizeof p);
    p.in = in;  // by reference: a z_stream must not move (its state points back at it)
    p.slot = png->row_bytes + 1;
    p.batch = (uint32_t)(256 * 1024 / p.slot) + 1;
    p.capacity = 4 * p.batch;
    p.height = png->info.height;
    p.ring = malloc((size_t)p.capacity * p.slot);
    if (!p.ring) return PB_PNG_MEMORY;
    pthread_mutex_init(&p.lock, NULL);
    pthread_cond_init(&p.changed, NULL);
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_set_qos_class_np(&attr, qos_class_self(), 0);
    pthread_t thread;
    pb_png_status status = PB_PNG_OK;
    if (pthread_create(&thread, &attr, produce, &p) != 0) {
        pthread_attr_destroy(&attr);
        pthread_cond_destroy(&p.changed);
        pthread_mutex_destroy(&p.lock);
        free(p.ring);
        *started = 0;
        return PB_PNG_OK;
    }
    *started = 1;
    pthread_attr_destroy(&attr);
    uint32_t available = 0, released = 0;
    for (uint32_t y = 0; y < p.height; y++) {
        // Hand slots back every batch (not only when caught up), so a consumer slower than the inflate (16-bit, alpha
        // box filter) never leaves the inflate thread waiting for a whole ring.
        if (y == available || y - released >= p.batch) {
            pthread_mutex_lock(&p.lock);
            p.released = released = y;
            pthread_cond_broadcast(&p.changed);
            while (!p.failed && p.produced <= y) pthread_cond_wait(&p.changed, &p.lock);
            available = p.produced;
            int failed = p.failed && p.produced <= y;
            pthread_mutex_unlock(&p.lock);
            if (failed) { status = PB_PNG_INVALID; break; }
        }
        if (consume(c, p.ring + (size_t)(y % p.capacity) * p.slot) != 0) { status = PB_PNG_INVALID; break; }
    }
    pthread_mutex_lock(&p.lock);
    p.released = p.height;
    p.cancelled = 1;
    pthread_cond_broadcast(&p.changed);
    pthread_mutex_unlock(&p.lock);
    pthread_join(thread, NULL);
    if (status == PB_PNG_OK && p.failed) status = PB_PNG_INVALID;
    pthread_cond_destroy(&p.changed);
    pthread_mutex_destroy(&p.lock);
    free(p.ring);
    return status;
}

static pb_png_status run_inline(consumer *c, inflater *in) {
    const png_t *png = c->png;
    const size_t slot = png->row_bytes + 1;
    const uint32_t batch = (uint32_t)(256 * 1024 / slot) + 1;
    uint8_t *rows = malloc((size_t)batch * slot);
    if (!rows) return PB_PNG_MEMORY;
    pb_png_status status = PB_PNG_OK;
    for (uint32_t y = 0; y < png->info.height && status == PB_PNG_OK;) {
        uint32_t n = png->info.height - y < batch ? png->info.height - y : batch;
        if (inflate_exactly(in, rows, (size_t)n * slot) != 0) { status = PB_PNG_INVALID; break; }
        for (uint32_t k = 0; k < n; k++) {
            if (consume(c, rows + (size_t)k * slot) != 0) { status = PB_PNG_INVALID; break; }
        }
        y += n;
    }
    if (status == PB_PNG_OK && inflate_finish(in) != 0) status = PB_PNG_INVALID;
    free(rows);
    return status;
}

pb_png_status pb_png_decode(const uint8_t *data, size_t size, unsigned factor, uint8_t *out, size_t stride,
                            int threads) {
    png_t png;
    pb_png_status status = parse(data, size, &png);
    if (status != PB_PNG_OK) return status;
    if (factor != 1 && factor != 2 && factor != 4 && factor != 8) return PB_PNG_UNSUPPORTED;
    const uint32_t w = png.info.width;
    consumer c;
    memset(&c, 0, sizeof c);
    c.png = &png;
    c.factor = factor;
    c.shift = factor == 8 ? 3 : factor == 4 ? 2 : factor == 2 ? 1 : 0;
    c.out = out;
    c.stride = stride;
    c.out_width = pb_png_scaled(w, factor);
    c.out_height = pb_png_scaled(png.info.height, factor);
    if (stride < (size_t)c.out_width * pb_png_output_bytes_per_pixel(&png.info, factor)) return PB_PNG_INVALID;
    // Row buffers get 16 bytes of slack: the NEON loops never read past a row, but palette unpacking of the last
    // partial byte and the bpp-chunked loops stay comfortably inside.
    c.cur = calloc(1, png.row_bytes + 16);
    c.prev = calloc(1, png.row_bytes + 16);
    if (factor > 1) {
        c.rgba = malloc((size_t)w * 4 + 16);
        c.columns = malloc((size_t)w * 4 * sizeof(uint32_t));
    }
    inflater in;
    memset(&in, 0, sizeof in);
    in.data = data;
    in.size = size;
    in.next = png.idat;
    if (!c.cur || !c.prev || (factor > 1 && (!c.rgba || !c.columns)) || inflateInit(&in.zs) != Z_OK) {
        free(c.cur); free(c.prev); free(c.rgba); free(c.columns);
        return PB_PNG_MEMORY;
    }
    // A second thread pays off once the inflate takes a few milliseconds (≥ 1 MB of filtered rows).
    int started = 0;
    if (threads > 1 && (png.row_bytes + 1) * png.info.height >= (1u << 20)) status = run_pipelined(&c, &in, &started);
    if (!started && status == PB_PNG_OK) status = run_inline(&c, &in);
    inflateEnd(&in.zs);
    free(c.cur); free(c.prev); free(c.rgba); free(c.columns);
    return status;
}
