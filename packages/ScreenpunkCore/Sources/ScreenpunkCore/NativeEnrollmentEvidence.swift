import Foundation

/// Pure proposals only. No persistence, transport or current-authority assertion.
/// Wire fields follow Cloud commit e7029fecc86a48934f48ca55604ce92c22dd2604.
/// Deliberately Encodable only: raw JSON admission requires a separate duplicate-key
/// and unknown-field qualifier before a decoder may be exposed.
public enum NativeEnrollmentFailure: Error, Equatable { case invalidInput, mismatchedEvidence, illegalSuccessor, capacityExceeded }
public struct NativeClaimInput: Encodable, Equatable, Sendable {
    public let requestId: UUID, transitionId: UUID, accountId: UUID
    public let locationId: UUID?
    public let name: String, profile: String
    private enum CodingKeys: String, CodingKey { case requestId, transitionId, accountId, locationId, name, profile }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(requestId, forKey: .requestId)
        try values.encode(transitionId, forKey: .transitionId)
        try values.encode(accountId, forKey: .accountId)
        try values.encode(locationId, forKey: .locationId)
        try values.encode(name, forKey: .name)
        try values.encode(profile, forKey: .profile)
    }

    public init(requestId: UUID, transitionId: UUID, accountId: UUID, locationId: UUID?, name: String, profile: String) throws {
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
    public let installationId: UUID, requestId: UUID, transitionId: UUID, challengeId: UUID, accountId: UUID
    public let locationId: UUID?
    public let createdAt: String, expiresAt: String
    public let outcome: Outcome
    private enum CodingKeys: String, CodingKey { case installationId, requestId, transitionId, challengeId, accountId, locationId, createdAt, expiresAt, outcome }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(installationId, forKey: .installationId)
        try values.encode(requestId, forKey: .requestId)
        try values.encode(transitionId, forKey: .transitionId)
        try values.encode(challengeId, forKey: .challengeId)
        try values.encode(accountId, forKey: .accountId)
        try values.encode(locationId, forKey: .locationId)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(expiresAt, forKey: .expiresAt)
        try values.encode(outcome, forKey: .outcome)
    }

    public init(installationId: UUID, requestId: UUID, transitionId: UUID, challengeId: UUID, accountId: UUID, locationId: UUID?, createdAt: String, expiresAt: String, outcome: Outcome) throws {
        guard try nativeEnrollmentInterval(expiresAt, createdAt, seconds: 600) else { throw NativeEnrollmentFailure.mismatchedEvidence }
        self.installationId = installationId; self.requestId = requestId; self.transitionId = transitionId; self.challengeId = challengeId; self.accountId = accountId; self.locationId = locationId; self.createdAt = createdAt; self.expiresAt = expiresAt; self.outcome = outcome
    }
}
public struct NativeActivationReceipt: Encodable, Sendable {
    public let installationId: UUID, deviceId: UUID, requestId: UUID, accountId: UUID, transitionId: UUID
    public let locationId: UUID?
    public let activatedAt: String
    public let initialGeneration: NativeGenerationReceipt
    private enum CodingKeys: String, CodingKey { case installationId, deviceId, requestId, accountId, locationId, transitionId, activatedAt, initialGeneration }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(installationId, forKey: .installationId)
        try values.encode(deviceId, forKey: .deviceId)
        try values.encode(requestId, forKey: .requestId)
        try values.encode(accountId, forKey: .accountId)
        try values.encode(locationId, forKey: .locationId)
        try values.encode(transitionId, forKey: .transitionId)
        try values.encode(activatedAt, forKey: .activatedAt)
        try values.encode(initialGeneration, forKey: .initialGeneration)
    }

    public init(installationId: UUID, deviceId: UUID, requestId: UUID, accountId: UUID, locationId: UUID?, transitionId: UUID, activatedAt: String, initialGeneration: NativeGenerationReceipt) throws {
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
typealias NativeEnrollmentInstant = BoundedRFC3339Instant
func nativeEnrollmentInterval(_ after: String, _ before: String, seconds: Int64) throws -> Bool {
    let a = try nativeEnrollmentTime(after), b = try nativeEnrollmentTime(before)
    return a.seconds - b.seconds == seconds && a.fraction == b.fraction
}
func nativeEnrollmentTime(_ value: String) throws -> NativeEnrollmentInstant {
    do { return try boundedRFC3339Time(value) }
    catch { throw NativeEnrollmentFailure.invalidInput }
}
