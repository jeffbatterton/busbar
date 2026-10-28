// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Busbar",
    platforms: [.macOS(.v15)],
    targets: [
        // UI-free logic: EcoFlow API, parsing, alerts. Kept separate so a future
        // iOS app or history logger can reuse it.
        .target(name: "BusbarCore"),
        .executableTarget(name: "Busbar", dependencies: ["BusbarCore"]),
        .testTarget(name: "BusbarCoreTests", dependencies: ["BusbarCore"]),
    ]
)
