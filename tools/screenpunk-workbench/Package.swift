// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScreenpunkWorkbench",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "screenpunk", targets: ["screenpunk"]),
        .executable(name: "screenpunk-service", targets: ["screenpunk-service"]),
        .executable(name: "screenpunk-mcp", targets: ["screenpunk-mcp"])
    ],
    dependencies: [.package(path: "../../packages/ScreenpunkController"),
                   .package(path: "../../packages/ScreenpunkApple"),
                   .package(path: "../../packages/ScreenpunkCore"),
                   .package(path: "../../packages/ScreenpunkBrokerMCP"),
                   .package(path: "../screenpunk-distribution")],
    targets: [
        .target(name: "WorkbenchCommand", dependencies: ["ScreenpunkController", "ScreenpunkApple", "ScreenpunkCore", "ScreenpunkBrokerMCP", .product(name: "ScreenpunkDistribution", package: "screenpunk-distribution")]),
        .executableTarget(name: "screenpunk", dependencies: ["WorkbenchCommand"]),
        .executableTarget(name: "screenpunk-service", dependencies: ["WorkbenchCommand"]),
        .executableTarget(name: "screenpunk-mcp", dependencies: ["WorkbenchCommand"]),
        .testTarget(name: "WorkbenchCommandTests", dependencies: ["WorkbenchCommand", .product(name: "ScreenpunkDistribution", package: "screenpunk-distribution")])
    ]
)
