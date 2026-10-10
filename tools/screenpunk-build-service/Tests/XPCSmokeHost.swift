import Foundation
import CryptoKit

@objc protocol SmokeBuildXPC {
    func prepare(_ request: Data, reply: @escaping (Data) -> Void)
    func upload(_ jobID: String, path: String, offset: Int64, bytes: Data,
                finalSHA256: String?, reply: @escaping (Data) -> Void)
    func execute(_ jobID: String, reply: @escaping (Data) -> Void)
    func download(_ jobID: String, path: String, offset: Int64, reply: @escaping (Data) -> Void)
    func release(_ jobID: String, reply: @escaping (Data) -> Void)
}

func call(_ action: (@escaping (Data) -> Void) -> Void) -> Data {
    let ready = DispatchSemaphore(value: 0)
    var result = Data()
    action { bytes in result = bytes; ready.signal() }
    guard ready.wait(timeout: .now() + .seconds(8)) == .success else { fatalError("XPC timeout") }
    return result
}

let connection = NSXPCConnection(serviceName: "xyz.screenpunk.build-service")
connection.remoteObjectInterface = NSXPCInterface(with: SmokeBuildXPC.self)
connection.resume()
defer { connection.invalidate() }
guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in print("XPC error: \(error)") }) as? SmokeBuildXPC else {
    fatalError("XPC proxy unavailable")
}
let source = Data("export {}".utf8)
let hash = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
let request = Data("""
{"version":1,"projectID":"smoke","jobID":"job-1","kitDirectory":"fixture","expectedSourceVersion":"\(String(repeating: "a", count: 64))"}
""".utf8)
let prepared = call { proxy.prepare(request, reply: $0) }
print("PREPARE \(String(decoding: prepared, as: UTF8.self))")
let uploaded = call { proxy.upload("job-1", path: "src/main.tsx", offset: 0, bytes: source, finalSHA256: hash, reply: $0) }
print("UPLOAD \(String(decoding: uploaded, as: UTF8.self))")
let executed = call { proxy.execute("job-1", reply: $0) }
print("EXECUTE \(String(decoding: executed, as: UTF8.self))")
let outcome = (try? JSONSerialization.jsonObject(with: executed)) as? [String: Any]
let tampered = ProcessInfo.processInfo.environment["SCREENPUNK_TAMPER_SMOKE"] == "1"
precondition(outcome?["code"] as? String == (tampered ? "build_failed" : "ok"))
let downloaded = call { proxy.download("job-1", path: "sandbox.json", offset: 0, reply: $0) }
print("RESULT \(String(decoding: downloaded.dropFirst(), as: UTF8.self))")
if !tampered {
    precondition(downloaded.first == 1)
    let result = (try? JSONSerialization.jsonObject(with: downloaded.dropFirst())) as? [String: String]
    precondition(result?["outside"] == "denied" && result?["network"] == "denied")
}
_ = call { proxy.release("job-1", reply: $0) }
