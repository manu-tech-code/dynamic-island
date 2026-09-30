// swift-tools-version: 6.0
// Phase 0 spikes: throwaway apps that answer the four open technical questions
// before Phase 1 starts. See RESULTS.md for what each one found.
import PackageDescription

let package = Package(
    name: "IslandSpikes",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "NotchGlassSpike", targets: ["NotchGlassSpike"]),
        .executable(name: "NowPlayingSpike", targets: ["NowPlayingSpike"]),
        .executable(name: "ClipboardSpike", targets: ["ClipboardSpike"]),
        .library(name: "NowPlayingBridge", type: .dynamic, targets: ["NowPlayingBridge"]),
    ],
    targets: [
        .executableTarget(name: "NotchGlassSpike", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "NowPlayingSpike", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "ClipboardSpike", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "NowPlayingBridge",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("Foundation")]
        ),
    ]
)
