// swift-tools-version: 5.9
import PackageDescription
import Foundation

let ownershipInfo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("OwnershipInfo.plist").path
let ownershipLinkerSettings: [LinkerSetting] = [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", ownershipInfo])]

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
        .executableTarget(name: "screenpunk", dependencies: ["WorkbenchCommand"], linkerSettings: ownershipLinkerSettings),
        .executableTarget(name: "screenpunk-service", dependencies: ["WorkbenchCommand"], linkerSettings: ownershipLinkerSettings),
        .executableTarget(name: "screenpunk-mcp", dependencies: ["WorkbenchCommand"], linkerSettings: ownershipLinkerSettings),
        .testTarget(name: "WorkbenchCommandTests", dependencies: ["WorkbenchCommand", .product(name: "ScreenpunkDistribution", package: "screenpunk-distribution")])
    ]
)
