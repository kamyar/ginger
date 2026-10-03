// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Ginger",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Ginger", targets: ["Ginger"])],
    targets: [
        .target(name: "GingerCore"),
        .executableTarget(name: "Ginger", dependencies: ["GingerCore"]),
        .testTarget(name: "GingerCoreTests", dependencies: ["GingerCore"]),
        .testTarget(name: "GingerTests", dependencies: ["Ginger", "GingerCore"])
    ]
)
