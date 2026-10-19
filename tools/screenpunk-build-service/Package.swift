// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScreenpunkBuildService",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ScreenpunkBuildService", targets: ["ScreenpunkBuildService"])],
    targets: [
        .target(name: "BuildSpawn", publicHeadersPath: "include"),
        .executableTarget(name: "ScreenpunkBuildService", dependencies: ["BuildSpawn"]),
        .testTarget(name: "ScreenpunkBuildServiceTests", dependencies: ["ScreenpunkBuildService"])
    ]
)
