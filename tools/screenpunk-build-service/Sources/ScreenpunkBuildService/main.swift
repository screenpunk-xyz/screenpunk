import Foundation
import Security

@objc protocol ScreenpunkBuildXPC {
    func prepare(_ request: Data, reply: @escaping (Data) -> Void)
    func upload(_ jobID: String, path: String, offset: Int64, bytes: Data,
                finalSHA256: String?, reply: @escaping (Data) -> Void)
    func execute(_ jobID: String, reply: @escaping (Data) -> Void)
    func download(_ jobID: String, path: String, offset: Int64, reply: @escaping (Data) -> Void)
    func cancel(_ jobID: String, reply: @escaping (Data) -> Void)
    func release(_ jobID: String, reply: @escaping (Data) -> Void)
}

struct BuildEnvelope: Codable {
    let version: Int
    let projectID: String
    let jobID: String
    let kitDirectory: String
    let expectedSourceVersion: String
}

struct BuildResponse: Codable {
    let code: String
    let detail: String
    let files: [BuildOutputFile]?
    let diagnostics: String?
}

struct BuildOutputFile: Codable {
    let path: String
    let bytes: Int64
    let sha256: String
}

enum BuildRequestValidation {
    static let maximumMessageBytes = 16 * 1024
    static let maximumChunkBytes = 256 * 1024
    private static let identifier = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
    private static let digest = try! NSRegularExpression(pattern: "^[a-f0-9]{64}$")
    private static let member = try! NSRegularExpression(pattern: "^[A-Za-z0-9_.@/-]{1,512}$")
    private static let sourceExtension = try! NSRegularExpression(pattern: "\\.(tsx?|jsx?|json|css|svg|png|jpe?g|webp|woff2?)$", options: [.caseInsensitive])
    private static let forbiddenNames: Set<String> = ["tsconfig.json", "jsconfig.json", "package.json", "package-lock.json", "yarn.lock", "pnpm-lock.yaml", ".npmrc"]

    static func decode(_ bytes: Data) throws -> BuildEnvelope {
        guard bytes.count <= maximumMessageBytes else { throw Failure.invalidRequest }
        let request = try JSONDecoder().decode(BuildEnvelope.self, from: bytes)
        guard request.version == 1,
              valid(request.projectID, with: identifier), valid(request.jobID, with: identifier),
              valid(request.kitDirectory, with: identifier),
              valid(request.expectedSourceVersion, with: digest),
              !request.kitDirectory.contains("..") else { throw Failure.invalidRequest }
        return request
    }

    static func sourceMember(_ path: String) -> Bool {
        guard valid(path, with: member), valid(path, with: sourceExtension, whole: false),
              !path.hasPrefix("/"), !path.contains("//"), !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return false }
        let names = path.split(separator: "/").map(String.init)
        return names.count <= 32 && !names.contains(where: { forbiddenNames.contains($0.lowercased()) || $0.lowercased() == "node_modules" || $0.lowercased() == "dist" || $0.lowercased().hasPrefix(".env") || $0.lowercased().contains(".config.") })
    }

    static func identifierValue(_ value: String) -> Bool { valid(value, with: identifier) }
    static func digestValue(_ value: String) -> Bool { valid(value, with: digest) }

    private static func valid(_ value: String, with expression: NSRegularExpression, whole: Bool = true) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = expression.firstMatch(in: value, range: range) else { return false }
        return !whole || match.range == range
    }

    enum Failure: Error { case invalidRequest }
}

enum BuildServiceIsolation {
    static func isNetworkDeniedSandbox() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let sandbox = SecTaskCopyValueForEntitlement(task, "com.apple.security.app-sandbox" as CFString, nil)
        let networkClient = SecTaskCopyValueForEntitlement(task, "com.apple.security.network.client" as CFString, nil)
        let networkServer = SecTaskCopyValueForEntitlement(task, "com.apple.security.network.server" as CFString, nil)
        return (sandbox as? Bool) == true && networkClient == nil && networkServer == nil
    }
}

final class BuildService: NSObject, NSXPCListenerDelegate {
    private let jobs = BuildJobs()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard BuildServiceIsolation.isNetworkDeniedSandbox() else { return false }
        let session = BuildSession(jobs: jobs)
        connection.exportedInterface = NSXPCInterface(with: ScreenpunkBuildXPC.self)
        connection.exportedObject = session
        connection.invalidationHandler = { [weak session] in session?.close() }
        connection.interruptionHandler = { [weak session] in session?.close() }
        connection.resume()
        return true
    }
}

private final class BuildSession: NSObject, ScreenpunkBuildXPC {
    private let jobs: BuildJobs
    private let lock = NSLock()
    private var owned: Set<String> = []
    private var closed = false

    init(jobs: BuildJobs) { self.jobs = jobs }

    private func owns(_ jobID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !closed && owned.contains(jobID)
    }

    func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        let identifiers = owned
        lock.unlock()
        for jobID in identifiers { try? jobs.cancel(jobID) }
        DispatchQueue.global(qos: .utility).async { [jobs] in
            for jobID in identifiers {
                let deadline = Date().addingTimeInterval(3)
                while Date() < deadline {
                    if (try? jobs.release(jobID)) != nil { break }
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
        }
    }

    private func encoded(_ response: BuildResponse) -> Data {
        (try? JSONEncoder().encode(response)) ?? Data()
    }

    private func outcome(_ work: () throws -> BuildResponse) -> Data {
        guard BuildServiceIsolation.isNetworkDeniedSandbox() else {
            return encoded(BuildResponse(code: "isolation_unavailable", detail: "Required App Sandbox is absent", files: nil, diagnostics: nil))
        }
        do { return encoded(try work()) }
        catch { return encoded(BuildResponse(code: "build_failed", detail: String(describing: error).prefix(4096).description, files: nil, diagnostics: nil)) }
    }

    func prepare(_ request: Data, reply: @escaping (Data) -> Void) {
        reply(outcome {
            let envelope = try BuildRequestValidation.decode(request)
            lock.lock(); let open = !closed; lock.unlock()
            guard open else { throw BuildJobError.invalidJob }
            try jobs.prepare(envelope)
            lock.lock()
            if closed { lock.unlock(); try? jobs.release(envelope.jobID); throw BuildJobError.invalidJob }
            owned.insert(envelope.jobID)
            lock.unlock()
            return BuildResponse(code: "ok", detail: "prepared", files: nil, diagnostics: nil)
        })
    }

    func upload(_ jobID: String, path: String, offset: Int64, bytes: Data,
                finalSHA256: String?, reply: @escaping (Data) -> Void) {
        reply(outcome { guard owns(jobID) else { throw BuildJobError.invalidJob }; try jobs.upload(jobID, path: path, offset: offset, bytes: bytes, finalSHA256: finalSHA256); return BuildResponse(code: "ok", detail: "uploaded", files: nil, diagnostics: nil) })
    }

    func execute(_ jobID: String, reply: @escaping (Data) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            reply(self.outcome { guard self.owns(jobID) else { throw BuildJobError.invalidJob }; return try self.jobs.execute(jobID) })
        }
    }

    func download(_ jobID: String, path: String, offset: Int64, reply: @escaping (Data) -> Void) {
        guard BuildServiceIsolation.isNetworkDeniedSandbox(), owns(jobID),
              let chunk = try? jobs.download(jobID, path: path, offset: offset) else { reply(Data([0])); return }
        var response = Data([1]); response.append(chunk); reply(response)
    }

    func cancel(_ jobID: String, reply: @escaping (Data) -> Void) {
        reply(outcome { guard owns(jobID) else { throw BuildJobError.invalidJob }; try jobs.cancel(jobID); return BuildResponse(code: "ok", detail: "cancelled", files: nil, diagnostics: nil) })
    }

    func release(_ jobID: String, reply: @escaping (Data) -> Void) {
        reply(outcome {
            guard owns(jobID) else { throw BuildJobError.invalidJob }
            try jobs.release(jobID)
            lock.lock(); owned.remove(jobID); lock.unlock()
            return BuildResponse(code: "ok", detail: "released", files: nil, diagnostics: nil)
        })
    }
}

let service = BuildService()
let listener = NSXPCListener.service()
listener.delegate = service
listener.resume()
