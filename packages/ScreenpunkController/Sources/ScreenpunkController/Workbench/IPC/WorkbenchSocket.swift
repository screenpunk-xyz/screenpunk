import Foundation
#if os(macOS)
import Darwin

final class WorkbenchFrameBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let maximum: Int
    private var used = 0
    init(maximum: Int) { self.maximum = maximum }
    func reserve(_ count: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard count <= maximum - used else { throw WorkbenchIPCError(.resourceLimit) }; used += count
    }
    var currentUsage: Int { lock.lock(); defer { lock.unlock() }; return used }
    func release(_ count: Int) { lock.lock(); used -= count; lock.unlock() }
}
enum WorkbenchSocket {
    static func make() throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WorkbenchIPCError(.unavailable) }
        var one: Int32 = 1
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0
        else { close(fd); throw WorkbenchIPCError(.unavailable) }
        return fd
    }
    static func configureAccepted(_ fd: Int32) throws {
        var one: Int32 = 1
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0
        else { throw WorkbenchIPCError(.unavailable) }
    }
    static func address<T>(_ path: String, _ action: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        let bytes = Array(path.utf8) + [0]
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { throw WorkbenchIPCError(.invalidConfiguration) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in raw.copyBytes(from: bytes) }
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { action($0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    }
    static func wait(_ fd: Int32, events: Int16, deadline: TimeInterval, clock: any WorkbenchClock) throws {
        while true {
            let remaining = deadline - clock.now()
            guard remaining.isFinite, remaining > 0 else { throw WorkbenchIPCError(.timedOut) }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let n = Darwin.poll(&descriptor, 1, Int32(min(100, max(1, ceil(remaining * 1000)))))
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw WorkbenchIPCError(.disconnected) }
            if n == 0 { continue }
            if descriptor.revents & events != 0 { return }
            if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { throw WorkbenchIPCError(.disconnected) }
        }
    }
    static func read(_ fd: Int32, count: Int, deadline: TimeInterval, clock: any WorkbenchClock) throws -> Data {
        var data = Data(count: count); var offset = 0
        try data.withUnsafeMutableBytes { raw in
            while offset < count {
                try wait(fd, events: Int16(POLLIN), deadline: deadline, clock: clock)
                let n = Darwin.recv(fd, raw.baseAddress!.advanced(by: offset), count - offset, 0)
                if n < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                guard n > 0 else { throw WorkbenchIPCError(.disconnected) }; offset += n
            }
        }
        return data
    }
    static func readFrame(_ fd: Int32, environment: WorkbenchBrokerEnvironment, budget: WorkbenchFrameBudget? = nil, deadline explicitDeadline: TimeInterval? = nil, idleDeadline: TimeInterval? = nil) throws -> Data {
        let deadline = explicitDeadline ?? idleDeadline ?? (environment.clock.now() + environment.limits.timeout)
        let header: Data
        if idleDeadline != nil {
            var first = try read(fd, count: 1, deadline: deadline, clock: environment.clock)
            first.append(try read(fd, count: 3,
                                  deadline: environment.clock.now() + environment.limits.timeout,
                                  clock: environment.clock))
            header = first
        } else {
            header = try read(fd, count: 4, deadline: deadline, clock: environment.clock)
        }
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0 else { throw WorkbenchIPCError(.invalidRequest) }
        guard length <= environment.limits.maxFrameBytes else { throw WorkbenchIPCError(.frameTooLarge) }
        try budget?.reserve(Int(length)); defer { budget?.release(Int(length)) }
        // An interactive review can leave the socket idle until its ticket
        // expires, but a frame that has started must still finish promptly.
        let bodyDeadline = idleDeadline == nil ? deadline : environment.clock.now() + environment.limits.timeout
        return try read(fd, count: Int(length), deadline: bodyDeadline, clock: environment.clock)
    }
    static func writeFrame(_ fd: Int32, bytes: Data, environment: WorkbenchBrokerEnvironment, deadline explicitDeadline: TimeInterval? = nil) throws {
        guard !bytes.isEmpty, bytes.count <= environment.limits.maxFrameBytes else { throw WorkbenchIPCError(.frameTooLarge) }
        let size = UInt32(bytes.count)
        var data = Data([UInt8((size >> 24) & 255), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)])
        data.append(bytes); let deadline = explicitDeadline ?? (environment.clock.now() + environment.limits.timeout); var offset = 0
        try data.withUnsafeBytes { raw in
            while offset < data.count {
                try wait(fd, events: Int16(POLLOUT), deadline: deadline, clock: environment.clock)
                let n = Darwin.send(fd, raw.baseAddress!.advanced(by: offset), data.count - offset, 0)
                if n < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                guard n > 0 else { throw WorkbenchIPCError(.disconnected) }; offset += n
            }
        }
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
}
#endif
