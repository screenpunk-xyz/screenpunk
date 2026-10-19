// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScreenpunkCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "ScreenpunkCore", targets: ["ScreenpunkCore"])
    ],
    targets: [
        .target(name: "CNativeArchive", publicHeadersPath: "include", linkerSettings: [.linkedLibrary("z", .when(platforms: [.iOS, .macOS]))]),
        .target(name: "ScreenpunkCore", dependencies: ["CNativeArchive"]),
        .testTarget(name: "ScreenpunkCoreTests", dependencies: ["ScreenpunkCore"], resources: [.copy("Fixtures/native-sign-in-fixtures.json"), .copy("Fixtures/native-delivery-codec-fixtures.json"), .copy("Fixtures/resulting-set-codec-fixtures.json")])
    ]
)
