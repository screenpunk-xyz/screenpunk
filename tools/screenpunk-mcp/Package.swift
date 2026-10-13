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
        .package(path: "../../packages/ScreenpunkBrokerMCP"),
        // 0.12 includes the upstream NetworkTransport actor-isolation race fix;
        // pin it for the normal Swift 6 dependency build rather than lowering compiler checks.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")
    ],
    targets: [
        .executableTarget(
            name: "screenpunk-mcp",
            dependencies: [
                "ScreenpunkCore",
                "ScreenpunkApple",
                "ScreenpunkController",
                "ScreenpunkBrokerMCP",
                .product(name: "MCP", package: "swift-sdk")
            ]
        ),
        .testTarget(
            name: "screenpunk-mcp-tests",
            dependencies: ["screenpunk-mcp", "ScreenpunkController", "ScreenpunkBrokerMCP"]
        )
    ]
)
