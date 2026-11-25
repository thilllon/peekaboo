// Early rendition of progressive JPEGs. A progressive file's refinement scans (successive approximation, Ah > 0)
// cost most of its decode while adding only the low bits of each coefficient: on a 24 MP photo the first-pass scans
// (52 % of the bytes) decode in 77 ms, the whole file in 300 ms. Decoding the file cut after its last first-pass scan
// yields a rendition at 35–52 dB PSNR of the exact one, while the exact decode runs on another thread.
#include "PeekabooDecode.h"

#include <setjmp.h>
#include <stdio.h>
#include <string.h>

// The libjpeg API of the libjpeg-turbo build PeekabooCore links statically (`mise run deps` installs its headers into
// .deps/ next to turbojpeg.h; see Package.swift). A "file not found" here means it has not been built yet:
#include "../../.deps/libjpeg-turbo/include/jpeglib.h"  // run `mise run deps`

/// Progressive files with more scans than this are left to the exact decode (a legitimate scan script has < 100).
enum { max_scans = 1000 };

size_t pb_jpeg_first_pass_end(const uint8_t *d, size_t n) {
    if (n < 4 || d[0] != 0xFF || d[1] != 0xD8) return 0;
    int components = 0, ids[4] = {0}, progressive = 0, pending = 0, scans = 0;
    uint64_t seen[4] = {0};  // bit k: coefficient k (zig-zag) of that component had its first pass
    size_t i = 2;
    while (i + 4 <= n) {
        if (d[i] != 0xFF) return 0;
        uint8_t m = d[i + 1];
        if (m == 0xFF) { i++; continue; }  // fill byte
        if (m == 0xD8 || m == 0x01 || (m >= 0xD0 && m <= 0xD7)) { i += 2; continue; }
        if (m == 0xD9) return 0;  // EOI before every coefficient arrived
        size_t length = (size_t)d[i + 2] << 8 | d[i + 3];
        if (length < 2 || length > n - i - 2) return 0;
        const uint8_t *s = d + i + 4;
        size_t body = length - 2;
        if (m == 0xC2) {  // SOF2: progressive, Huffman
            if (body < 6 || progressive) return 0;
            components = s[5];
            if (components < 1 || components > 4 || body < 6 + 3 * (size_t)components) return 0;
            for (int k = 0; k < components; k++) ids[k] = s[6 + 3 * k];
            progressive = 1;
        } else if (m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC) {
            return 0;  // another frame type
        } else if (m == 0xDA) {  // SOS
            if (!progressive || body < 1) return 0;
            int count = s[0];
            if (count < 1 || count > 4 || body < 1 + 2 * (size_t)count + 3 || ++scans > max_scans) return 0;
            int ss = s[1 + 2 * count], se = s[2 + 2 * count], ah = s[3 + 2 * count] >> 4, al = s[3 + 2 * count] & 15;
            if (ss > se || se > 63) return 0;
            if (ah == 0) {
                uint64_t band = (se == 63 ? ~0ull : (1ull << (se + 1)) - 1) & ~((1ull << ss) - 1);
                for (int c = 0; c < count; c++) {
                    int k = 0;
                    while (k < components && ids[k] != s[1 + 2 * c]) k++;
                    if (k == components) return 0;
                    seen[k] |= band;
                }
                if (al > 0) pending = 1;
            }
            // Skip the entropy-coded data: it ends at the first marker other than a stuffed 0xFF00 or RSTn.
            size_t j = i + 2 + length;
            for (;;) {
                const uint8_t *ff = memchr(d + j, 0xFF, n - j);
                if (!ff || (size_t)(ff - d) + 1 >= n) return 0;
                j = (size_t)(ff - d);
                uint8_t next = d[j + 1];
                if (next == 0x00 || (next >= 0xD0 && next <= 0xD7)) { j += 2; continue; }
                break;
            }
            int complete = 1;
            for (int k = 0; k < components; k++) complete &= seen[k] == ~0ull;
            if (complete) return pending ? j : 0;
            i = j;
            continue;
        }
        i += 2 + length;
    }
    return 0;
}

typedef struct {
    struct jpeg_error_mgr pub;
    jmp_buf jump;
} error_manager;

static void fail(j_common_ptr cinfo) { longjmp(((error_manager *)cinfo->err)->jump, 1); }

/// Corrupt-data warnings do not stop the decode (TurboJPEG's default); the cut stream always ends in one ("premature
/// end of JPEG file") when the memory source supplies the EOI.
static void quiet(j_common_ptr cinfo, int level) { (void)cinfo; (void)level; }

int pb_jpeg_decode_truncated(const uint8_t *data, size_t size, int denom, int width, int height, uint8_t *out,
                             size_t stride, char *message, size_t message_size) {
    struct jpeg_decompress_struct cinfo;
    error_manager errors;
    cinfo.err = jpeg_std_error(&errors.pub);
    errors.pub.error_exit = fail;
    errors.pub.emit_message = quiet;
    if (setjmp(errors.jump)) {
        if (message && message_size) {
            char text[JMSG_LENGTH_MAX];
            (*cinfo.err->format_message)((j_common_ptr)&cinfo, text);
            snprintf(message, message_size, "%s", text);
        }
        jpeg_destroy_decompress(&cinfo);
        return -1;
    }
    jpeg_create_decompress(&cinfo);
    jpeg_mem_src(&cinfo, data, (unsigned long)size);
    jpeg_read_header(&cinfo, TRUE);
    if (cinfo.jpeg_color_space == JCS_CMYK || cinfo.jpeg_color_space == JCS_YCCK) {
        if (message && message_size) snprintf(message, message_size, "CMYK");
        jpeg_destroy_decompress(&cinfo);
        return -1;
    }
    cinfo.out_color_space = JCS_EXT_BGRX;
    cinfo.scale_num = 1;
    cinfo.scale_denom = (unsigned)denom;
    cinfo.do_block_smoothing = FALSE;
    jpeg_start_decompress(&cinfo);
    if (cinfo.output_width != (JDIMENSION)width || cinfo.output_height != (JDIMENSION)height
        || cinfo.output_components != 4) {
        if (message && message_size) snprintf(message, message_size, "unexpected output size");
        jpeg_destroy_decompress(&cinfo);
        return -1;
    }
    while (cinfo.output_scanline < cinfo.output_height) {
        JSAMPROW rows[16];
        JDIMENSION count = cinfo.rec_outbuf_height < 16 ? (JDIMENSION)cinfo.rec_outbuf_height : 16;
        if (count > cinfo.output_height - cinfo.output_scanline) count = cinfo.output_height - cinfo.output_scanline;
        for (JDIMENSION r = 0; r < count; r++) rows[r] = out + (size_t)(cinfo.output_scanline + r) * stride;
        jpeg_read_scanlines(&cinfo, rows, count);
    }
    jpeg_finish_decompress(&cinfo);
    jpeg_destroy_decompress(&cinfo);
    return 0;
}
