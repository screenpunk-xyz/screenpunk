import Foundation
import ScreenpunkCore

/// Shared composition used by the Mac canvas, preview helper and paired device.
public final class PublicReadSession: @unchecked Sendable {
    public let runtime: PublicReadRuntime
    public let resources: PublicRasterResources
    private final class Lease: @unchecked Sendable {
        let lock = NSLock(); var active = true
        func valid() -> Bool { lock.lock(); defer { lock.unlock() }; return active }
        func close() { lock.lock(); active = false; lock.unlock() }
    }
    private let lease: Lease
    public init(provisioning: PublicReadProvisioning, transport: any HTTPTransport = HomeAssistantHTTPTransport(),
                resolver: any DestinationResolver = LiteralOrResolvedDestinationResolver(), isCurrent: @escaping @Sendable () -> Bool = { true }) throws {
        let lease = Lease(); self.lease = lease
        let current: @Sendable () -> Bool = { lease.valid() && isCurrent() }
        runtime = try PublicReadRuntime(provisioning: provisioning, transport: transport, resolver: resolver, isCurrent: current)
        resources = PublicRasterResources(isCurrent: current)
    }
    public func cancel() { lease.close(); resources.clear(); let runtime = runtime; Task { await runtime.cancel() } }
    deinit { cancel() }
}

