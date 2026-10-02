import XCTest
import Foundation
import Darwin
@testable import ScreenpunkDistribution

final class HomebrewCommitEvidenceTests: XCTestCase {
    private final class Fixture {
        let base: URL
        let root: URL
        let metadata: URL
        let bin: URL
        let state: URL
        let directory: Int32
        let evidence: HomebrewCommitEvidence
        init() throws {
            base = URL(fileURLWithPath: "/private/tmp/sp-brew-commit-" + UUID().uuidString)
            root = base.appendingPathComponent("Caskroom/screenpunk-cli/1.0.1/Screenpunk CLI 1.0.1")
            metadata = base.appendingPathComponent("Caskroom/screenpunk-cli/.metadata")
            bin = base.appendingPathComponent("bin")
            state = base.appendingPathComponent("state")
            for path in [root.appendingPathComponent("bin"), metadata, bin, state] {
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            for name in ["screenpunk", "screenpunk-mcp"] {
                try Data("fixture".utf8).write(to: root.appendingPathComponent("bin/" + name))
            }
            directory = open(state.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { throw DistributionError.unavailable }
            evidence = HomebrewCommitEvidence(root: root, version: "1.0.1", metadata: metadata, bin: bin)
        }
        deinit { close(directory); try? FileManager.default.removeItem(at: base) }
        func link(_ name: String) throws {
            try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent(name),
                withDestinationURL: root.appendingPathComponent("bin/" + name))
        }
        func config() throws {
            try Data("{}".utf8).write(to: metadata.appendingPathComponent("config.json"), options: .atomic)
        }
        func receipt(version: String = "1.0.1") throws {
            let bytes = try JSONSerialization.data(withJSONObject: ["arch": "arm64", "source": ["version": version],
                "uninstall_artifacts": [
                    ["binary": ["Screenpunk CLI \(version)/bin/screenpunk"]],
                    ["binary": ["Screenpunk CLI \(version)/bin/screenpunk-mcp"]]
                ]])
            try bytes.write(to: metadata.appendingPathComponent("INSTALL_RECEIPT.json"), options: .atomic)
        }
    }
    func testFirstLinkExposureAndFailedSecondArtifactCannotStartBeforeCommit() throws {
        let f = try Fixture()
        try f.config(); try f.receipt(version: "1.0.0")
        try f.evidence.prepareInstall(stateDirectory: f.directory)
        try f.link("screenpunk")
        XCTAssertThrowsError(try f.evidence.assertReady(stateDirectory: f.directory))
        try f.link("screenpunk-mcp")
        XCTAssertThrowsError(try f.evidence.assertReady(stateDirectory: f.directory))
        try f.config() // all artifacts completed; old receipt still blocks new version
        XCTAssertThrowsError(try f.evidence.assertReady(stateDirectory: f.directory))
        try f.receipt()
        XCTAssertNoThrow(try f.evidence.assertReady(stateDirectory: f.directory))
    }
    func testSameVersionReinstallRequiresNewCompletedArtifactConfig() throws {
        let f = try Fixture()
        try f.config(); try f.receipt(); try f.link("screenpunk"); try f.link("screenpunk-mcp")
        try f.evidence.prepareInstall(stateDirectory: f.directory)
        XCTAssertThrowsError(try f.evidence.assertReady(stateDirectory: f.directory))
        try f.config()
        XCTAssertNoThrow(try f.evidence.assertReady(stateDirectory: f.directory))
    }
    func testFreshInstallNeedsGateAndReceiptAndBothLinks() throws {
        let f = try Fixture()
        XCTAssertThrowsError(try f.evidence.assertReady(stateDirectory: f.directory))
        try f.evidence.prepareInstall(stateDirectory: f.directory)
        try f.config(); try f.link("screenpunk"); try f.link("screenpunk-mcp")
        XCTAssertThrowsError(try f.evidence.assertReady(stateDirectory: f.directory))
        try f.receipt()
        XCTAssertNoThrow(try f.evidence.assertReady(stateDirectory: f.directory))
        try FileManager.default.removeItem(at: f.bin.appendingPathComponent("screenpunk-mcp"))
        XCTAssertThrowsError(try f.evidence.assertReady(stateDirectory: f.directory))
    }
}
