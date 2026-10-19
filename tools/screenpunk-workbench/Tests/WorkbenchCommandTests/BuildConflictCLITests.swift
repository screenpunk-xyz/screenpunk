import XCTest
import Foundation
import ScreenpunkController
@testable import WorkbenchCommand

final class BuildConflictCLITests: XCTestCase {
    func testPublicCLIReportsSourceAndHeadConflictsAndAcceptsFreshInputs() throws {
        let root = URL(fileURLWithPath: "/private/tmp/sp-cli-build-conflict-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("runtime")
        let home = root.appendingPathComponent("home")
        let host = try WorkbenchServiceHost(
            broker: WorkbenchBrokerEnvironment(runtimeDirectory: runtime), home: home,
            documents: CLIWorkspaceDocuments(environment: [
                "SCREENPUNK_DOCUMENTS_DIRECTORY": root.appendingPathComponent("Documents").path]),
            ownerCheck: {}, nativeFactory: { _ in nil })
        defer { host.stop() }
        var binary = ProcessInfo.processInfo.environment["SP_CLI_TEST_EXECUTABLE"].map {
            URL(fileURLWithPath: $0)
        }
        var candidate = Bundle(for: Self.self).bundleURL
        for _ in 0..<7 where binary == nil {
            let path = candidate.appendingPathComponent("screenpunk")
            if FileManager.default.isExecutableFile(atPath: path.path) { binary = path }
            candidate.deleteLastPathComponent()
        }
        let executable = try XCTUnwrap(binary)
        func run(_ words: [String], status: Int32 = 0) throws -> [String: Any] {
            let output = root.appendingPathComponent(UUID().uuidString + ".json")
            XCTAssertTrue(FileManager.default.createFile(atPath: output.path, contents: nil))
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            let process = Process()
            process.executableURL = executable
            process.environment = ["PATH": "/usr/bin:/bin",
                "SCREENPUNK_DOCUMENTS_DIRECTORY": root.appendingPathComponent("Documents").path]
            process.arguments = words + ["--json", "--no-input", "--home", home.path,
                "--runtime-directory", runtime.path]
            process.standardOutput = handle; process.standardError = handle
            try process.run(); process.waitUntilExit()
            let bytes = try Data(contentsOf: output)
            XCTAssertEqual(process.terminationStatus, status, String(decoding: bytes, as: UTF8.self))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        }
        func result(_ words: [String]) throws -> [String: Any] {
            try XCTUnwrap(run(words)["result"] as? [String: Any])
        }
        _ = try result(["workspace", "init", root.appendingPathComponent("visible").path])
        let created = try XCTUnwrap(result(["project", "create", "Phone"])["project"] as? [String: Any])
        let project = try XCTUnwrap(created["project"] as? [String: Any])
        let id = try XCTUnwrap(project["projectId"] as? String)
        let oldSource = try XCTUnwrap(created["sourceVersion"] as? String)
        let first = try XCTUnwrap(result(["build", "run", id, oldSource])["build"] as? [String: Any])
        let base = try XCTUnwrap(first["revision"] as? String)
        let input = root.appendingPathComponent("formatted.html")
        try Data("<html>formatted source</html>".utf8).write(to: input)
        let edited = try XCTUnwrap(result(["project", "edit", id, oldSource,
            "web/index.html", input.path])["project"] as? [String: Any])
        let source = try XCTUnwrap(edited["sourceVersion"] as? String)
        XCTAssertNotEqual(source, oldSource)
        let stale = try XCTUnwrap(run(["build", "run", id, oldSource, base], status: 6)["error"] as? [String: Any])
        XCTAssertEqual(stale["code"] as? String, "build_source_conflict")
        let missing = try XCTUnwrap(run(["build", "run", id, source], status: 6)["error"] as? [String: Any])
        XCTAssertEqual(missing["code"] as? String, "build_head_conflict")
        let unchanged = try XCTUnwrap(result(["build", "head", id])["build"] as? [String: Any])
        XCTAssertEqual(unchanged["revision"] as? String, base)
        let fresh = try XCTUnwrap(result(["build", "run", id, source, base])["build"] as? [String: Any])
        XCTAssertEqual(fresh["sourceVersion"] as? String, source)
        XCTAssertNotEqual(fresh["revision"] as? String, base)
    }
}
