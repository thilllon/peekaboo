// swift-tools-version: 6.2
import PackageDescription

// Release builds favour raw speed: whole-module optimisation is the SwiftPM
// release default; exclusivity checks are dropped because the hot paths are
// audited single-owner buffers.
let speed: [SwiftSetting] = [
    .unsafeFlags(["-enforce-exclusivity=unchecked"], .when(configuration: .release)),
]

let package = Package(
    name: "Peekaboo",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Peekaboo", targets: ["PeekabooApp"]),
        .executable(name: "peekaboo-bench", targets: ["PeekabooBench"]),
        .library(name: "PeekabooCore", targets: ["PeekabooCore"]),
        .library(name: "PeekabooRender", targets: ["PeekabooRender"]),
    ],
    targets: [
        // libjpeg-turbo (static): parallel CPU JPEG decoding with DCT scaling and ROI crops.
        .systemLibrary(name: "CTurboJPEG", path: "Sources/CTurboJPEG"),
        // Own C decoders where ImageIO is slow: PNG (system zlib) and the early rendition of progressive JPEGs.
        // SwiftPM builds release C at -Os, which leaves the unfilter's per-byte loops rolled (the left neighbours go
        // through memory): 24 MP PNG 158–165 vs 138–143 ms at -O3 with two threads, 272 vs 202 ms with one.
        .target(name: "CPeekabooDecode", cSettings: [.unsafeFlags(["-O3"], .when(configuration: .release))],
                linkerSettings: [.linkedLibrary("z")]),
        // Decode tiers, tiered cache, prefetch scheduler, folder model, config/keymap. No AppKit.
        .target(
            name: "PeekabooCore",
            dependencies: ["CTurboJPEG", "CPeekabooDecode"],
            swiftSettings: speed,
            linkerSettings: [.unsafeFlags(["/opt/homebrew/opt/jpeg-turbo/lib/libturbojpeg.a"])]),
        // Metal renderer: textures, quality pyramid, resampling kernels, progressive refinement.
        .target(name: "PeekabooRender", dependencies: ["PeekabooCore"], swiftSettings: speed),
        // AppKit shell (programmatic; no storyboard, no SwiftUI).
        .executableTarget(name: "PeekabooApp", dependencies: ["PeekabooCore", "PeekabooRender"], swiftSettings: speed),
        // Performance regression CLI.
        .executableTarget(name: "PeekabooBench", dependencies: ["PeekabooCore", "PeekabooRender"], swiftSettings: speed),
        .testTarget(name: "PeekabooCoreTests", dependencies: ["PeekabooCore"]),
        .testTarget(name: "PeekabooRenderTests", dependencies: ["PeekabooRender"]),
        .testTarget(name: "PeekabooAppTests", dependencies: ["PeekabooApp"]),
    ],
    swiftLanguageModes: [.v5]
)
