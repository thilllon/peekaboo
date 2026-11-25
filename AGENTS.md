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
- **Env files**: real values only in untracked `.env.<name>` files (e.g. `.env.production`, mode 600);
  the committed `.env.example` lists the same keys with empty values. Signing private keys never go in
  any env file: they stay in the login keychain and the `AuthKey_*.p8` file (mode 600, outside the repo).
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
| Release app bundle | `mise run app` → `build/Peekaboo.app` (version: today, `VERSION=` overrides) |
| Install locally | `mise run install` → `~/Applications/Peekaboo.app` + `peekaboo` CLI in `~/.local/bin` |
| DMG + updater zip | `mise run dmg` → `build/Peekaboo-<version>.dmg`, `build/Peekaboo-<version>.zip` |
| Release | `mise run release`: date version, notarized DMG, tag, GitHub Release (see [Releases](#releases)) |
| Secret scan (history + tree) | `mise run secrets` |
| Latency trace | `PEEKABOO_TRACE=1 build/Peekaboo.app/Contents/MacOS/Peekaboo <image>` |
| Benchmark corpus | `mise run corpus` → `~/Library/Caches/peekaboo-corpus` (override with `PEEKABOO_CORPUS`) |
| Benchmarks | `swift run -c release peekaboo-bench <suite>` |

## Debug switches

| Switch | Effect |
|---|---|
| `PEEKABOO_TRACE=1` | timestamped stderr trace: decode paths and ms, scheduling, present mode, HUD, toasts (also `[debug] trace`, from the config apply on) |
| `PEEKABOO_ACTIONS="nav.next,zoom.toggle,…"` | run action ids 1 s after launch, 400 ms apart (smoke runs, screenshots) |
| `Peekaboo --selftest <folder>` | open the folder, measure launch → first frame and action → frame latency, print one JSON line, exit |
| `PEEKABOO_NO_IOSURFACE_SPI=1` | force the public ImageIO path instead of the private IOSurface fast path (`[decode] fast_path = false` in Settings/config) |
| `PEEKABOO_HDR=1` | force gain-map and PQ / HLG photos to HDR (users switch it with `[decode] hdr` in Settings; off by default: 13× the SDR cost) |
| `PEEKABOO_CONFIG=<file>` | use another config file |
| `PEEKABOO_UPDATE_URL=<url>` | read the update manifest from here (a `file://` or `http://` test manifest; nothing is remembered) |
| `peekaboo-bench decode / pipeline [--cold] / render [--png DIR]` | regression benches (corpus from `PEEKABOO_CORPUS`, built by `mise run corpus`) |
| `peekaboo-bench anim [file …]` | headless animation playback: on-screen duration vs declared delay, late frames, decode per frame, memory |

## Layout

- `Sources/PeekabooCore` — decoding, tiered cache, prefetch scheduler, folder model,
  config/keymap, update verification and install (`Update/`). No AppKit. Shared contract types live in
  `Sources/PeekabooCore/Model`.
- `Sources/CPeekabooDecode` — own C decoders where ImageIO is slow: PNG (system zlib) and the
  first-pass rendition of progressive JPEGs (libjpeg-turbo). They parse untrusted files: keep
  every bound checked and the mutation tests (`PNGDecodeTests`, `EarlyRenditionTests`) passing.
- `Sources/PeekabooRender` — Metal renderer (zero-copy textures, quality pyramid,
  resampling kernels, progressive refinement).
- `Sources/PeekabooApp` — programmatic AppKit shell (no storyboards, nibs or SwiftUI); `Settings/` is the Settings
  window, which writes config.toml through `ConfigEditor` (minimal text edits) and is built on first use only.
- `Sources/PeekabooBench` — `peekaboo-bench` performance regression CLI.
- `Resources/Info.plist` — bundle metadata and document types; `Resources/peekaboo` — CLI launcher shipped in the bundle; `.mise/tasks/` — app bundle, DMG, install and release tasks (`.mise/lib/signing.sh`: signing and notarization helpers).

## Releases

Versions are dates: `YYYYMMDD`, and `YYYYMMDD.N` for a further release the same day. The git tag is the bare
version (`20261125`, no `v`), the release title `Peekaboo 20261125`; the legacy `v0.1.0` is older than every date.
`CFBundleShortVersionString` and `CFBundleVersion` both hold the version, `PeekabooCommit` the short commit (About
panel, `peekaboo --version`, and the Settings window through `BuildInfo.versionLine`).

One-time setup on the maintainer's Mac (never commit any of it):

1. A **Developer ID Application** certificate in the login keychain: Xcode › Settings › Accounts › the team ›
   Manage Certificates… › + › Developer ID Application (the Account Holder can create it). Check with
   `security find-identity -v -p codesigning`.
2. A **notarytool keychain profile** named `peekaboo-notary` (`NOTARY_PROFILE=` picks another):
   `xcrun notarytool store-credentials peekaboo-notary --apple-id <Apple ID> --team-id <TEAMID>` with an
   app-specific password from account.apple.com (or `--key/--key-id/--issuer` for an App Store Connect API key).

`mise run release`, from a clean `main` in sync with `origin/main`:

1. picks the version: today, or the next free `.N` (`mise run release 20261125.2` names one; it must be newer);
2. builds `build/Peekaboo.app`, signed with the Developer ID (hardened runtime, no entitlements, secure timestamp);
3. zips it, notarizes the zip, staples the app and zips it again: `Peekaboo-<v>.zip`, the updater's payload;
4. builds `Peekaboo-<v>.dmg` (volume `Peekaboo <v>`, the app and an Applications link), signs, notarizes, staples it;
5. writes `latest.json` (`version`, `minimumSystemVersion`, `url`, `sha256`, `size`, `dmg`, `notes`, `published`);
6. tags, pushes the tag and publishes the GitHub Release with `Peekaboo-<v>.dmg`, `Peekaboo.dmg` (same bytes, for the
   README's `releases/latest/download/Peekaboo.dmg` link), `Peekaboo-<v>.zip` and `latest.json`.

Without a Developer ID it refuses to publish unless `ALLOW_ADHOC=1` (other Macs then need "Open Anyway").
`DRY_RUN=1 mise run release` builds and packages everything (ad-hoc without a certificate) and prints the
notarization, tag and publish commands instead of running them. `mise run app` and `mise run dmg` sign with the
Developer ID when the keychain has one and fall back to ad-hoc for local builds (`SIGN_IDENTITY=-` forces ad-hoc);
a local ad-hoc build carries `get-task-allow` (lldb, Instruments), a release never does. A release-config bundle's
executable is stripped of the linker's debug map (`strip -S`), which names every object file and source folder by
absolute path, the home folder included; the app task refuses to sign one that still contains `/Users/` or `$HOME`
(`.build/release/Peekaboo` keeps the map for lldb).

Installed apps read `https://github.com/thilllon/peekaboo/releases/latest/download/latest.json`
(`Sources/PeekabooApp/Update`, `Sources/PeekabooCore/Update`): keep its fields and the zip layout stable, since every
installed version parses them. The updater is set up 1 s after launch (0.3 ms), touches the network and the disk
only from 11 s on and never on the main thread, and installs only a download whose SHA-256 matches and whose
signature carries the running app's identifier and team.

## Performance rules

- Nothing slow on the main thread: no decoding, colour conversion, file I/O or large allocations.
- Optional UI (the Settings window, its panes) is built when first used, never at launch. AppKit buttons and pop-ups
  cost ~1 ms each to create: draw repeated controls (the shortcut editor's key caps) instead of building them per row.
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
