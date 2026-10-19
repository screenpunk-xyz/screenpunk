import Foundation
#if os(macOS)
import Darwin

/// Binds only IPv4 loopback before opening the browser; never serves project files.
public final class ControllerCloudLoopback: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    public let redirectURI: String
    public init(port: UInt16 = 43871) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControllerCloudError.invalidConfiguration }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0, listen(fd, 4) == 0 else { Darwin.close(fd); throw ControllerCloudError.invalidConfiguration }
        descriptor = fd; redirectURI = "http://127.0.0.1:\(port)/callback"
    }
    deinit { close() }
    public func close() { lock.lock(); defer { lock.unlock() }; if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } }
    private func currentFD() -> Int32 { lock.lock(); defer { lock.unlock() }; return descriptor }
    public func callback(timeout: TimeInterval = 180) async throws -> URL {
        let operation = Task.detached { [self] () throws -> URL in
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                try Task.checkCancellation()
                let fd = currentFD(); guard fd >= 0 else { throw CancellationError() }
                var waiting = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let readiness = poll(&waiting, 1, 200)
                if readiness == 0 { continue }
                guard readiness > 0 else { throw ControllerCloudError.invalidCallback }
                let peer = accept(fd, nil, nil); guard peer >= 0 else { continue }
                defer { Darwin.close(peer) }
                var peerWaiting = pollfd(fd: peer, events: Int16(POLLIN), revents: 0)
                guard poll(&peerWaiting, 1, 2000) > 0 else { continue }
                var bytes = [UInt8](repeating: 0, count: 8192)
                let count = recv(peer, &bytes, bytes.count, 0)
                guard count > 0, let request = String(bytes: bytes.prefix(count), encoding: .utf8),
                      let first = request.components(separatedBy: "\r\n").first else { continue }
                let words = first.split(separator: " ")
                guard words.count == 3, words[0] == "GET", words[1].hasPrefix("/callback?"),
                      let callback = URL(string: "http://127.0.0.1:" + String(URL(string: redirectURI)!.port!) + String(words[1])) else { continue }
                let message = "You can return to Screenpunk."
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(message.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n" + message
                _ = response.withCString { send(peer, $0, response.utf8.count, 0) }
                return callback
            }
            throw ControllerCloudError.invalidCallback
        }
        return try await withTaskCancellationHandler(operation: { try await operation.value }, onCancel: { operation.cancel() })
    }
}
#endif
