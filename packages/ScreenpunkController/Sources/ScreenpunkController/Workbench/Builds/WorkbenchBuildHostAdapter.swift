import Foundation
import CryptoKit
import Darwin

/// The selected host comes only from the installed, independently authenticated catalog.
/// Workspace bytes never select an executable or alter its launch environment.
final class WorkbenchBuildHostAdapter {
    private let installer: ToolchainKitInstaller
    init(installer: ToolchainKitInstaller) { self.installer = installer }

    func build(projectID: String, sourceVersion: String,
               requirement: WorkspaceToolchainRequirements.Requirement,
               inputs: OfflineBuildInputPlan, stagingPath: String,
               cancelled: @escaping () -> Bool = { false }) throws -> OfflineBuildResult {
        guard WorkspaceValidation.id(projectID), WorkspaceValidation.sha256(sourceVersion) else {
            throw OfflineBuildError.invalidResponse
        }
        // installed() resolves the exact current or historical pin against the local trusted
        // catalog and verifies both the complete inventory and the publisher-signed host.
        let installed = try installer.installed(requirement)
        let bundle = installed.bundlePath
        let executable = bundle + "/Contents/MacOS/ScreenpunkBuildHost"
        guard bundle == installed.kit.installedPath + "/" + ToolchainHostBundleContract.bundle else {
            throw ToolchainTrustError.unsafePath
        }
        let directory = open(installed.kit.installedPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw ToolchainTrustError.unsafePath }
        defer { close(directory) }
        let hostFD = open(bundle, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard hostFD >= 0 else { throw ToolchainTrustError.unsafePath }
        defer { close(hostFD) }
        var before = stat()
        guard fstat(hostFD, &before) == 0 else { throw ToolchainTrustError.unsafePath }
        // Reverify immediately before Process.run. The directory descriptors retain the
        // selected unit; the installer never replaces an installed unit in place.
        let fresh = try installer.installed(requirement)
        guard fresh.bundlePath == bundle, fresh.kit.rootIdentity == installed.kit.rootIdentity,
              samePathIdentity(bundle, before) else { throw ToolchainTrustError.inventoryMismatch }
        let session = try BuildHostSession(executable: executable, cancelled: cancelled)
        defer { session.close() }
        guard samePathIdentity(bundle, before) else { throw ToolchainTrustError.inventoryMismatch }
        let jobID = UUID().uuidString
        try requireOK(session.call(.init(action: "prepare", projectID: projectID, jobID: jobID,
                                         sourceVersion: sourceVersion), seconds: 5))
        defer { _ = try? session.call(.init(action: "release", jobID: jobID), seconds: 5) }
        for file in inputs.files {
            var offset = 0
            repeat {
                if cancelled() {
                    _ = try? session.call(.init(action: "cancel", jobID: jobID), seconds: 5)
                    throw OfflineBuildError.buildFailed("cancelled")
                }
                let end = min(file.bytes.count, offset + 256 * 1024)
                try requireOK(session.call(.init(action: "upload", jobID: jobID,
                    path: file.relativePath, offset: Int64(offset),
                    bytes: file.bytes.subdata(in: offset..<end),
                    finalSHA256: end == file.bytes.count ? file.sha256 : nil), seconds: 5))
                offset = end
            } while offset < file.bytes.count
        }
        let built = try requireOK(session.call(.init(action: "execute", jobID: jobID), seconds: 125))
        guard let files = built.files, !files.isEmpty, files.count <= 2_000,
              (built.diagnostics?.utf8.count ?? 0) <= 32 * 1024 else {
            throw OfflineBuildError.invalidResponse
        }
        let destination = URL(fileURLWithPath: stagingPath)
        try OfflineBuildOutputStage.save(files, to: destination) { path, offset in
            let reply = try session.call(.init(action: "download", jobID: jobID,
                                               path: path, offset: offset), seconds: 5)
            guard reply.count > 1, reply.first == 1,
                  reply.count - 1 <= OfflineBuildOutputStage.chunkBytes else {
                throw OfflineBuildError.invalidResponse
            }
            return Data(reply.dropFirst())
        }
        return OfflineBuildResult(stagingPath: destination.path, diagnostics: built.diagnostics ?? "")
    }

    private func samePathIdentity(_ path: String, _ before: stat) -> Bool {
        var now = stat()
        return lstat(path, &now) == 0 && now.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) &&
            now.st_dev == before.st_dev && now.st_ino == before.st_ino
    }

    @discardableResult private func requireOK(_ data: Data) throws -> BuildHostServiceReply {
        guard data.count <= 2 * 1024 * 1024,
              let reply = try? JSONDecoder().decode(BuildHostServiceReply.self, from: data),
              reply.detail.utf8.count <= 4_096,
              (reply.diagnostics?.utf8.count ?? 0) <= 32 * 1024 else {
            throw OfflineBuildError.invalidResponse
        }
        guard reply.code == "ok" else {
            throw OfflineBuildError.buildFailed(reply.detail +
                (reply.diagnostics.map { "\n" + $0 } ?? ""))
        }
        return reply
    }
}

private struct BuildHostServiceReply: Decodable {
    let code: String
    let detail: String
    let files: [OfflineBuildOutputFile]?
    let diagnostics: String?
}

struct BuildHostWireRequest: Encodable {
    let version = 1
    var id = 0
    let action: String
    var projectID: String? = nil
    let jobID: String
    var sourceVersion: String? = nil
    var path: String? = nil
    var offset: Int64? = nil
    var bytes: Data? = nil
    var finalSHA256: String? = nil
}

private struct BuildHostWireReply: Decodable {
    let id: Int
    let payload: Data
}

/// One child host and one XPC connection per build. Responses are length-bounded,
/// monotonically timed and treated as untrusted even after signature verification.
final class BuildHostSession {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let cancelled: () -> Bool
    private var nextID = 1
    private var cancelSent = false
    private var executingJobID: String?
    private let writeLock = NSLock()
    private let readFD: Int32
    private let writeFD: Int32

    init(executable: String, cancelled: @escaping () -> Bool) throws {
        self.cancelled = cancelled
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = []
        process.environment = ["PATH": "/usr/bin:/bin", "NODE_ENV": "production"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        readFD = output.fileHandleForReading.fileDescriptor
        writeFD = input.fileHandleForWriting.fileDescriptor
        guard fcntl(writeFD, F_SETNOSIGPIPE, 1) == 0 else {
            throw OfflineBuildError.isolatedExecutorUnavailable
        }
        let flags = fcntl(writeFD, F_GETFL)
        guard flags >= 0, fcntl(writeFD, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw OfflineBuildError.isolatedExecutorUnavailable
        }
        do { try process.run() } catch { throw OfflineBuildError.isolatedExecutorUnavailable }
    }

    func close() {
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        try? output.fileHandleForReading.close()
    }

    func call(_ request: BuildHostWireRequest, seconds: TimeInterval) throws -> Data {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        var message = request
        message.id = nextID; nextID += 1
        if request.action == "execute" { executingJobID = request.jobID }
        defer { if request.action == "execute" { executingJobID = nil } }
        try send(message, deadline: deadline)
        while true {
            let reply = try receive(deadline: deadline)
            if reply.id == message.id { return reply.payload }
            guard cancelSent, reply.id == nextID - 1 else { throw OfflineBuildError.invalidResponse }
        }
    }

    private func send(_ request: BuildHostWireRequest, deadline: TimeInterval) throws {
        guard let encoded = try? JSONEncoder().encode(request), encoded.count > 0,
              encoded.count <= 512 * 1024 else { throw OfflineBuildError.invalidResponse }
        var length = UInt32(encoded.count).bigEndian
        writeLock.lock(); defer { writeLock.unlock() }
        try withUnsafeBytes(of: &length) {
            try writeAll($0.baseAddress!, $0.count, deadline: deadline, allowCancelled: request.action == "cancel")
        }
        try encoded.withUnsafeBytes {
            try writeAll($0.baseAddress!, $0.count, deadline: deadline, allowCancelled: request.action == "cancel")
        }
    }

    private func writeAll(_ pointer: UnsafeRawPointer, _ count: Int,
                          deadline: TimeInterval, allowCancelled: Bool) throws {
        var offset = 0
        while offset < count {
            if !allowCancelled && cancelled() { throw OfflineBuildError.buildFailed("cancelled") }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw OfflineBuildError.isolatedExecutorUnavailable }
            let n = Darwin.write(writeFD, pointer.advanced(by: offset), count - offset)
            if n < 0 && errno == EINTR { continue }
            if n > 0 { offset += n; continue }
            guard n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) else {
                throw OfflineBuildError.isolatedExecutorUnavailable
            }
            var descriptor = pollfd(fd: writeFD, events: Int16(POLLOUT), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, Int32(min(50, remaining * 1_000)))
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw OfflineBuildError.isolatedExecutorUnavailable }
        }
    }

    private func receive(deadline: TimeInterval) throws -> BuildHostWireReply {
        let header = try readExact(4, deadline: deadline)
        let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0, count <= 3 * 1024 * 1024 else { throw OfflineBuildError.invalidResponse }
        let bytes = try readExact(Int(count), deadline: deadline)
        guard let reply = try? JSONDecoder().decode(BuildHostWireReply.self, from: bytes),
              reply.payload.count <= 2 * 1024 * 1024 else { throw OfflineBuildError.invalidResponse }
        return reply
    }

    private func readExact(_ count: Int, deadline: TimeInterval) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { throw OfflineBuildError.invalidResponse }
            var offset = 0
            while offset < count {
                if let job = executingJobID, cancelled() && !cancelSent {
                    cancelSent = true
                    var cancel = BuildHostWireRequest(action: "cancel", jobID: job)
                    cancel.id = nextID; nextID += 1
                    try send(cancel, deadline: deadline)
                }
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw OfflineBuildError.isolatedExecutorUnavailable }
                var descriptor = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&descriptor, 1, Int32(min(50, remaining * 1_000)))
                if ready < 0 && errno == EINTR { continue }
                guard ready >= 0 else { throw OfflineBuildError.isolatedExecutorUnavailable }
                if ready == 0 { continue }
                let n = Darwin.read(readFD, base.advanced(by: offset), count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw OfflineBuildError.isolatedExecutorUnavailable }
                offset += n
            }
        }
        return data
    }
}
