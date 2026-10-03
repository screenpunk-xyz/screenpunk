import Foundation

#if os(macOS)
import Darwin
import IOKit

/// Candidate production source for the M4 clock. It remains unwired while the
/// deployment route and owner-bound ledger are disabled. Every failed read
/// yields a clock value that the ledger rejects, never a generated boot ID.
struct WorkbenchTrustedClock {
    struct Source {
        let bootSessionID: () -> String?
        let wallTime: () -> TimeInterval
        let monotonicNanoseconds: () -> UInt64?

        static let system = Source(
            bootSessionID: {
                guard let matching = IOServiceMatching("IOPMrootDomain") else { return nil }
                let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
                guard service != IO_OBJECT_NULL else { return nil }
                defer { IOObjectRelease(service) }
                guard let value = IORegistryEntryCreateCFProperty(service,
                    "BootSessionUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else { return nil }
                return value as? String
            },
            wallTime: { Date().timeIntervalSince1970 },
            monotonicNanoseconds: {
                let value = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
                return value == 0 ? nil : value
            })
    }

    private let source: Source
    init(source: Source = .system) { self.source = source }

    func sample() -> WorkbenchDeploymentClock {
        let before = source.bootSessionID()
        let wall = source.wallTime()
        let monotonic = source.monotonicNanoseconds()
        let after = source.bootSessionID()
        guard let before, let after, let first = UUID(uuidString: before),
              let last = UUID(uuidString: after), first == last,
              wall.isFinite, wall > 0, wall < Double(Int64.max),
              let monotonic, monotonic > 0 else {
            return .init(wallSeconds: 0, monotonicMilliseconds: -1, bootId: "")
        }
        return .init(wallSeconds: Int64(wall.rounded(.down)),
                     monotonicMilliseconds: Int64(monotonic / 1_000_000),
                     bootId: first.uuidString.lowercased())
    }
}
#endif
