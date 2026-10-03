import Foundation

/// Pure proposals only. No persistence, transport or current-authority assertion.
/// Wire fields follow Cloud commit e7029fecc86a48934f48ca55604ce92c22dd2604.
/// Deliberately Encodable only: raw JSON admission requires a separate duplicate-key
/// and unknown-field qualifier before a decoder may be exposed.
public enum NativeEnrollmentFailure: Error, Equatable { case invalidInput, mismatchedEvidence, illegalSuccessor, capacityExceeded }
public struct NativeClaimInput: Encodable, Equatable, Sendable {
    public let requestId: UUID, transitionId: UUID, accountId: UUID, locationId: UUID
    public let name: String, profile: String
    public init(requestId: UUID, transitionId: UUID, accountId: UUID, locationId: UUID, name: String, profile: String) throws {
        for value in [name, profile] {
            let scalars = value.unicodeScalars
            guard (1...128).contains(scalars.count), scalars.contains(where: { !Self.trimmedScalar($0.value) }),
                  !scalars.contains(where: { $0.properties.generalCategory == .control }) else { throw NativeEnrollmentFailure.invalidInput }
        }
        guard requestId != transitionId else { throw NativeEnrollmentFailure.invalidInput }
        self.requestId = requestId; self.transitionId = transitionId; self.accountId = accountId; self.locationId = locationId; self.name = name; self.profile = profile
    }
    // ECMAScript WhiteSpace and LineTerminator, without normalizing the stored string.
    private static func trimmedScalar(_ v: UInt32) -> Bool {
        [9,10,11,12,13,32,160,0x1680,0x2028,0x2029,0x202F,0x205F,0x3000,0xFEFF].contains(v) || (0x2000...0x200A).contains(v)
    }
    public static func == (a: Self, b: Self) -> Bool {
        a.requestId == b.requestId && a.transitionId == b.transitionId && a.accountId == b.accountId && a.locationId == b.locationId && a.name.utf8.elementsEqual(b.name.utf8) && a.profile.utf8.elementsEqual(b.profile.utf8)
    }
}
public struct NativeActivationInput: Encodable, Equatable, Sendable {
    public let installationId: UUID, requestId: UUID, challengeId: UUID, transitionId: UUID
    public init(installationId: UUID, requestId: UUID, challengeId: UUID, transitionId: UUID) { self.installationId = installationId; self.requestId = requestId; self.challengeId = challengeId; self.transitionId = transitionId }
}
public struct NativeGenerationReceipt: Encodable, Sendable {
    public let generationId: UUID
    public let createdAt: String, renewAfter: String, expiresAt: String
    public init(generationId: UUID, createdAt: String, renewAfter: String, expiresAt: String) throws {
        guard try nativeEnrollmentInterval(renewAfter, createdAt, seconds: 720 * 3600),
              try nativeEnrollmentInterval(expiresAt, createdAt, seconds: 2160 * 3600) else { throw NativeEnrollmentFailure.mismatchedEvidence }
        self.generationId = generationId; self.createdAt = createdAt; self.renewAfter = renewAfter; self.expiresAt = expiresAt
    }
}
public struct NativeClaimReceipt: Encodable, Sendable {
    public enum Outcome: String, Encodable, Sendable { case pending, expired, cancelled }
    public let installationId: UUID, requestId: UUID, transitionId: UUID, challengeId: UUID, accountId: UUID, locationId: UUID
    public let createdAt: String, expiresAt: String
    public let outcome: Outcome
    public init(installationId: UUID, requestId: UUID, transitionId: UUID, challengeId: UUID, accountId: UUID, locationId: UUID, createdAt: String, expiresAt: String, outcome: Outcome) throws {
        guard try nativeEnrollmentInterval(expiresAt, createdAt, seconds: 600) else { throw NativeEnrollmentFailure.mismatchedEvidence }
        self.installationId = installationId; self.requestId = requestId; self.transitionId = transitionId; self.challengeId = challengeId; self.accountId = accountId; self.locationId = locationId; self.createdAt = createdAt; self.expiresAt = expiresAt; self.outcome = outcome
    }
}
public struct NativeActivationReceipt: Encodable, Sendable {
    public let installationId: UUID, deviceId: UUID, requestId: UUID, accountId: UUID, locationId: UUID, transitionId: UUID
    public let activatedAt: String
    public let initialGeneration: NativeGenerationReceipt
    public init(installationId: UUID, deviceId: UUID, requestId: UUID, accountId: UUID, locationId: UUID, transitionId: UUID, activatedAt: String, initialGeneration: NativeGenerationReceipt) throws {
        guard installationId == deviceId, try nativeEnrollmentTime(activatedAt) == nativeEnrollmentTime(initialGeneration.createdAt) else { throw NativeEnrollmentFailure.mismatchedEvidence }
        self.installationId = installationId; self.deviceId = deviceId; self.requestId = requestId; self.accountId = accountId; self.locationId = locationId; self.transitionId = transitionId; self.activatedAt = activatedAt; self.initialGeneration = initialGeneration
    }
}
public enum NativeClaimResult: Sendable { case claim(NativeClaimReceipt), activated(NativeActivationReceipt) }
public struct NativeEnrollmentEvidence: Encodable, Sendable {
    public static let maximumRecords = 64, reservedBytesPerRecord = 8192, maximumEncodedBytes = 1_048_576
    public enum Event: Encodable, Sendable {
        case claimProposed, pendingClaimObserved(NativeClaimReceipt), activationProposed(NativeActivationInput)
        case terminalClaimObserved(NativeClaimReceipt), historicalActivationObserved(NativeActivationReceipt)
    }
    public struct Enrollment: Encodable, Sendable {
        public let localEnrollmentId: UUID
        public let binding: DeviceManagementFormatHistory.Binding
        public let claimInput: NativeClaimInput
        public let events: [Event]
        init(localEnrollmentId: UUID, binding: DeviceManagementFormatHistory.Binding, claimInput: NativeClaimInput, events: [Event]) {
            self.localEnrollmentId = localEnrollmentId; self.binding = binding; self.claimInput = claimInput; self.events = events
        }
    }
    public let schemaVersion = 1
    public let enrollments: [Enrollment]
    public init() { enrollments = [] }
    init(_ records: [Enrollment]) throws {
        guard records.count <= Self.maximumRecords else { throw NativeEnrollmentFailure.capacityExceeded }
        for record in records {
            guard record.events.count <= 4, try nativeEnrollmentBytes(record).count <= Self.reservedBytesPerRecord else { throw NativeEnrollmentFailure.capacityExceeded }
        }
        enrollments = records
        guard try nativeEnrollmentBytes(self).count <= Self.maximumEncodedBytes else { throw NativeEnrollmentFailure.capacityExceeded }
    }
}
func nativeEnrollmentBytes<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try encoder.encode(value)
}
/// Exact comparison representation; never sends untrusted precision to ICU or Double.
struct NativeEnrollmentInstant: Equatable {
    let seconds: Int64
    let fraction: String // trailing zeroes removed; empty means an integral second
}
func nativeEnrollmentInterval(_ after: String, _ before: String, seconds: Int64) throws -> Bool {
    let a = try nativeEnrollmentTime(after), b = try nativeEnrollmentTime(before)
    return a.seconds - b.seconds == seconds && a.fraction == b.fraction
}
func nativeEnrollmentTime(_ value: String) throws -> NativeEnrollmentInstant {
    let bytes = Array(value.utf8.prefix(257))
    guard (20...256).contains(bytes.count) else { throw NativeEnrollmentFailure.invalidInput }
    func integer(_ start: Int, _ count: Int) throws -> Int {
        guard start >= 0, start + count <= bytes.count else { throw NativeEnrollmentFailure.invalidInput }
        var result = 0
        for byte in bytes[start..<(start + count)] {
            guard (48...57).contains(byte) else { throw NativeEnrollmentFailure.invalidInput }
            result = result * 10 + Int(byte - 48)
        }
        return result
    }
    guard bytes[4] == 45, bytes[7] == 45, bytes[10] == 84,
          bytes[13] == 58, bytes[16] == 58 else { throw NativeEnrollmentFailure.invalidInput }
    let year = try integer(0, 4), month = try integer(5, 2), day = try integer(8, 2)
    let hour = try integer(11, 2), minute = try integer(14, 2), second = try integer(17, 2)
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    guard year > 0, (1...12).contains(month), day > 0, day <= days[month - 1],
          hour < 24, minute < 60, second < 60 else { throw NativeEnrollmentFailure.invalidInput }
    var cursor = 19, fraction: [UInt8] = []
    if bytes[cursor] == 46 {
        cursor += 1
        let start = cursor
        while cursor < bytes.count, (48...57).contains(bytes[cursor]) { fraction.append(bytes[cursor]); cursor += 1 }
        guard cursor > start else { throw NativeEnrollmentFailure.invalidInput }
    }
    guard cursor < bytes.count else { throw NativeEnrollmentFailure.invalidInput }
    var offset = 0
    if bytes[cursor] == 90 {
        guard cursor + 1 == bytes.count else { throw NativeEnrollmentFailure.invalidInput }
    } else {
        guard bytes[cursor] == 43 || bytes[cursor] == 45, cursor + 6 == bytes.count,
              bytes[cursor + 3] == 58 else { throw NativeEnrollmentFailure.invalidInput }
        let offsetHour = try integer(cursor + 1, 2), offsetMinute = try integer(cursor + 4, 2)
        guard offsetHour < 24, offsetMinute < 60 else { throw NativeEnrollmentFailure.invalidInput }
        offset = (offsetHour * 60 + offsetMinute) * 60 * (bytes[cursor] == 43 ? 1 : -1)
    }
    while fraction.last == 48 { fraction.removeLast() }
    // Proleptic Gregorian day count relative to 1970-01-01. Four-digit years
    // and bounded offsets keep every intermediate safely inside Int64.
    let priorYears = year - 1
    let priorDays = 365 * priorYears + priorYears / 4 - priorYears / 100 + priorYears / 400
    let dayIndex = priorDays + days.prefix(month - 1).reduce(0, +) + day - 1 - 719162
    let seconds = Int64(dayIndex) * 86400 + Int64(hour * 3600 + minute * 60 + second - offset)
    return NativeEnrollmentInstant(seconds: seconds, fraction: String(decoding: fraction, as: UTF8.self))
}
