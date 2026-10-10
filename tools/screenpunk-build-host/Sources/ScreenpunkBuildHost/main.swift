import Foundation
import Darwin

@objc private protocol BuildServiceXPC {
    func prepare(_ request: Data, reply: @escaping (Data) -> Void)
    func upload(_ jobID: String, path: String, offset: Int64, bytes: Data,
                finalSHA256: String?, reply: @escaping (Data) -> Void)
    func execute(_ jobID: String, reply: @escaping (Data) -> Void)
    func download(_ jobID: String, path: String, offset: Int64, reply: @escaping (Data) -> Void)
    func cancel(_ jobID: String, reply: @escaping (Data) -> Void)
    func release(_ jobID: String, reply: @escaping (Data) -> Void)
}

private struct Request: Decodable {
    let version: Int
    let id: Int
    let action: String
    let projectID: String?
    let jobID: String?
    let sourceVersion: String?
    let path: String?
    let offset: Int64?
    let bytes: Data?
    let finalSHA256: String?
}

private struct Response: Encodable {
    let id: Int
    let payload: Data
}

private struct Prepare: Encodable {
    let version = 1
    let projectID: String
    let jobID: String
    let kitDirectory: String
    let expectedSourceVersion: String
}

/// Framing uses a four-byte big-endian length. The host has no executable, environment,
/// service-name, absolute-path, or runtime-URL field in its input language.
private final class Host {
    private let connection: NSXPCConnection
    private let kitDirectory: String
    private let output = NSLock()
    private let state = NSLock()
    private var jobID: String?
    private var closed = false
    private let inputFD = STDIN_FILENO
    private let outputFD = STDOUT_FILENO
    private let maxFrame = 512 * 1024

    init?() {
        guard fcntl(STDOUT_FILENO, F_SETNOSIGPIPE, 1) == 0 else { return nil }
        guard let kit = Bundle.main.object(forInfoDictionaryKey: "ScreenpunkKitDirectory") as? String,
              !kit.isEmpty, kit.utf8.count <= 160,
              kit.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
              !kit.contains(".."),
              FileManager.default.fileExists(atPath: Bundle.main.bundlePath +
                "/Contents/XPCServices/ScreenpunkBuildService.xpc/Contents/Resources/AuthoringKit/" +
                kit + "/kit.json") else { return nil }
        kitDirectory = kit
        connection = NSXPCConnection(serviceName: "xyz.screenpunk.build-service")
        connection.remoteObjectInterface = NSXPCInterface(with: BuildServiceXPC.self)
        connection.resume()
    }

    deinit { connection.invalidate() }

    func run() {
        while let frame = readFrame() {
            guard let request = try? JSONDecoder().decode(Request.self, from: frame),
                  request.version == 1, request.id >= 0 else { break }
            handle(request)
        }
        state.lock(); closed = true; state.unlock()
        connection.invalidate()
    }

    private func handle(_ request: Request) {
        guard let job = request.jobID, job.utf8.count <= 128,
              job.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            reply(request.id, Data()); return
        }
        state.lock()
        let permitted: Bool
        if request.action == "prepare" && jobID == nil {
            jobID = job; permitted = true
        } else { permitted = jobID == job && !closed }
        state.unlock()
        guard permitted else { reply(request.id, Data()); return }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            fputs("Build service XPC error: \(error)\n", stderr)
            self?.reply(request.id, Data())
        }) as? BuildServiceXPC else { reply(request.id, Data()); return }
        switch request.action {
        case "prepare":
            guard let project = request.projectID, project.utf8.count <= 128,
                  let version = request.sourceVersion, version.utf8.count == 64,
                  let encoded = try? JSONEncoder().encode(Prepare(projectID: project, jobID: job,
                    kitDirectory: kitDirectory, expectedSourceVersion: version)),
                  encoded.count <= 16 * 1024 else { reply(request.id, Data()); return }
            proxy.prepare(encoded) { [self] in reply(request.id, $0) }
        case "upload":
            guard let path = request.path, path.utf8.count <= 512,
                  let offset = request.offset, offset >= 0,
                  let bytes = request.bytes, bytes.count <= 256 * 1024 else {
                reply(request.id, Data()); return
            }
            proxy.upload(job, path: path, offset: offset, bytes: bytes,
                         finalSHA256: request.finalSHA256) { [self] in reply(request.id, $0) }
        case "execute":
            proxy.execute(job) { [self] in reply(request.id, $0) }
        case "download":
            guard let path = request.path, path.utf8.count <= 512,
                  let offset = request.offset, offset >= 0 else { reply(request.id, Data()); return }
            proxy.download(job, path: path, offset: offset) { [self] in reply(request.id, $0) }
        case "cancel":
            proxy.cancel(job) { [self] in reply(request.id, $0) }
        case "release":
            proxy.release(job) { [self] in
                state.lock(); jobID = nil; state.unlock()
                reply(request.id, $0)
            }
        default: reply(request.id, Data())
        }
    }

    private func reply(_ id: Int, _ payload: Data) {
        let bounded = payload.count <= 2 * 1024 * 1024 ? payload : Data()
        guard let encoded = try? JSONEncoder().encode(Response(id: id, payload: bounded)),
              encoded.count <= 3 * 1024 * 1024 else { return }
        var length = UInt32(encoded.count).bigEndian
        output.lock(); defer { output.unlock() }
        _ = withUnsafeBytes(of: &length) { writeAll($0.baseAddress!, $0.count) }
        _ = encoded.withUnsafeBytes { writeAll($0.baseAddress!, $0.count) }
    }

    private func writeAll(_ pointer: UnsafeRawPointer, _ count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let n = Darwin.write(outputFD, pointer.advanced(by: offset), count - offset)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return false }
            offset += n
        }
        return true
    }

    private func readFrame() -> Data? {
        guard let header = readExact(4), header.count == 4 else { return nil }
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= maxFrame else { return nil }
        return readExact(Int(length))
    }

    private func readExact(_ count: Int) -> Data? {
        var result = Data(count: count)
        let success = result.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < count {
                let n = Darwin.read(inputFD, base.advanced(by: offset), count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
        return success ? result : nil
    }
}

guard let host = Host() else { exit(78) }
host.run()
