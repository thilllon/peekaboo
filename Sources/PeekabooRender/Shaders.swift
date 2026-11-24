// MSL source for the PPR renderer (compiled at runtime: the offline Metal compiler is not installed).
//
// Conventions shared by every pass, so that swapping in better pixels never shifts the picture:
//   * "tier texels": texels of the decoded tier texture (stored orientation, before EXIF orientation).
//     Texel i covers [i, i+1); its centre is i + 0.5. Lower tiers are addressed at a non-integer scale of the
//     full-resolution stored image, so every tier maps onto the same full-resolution coordinate system.
//   * pyramid level L texel i covers tier texels [i*2^L, (i+1)*2^L).
//   * colours after `fetch0` (and in every pyramid level / canvas) are linear Display P3, premultiplied alpha.
enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    #define MAXW 24
    #define MAXTILES 16
    constant float PI_F = 3.14159265358979f;

    // ---------------- 1-D kernels ----------------
    enum : int { F_LANCZOS3 = 0, F_CUBIC = 1, F_MKS2013 = 2, F_MKS2021 = 3 };
    inline float sincf(float x) { x = fabs(x); if (x < 1e-5f) return 1.0f; float px = PI_F * x; return precise::sin(px) / px; }
    inline float lanczos(float x, float a) { x = fabs(x); return x < a ? sincf(x) * sincf(x / a) : 0.0f; }
    inline float bccubic(float x, float B, float C) {
        x = fabs(x);
        if (x < 1.0f) return ((12.0f - 9.0f*B - 6.0f*C)*x*x*x + (-18.0f + 12.0f*B + 6.0f*C)*x*x + (6.0f - 2.0f*B)) * (1.0f/6.0f);
        if (x < 2.0f) return ((-B - 6.0f*C)*x*x*x + (6.0f*B + 30.0f*C)*x*x + (-12.0f*B - 48.0f*C)*x + (8.0f*B + 24.0f*C)) * (1.0f/6.0f);
        return 0.0f;
    }
    inline float mks2013(float x) {
        x = fabs(x);
        if (x <= 0.5f) return 17.0f/16.0f - 1.75f*x*x;
        if (x <= 1.5f) return (1.0f - x)*(1.75f - x);
        if (x <= 2.5f) { float t = 2.5f - x; return -0.125f*t*t; }
        return 0.0f;
    }
    inline float mks2021(float x) {
        x = fabs(x);
        if (x <= 0.5f) return 577.0f/576.0f - (239.0f/144.0f)*x*x;
        if (x <= 1.5f) return (140.0f*x*x - 379.0f*x + 239.0f) * (1.0f/144.0f);
        if (x <= 2.5f) return -(24.0f*x*x - 113.0f*x + 130.0f) * (1.0f/144.0f);
        if (x <= 3.5f) return (4.0f*x*x - 27.0f*x + 45.0f) * (1.0f/144.0f);
        if (x <= 4.5f) { float t = 2.0f*x - 9.0f; return -t*t * (1.0f/1152.0f); }
        return 0.0f;
    }
    inline float kern(int f, float x, float B, float C) {
        switch (f) {
            case F_LANCZOS3: return lanczos(x, 3.0f);
            case F_CUBIC:    return bccubic(x, B, C);
            case F_MKS2013:  return mks2013(x);
            case F_MKS2021:  return mks2021(x);
            default:         return 0.0f;
        }
    }

    // ---------------- source (tier texture) access: tiles + transfer function + gamut matrix ----------------
    struct SrcInfo {
        float4 m0, m1, m2;     // rows: source linear RGB -> linear Display P3
        int width, height;     // tier size in texels
        int tileShift, tileCols;
        int tileCount, trc;    // trc: 0 none (linear or hardware sRGB view), 1 sRGB curve (sign-symmetric), 2 LUT
        int alpha, lutSize;    // alpha: 0 opaque, 1 premultiplied, 2 straight
    };

    inline float3 trcDecode(float3 v, constant SrcInfo& s, constant float* lut) {
        if (s.trc == 1) {
            float3 a = fabs(v);
            float3 d = select(pow((a + 0.055f) / 1.055f, 2.4f), a / 12.92f, a <= 0.04045f);
            return copysign(d, v);
        } else if (s.trc == 2) {
            float n1 = float(s.lutSize - 1);
            float3 x = clamp(v, 0.0f, 1.0f) * n1;
            int3 i = min(int3(x), int3(s.lutSize - 2));
            float3 f = x - float3(i);
            return float3(mix(lut[i.x], lut[i.x + 1], f.x), mix(lut[i.y], lut[i.y + 1], f.y), mix(lut[i.z], lut[i.z + 1], f.z));
        }
        return v;
    }

    inline float4 rawRead(array<texture2d<float, access::read>, MAXTILES> tiles, constant SrcInfo& s, int x, int y) {
        x = clamp(x, 0, s.width - 1);
        y = clamp(y, 0, s.height - 1);
        if (s.tileCount <= 1) return tiles[0].read(uint2(uint(x), uint(y)));
        int tx = x >> s.tileShift, ty = y >> s.tileShift;
        return tiles[ty * s.tileCols + tx].read(uint2(uint(x - (tx << s.tileShift)), uint(y - (ty << s.tileShift))));
    }

    inline float4 toP3(float4 c, constant SrcInfo& s) {
        c.rgb = float3(dot(s.m0.xyz, c.rgb), dot(s.m1.xyz, c.rgb), dot(s.m2.xyz, c.rgb));
        return c;
    }

    // Level-0 texel as linear light in the source primaries, premultiplied (apply `toP3` after linear filtering).
    inline float4 fetch0lin(array<texture2d<float, access::read>, MAXTILES> tiles, constant SrcInfo& s, constant float* lut, int x, int y) {
        float4 c = rawRead(tiles, s, x, y);
        if (s.alpha == 0) {
            c.a = 1.0f;
            c.rgb = trcDecode(c.rgb, s, lut);
        } else if (s.alpha == 1) {
            if (s.trc != 0) {
                float a = c.a;
                float3 u = a > 1e-6f ? c.rgb / a : float3(0.0f);
                c.rgb = trcDecode(u, s, lut) * a;
            }
        } else {
            c.rgb = trcDecode(c.rgb, s, lut) * c.a;
        }
        return c;
    }

    // Level-0 texel as linear Display P3, premultiplied.
    inline float4 fetch0(array<texture2d<float, access::read>, MAXTILES> tiles, constant SrcInfo& s, constant float* lut, int x, int y) {
        return toP3(fetch0lin(tiles, s, lut, x, y), s);
    }

    // ---------------- resampling light ----------------
    constant float SIG_C = 0.75f, SIG_S = 6.5f;
    inline float3 sigFwd(float3 x) {
        float s0 = 1.0f / (1.0f + exp(SIG_S * SIG_C)), s1 = 1.0f / (1.0f + exp(SIG_S * (SIG_C - 1.0f)));
        return SIG_C - log(1.0f / (clamp(x, 0.0f, 1.0f) * (s1 - s0) + s0) - 1.0f) / SIG_S;
    }
    inline float3 sigInv(float3 y) {
        float s0 = 1.0f / (1.0f + exp(SIG_S * SIG_C)), s1 = 1.0f / (1.0f + exp(SIG_S * (SIG_C - 1.0f)));
        return (1.0f / (1.0f + exp(SIG_S * (SIG_C - y))) - s0) / (s1 - s0);
    }
    inline float4 toL(float4 c, int m) { if (m == 1) c.rgb = sigFwd(c.rgb); return c; }
    inline float4 fromL(float4 c, int m) { if (m == 1) c.rgb = sigInv(c.rgb); return c; }

    struct RP {
        float ox, oy;        // level texel position of output pixel (0,0)'s top-left corner
        float sx, sy;        // level texels per output pixel
        float kx, ky;        // kernel stretch per axis
        float radius;        // kernel support (kernel units)
        float antiring;      // 0..1; negative: also while reducing (safe because r < 2)
        float B, C;          // cubic parameters
        int filter;
        int srcW, srcH;      // level size
        int dstW, dstH;      // canvas size
        int rowStart;        // first source row held in tmp (this band)
        int dstRow0;         // first canvas row of this band
        int light;           // 0 linear, 1 sigmoidal
        int fromLevel0;      // 1: read level 0 through fetch0, 0: read `level`
        int tmpRows;
    };

    inline float4 fetchL(array<texture2d<float, access::read>, MAXTILES> tiles, texture2d<float, access::read> level, constant SrcInfo& s,
                         constant float* lut, constant RP& p, int x, int y) {
        if (p.fromLevel0 != 0) return fetch0(tiles, s, lut, x, y);
        return level.read(uint2(uint(clamp(x, 0, p.srcW - 1)), uint(clamp(y, 0, p.srcH - 1))));
    }

    // ---------------- PPR residual pass: per-axis weight tables + separable H/V ----------------
    struct AW { float o; float s; float k; float radius; float B; float C; int filter; int n; };
    kernel void axisWeights(constant AW& a [[buffer(0)]], device int* first [[buffer(1)]], device float* wts [[buffer(2)]],
                            uint i [[thread_position_in_grid]])
    {
        if (i >= (uint)a.n) return;
        float pc = a.o + (float(i) + 0.5f) * a.s - 0.5f;
        float r = a.radius * a.k;
        int x0 = int(ceil(pc - r)), x1 = int(floor(pc + r));
        int n = min(x1 - x0 + 1, MAXW);
        float ws = 0.0f, w[MAXW];
        for (int t = 0; t < MAXW; t++) { w[t] = t < n ? kern(a.filter, (float(x0 + t) - pc) / a.k, a.B, a.C) : 0.0f; ws += w[t]; }
        first[i] = x0;
        float inv = ws != 0.0f ? 1.0f / ws : 0.0f;
        for (int t = 0; t < MAXW; t++) wts[i * MAXW + t] = w[t] * inv;
    }

    // Specialised variants (no dead paths, so no register pressure from unused code):
    //   MODE 0: pyramid level (rgba16Float, linear light)      MODE 1: level 0, one tile, decoded by the texture unit
    //   MODE 2: level 0, general (tiles, transfer curve LUT, straight alpha; runtime light)
    template <int MODE, int LIGHT>
    inline void resampleHImpl(array<texture2d<float, access::read>, MAXTILES> tiles, texture2d<float, access::read> level, texture2d<float, access::write> tmp,
                              constant RP& p, constant int* first, constant float* wts, int ntaps,
                              constant SrcInfo& s, constant float* lut, uint2 gid)
    {
        if (gid.x >= (uint)p.dstW || gid.y >= (uint)p.tmpRows) return;
        int x0 = first[gid.x];
        int yy = p.rowStart + int(gid.y);
        constant float* w = wts + gid.x * MAXW;
        float4 acc = 0.0f;
        float ar = fabs(p.antiring);
        bool doAR = ar > 0.0f && (p.antiring < 0.0f || p.sx < 1.0f);
        int xi = int(floor(p.ox + (float(gid.x) + 0.5f) * p.sx - 0.5f));
        if (MODE == 0) {
            int W1 = p.srcW - 1;
            uint y = uint(clamp(yy, 0, p.srcH - 1));
            for (int t = 0; t < ntaps; t++) acc += w[t] * level.read(uint2(uint(clamp(x0 + t, 0, W1)), y));
            if (doAR) {
                float4 a = level.read(uint2(uint(clamp(xi, 0, W1)), y)), b = level.read(uint2(uint(clamp(xi + 1, 0, W1)), y));
                acc = mix(acc, clamp(acc, min(a, b), max(a, b)), ar);
            }
        } else if (MODE == 1) {
            texture2d<float, access::read> t0 = tiles[0];
            int W1 = s.width - 1;
            uint y = uint(clamp(yy, 0, s.height - 1));
            bool opaque = s.alpha == 0;
            if (LIGHT == 0) {
                // Linear light: filter in the source primaries, convert once (the matrix commutes with the filter).
                for (int t = 0; t < ntaps; t++) acc += w[t] * t0.read(uint2(uint(clamp(x0 + t, 0, W1)), y));
                if (doAR) {
                    float4 a = t0.read(uint2(uint(clamp(xi, 0, W1)), y)), b = t0.read(uint2(uint(clamp(xi + 1, 0, W1)), y));
                    acc = mix(acc, clamp(acc, min(a, b), max(a, b)), ar);
                }
                if (opaque) acc.a = 1.0f;
                acc = toP3(acc, s);
            } else {
                for (int t = 0; t < ntaps; t++) {
                    float4 c = t0.read(uint2(uint(clamp(x0 + t, 0, W1)), y));
                    if (opaque) c.a = 1.0f;
                    acc += w[t] * toL(toP3(c, s), 1);
                }
                if (doAR) {
                    float4 a = t0.read(uint2(uint(clamp(xi, 0, W1)), y)), b = t0.read(uint2(uint(clamp(xi + 1, 0, W1)), y));
                    if (opaque) { a.a = 1.0f; b.a = 1.0f; }
                    a = toL(toP3(a, s), 1); b = toL(toP3(b, s), 1);
                    acc = mix(acc, clamp(acc, min(a, b), max(a, b)), ar);
                }
            }
        } else {
            for (int t = 0; t < ntaps; t++) acc += w[t] * toL(fetch0(tiles, s, lut, x0 + t, yy), p.light);
            if (doAR) {
                float4 a = toL(fetch0(tiles, s, lut, xi, yy), p.light);
                float4 b = toL(fetch0(tiles, s, lut, xi + 1, yy), p.light);
                acc = mix(acc, clamp(acc, min(a, b), max(a, b)), ar);
            }
        }
        tmp.write(acc, gid);
    }

    #define RESAMPLE_H(NAME, MODE, LIGHT) \\
    kernel void NAME(array<texture2d<float, access::read>, MAXTILES> tiles [[texture(0)]], texture2d<float, access::read> level [[texture(16)]], \\
                     texture2d<float, access::write> tmp [[texture(17)]], \\
                     constant RP& p [[buffer(0)]], constant int* first [[buffer(1)]], constant float* wts [[buffer(2)]], \\
                     constant int& ntaps [[buffer(3)]], constant SrcInfo& s [[buffer(4)]], constant float* lut [[buffer(5)]], \\
                     uint2 gid [[thread_position_in_grid]]) \\
    { resampleHImpl<MODE, LIGHT>(tiles, level, tmp, p, first, wts, ntaps, s, lut, gid); }
    RESAMPLE_H(resampleH_level, 0, 0)
    RESAMPLE_H(resampleH_fast, 1, 0)
    RESAMPLE_H(resampleH_fastSigmoid, 1, 1)
    RESAMPLE_H(resampleH_general, 2, 0)

    template <int LIGHT>
    inline void resampleVImpl(texture2d<float, access::read> tmp, texture2d<float, access::write> dst, constant RP& p,
                              constant int* first, constant float* wts, int ntaps, uint2 gid)
    {
        int y = p.dstRow0 + int(gid.y);
        if (gid.x >= (uint)p.dstW || y >= p.dstH) return;
        int y0 = first[y];
        int H1 = p.srcH - 1, T1 = p.tmpRows - 1;
        constant float* w = wts + y * MAXW;
        float4 acc = 0.0f;
        for (int t = 0; t < ntaps; t++)
            acc += w[t] * tmp.read(uint2(gid.x, uint(clamp(clamp(y0 + t, 0, H1) - p.rowStart, 0, T1))));
        float ar = fabs(p.antiring);
        if (ar > 0.0f && (p.antiring < 0.0f || p.sy < 1.0f)) {
            int yi = int(floor(p.oy + (float(y) + 0.5f) * p.sy - 0.5f));
            float4 a = tmp.read(uint2(gid.x, uint(clamp(clamp(yi, 0, H1) - p.rowStart, 0, T1))));
            float4 b = tmp.read(uint2(gid.x, uint(clamp(clamp(yi + 1, 0, H1) - p.rowStart, 0, T1))));
            acc = mix(acc, clamp(acc, min(a, b), max(a, b)), ar);
        }
        float4 o = LIGHT == 1 ? fromL(acc, 1) : acc;
        o.a = clamp(o.a, 0.0f, 1.0f);
        dst.write(o, uint2(gid.x, uint(y)));
    }
    kernel void resampleV_linear(texture2d<float, access::read> tmp [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                                 constant RP& p [[buffer(0)]], constant int* first [[buffer(1)]], constant float* wts [[buffer(2)]],
                                 constant int& ntaps [[buffer(3)]], uint2 gid [[thread_position_in_grid]])
    { resampleVImpl<0>(tmp, dst, p, first, wts, ntaps, gid); }
    kernel void resampleV_sigmoid(texture2d<float, access::read> tmp [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                                  constant RP& p [[buffer(0)]], constant int* first [[buffer(1)]], constant float* wts [[buffer(2)]],
                                  constant int& ntaps [[buffer(3)]], uint2 gid [[thread_position_in_grid]])
    { resampleVImpl<1>(tmp, dst, p, first, wts, ntaps, gid); }

    // ---------------- pyramid: separable decimation by `factor` with host weights (linear light) ----------------
    struct DP { int taps, baseOff, factor, srcW, srcH, dstW, dstH, rowStart, dstRow0, tmpRows, fromLevel0, pad; };
    kernel void downH_level(texture2d<float, access::read> level [[texture(16)]],
                            texture2d<float, access::write> tmp [[texture(17)]],
                            constant DP& d [[buffer(0)]], constant float* w [[buffer(1)]],
                            uint2 gid [[thread_position_in_grid]])
    {
        int x = int(gid.x);
        if (x >= d.dstW || int(gid.y) >= d.tmpRows) return;
        uint y = uint(clamp(d.rowStart + int(gid.y), 0, d.srcH - 1));
        int base = x * d.factor + d.baseOff;
        float4 acc = 0.0f;
        for (int t = 0; t < d.taps; t++) acc += w[t] * level.read(uint2(uint(clamp(base + t, 0, d.srcW - 1)), y));
        tmp.write(acc, gid);
    }
    kernel void downH_source(array<texture2d<float, access::read>, MAXTILES> tiles [[texture(0)]],
                             texture2d<float, access::write> tmp [[texture(17)]],
                             constant DP& d [[buffer(0)]], constant float* w [[buffer(1)]],
                             constant SrcInfo& s [[buffer(4)]], constant float* lut [[buffer(5)]],
                             uint2 gid [[thread_position_in_grid]])
    {
        int x = int(gid.x);
        if (x >= d.dstW || int(gid.y) >= d.tmpRows) return;
        int y = clamp(d.rowStart + int(gid.y), 0, d.srcH - 1);
        int base = x * d.factor + d.baseOff;
        float4 acc = 0.0f;
        if (s.tileCount == 1 && s.trc == 0 && s.alpha != 2) {
            texture2d<float, access::read> t0 = tiles[0];
            for (int t = 0; t < d.taps; t++) acc += w[t] * t0.read(uint2(uint(clamp(base + t, 0, d.srcW - 1)), uint(y)));
            if (s.alpha == 0) acc.a = 1.0f;
        } else {
            for (int t = 0; t < d.taps; t++) acc += w[t] * fetch0lin(tiles, s, lut, clamp(base + t, 0, d.srcW - 1), y);
        }
        tmp.write(toP3(acc, s), gid);
    }
    kernel void downV(texture2d<float, access::read> tmp [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      constant DP& d [[buffer(0)]], constant float* w [[buffer(1)]],
                      uint2 gid [[thread_position_in_grid]])
    {
        int x = int(gid.x), y = d.dstRow0 + int(gid.y);
        if (x >= d.dstW || y >= d.dstH) return;
        int base = y * d.factor + d.baseOff;
        float4 acc = 0.0f;
        for (int t = 0; t < d.taps; t++)
            acc += w[t] * tmp.read(uint2(uint(x), uint(clamp(clamp(base + t, 0, d.srcH - 1) - d.rowStart, 0, d.tmpRows - 1))));
        acc.rgb = max(acc.rgb, 0.0f);
        acc.a = clamp(acc.a, 0.0f, 1.0f);
        dst.write(acc, uint2(uint(x), uint(y)));
    }

    // Level 0 -> linear float copy (Stage-0 previews: hardware bilinear for the B-spline).
    kernel void convertLinear(array<texture2d<float, access::read>, MAXTILES> tiles [[texture(0)]],
                              texture2d<float, access::write> dst [[texture(17)]],
                              constant SrcInfo& s [[buffer(4)]], constant float* lut [[buffer(5)]],
                              uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        dst.write(fetch0(tiles, s, lut, int(gid.x), int(gid.y)), gid);
    }

    // ---------------- present (render pipeline, one full-screen triangle) ----------------
    struct VOut { float4 position [[position]]; };
    vertex VOut fullscreenVS(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        VOut o; o.position = float4(p * 2.0f - 1.0f, 0.0f, 1.0f); return o;
    }

    struct PresentP {
        float4 imageRect;      // image extent in drawable pixels (x0, y0, x1, y1), for edge coverage
        float4 bg0, bg1;       // linear background (checker: two colours)
        float2 m0, m1, off;    // drawable pixel centre -> tier texel position
        int2 p0, p1, t;        // drawable pixel index -> canvas / tier texel index (signed permutation + offset)
        int2 canvasSize;
        float checker;         // checker cell in device pixels (0: solid)
        int mode;              // 0 background, 1 canvas, 2 exact, 3 B-spline, 4 sharp bilinear, 5 trilinear
        int encode;            // 1: sRGB-curve encode + dither (8-bit drawable); 0: linear (EDR / float)
        float ditherAmp;
        float zoom;            // device pixels per tier texel
        float gridAlpha;       // pixel grid strength (0: off)
        float lod;             // trilinear: log2(tier texels per device pixel)
        int levelA;            // trilinear: level bound to texture(1) (0: level 0 via fetch0)
        int levelB;            // trilinear: level bound to texture(2) (-1: none)
        int pad0, pad1, pad2;
    };

    inline float3 enc3(float3 x) { float3 a = fabs(x); float3 e = select(1.055f * pow(a, 1.0f / 2.4f) - 0.055f, 12.92f * a, a <= 0.0031308f); return copysign(e, x); }
    inline float hash12(float2 p) { float3 p3 = fract(float3(p.xyx) * 0.1031f); p3 += dot(p3, p3.yzx + 33.33f); return fract((p3.x + p3.y) * p3.z); }

    inline float4 bilinear0(array<texture2d<float, access::read>, MAXTILES> tiles, constant SrcInfo& s, constant float* lut, float2 pos, float2 f) {
        float2 t = pos - 0.5f; int2 i = int2(floor(t));
        float4 a = fetch0(tiles, s, lut, i.x, i.y), b = fetch0(tiles, s, lut, i.x + 1, i.y);
        float4 c = fetch0(tiles, s, lut, i.x, i.y + 1), d = fetch0(tiles, s, lut, i.x + 1, i.y + 1);
        return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
    }

    fragment float4 presentFS(VOut in [[stage_in]],
                              texture2d<float> canvas [[texture(0)]],
                              texture2d<float> levelA [[texture(1)]],
                              texture2d<float> levelB [[texture(2)]],
                              array<texture2d<float, access::read>, MAXTILES> tiles [[texture(3)]],
                              constant PresentP& q [[buffer(0)]], constant SrcInfo& s [[buffer(1)]], constant float* lut [[buffer(2)]])
    {
        float2 frag = in.position.xy;
        int2 px = int2(floor(frag));
        float covx = clamp(min(float(px.x) + 1.0f, q.imageRect.z) - max(float(px.x), q.imageRect.x), 0.0f, 1.0f);
        float covy = clamp(min(float(px.y) + 1.0f, q.imageRect.w) - max(float(px.y), q.imageRect.y), 0.0f, 1.0f);
        float cov = covx * covy;
        float4 c = 0.0f;
        if (cov > 0.0f && q.mode != 0) {
            if (q.mode == 1 || q.mode == 2) {
                int2 u = int2(q.p0.x * px.x + q.p0.y * px.y, q.p1.x * px.x + q.p1.y * px.y) + q.t;
                if (q.mode == 1) {
                    u = clamp(u, int2(0), q.canvasSize - 1);
                    c = canvas.read(uint2(u));
                } else {
                    c = fetch0(tiles, s, lut, u.x, u.y);
                }
            } else {
                float2 pos = float2(dot(q.m0, frag), dot(q.m1, frag)) + q.off;   // tier texels
                if (q.mode == 3) {
                    // 4-fetch cubic B-spline (B=1, C=0) over the linear preview: soft, never blocky or ringing.
                    constexpr sampler sm(coord::pixel, address::clamp_to_edge, filter::linear);
                    float2 t = pos - 0.5f, f = fract(t), cc = floor(t) + 0.5f;
                    float2 f2 = f * f, f3 = f2 * f;
                    float2 w0 = (1.0f/6.0f) * (1.0f - 3.0f*f + 3.0f*f2 - f3), w1 = (1.0f/6.0f) * (4.0f - 6.0f*f2 + 3.0f*f3);
                    float2 w2 = (1.0f/6.0f) * (1.0f + 3.0f*f + 3.0f*f2 - 3.0f*f3), w3 = (1.0f/6.0f) * f3;
                    float2 g0 = w0 + w1, g1 = w2 + w3;
                    float2 h0 = cc - 1.0f + w1 / g0, h1 = cc + 1.0f + w3 / g1;
                    c = g0.y * (g0.x * levelA.sample(sm, float2(h0.x, h0.y)) + g1.x * levelA.sample(sm, float2(h1.x, h0.y)))
                      + g1.y * (g0.x * levelA.sample(sm, float2(h0.x, h1.y)) + g1.x * levelA.sample(sm, float2(h1.x, h1.y)));
                } else if (q.mode == 4) {
                    // sharp bilinear: nearest with a 1-device-pixel antialiased seam (no shimmer while panning)
                    float2 t = pos - 0.5f, i = floor(t), f = t - i;
                    f = clamp((f - 0.5f) * q.zoom + 0.5f, 0.0f, 1.0f);
                    c = bilinear0(tiles, s, lut, i + 0.5f + 0.5f, f);
                    if (q.gridAlpha > 0.0f) {
                        float2 g = fract(pos);
                        float2 dist = min(g, 1.0f - g) * q.zoom;           // device pixels to the nearest texel edge
                        float line = 1.0f - clamp(min(dist.x, dist.y) - 0.5f, 0.0f, 1.0f);
                        c.rgb = mix(c.rgb, float3(0.5f) * c.a, line * q.gridAlpha);
                    }
                } else {
                    // trilinear over the pyramid (gesture path)
                    constexpr sampler sm(coord::pixel, address::clamp_to_edge, filter::linear);
                    float4 a;
                    if (q.levelA == 0) {
                        float2 t = pos - 0.5f; float2 f = t - floor(t);
                        a = bilinear0(tiles, s, lut, pos, f);
                    } else {
                        a = levelA.sample(sm, pos / float(1 << q.levelA));
                    }
                    if (q.levelB > 0) {
                        float4 b = levelB.sample(sm, pos / float(1 << q.levelB));
                        float fr = clamp(q.lod - float(q.levelA), 0.0f, 1.0f);
                        a = mix(a, b, fr);
                    }
                    c = a;
                }
            }
            c *= cov;
        }
        float3 bg = q.bg0.rgb;
        if (q.checker > 0.0f) {
            int2 cell = int2(floor(frag / q.checker));
            bg = ((cell.x + cell.y) & 1) ? q.bg1.rgb : q.bg0.rgb;
        }
        float3 lin = c.rgb + bg * (1.0f - c.a);
        if (q.encode != 0) {
            float3 rgb = enc3(clamp(lin, 0.0f, 1.0f));
            rgb += (hash12(frag) + hash12(frag + 17.13f) - 1.0f) * q.ditherAmp;   // TPDF +-1 LSB
            return float4(rgb, 1.0f);
        }
        return float4(lin, 1.0f);
    }
    """
}
