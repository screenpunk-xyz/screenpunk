import XCTest
import Foundation
import CryptoKit
import Darwin
@testable import ScreenpunkBuildService

final class BuildJobsTests: XCTestCase {
    private func withFixture(script: String, duration: TimeInterval = 3,
                             run: (BuildJobs, BuildEnvelope, URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: "/private/tmp/screenpunk-f4-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let kit = root.appendingPathComponent("kits/fixture")
        try FileManager.default.createDirectory(at: kit.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: kit.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        // This system-Node link is confined to a test-injected verifier. Production
        // requires the exact signed, inherited pinned Node inside the sealed bundle.
        try FileManager.default.createSymbolicLink(at: kit.appendingPathComponent("bin/node"),
                                                   withDestinationURL: URL(fileURLWithPath: "/usr/local/bin/node"))
        try script.write(to: kit.appendingPathComponent("scripts/build.mjs"), atomically: true, encoding: .utf8)
        let jobs = BuildJobs(stagingRoot: root, kitRoot: root.appendingPathComponent("kits"),
                             maxDuration: duration, verifyKit: { _ in true })
        let request = BuildEnvelope(version: 1, projectID: "demo", jobID: "job-1", kitDirectory: "fixture",
                                    expectedSourceVersion: String(repeating: "a", count: 64))
        try run(jobs, request, root)
    }

    private func source(_ jobs: BuildJobs, _ request: BuildEnvelope) throws {
        try jobs.prepare(request)
        let bytes = Data("export {}".utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try jobs.upload(request.jobID, path: "src/main.tsx", offset: 0, bytes: bytes, finalSHA256: digest)
    }

    func testFixedScriptBuildAndChunkedResult() throws {
        try withFixture(script: """
        import fs from 'node:fs';
        fs.mkdirSync(process.argv[3], {recursive:true});
        fs.writeFileSync(process.argv[3] + '/index.html', 'fixture-result');
        """) { jobs, request, _ in
            try source(jobs, request)
            let result = try jobs.execute(request.jobID)
            XCTAssertEqual(result.code, "ok")
            XCTAssertEqual(result.files?.map(\.path), ["index.html"])
            XCTAssertEqual(try jobs.download(request.jobID, path: "index.html", offset: 0), Data("fixture-result".utf8))
            try jobs.release(request.jobID)
        }
    }

    func testFixedCompilerTemporarySiblingIsMonitoredAndCanPublish() throws {
        try withFixture(script: """
        import fs from 'node:fs';
        import path from 'node:path';
        const output = process.argv[3];
        const stage = fs.mkdtempSync(path.join(path.dirname(output), '.screenpunk-build-'));
        fs.writeFileSync(stage + '/index.html', 'fixture-result');
        await new Promise(resolve => setTimeout(resolve, 150));
        fs.renameSync(stage, output);
        """) { jobs, request, _ in
            try source(jobs, request)
            let result = try jobs.execute(request.jobID)
            XCTAssertEqual(result.code, "ok")
            XCTAssertEqual(result.files?.map(\.path), ["index.html"])
            try jobs.release(request.jobID)
        }
    }

    func testHugeLogAndOutputAbort() throws {
        for script in [
            "process.stdout.write('x'.repeat(2*1024*1024)); setTimeout(()=>{},10000);",
            "import fs from 'node:fs'; fs.mkdirSync(process.argv[3],{recursive:true}); fs.writeFileSync(process.argv[3]+'/huge.bin',Buffer.alloc(51*1024*1024));"
        ] {
            try withFixture(script: script) { jobs, request, _ in
                try source(jobs, request)
                XCTAssertThrowsError(try jobs.execute(request.jobID))
                try jobs.release(request.jobID)
            }
        }
    }

    func testCompilerFailureReturnsBoundedDiagnostic() throws {
        try withFixture(script: "console.error('synthetic compile failure'); process.exit(2);") { jobs, request, _ in
            try source(jobs, request)
            let response = try jobs.execute(request.jobID)
            XCTAssertEqual(response.code, "compiler_failed")
            XCTAssertTrue(response.diagnostics?.contains("synthetic compile failure") == true)
            try jobs.release(request.jobID)
        }
    }

    func testCompilerFailureDrainsFinalDiagnosticTail() throws {
        try withFixture(script: "import fs from 'node:fs'; fs.writeSync(2, 'x'.repeat(24*1024)); fs.writeSync(2, 'TAIL-END'); process.exit(2);") { jobs, request, _ in
            try source(jobs, request)
            let response = try jobs.execute(request.jobID)
            XCTAssertEqual(response.code, "compiler_failed")
            XCTAssertTrue(response.diagnostics?.hasSuffix("TAIL-END") == true)
            try jobs.release(request.jobID)
        }
    }

    func testOutputScanRejectsExcessiveNesting() throws {
        try withFixture(script: """
        import fs from 'node:fs';
        let p = process.argv[3];
        for (let i = 0; i < 33; i++) { p += '/d'; fs.mkdirSync(p, {recursive:true}); }
        fs.writeFileSync(p + '/tiny.txt', 'x');
        """) { jobs, request, _ in
            try source(jobs, request)
            XCTAssertThrowsError(try jobs.execute(request.jobID))
            try jobs.release(request.jobID)
        }
    }

    func testUploadAdmissionBoundsTotalDirectoriesAndFiles() throws {
        try withFixture(script: "") { jobs, request, _ in
            try jobs.prepare(request)
            let bytes = Data("x".utf8)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            var rejected = false
            for index in 0..<140 {
                let path = "p\(index)/" + Array(repeating: "d", count: 29).joined(separator: "/") + "/file.ts"
                do { try jobs.upload(request.jobID, path: path, offset: 0, bytes: bytes, finalSHA256: digest) }
                catch BuildJobError.quota { rejected = true; break }
            }
            XCTAssertTrue(rejected)
            try jobs.release(request.jobID)
        }
    }

    func testSourcePathLimitsRemainRelativeToSourceUnderStagePrefix() throws {
        let script = "import fs from 'node:fs'; fs.mkdirSync(process.argv[3],{recursive:true}); fs.writeFileSync(process.argv[3]+'/index.html','ok');"
        let bytes = Data("{}".utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        for components in [31, 32] {
            try withFixture(script: script) { jobs, request, _ in
                try source(jobs, request)
                let path = (["src"] + Array(repeating: "d", count: components - 2) + ["asset.json"]).joined(separator: "/")
                XCTAssertEqual(path.split(separator: "/").count, components)
                try jobs.upload(request.jobID, path: path, offset: 0, bytes: bytes, finalSHA256: digest)
                XCTAssertEqual(try jobs.execute(request.jobID).code, "ok")
                try jobs.release(request.jobID)
            }
        }
        try withFixture(script: script) { jobs, request, _ in
            try source(jobs, request)
            let path = (["src"] + Array(repeating: "d", count: 31) + ["asset.json"]).joined(separator: "/")
            XCTAssertEqual(path.split(separator: "/").count, 33)
            XCTAssertThrowsError(try jobs.upload(request.jobID, path: path,
                                                  offset: 0, bytes: bytes, finalSHA256: digest))
            try jobs.release(request.jobID)
        }
    }

    func testMaximumLengthSourcePathSurvivesStagePrefix() throws {
        let script = "import fs from 'node:fs'; fs.mkdirSync(process.argv[3],{recursive:true}); fs.writeFileSync(process.argv[3]+'/index.html','ok');"
        try withFixture(script: script) { jobs, request, _ in
            try source(jobs, request)
            let directories = ["src"] + Array(repeating: String(repeating: "d", count: 16), count: 22) +
                Array(repeating: String(repeating: "e", count: 15), count: 8)
            let path = (directories + ["a.json"]).joined(separator: "/")
            XCTAssertEqual(path.utf8.count, 512)
            XCTAssertEqual(path.split(separator: "/").count, 32)
            let bytes = Data("{}".utf8)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            try jobs.upload(request.jobID, path: path, offset: 0, bytes: bytes, finalSHA256: digest)
            XCTAssertEqual(try jobs.execute(request.jobID).code, "ok")
            try jobs.release(request.jobID)
        }
    }

    func testDeadlineKillsProcessGroup() throws {
        try withFixture(script: "setInterval(()=>{},1000);", duration: 0.15) { jobs, request, _ in
            try source(jobs, request)
            XCTAssertThrowsError(try jobs.execute(request.jobID))
            try jobs.release(request.jobID)
        }
    }

    func testChildReceivesOnlyFixedEnvironment() throws {
        try withFixture(script: """
        import fs from 'node:fs';
        fs.mkdirSync(process.argv[3],{recursive:true});
        fs.writeFileSync(process.argv[3]+'/env.json',JSON.stringify(process.env));
        """) { jobs, request, _ in
            try source(jobs, request)
            _ = try jobs.execute(request.jobID)
            let data = try jobs.download(request.jobID, path: "env.json", offset: 0)
            let environment = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
            XCTAssertTrue(Set(environment.keys).isSubset(of: ["HOME", "TMPDIR", "PATH", "NODE_ENV", "__CF_USER_TEXT_ENCODING"]))
            XCTAssertEqual(environment["NODE_ENV"], "production")
            XCTAssertNil(environment["NODE_OPTIONS"])
            XCTAssertNil(environment["AWS_SECRET_ACCESS_KEY"])
            try jobs.release(request.jobID)
        }
    }

    func testCancellationReapsRootAndDescendant() throws {
        try withFixture(script: """
        import fs from 'node:fs';
        import {spawn} from 'node:child_process';
        fs.mkdirSync(process.argv[3],{recursive:true});
        const child=spawn(process.execPath,['-e','setInterval(()=>{},1000)'],{stdio:'ignore'});
        fs.writeFileSync(process.argv[3]+'/child.pid',String(child.pid));
        setInterval(()=>{},1000);
        """, duration: 3) { jobs, request, root in
            try source(jobs, request)
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                _ = try? jobs.execute(request.jobID)
                finished.signal()
            }
            var childPID: Int32?
            let waitUntil = Date().addingTimeInterval(1)
            while childPID == nil && Date() < waitUntil {
                if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
                    for case let url as URL in walker where url.lastPathComponent == "child.pid" {
                        childPID = Int32((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                    }
                }
                if childPID == nil { Thread.sleep(forTimeInterval: 0.02) }
            }
            XCTAssertNotNil(childPID)
            try jobs.cancel(request.jobID)
            XCTAssertEqual(finished.wait(timeout: .now() + .seconds(2)), .success)
            if let childPID {
                XCTAssertNotEqual(kill(childPID, 0), 0)
            }
            try jobs.release(request.jobID)
        }
    }

    func testRootExitWaitsForDescendantBeforePublishing() throws {
        try withFixture(script: """
        import fs from 'node:fs';
        import {spawn} from 'node:child_process';
        fs.mkdirSync(process.argv[3], {recursive:true});
        const child=spawn(process.execPath,['-e','setInterval(()=>{},1000)'],{stdio:'ignore'});
        fs.writeFileSync(process.argv[3]+'/child.pid',String(child.pid));
        process.exit(0);
        """) { jobs, request, _ in
            try source(jobs, request)
            let result = try jobs.execute(request.jobID)
            XCTAssertEqual(result.code, "ok")
            let childPID = Int32(String(decoding: try jobs.download(request.jobID, path: "child.pid", offset: 0), as: UTF8.self))
            XCTAssertNotNil(childPID)
            if let childPID { XCTAssertNotEqual(kill(childPID, 0), 0) }
            try jobs.release(request.jobID)
        }
    }
}
