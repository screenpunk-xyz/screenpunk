import Foundation

#if os(macOS)
enum WorkbenchLocalReviewMethod: String, CaseIterable {
    case begin = "connection.reviewBegin"
    case confirm = "connection.reviewConfirm"
}

/// Broker-frozen, redacted scope for a local terminal or native GUI review.
/// The handle is single-use and bound to the authenticated socket session.
public struct WorkbenchConnectionReview: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let reviewHandle: String
    public let intentId: String
    public let declarationHash: String
    public let authorizationContextHash: String
    public let ownerPin: String
    public let ownerEpoch: String
    public let devicePin: String
    public let pairingEpoch: String
    public let endpoint: String
    public let credentialGeneration: Int
    public let grantGeneration: Int
    public let intentExpiresAt: Date
    public let reviewExpiresAt: Date
    public let summary: WorkbenchConnectionSummary

    init(handle: String, intent: WorkbenchConnectionIntent,
         state: WorkbenchLocalAuthorityState, summary: WorkbenchConnectionSummary,
         endpoint: String, reviewedAt: Date) throws {
        guard let owner = state.controllerPin, let pairing = state.devices[intent.deviceId] else {
            throw WorkbenchAuthorityError.staleContext
        }
        schemaVersion = 1; reviewHandle = handle; intentId = intent.intentId
        declarationHash = intent.declarationHash
        authorizationContextHash = intent.authorizationContextHash
        ownerPin = owner; ownerEpoch = state.controllerIdentityEpoch
        devicePin = pairing.peerPin; pairingEpoch = pairing.pairingEpoch
        self.endpoint = endpoint
        credentialGeneration = intent.credentialGeneration
        grantGeneration = state.connections[intent.grant.id.uuidString.lowercased()]?.grantGeneration ?? 0
        intentExpiresAt = intent.expiresAt
        reviewExpiresAt = min(intent.expiresAt, reviewedAt.addingTimeInterval(300))
        self.summary = summary
    }

    func validate() throws {
        guard schemaVersion == 1, Data(base64Encoded: reviewHandle)?.count == 32,
              !intentId.isEmpty, declarationHash.count == 64, authorizationContextHash.count == 64,
              !ownerPin.isEmpty, !devicePin.isEmpty, credentialGeneration >= 0,
              grantGeneration >= 0, reviewExpiresAt <= intentExpiresAt,
              summary.deviceId.count <= 128, summary.operations.count <= 32 else {
            throw WorkbenchIPCError(.invalidRequest)
        }
    }
}

struct WorkbenchLocalReviewTicket {
    let review: WorkbenchConnectionReview
    let deadlineUptime: TimeInterval
}
#endif
