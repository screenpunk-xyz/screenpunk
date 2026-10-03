import Foundation

public enum CloudInstallationCredentialFormat: String, Sendable {
    case legacyLocal32
    case nativeInstallationV1
}

/// Read-only local evidence, with no persistence or remote authority semantics.
public struct CloudInstallationHistoryInterpretation: Equatable, Sendable {
    public struct Binding: Equatable, Sendable {
        public let localCredentialBindingID: UUID
        public let transitionID: UUID
        public let credentialReference: String
        public let format: CloudInstallationCredentialFormat
    }

    public let sourceSchemaVersion: Int
    public let transitions: [DeviceManagementTransitionEntry]
    public let bindings: [Binding]

    public init(version2 history: DeviceManagementTransitionHistory) throws {
        guard history.schemaVersion == 2 else { throw DeviceManagementTransitionStoreError.unsupportedVersion(history.schemaVersion) }
        // Reapply the existing constructor's complete validation; there is no separate validate API.
        let validated = try DeviceManagementTransitionHistory(transitions: history.transitions, credentials: history.credentials)
        sourceSchemaVersion = history.schemaVersion
        transitions = validated.transitions
        bindings = validated.credentials.map {
            Binding(localCredentialBindingID: $0.credentialGenerationID, transitionID: $0.transitionID,
                    credentialReference: $0.credentialReference, format: .legacyLocal32)
        }
    }
}
