// swift-tools-version: 6.2
// Pure, UI-free logic for the island: activity model, ranking, layout metrics,
// settings, notch math and parsers. Tested with `swift test` without launching the app.
import PackageDescription

let package = Package(
    name: "IslandKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "IslandCore", targets: ["IslandCore"]),
    ],
    targets: [
        .target(name: "IslandCore"),
        .testTarget(name: "IslandCoreTests", dependencies: ["IslandCore"]),
    ]
)
