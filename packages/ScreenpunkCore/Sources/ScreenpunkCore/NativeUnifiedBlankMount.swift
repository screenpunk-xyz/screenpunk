import Foundation
import CoreFoundation

/// Issued only from the durable, resource-verified blank mount of this session.
@_spi(NativeInstallation) public final class NativeUnifiedBlankMount: @unchecked Sendable, CustomReflectable {
    let generationID: UUID
    let installationID: UUID
    private let validate: () throws -> Void
    init(generationID: UUID, installationID: UUID, validate: @escaping () throws -> Void) { self.generationID = generationID; self.installationID = installationID; self.validate = validate }
    public var customMirror: Mirror { Mirror(self, children: [] as [(String, Any)]) }
    func validatedBody() throws -> Data {
        try validate()
        return try JSONSerialization.data(withJSONObject: ["generationId": generationID.uuidString.lowercased(), "entryId": NSNull(), "packageDigest": NSNull()], options: [.sortedKeys])
    }
    func validateReceipt(_ data: Data) throws {
        try validate()
        guard data.count <= 4096, let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(body.keys) == Set(["schemaVersion", "generationId", "entryId", "accepted"]),
            let version = body["schemaVersion"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.intValue == 1, version.doubleValue == 1, body["generationId"] as? String == generationID.uuidString.lowercased(),
            body["entryId"] is NSNull, let accepted = body["accepted"] as? NSNumber,
            CFGetTypeID(accepted) == CFBooleanGetTypeID(), accepted.boolValue else { throw NativeEnrollmentPromotionError.blocked }
        try validate()
    }
}
extension DeviceUnifiedInventorySession {
    @_spi(NativeInstallation) public func retainedMountedEmptyObservation() throws -> NativeUnifiedBlankMount {
        let association = try validatedAssociation()
        guard association.configuredEntryID == nil, let mounted = try mountedAssociation(), mounted.currentlyConfigured,
            mounted.generationID == association.generationID, mounted.entryID == nil, mounted.manifestDigest == nil else { throw NativeEnrollmentPromotionError.blocked }
        return NativeUnifiedBlankMount(generationID: association.generationID, installationID: association.installationID) { [self] in
            let current = try validatedAssociation()
            guard current.installationID == association.installationID, current.generationID == association.generationID, current.configuredEntryID == nil,
                let proof = try mountedAssociation(), proof.currentlyConfigured, proof.generationID == current.generationID,
                proof.entryID == nil, proof.manifestDigest == nil else { throw NativeEnrollmentPromotionError.blocked }
        }
    }
}
