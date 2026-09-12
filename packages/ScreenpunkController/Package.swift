// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScreenpunkController",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "ScreenpunkController", targets: ["ScreenpunkController"])
    ],
    dependencies: [
        .package(path: "../ScreenpunkCore")
    ],
    targets: [
        .target(
            name: "ScreenpunkController",
            dependencies: ["ScreenpunkCore"]
        ),
        .testTarget(
            name: "ScreenpunkControllerTests",
            dependencies: ["ScreenpunkController"]
        )
    ]
)
