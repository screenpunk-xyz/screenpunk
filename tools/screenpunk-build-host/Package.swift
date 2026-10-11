// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScreenpunkBuildHost",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ScreenpunkBuildHost", targets: ["ScreenpunkBuildHost"])],
    targets: [.executableTarget(name: "ScreenpunkBuildHost")]
)
