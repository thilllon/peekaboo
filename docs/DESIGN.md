# Peekaboo — design

Ultra-fast image viewer for macOS on Apple Silicon. This document records the decisions and the
measurements behind them (all measured on an M4 Pro, 48 GB, macOS 26.6, unless noted).
`docs/research.md` summarises the research; this file is what the code must implement.

## 1. Decisions

| Question | Decision | Evidence |
|---|---|---|
| Language | **Swift + AppKit + Metal + ImageIO**, plus libjpeg-turbo (C, static) | Both Swift and Rust compile through LLVM; every measured win comes from the decoder or the pipeline. HEIC hardware decode, camera RAW previews, HDR gain maps and AppKit integration exist only through Apple frameworks. AppKit init (~75–110 ms) dominates launch in both languages; dyld + Swift runtime ≈ 6 ms. |
| UI toolkit | Programmatic AppKit, no storyboards/nibs/SwiftUI | `NSApplication.shared` 35–48 ms, first window 31–46 ms (borderless 12 ms), menu 1–2 ms. |
| Display | Own Metal renderer on a raw `CAMetalLayer` | `CALayer.contents = CGImage` costs 58–323 ms of main-thread CPU per 24 MP image (colour conversion at commit). Metal: ~1 ms upload + < 3 ms draw. |
| Upload | Zero-copy: decode into a shared `MTLBuffer` / IOSurface, wrap as texture | `makeTexture` over the buffer: 0.014 ms. `replace(region:)` 7.6 ms. |
| Lifecycle | Stay resident after the last window closes | Re-open of a running app ≈ 65 ms (mostly `open`/LaunchServices) vs 230–250 ms cold. |
| Shaders | MSL source embedded in Swift, compiled at runtime on a background thread started in `main()` | Offline compiler absent. 1.1 ms with a warm OS shader cache, 31–42 ms (≤ 97 ms) on first compile; hidden behind AppKit init. |

## 2. Decode paths (per format)

ImageIO facts that drive the routing:
- Baseline JPEG is decoded by the **hardware JPEG engines** (2 on M4 Pro) at every size tested — 24 / 50 / 60 MP in
  49.8 / 114 / 129 ms vs libjpeg-turbo 109 / 284 / 308 ms, and up to 101.5 MP / 65000 px wide through the IOSurface path
  (101.5 MP: 123 ms wall, 16 ms CPU). Progressive JPEGs never are; that is why the 101 MP and panorama corpus files
  (both progressive) take 0.7–1 s in ImageIO.
- `kCGImageSourceShouldCacheImmediately` decodes are **serialised process-wide** (flat 10.5 img/s at 1–12 threads); a lazy
  `CGImage` drawn into our own pre-faulted buffer in its native colour space scales to 33 img/s at 12 threads, and the
  private `CGImageSourceCreateIOSurfaceAtIndex` path also runs in parallel. Never share a `CGImageSource` across threads:
  it serialises (2.9–6.7× slower) and produced non-deterministic pixels in the thread-safety test. That private call returns a BGRA
  IOSurface (zero copy to Metal) and uses **both** HW engines: 24 MP at ~20 ms per image with 2 workers.
  It is resolved with `dlsym` and must fall back to the public path when missing.
- `CreateThumbnailAtIndex(Always, MaxPixelSize 3456)` is a **trap** for JPEG (131–144 ms for 24 MP, 3× a full
  HW decode: CPU resampling). Decode full or `SubsampleFactor 2` and scale on the GPU.
- Thumbnails with `MaxPixelSize` and *without* `…Always` return embedded previews: JPEG EXIF thumb 0.3–0.5 ms,
  HEIC thumbnail item ~2 ms, RAW: ARW 1616×1080 in 11 ms, RAF 4416×2944 in 34 ms, NEF full-size in 94 ms,
  ProRAW DNG 4032×3024 in 42 ms. **CR3 exposes no preview** (parse the ISO-BMFF container for the embedded JPEG).
- Progressive JPEG is never HW-decoded (24 MP: 310 ms), but `SubsampleFactor 8` takes a DC-only path: 32 ms.
- Baseline JPEG scale cliffs: `SubsampleFactor 4` is the cheapest reduced decode (24 MP 40 ms, 50–60 MP 90–101 ms);
  `SubsampleFactor 8` and thumbnails ≤ 1024 px are *slower* (they leave the hardware path).
- JPEG > HW limit (101 MP: 726 ms; 22705 px panorama: 1044 ms) falls back to single-threaded software.
- PNG (24 MP 300 ms) and WebP (lossy 320 ms, lossless 380 ms) have no fast path, and the subsample factor saves
  nothing (WebP ignores it; PNG still inflates and unfilters every row). PNG goes to our own decoder (below); WebP stays
  with ImageIO: libwebp itself, built from source with threads and scaling, is only 16–25 % faster on lossy and not at
  all on lossless (one token partition: parsing is serial), not worth 35k lines of parser that the OS patches for us.
  HEIC cost is independent of output size (always full decode, HW).
- Default outputs are not BGRA (full decode = RGBX, thumbnails = XRGB); converting by drawing costs +62 ms per
  24 MP. **Never convert on the CPU**: `PixelLayout` + texture swizzle cover every native layout.
- Metadata (`CopyPropertiesAtIndex`) costs 0.07–0.6 ms (RAW 1.3–2.6 ms); creating a source does not read the file.

libjpeg-turbo (static, `CTurboJPEG`) on real 24–101 MP photos: 24 MP 109 ms, 60 MP 308 ms, 101 MP 641 ms;
DCT scaling saves only 10–20% on high-entropy files (Huffman-bound); 10 threads ≈ 40 images/s.

**Progressive JPEG — early rendition.** The refinement scans (successive approximation, Ah > 0) cost most of a
progressive decode yet only add the low bits of each coefficient: the first-pass scans (23–52 % of the bytes) decode
in a quarter to a seventh of the time. For the image on screen, the screen-tier decode starts a second libjpeg-turbo
decode of the file cut after its last first-pass scan (`pb_jpeg_first_pass_end`; block smoothing off) on another core
and hands it over as an approximate tier (`DecodedImage.isApproximate`) while the exact decode runs, unslowed:

| file (screen tier at 3456 px) | first pixel (DC preview) | early rendition | PSNR vs exact | exact |
|---|---|---|---|---|
| 24 MP 4:2:0 (mozjpeg) | 40 ms | 42 ms | 32.1 dB | 164 ms |
| 24 MP 4:4:4 | 36 ms | 76 ms | 35.5 dB | 300 ms |
| 101 MP 4:4:4 (1/2) | 0.3 ms (160 px EXIF thumb) | 94 ms | 51.9 dB | 682 ms |
| 22705 px panorama (1/4) | 0.2 ms (157 px EXIF thumb) | 146 ms | 49.8 dB | 933 ms |

Rejected (measured, docs/research.md): libjpeg buffered-image mode in the same decode (same early time, exact +10 %),
also skipping only the luma refinements (+1.4–4 dB for 2–4× the time), `TJPARAM_FASTUPSAMPLE`/`FASTDCT` for the
screen tier (24 MP 4:2:0: −18 % but 38 dB at 100 %, which is that tier), decoding independent scan chains in
parallel (the luma chain is ≥ 55 % of the work: ≤ 1.4×, needs libjpeg internals).

**PNG — own decoder** (`Sources/CPeekabooDecode/png.c`): truecolour and palette images, 8 and 16 bits, not
interlaced. The system zlib (as fast as libdeflate here: 127 vs 115 ms for 24 MP, Wuffs 152 ms) inflates on a second
thread into a ring of rows while the calling thread unfilters (branchless scalar Paeth: 62 ms for 24 MP; libpng-style
NEON 89 ms, branchy 151 ms) and writes RGBA, box-filtered /2–/8 for reduced tiers (premultiplied when there is alpha).
24 MP: 153–164 ms at every tier vs ImageIO 277–317 ms (12 MP: 60–66 vs 117–133 ms), with ImageIO's sample values
(tests compare every colour type, depth, filter type and tRNS form; the corpus files are identical) and ImageIO's colour
space. Grayscale (ImageIO's gray colour space and converting draw), Adam7, APNG and malformed files go to ImageIO.

| Source | `.preview` (≤ 512 px) | `.screen` | `.full` |
|---|---|---|---|
| JPEG baseline ≤ HW limit | embedded EXIF/MPF thumb if present (0.2–1 ms); else `Subsample 4` (24 MP 40 ms) — never 8 | `Subsample 2` when W/2 ≥ screen (24 MP 44.6 ms), else full | HW: IOSurface path or lazy decode drawn into own buffer (49.8 ms @ 24 MP) |
| JPEG progressive | `Subsample 8` (DC-only, 32 ms @ 24 MP, 88 ms @ 101 MP) | libjpeg-turbo, DCT scale covering the screen (24 MP: full size, 300 ms); on screen the first-pass rendition first (76 ms) | libjpeg-turbo (290 ms @ 24 MP); when zoomed, the same early rendition |
| JPEG baseline > 102 MP | embedded thumb, else `Subsample 4` | libjpeg-turbo, DCT scale covering the screen | libjpeg-turbo (tiles above 16384 px) |
| HEIC / HEIF / AVIF | embedded thumbnail item (~2 ms); else thumbnail 1024 (70–76 ms @ 50 MP) | thumbnail at the screen long side (62–73 ms @ 50 MP) | ImageIO full via IOSurface (94–110 ms; 195–227 ms if copied out) |
| Camera RAW | embedded preview, thumbnail without `Always` (ARW 15, RAF 19, NEF 43 ms); CR3 via own BMFF parse | embedded preview at screen size if it covers the screen (RAF 70, NEF 93 ms), else RAW decode in the background | RAW decode (ProRAW 133 … ARW 61 MP 886 ms), only on zoom |
| PNG (RGB, RGBA, palette; not interlaced) | own decoder, box filter /8 (24 MP 164 ms) | own decoder, box filter covering the screen (24 MP 154 ms) | own decoder (16-bit stays 16-bit; 24 MP 153 ms) |
| WebP / TIFF / GIF / JXL / PSD / EXR, other PNG | thumbnail ≤ 512 (TIFF 23, AVIF 48, WebP 350 ms) | IOSurface SPI /n (lazy draw as fallback) | IOSurface SPI (lazy draw as fallback) |

HDR (gain-map HEIC/JPEG): `kCGImageSourceDecodeRequest = DecodeToHDR` (10-bit PQ / half-float) when the screen
reports EDR headroom > 1, displayed through the EDR path of the renderer. SDR otherwise.

## 3. Pipeline — predictive prefetch & tiered cache ("P4")

Validated with a discrete-event simulator (6 navigation traces × 4 cost profiles): prefetch hit 94% (the rest are
random jumps), stale frames 0–1% (87% without prefetch, 14% with fixed ahead-2), first pixel 4–11 ms, cold
time-to-sharp equal to no-prefetch.

- **Navigation model**: cursor, direction, EMA of inter-navigation interval (weight 0.5, clamp 2 s; jumps reset to 1 s),
  `I_eff = max(EMA, now − lastNav)`, A/B toggle detection.
- **ETA** of image *j*: ahead `dist·I_eff`; behind `dist·max(I_eff, 300 ms) + 600 ms`; A/B partner `I_eff` (pinned).
- **Windows**: `.screen` ahead `clamp(2 + ⌈250/I_eff⌉, 2, 12)`, behind 2; `.preview` ahead `clamp(4 + ⌈1000/I_eff⌉, 4, 48)`, behind 4.
  Earliest deadline first; a preview runs just before the screen tier of the same image.
- **Skimming** (`I_eff < 120 ms`): show previews only; the screen tier of the visible image waits for a dwell of
  `clamp(1.5·EMA, 40, 120) ms`. Skip a screen-tier prefetch that cannot finish before the user passes the image.
- **Foreground gate**: while the visible image's decode is queued or running, no new prefetch starts.
- **Lanes**: 6 decode lanes (one reserved for the visible image), routed by decode path (HW JPEG engine: ≤ 2 in flight;
  CPU/libjpeg-turbo; ImageIO other). 4 background lanes (QoS utility → E-cores) for the folder-wide preview sweep,
  paused while skimming. Generation counters cancel queued work instantly; running decodes cannot be aborted.
- **Retention by ETA, not LRU**. Budgets for 48 GB: screen tier 2 GB (keep ETA ≤ 5 s or ±3), preview 256 MB
  (±64), full 1 GB (current + A/B partner). Memory pressure: `.warning` drops far tiers and halves budgets for 60 s;
  `.critical` keeps only the current image and nearby previews. `PixelBufferPool` recycles buffers.
- **Persistent cache**: none of our own (disk is scarce). The QuickLook thumbnail cache (`QLThumbnailGenerator`)
  answers in ~1.2 ms for previously seen files across launches: use it for the preview sweep and race it against the
  own preview decode. Re-evaluated for the slow formats: with PNG at ~150 ms and the progressive early rendition at
  40–150 ms, a disk cache of screen renditions (~25 MB each) would only shorten revisits, never a first view.
- **Early renditions**: a screen or full decode may hand over an approximate version of its tier (progressive JPEG
  first passes) through a `PartialSink`; the scheduler asks whether it is still wanted (the current image's screen
  tier until it is sharp, its full tier once requested), the pipeline shows it and never caches it, and the exact tier
  of the same decode replaces it. Prefetch decodes never make one.
- **Folder**: `getattrlistbulk` (10k entries with metadata in 8 ms) and a precomputed natural-sort key (7 ms for
  10k names; `localizedStandardCompare` 30 ms). Watch the directory with a `DispatchSource` (0.2–0.6 ms latency).
- `F_RDADVISE` read-ahead when a file enters a prefetch window.

## 4. Renderer — PPR (Peekaboo Progressive Resampler)

Every stage draws in one image coordinate system (full-resolution, oriented pixels), so better pixels never shift
the picture. Quality matches a float64 direct Lanczos-3 resample at 48–74 dB PSNR (SSIM ≥ 0.9996); naive bilinear
viewers score 21–26 dB and alias 10–25× more.

- **Stage 0** (any preview): 4-fetch cubic B-spline upscale — soft, never blocky or ringing (0.62 ms).
- **Stage 1** (screen tier): treated as pyramid level *k* of the full image.
- **Stage 2** (full): level 0 as `rgba8Unorm_srgb` (free linearisation), levels ≥ 1 in `rgba16Float` linear light built by
  separable 2× decimation with a 12-tap Lanczos-3 (6.4 ms for 24 MP, split into ≤ 2 ms chunks). Do not use
  `generateMipmaps` (box filter, misaligned on odd sizes).
- **Per frame** (reduction f): level `L = ⌊log2 f⌋`, residual `r = f/2^L ∈ [1,2)` resampled by Lanczos-3 stretched by *r*
  (≤ 13 taps/axis, separable, per-row/column weight tables) → **constant cost ≤ 2.7–3.1 ms at 3456×2234**.
  Shrinking in linear light with anti-ringing 0.5; enlarging in sigmoidal light (centre 0.75, slope 6.5) with
  anti-ringing 0.6; exactly 100 % with integer offset = exact copy; ≥ 400 % sharp-bilinear (+ pixel grid ≥ 800 %).
- **Interaction**: during pinch/zoom animation draw trilinear over the HQ pyramid (0.3–1.2 ms); **90 ms after the
  gesture settles re-rasterise once** with the HQ kernel into a canvas; panning at fixed zoom reuses the canvas.
  Neighbours get pre-rendered fit canvases, so next/prev is a ~0.4 ms present.
- **Colour**: working space linear Display P3; source → working conversion on the GPU (3×3 matrix + transfer function),
  never on the CPU. SDR: `bgra8Unorm` drawable tagged Display P3, sRGB-curve encode + TPDF ±1 LSB dither in the present
  pass. HDR/EDR: `rgba16Float` + `extendedLinearDisplayP3`, macOS 26 `preferredDynamicRange`.
- **Tiling** above 16384 px (Apple9 limit, verified): level-0 tiles with an 8 px apron, visible tiles first.
- **Pacing**: event-driven immediate render for discrete actions; a `CADisplayLink` only while animating;
  one drawable per refresh.
- **Present latency**: measured present → glass on the built-in 120 Hz panel (random key timing): 13.6 ms median with
  `displaySyncEnabled = true`, 12.5 ms with 2 drawables, **5.9 ms with `displaySyncEnabled = false`**, 23.3 ms with
  `presentsWithTransaction`. Discrete updates (navigation, single zoom steps, refinements) present with display sync
  off; continuous motion (pinch, momentum, held pan keys) turns it back on so frames never tear.

## 5. App & UX

- One chrome-less window (transparent title bar, black background). Opening one file browses its folder in Finder
  order; several files browse that set; a folder browses its images. Folder listing happens after the first pixel.
- Keys: one `NSEvent` local monitor; chords match the **physical key** through the ASCII-capable layout, so
  bindings work under the Korean input method. Keymap contexts `normal` / `zoomed`, chord sequences ("g g").
- Navigation never shows a blank frame or spinner: the title/HUD switches to the target in the same frame; the
  previous image stays until the target's first tier is ready; swaps are instant and geometry-identical.
- Config: TOML at `~/.config/peekaboo/config.toml` (`$XDG_CONFIG_HOME`, `$PEEKABOO_CONFIG`), hot reload, errors
  as a toast; actions `namespace.verb[:arg]` (see `Sources/PeekabooCore/Model/Action.swift`), move/copy and
  open-with slots.
- File actions: trash with ⌘Z undo, move/copy to slots with undo, reveal, copy path/name/image, open with;
  stars/labels/flags as Finder tags.
- HUD as `CATextLayer`s above the Metal layer (no blur views), updated only on state changes; toasts.
- Full screen: instant borderless (notch-aware) by default; native as an option.

## 6. Performance budget

| Path | Target |
|---|---|
| Prefetch hit: key → frame submitted (CPU encode + GPU) | ≤ 1 ms (measured encode 0.05–0.09 ms, GPU 0.3–0.5 ms) |
| Prefetch hit: key → on glass | ≤ 1 refresh: present → glass 5.9 ms median with display sync off (13.6 ms with it on) |
| Miss, embedded preview available: first pixel | ≤ 12 ms after the key |
| Cold launch (Finder) → first pixel | ≤ 250 ms (measured skeleton-equivalent 258 ms; remove the ~70 ms main-thread stall before the first present) |
| Resident re-open → first pixel | ≤ 80 ms |
| GPU per frame at 3456×2234 | ≤ 3.5 ms |
| Main-thread work per navigation | ≤ 1 ms |

Measure with `PEEKABOO_TRACE=1` (stderr timeline) and `peekaboo-bench`.
