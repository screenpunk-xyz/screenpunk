#if os(macOS)
import XCTest
import Foundation
import Darwin
@testable import ScreenpunkController

final class WorkbenchHealthBrokerTests: XCTestCase {
    private func environment(timeout: TimeInterval = 1, connections: Int = 32, frame: Int = 8 * 1024 * 1024,
                             staging: Int = 64 * 1024 * 1024, peers: any WorkbenchPeerCredentials = WorkbenchSystemPeerCredentials()) throws -> WorkbenchBrokerEnvironment {
        try WorkbenchBrokerEnvironment(runtimeDirectory: URL(fileURLWithPath: "/private/tmp/sp-wb-" + UUID().uuidString.prefix(12)),
            limits: WorkbenchIPCLimits(maxFrameBytes: frame, maxConnections: connections, maxStagingBytes: staging, timeout: timeout), peerCredentials: peers)
    }
    private func cleanup(_ env: WorkbenchBrokerEnvironment) { try? FileManager.default.removeItem(at: env.runtimeDirectory) }
    private func code(_ expected: WorkbenchIPCErrorCode, _ action: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) { XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, expected, file: file, line: line) }
    }
    private func until(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let end = ProcessInfo.processInfo.systemUptime + 2
        while !predicate() && ProcessInfo.processInfo.systemUptime < end { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertTrue(predicate(), file: file, line: line)
    }
    private func raw(_ env: WorkbenchBrokerEnvironment) throws -> Int32 {
        let fd = try WorkbenchSocket.make()
        do {
            let result = try WorkbenchSocket.address(env.runtimeDirectory.appendingPathComponent("broker.sock").path) { Darwin.connect(fd, $0, $1) }
            if result != 0 {
                guard errno == EINPROGRESS || errno == EAGAIN else { throw WorkbenchIPCError(.unavailable) }
                try WorkbenchSocket.wait(fd, events: Int16(POLLOUT), deadline: env.clock.now() + env.limits.timeout, clock: env.clock)
            }
            return fd
        } catch { Darwin.close(fd); throw error }
    }
    private func send(_ fd: Int32, _ object: [String: Any], _ env: WorkbenchBrokerEnvironment) throws {
        try WorkbenchSocket.writeFrame(fd, bytes: JSONSerialization.data(withJSONObject: object), environment: env)
    }
    private func response(_ fd: Int32, _ env: WorkbenchBrokerEnvironment) throws -> WorkbenchWireResponse {
        try JSONDecoder().decode(WorkbenchWireResponse.self, from: WorkbenchSocket.readFrame(fd, environment: env))
    }
    private func authenticate(_ fd: Int32, _ env: WorkbenchBrokerEnvironment, hello: Bool = true) throws {
        let dir = try WorkbenchRuntimeDirectory(environment: env, create: false)
        try send(fd, ["apiVersion": "1.0", "instanceId": dir.locator().instanceId, "token": dir.read("broker.token", maxBytes: 32).base64EncodedString()], env)
        XCTAssertTrue(try response(fd, env).ok)
        if hello { try send(fd, ["apiVersion": "1.0", "requestId": "hello", "method": "system.hello", "params": [:]], env); XCTAssertTrue(try response(fd, env).ok) }
    }

    func testActualSocketPeerUIDsAndHonestSnapshots() throws {
        let peers = CountingPeers(); let env = try environment(peers: peers)
        defer { cleanup(env) }
        let server = WorkbenchBrokerServer(environment: env); let started = try server.start(); defer { server.stop() }
        let client = WorkbenchBrokerClient(environment: env); try client.connect(); defer { client.close() }
        XCTAssertEqual(try client.hello(), started); XCTAssertEqual(try client.capabilities(), started); XCTAssertEqual(try client.health(), started)
        XCTAssertEqual(started.supportedMethods, WorkbenchMethodRegistry.supportedMethods)
        XCTAssertEqual(started.workspaceState, "unconfigured"); XCTAssertEqual(started.build, "unavailable")
        XCTAssertEqual(started.devices, "unavailable"); XCTAssertEqual(started.screenshots, "unavailable")
        XCTAssertGreaterThanOrEqual(peers.calls, 2) // real getpeereid on server AND client
        let files = Set(try FileManager.default.contentsOfDirectory(atPath: env.runtimeDirectory.path))
        XCTAssertEqual(files, ["broker.sock", "broker.token", "broker.local-token", "broker.locator.json", "broker.lock"])
    }
    func testClientRejectsWrongServerUIDBeforeReadingTokenBytes() throws {
        let env = try environment(); defer { cleanup(env) }
        let server = WorkbenchBrokerServer(environment: env); try server.start(); defer { server.stop() }
        // Oversized token would fail a token read; wrong peer must fail first.
        let fd = open(env.runtimeDirectory.appendingPathComponent("broker.token").path, O_WRONLY | O_TRUNC)
        XCTAssertGreaterThanOrEqual(fd, 0); var byte: UInt8 = 42
        for _ in 0..<33 { _ = Darwin.write(fd, &byte, 1) }; Darwin.close(fd)
        let bad = try WorkbenchBrokerEnvironment(runtimeDirectory: env.runtimeDirectory, limits: env.limits,
                                                 peerCredentials: FixedPeers(uid: geteuid() + 1))
        let client = WorkbenchBrokerClient(environment: bad)
        code(.unauthorizedPeer) { try client.connect() }
    }
    func testServerRejectsWrongClientUIDBeforeAuthentication() throws {
        let env = try environment(peers: FixedPeers(uid: geteuid() + 1)); defer { cleanup(env) }
        let server = WorkbenchBrokerServer(environment: env); try server.start(); defer { server.stop() }
        let fd = try raw(env); defer { Darwin.close(fd) }
        code(.disconnected) { _ = try WorkbenchSocket.readFrame(fd, environment: env) }
    }
    func testWrongTokenAndProtocolReject() throws {
        let env = try environment(); defer { cleanup(env) }
        let server = WorkbenchBrokerServer(environment: env); try server.start(); defer { server.stop() }
        let dir = try WorkbenchRuntimeDirectory(environment: env, create: false)
        for (version, token, expected) in [("1.0", Data(repeating: 0, count: 32), WorkbenchIPCErrorCode.authenticationFailed),
                                         ("9.0", try dir.read("broker.token", maxBytes: 32), .unsupportedVersion)] {
            let fd = try raw(env); defer { Darwin.close(fd) }
            try send(fd, ["apiVersion": version, "instanceId": dir.locator().instanceId, "token": token.base64EncodedString()], env)
            XCTAssertEqual(try response(fd, env).error?.code, expected)
        }
    }
    func testStaleInstanceLocatorRejects() throws {
        let env = try environment(); defer { cleanup(env) }
        let server = WorkbenchBrokerServer(environment: env); try server.start(); defer { server.stop() }
        let file = env.runtimeDirectory.appendingPathComponent("broker.locator.json")
        let bytes = try WorkbenchSocket.encode(WorkbenchRuntimeLocator(instanceId: UUID().uuidString))
        let fd = open(file.path, O_WRONLY | O_TRUNC); XCTAssertGreaterThanOrEqual(fd, 0)
        bytes.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, bytes.count) }; Darwin.close(fd)
        let client = WorkbenchBrokerClient(environment: env); code(.instanceMismatch) { try client.connect() }
    }
    func testClosedMethodAndFieldRegistryOverWire() throws {
        let env = try environment(); defer { cleanup(env) }
        let server = WorkbenchBrokerServer(environment: env); try server.start(); defer { server.stop() }
        let variants: [([String: Any], WorkbenchIPCErrorCode)] = [
            (["apiVersion":"1.0", "requestId":"bad", "method":"approval.resolve", "params":[:]], .methodNotFound),
            (["apiVersion":"1.0", "requestId":"bad", "method":"system.health", "params":["approved":true]], .invalidRequest),
            (["apiVersion":"1.0", "requestId":"bad", "method":"system.health", "params":[:], "role":"gui"], .invalidRequest),
            (["apiVersion":"2.0", "requestId":"bad", "method":"system.health", "params":[:]], .unsupportedVersion)]
        for (request, expected) in variants {
            let fd = try raw(env); defer { Darwin.close(fd) }; try authenticate(fd, env)
            try send(fd, request, env); XCTAssertEqual(try response(fd, env).error?.code, expected)
        }
    }
    func testHelloRequiredAndDuplicateKeysRejectOverWire() throws {
        let env = try environment(); defer { cleanup(env) }
        let server = WorkbenchBrokerServer(environment: env); try server.start(); defer { server.stop() }
        let first = try raw(env); defer { Darwin.close(first) }; try authenticate(first, env, hello: false)
        try send(first, ["apiVersion":"1.0", "requestId":"early", "method":"system.health", "params":[:]], env)
        XCTAssertEqual(try response(first, env).error?.code, .invalidRequest)
        let second = try raw(env); defer { Darwin.close(second) }; try authenticate(second, env)
        let duplicate = Data(#"{"apiVersion":"1.0","requestId":"dup","method":"system.health","method":"approval.resolve","params":{}}"#.utf8)
        try WorkbenchSocket.writeFrame(second, bytes: duplicate, environment: env)
        XCTAssertEqual(try response(second, env).error?.code, .invalidRequest)
    }
    func testConcurrentClientsAndSingleton() throws {
        let env = try environment(timeout: 2); defer { cleanup(env) }
        let server = WorkbenchBrokerServer(environment: env); let snapshot = try server.start(); defer { server.stop() }
        let second = WorkbenchBrokerServer(environment: env); code(.alreadyRunning) { try second.start() }
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            do { let c = WorkbenchBrokerClient(environment: env); try c.connect(); defer { c.close() }; results.append(try c.health().instanceId) }
            catch { results.fail() }
        }
        XCTAssertEqual(results.failures, 0); XCTAssertEqual(results.ids.count, 12); XCTAssertEqual(Set(results.ids), [snapshot.instanceId])
    }
    func testPartialFrameDeadlineDisconnectAndHealthyProgress() throws {
        let env = try environment(timeout: 0.25); defer { cleanup(env) }
        let server = WorkbenchBrokerServer(environment: env); try server.start(); defer { server.stop() }
        let fd = try raw(env); defer { Darwin.close(fd) }
        var partial: UInt8 = 0; XCTAssertEqual(Darwin.send(fd, &partial, 1, 0), 1)
        let healthy = WorkbenchBrokerClient(environment: env); try healthy.connect(); XCTAssertEqual(try healthy.health().status, "ready"); healthy.close()
        // Wait with a longer observer deadline than the server's partial-frame deadline.
        let observe = try WorkbenchBrokerEnvironment(runtimeDirectory: env.runtimeDirectory, limits: .init(timeout: 1))
        code(.disconnected) { _ = try response(fd, observe) }
        until { server.activeConnectionCount == 0 }
    }
    func testAuthenticationAndHelloShareOneDeadline() throws {
        let env = try environment(timeout: 0.3); defer { cleanup(env) }
        let server = WorkbenchBrokerServer(environment: env); try server.start(); defer { server.stop() }
        let fd = try raw(env); defer { Darwin.close(fd) }
        until { server.activeConnectionCount == 1 }
        Thread.sleep(forTimeInterval: 0.18)
        try authenticate(fd, env, hello: false)
        let observe = try WorkbenchBrokerEnvironment(runtimeDirectory: env.runtimeDirectory, limits: .init(timeout: 1))
        let start = ProcessInfo.processInfo.systemUptime
        code(.disconnected) { _ = try response(fd, observe) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.25)
    }
    func testPartialAuthenticatedPayloadDeadlineReleasesStaging() throws {
        let env = try environment(timeout: 0.2, frame: 1024); defer { cleanup(env) }
        let server = WorkbenchBrokerServer(environment: env); try server.start(); defer { server.stop() }
        let fd = try raw(env); defer { Darwin.close(fd) }; try authenticate(fd, env)
        let partial: [UInt8] = [0, 0, 0, 100, 123]
        partial.withUnsafeBytes { _ = Darwin.send(fd, $0.baseAddress, partial.count, 0) }
        until { server.stagedFrameBytes == 100 }
        let observe = try WorkbenchBrokerEnvironment(runtimeDirectory: env.runtimeDirectory, limits: .init(timeout: 1))
        code(.disconnected) { _ = try response(fd, observe) }
        until { server.stagedFrameBytes == 0 }
    }
    func testOversizedAndZeroLengthFramesRejectBeforeAllocation() throws {
        let env = try environment(frame: 1024); defer { cleanup(env) }
        let server = WorkbenchBrokerServer(environment: env); try server.start(); defer { server.stop() }
        for header in [[UInt8](arrayLiteral: 0, 0, 4, 1), [0, 0, 0, 0]] {
            let fd = try raw(env); defer { Darwin.close(fd) }
            header.withUnsafeBytes { XCTAssertEqual(Darwin.send(fd, $0.baseAddress, 4, 0), 4) }
            let error = try response(fd, env).error?.code
            XCTAssertEqual(error, header[3] == 1 ? .frameTooLarge : .invalidRequest)
        }
        XCTAssertEqual(server.stagedFrameBytes, 0)
    }
    func testAggregateFrameBudgetAndConnectionLimit() throws {
        let env = try environment(connections: 3, frame: 1024, staging: 1024); defer { cleanup(env) }
        let server = WorkbenchBrokerServer(environment: env); try server.start(); defer { server.stop() }
        let stalled = try raw(env); defer { Darwin.close(stalled) }
        let header: [UInt8] = [0, 0, 4, 0]; header.withUnsafeBytes { _ = Darwin.send(stalled, $0.baseAddress, 4, 0) }
        until { server.stagedFrameBytes == 1024 }
        let client = WorkbenchBrokerClient(environment: env); code(.resourceLimit) { try client.connect() }
        _ = Darwin.shutdown(stalled, SHUT_RDWR); until { server.stagedFrameBytes == 0 }
        let recovered = WorkbenchBrokerClient(environment: env); try recovered.connect(); recovered.close()
    }
    func testConnectionCapAndStopUnblockIdleClients() throws {
        let env = try environment(connections: 1); defer { cleanup(env) }
        let server = WorkbenchBrokerServer(environment: env); try server.start()
        let first = try raw(env); defer { Darwin.close(first) }; until { server.activeConnectionCount == 1 }
        let second = try raw(env); defer { Darwin.close(second) }
        code(.disconnected) { _ = try WorkbenchSocket.readFrame(second, environment: env) }
        let start = ProcessInfo.processInfo.systemUptime; server.stop()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
        code(.disconnected) { _ = try WorkbenchSocket.readFrame(first, environment: env) }
    }
    func testRestartRotatesTokenAndRetainsLockInode() throws {
        let env = try environment(); defer { cleanup(env) }
        let server = WorkbenchBrokerServer(environment: env); let before = try server.start()
        let dir = try WorkbenchRuntimeDirectory(environment: env, create: false)
        let token = try dir.read("broker.token", maxBytes: 32)
        let localToken = try dir.read("broker.local-token", maxBytes: 32)
        XCTAssertNotEqual(token, localToken)
        let lockID = try dir.identity(of: "broker.lock")
        server.stop(); server.stop()
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: env.runtimeDirectory.path)), ["broker.lock"])
        let after = try server.start(); defer { server.stop() }
        XCTAssertNotEqual(before.instanceId, after.instanceId); XCTAssertNotEqual(token, try dir.read("broker.token", maxBytes: 32))
        XCTAssertNotEqual(localToken, try dir.read("broker.local-token", maxBytes: 32))
        XCTAssertEqual(lockID, try dir.identity(of: "broker.lock"))
        let fd = try raw(env); defer { Darwin.close(fd) }
        try send(fd, ["apiVersion":"1.0", "instanceId":after.instanceId, "token":token.base64EncodedString()], env)
        XCTAssertEqual(try response(fd, env).error?.code, .authenticationFailed)
    }
    func testKernelLockReleasesAfterProcessDeathAndStaleFilesRecover() throws {
        let env = try environment(); defer { cleanup(env) }
        let dir = try WorkbenchRuntimeDirectory(environment: env, create: true)
        let held = try dir.lock(); _ = flock(held, LOCK_UN); Darwin.close(held)
        let child = Process(); let ready = Pipe(); child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "import os,fcntl,sys,time; f=os.open(sys.argv[1],os.O_RDWR); fcntl.flock(f,fcntl.LOCK_EX); print('ready',flush=True); time.sleep(30)", env.runtimeDirectory.appendingPathComponent("broker.lock").path]
        child.standardOutput = ready; try child.run()
        XCTAssertEqual(try ready.fileHandleForReading.read(upToCount: 6), Data("ready\n".utf8))
        let server = WorkbenchBrokerServer(environment: env); code(.alreadyRunning) { try server.start() }
        _ = Darwin.kill(child.processIdentifier, SIGKILL); child.waitUntilExit()
        _ = try dir.create("broker.token", bytes: Data(repeating: 1, count: 32))
        _ = try dir.create("broker.locator.json", bytes: WorkbenchSocket.encode(WorkbenchRuntimeLocator(instanceId: UUID().uuidString)))
        let stale = try WorkbenchSocket.make()
        XCTAssertEqual(try WorkbenchSocket.address(env.runtimeDirectory.appendingPathComponent("broker.sock").path) { Darwin.bind(stale, $0, $1) }, 0)
        XCTAssertEqual(fchmodat(dir.fd, "broker.sock", 0o600, 0), 0); Darwin.close(stale)
        try server.start(); defer { server.stop() }
        let client = WorkbenchBrokerClient(environment: env); try client.connect(); client.close()
    }
    /// Run the mkdir/lock/bind prefix in a child so umask never changes this multithreaded test process.
    private func interruptedSocket(_ env: WorkbenchBrokerEnvironment) throws -> stat {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.environment = ["PATH": "/usr/bin:/bin", "HOME": "/private/tmp"]
        child.arguments = ["-c", "import os,fcntl,socket,sys; os.umask(0o022); f=os.open(sys.argv[1]+'/broker.lock',os.O_RDWR|os.O_CREAT,0o600); fcntl.flock(f,fcntl.LOCK_EX); s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.bind(sys.argv[1]+'/broker.sock'); s.close(); os.close(f)", env.runtimeDirectory.path]
        try child.run(); child.waitUntilExit(); XCTAssertEqual(child.terminationStatus, 0)
        var metadata = stat()
        XCTAssertEqual(lstat(env.runtimeDirectory.appendingPathComponent("broker.sock").path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & 0o7777, 0o755)
        return metadata
    }
    func testInterruptedBindBeforeChmodRecoversAndRotatesIdentity() throws {
        let env = try environment(); defer { cleanup(env) }
        let server = WorkbenchBrokerServer(environment: env)
        let previous = try server.start()
        let dir = try WorkbenchRuntimeDirectory(environment: env, create: false)
        let oldToken = try dir.read("broker.token", maxBytes: 32)
        let lockID = try dir.identity(of: "broker.lock")
        server.stop()
        _ = try interruptedSocket(env)
        let sentinel = env.runtimeDirectory.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinel)
        let recovered = try server.start(); defer { server.stop() }
        XCTAssertNotEqual(recovered.instanceId, previous.instanceId)
        XCTAssertNotEqual(try dir.read("broker.token", maxBytes: 32), oldToken)
        XCTAssertEqual(try dir.identity(of: "broker.lock"), lockID)
        _ = try dir.identity(of: "broker.sock", socket: true) // Published socket is strictly 0600.
        let client = WorkbenchBrokerClient(environment: env); try client.connect(); defer { client.close() }
        XCTAssertEqual(try client.health(), recovered)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    }
    func testFailureBeforeChmodCleansCapturedSocketAndAllowsRetry() throws {
        let env = try environment(); defer { cleanup(env) }
        let dir = try WorkbenchRuntimeDirectory(environment: env, create: true)
        let sentinel = env.runtimeDirectory.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinel)
        let failing = WorkbenchBrokerServer(environment: env, afterSocketBound: {
            XCTAssertEqual(fchmodat(dir.fd, "broker.sock", 0o755, 0), 0)
            throw WorkbenchIPCError(.insecureRuntime)
        })
        code(.insecureRuntime) { try failing.start() }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: env.runtimeDirectory.path)), ["broker.lock", "sentinel"])
        let lockID = try dir.identity(of: "broker.lock")
        let retry = WorkbenchBrokerServer(environment: env); try retry.start(); defer { retry.stop() }
        let client = WorkbenchBrokerClient(environment: env); try client.connect(); defer { client.close() }
        XCTAssertEqual(try client.health().status, "ready")
        XCTAssertEqual(try dir.identity(of: "broker.lock"), lockID)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    }
    func testFailureCleanupPreservesReplacedSocketNode() throws {
        let env = try environment(); defer { cleanup(env) }
        let socket = env.runtimeDirectory.appendingPathComponent("broker.sock")
        let saved = env.runtimeDirectory.appendingPathComponent("saved.sock")
        let failing = WorkbenchBrokerServer(environment: env, afterSocketBound: {
            try FileManager.default.moveItem(at: socket, to: saved)
            try Data("replacement".utf8).write(to: socket)
            XCTAssertEqual(chmod(socket.path, 0o600), 0)
            throw WorkbenchIPCError(.insecureRuntime)
        })
        code(.insecureRuntime) { try failing.start() }
        XCTAssertEqual(try Data(contentsOf: socket), Data("replacement".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
        code(.insecureRuntime) { try WorkbenchBrokerServer(environment: env).start() }
        XCTAssertEqual(try Data(contentsOf: socket), Data("replacement".utf8))
    }
    func testStaleSocketLinksWrongTypesAndSpecialModesRejectWithoutRetirement() throws {
        for variant in ["symlink", "regular", "directory", "specialMode", "hardlink"] {
            let env = try environment(); defer { cleanup(env) }
            let dir = try WorkbenchRuntimeDirectory(environment: env, create: true)
            let held = try dir.lock(); _ = flock(held, LOCK_UN); Darwin.close(held)
            let sentinel = env.runtimeDirectory.appendingPathComponent("sentinel")
            try Data("keep".utf8).write(to: sentinel)
            let socket = env.runtimeDirectory.appendingPathComponent("broker.sock")
            switch variant {
            case "symlink": try FileManager.default.createSymbolicLink(at: socket, withDestinationURL: sentinel)
            case "regular": try Data("wrong-type".utf8).write(to: socket); XCTAssertEqual(chmod(socket.path, 0o600), 0)
            case "directory": try FileManager.default.createDirectory(at: socket, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            default:
                _ = try interruptedSocket(env)
                if variant == "specialMode" { XCTAssertEqual(chmod(socket.path, 0o1755), 0) }
                else { XCTAssertEqual(link(socket.path, env.runtimeDirectory.appendingPathComponent("socket-link").path), 0) }
            }
            // Unsafe socket validation must complete before these otherwise-valid records are retired.
            let bytes = Data(repeating: 3, count: 32)
            _ = try dir.create("broker.token", bytes: bytes)
            let locator = WorkbenchRuntimeLocator(instanceId: UUID().uuidString)
            _ = try dir.create("broker.locator.json", bytes: WorkbenchSocket.encode(locator))
            var before = stat(); XCTAssertEqual(lstat(socket.path, &before), 0)
            code(.insecureRuntime) { try WorkbenchBrokerServer(environment: env).start() }
            var after = stat(); XCTAssertEqual(lstat(socket.path, &after), 0)
            XCTAssertEqual(WorkbenchFileIdentity(before), WorkbenchFileIdentity(after))
            XCTAssertEqual(try dir.read("broker.token", maxBytes: 32), bytes)
            XCTAssertEqual(try dir.locator(), locator)
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        }
    }
    func testUnpublishedSocketOwnerValidationAndStrictClientPermissions() throws {
        let env = try environment(); defer { cleanup(env) }
        let dir = try WorkbenchRuntimeDirectory(environment: env, create: true)
        let metadata = try interruptedSocket(env)
        var foreign = metadata; foreign.st_uid = env.ownerUID + 1
        // Actual different-owner creation needs another account/root; validate foreign metadata
        // through the exact same policy used for real fstatat results, without changing OS ownership.
        code(.insecureRuntime) { _ = try WorkbenchRuntimeDirectory.validateUnpublishedSocket(foreign, ownerUID: env.ownerUID) }
        var linked = metadata; linked.st_nlink = 2
        code(.insecureRuntime) { _ = try WorkbenchRuntimeDirectory.validateUnpublishedSocket(linked, ownerUID: env.ownerUID) }
        _ = try dir.create("broker.token", bytes: Data(repeating: 4, count: 32))
        _ = try dir.create("broker.locator.json", bytes: WorkbenchSocket.encode(WorkbenchRuntimeLocator(instanceId: UUID().uuidString)))
        code(.insecureRuntime) { try WorkbenchBrokerClient(environment: env).connect() }
        code(.insecureRuntime) { _ = try dir.identity(of: "broker.sock", socket: true) }
    }
    func testRejectsUnsafeModesLinksAndOwnershipWithoutTouchingSentinel() throws {
        let env = try environment(); defer { cleanup(env) }
        try FileManager.default.createDirectory(at: env.runtimeDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        code(.insecureRuntime) { try WorkbenchBrokerServer(environment: env).start() }
        XCTAssertEqual(chmod(env.runtimeDirectory.path, 0o700), 0)
        let sentinel = env.runtimeDirectory.appendingPathComponent("sentinel"); try Data("keep".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: env.runtimeDirectory.appendingPathComponent("broker.lock"), withDestinationURL: sentinel)
        code(.insecureRuntime) { try WorkbenchBrokerServer(environment: env).start() }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        try FileManager.default.removeItem(at: env.runtimeDirectory.appendingPathComponent("broker.lock"))
        let wrong = try WorkbenchBrokerEnvironment(runtimeDirectory: env.runtimeDirectory, ownerUID: geteuid() + 1)
        code(.insecureRuntime) { try WorkbenchBrokerServer(environment: wrong).start() }
        let alias = env.runtimeDirectory.appendingPathExtension("alias"); defer { try? FileManager.default.removeItem(at: alias) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: env.runtimeDirectory)
        let linked = try WorkbenchBrokerEnvironment(runtimeDirectory: alias)
        code(.insecureRuntime) { try WorkbenchBrokerServer(environment: linked).start() }
    }
    func testClientRejectsLinkedLocatorAndHardlinkedToken() throws {
        let env = try environment(); defer { cleanup(env) }
        let server = WorkbenchBrokerServer(environment: env); try server.start(); defer { server.stop() }
        let locator = env.runtimeDirectory.appendingPathComponent("broker.locator.json"), saved = env.runtimeDirectory.appendingPathComponent("saved.json")
        try FileManager.default.moveItem(at: locator, to: saved); try FileManager.default.createSymbolicLink(at: locator, withDestinationURL: saved)
        code(.insecureRuntime) { try WorkbenchBrokerClient(environment: env).connect() }
        try FileManager.default.removeItem(at: locator); try FileManager.default.moveItem(at: saved, to: locator)
        XCTAssertEqual(link(env.runtimeDirectory.appendingPathComponent("broker.token").path, env.runtimeDirectory.appendingPathComponent("token-link").path), 0)
        code(.insecureRuntime) { try WorkbenchBrokerClient(environment: env).connect() }
    }
    func testCleanupDoesNotDeleteReplacedFilesOrUnrelatedContent() throws {
        let env = try environment(); defer { cleanup(env) }
        let server = WorkbenchBrokerServer(environment: env); try server.start()
        let token = env.runtimeDirectory.appendingPathComponent("broker.token")
        try FileManager.default.moveItem(at: token, to: env.runtimeDirectory.appendingPathComponent("saved-token"))
        try Data("replacement".utf8).write(to: token); XCTAssertEqual(chmod(token.path, 0o600), 0)
        let note = env.runtimeDirectory.appendingPathComponent("note"); try Data("unrelated".utf8).write(to: note)
        server.stop()
        XCTAssertEqual(try Data(contentsOf: token), Data("replacement".utf8)); XCTAssertEqual(try Data(contentsOf: note), Data("unrelated".utf8))
    }
    func testClientLifecycleAndUnavailableDoesNotCreateRuntime() throws {
        let env = try environment(); defer { cleanup(env) }
        let client = WorkbenchBrokerClient(environment: env)
        code(.unavailable) { try client.connect() }; XCTAssertFalse(FileManager.default.fileExists(atPath: env.runtimeDirectory.path))
        code(.disconnected) { _ = try client.health() }; client.close(); client.close()
        let server = WorkbenchBrokerServer(environment: env); try server.start()
        try client.connect(); server.stop(); code(.disconnected) { _ = try client.health() }
    }
}
private struct FixedPeers: WorkbenchPeerCredentials { let uid: UInt32; func effectiveUID(socket: Int32) throws -> UInt32 { uid } }
private final class CountingPeers: WorkbenchPeerCredentials, @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func effectiveUID(socket: Int32) throws -> UInt32 { lock.lock(); count += 1; lock.unlock(); return try WorkbenchSystemPeerCredentials().effectiveUID(socket: socket) }
}
private final class Results: @unchecked Sendable {
    private let lock = NSLock(); private var values: [String] = []; private var errors = 0
    var ids: [String] { lock.lock(); defer { lock.unlock() }; return values }
    var failures: Int { lock.lock(); defer { lock.unlock() }; return errors }
    func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    func fail() { lock.lock(); errors += 1; lock.unlock() }
}
#endif
