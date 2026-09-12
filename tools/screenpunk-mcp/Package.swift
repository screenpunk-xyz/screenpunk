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
        .package(path: "../../packages/ScreenpunkCore"),
        .package(path: "../../packages/ScreenpunkApple"),
        .package(path: "../../packages/ScreenpunkController"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.10.2")
    ],
    targets: [
        .executableTarget(
            name: "screenpunk-mcp",
            dependencies: [
                "ScreenpunkCore",
                "ScreenpunkApple",
                "ScreenpunkController",
                .product(name: "MCP", package: "swift-sdk")
            ]
        )
    ]
)
