import Foundation
import ScreenpunkCore
#if os(macOS)

enum WorkbenchHomeAssistantMethod: String, CaseIterable {
    case reviewBegin = "homeAssistant.reviewBegin"
    case reviewConfirm = "homeAssistant.reviewConfirm"
    case status = "homeAssistant.status"
    case cancelPrepared = "homeAssistant.cancelPrepared"
}

/// Complete nonsecret scope frozen by the broker for a single local socket.
public struct WorkbenchHomeAssistantReview: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let reviewHandle: String
    public let intentId: String
    public let workspaceId: String
    public let selectionGeneration: Int
    public let deviceId: String
    public let dashboardId: String
    public let revision: String
    public let packageDigest: String
    public let authorizationContextHash: String
    public let declarationHash: String
    public let ownerPin: String
    public let devicePin: String
    public let pairingEpoch: String
    public let origin: String
    public let connectionId: String
    public let declaration: ManifestConnection
    public let reviewExpiresAt: Date

    init(handle: String, intentId: String, context: WorkbenchHomeAssistantContext,
         ownerPin: String, devicePin: String, pairingEpoch: String,
         origin: String, connectionId: String, declaration: ManifestConnection,
         reviewExpiresAt: Date) throws {
        schemaVersion = 1; reviewHandle = handle; self.intentId = intentId
        workspaceId = context.workspaceId; selectionGeneration = context.selectionGeneration
        deviceId = context.deviceId; dashboardId = context.dashboardId
        revision = context.revision; packageDigest = context.packageDigest
        authorizationContextHash = context.authorizationContextHash
        self.ownerPin = ownerPin; self.devicePin = devicePin
        self.pairingEpoch = pairingEpoch; self.origin = origin
        self.connectionId = connectionId; self.declaration = declaration
        self.reviewExpiresAt = reviewExpiresAt
        let declarationObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(declaration))
        declarationHash = try ToolchainCanonical.hash(domain: "home-assistant-review", value: [
            "workspaceId": workspaceId, "selectionGeneration": selectionGeneration,
            "deviceId": deviceId, "dashboardId": dashboardId, "revision": revision,
            "packageDigest": packageDigest, "authorizationContextHash": authorizationContextHash,
            "ownerPin": ownerPin, "devicePin": devicePin, "pairingEpoch": pairingEpoch,
            "origin": origin, "connectionId": connectionId,
            "declaration": declarationObject
        ])
        try validate()
    }

    var context: WorkbenchHomeAssistantContext {
        .init(workspaceId: workspaceId, selectionGeneration: selectionGeneration,
            deviceId: deviceId, dashboardId: dashboardId, revision: revision,
            packageDigest: packageDigest,
            authorizationContextHash: authorizationContextHash)
    }

    public func validate() throws {
        guard schemaVersion == 1, Data(base64Encoded: reviewHandle)?.count == 32,
              UUID(uuidString: intentId) != nil,
              WorkspaceValidation.id(workspaceId), selectionGeneration > 0,
              WorkspaceValidation.id(deviceId), WorkspaceValidation.id(dashboardId),
              WorkspaceValidation.id(revision), WorkspaceValidation.sha256(packageDigest),
              WorkspaceValidation.sha256(authorizationContextHash),
              WorkspaceValidation.sha256(declarationHash),
              !ownerPin.isEmpty, !devicePin.isEmpty, !pairingEpoch.isEmpty,
              declaration.alias == "home", !connectionId.isEmpty,
              connectionId.utf8.count <= 128, reviewExpiresAt.timeIntervalSince1970 > 0 else {
            throw WorkbenchIPCError(.invalidRequest)
        }
    }
}

struct WorkbenchHomeAssistantReviewTicket {
    let review: WorkbenchHomeAssistantReview
    let manifest: DashboardManifest
    let deadlineUptime: TimeInterval
}

/// Redacted durable attempt status; the Keychain reference and token never
/// cross the socket, enter a workspace, or appear in terminal output.
public struct WorkbenchHomeAssistantAttemptView: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let intentId: String
    public let workspaceId: String
    public let selectionGeneration: Int
    public let deviceId: String
    public let dashboardId: String
    public let revision: String
    public let packageDigest: String
    public let origin: String
    public let connectionId: String
    public let provisioningId: String
    public let phase: String

    init(_ attempt: WorkbenchHomeAssistantAttempt) {
        schemaVersion = 1; intentId = attempt.intentId
        workspaceId = attempt.workspaceId; selectionGeneration = attempt.selectionGeneration
        deviceId = attempt.deviceId; dashboardId = attempt.dashboardId
        revision = attempt.revision; packageDigest = attempt.packageDigest
        origin = attempt.origin; connectionId = attempt.connectionId
        provisioningId = attempt.provisioningId; phase = attempt.phase.rawValue
    }
    public func validate() throws {
        guard schemaVersion == 1, UUID(uuidString: intentId) != nil,
              WorkspaceValidation.id(workspaceId), selectionGeneration > 0,
              WorkspaceValidation.id(deviceId), WorkspaceValidation.id(dashboardId),
              WorkspaceValidation.id(revision), WorkspaceValidation.sha256(packageDigest),
              UUID(uuidString: provisioningId) != nil,
              WorkbenchHomeAssistantAttempt.Phase(rawValue: phase) != nil else {
            throw WorkbenchIPCError(.invalidRequest)
        }
    }
}
#endif
