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
| Oldest macOS | **14 (Sonoma)**, Apple Silicon. Newer APIs behind `#available` with the macOS 26 path unchanged (ISO gain-map probe 15+, `MTLCompileOptions.mathMode` 15+, EDR drawable tagging 26+); ImageIO's private surface SPI and its `kCGImageSurfaceFormatRequest` are `dlsym` lookups, and every route falls back to the public path without them; the runtime-compiled shaders (renderer, YCbCr converter) stay MSL 3.1; libjpeg-turbo built from its pinned release for 14.0 at `-O3` (`mise run deps`), whose own headers (TurboJPEG, and the libjpeg API of the early rendition) come from the same build; binaries record SDK 26.0 | Every strong import passes the SDK's macOS 14 availability annotations. On macOS 26 decode, pipeline, render and process-launch times are unchanged (same pixels), except libjpeg-turbo: Homebrew's bottle is `-Os`, upstream's Release `-O3` decodes progressive JPEGs 4–26 % faster (101 MP `.full` 795 → 587 ms; an `-Os` build of the same source measures as before). |

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
- HEIF orientation lives in `irot` / `imir`: ImageIO writes both those and the EXIF tag, reports the orientation from the
  transform properties (a libheif-style file with `irot` and EXIF 1 reports the `irot` value) and decodes stored pixels;
  embedded thumbnails come back rotated. All 8 orientations, with and without thumbnail items, match ImageIO's oriented
  thumbnail in every tier (tested end to end).
- The surface SPI's BGRA for HEIF / AVIF is ImageIO converting the decoder's YCbCr on the CPU. Its private
  `kCGImageSurfaceFormatRequest = '420f'` hands over the native bi-planar YCbCr instead (12 MP HEIC 10 vs 32 ms, 50 MP 22
  vs 83 ms, best of 5); 10-bit sources come out bi-planar anyway (`'xf20'`, 16-bit containers: 24 MP 7.5 ms; asking them
  for `'420f'` makes ImageIO convert on the CPU, 39 ms). Reduced decodes (`SubsampleFactor`) are CPU work too (12 MP /4
  30 ms; 10-bit 24 MP /2…/8 36–75 ms): decode at /1 and reduce on the GPU. Before, 10-bit images took the public path,
  which drew them into 8-bit BGRA on the CPU: 24 MP 115 ms (Display P3) to 212 ms (PQ).
- Those bi-planar surfaces are all tagged `IOSurfaceYCbCrMatrix = ITU_R_601_4`, but their pixels keep the file's matrix
  (`'420f'` requests convert only the range): the matrix comes from the primary item's `colr` `nclx` box, which ImageIO
  follows over the codec's own colour description (`HEIFColour`; BT.601 when absent). Converted as BT.601 against
  ImageIO's own RGB: a 10-bit BT.709 AVIF 41 dB (62 dB as BT.709), a BT.2020 one 40 dB (65 dB); a BT.709-labelled saturated
  green 40 levels off. Matrices the converter lacks (identity, YCgCo, ICtCp, …) keep ImageIO's conversion.
- PQ / HLG images (camera HIF, HDR AVIF) decoded by default keep PQ code values in a BT.2100 space: shown as SDR they were
  ~6× too dark. The SPI honours `kCGImageSourceDecodeToSDR` (ImageIO's tone-mapped SDR rendition, `'420f'`, Display P3,
  24 MP 15 ms). That rendition's YCbCr is BT.2020 whatever the source's matrix and primaries (as BT.601 a saturated HLG
  green came out 21 levels too bright).
- The first HEVC decode of a process waits for the hardware decoder: 62 ms wall (12 ms CPU) for a 16 px HEIC, then ~2 ms;
  it stays warm (45 s idle measured) and costs 3.4 MB.
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

(Measured with Homebrew's `-Os` libjpeg-turbo. With the `-O3` build from `mise run deps` the exact tiers of these files
decode 6–25 % faster (101 MP 717 → 539 ms) and the early renditions keep their PSNR to 0.01 dB; they land as early or
up to 5 ms sooner, except the 101 MP one, 5 ms later beside its exact decode (92 → 98 ms; alone 94 → 96 ms: `-O3` code
for its first-pass path, an `-Os` build of the same source takes 93 ms).)

Rejected (measured, docs/research.md): libjpeg buffered-image mode in the same decode (same early time, exact +10 %),
also skipping only the luma refinements (+1.4–4 dB for 2–4× the time), `TJPARAM_FASTUPSAMPLE`/`FASTDCT` for the
screen tier (24 MP 4:2:0: −18 % but 38 dB at 100 %, which is that tier), decoding independent scan chains in
parallel (the luma chain is ≥ 55 % of the work: ≤ 1.4×, needs libjpeg internals).

**PNG — own decoder** (`Sources/CPeekabooDecode/png.c`): truecolour and palette images, 8 and 16 bits, not
interlaced. The system zlib (as fast as libdeflate here: 127 vs 115 ms for 24 MP, Wuffs 152 ms) inflates on a second
thread into a ring of rows while the calling thread unfilters (branchless scalar Paeth: 62 ms for 24 MP; libpng-style
NEON 89 ms, branchy 151 ms) and writes RGBA, box-filtered /2–/8 for reduced tiers (premultiplied when there is alpha).
24 MP: 143–154 ms at every tier vs ImageIO 303–334 ms (12 MP: 63 vs 118–155 ms), with ImageIO's sample values
(tests compare every colour type, depth, filter type and tRNS form; the corpus files are identical) and ImageIO's colour
space. The target builds at `-O3`: SwiftPM's release default `-Os` leaves the unfilter's per-byte loops rolled
(24 MP 158–167 ms). Grayscale (ImageIO's gray colour space and converting draw), Adam7, APNG (its animation is
ImageIO's, below) and malformed files go to ImageIO, and so do values the format leaves undefined, where ImageIO has its
own answer: an 8-bit colour key above 255, palette indices past the palette. 16-bit PQ / HLG PNGs (a BT.2100 profile)
take ImageIO's tone-mapped SDR rendition like PQ / HLG HEIF: the decoder would hand over their code values.

| Source | `.preview` (≤ 512 px) | `.screen` | `.full` |
|---|---|---|---|
| JPEG baseline ≤ HW limit | embedded EXIF/MPF thumb if present (0.2–1 ms); else `Subsample 4` (24 MP 40 ms) — never 8 | `Subsample 2` when W/2 ≥ screen (24 MP 44.6 ms), else full | HW: IOSurface path or lazy decode drawn into own buffer (49.8 ms @ 24 MP) |
| JPEG progressive | `Subsample 8` (DC-only, 32 ms @ 24 MP, 88 ms @ 101 MP) | libjpeg-turbo, DCT scale covering the screen (24 MP: full size, 300 ms); on screen the first-pass rendition first (76 ms) | libjpeg-turbo (290 ms @ 24 MP); when zoomed, the same early rendition |
| JPEG baseline > 102 MP | embedded thumb, else `Subsample 4` | libjpeg-turbo, DCT scale covering the screen | libjpeg-turbo (tiles above 16384 px) |
| HEIC / HEIF / AVIF | embedded thumbnail item (~2 ms); else native YCbCr at /1 reduced on the GPU (/≤8) | native YCbCr (SPI `'420f'`; 10-bit `'xf20'`; PQ / HLG: the SDR rendition) at /1 → one Metal pass, reduced to cover the screen → `bgra8` / `bgr10a2` | same, unreduced |
| Camera RAW | embedded preview, thumbnail without `Always` (ARW 15, RAF 19, NEF 43 ms); CR3 via own BMFF parse | embedded preview at screen size if it covers the screen (RAF 70, NEF 93 ms), else RAW decode in the background | RAW decode (ProRAW 133 … ARW 61 MP 886 ms), only on zoom |
| PNG (RGB, RGBA, palette; not interlaced) | own decoder, box filter /8 (24 MP 143 ms) | own decoder, box filter covering the screen (24 MP 143 ms) | own decoder (16-bit stays 16-bit; 24 MP 145–154 ms) |
| WebP / TIFF / GIF / JXL / PSD / EXR, other PNG (grayscale, Adam7, APNG, PQ / HLG) | thumbnail ≤ 512 (TIFF 23, AVIF 48, WebP 350 ms) | IOSurface SPI /n (lazy draw as fallback) | IOSurface SPI (lazy draw as fallback) |

HDR (gain-map HEIC/JPEG, PQ / HLG HEIF and PNG) with `[decode] hdr` on (Settings › Performance; `PEEKABOO_HDR=1` forces it;
off by default, 10–15× the SDR decode): `kCGImageSourceDecodeRequest = DecodeToHDR` (half-float, extended-linear Display P3),
displayed through the EDR path of the renderer. SDR otherwise (PQ / HLG: ImageIO's SDR rendition). Switching it decodes those
images again (`ImagePipeline.redecode(where:)`, `ImageInfo.hasHDRRendition`); the one on screen swaps in place.

`main()` decodes a 16 px HEIC (`HEVCWarmUp`) while AppKit starts, at utility QoS, queued by the userInitiated thread
that builds `FolderScanner.supportedExtensions` once that is done (ImageIO's one-time setup has run at userInitiated by
then, so no decode waits for it on the slower thread). A HEIC opened at launch decodes warm: process start → first
committed frame of a 12 MP HEIC 159–163 → 109–110 ms (50 MP 184 → 133 ms), JPEG launches unchanged (24 MP whose first
tier is its EXIF thumbnail 125.2 vs 126.8 ms, 24 MP 4:2:0 106.9 vs 105.4 ms); medians of 8 interleaved runs, commit
times. The same block at userInitiated: 113–122 ms (50 MP 144 ms). Started only after the folder listing when the
folder holds HEIF, it keeps none of the gain (159 ms): the first decode already waits for the hardware decoder then.

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
  `clamp(1.5·EMA, 40, 120) ms`. Skip a screen-tier prefetch that cannot finish before the user passes the image, and
  one of an image already passed unless it is short (≤ 150 ms with every lane busy: hardware JPEG and HEIC decodes):
  its reversal ETA makes any decode look feasible, but a progressive JPEG or PNG decode started for every image passed
  fills the lanes and still runs beside the decode of the image the user stops on.
- **Cost model**: EWMA of measured decode times per (format family by extension, megapixel bucket, tier),
  normalised by concurrency, seeded from §2. Baseline and progressive JPEGs share a family: told apart, the exact
  progressive estimate (×1.6 for all lanes busy in the feasibility test) stopped prefetches that do land in time in
  mixed folders (docs/research.md, "Skimming past progressive JPEGs").
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
  of the same decode replaces it. Prefetch decodes never make one. A rendition of another version of the file than
  the listed one is dropped; the file the app opens is decoded before its folder is listed, so the worker's `stat`
  before the decode is what is compared.
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
  pass. HDR/EDR: `rgba16Float` + `extendedLinearDisplayP3`, macOS 26 `preferredDynamicRange` + `contentsHeadroom`
  (macOS 14–15: `wantsExtendedDynamicRangeContent`).
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
  open-with slots. The Settings window (⌘,, built on first use) writes the same file through minimal text edits
  (`TOMLEditor`: comments and layout kept, each edit verified by parsing it back); the file stays the single source
  of truth and its reload is what applies a change. Decoder and trace switches are process-wide flags set once per
  config apply, never looked up per decode.
- File actions: trash with ⌘Z undo, move/copy to slots with undo, reveal, copy path/name/image, open with;
  stars/labels/flags as Finder tags.
- Picks (no database: the Finder tag `Pick` on the file): the folder's tags are read once per listing on a utility
  queue after the first frame (one `getxattr` per file, four lanes: ~40 ms for 5,000 files; a rescan reads only the
  files that are new, changed in size, date or inode, or back after the viewer moved them out) and kept current from
  the flags the app writes. The picks-only view is a browsing set of its own handed to the pipeline (`setFiles`), so
  navigation, prefetch and the HUD work on it unchanged; the full set waits beside it. Entering it finds the picks
  through the pipeline's lookup by name (O(picks), not a hash of every file), and every toggle restarts the
  pipeline's navigation clock, so the new neighbours are prefetched however long the photo was looked at. Replaced
  lists are freed on a utility queue (their last release is 0.65 ms per 5,000 files on the main thread). Copying
  every pick reads the tags again, then copies on a utility queue through the same never-overwrite placement as
  `file.copy`.
- HUD as `CATextLayer`s above the Metal layer (no blur views), updated only on state changes; toasts.
- Full screen: instant borderless (notch-aware) by default; native as an option.
- Updates (no Sparkle): `latest.json` of the latest GitHub release, read 11 s after launch (the updater is set up 1 s
  after launch, behind the first frame and its sharp tier), every 6 h and when the network returns (≥ 1 h apart), on a
  utility queue with an ephemeral `URLSession`. A newer zip is verified (SHA-256,
  code signature with Peekaboo's identifier and the running app's Developer ID team), staged on the app's volume
  (`~/Library/Caches/com.thilllon.Peekaboo/Updates`, or one fixed folder among the system's temporary items of the
  app's volume, so nothing piles up per run) and swapped in with one `renamex_np(RENAME_SWAP)` by the app's own
  executable (`--install-update`) once the app has quit. An install that fails there is recorded
  (`InstallFailure.plist` in the same cache folder): the next run says so in one toast (a file read on the utility
  queue 1 s after launch), and automatic checks then offer that version as a download instead of fetching it again
  to fail on every quit; "Check for Updates…" or a newer release tries again.
  Nothing of it runs before the first frame; launch → first frame is unchanged. The banner (an AppKit text field and
  buttons: 5–20 ms of main-thread work to build) waits for 1.5 s without input unless the user asked for it, so it
  never lands between two images or in a gesture.
- Folder access: macOS asks once for each of Desktop, Documents and Downloads, the first time the app reads it (a
  prompt that blocks the reading thread until it is answered). At first launch (`PeekabooFolderAccessRequested` in
  the app's defaults) `FolderAccessRequest` lists the three one after another on a utility queue, a second after
  launch next to the updater, so the prompts come right after installation instead of in the middle of browsing:
  nothing runs before the first frame, and the main thread spends one `UserDefaults` read on it (plus a queue hop at
  first launch). Only when LaunchServices started the app (launchd is its parent: Finder, the Dock, `open`, the
  updater's relaunch), because macOS charges what a process started from a shell reads to the terminal; never
  headless, in the self-test, with `PEEKABOO_ACTIONS` or outside an app bundle. A listing that is refused shows the
  opened image on its own with a 6 s toast that says how to allow it, again at either end of the set instead of
  "First image" / "Last image" (an opened folder says it as its message). EPERM (privacy protection) names the Files &
  Folders switch of the place the folder is in (Desktop, Documents or Downloads Folder; Removable or Network Volumes,
  from one `statfs` off the main thread), else Full Disk Access, the only setting for Mail, Messages or Time Machine
  backups; EACCES (the folder's own permissions) points to Finder › Get Info › Sharing & Permissions. While the
  folder is refused, the window becoming key lists it again (back from System Settings), off the main thread.
- One Peekaboo.app (`AppInstall`, `Installation`): a copy that runs from a disk image (a read-only volume under
  `/Volumes`) or from App Translocation's read-only path cannot update itself, and each downloaded version used to
  leave one more Peekaboo. main.swift decides first, on `argv[0]`: two C string comparisons, 0.1–0.4 µs on the first
  call (Foundation's `String.contains` on `Bundle.main.bundlePath` took 30–55 µs), plus one `statfs` for a path under
  `/Volumes` (2.5–6.5 µs, so a copy kept on a writable drive stays where it is). Such a copy skips the GPU, ImageIO and
  HEVC warm-ups and builds no window: it keeps the launch's files (command line, open-documents events) and, once
  launching has finished, a user-initiated queue installs it at `/Applications/Peekaboo.app`, or at
  `~/Applications/Peekaboo.app` when `/Applications` is not writable or the bundle there is not one the user may
  replace (another app of that name, another account's copy). An older or the same build there is replaced: copied
  into a new folder on the target's volume, its quarantine flag removed (Gatekeeper would ask again, or translocate
  it), verified like an update (identifier, version and build, the running app's signing requirement) and swapped in
  with one `renamex_np(RENAME_SWAP)`; 21–128 ms from a quarantined UDZO image for the 4.4 MB release bundle, 14–53 ms
  of it the signature check. The target is checked again right before the swap, and the bundle the swap moved out
  must be the one checked (not a newer build another installer put there meanwhile), or the swap is undone. A newer
  build in either Applications folder (or the same build in the other one) is kept and gets the files; another app of
  that name is never touched. Peekaboo stays open after its last window closes, so an older copy usually runs at the
  target: it is quit (`NSRunningApplication.terminate`), and the install waits until no process runs that bundle
  (`proc_pidpath` of every process, 1.6–2.3 ms a scan, so the update installer the quitting copy may start counts too)
  for at most 10 s, then reads the target again; a copy that does not quit leaves Peekaboo here with a toast. A copy
  of the same or a newer build that runs gets the files as they are. Otherwise the copy opens the files in the
  installed one, a new instance (`NSWorkspace.OpenConfiguration.createsNewApplicationInstance`) started with
  `--eject-disk-images=<pid>` (it never installs again; `--kept-newer` when nothing was installed), sends the files
  opened meanwhile after them, and quits. A second after launch, on a utility queue, the installed copy waits for that
  process to exit, quits the older Peekaboo copies that run from a disk image, and ejects every read-only local volume
  under `/Volumes` that this user mounted, is a disk image (DiskArbitration's device model, 0.24–0.41 ms, asked before
  anything on the volume is read: never an NTFS drive or a locked card, whose first read may have macOS ask for the
  Removable Volumes permission) with a Peekaboo.app of this identifier at its top, and holds no file it shows
  (`NSWorkspace.unmountAndEjectDevice`: 86 ms; an image still in use fails after ~1 s with `fBsyErr` and is tried
  once more 2 s later). Who mounted a volume comes with the list: one copy of the mount table (`getmntinfo_r_np`,
  waiting for no file system: 2.1–2.3 µs, where `FileManager.mountedVolumeURLs` took 6.3–6.6 µs and 2.5–19 ms on its
  first call) gives each volume's flags and `f_owner`, the uid that mounted it (0 for the system's; `st_uid` on a disk
  image, mounted with `MNT_IGNORE_OWNERSHIP`, shows whoever looks). Another account's images are neither asked about
  nor read, and the copies quit are this session's (`NSRunningApplication`): with two accounts logged in at once, the
  copy installed in one had ejected an image the other opened and tried to unmount the one the other's Peekaboo ran
  from (#90). One toast says which version is installed where and names the images left. If the install
  or the start fails, the copy launches as usual, with a toast that gives the reason on its own line. Tests
  (headless), `--selftest` and `PEEKABOO_ACTIONS` never install or eject.
- A newer Peekaboo opened while one runs (`DiskImageUpdate`): the downloaded copy is quarantined and was never opened,
  so Finder hands its launch to Gatekeeper's first-launch path (CoreServicesUIAgent), which brings the running copy to
  the front (`SETFRONT`) instead of starting the new one: the copy above never runs. So the running copy acts. A second
  after launch, next to the updater, it is created (0.15–0.25 ms of main-thread time once, about what the updater's own
  setup costs right before it; 11–17 µs warm); its two workspace observers are registered on its utility queue, because
  on the main thread they cost 0.9–1.8 ms (0.21–0.32 ms CPU, the rest waiting on the system). On every mount, and once
  for the volumes mounted already 2 s later, the queue looks at this user's disk images under `/Volumes` not seen yet
  (read-only local volumes whose device DiskArbitration calls a disk image, then one `Info.plist` each: a locked card, a
  read-only drive or a network share is never read, so macOS never asks for the Removable or Network Volumes permission
  on Peekaboo's behalf) and stages the newest Peekaboo.app of this identifier above the running build that runs on this
  macOS (`LSMinimumSystemVersion`: installed, a release for a newer one would not start, and the app it replaced would
  be gone) like a download: `<staging root>/<version token>/Peekaboo.app`, the updater's folder, copied, verified
  against the running app's Developer ID requirement, and only then cleared of its quarantine flag (`AppInstall.stage`:
  21.5–22.1 ms median for the 4.6 MB 20261126-6c7b06 bundle from the SSD, 2.6–3.1 ms of it the copy, the rest the
  signature check; a copy staged there before that still verifies is kept, 16–19 ms). A Peekaboo.app that is a symbolic
  link is never staged: staging would clear the quarantine flags of whatever it points to, and the install would put the
  link in the app's place (`UpdateInstaller.verify` refuses a link for every update, the helper's included). An ad-hoc
  signed app stages nothing: its requirement names no team, and a disk image comes without the manifest's SHA-256. A
  version whose install failed at this bundle (`InstallFailure.plist`) is not staged again, so a failing install cannot
  relaunch the app over and over; the first scan deletes the staged copies that are not above the running build. The
  staged copy stays when the volume is unmounted, the updater's clean-ups leave it (`keepStaged`), and a newer one
  replaces it. An activation costs one stored flag when nothing is staged (0.9 ns in a release build,
  `applicationDidBecomeActive` 1.0 ns with or without the component; a `Copy?` holds a URL, whose layout Foundation only
  knows at run time, and testing it for nil took 42 ns; the stack space `asyncAfter` needs, set up before the check,
  cost 7 ns until that part moved out of line). With a copy staged, `applicationDidBecomeActive` or
  `applicationShouldHandleReopen` hands over 0.25 s later, never sooner (not even when a copy is staged within that
  time), so that a photo opened from Finder with the activation is the one reopened: the staged copy and the bundle in
  its place are read again (76–88 µs, 0.14–0.22 ms the first time), then the update installer is started with
  `--relaunch`, the photo shown and `--eject-disk-images`, and the app quits; the installer swaps the copy in and
  relaunches the app with `open -a <app> [photo] --args --eject-disk-images=<installer pid>` (the eject option only
  after a successful install; the photo only while it exists, since `open` refuses a missing file without starting the
  app, and a failed `open` is tried once more without it), so the relaunched copy ejects the Peekaboo disk images and
  says which version is installed where. The updater's ready download installs instead when it is as new or newer
  (`restartToUpdate`, ejecting too); there is never a second installer, and quitting with a copy staged installs it
  without a relaunch unless the updater installs a build as new or newer then. The hand-over waits for a mount still
  being looked at (counted on the main thread as AppKit posts it, so the activation the double-click on its copy causes
  is never lost to a slow scan), a copy being staged, a background file operation (copy, move to another volume, slow
  undo or redo, copying the picks; 2.5 s more so its result can be read) and a menu or modal panel (it runs in the
  default run-loop mode only), and needs the app still in front; one attempt per version and run, and an installer that
  cannot start leaves the app running with a toast. Never in tests (headless), `--selftest`, `PEEKABOO_ACTIONS`, an
  installing copy, an app that cannot replace itself, or once the app quits. Releases up to 20261126-6c7b06 cannot do
  this: quit them before opening a newer one.

### Animation

GIF, APNG, animated WebP, HEICS and AVIS (`ImageInfo.isAnimated`: more than one frame in one of those types; HEIC
collections such as dynamic wallpapers, TIFF pages and ICO sizes stay stills). The pipeline decodes frame 0 like any
still, so an animation shows as fast as a photo and its neighbours are prefetched as usual; once it is on screen (and
the user is not skimming past it), an `AnimationPlayer` takes over. Stills never create one. Frames are exact tiers:
an early rendition (`isApproximate`) on screen holds autoplay back until its exact tier shows, a frame shown clears it,
and an early rendition never replaces a frame.

- **Frames**: ImageIO composites them (disposal none / background / previous, blending source / over), checked against
  hand-made GIF, APNG and WebP files; animated WebP through libwebp instead (below). One quirk: ImageIO declares some composited GIF frames opaque although an earlier
  "restore to background" left them transparent; their fourth byte is the canvas alpha and is honoured.
- **Timing**: per-frame unclamped delays (APNG needs the frame's own properties; its container holds ImageIO's clamp at
  50 ms), browser clamping (≤ 10 ms plays as 100 ms), ImageIO's loop counts (plays; 0 = forever; a GIF without the
  NETSCAPE extension plays once), the last frame stays after the last play.
- **Decoding**: one serial queue, in order, into a page-granular pool of the player's own. When all frames fit
  `min(screen budget / 8, 256 MB)` each is decoded once and kept (later loops decode nothing); otherwise a window of up to
  8 frames ahead. Corpus: 400×400 GIF 0.8 ms / WebP 0.5 ms per frame, 44 frames = 27.5 MB kept. Frames are canvas-sized,
  so an animation one frame of which does not fit that budget stays a still (`AnimationPlayer.fits`: an 11 KB WebP
  declaring a 12000×12000 canvas kept 1.1 GB of frames, a 2.3 GB footprint, 0.5 s per frame).
- **Animated WebP through libwebp**: ImageIO re-composites a WebP from its first frame for every frame it returns (with
  any caching option, and in its own `CGAnimateImageAtURLWithBlock` too), so frame *i* cost O(*i*): the corpus WebP
  grew from 3 to 31 ms per frame over its 44 frames, a 1920×1080 × 50-frame one from 34 to 309 ms and played 41 of 100
  frames late. `WebPFrames` decodes with libwebp's `WebPAnimDecoder` (libwebp 1.6.0, built by `mise run deps`), which
  keeps the canvas and adds only the next frame; ImageIO still reads the timing. `peekaboo-bench anim`, M4 Pro, ImageIO
  → libwebp: 400×400 × 44 p50 11.0 → 0.53 ms, p95 21.9 → 0.80 ms per frame; 1920×1080 × 50 p50 157 → 6.4 ms, p95 298 →
  11.9 ms, late frames 41 → 0 of 100, on-screen duration error +63 → 0 ms. The frames match ImageIO's within codec
  rounding (max 8 levels, mean < 0.5; `AnimationTests`). A file libwebp reads differently (frame count, canvas) stays
  with ImageIO. GIF and APNG keep the previous canvas (flat ~1 ms per 480×270 frame over 600 frames), but a backward
  step outside the kept frames re-composites from the start (600 frames: 0.46 s); so does a WebP's.
- **Pacing**: the view's display link, running only around frame deadlines (paused between them, woken by a timer 1.5
  refreshes early). A frame due within half a refresh is shown at that refresh; the timeline does not drift and is
  re-anchored when a frame is more than one frame late (no catch-up burst). Headless at 120 Hz over 3 loops of the corpus
  GIF / WebP (90 ms frames): on-screen duration − declared mean +0.03 ms, |error| p95 6.7 ms (the 8.3 ms refresh grid),
  no late frames. Playback pauses while the window is hidden, occluded or minimised and stops on navigation.
- **Rendering**: frames bypass the prepared-neighbour cache. While playing no pyramid is built: views that would read one
  (frame shown below half size) draw bilinear from level 0, all others take their usual path (level-0 HQ canvas, 1:1,
  sharp bilinear). GPU per frame at 3456×2234 / 1440×900 (M4 Pro): pyramid of a 3840×2160 frame 4.1 ms (9 ms wall),
  level-0 canvas 0.4–1.6 ms, bilinear 0.1–0.7 ms. Paused, stepped or finished: the full PPR path, pyramid included.
- **Keys**: `view.play_pause` (`k`), `view.frame_prev` / `view.frame_next` (`,` / `.`, pause and step, repeat while
  held); the full HUD shows `Frame i/N`.

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
