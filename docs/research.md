# Peekaboo — research summary

Two hours of research and on-device measurement went into the design: eight research tracks plus a benchmark
corpus and harnesses, all run on the target machine (MacBook Pro M4 Pro, 10P+4E, 48 GB, macOS 26.6, XDR 120 Hz
+ external 144 Hz). This file keeps the conclusions and the numbers; `docs/DESIGN.md` turns them into the spec.

Corpus: real photographs (Wikimedia Commons featured/quality images, raw.pixls.us CC0 RAW samples) — JPEG
12–101 MP incl. progressive, 4:4:4, EXIF-rotated and a 22705 px panorama; HEIC 12/50 MP; AVIF, PNG, WebP, TIFF,
JPEG XL, an HDR gain-map JPEG; RAW from Sony (ARW 61 MP), Canon (CR3 45 MP), Nikon (NEF 46 MP), Fujifilm (RAF)
and Apple ProRAW (DNG).

## Why Swift, not Rust

Speed comes from *which decoder runs* and *how the pipeline is scheduled*, not from the language: both compile
through LLVM to the same machine code and call C/Objective-C with zero-cost FFI. Measured:

| Operation | Swift + Apple frameworks | Rust | Verdict |
|---|---|---|---|
| 24 MP baseline JPEG (real 15 MB photo), single image | ImageIO hardware engine 51 ms | zune-jpeg 128 ms, `image` 128 ms, jpeg-decoder 179 ms, libjpeg-turbo 109 ms | Apple HW wins; Swift can also call libjpeg-turbo |
| Many JPEGs in parallel (prefetch) | HW IOSurface path ~20 ms/img on 2 engines + libjpeg-turbo on P-cores | libjpeg-turbo / zune on 8–10 threads | parity — the same C library is available to Swift |
| HEIC (iPhone) | hardware HEVC, 12 MP ≈ 40 ms | libheif + software libde265 (not even buildable here) | Swift only |
| Camera RAW previews / HDR gain maps | ImageIO (embedded previews 11–94 ms; `DecodeToHDR`) | rawler / young 0.x crates | Swift |
| Launch → first frame | AppKit init dominates (~75–110 ms); dyld + Swift runtime ≈ 6 ms | winit + wgpu: ~190–212 ms warm to first present | no language advantage; AppKit cost is shared |
| Menus, Finder "Open With", drag & drop, full screen, display-link pacing | native | winit lacks them → objc2 glue per feature | Swift |

So the app is Swift/AppKit/Metal/ImageIO, with libjpeg-turbo linked statically for the CPU decode lane.

## What makes viewers feel slow (prior art)

- The fastest viewers mostly **avoid decoding**: Photo Mechanic, FastRawViewer, nomacs and JPEGView show the camera's
  embedded JPEG preview first; Quick Look and Photos show cached derivatives.
- **Prefetch policy separates "instant" from "slow"**: XnView MP reads exactly *one* image ahead and has no GPU
  rendering; the good ones are direction-aware, parallel and cancellable (FastRawViewer, PicView 7 ahead / 3 behind).
- **Zoom smoothness comes from the GPU**: CPU viewers re-rasterise after a 50–200 ms debounce (qView, JPEGView, Eye of
  GNOME); GPU viewers (Loupe, oculante, Xee) draw textures through a transform.
- **Low-res first must be geometry-identical** to the final image, otherwise it "jumps" (a common XnView complaint).
- Shipping cache budgets are tiny (5 images / 256 MB); a 48 GB Mac can hold dozens of screen-sized frames.

## Apple ImageIO on this Mac

- Baseline JPEG ≤ ~50 MP is decoded by **two hardware JPEG engines**: 24 MP 51 ms vs 109 ms in software. Beyond
  that (101 MP, 22705 px panorama) it silently falls back to single-threaded software (726 ms / 1044 ms).
- `ShouldCacheImmediately` decodes are **serialised per process**; the private `CGImageSourceCreateIOSurfaceAtIndex`
  returns a BGRA IOSurface (zero-copy into Metal) and runs on both engines in parallel (~20 ms per 24 MP JPEG).
- `CreateThumbnailAtIndex(Always, MaxPixelSize 3456)` is a trap: 131–144 ms for 24 MP (CPU resampling), 3× a full
  hardware decode. Decode full or subsampled and scale on the GPU instead.
- Embedded previews are nearly free: JPEG EXIF thumbnail 0.3–0.5 ms, HEIC thumbnail item ~2 ms, RAW previews
  11 ms (ARW 1616×1080) to 94 ms (NEF full size). CR3 previews are not exposed by ImageIO.
- Progressive JPEG is never hardware-decoded (24 MP: 310 ms) but `SubsampleFactor 8` takes a DC-only path (32 ms).
- PNG (24 MP 268 ms) and WebP (290 ms) have no fast path. HEIC always decodes fully (any output size). Both are now
  measured in detail below ("Slow formats"): PNG has its own decoder, WebP stays with ImageIO.
- Native outputs are RGBX / XRGB / 16-bit, not BGRA: converting by drawing costs +62 ms per 24 MP, so the renderer
  samples every layout directly via texture swizzles.
- Metadata is cheap and lazy: 0.07–0.6 ms per file (RAW 1.3–2.6 ms).

## Display path

- `CALayer.contents = CGImage` costs **58–323 ms of main-thread CPU** per 24 MP image (colour conversion at commit) —
  the class of hitch that makes viewers stutter. A Metal path costs ~1 ms upload + < 3 ms draw.
- Zero-copy upload (`makeTexture` over a shared buffer) takes 0.014 ms vs 7.6 ms for `replace(region:)`.
- Max texture size on the M4 Pro (Apple9) is 16384 px; larger images need tiles.
- Runtime shader compile: 1.1 ms with a warm OS shader cache, 31–97 ms on first compile — hidden behind AppKit init.
- `CVDisplayLink` is deprecated since macOS 15; use `CAMetalDisplayLink` / `NSView.displayLink` only while animating.

## Launch & lifecycle

- Direct exec reaches the first frame in ~130–155 ms; via Finder/`open` ~230–250 ms (LaunchServices adds ~90 ms).
- `NSApplication.shared` 35–48 ms, first window 31–46 ms (borderless 12 ms), main menu 1–2 ms.
- **Staying resident** makes re-opening ~65 ms from the command line (the app's own work ≈ 2 ms).
- The open-documents event arrives 52–60 ms after `willFinishLaunching`: create the window and start Metal before it.

## Predictive prefetch ("P4")

A discrete-event simulator compared policies over 6 navigation traces × 4 cost profiles:

| Policy (24 MP JPEG profile) | First pixel (cold) | Sharp (cold) | Prefetch hit | Stale frames |
|---|---|---|---|---|
| No prefetch | 25 ms | 25 ms | 13 % | 87 % |
| Fixed: 2 ahead | 27 ms | 27 ms | 86 % | 14 % |
| 4 ahead / 2 behind | 31 ms | 31 ms | 94 % | 6 % |
| **P4 predictive** (ETA deadlines, velocity-scaled windows, skimming, foreground gate) | **4 ms** | **25 ms** | **94 %** | **0 %** |

The remaining 6 % are random jumps. Directory listing with `getattrlistbulk`: 10k entries in 8 ms; precomputed
natural-sort keys sort 10k names in 7 ms (`localizedStandardCompare`: 30 ms).

## Rendering ("PPR")

| Method (24 MP photo, vs float64 direct Lanczos-3) | PSNR when zoomed out | Cost per 3456×2234 frame |
|---|---|---|
| Bilinear, no mipmaps (typical viewer) | 21–26 dB, 10–25× more aliasing | ~0.5 ms |
| Metal `generateMipmaps` + trilinear | 24–33 dB | 0.3–1.2 ms |
| **PPR**: linear-light Lanczos-3 pyramid + residual Lanczos-3 (r < 2) | **48–74 dB**, SSIM ≥ 0.9996 | **≤ 2.7–3.1 ms at any zoom** |

Anti-ringing halves halos when shrinking (44.6 → 20.4 sRGB levels) with no extra aliasing; sigmoidal-light
enlargement cuts dark halos from 63 to 5.9 levels while staying the sharpest kernel tested.

## Keyboard & config

Default keymap merges viewer consensus (arrows/Space/Backspace, `f`, `z`, `i`), macOS conventions (⌘⌫ trash, ⌘Z,
⌥⌘C copy path) and Lightroom culling keys (0–5 stars, 6–9 labels, P/X/U, Shift = act and advance). Keys match the
*physical* key through the ASCII-capable layout, so shortcuts keep working while the Korean input method is active.
Config is TOML at `~/.config/peekaboo/config.toml`, hot-reloaded.

## Benchmarks (measured on the target Mac)

Run 2026-11-24, one suite at a time, AC power, no thermal warnings; medians (N = 3–10). The harnesses lived in a
scratch area and are not part of the repo; the decode and render benches are reproduced by `peekaboo-bench`.

### Winners per tier and format (median ms, single image)

| tier | baseline JPEG 24 MP (14.9 MB) | baseline JPEG 50-60 MP | progressive JPEG 24 / 101 MP | HEIC 44-50 MP | RAW | PNG / TIFF / WebP / AVIF 24 MP |
|---|---|---|---|---|---|---|
| dimensions | tj3DecompressHeader 0.011 (in-memory) or ImageIO props 0.49; both negligible | ImageIO props 1.5-2.5, tj header 0.02 | ImageIO props 0.5-0.7 | ImageIO props 0.6-0.7 | ImageIO props 1.5-2.2 | ImageIO props 0.06-0.6 |
| preview <= 1024 | EXIF thumb via `thumb_ifabsent` 0.2-1 ms when present (160-320 px only); else ImageIO `subsample 4` **40.2** (1486x991), `thumb_always 1024` 44.8; tj 1/8 86.7 | ImageIO `subsample 4` **89.8-101** (2172-2376 px); EXIF thumb 0.4 ms (256 px) | ImageIO `subsample 8` / `thumb_always <=512`: **32 / 88** | ImageIO `thumb_always 1024` 70-76, `subsample 8` 73 | embedded preview via `thumb_ifabsent 1024`: **ARW 15.4**, RAF 19.2, NEF 42.6; ProRAW `thumb_always 1024` 24; CR3 has no usable embedded preview (301) | TIFF `thumb_always 512` 23; AVIF 48; PNG 277; WebP 303 |
| screen fit (2048-3456) | ImageIO `subsample 2` **44.6** (2973x1982); `thumb_always 2560` 70; `thumb_always 3456` 138 is a trap (full decode + high-quality resample) | ImageIO `subsample 2` 95-104 (4344-4752 px, then GPU downsample about 2.6 ms) or `thumb_always 2048` 110-124 | tj 1/2 **253**, zune full 304, ImageIO `subsample 2` 302 (24 MP); 101 MP: zune full 546 | ImageIO `thumb_always 3456` **62-73** or `subsample 2` 73 | `thumb_ifabsent 3456`: RAF **70.5**, NEF 92.5, ARW 10.5 (but only 1616x1080; `thumb_always 3456` 463); ProRAW 103; CR3 419 | TIFF `full_cache` 18; AVIF `thumb 3456` 50; PNG 317; WebP 345 |
| full res | ImageIO `full_cache` **49.8** (tj 109, zune 128, jpeg-decoder 179) | ImageIO **114-129** (tj 284-308, zune 306-359) | **tj 290** / **zune 546** (ImageIO 320 / 709) | ImageIO `full_cache` 94-110 (195-227 materialized) | ImageIO materialized: ProRAW 12 MP 133, RAF 26 MP 384, NEF 46 MP 504, CR3 45 MP 733, ARW 61 MP 886 | TIFF 18 (ImageIO), PNG 203 (Rust `png`; ImageIO 257), AVIF 60-114 (ImageIO), WebP 277 (ImageIO; image-webp 496) |
| parallel prefetch (12 images, mixed nav set) | libjpeg-turbo scales 6.1x to 10 threads (38.6 img/s full, 43.4 img/s at 1/2); zune 6.2x (32.8 img/s). ImageIO `full_cache` is flat at 10.3-10.8 img/s; ImageIO lazy decode + draw into pre-faulted buffers reaches **33.1 img/s** at 12 threads; `thumb_always 3456` 28.2 img/s | (same set) | (same set) | ImageIO only (in the mixed set) | not measured in parallel | not measured in parallel |

### Parallel decode throughput (12-image navigation batch, images/s)

| decoder | 1 thread | 4 | 8 | 10 | 12 |
|---|---|---|---|---|---|
| ImageIO `ShouldCacheImmediately` | 10.3 | 10.5 | 10.6 | 10.7 | 10.8 |
| ImageIO lazy decode drawn into own pre-faulted buffer | 7.8 | 19.1 | 26.6 | 27.4 | 33.1 |
| libjpeg-turbo full | 6.3 | 20.8 | 35.4 | 38.6 | 37.6 |
| libjpeg-turbo 1/2 | 6.9 | 23.6 | 38.0 | 43.4 | 42.8 |
| zune-jpeg (Rust) full | 5.3 | 16.0 | 29.7 | 32.8 | 32.4 |

### GPU and display

- Upload: IOSurface wrap 0.003 ms, no-copy linear texture 0.02–0.04 ms, blit to private 1.1 ms (24 MP).
- Downsampling 24 MP → 3456 px: MPS Lanczos 2.13 ms GPU (46 dB vs vImage HQ, which takes 47 ms on the CPU); bilinear 0.32 ms (37.8 dB).
- `layer.contents = CGImage` (3456×2304) blocks the main thread 23 ms at commit; an IOSurface 0.15–0.34 ms.
- CAMetalLayer present → on glass: 24.9 ms (3 vsyncs) on the built-in 120 Hz panel, 13.8 ms (2 vsyncs) at 144 Hz.
- Zoom/pan frame (3200×1974): trilinear 0.31–0.38 ms, bicubic 1.1–1.6 ms; MPS Lanczos per frame 4–6 ms (so only on settle).

### Launch to first frame (spawn → first frame, median [p90] ms)

| variant | direct exec | via LaunchServices (.app) |
|---|---|---|
| Swift AppKit + CAMetalLayer, ImageIO | 192 [196] | 258 [291] |
| Swift AppKit + CALayer, ImageIO | 193 [200] | 262 [280] |
| Rust winit + wgpu, ImageIO | 204 [209] | — |
| Rust winit + wgpu, libjpeg-turbo 1/2 | 182 [192] | 257 [303] |

Same decoder, Swift reaches the first frame 11–15 ms sooner; through LaunchServices all variants land at 257–262 ms,
so staying resident (≈ 65 ms re-open) matters far more than the language.

## Slow formats: progressive JPEG, PNG, WebP (2026-11-25)

Measured on the same Mac while five other workloads shared it (load average 5–11): release builds, medians of ≥ 5
runs, A/B runs interleaved. Harnesses: `peekaboo-bench decode` (now prints the early rendition and, with `--variants`,
PNG exactness against ImageIO); the one-off C harnesses lived in a scratch area.

Before / after, `peekaboo-bench decode --iters 5` on the whole corpus, `main` and this change alternating, median of
5 rounds (ms; preview 512 px, screen 3456 px):

| file | preview | screen | full | early rendition (PSNR) |
|---|---|---|---|---|
| PNG 24 MP | 317 → **164** | 281 → **154** | 277 → **153** | |
| PNG 12 MP | 133 → **66** | 117 → **63** | 118 → **60** | |
| progressive JPEG 24 MP 4:4:4 | 35 → 36 | 301 → 300 | 299 → 300 | **76** (35.5 dB) |
| progressive JPEG 24 MP 4:2:0 (mozjpeg) | 39 → 40 | 168 → 164 | 165 → 163 | **42** (32.1 dB) |
| progressive JPEG 101 MP 4:4:4 | 0.4 → 0.3 | 679 → 682 | 729 → 717 | **94** (51.9 dB) |
| progressive JPEG 22705 px panorama | 0.2 → 0.2 | 945 → 933 | 1001 → 1015 | **146** (49.8 dB) |
| WebP 24 MP lossy / lossless | 338 → 335 / 402 → 401 | 309 → 304 / 366 → 367 | 305 → 308 / 364 → 367 | |

Unchanged within noise: baseline JPEG 12–60 MP (e.g. 24 MP screen 39.9 → 40.3, 60 MP 95.4 → 95.2), HEIC and AVIF
(the shared hardware HEVC engine swung both builds by up to 2× between rounds; the quiet rounds agree), JPEG XL, TIFF,
GIF, every RAW, and the parallel `.screen` throughput over `nav/` (6 threads 57.4 → 55.8 images/s, pairwise per round
−0.4…+2.2 except one outlier round). The exact progressive decode beside its early rendition: 298 / 166 / 673 / 932 ms
for the four files above (alone 300 / 164 / 682 / 933 ms).

### Progressive JPEG

Where a progressive decode spends its time (libjpeg-turbo 3.2.1, 1/8 scale so the IDCT is negligible; 24 MP 4:4:4,
libjpeg's standard script): DC 47 ms (mostly the whole-image coefficient buffer), Y AC 1–5 + Cr + Cb + Y AC 6–63 first
passes +23 ms, **Y refinement 2→1 +57 ms, Cr/Cb refinements +81 ms, Y refinement 1→0 +87 ms**. Refinement scans are
bit-serial per coefficient and dominate; entropy decoding is the floor at every DCT scale (1/1 336 ms, 1/8 303 ms).

Decoding the file cut after its last first-pass scan (every coefficient known at reduced precision), at the screen
scale, PSNR against the exact decode at that scale:

| file | cut at | first passes, smoothing on / off | PSNR | exact |
|---|---|---|---|---|
| 24 MP 4:4:4 (14 MB), 1/1 | 52 % | 87 / 74 ms | 35.5 dB | 304–320 ms |
| 24 MP 4:4:4, 1/2 | 52 % | 88 / 63 ms | 42.2 dB | 294–308 ms |
| 24 MP 4:2:0 mozjpeg (6.4 MB), 1/1 | 46 % | 47 / 39 ms | 32.1 dB | 163–170 ms |
| 101 MP 4:4:4, 1/2 | 23 % | 154 / 93 ms | 51.9 dB | 735–742 ms |
| 22705 px panorama, 1/4 | 39 % | 205 / 144 ms | 49.8 dB | 973–995 ms |

Block smoothing (libjpeg's default for incomplete scans) only costs time at that point: off. Options compared:

- **Concurrent truncated decode (adopted)**: the cut file decoded on a second core beside the plain decode: early
  77 / 40 / 104 / 138 ms for the four files, exact 302 / 174 / 723 / 997 ms (alone 320 / 165 / 735 / 990: unslowed
  within noise, ≤ 5 %). Through the app's decoder: 76 / 41 / 108 / 148 ms beside 299 / 165 / 670 / 935 ms.
- libjpeg buffered-image mode, one decode with an extra output pass after the cut: early at the same time, the final
  pass bit-identical to `tj3Decompress8`, but the exact output 7–12 % later (24 MP 4:4:4 326–353 vs 299–318 ms).
- All scans except the luma AC refinements (chroma and DC refinements kept; legal, the successive-approximation chains
  are per component): +1.4–4 dB for 1.5–4× the time (24 MP 4:2:0 60 ms 33.5 dB; 101 MP 433 ms 55.4 dB).
- `JDCT_IFAST` for the early pass: −4 % time, −0.2–0.6 dB. Not worth a second code path.
- `TJPARAM_FASTUPSAMPLE` / `FASTDCT` for the exact screen tier (24 MP 4:2:0 at 1/1): 163 / 166 vs 198 ms but 38.4 /
  45.3 dB, and at 3456 px that tier is the full-resolution image (no `.full` decode follows). 4:4:4 gains nothing.
- Parallel scan chains (DC, Y, Cb, Cr decoded by separate handles): the luma chain alone is ≥ 55 % of the entropy
  work, so ≤ 1.4×, and merging coefficients needs libjpeg-internal structures. Not built.

### PNG

24 MP RGB photo (5947×3964, Paeth on 84 % of the rows, 16 KB IDATs, iCCP) and 12 MP "screenshot-like" (Avg rows):

| decoder | 24 MP | 12 MP | notes |
|---|---|---|---|
| ImageIO (IOSurface SPI, the previous path) | 282–312 ms | 120–123 ms | subsample /2–/8 saves nothing (297–323 ms) |
| Wuffs 0.4 (NEON filters) | 296 ms (279 without checksums) | 95 ms | |
| libspng 0.7.4 + system zlib | 244 ms | 90 ms | |
| libdeflate 1.26 + scalar unfilter | 302 ms (inflate 113) | 106 ms (inflate 51) | non-streaming |
| **own decoder (`CPeekabooDecode`), one thread** | 195–216 ms | 71–75 ms | system zlib, branchless unfilter |
| **own decoder, inflate on a second thread** | **137–156 ms** | **59–62 ms** | every tier (box filter /2–/8 included) |

Inflate alone over the same IDAT stream: libdeflate 115 ms, system zlib 127 ms, Wuffs 152 ms (24 MP); 53 / 53 / 67 ms
(12 MP). Apple's zlib is within 10 % of libdeflate and streams, so the pipeline needs no vendored inflate. Paeth
unfilter of the 24 MP image: branchy scalar 151 ms, libpng-style NEON 89 ms, **branchless scalar 62 ms** (the left
neighbour in a register per byte keeps three independent chains in flight), two rows interleaved 58 ms. CRC checks of
every IDAT cost ≤ 5 ms and are kept (a corrupt file goes to ImageIO). Samples are identical to ImageIO's for RGB/RGBA
8/16-bit, palette 1/2/4/8-bit with and without tRNS, colour keys and every filter type (`PNGDecodeTests`).

Apple's `iDOT` PNGs (screenshots) split the rows in two halves that ImageIO inflates in parallel. The IDAT data is
still one zlib stream (fully flushed at the split, the split row Sub-filtered), so the decoder reads it as one: a
system-resource iDOT PNG decodes identically to ImageIO (5.7 vs 6.4 ms), and a 12 MP iDOT re-encode of the corpus
screenshot-like PNG in 66 ms vs ImageIO's 80–86 ms (117 ms without iDOT). Inflating the halves on two threads would
roughly halve that again (not done yet). `CgBI` (Xcode's iOS-optimised PNG: a critical chunk) goes to ImageIO.

### WebP

libwebp 1.6.0 built from source (`-O3`, NEON) decoding BGRA into an own buffer vs ImageIO (which renders the same
pixels, so it is libwebp underneath):

| 24 MP | ImageIO | libwebp | `use_threads` | `use_threads` + scaled to 3456 | to 744 |
|---|---|---|---|---|---|
| lossy q90 (6.4 MB) | 331 ms | 289 ms | 279 ms | 268 ms | 261 ms |
| lossless (30 MB) | 372 ms | 360 ms | 366 ms | 485 ms | 404 ms |

Threads barely help (one token partition: the bool decoder parses serially and dominates at this bitrate); scaling
happens after the decode. ImageIO's subsample factor is ignored for WebP (always 5947×3964) and its 512 px thumbnail
costs 357 / 422 ms. Incremental decoding (`WebPIDecoder`) yields rows top to bottom, never a whole low-resolution
image, so it offers no early tier either (VP8 has no DC-only shortcut: every token must be parsed in order). Not adopted: 16–25 % on lossy, nothing on lossless, for 35k lines of vendored parser that would
no longer get Apple's security updates (CVE-2023-4863 was a libwebp heap overflow).

### End to end (`peekaboo-bench pipeline --cold`)

Folders of hard links into the corpus: 24 progressive JPEGs (24 MP 4:4:4, 24 MP 4:2:0, 101 MP, repeated) and 16
PNGs (24 and 12 MP). `main` and this change interleaved, medians of 3–5 rounds. "Early" is the first screen-or-better
tier (an early rendition included), "sharp" the exact one:

| folder, trace | metric | `main` | this change |
|---|---|---|---|
| progressive, random jumps | first pixel p90 | 40 ms | 40 ms |
| | early p90 / p99 | 304 / 681 ms | **84 / 99 ms** |
| | sharp p90 / p99 | 304 / 681 ms | 307 / 686 ms |
| progressive, key repeat then dwell | early / sharp | 798 / 798 ms | **210** / 794 ms |
| PNG, random jumps | first pixel = sharp, p90 / p99 | 292 / 297 ms | **162 / 171 ms** |
| PNG, key repeat (30/s) | first pixel p90 | 120 ms | **31 ms** |
| | sharp after the dwell | 189 ms | **123 ms** |
| both, steady 1/s and A/B toggling | prefetch hits | 100 % | 100 % |

`navigate()` and the main-thread time per navigation are unchanged (p50 47–86 µs, 0.15–0.45 ms per navigation in
both). Both builds showed occasional 3–12 ms main-thread iterations while the machine was saturated by other
workloads; a temporary watchdog that sampled the main thread during them found it descheduled at arbitrary
instructions (a struct copy, the run loop's port poll), not waiting on a lock, a fault or the decoders. Decoding
prefetched PNGs on one thread instead of two removed nothing measurable there but left fewer previews ready while
skimming (first pixel p90 108–123 ms instead of 24–35), so prefetch keeps the second thread.

### Persistent cache

Not built: after these changes the slowest first views are ~150–165 ms (PNG 24 MP, progressive panorama early
rendition); a disk cache of ~25 MB screen renditions would only shorten revisits, which QuickLook's thumbnail cache and
the in-memory tiers already cover, at gigabytes of disk.
