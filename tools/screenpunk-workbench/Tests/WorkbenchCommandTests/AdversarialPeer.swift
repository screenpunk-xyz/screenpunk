import Foundation
import Darwin

/// Test-only local peer: deliberately emits a single invalid authentication response.
/// It is a wire fixture, never an alternate broker implementation.
final class AdversarialPeer {
    let listener: Int32
    let completed = DispatchSemaphore(value: 0)
    init(runtime: URL, response: Data?, pause: Double = 0) throws {
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let instance = UUID().uuidString.lowercased()
        let locator = try JSONSerialization.data(withJSONObject: ["apiVersion": "1.0", "instanceId": instance,
            "socketFile": "broker.sock", "tokenFile": "broker.token"])
        let token = Data(repeating: 0x41, count: 32)
        for (name, bytes) in [("broker.token", token), ("broker.locator.json", locator)] {
            try bytes.write(to: runtime.appendingPathComponent(name))
            chmod(runtime.appendingPathComponent(name).path, 0o600)
        }
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw NSError(domain: "fixture", code: 1) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(runtime.appendingPathComponent("broker.sock").path.utf8) + [0]
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw NSError(domain: "fixture", code: 2) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 1) == 0 else { close(listener); throw NSError(domain: "fixture", code: 3) }
        chmod(runtime.appendingPathComponent("broker.sock").path, 0o600)
        let fd = listener
        let done = completed
        DispatchQueue.global().async {
            let peer = accept(fd, nil, nil)
            defer { if peer >= 0 { close(peer) }; done.signal() }
            guard peer >= 0 else { return }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noSignal: Int32 = 1
            setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var buffer = [UInt8](repeating: 0, count: 4096)
            guard read(peer, &buffer, buffer.count) > 0 else { return }
            if pause > 0 { Thread.sleep(forTimeInterval: pause) }
            if let response {
                var length = UInt32(response.count).bigEndian
                var frame = withUnsafeBytes(of: &length) { Data($0) }
                frame.append(response)
                frame.withUnsafeBytes { _ = Darwin.write(peer, $0.baseAddress, $0.count) }
            }
        }
    }
    deinit { shutdown(listener, SHUT_RDWR); close(listener); _ = completed.wait(timeout: .now() + 3) }
}
