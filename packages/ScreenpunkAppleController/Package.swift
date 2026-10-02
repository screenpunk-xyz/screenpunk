// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScreenpunkAppleController",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ScreenpunkAppleController", targets: ["ScreenpunkAppleController"])
    ],
    dependencies: [
        .package(path: "../ScreenpunkCore"),
        .package(path: "../ScreenpunkController"),
        .package(path: "../ScreenpunkApple")
    ],
    targets: [
        .target(
            name: "ScreenpunkAppleController",
            dependencies: ["ScreenpunkCore", "ScreenpunkController", "ScreenpunkApple"]
        ),
        .testTarget(
            name: "ScreenpunkAppleControllerTests",
            dependencies: ["ScreenpunkAppleController", "ScreenpunkController", "ScreenpunkCore"]
        )
    ]
)
