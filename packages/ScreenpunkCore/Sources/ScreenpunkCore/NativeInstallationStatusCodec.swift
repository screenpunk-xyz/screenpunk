import Foundation

/// Observation only. No transport, secret, durability or current-admission lease.
/// Schema pinned to cloud e7029fecc86a48934f48ca55604ce92c22dd2604.
enum NativeInstallationStatusValue: Sendable {
    enum Credential: String, Sendable { case current, expired, revoked }
    enum Authority: String, Sendable { case active, revoked }
    struct Rotation: Sendable {
        let installationId: UUID, transitionId: UUID, requestId: UUID, previousGenerationId: UUID
        let generation: NativeGenerationReceipt
        let rotatedAt: String
    }
    struct Current: Sendable {
        let installationId: UUID, accountId: UUID, transitionId: UUID
        let locationId: UUID?
        let generation: NativeGenerationReceipt
        let activation: NativeActivationReceipt
        let credential: Credential
        let authority: Authority
    }
    case claim(NativeClaimReceipt), historicalRotation(Rotation), currentGeneration(Current)
}

enum NativeInstallationStatusCodec {
    enum Failure: Error, Equatable { case capacity, invalidJSON, invalidValue }
    /// Local defensive envelope cap, not a server/wire declared response cap.
    static let maximumBytes = 16_384
    static func decode(_ data: Data) throws -> NativeInstallationStatusValue {
        guard data.count <= maximumBytes else { throw Failure.capacity }
        let root: [String: Any]
        do { root = try StructuralStoreCodec.object(data, limit: maximumBytes) }
        catch { throw Failure.invalidJSON }
        do {
            switch try string(root, "kind") {
            case "claim":
                try keys(root, ["kind", "claim"])
                return .claim(try claim(object(root, "claim")))
            case "historical-rotation":
                try keys(root, ["kind", "rotation"])
                let o = try object(root, "rotation")
                try keys(o, ["installationId", "transitionId", "requestId", "previousGenerationId", "generation", "rotatedAt"])
                let g = try generation(object(o, "generation")), previous = try uuid(o, "previousGenerationId")
                let time = try timestamp(o, "rotatedAt")
                guard previous != g.generationId, try nativeEnrollmentTime(time) == nativeEnrollmentTime(g.createdAt) else { throw Failure.invalidValue }
                return .historicalRotation(.init(installationId: try uuid(o, "installationId"), transitionId: try uuid(o, "transitionId"),
                    requestId: try uuid(o, "requestId"), previousGenerationId: previous, generation: g, rotatedAt: time))
            case "current-generation":
                try keys(root, ["kind", "installationId", "accountId", "locationId", "transitionId", "generation", "activation", "credential", "authority"])
                let a = try activation(object(root, "activation"))
                let i = try uuid(root, "installationId"), account = try uuid(root, "accountId"), location = try optionalLocation(root, "locationId"), transition = try uuid(root, "transitionId")
                guard i == a.installationId, account == a.accountId, transition == a.transitionId,
                      let c = NativeInstallationStatusValue.Credential(rawValue: try string(root, "credential")),
                      let authority = NativeInstallationStatusValue.Authority(rawValue: try string(root, "authority")) else { throw Failure.invalidValue }
                // Current generation can differ from the immutable initial generation.
                return .currentGeneration(.init(installationId: i, accountId: account, transitionId: transition, locationId: location,
                    generation: try generation(object(root, "generation")), activation: a, credential: c, authority: authority))
            default: throw Failure.invalidValue
            }
        } catch { throw Failure.invalidValue }
    }
    private static func keys(_ o: [String: Any], _ k: Set<String>) throws { try StructuralStoreCodec.keys(o, required: k) }
    private static func object(_ o: [String: Any], _ key: String) throws -> [String: Any] {
        guard let value = o[key] as? [String: Any] else { throw Failure.invalidValue }; return value
    }
    private static func string(_ o: [String: Any], _ key: String) throws -> String {
        guard let value = o[key] as? String else { throw Failure.invalidValue }; return value
    }
    private static func optionalLocation(_ o: [String: Any], _ key: String) throws -> UUID? {
        if o[key] is NSNull { return nil }
        return try uuid(o, key)
    }
    private static func uuid(_ o: [String: Any], _ key: String) throws -> UUID {
        var value = try string(o, key)
        // Accepted ajv-formats UUID: optional case-insensitive URN, no extra
        // delivery-specific version/variant restrictions or canonical-only rule.
        if value.lowercased().hasPrefix("urn:uuid:") { value = String(value.dropFirst(9)) }
        let b = Array(value.utf8)
        guard b.count == 36, b.enumerated().allSatisfy({ index, byte in
            [8,13,18,23].contains(index) ? byte == 45 : (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }), let id = UUID(uuidString: value) else { throw Failure.invalidValue }; return id
    }
    private static func timestamp(_ o: [String: Any], _ key: String) throws -> String {
        let value = try string(o, key)
        // Intentionally supports genuine lifecycle timestamps representable by
        // the existing bounded Gregorian evidence model, not every AJV date-time
        // spelling. Unsupported spellings fail closed as observations.
        _ = try nativeEnrollmentTime(value) // No ICU or broader normalization.
        return value
    }
    private static func generation(_ o: [String: Any]) throws -> NativeGenerationReceipt {
        try keys(o, ["generationId", "createdAt", "renewAfter", "expiresAt"])
        return try .init(generationId: uuid(o, "generationId"), createdAt: timestamp(o, "createdAt"),
                         renewAfter: timestamp(o, "renewAfter"), expiresAt: timestamp(o, "expiresAt"))
    }
    private static func activation(_ o: [String: Any]) throws -> NativeActivationReceipt {
        try keys(o, ["installationId", "deviceId", "requestId", "accountId", "locationId", "transitionId", "activatedAt", "initialGeneration"])
        return try .init(installationId: uuid(o, "installationId"), deviceId: uuid(o, "deviceId"), requestId: uuid(o, "requestId"),
            accountId: uuid(o, "accountId"), locationId: optionalLocation(o, "locationId"), transitionId: uuid(o, "transitionId"),
            activatedAt: timestamp(o, "activatedAt"), initialGeneration: generation(object(o, "initialGeneration")))
    }
    private static func claim(_ o: [String: Any]) throws -> NativeClaimReceipt {
        try keys(o, ["installationId", "requestId", "transitionId", "challengeId", "accountId", "locationId", "createdAt", "expiresAt", "outcome"])
        guard let outcome = NativeClaimReceipt.Outcome(rawValue: try string(o, "outcome")) else { throw Failure.invalidValue }
        return try .init(installationId: uuid(o, "installationId"), requestId: uuid(o, "requestId"), transitionId: uuid(o, "transitionId"),
            challengeId: uuid(o, "challengeId"), accountId: uuid(o, "accountId"), locationId: optionalLocation(o, "locationId"),
            createdAt: timestamp(o, "createdAt"), expiresAt: timestamp(o, "expiresAt"), outcome: outcome)
    }
}
