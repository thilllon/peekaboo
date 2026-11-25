<p align="center">
  <img src="docs/assets/icon.png" alt="Peekaboo" width="128" height="128" />
</p>

<h1 align="center">Peekaboo</h1>

<p align="center">
  <strong>An ultra-fast, keyboard-first image viewer for macOS on Apple Silicon.</strong><br />
  The next photo is already decoded before you press the key. Sharp pixels in a frame, not a spinner.
</p>

<p align="center">
  <a href="https://github.com/thilllon/peekaboo/releases/latest"><b>Download Peekaboo</b></a> ·
  <a href="https://thilllon.github.io/projects/peekaboo/">Website</a> ·
  <a href="docs/CONFIG.md">Configuration</a> ·
  <a href="docs/DESIGN.md">Design</a>
</p>

<p align="center">
  <a href="https://github.com/thilllon/peekaboo/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/thilllon/peekaboo/ci.yml?branch=main&logo=githubactions&logoColor=white&label=CI" alt="CI" /></a>
  <a href="https://github.com/thilllon/peekaboo/releases/latest"><img src="https://img.shields.io/github/v/release/thilllon/peekaboo?label=release" alt="release" /></a>
  <img src="https://img.shields.io/badge/macOS-14%2B%20%C2%B7%20Apple%20Silicon-black?logo=apple" alt="macOS 14+" />
  <a href="./LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT" /></a>
</p>

<p align="center">
  <img src="docs/assets/screenshot.jpg" alt="Peekaboo showing a photo with its minimal HUD" width="100%" />
</p>

## Why it is fast

Everything below was measured on a MacBook Pro M4 Pro (see [docs/research.md](docs/research.md)).

- **Hardware decoding, zero copies.** Baseline JPEGs go through the Apple Silicon JPEG engines (24 MP in 50 ms vs 109 ms for
  libjpeg-turbo), HEIC and AVIF through the hardware decoders with their YCbCr converted on the GPU (a 12 MP HEIC in 12 ms,
  10-bit ones 20× faster than before), and the decoded pixels are handed to the GPU without a single copy.
- **No slow format left behind.** PNGs go through Peekaboo's own decoder (inflate on one core, unfilter on another),
  about twice as fast as ImageIO with identical pixels: 24 MP in ~145 ms instead of ~300. Progressive JPEGs, which no
  hardware decodes, show their first-pass scans while the exact decode finishes on another core: a 101 MP photo looks
  sharp (52 dB) after 94 ms instead of 680 ms.
- **The next image is already there.** A predictive prefetcher schedules every decode by *when you will reach that image*,
  scales its look-ahead with how fast you browse, and switches to embedded previews while you hold an arrow key.
  On a 120-photo folder it hits 100 % of steps when browsing steadily and 96 % while holding an arrow key
  (XnView MP reads one image ahead). A prefetched image is a 0.3 ms GPU present, on glass ~6 ms later.
- **Low quality first, then exact.** Each image arrives in tiers — embedded preview, screen-size decode, full resolution — all
  drawn in one coordinate system, so a sharper tier never shifts the picture. Camera previews come straight out of the file:
  2–3 ms for JPEGs with an MPF preview, 10–34 ms for RAW (ARW, CR3, NEF, RAF, DNG).
- **A custom renderer (PPR).** A linear-light Lanczos-3 pyramid plus a residual resample keeps zoomed-out images as sharp as an
  offline Lanczos resize (48–74 dB PSNR) at a constant ≤ 3 ms per frame, at any zoom. While you pinch it draws a cheap
  trilinear frame and re-rasterises 90 ms after you stop.
- **Native and resident.** AppKit + Metal, no Electron, no SwiftUI; the first frame is committed ~80 ms after the process
  starts. Closing the window keeps the app warm, so the next open takes ~65 ms.

## Features

- Opens one file and browses its whole folder in Finder order; JPEG, HEIC / HEIF (10-bit and HDR PQ / HLG camera files,
  grids, sequences, depth and Live Photo stills, `.hif`), AVIF, PNG, WebP, TIFF, GIF, JPEG XL, PSD, EXR and camera RAW
  (embedded previews first).
- Plays animated GIF, APNG, animated WebP and HEIC / AVIF sequences with their frame timing and loop counts: `k` pauses,
  `,` and `.` step a frame. Stills pay nothing for it. (Large animated WebPs play below their frame rate: ImageIO
  re-composites every WebP frame from the first one.)
- Keyboard-first and fully remappable: record new keys in Settings (⌘,) — a key that is taken names its action, and
  pressing it again moves it — or edit the TOML file, which reloads as you save it. Shortcuts keep working with
  non-Latin input methods (Korean, Japanese, …).
- Culling keys borrowed from Lightroom: 0–5 stars, 6–9 colour labels, P / X / U flags, Shift to act and advance — stored as
  Finder tags.
- Trash with undo, move/copy to configurable slots, reveal, copy path or image, open with your editor, shell templates.
- Instant (non-animated) full screen that respects the notch; HDR/EDR photos on XDR displays.
- Pinch/scroll zoom around the pointer, pixel-exact 100 %, pixel grid when you zoom far in.

## Install

1. Download `Peekaboo-<version>.dmg` from the [latest release](https://github.com/thilllon/peekaboo/releases/latest)
   (the volume is named after the version too, e.g. "Peekaboo 20261125-ab2342") and drag Peekaboo to Applications.
2. Releases are signed with a Developer ID and notarized by Apple, so Peekaboo opens like any other app, and they update
   themselves.
3. At first launch macOS asks, once for each, whether Peekaboo may access your Desktop, Documents and Downloads folders:
   Peekaboo lists the folder of the image you open so you can browse it, and asks then rather than in the middle of your
   work. macOS keeps the answers, across updates too; change them in **System Settings → Privacy & Security → Files &
   Folders**. In a folder Peekaboo may not read, the image you open shows on its own and a toast says how to allow it.
4. Optional: make it the default viewer with Finder → Get Info → Open with → Peekaboo → Change All.

Requires macOS 14 (Sonoma) or later on Apple Silicon.

**Versions** are the release commit's day and the start of its hash, e.g. `20261125-ab2342`. Peekaboo › About Peekaboo,
Settings and `peekaboo --version` show it with the build number, e.g. `20261125-ab2342 (35)`.

**Updates**: when it is online, Peekaboo looks for a newer release (10 s after launch at the earliest, then every 6 hours and
when the network comes back; never while it launches or on the main thread). A new release is downloaded in the background,
verified (SHA-256 and code signature) and installed when you quit, or at once with **Restart to Update**. Peekaboo › Check
for Updates… (or Check Now in Settings › Updates, which shows the status) looks now. Turn either part off in
Settings › Updates or under [`[updates]`](docs/CONFIG.md#updates).

## Usage

Open an image from Finder (Open With → Peekaboo), drop files or a folder on the window or Dock icon, or press ⌘O.
Opening one image browses its whole folder.

| Keys | Action |
|---|---|
| → ↓ Space · ← ↑ ⌫ | next · previous |
| Home · End · `[` `]` | first · last · jump 10 |
| `z` / double-click · ⌘0 · ⌘1 · ⌘2 | fit ↔ 100 % · fit · 100 % · 200 % |
| `=` `-` · pinch · ⌘-scroll | zoom around the pointer |
| `f` / Return · Esc | instant full screen · leave |
| `i` · Tab · `b` · `?` | HUD (minimal → EXIF) · hide overlays · background · all shortcuts |
| `r` `shift+r` · `\|` `_` | rotate · flip |
| `k` · `,` `.` | play / pause an animation · previous / next frame |
| `0`–`5` · `6`–`9` · `p` `x` `u` (+Shift = and advance) | stars · colour labels · pick / reject / clear |
| ⌘⌫ · ⌘Z | move to Trash · undo |
| `m` · `c` · ⌥1–9 | move / copy to a slot |
| ⌘C · ⌥⌘C · ⇧⌘R · `e` | copy image · copy path · reveal in Finder · open in editor |

Every binding is configurable; the full table is in [docs/CONFIG.md](docs/CONFIG.md#default-keymap).

Command line: `peekaboo <image-or-folder> …`, `peekaboo --version` (installed into `~/.local/bin` by `mise run install`).

## Configuration

Press ⌘, for Settings: every option (viewer, keyboard shortcuts, move/copy slots, apps, ratings, memory, HDR decoding,
updates) and the default-viewer switch per image type. Settings writes `~/.config/peekaboo/config.toml`, changing only
the lines it must and keeping your comments; the file is the single source of truth, so edits in your editor apply
live and show in Settings too (Peekaboo › Open config.toml). See [docs/CONFIG.md](docs/CONFIG.md) for every option
and action.

## Build from source

```sh
mise install              # pinned gitleaks, lefthook, cmake
mise run setup            # git hooks
mise run deps             # static libjpeg-turbo and libwebp (pinned, checksum-verified) for macOS 14 → .deps/
mise run install          # build the release app into ~/Applications
```

`swift build`, `swift test`, `mise run app`, `mise run dmg`, `peekaboo-bench <anim|decode|pipeline|render>`. Releases:
`mise run release` (see [AGENTS.md](AGENTS.md#releases)).

## How it works

| Module | Responsibility |
|---|---|
| `PeekabooCore` | decoding routes (ImageIO hardware paths, libjpeg-turbo lane, own PNG decoder, embedded previews), predictive prefetch scheduler, tiered cache, animation player, folder model, config & keymap |
| `CPeekabooDecode` | C decoders where ImageIO is slow: PNG (system zlib, two-thread pipeline), early renditions of progressive JPEGs |
| `PeekabooRender` | Metal renderer: zero-copy textures, Lanczos-3 pyramid, residual resampler, colour management, settle-time refinement |
| `PeekabooApp` | AppKit shell: window, input, HUD, full screen, file actions |
| `PeekabooBench` | performance regression CLI |

The decisions and the measurements behind them are in [docs/DESIGN.md](docs/DESIGN.md) and [docs/research.md](docs/research.md).

## License

[MIT](LICENSE)

Peekaboo links [libjpeg-turbo](https://libjpeg-turbo.org) and [libwebp](https://chromium.googlesource.com/webm/libwebp)
statically. This software is based in part on the work of the Independent JPEG Group. libjpeg-turbo's license (IJG,
Modified BSD, zlib) ships in the app as `Contents/Resources/LICENSE-libjpeg-turbo.md`, libwebp's (BSD-3-Clause and its
patent grant) as `Contents/Resources/LICENSE-libwebp.txt`.
