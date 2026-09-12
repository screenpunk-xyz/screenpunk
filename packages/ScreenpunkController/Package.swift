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
            dependencies: ["ScreenpunkCore"],
            resources: [
                .copy("Resources/help.json"),
                .copy("Resources/mcp-catalog.json")
            ]
        ),
        .testTarget(
            name: "ScreenpunkControllerTests",
            dependencies: ["ScreenpunkController"]
        )
    ]
)
