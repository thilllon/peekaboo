// swift-tools-version: 6.2
import PackageDescription

// Oldest supported macOS (Sonoma; Apple Silicon only). `.mise/tasks/deps` builds libjpeg-turbo for the same version.
let minimumMacOS = "14.0"

// Release builds favour raw speed: whole-module optimisation is the SwiftPM
// release default; exclusivity checks are dropped because the hot paths are
// audited single-owner buffers.
let speed: [SwiftSetting] = [
    .unsafeFlags(["-enforce-exclusivity=unchecked"], .when(configuration: .release)),
]

// SwiftPM links without telling ld the SDK version, so ld records the deployment target in its place and system
// frameworks would run the app in their macOS 14 compatibility mode on every newer macOS. Record the SDK the app was
// linked against before it supported macOS 14 (26.0): macOS 26 keeps the exact behaviour everything was measured with.
let linkedSDK: [LinkerSetting] = [
    .unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", minimumMacOS, "-Xlinker", "26.0"]),
]

let package = Package(
    name: "Peekaboo",
    platforms: [.macOS(minimumMacOS)],
    products: [
        .executable(name: "Peekaboo", targets: ["PeekabooApp"]),
        .executable(name: "peekaboo-bench", targets: ["PeekabooBench"]),
        .library(name: "PeekabooCore", targets: ["PeekabooCore"]),
        .library(name: "PeekabooRender", targets: ["PeekabooRender"]),
    ],
    targets: [
        // libjpeg-turbo (static, built by `mise run deps`): parallel CPU JPEG decoding with DCT scaling and ROI crops.
        .systemLibrary(name: "CTurboJPEG", path: "Sources/CTurboJPEG"),
        // Own C decoders where ImageIO is slow: PNG (system zlib) and the early rendition of progressive JPEGs.
        // SwiftPM builds release C at -Os, which leaves the unfilter's per-byte loops rolled (the left neighbours go
        // through memory): 24 MP PNG 158–167 ms, 143–154 ms at -O3 (one thread: 272 vs 202 ms).
        .target(name: "CPeekabooDecode", cSettings: [.unsafeFlags(["-O3"], .when(configuration: .release))],
                linkerSettings: [.linkedLibrary("z")]),
        // Decode tiers, tiered cache, prefetch scheduler, folder model, config/keymap. No AppKit.
        .target(
            name: "PeekabooCore",
            dependencies: ["CTurboJPEG", "CPeekabooDecode"],
            swiftSettings: speed,
            linkerSettings: [.unsafeFlags([Context.packageDirectory + "/.deps/libjpeg-turbo/lib/libturbojpeg.a"])]),
        // Metal renderer: textures, quality pyramid, resampling kernels, progressive refinement.
        .target(name: "PeekabooRender", dependencies: ["PeekabooCore"], swiftSettings: speed),
        // AppKit shell (programmatic; no storyboard, no SwiftUI).
        .executableTarget(name: "PeekabooApp", dependencies: ["PeekabooCore", "PeekabooRender"], swiftSettings: speed,
                          linkerSettings: linkedSDK),
        // Performance regression CLI.
        .executableTarget(name: "PeekabooBench", dependencies: ["PeekabooCore", "PeekabooRender"], swiftSettings: speed,
                          linkerSettings: linkedSDK),
        .testTarget(name: "PeekabooCoreTests", dependencies: ["PeekabooCore"]),
        .testTarget(name: "PeekabooRenderTests", dependencies: ["PeekabooRender"]),
        .testTarget(name: "PeekabooAppTests", dependencies: ["PeekabooApp"]),
    ],
    swiftLanguageModes: [.v5]
)
