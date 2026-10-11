import XCTest
import Foundation
@testable import ScreenpunkController

final class OfflineBuildInputPlanTests: XCTestCase {
    private func fixture(_ work: (URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: "/private/tmp/screenpunk-input-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "export {}".write(to: root.appendingPathComponent("src/main.tsx"), atomically: true, encoding: .utf8)
        try work(root)
    }

    func testFrozenBytesAndOutsideLinkRejection() throws {
        try fixture { root in
            let plan = try OfflineBuildInputPlan.capture(root)
            XCTAssertEqual(plan.files.map(\.relativePath), ["src/main.tsx"])
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("src/external.ts"),
                                                       withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
            XCTAssertThrowsError(try OfflineBuildInputPlan.capture(root))
        }
    }

    func testProjectConfigCannotEnterTransfer() throws {
        for name in ["tsconfig.json", "TSConfig.JSON", "package.json", "src/evil.config.ts", "src/outside.sh"] {
            try fixture { root in
                try "{}".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
                XCTAssertThrowsError(try OfflineBuildInputPlan.capture(root))
            }
        }
    }

    func testCaptureUsesProjectRelativeComponentAndByteLimits() throws {
        for components in [31, 32, 33] {
            try fixture { root in
                let parts = ["src"] + Array(repeating: "d", count: components - 2) + ["asset.json"]
                let relative = parts.joined(separator: "/")
                XCTAssertEqual(parts.count, components)
                let file = root.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try "{}".write(to: file, atomically: true, encoding: .utf8)
                if components <= 32 {
                    let plan = try OfflineBuildInputPlan.capture(root)
                    XCTAssertTrue(plan.files.contains { $0.relativePath == relative })
                } else {
                    XCTAssertThrowsError(try OfflineBuildInputPlan.capture(root))
                }
            }
        }
        try fixture { root in
            let directories = ["src"] + Array(repeating: String(repeating: "d", count: 16), count: 22) +
                Array(repeating: String(repeating: "e", count: 15), count: 8)
            let relative = (directories + ["a.json"]).joined(separator: "/")
            XCTAssertEqual(relative.utf8.count, 512)
            XCTAssertEqual(relative.split(separator: "/").count, 32)
            let file = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try "{}".write(to: file, atomically: true, encoding: .utf8)
            let plan = try OfflineBuildInputPlan.capture(root)
            XCTAssertTrue(plan.files.contains { $0.relativePath == relative })
        }
    }

    func testDepthEntryBudgetAndCancellationApplyBeforeFiles() throws {
        try fixture { root in
            var deep = root.appendingPathComponent("src")
            for _ in 0..<32 { deep.appendPathComponent("d") }
            try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
            XCTAssertThrowsError(try OfflineBuildInputPlan.capture(root))
        }
        try fixture { root in
            let directory = root.appendingPathComponent("src")
            for index in 0..<4000 {
                try FileManager.default.createDirectory(at: directory.appendingPathComponent("d\(index)"),
                                                        withIntermediateDirectories: false)
            }
            XCTAssertThrowsError(try OfflineBuildInputPlan.capture(root)) { error in
                guard case OfflineBuildInputError.limitExceeded = error else {
                    XCTFail("Expected total-entry limit, got \(error)"); return
                }
            }
        }
        try fixture { root in
            XCTAssertThrowsError(try OfflineBuildInputPlan.capture(root, cancelled: { true }))
            XCTAssertThrowsError(try OfflineBuildInputPlan.capture(root,
                deadline: ProcessInfo.processInfo.systemUptime - 1))
        }
    }
}
