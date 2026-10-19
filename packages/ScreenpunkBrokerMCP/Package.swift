// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScreenpunkBrokerMCP",
    platforms: [.macOS(.v13)],
    products: [.library(name: "ScreenpunkBrokerMCP", targets: ["ScreenpunkBrokerMCP"])],
    dependencies: [
        .package(path: "../ScreenpunkController"),
        .package(path: "../ScreenpunkCore")
    ],
    targets: [
        .target(name: "ScreenpunkBrokerMCP", dependencies: ["ScreenpunkController", "ScreenpunkCore"])
    ]
)
