import Foundation
import CryptoKit
import Security
import Darwin
import BuildSpawn

enum BuildJobError: Error {
    case invalidJob, quota, invalidMember, invalidOffset, digestMismatch, incompleteSource
    case kitUnavailable, spawnFailed(Int32), failed(Int32), timedOut, cancelled, outputInvalid
    case descendantNotTerminated
}

private final class BuildJob {
    struct SourceFile { var bytes: Int64; var complete: Bool }
    let envelope: BuildEnvelope
    let root: URL
    let source: URL
    let output: URL
    let home: URL
    var sourceFiles: [String: SourceFile] = [:]
    var portableFiles: [String: String] = [:]
    var sourceDirectories: Set<String> = []
    var attemptedFiles: Set<String> = []
    var sourceBytes: Int64 = 0
    var running = false
    var cancelled = false
    var pid: pid_t = 0
    var outputs: [String: BuildOutputFile] = [:]

    init(_ envelope: BuildEnvelope, root: URL) {
        self.envelope = envelope
        self.root = root
        source = root.appendingPathComponent("source", isDirectory: true)
        output = root.appendingPathComponent("output", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
    }
}

final class BuildJobs {
    private let lock = NSLock()
    private var jobs: [String: BuildJob] = [:]
    private let fm = FileManager.default
    private let stagingRoot: URL
    private let kitRoot: URL
    private let verifyKit: (URL) -> Bool
    private let maxDuration: TimeInterval

    init(stagingRoot: URL? = nil, kitRoot: URL? = nil, maxDuration: TimeInterval = 120,
         verifyKit: ((URL) -> Bool)? = nil) {
        self.stagingRoot = stagingRoot ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        self.kitRoot = kitRoot ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/AuthoringKit", isDirectory: true)
        self.maxDuration = maxDuration
        self.verifyKit = verifyKit ?? Self.verifySealedKit
    }

    func prepare(_ envelope: BuildEnvelope) throws {
        lock.lock(); defer { lock.unlock() }
        guard jobs.count < 2, jobs[envelope.jobID] == nil,
              !jobs.values.contains(where: { $0.envelope.projectID == envelope.projectID }) else { throw BuildJobError.quota }
        let root = stagingRoot.appendingPathComponent("screenpunk-build-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let job = BuildJob(envelope, root: root)
        do {
            try fm.createDirectory(at: job.source, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try fm.createDirectory(at: job.home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            jobs[envelope.jobID] = job
        } catch {
            try? fm.removeItem(at: root)
            throw error
        }
    }

    func upload(_ jobID: String, path: String, offset: Int64, bytes: Data, finalSHA256: String?) throws {
        guard BuildRequestValidation.identifierValue(jobID), BuildRequestValidation.sourceMember(path),
              bytes.count <= BuildRequestValidation.maximumChunkBytes,
              offset >= 0, finalSHA256.map(BuildRequestValidation.digestValue) ?? true else { throw BuildJobError.invalidMember }
        lock.lock(); defer { lock.unlock() }
        guard let job = jobs[jobID], !job.running, !job.cancelled else { throw BuildJobError.invalidJob }
        let portable = path.lowercased()
        guard job.portableFiles[portable] == nil || job.portableFiles[portable] == path else { throw BuildJobError.invalidMember }
        let parts = path.split(separator: "/").map(String.init)
        var directories = Set<String>()
        for count in 1..<parts.count { directories.insert(parts.prefix(count).joined(separator: "/")) }
        let prospectiveDirectories = job.sourceDirectories.union(directories)
        let prospectiveFiles = job.attemptedFiles.union([path])
        guard prospectiveDirectories.count + prospectiveFiles.count <= 4000,
              prospectiveFiles.count <= 2000 else { throw BuildJobError.quota }
        for member in prospectiveDirectories.union(prospectiveFiles) {
            let key = member.lowercased()
            guard job.portableFiles[key] == nil || job.portableFiles[key] == member else {
                throw BuildJobError.invalidMember
            }
        }
        job.sourceDirectories = prospectiveDirectories
        job.attemptedFiles = prospectiveFiles
        for member in directories { job.portableFiles[member.lowercased()] = member }
        job.portableFiles[portable] = path
        var state = job.sourceFiles[path] ?? BuildJob.SourceFile(bytes: 0, complete: false)
        guard !state.complete, offset == state.bytes,
              job.sourceBytes + Int64(bytes.count) <= 50 * 1024 * 1024,
              job.sourceFiles.count < 2000 || job.sourceFiles[path] != nil else { throw BuildJobError.quota }
        let file = job.source.appendingPathComponent(path)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        if offset == 0 {
            let descriptor = open(file.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw BuildJobError.invalidMember }
            close(descriptor)
        }
        let descriptor = open(file.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw BuildJobError.invalidMember }
        defer { close(descriptor) }
        guard lseek(descriptor, offset, SEEK_SET) == offset else { throw BuildJobError.invalidOffset }
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var remaining = bytes.count
            var cursor = base
            while remaining > 0 {
                let written = Darwin.write(descriptor, cursor, remaining)
                guard written > 0 else { throw BuildJobError.invalidMember }
                remaining -= written
                cursor = cursor.advanced(by: written)
            }
        }
        state.bytes += Int64(bytes.count)
        job.sourceBytes += Int64(bytes.count)
        if let finalSHA256 {
            guard try Self.sha256(file) == finalSHA256 else { throw BuildJobError.digestMismatch }
            state.complete = true
        }
        job.sourceFiles[path] = state
    }

    func execute(_ jobID: String) throws -> BuildResponse {
        lock.lock()
        guard let job = jobs[jobID], !job.running, !job.cancelled,
              !job.sourceFiles.isEmpty, job.sourceFiles["src/main.tsx"]?.complete == true,
              job.sourceFiles.values.allSatisfy(\.complete) else {
            lock.unlock(); throw BuildJobError.incompleteSource
        }
        job.running = true
        lock.unlock()
        var groupSafe = true
        defer {
            lock.lock()
            if groupSafe { job.running = false; job.pid = 0 }
            // On an unconfirmed group, retain the job, quota slot and staging directory.
            lock.unlock()
        }

        let kit = kitRoot.appendingPathComponent(job.envelope.kitDirectory, isDirectory: true)
        guard verifyKit(kit) else { throw BuildJobError.kitUnavailable }
        let node = kit.appendingPathComponent("bin/node")
        let script = kit.appendingPathComponent("scripts/build.mjs")
        guard fm.isExecutableFile(atPath: node.path), fm.fileExists(atPath: script.path) else { throw BuildJobError.kitUnavailable }

        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw BuildJobError.spawnFailed(errno) }
        defer { close(descriptors[0]) }
        let current = fcntl(descriptors[0], F_GETFL)
        _ = fcntl(descriptors[0], F_SETFL, current | O_NONBLOCK)
        var pid: pid_t = 0
        let spawned = node.path.withCString { executable in
            script.path.withCString { script in
                job.source.path.withCString { source in
                    job.output.path.withCString { output in
                        job.home.path.withCString { home in
                            sp_build_spawn(executable, script, source, output, home, descriptors[1], &pid)
                        }
                    }
                }
            }
        }
        close(descriptors[1])
        guard spawned == 0, pid > 0 else { throw BuildJobError.spawnFailed(Int32(spawned)) }
        groupSafe = false
        lock.lock(); job.pid = pid; lock.unlock()

        let deadline = ProcessInfo.processInfo.systemUptime + maxDuration
        var log = Data()
        var status: Int32 = 0
        var reaped = false
        var failure: BuildJobError?
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let received = Darwin.read(descriptors[0], &buffer, buffer.count)
            if received > 0 {
                if log.count + received > 1024 * 1024 { failure = .quota }
                else { log.append(contentsOf: buffer.prefix(received)) }
            } else if received < 0 && errno != EAGAIN && errno != EINTR {
                failure = .outputInvalid
            }
            lock.lock(); let cancelled = job.cancelled; lock.unlock()
            if cancelled { failure = .cancelled }
            if ProcessInfo.processInfo.systemUptime >= deadline { failure = .timedOut }
            if failure == nil {
                do {
                    _ = try Self.scan(job.root, maxBytes: 256 * 1024 * 1024, maxFiles: 4000,
                                      hashFiles: false, deadline: deadline,
                                      cancelled: { self.isCancelled(job) }, requireStable: false,
                                      stageRoot: true)
                } catch BuildJobError.cancelled { failure = .cancelled }
                  catch BuildJobError.timedOut { failure = .timedOut }
                  catch { failure = .quota }
            }
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { reaped = true; break }
            if waited < 0 && errno != EINTR { failure = .failed(errno); break }
            if failure != nil { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        // The spawn attribute creates an owned process group before exec. Root reaping alone
        // says nothing about descendants; never free the quota or stage until the group is gone.
        guard Self.stopGroup(pid, rootReaped: &reaped, status: &status) else {
            throw BuildJobError.descendantNotTerminated
        }
        // Once all group writers are gone, drain the pipe to EOF under the existing 1 MiB cap.
        let drainDeadline = ProcessInfo.processInfo.systemUptime + 2
        while true {
            let received = Darwin.read(descriptors[0], &buffer, buffer.count)
            if received > 0 {
                if log.count + received > 1024 * 1024 { failure = .quota }
                else { log.append(contentsOf: buffer.prefix(received)) }
                continue
            }
            if received == 0 { break }
            if errno == EINTR { continue }
            if errno == EAGAIN && ProcessInfo.processInfo.systemUptime < drainDeadline {
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            throw BuildJobError.outputInvalid
        }
        groupSafe = true
        if let failure { throw failure }
        guard (status & 0x7f) == 0, ((status >> 8) & 0xff) == 0 else {
            return BuildResponse(code: "compiler_failed", detail: "Compiler exited with status \(status)", files: nil,
                                 diagnostics: String(decoding: log.suffix(32 * 1024), as: UTF8.self))
        }
        let outputs = try Self.scan(job.output, maxBytes: 50 * 1024 * 1024, maxFiles: 2000,
                                    deadline: ProcessInfo.processInfo.systemUptime + 10,
                                    cancelled: { self.isCancelled(job) })
        guard !outputs.isEmpty else { throw BuildJobError.outputInvalid }
        lock.lock(); job.outputs = Dictionary(uniqueKeysWithValues: outputs.map { ($0.path, $0) }); lock.unlock()
        return BuildResponse(code: "ok", detail: "built", files: outputs,
                             diagnostics: String(decoding: log.suffix(32 * 1024), as: UTF8.self))
    }

    private func isCancelled(_ job: BuildJob) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return job.cancelled
    }

    private static func stopGroup(_ group: pid_t, rootReaped: inout Bool,
                                  status: inout Int32) -> Bool {
        func gone() -> Bool { kill(-group, 0) == -1 && errno == ESRCH }
        let start = ProcessInfo.processInfo.systemUptime
        let deadline = start + 2
        var escalated = false
        if !gone() { _ = kill(-group, SIGTERM) }
        while ProcessInfo.processInfo.systemUptime < deadline {
            if !rootReaped {
                let waited = waitpid(group, &status, WNOHANG)
                if waited == group { rootReaped = true }
                else if waited < 0 && errno != EINTR { return false }
            }
            if rootReaped && gone() { return true }
            if !escalated && ProcessInfo.processInfo.systemUptime - start >= 0.2 {
                _ = kill(-group, SIGKILL)
                escalated = true
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    func download(_ jobID: String, path: String, offset: Int64) throws -> Data {
        lock.lock()
        guard let job = jobs[jobID], let file = job.outputs[path], !job.running,
              offset >= 0, offset <= file.bytes else { lock.unlock(); throw BuildJobError.invalidJob }
        let url = job.output.appendingPathComponent(path)
        lock.unlock()
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw BuildJobError.outputInvalid }
        defer { close(descriptor) }
        guard lseek(descriptor, offset, SEEK_SET) == offset else { throw BuildJobError.invalidOffset }
        let count = min(BuildRequestValidation.maximumChunkBytes, Int(file.bytes - offset))
        var bytes = [UInt8](repeating: 0, count: count)
        let received = Darwin.read(descriptor, &bytes, count)
        guard received == count else { throw BuildJobError.outputInvalid }
        return Data(bytes)
    }

    func cancel(_ jobID: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let job = jobs[jobID] else { throw BuildJobError.invalidJob }
        job.cancelled = true
        if job.pid > 0 { kill(-job.pid, SIGTERM) }
    }

    func release(_ jobID: String) throws {
        lock.lock()
        guard let job = jobs[jobID], !job.running else { lock.unlock(); throw BuildJobError.invalidJob }
        jobs.removeValue(forKey: jobID)
        lock.unlock()
        try fm.removeItem(at: job.root)
    }

    private static func sha256(_ url: URL, limit: Int64 = 50 * 1024 * 1024) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        var consumed: Int64 = 0
        while true {
            let chunk = try handle.read(upToCount: 256 * 1024) ?? Data()
            if chunk.isEmpty { break }
            guard Int64(chunk.count) <= limit - consumed else { throw BuildJobError.quota }
            consumed += Int64(chunk.count)
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func scan(_ root: URL, maxBytes: Int64, maxFiles: Int,
                             hashFiles: Bool = true, deadline: TimeInterval,
                             cancelled: () -> Bool, requireStable: Bool = true,
                             stageRoot: Bool = false) throws -> [BuildOutputFile] {
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw BuildJobError.outputInvalid }
        defer { close(directory) }
        var result: [BuildOutputFile] = []
        var portable = Set<String>()
        var bytes: Int64 = 0
        var entries = 0
        func check() throws {
            if cancelled() { throw BuildJobError.cancelled }
            if ProcessInfo.processInfo.systemUptime >= deadline { throw BuildJobError.timedOut }
        }
        func walk(_ parent: Int32, prefix: String, depth: Int) throws {
            try check()
            var before = stat()
            guard fstat(parent, &before) == 0 else { throw BuildJobError.outputInvalid }
            let copy = dup(parent)
            guard copy >= 0, let stream = fdopendir(copy) else {
                if copy >= 0 { close(copy) }
                throw BuildJobError.outputInvalid
            }
            defer { closedir(stream) }
            while true {
                try check()
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw BuildJobError.outputInvalid }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                        String(validatingUTF8: $0)
                    }
                }
                guard let name else { throw BuildJobError.outputInvalid }
                if name == "." || name == ".." { continue }
                entries += 1
                guard entries <= maxFiles * 2, depth < (stageRoot ? 33 : 32) else {
                    throw BuildJobError.quota
                }
                let relative = prefix.isEmpty ? name : prefix + "/" + name
                let parts = relative.split(separator: "/")
                let member: String
                if stageRoot {
                    guard let first = parts.first,
                          (["source", "output", "home"].contains(first) ||
                           Self.compilerStageName(String(first))),
                          parts.count <= 33 else { throw BuildJobError.outputInvalid }
                    member = parts.dropFirst().joined(separator: "/")
                } else {
                    guard parts.count <= 32 else { throw BuildJobError.outputInvalid }
                    member = relative
                }
                guard member.utf8.count <= 512,
                      member.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 47, 64, 95].contains($0) }),
                      portable.insert(relative.lowercased()).inserted else { throw BuildJobError.outputInvalid }
                var info = stat()
                guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                      info.st_uid == geteuid() else { throw BuildJobError.outputInvalid }
                switch info.st_mode & mode_t(S_IFMT) {
                case mode_t(S_IFDIR):
                    let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw BuildJobError.outputInvalid }
                    do { try walk(child, prefix: relative, depth: depth + 1) }
                    catch { close(child); throw error }
                    close(child)
                case mode_t(S_IFREG):
                    guard (!stageRoot || !member.isEmpty), info.st_nlink == 1, info.st_size >= 0,
                          info.st_size <= maxBytes - bytes, result.count < maxFiles else {
                        throw BuildJobError.quota
                    }
                    let file = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                    guard file >= 0 else { throw BuildJobError.outputInvalid }
                    let digest: String
                    do {
                        var opened = stat()
                        guard fstat(file, &opened) == 0, opened.st_dev == info.st_dev,
                              opened.st_ino == info.st_ino else { throw BuildJobError.outputInvalid }
                        digest = hashFiles ? try sha256(file, limit: info.st_size, check: check) : ""
                        var after = stat()
                        guard fstat(file, &after) == 0,
                              (!requireStable || same(info, after)) else { throw BuildJobError.outputInvalid }
                    } catch { close(file); throw error }
                    close(file)
                    bytes += info.st_size
                    result.append(BuildOutputFile(path: relative, bytes: info.st_size, sha256: digest))
                default: throw BuildJobError.outputInvalid
                }
            }
            var after = stat()
            guard fstat(parent, &after) == 0,
                  (!requireStable || same(before, after)) else { throw BuildJobError.outputInvalid }
        }
        try walk(directory, prefix: "", depth: 0)
        return result.sorted { $0.path < $1.path }
    }

    /// The fixed authoring script uses mkdtemp beside the final output, then renames
    /// the completed stage to output. Its transient directory is still inside the
    /// monitored job root and consumes the same entry/byte/deadline quota.
    private static func compilerStageName(_ name: String) -> Bool {
        let prefix = ".screenpunk-build-"
        guard name.hasPrefix(prefix), name.utf8.count == prefix.utf8.count + 6 else { return false }
        return name.dropFirst(prefix.count).utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }
    }

    private static func same(_ before: stat, _ after: stat) -> Bool {
        before.st_dev == after.st_dev && before.st_ino == after.st_ino &&
        before.st_size == after.st_size &&
        before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec &&
        before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec &&
        before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec &&
        before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    }

    private static func sha256(_ fd: Int32, limit: Int64, check: () throws -> Void) throws -> String {
        var digest = SHA256()
        var consumed: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            try check()
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw BuildJobError.outputInvalid }
            if count == 0 { break }
            guard Int64(count) <= limit - consumed else { throw BuildJobError.quota }
            consumed += Int64(count)
            digest.update(data: Data(buffer.prefix(count)))
        }
        guard consumed == limit else { throw BuildJobError.outputInvalid }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func verifySealedKit(_ kit: URL) -> Bool {
        guard kit.path.hasPrefix(Bundle.main.bundleURL.path + "/Contents/Resources/AuthoringKit/"),
              let code = staticCode(Bundle.main.bundleURL),
              SecStaticCodeCheckValidity(code, SecCSFlags(), nil) == errSecSuccess,
              let nodeCode = staticCode(kit.appendingPathComponent("bin/node")),
              SecStaticCodeCheckValidity(nodeCode, SecCSFlags(), nil) == errSecSuccess else { return false }
        var details: CFDictionary?
        guard SecCodeCopySigningInformation(nodeCode, SecCSFlags(rawValue: kSecCSSigningInformation), &details) == errSecSuccess,
              let info = details as? [String: Any],
              let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              entitlements["com.apple.security.app-sandbox"] as? Bool == true,
              entitlements["com.apple.security.inherit"] as? Bool == true,
              Set(entitlements.keys) == ["com.apple.security.app-sandbox", "com.apple.security.inherit"] else { return false }
        return true
    }

    private static func staticCode(_ url: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        return SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess ? code : nil
    }
}
