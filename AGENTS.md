# Peekaboo — instructions for coding agents

Peekaboo is an ultra-fast image viewer for macOS on Apple Silicon. **Speed is the product.**

## Rule #1 — performance is the first principle, always

**Performance comes first, no matter what, in every decision.** When anything conflicts with speed —
a feature, a setting, a dependency, UI polish, code style, a deadline — speed wins. Judge every change
first by launch-to-first-pixel, next/previous latency, time to sharp and zoom/pan smoothness
(120 Hz ProMotion, 144 Hz external), and only then by features.

- New features must cost ~0 on the hot paths: nothing on the launch path before the first frame,
  nothing on the main thread during navigation; initialise lazily, after the first frame, off the main thread.
- Measure before and after on the target Mac (`PEEKABOO_TRACE=1`, `peekaboo-bench`, `--selftest`) and put
  the numbers in the PR. A change without numbers that touches a hot path is not done.
- If a request would slow a hot path, find a design that doesn't, or say so plainly. Never ship a silent regression.

## Non-negotiable rules

- **Never commit secrets or personal data**: tokens, keys, certificates, `.env` files,
  personal e-mail addresses, absolute home paths (`/Users/<name>/…`), agent scratch paths.
  `gitleaks` (config: `.gitleaks.toml`) runs on every commit and push via lefthook and in CI.
  Never bypass it (`--no-verify`, `LEFTHOOK=0`); remove the offending content instead.
- Commit messages: imperative subject line.
- **No AI attribution anywhere**: no `Co-Authored-By` trailers, no "Generated with …" lines, no agent session
  URLs or IDs in commits, PR titles/descriptions, issues, comments or release notes.
- One GitHub issue per workstream; PR descriptions say `Closes #N`. Merge only when
  `swift build` and `swift test` pass (CI runs both plus the secret scan).
- Keep `main` lean: delete unused code, functions, files, scripts and prototypes instead of
  leaving them behind.

## Setup

```sh
mise install       # pinned gitleaks + lefthook (mise.toml)
mise run setup     # installs the git hooks
brew install jpeg-turbo   # static libturbojpeg linked into PeekabooCore
```

## Commands

| Task | Command |
|---|---|
| Debug build | `swift build` (`mise run build`) |
| Unit tests | `swift test` (`mise run test`) |
| Release app bundle | `mise run app` → `build/Peekaboo.app` |
| Install locally | `mise run install` → `~/Applications/Peekaboo.app` + `peekaboo` CLI in `~/.local/bin` |
| DMG (drag-to-Applications) | `mise run dmg` → `build/Peekaboo.dmg` |
| Release | `mise run release <version>`: tag on `main`, build the DMG, publish a GitHub Release |
| Secret scan (history + tree) | `mise run secrets` |
| Latency trace | `PEEKABOO_TRACE=1 build/Peekaboo.app/Contents/MacOS/Peekaboo <image>` |
| Benchmark corpus | `mise run corpus` → `~/Library/Caches/peekaboo-corpus` (override with `PEEKABOO_CORPUS`) |
| Benchmarks | `swift run -c release peekaboo-bench <suite>` |

## Debug switches

| Switch | Effect |
|---|---|
| `PEEKABOO_TRACE=1` | timestamped stderr trace: decode paths and ms, scheduling, present mode, HUD, toasts |
| `PEEKABOO_ACTIONS="nav.next,zoom.toggle,…"` | run action ids 1 s after launch, 400 ms apart (smoke runs, screenshots) |
| `Peekaboo --selftest <folder>` | open the folder, measure launch → first frame and action → frame latency, print one JSON line, exit |
| `PEEKABOO_NO_IOSURFACE_SPI=1` | force the public ImageIO path instead of the private IOSurface fast path |
| `PEEKABOO_HDR=1` | decode gain-map photos to HDR (off by default: 13× the SDR cost) |
| `PEEKABOO_CONFIG=<file>` | use another config file |
| `peekaboo-bench decode / pipeline [--cold] / render [--png DIR]` | regression benches (corpus from `PEEKABOO_CORPUS`, built by `mise run corpus`) |

## Layout

- `Sources/PeekabooCore` — decoding, tiered cache, prefetch scheduler, folder model,
  config/keymap. No AppKit. Shared contract types live in `Sources/PeekabooCore/Model`.
- `Sources/PeekabooRender` — Metal renderer (zero-copy textures, quality pyramid,
  resampling kernels, progressive refinement).
- `Sources/PeekabooApp` — programmatic AppKit shell (no storyboards, nibs or SwiftUI).
- `Sources/PeekabooBench` — `peekaboo-bench` performance regression CLI.
- `Resources/Info.plist` — bundle metadata and document types; `Resources/peekaboo` — CLI launcher shipped in the bundle; `.mise/tasks/` — app bundle and install tasks.

## Performance rules

- Nothing slow on the main thread: no decoding, colour conversion, file I/O or large allocations.
- Never assign a large `CGImage` to `CALayer.contents` (Core Animation converts it on the main
  thread, 58–323 ms per 24 MP image). Everything on screen goes through the Metal renderer.
- Decode into `PixelBuffer` (shared `MTLBuffer`) and wrap it as a texture without copying.
  Keep the `PixelBuffer` alive until every command buffer reading it has completed.
- Progressive tiers (`preview` → `screen` → `full`) share one geometry, so a refinement never
  shifts or rescales the picture.
- Measure before and after performance work (`PEEKABOO_TRACE=1`, `peekaboo-bench`) and put the
  numbers in the PR description.

## Code conventions

- Swift 6.4 toolchain in Swift 5 language mode; deployment target macOS 26 (Apple Silicon).
- Tests that need Metal, a display or the benchmark corpus must `XCTSkip` when it is unavailable.
- Prefer Apple frameworks (ImageIO, Metal, Accelerate) and static C libraries over new
  dependencies.
