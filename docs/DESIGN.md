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
- Baseline JPEG ≤ ~50 MP is decoded by the **hardware JPEG engines** (2 on M4 Pro): 24 MP 51 ms vs 109 ms in software.
- `kCGImageSourceShouldCacheImmediately` decodes are **serialised process-wide**; the draw, thumbnail and
  private `CGImageSourceCreateIOSurfaceAtIndex` paths run in parallel. That private call returns a BGRA
  IOSurface (zero copy to Metal) and uses **both** HW engines: 24 MP at ~20 ms per image with 2 workers.
  It is resolved with `dlsym` and must fall back to the public path when missing.
- `CreateThumbnailAtIndex(Always, MaxPixelSize 3456)` is a **trap** for JPEG (131–144 ms for 24 MP, 3× a full
  HW decode: CPU resampling). Decode full or `SubsampleFactor 2` and scale on the GPU.
- Thumbnails with `MaxPixelSize` and *without* `…Always` return embedded previews: JPEG EXIF thumb 0.3–0.5 ms,
  HEIC thumbnail item ~2 ms, RAW: ARW 1616×1080 in 11 ms, RAF 4416×2944 in 34 ms, NEF full-size in 94 ms,
  ProRAW DNG 4032×3024 in 42 ms. **CR3 exposes no preview** (parse the ISO-BMFF container for the embedded JPEG).
- Progressive JPEG is never HW-decoded (24 MP: 310 ms), but `SubsampleFactor 8` takes a DC-only path: 32 ms.
- JPEG > HW limit (101 MP: 726 ms; 22705 px panorama: 1044 ms) falls back to single-threaded software.
- PNG (24 MP 268 ms) and WebP (290 ms) have no fast path. HEIC cost is independent of output size (always full decode, HW).
- Default outputs are not BGRA (full decode = RGBX, thumbnails = XRGB); converting by drawing costs +62 ms per
  24 MP. **Never convert on the CPU**: `PixelLayout` + texture swizzle cover every native layout.
- Metadata (`CopyPropertiesAtIndex`) costs 0.07–0.6 ms (RAW 1.3–2.6 ms); creating a source does not read the file.

libjpeg-turbo (static, `CTurboJPEG`) on real 24–101 MP photos: 24 MP 109 ms, 60 MP 308 ms, 101 MP 641 ms;
DCT scaling saves only 10–20% on high-entropy files (Huffman-bound); 10 threads ≈ 40 images/s.

| Source | `.preview` (≤ 512 px) | `.screen` | `.full` |
|---|---|---|---|
| JPEG baseline ≤ HW limit | embedded EXIF/MPF thumb if present; else `Subsample 8` | HW IOSurface path (full or `Subsample 2` when W/2 ≥ screen) | HW IOSurface path |
| JPEG progressive | `Subsample 8` (DC-only) | libjpeg-turbo, DCT scale covering the screen | libjpeg-turbo |
| JPEG > HW limit | embedded thumb, else libjpeg-turbo 1/8 | libjpeg-turbo, DCT scale covering the screen | libjpeg-turbo (tiles for > 16384 px) |
| HEIC / HEIF / AVIF | embedded thumbnail item | ImageIO (HW) | ImageIO (HW) |
| Camera RAW | embedded preview (thumbnail without `Always`); CR3 via own BMFF parse | largest embedded preview if it covers the screen, else RAW decode (background) | RAW decode (0.25–1.4 s), only on zoom |
| PNG / WebP / TIFF / GIF / JXL / PSD / EXR | `CreateThumbnailAtIndex(Always, ≤ 512)` | parallel draw path | parallel draw path |

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
  own preview decode.
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
- **Pacing**: event-driven immediate render for discrete actions; `CAMetalDisplayLink` only while animating;
  one drawable per refresh.

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
| Prefetch hit: key → frame on glass | ≤ 1 refresh (8.3 ms @120 Hz) |
| Miss, embedded preview available: first pixel | ≤ 12 ms after the key |
| Cold launch (Finder) → first pixel | ≤ 250 ms |
| Resident re-open → first pixel | ≤ 80 ms |
| GPU per frame at 3456×2234 | ≤ 3.5 ms |
| Main-thread work per navigation | ≤ 1 ms |

Measure with `PEEKABOO_TRACE=1` (stderr timeline) and `peekaboo-bench`.
