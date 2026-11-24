# Peekaboo — instructions for coding agents

Peekaboo is an ultra-fast image viewer for macOS on Apple Silicon. **Speed is the product.**
Judge every change first by launch-to-first-pixel, next/previous latency and zoom/pan
smoothness (120 Hz ProMotion, 144 Hz external), then by features.

## Non-negotiable rules

- **Never commit secrets or personal data**: tokens, keys, certificates, `.env` files,
  personal e-mail addresses, absolute home paths (`/Users/<name>/…`), agent scratch paths.
  `gitleaks` (config: `.gitleaks.toml`) runs on every commit and push via lefthook and in CI.
  Never bypass it (`--no-verify`, `LEFTHOOK=0`); remove the offending content instead.
- Commit messages: imperative subject line. Do not add `Co-Authored-By` trailers.
- One GitHub issue per workstream; PR descriptions say `Closes #N`. Merge only when
  `swift build` and `swift test` pass (CI runs both plus the secret scan).
- Keep `main` lean: delete unused code, functions, files, scripts and prototypes instead of
  leaving them behind.

## Setup

```sh
mise install       # pinned gitleaks + lefthook (mise.toml)
mise run setup     # installs the git hooks
```

## Commands

| Task | Command |
|---|---|
| Debug build | `swift build` (`mise run build`) |
| Unit tests | `swift test` (`mise run test`) |
| Release app bundle | `scripts/build-app.sh` → `build/Peekaboo.app` |
| Install locally | `scripts/install.sh` → `~/Applications/Peekaboo.app` |
| Secret scan (history + tree) | `mise run secrets` |
| Latency trace | `PEEKABOO_TRACE=1 build/Peekaboo.app/Contents/MacOS/Peekaboo <image>` |
| Benchmarks | `swift run -c release peekaboo-bench <suite>` |

## Layout

- `Sources/PeekabooCore` — decoding, tiered cache, prefetch scheduler, folder model,
  config/keymap. No AppKit. Shared contract types live in `Sources/PeekabooCore/Model`.
- `Sources/PeekabooRender` — Metal renderer (zero-copy textures, quality pyramid,
  resampling kernels, progressive refinement).
- `Sources/PeekabooApp` — programmatic AppKit shell (no storyboards, nibs or SwiftUI).
- `Sources/PeekabooBench` — `peekaboo-bench` performance regression CLI.
- `Resources/Info.plist` — bundle metadata and document types; `scripts/` — build/install.

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

- Swift 6.4 toolchain in Swift 5 language mode; deployment target macOS 15.
- Tests that need Metal, a display or the benchmark corpus must `XCTSkip` when it is unavailable.
- Prefer Apple frameworks (ImageIO, Metal, Accelerate) and static C libraries over new
  dependencies.
