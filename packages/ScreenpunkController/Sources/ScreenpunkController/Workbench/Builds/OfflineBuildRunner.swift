import Foundation

enum OfflineBuildError: Error, Equatable {
    case isolatedExecutorUnavailable, invalidResponse, buildFailed(String), outputLimit
}

struct OfflineBuildRequest {
    let projectID: String
    let snapshotPath: String
    let stagingPath: String
    let expectedSourceVersion: String
}

struct OfflineBuildResult {
    let stagingPath: String
    let diagnostics: String
}

@objc private protocol OfflineBuildXPC {
    func prepare(_ request: Data, reply: @escaping (Data) -> Void)
    func upload(_ jobID: String, path: String, offset: Int64, bytes: Data,
                finalSHA256: String?, reply: @escaping (Data) -> Void)
    func execute(_ jobID: String, reply: @escaping (Data) -> Void)
    func download(_ jobID: String, path: String, offset: Int64, reply: @escaping (Data) -> Void)
    func cancel(_ jobID: String, reply: @escaping (Data) -> Void)
    func release(_ jobID: String, reply: @escaping (Data) -> Void)
}

private struct OfflineBuildMessage: Encodable {
    let version = 1
    let projectID: String
    let jobID: String
    let kitDirectory: String
    let expectedSourceVersion: String
}

private struct OfflineBuildReply: Decodable {
    let code: String
    let detail: String
    let files: [OfflineBuildOutputFile]?
    let diagnostics: String?
}

enum OfflineBuildRunner {
    private static let serviceName = "xyz.screenpunk.build-service"
    private static let chunkBytes = 256 * 1024

    static func run(_ request: OfflineBuildRequest, kit: VerifiedToolchainKit,
                    resolver: TrustedToolchainResolver,
                    isCancelled: @escaping () -> Bool = { false }) throws -> OfflineBuildResult {
        let verified = try resolver.verifyForUse(kit)
        let serviceBundle = Bundle.main.bundleURL
            .appendingPathComponent("Contents/XPCServices/ScreenpunkBuildService.xpc", isDirectory: true)
        let serviceBinary = serviceBundle.appendingPathComponent("Contents/MacOS/ScreenpunkBuildService")
        let expectedKit = serviceBundle.appendingPathComponent("Contents/Resources/AuthoringKit")
            .appendingPathComponent(verified.approved.directoryName)
        guard FileManager.default.fileExists(atPath: serviceBinary.path),
              verified.installedPath == expectedKit.path else { throw OfflineBuildError.isolatedExecutorUnavailable }
        let inputs = try OfflineBuildInputPlan.capture(URL(fileURLWithPath: request.snapshotPath),
            deadline: ProcessInfo.processInfo.systemUptime + 120, cancelled: isCancelled)
        let jobID = UUID().uuidString
        let message = OfflineBuildMessage(projectID: request.projectID, jobID: jobID,
                                          kitDirectory: verified.approved.directoryName,
                                          expectedSourceVersion: request.expectedSourceVersion)
        let envelope = try JSONEncoder().encode(message)
        guard envelope.count <= 16 * 1024 else { throw OfflineBuildError.invalidResponse }

        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: OfflineBuildXPC.self)
        connection.resume()
        defer { connection.invalidate() }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in }) as? OfflineBuildXPC else {
            throw OfflineBuildError.isolatedExecutorUnavailable
        }
        try requireOK(call(seconds: 5) { proxy.prepare(envelope, reply: $0) })
        defer { _ = try? call(seconds: 5) { proxy.release(jobID, reply: $0) } }

        for input in inputs.files {
            var offset = 0
            repeat {
                if isCancelled() { _ = try? call(seconds: 5) { proxy.cancel(jobID, reply: $0) }; throw OfflineBuildError.buildFailed("cancelled") }
                let end = min(input.bytes.count, offset + chunkBytes)
                let chunk = input.bytes.subdata(in: offset..<end)
                let final = end == input.bytes.count ? input.sha256 : nil
                try requireOK(call(seconds: 5) {
                    proxy.upload(jobID, path: input.relativePath, offset: Int64(offset),
                                 bytes: chunk, finalSHA256: final, reply: $0)
                })
                offset = end
            } while offset < input.bytes.count
        }

        var cancellationSent = false
        let response = try call(seconds: 125, cancellation: {
            if !cancellationSent && isCancelled() {
                cancellationSent = true
                proxy.cancel(jobID) { _ in }
            }
        }, onTimeout: {
            proxy.cancel(jobID) { _ in }
        }) { proxy.execute(jobID, reply: $0) }
        let build = try requireOK(response)
        guard let files = build.files, !files.isEmpty, files.count <= 2000,
              (build.diagnostics?.utf8.count ?? 0) <= 32 * 1024 else { throw OfflineBuildError.invalidResponse }
        let destination = URL(fileURLWithPath: request.stagingPath)
        try OfflineBuildOutputStage.save(files, to: destination) { path, offset in
                if isCancelled() { proxy.cancel(jobID) { _ in }; throw OfflineBuildError.buildFailed("cancelled") }
                let packet = try call(seconds: 5) { proxy.download(jobID, path: path, offset: offset, reply: $0) }
                guard packet.first == 1, packet.count > 1,
                      packet.count - 1 <= chunkBytes,
                      packet.count - 1 <= OfflineBuildOutputStage.chunkBytes else { throw OfflineBuildError.invalidResponse }
                return Data(packet.dropFirst())
        }
        // expectedSourceVersion is a caller label until the authoring snapshot/CAS layer binds
        // these captured bytes to its canonical source hash. Do not echo it as verified output.
        return OfflineBuildResult(stagingPath: destination.path, diagnostics: build.diagnostics ?? "")
    }

    private static func call(seconds: Int, cancellation: (() -> Void)? = nil,
                             onTimeout: (() -> Void)? = nil,
                             _ invoke: (@escaping (Data) -> Void) -> Void) throws -> Data {
        let ready = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: Data?
        invoke { data in lock.lock(); result = data; lock.unlock(); ready.signal() }
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while ready.wait(timeout: .now() + .milliseconds(50)) != .success {
            cancellation?()
            if Date() >= deadline { onTimeout?(); throw OfflineBuildError.isolatedExecutorUnavailable }
        }
        lock.lock(); defer { lock.unlock() }
        guard let result, result.count <= 2 * 1024 * 1024 else { throw OfflineBuildError.invalidResponse }
        return result
    }

    @discardableResult private static func requireOK(_ response: Data) throws -> OfflineBuildReply {
        guard let reply = try? JSONDecoder().decode(OfflineBuildReply.self, from: response) else {
            throw OfflineBuildError.invalidResponse
        }
        guard reply.code == "ok" else {
            let diagnostic = String((reply.diagnostics ?? "").prefix(32 * 1024))
            throw OfflineBuildError.buildFailed(String(reply.detail.prefix(4096)) + (diagnostic.isEmpty ? "" : "\n" + diagnostic))
        }
        return reply
    }

}
