import Foundation
import CryptoKit
#if os(macOS)
import Darwin

protocol ToolchainArtifactFetching {
    /// Supply bounded chunks from only the catalog-approved HTTPS URL. A production fetcher must
    /// reject redirects outside the independently configured release origin.
    func fetch(_ url: URL, writeChunk: @escaping (Data) throws -> Void) throws
}

struct ToolchainVolumeCapacity {
    let totalBytes: Int64
    let availableBytes: Int64
    let blockBytes: Int64
}

protocol ToolchainCapacityProviding {
    func capacity(directoryFD: Int32) throws -> ToolchainVolumeCapacity
}

struct MacOSToolchainCapacityProvider: ToolchainCapacityProviding {
    func capacity(directoryFD: Int32) throws -> ToolchainVolumeCapacity {
        var volume = statfs()
        guard fstatfs(directoryFD, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0,
              volume.f_bsize > 0,
              volume.f_blocks <= UInt64(Int64.max) / UInt64(volume.f_bsize),
              volume.f_bavail <= UInt64(Int64.max) / UInt64(volume.f_bsize) else {
            throw ToolchainTrustError.limitExceeded
        }
        return ToolchainVolumeCapacity(totalBytes: Int64(volume.f_blocks) * Int64(volume.f_bsize),
            availableBytes: Int64(volume.f_bavail) * Int64(volume.f_bsize),
            blockBytes: Int64(volume.f_bsize))
    }
}

private struct ToolchainDiskBudget {
    let artifactBytes: Int64
    let expandedBytes: Int64
    let overheadBytes: Int64
    let provider: any ToolchainCapacityProviding
    let directoryFD: Int32

    init(entry: ToolchainCatalogEntry, provider: any ToolchainCapacityProviding, directoryFD: Int32) throws {
        self.provider = provider; self.directoryFD = directoryFD
        artifactBytes = Int64(entry.artifactBytes)
        expandedBytes = try entry.inventory.reduce(Int64(0)) { total, item in
            let (next, overflow) = total.addingReportingOverflow(Int64(item.bytes))
            guard !overflow else { throw ToolchainTrustError.limitExceeded }
            return next
        }
        var directories = Set<String>()
        for item in entry.inventory {
            let parts = item.path.split(separator: "/")
            for count in 1..<parts.count { directories.insert(parts.prefix(count).joined(separator: "/")) }
        }
        let capacity = try provider.capacity(directoryFD: directoryFD)
        guard capacity.totalBytes > 0, capacity.availableBytes >= 0,
              capacity.availableBytes <= capacity.totalBytes, capacity.blockBytes > 0 else {
            throw ToolchainTrustError.limitExceeded
        }
        let metadataEntries = Int64(entry.inventory.count + directories.count + 16)
        let (overhead, overflow) = metadataEntries.multipliedReportingOverflow(by: capacity.blockBytes)
        guard !overflow else { throw ToolchainTrustError.limitExceeded }
        overheadBytes = overhead
        try require(remainingArtifact: artifactBytes, remainingExpanded: expandedBytes)
    }

    func require(remainingArtifact: Int64, remainingExpanded: Int64) throws {
        guard remainingArtifact >= 0, remainingExpanded >= 0,
              remainingArtifact <= artifactBytes, remainingExpanded <= expandedBytes else {
            throw ToolchainTrustError.limitExceeded
        }
        let capacity = try provider.capacity(directoryFD: directoryFD)
        guard capacity.totalBytes > 0, capacity.availableBytes >= 0,
              capacity.availableBytes <= capacity.totalBytes else { throw ToolchainTrustError.limitExceeded }
        let (staging, firstOverflow) = remainingArtifact.addingReportingOverflow(remainingExpanded)
        let (withOverhead, secondOverflow) = staging.addingReportingOverflow(overheadBytes)
        guard !firstOverflow, !secondOverflow else { throw ToolchainTrustError.limitExceeded }
        // The M0 10% headroom applies to this import's peak, not to the size of
        // an otherwise unrelated APFS volume. Keep at least 128 MiB free beyond
        // the remaining archive copy, expanded stage, and conservative metadata.
        let percentage = withOverhead / 10 + (withOverhead % 10 == 0 ? 0 : 1)
        let reserve = max(Int64(128) * 1024 * 1024, percentage)
        let (required, thirdOverflow) = withOverhead.addingReportingOverflow(reserve)
        guard !thirdOverflow,
              capacity.availableBytes >= required else { throw ToolchainTrustError.limitExceeded }
    }
}

/// Strict HTTPS transport. Each request gets an isolated delegate and serial callback queue.
struct ToolchainHTTPSArtifactFetcher: ToolchainArtifactFetching {
    func fetch(_ url: URL, writeChunk: @escaping (Data) throws -> Void) throws {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.fragment == nil else { throw ToolchainTrustError.invalidCatalog }
        let delegate = DownloadDelegate(writer: writeChunk)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        let task = session.dataTask(with: url)
        task.resume()
        if delegate.finished.wait(timeout: .now() + 610) == .timedOut {
            delegate.disableWrites()
            task.cancel(); session.invalidateAndCancel()
            throw ToolchainTrustError.artifactMismatch
        }
        delegate.disableWrites()
        session.finishTasksAndInvalidate()
        if let failure = delegate.failure { throw failure }
        guard delegate.acceptedResponse else { throw ToolchainTrustError.artifactMismatch }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate,
    @unchecked Sendable {
    let writer: (Data) throws -> Void
    let finished = DispatchSemaphore(value: 0)
    private let writeLock = NSLock()
    private var writesEnabled = true
    var failure: Error?
    var acceptedResponse = false

    init(writer: @escaping (Data) throws -> Void) { self.writer = writer }

    func disableWrites() {
        writeLock.lock(); writesEnabled = false; writeLock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        failure = ToolchainTrustError.artifactMismatch
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            failure = ToolchainTrustError.artifactMismatch
            completionHandler(.cancel)
            return
        }
        acceptedResponse = true
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard writesEnabled else { return }
        guard failure == nil else { dataTask.cancel(); return }
        do { try writer(data) }
        catch { failure = error; dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if failure == nil, error != nil { failure = ToolchainTrustError.artifactMismatch }
        finished.signal()
    }
}

struct InstalledToolchainHost {
    let kit: VerifiedToolchainKit
    let bundlePath: String
}

/// Invoked only by an explicit `toolchain install` operation, never workspace discovery.
final class ToolchainKitInstaller {
    private enum ArtifactSource {
        case installedReleaseOrApprovedURL
        case verifiedRelease(URL)
    }
    let catalog: DurableToolchainCatalogStore
    let installedRoot: String
    let fetcher: any ToolchainArtifactFetching
    let bundleSignature: any ToolchainHostBundleSignatureVerifying
    let capacityProvider: any ToolchainCapacityProviding
    let installedReleaseRoot: URL?

    init(catalog: DurableToolchainCatalogStore, installedRoot: String,
         fetcher: any ToolchainArtifactFetching,
         bundleSignature: any ToolchainHostBundleSignatureVerifying,
         capacityProvider: any ToolchainCapacityProviding = MacOSToolchainCapacityProvider(),
         installedReleaseRoot: URL? = nil) {
        self.catalog = catalog; self.installedRoot = installedRoot
        self.fetcher = fetcher; self.bundleSignature = bundleSignature
        self.capacityProvider = capacityProvider; self.installedReleaseRoot = installedReleaseRoot
    }

    func installed(_ requirement: WorkspaceToolchainRequirements.Requirement) throws -> InstalledToolchainHost {
        guard installedRoot == catalog.installedKitRoot else { throw ToolchainTrustError.unsafePath }
        return try catalog.withResolved(requirement) { resolver, approved in
            try ToolchainHostBundleContract.validate(approved)
            let kit = try resolver.verifyInstalled(approved)
            let bundle = kit.installedPath + "/" + ToolchainHostBundleContract.bundle
            try bundleSignature.verify(bundlePath: bundle, expected: approved.entry.publisher)
            return InstalledToolchainHost(kit: kit, bundlePath: bundle)
        }
    }

    func install(_ requirement: WorkspaceToolchainRequirements.Requirement) throws -> InstalledToolchainHost {
        try install(requirement, source: .installedReleaseOrApprovedURL)
    }

    /// Import a package-carried archive only after an independently authenticated catalog
    /// resolves this exact requirement. The local file supplies bytes, never authority.
    func installOffline(_ requirement: WorkspaceToolchainRequirements.Requirement,
                        verifiedReleaseRoot: URL) throws -> InstalledToolchainHost {
        try install(requirement, source: .verifiedRelease(verifiedReleaseRoot))
    }

    private func install(_ requirement: WorkspaceToolchainRequirements.Requirement,
                         source: ArtifactSource) throws -> InstalledToolchainHost {
        guard installedRoot == catalog.installedKitRoot else { throw ToolchainTrustError.unsafePath }
        return try catalog.withResolved(requirement) { resolver, approved in
            try ToolchainHostBundleContract.validate(approved)
            let root = try WorkspaceFiles(path: installedRoot)
            let finalName = approved.directoryName
            var existing = stat()
            if fstatat(root.fd, finalName, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
                let kit = try resolver.verifyInstalled(approved)
                let bundle = kit.installedPath + "/" + ToolchainHostBundleContract.bundle
                try bundleSignature.verify(bundlePath: bundle, expected: approved.entry.publisher)
                return InstalledToolchainHost(kit: kit, bundlePath: bundle)
            }
            guard errno == ENOENT else { throw ToolchainTrustError.unsafePath }
            let disk = try ToolchainDiskBudget(entry: approved.entry,
                                               provider: capacityProvider, directoryFD: root.fd)
            let archiveName = ".download-" + UUID().uuidString
            let archive = installedRoot + "/" + archiveName
            let archiveFD = openat(root.fd, archiveName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard archiveFD >= 0 else { throw ToolchainTrustError.unsafePath }
            defer { _ = unlinkat(root.fd, archiveName, 0) }
            do {
                var received = 0
                let writeChunk: (Data) throws -> Void = { chunk in
                    guard !chunk.isEmpty, chunk.count <= approved.entry.artifactBytes - received else {
                        throw ToolchainTrustError.limitExceeded
                    }
                    try chunk.withUnsafeBytes { raw in
                        var offset = 0
                        while offset < raw.count {
                            try disk.require(remainingArtifact: Int64(approved.entry.artifactBytes - received),
                                             remainingExpanded: disk.expandedBytes)
                            let step = min(64 * 1024, raw.count - offset)
                            var written = 0
                            while written < step {
                                let count = Darwin.write(archiveFD,
                                    raw.baseAddress!.advanced(by: offset + written), step - written)
                                if count < 0 && errno == EINTR { continue }
                                guard count > 0 else { throw ToolchainTrustError.unsafePath }
                                written += count
                            }
                            offset += step
                            received += step
                            try disk.require(remainingArtifact: Int64(approved.entry.artifactBytes - received),
                                             remainingExpanded: disk.expandedBytes)
                        }
                    }
                }
                switch source {
                case .installedReleaseOrApprovedURL:
                    if let relative = approved.entry.embeddedArtifactPath {
                        guard let root = installedReleaseRoot else {
                            throw ToolchainTrustError.trustUnavailable
                        }
                        try Self.streamOfflineArchive(root: root, relativePath: relative,
                                                      expectedBytes: approved.entry.artifactBytes,
                                                      writeChunk: writeChunk)
                    } else {
                        guard let url = URL(string: approved.entry.downloadURL), url.scheme == "https" else {
                            throw ToolchainTrustError.invalidCatalog
                        }
                        try fetcher.fetch(url, writeChunk: writeChunk)
                    }
                case .verifiedRelease(let root):
                    guard let relative = approved.entry.embeddedArtifactPath else {
                        throw ToolchainTrustError.invalidCatalog
                    }
                    try Self.streamOfflineArchive(root: root, relativePath: relative,
                                                  expectedBytes: approved.entry.artifactBytes,
                                                  writeChunk: writeChunk)
                }
                guard received == approved.entry.artifactBytes else { throw ToolchainTrustError.artifactMismatch }
                guard fsync(archiveFD) == 0 else { throw ToolchainTrustError.unsafePath }
            } catch { close(archiveFD); throw error }
            close(archiveFD)
            try resolver.verifyArtifact(at: archive, for: approved)

            let stageName = ".stage-" + UUID().uuidString
            guard mkdirat(root.fd, stageName, 0o700) == 0 else { throw ToolchainTrustError.unsafePath }
            let stagePath = installedRoot + "/" + stageName
            defer { Self.removePrivateStage(stagePath) }
            try disk.require(remainingArtifact: 0, remainingExpanded: disk.expandedBytes)
            try StrictToolchainTar.extract(archive: archive, destination: stagePath,
                                           inventory: approved.entry.inventory) { remaining in
                try disk.require(remainingArtifact: 0, remainingExpanded: remaining)
            }
            _ = try ToolchainKitVerifier(signature: signatureVerifier(resolver)).verify(root: stagePath, approved: approved)
            try bundleSignature.verify(bundlePath: stagePath + "/" + ToolchainHostBundleContract.bundle,
                                       expected: approved.entry.publisher)
            try resolver.verifyArtifact(at: archive, for: approved)
            try root.verifyRoot()
            guard renameatx_np(root.fd, stageName, root.fd, finalName, UInt32(RENAME_EXCL)) == 0 else {
                // Another client or a retained corrupt kit must never be silently replaced.
                throw ToolchainTrustError.unsafePath
            }
            guard fsync(root.fd) == 0 else { throw ToolchainTrustError.unsafePath }
            let kit = try resolver.verifyInstalled(approved)
            let bundle = kit.installedPath + "/" + ToolchainHostBundleContract.bundle
            try bundleSignature.verify(bundlePath: bundle, expected: approved.entry.publisher)
            return InstalledToolchainHost(kit: kit, bundlePath: bundle)
        }
    }

    // The resolver owns the publisher backend. A stage is checked with the same backend before
    // publication; expose it through a narrow internal method rather than creating a new policy.
    private func signatureVerifier(_ resolver: TrustedToolchainResolver) -> any ToolchainExecutableSignatureVerifying {
        resolver.installationSignatureVerifier
    }

    private static func streamOfflineArchive(root: URL, relativePath: String, expectedBytes: Int,
                                             writeChunk: (Data) throws -> Void) throws {
        guard root.isFileURL, root.path.hasPrefix("/"),
              !root.pathComponents.contains(".."),
              relativePath.hasPrefix("Resources/Toolchains/"),
              relativePath.hasSuffix(".tar"),
              WorkspaceValidation.member(relativePath) else {
            throw ToolchainTrustError.unsafePath
        }
        var parent = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw ToolchainTrustError.unsafePath }
        defer { close(parent) }
        let parts = relativePath.split(separator: "/").map(String.init)
        for part in parts.dropLast() {
            let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw ToolchainTrustError.unsafePath }
            close(parent); parent = next
        }
        let fd = openat(parent, parts.last!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ToolchainTrustError.unsafePath }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_uid == geteuid(), before.st_nlink == 1,
              before.st_mode & mode_t(0o022) == 0,
              before.st_size == expectedBytes else { throw ToolchainTrustError.artifactMismatch }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw ToolchainTrustError.artifactMismatch }
            if count == 0 { break }
            try writeChunk(Data(chunk.prefix(count)))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_dev == after.st_dev,
              before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw ToolchainTrustError.artifactMismatch
        }
    }

    private static func removePrivateStage(_ path: String) {
        var root = stat()
        guard lstat(path, &root) == 0, root.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return }
        if let walk = FileManager.default.enumerator(atPath: path) {
            for case let relative as String in walk {
                let member = path + "/" + relative
                var info = stat()
                if lstat(member, &info) == 0 && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                    _ = chmod(member, 0o700)
                }
            }
        }
        _ = chmod(path, 0o700)
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// Release format: uncompressed POSIX ustar with regular-file members only. Every member must
/// appear once in the signed inventory; directories are synthesized, never trusted from tar.
enum StrictToolchainTar {
    static func extract(archive: String, destination: String, inventory: [ToolchainInventoryItem],
                        ensureCapacity: (Int64) throws -> Void) throws {
        let fd = open(archive, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ToolchainTrustError.artifactMismatch }
        defer { close(fd) }
        let root = open(destination, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw ToolchainTrustError.unsafePath }
        defer { close(root) }
        let expected = Dictionary(uniqueKeysWithValues: inventory.map { ($0.path, $0) })
        var seen = Set<String>()
        var directories = Set<String>()
        var offset: Int64 = 0
        var expanded: Int64 = 0
        let signedExpanded = inventory.reduce(Int64(0)) { $0 + Int64($1.bytes) }
        var writtenBytes: Int64 = 0
        var headerCount = 0
        while true {
            let header = try block(fd, at: offset)
            offset += 512
            if header.allSatisfy({ $0 == 0 }) {
                let second = try block(fd, at: offset)
                guard second.allSatisfy({ $0 == 0 }) else { throw ToolchainTrustError.artifactMismatch }
                offset += 512
                var info = stat()
                guard fstat(fd, &info) == 0 else { throw ToolchainTrustError.artifactMismatch }
                while offset < info.st_size {
                    guard try block(fd, at: offset).allSatisfy({ $0 == 0 }) else {
                        throw ToolchainTrustError.artifactMismatch
                    }
                    offset += 512
                }
                guard offset == info.st_size, seen.count == expected.count else {
                    throw ToolchainTrustError.inventoryMismatch
                }
                break
            }
            guard headerCount < 100_000 else { throw ToolchainTrustError.limitExceeded }
            headerCount += 1
            let checksum = try octal(header[148..<156])
            var copy = header
            for index in 148..<156 { copy[index] = 32 }
            guard checksum == copy.reduce(0, { $0 + Int($1) }),
                  Array(header[257..<263]) == [117, 115, 116, 97, 114, 0],
                  Array(header[263..<265]) == [48, 48],
                  header[156] == 0 || header[156] == 48 else {
                throw ToolchainTrustError.artifactMismatch
            }
            let name = try field(header[0..<100])
            let prefix = try field(header[345..<500], allowEmpty: true)
            let path = prefix.isEmpty ? name : prefix + "/" + name
            guard WorkspaceValidation.member(path), path == path.precomposedStringWithCanonicalMapping,
                  let item = expected[path], seen.insert(path).inserted else {
                throw ToolchainTrustError.inventoryMismatch
            }
            let length = try octal(header[124..<136])
            guard length == item.bytes, length <= 2_147_483_648 - expanded else {
                throw ToolchainTrustError.inventoryMismatch
            }
            expanded += Int64(length)
            let parts = path.split(separator: "/").map(String.init)
            var parent = dup(root)
            guard parent >= 0 else { throw ToolchainTrustError.unsafePath }
            do {
                var relative = ""
                for part in parts.dropLast() {
                    relative = relative.isEmpty ? part : relative + "/" + part
                    if directories.insert(relative).inserted {
                        try ensureCapacity(signedExpanded - writtenBytes)
                        guard mkdirat(parent, part, 0o700) == 0 else { throw ToolchainTrustError.unsafePath }
                    }
                    let child = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw ToolchainTrustError.unsafePath }
                    close(parent); parent = child
                }
                let output = openat(parent, parts.last!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard output >= 0 else { throw ToolchainTrustError.unsafePath }
                do {
                    var digest = SHA256()
                    var copied = 0
                    while copied < length {
                        let amount = min(64 * 1024, length - copied)
                        try ensureCapacity(signedExpanded - writtenBytes)
                        var chunk = [UInt8](repeating: 0, count: amount)
                        let got = chunk.withUnsafeMutableBytes { raw in
                            pread(fd, raw.baseAddress, amount, offset + Int64(copied))
                        }
                        guard got == amount else { throw ToolchainTrustError.artifactMismatch }
                        digest.update(data: Data(chunk))
                        var written = 0
                        while written < amount {
                            let n = chunk.withUnsafeBytes { raw in
                                Darwin.write(output, raw.baseAddress!.advanced(by: written), amount - written)
                            }
                            if n < 0 && errno == EINTR { continue }
                            guard n > 0 else { throw ToolchainTrustError.unsafePath }
                            written += n
                        }
                        copied += amount
                        writtenBytes += Int64(amount)
                        try ensureCapacity(signedExpanded - writtenBytes)
                    }
                    let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
                    guard actual == item.sha256,
                          fchmod(output, item.role == "executable" ? 0o500 : 0o400) == 0,
                          fsync(output) == 0 else { throw ToolchainTrustError.inventoryMismatch }
                } catch { close(output); throw error }
                close(output)
            } catch { close(parent); throw error }
            close(parent)
            offset += Int64(((length + 511) / 512) * 512)
        }
        for relative in directories.sorted(by: { $0.split(separator: "/").count > $1.split(separator: "/").count }) {
            let child = openat(root, relative, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw ToolchainTrustError.unsafePath }
            let success = fchmod(child, 0o500) == 0 && fsync(child) == 0
            close(child)
            guard success else { throw ToolchainTrustError.unsafePath }
        }
        guard fchmod(root, 0o500) == 0, fsync(root) == 0 else { throw ToolchainTrustError.unsafePath }
    }

    private static func block(_ fd: Int32, at offset: Int64) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 512)
        let amount = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, 512, offset) }
        guard amount == 512 else { throw ToolchainTrustError.artifactMismatch }
        return bytes
    }
    private static func field(_ bytes: ArraySlice<UInt8>, allowEmpty: Bool = false) throws -> String {
        let content = bytes.prefix(while: { $0 != 0 })
        guard bytes.dropFirst(content.count).allSatisfy({ $0 == 0 }),
              let value = String(bytes: content, encoding: .utf8), (allowEmpty || !value.isEmpty) else {
            throw ToolchainTrustError.artifactMismatch
        }
        return value
    }
    private static func octal(_ bytes: ArraySlice<UInt8>) throws -> Int {
        let characters = bytes.prefix(while: { $0 != 0 && $0 != 32 })
        guard let value = String(bytes: characters, encoding: .ascii), !value.isEmpty,
              value.utf8.allSatisfy({ (48...55).contains($0) }),
              let number = Int(value, radix: 8), number >= 0,
              bytes.dropFirst(characters.count).allSatisfy({ $0 == 0 || $0 == 32 }) else {
            throw ToolchainTrustError.artifactMismatch
        }
        return number
    }
}
#endif
