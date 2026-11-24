// swift-tools-version: 6.0
import PackageDescription

// Release builds favour raw speed: whole-module optimisation is the SwiftPM
// release default; exclusivity checks are dropped because the hot paths are
// audited single-owner buffers.
let speed: [SwiftSetting] = [
    .unsafeFlags(["-enforce-exclusivity=unchecked"], .when(configuration: .release)),
]

let package = Package(
    name: "Peekaboo",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Peekaboo", targets: ["PeekabooApp"]),
        .executable(name: "peekaboo-bench", targets: ["PeekabooBench"]),
        .library(name: "PeekabooCore", targets: ["PeekabooCore"]),
        .library(name: "PeekabooRender", targets: ["PeekabooRender"]),
    ],
    targets: [
        // Decode tiers, tiered cache, prefetch scheduler, folder model, config/keymap. No AppKit.
        .target(name: "PeekabooCore", swiftSettings: speed),
        // Metal renderer: textures, quality pyramid, resampling kernels, progressive refinement.
        .target(name: "PeekabooRender", dependencies: ["PeekabooCore"], swiftSettings: speed),
        // AppKit shell (programmatic; no storyboard, no SwiftUI).
        .executableTarget(name: "PeekabooApp", dependencies: ["PeekabooCore", "PeekabooRender"], swiftSettings: speed),
        // Performance regression CLI.
        .executableTarget(name: "PeekabooBench", dependencies: ["PeekabooCore", "PeekabooRender"], swiftSettings: speed),
        .testTarget(name: "PeekabooCoreTests", dependencies: ["PeekabooCore"]),
        .testTarget(name: "PeekabooRenderTests", dependencies: ["PeekabooRender"]),
    ],
    swiftLanguageModes: [.v5]
)
