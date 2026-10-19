// swift-tools-version: 5.9
import PackageDescription

// Includes package lifecycle ownership and Homebrew commit evidence.

let package = Package(
    name: "ScreenpunkDistribution",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ScreenpunkDistribution", targets: ["ScreenpunkDistribution"]),
        .executable(name: "screenpunk-package", targets: ["screenpunk-package"])
    ],
    targets: [
        .target(name: "ScreenpunkDistribution"),
        .executableTarget(name: "screenpunk-package", dependencies: ["ScreenpunkDistribution"]),
        .testTarget(name: "ScreenpunkDistributionTests", dependencies: ["ScreenpunkDistribution"])
    ]
)
