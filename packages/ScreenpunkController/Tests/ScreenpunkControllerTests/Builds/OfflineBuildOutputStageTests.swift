import XCTest
import Foundation
import CryptoKit
@testable import ScreenpunkController

final class OfflineBuildOutputStageTests: XCTestCase {
    private func fixture(_ work: (URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: "/private/tmp/screenpunk-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try work(root)
    }

    func testFailurePreservesExistingPackageAndCleansPartialStage() throws {
        try fixture { root in
            let destination = root.appendingPathComponent("package")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let prior = destination.appendingPathComponent("index.html")
            try Data("prior".utf8).write(to: prior)
            let bytes = Data("new".utf8)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let manifest = [OfflineBuildOutputFile(path: "index.html", bytes: Int64(bytes.count), sha256: digest)]
            XCTAssertThrowsError(try OfflineBuildOutputStage.save(manifest, to: destination) { _, _ in
                XCTFail("Existing destination must be rejected before transfer")
                return bytes
            })
            XCTAssertEqual(try Data(contentsOf: prior), Data("prior".utf8))

            let brokenLink = root.appendingPathComponent("broken-package")
            try FileManager.default.createSymbolicLink(at: brokenLink,
                                                       withDestinationURL: root.appendingPathComponent("missing-target"))
            XCTAssertThrowsError(try OfflineBuildOutputStage.save(manifest, to: brokenLink) { _, _ in bytes })
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: brokenLink.path),
                           root.appendingPathComponent("missing-target").path)

            let absent = root.appendingPathComponent("new-package")
            let wrong = [OfflineBuildOutputFile(path: "index.html", bytes: Int64(bytes.count),
                                                sha256: String(repeating: "0", count: 64))]
            XCTAssertThrowsError(try OfflineBuildOutputStage.save(wrong, to: absent) { _, _ in bytes })
            XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path)
                .contains(where: { $0.hasPrefix(".screenpunk-build-") }))
        }
    }

    func testValidBytesPublishOnlyAfterHashCheck() throws {
        try fixture { root in
            let destination = root.appendingPathComponent("package")
            let bytes = Data("validated output".utf8)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let manifest = [OfflineBuildOutputFile(path: "assets/output.css", bytes: Int64(bytes.count), sha256: digest)]
            try OfflineBuildOutputStage.save(manifest, to: destination) { _, offset in
                bytes.subdata(in: Int(offset)..<min(bytes.count, Int(offset) + 3))
            }
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("assets/output.css")), bytes)
        }
    }
}
