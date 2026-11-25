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
- Commit messages: imperative subject line. The lefthook hooks reject a commit whose author is not the GitHub noreply
  address or whose message carries AI attribution.
- **No AI attribution anywhere**: no `Co-Authored-By` trailers, no "Generated with …" lines, no agent session
  URLs or IDs in commits, PR titles/descriptions, issues, comments or release notes.
- One GitHub issue per workstream; PR descriptions say `Closes #N`. Merge only when
  `swift build` and `swift test` pass (CI runs both plus the secret scan).
- Keep `main` lean: delete unused code, functions, files, scripts and prototypes instead of
  leaving them behind.

## Setup

```sh
mise install       # pinned gitleaks, lefthook, cmake (mise.toml)
mise run setup     # installs the git hooks
mise run deps      # static libjpeg-turbo and libwebp for the deployment target → .deps/ (linked into PeekabooCore)
```

## Commands

| Task | Command |
|---|---|
| Static C dependencies | `mise run deps`: pinned libjpeg-turbo and libwebp, SHA-256 checked, built for macOS 14 arm64 into `.deps/` (no-op when up to date) |
| Debug build | `swift build` (`mise run build`) |
| Unit tests | `swift test` (`mise run test`) |
| Release app bundle | `mise run app` → `build/Peekaboo.app` (version and build number of `HEAD`; `VERSION=` / `BUILD=` override) |
| Install locally | `mise run install` → `~/Applications/Peekaboo.app` + `peekaboo` CLI in `~/.local/bin` |
| DMG + updater zip | `mise run dmg` → `build/Peekaboo-<version>.dmg`, `build/Peekaboo-<version>.zip` |
| Release | `mise run release`: version of `HEAD`, notarized DMG, tag `v<version>`, GitHub Release (see [Releases](#releases)) |
| Secret scan (history + tree) | `mise run secrets` |
| Latency trace | `PEEKABOO_TRACE=1 build/Peekaboo.app/Contents/MacOS/Peekaboo <image>` |
| Benchmark corpus | `mise run corpus` → `~/Library/Caches/peekaboo-corpus` (override with `PEEKABOO_CORPUS`; its derived files need `brew install jpeg-turbo webp`) |
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
| `defaults delete com.thilllon.Peekaboo PeekabooFolderAccessRequested` | Peekaboo.app's next launch lists Desktop, Documents and Downloads again (macOS prompts only for a folder it has no answer for: `tccutil reset SystemPolicyDownloadsFolder com.thilllon.Peekaboo`, likewise `…DesktopFolder`, `…DocumentsFolder`) |
| `peekaboo-bench decode / pipeline [--cold] / render [--png DIR]` | regression benches (corpus from `PEEKABOO_CORPUS`, built by `mise run corpus`) |
| `peekaboo-bench anim [file …]` | headless animation playback: on-screen duration vs declared delay, late frames, decode per frame, memory |

## Layout

- `Sources/PeekabooCore` — decoding, tiered cache, prefetch scheduler, folder model,
  config/keymap, update verification and install (`Update/`). No AppKit. Shared contract types live in
  `Sources/PeekabooCore/Model`.
- `Sources/CPeekabooDecode` — own C decoders where ImageIO is slow: PNG (system zlib) and the
  first-pass rendition of progressive JPEGs (libjpeg-turbo's libjpeg API, headers from `.deps/`). They parse
  untrusted files: keep every bound checked and the mutation tests (`PNGDecodeTests`, `EarlyRenditionTests`) passing.
- `Sources/CTurboJPEG`, `Sources/CWebP` — module maps for the static libjpeg-turbo and libwebp in `.deps/`.
- `Sources/PeekabooRender` — Metal renderer (zero-copy textures, quality pyramid,
  resampling kernels, progressive refinement).
- `Sources/PeekabooApp` — programmatic AppKit shell (no storyboards, nibs or SwiftUI); `Settings/` is the Settings
  window, which writes config.toml through `ConfigEditor` (minimal text edits) and is built on first use only.
- `Sources/PeekabooBench` — `peekaboo-bench` performance regression CLI.
- `Resources/Info.plist` — bundle metadata and document types; `Resources/peekaboo` — CLI launcher shipped in the bundle; `.mise/tasks/` — dependency, app bundle, DMG, install and release tasks (`.mise/lib/signing.sh`: signing and notarization helpers; `.mise/lib/version.sh`: version and build number of `HEAD`); `.deps/` (gitignored) — what `mise run deps` builds.

## Releases

A version is `YYYYMMDD-<sha6>` of the released commit: its committer day in Asia/Seoul
(`TZ=Asia/Seoul git show -s --format=%cd --date=format-local:%Y%m%d HEAD`) and the first six hex digits of its SHA,
e.g. `20261125-ab2342`. One commit always gets one version, on any machine; there is no same-day counter. It is
`CFBundleShortVersionString` (About panel, `peekaboo --version`, and the Settings window through
`BuildInfo.versionLine`), the disk image `Peekaboo-<version>.dmg`,
the tag `v<version>` and the release title `Peekaboo <version>`. A SHA is not orderable, so `CFBundleVersion` is the
**build number**, `git rev-list --count HEAD` on `main`, and the updater compares only that: a release must have a
higher build than the latest one, and an update must carry the build its `latest.json` names.

One-time setup on the maintainer's Mac (never commit any of it):

1. A **Developer ID Application** certificate in the login keychain: Xcode › Settings › Accounts › the team ›
   Manage Certificates… › + › Developer ID Application (the Account Holder can create it). Check with
   `security find-identity -v -p codesigning`.
2. A **notarytool keychain profile** named `peekaboo` (`NOTARY_PROFILE=` picks another):
   `xcrun notarytool store-credentials peekaboo --key <AuthKey_….p8> --key-id <key ID> --issuer <issuer ID>` for an
   App Store Connect API key (or `--apple-id <Apple ID> --team-id <TEAMID>` with an app-specific password).
3. Optionally `.env.production` (git-ignored, mode 600, keys as in `.env.example`): the release tasks read
   `DEVELOPER_ID_SHA1` (the identity to sign with), `NOTARY_KEYCHAIN_PROFILE` and `APPLE_TEAM_ID` (the team the
   release must be signed by) from it; without it they use the keychain's Developer ID and the profile `peekaboo`.

`mise run release`, from a clean `main` in sync with `origin/main`:

1. takes the version and build number of `HEAD`; stops if its tag exists or its build is not above the latest
   release's (from that release's `latest.json`);
2. builds `build/Peekaboo.app`, signed with the Developer ID (hardened runtime, no entitlements, secure timestamp);
3. zips it, notarizes the zip, staples the app and zips it again: `Peekaboo-<v>.zip`, the updater's payload;
4. builds `Peekaboo-<v>.dmg` (volume `Peekaboo <v>`, the app and an Applications link), signs, notarizes, staples it;
5. writes `latest.json` (`version`, `build`, `minimumSystemVersion`, `url`, `sha256`, `size`, `dmg`, `notes`, `published`);
6. tags the commit it built as `v<version>` (it stops if the checkout changed meanwhile), pushes the tag and publishes the
   GitHub Release with `Peekaboo-<v>.dmg`, `Peekaboo-<v>.zip` and `latest.json`. Every download carries its version: there is
   no unversioned `Peekaboo.dmg`. Notes are generated, or taken from `NOTES_FILE=<file>`. The tagger must be the GitHub
   noreply address (`git config user.email`).

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

- Swift 6.4 toolchain in Swift 5 language mode; deployment target macOS 14 (Apple Silicon). Newer APIs go behind
  `if #available(macOS 15 / 26, *)` with the newest path first, so macOS 26 runs exactly the code it ran before;
  never put the check in a per-pixel or per-frame loop. C code is built for the same target (`mise run deps`,
  SwiftPM C targets); the linker must not warn about objects "built for newer macOS". The binaries record SDK 26.0
  (see `linkedSDK` in Package.swift). Metal source compiled at runtime must stay within MSL 3.1, macOS 14's newest:
  add every such source to `testShadersCompileAsMetal31ForMacOS14`.
- Tests that need Metal, a display or the benchmark corpus must `XCTSkip` when it is unavailable.
- Tests never show a window or take the keyboard focus: derive window tests from `ViewerTestCase` (`.prohibited`
  activation policy; a test fails if the process activates, a window comes on screen, or the test leaves a window
  open) and build controllers with `presentation: .headless` (ordered in transparent and off every screen, never
  key; frames still render).
- Prefer Apple frameworks (ImageIO, Metal, Accelerate) and static C libraries over new
  dependencies.
