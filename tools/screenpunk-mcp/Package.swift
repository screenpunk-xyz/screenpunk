// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "screenpunk-mcp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "screenpunk-mcp", targets: ["screenpunk-mcp"])
    ],
    dependencies: [
        .package(path: "../../packages/ScreenpunkCore")
    ],
    targets: [
        .executableTarget(
            name: "screenpunk-mcp",
            dependencies: ["ScreenpunkCore"]
        )
    ]
)
