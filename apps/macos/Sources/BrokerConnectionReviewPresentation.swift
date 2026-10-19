import Foundation
import ScreenpunkController

struct BrokerConnectionReviewFacts {
    struct Operation {
        let name: String
        let method: String
        let address: String
        let writes: Bool
    }
    let alias: String
    let ownerPin: String
    let ownerEpoch: String
    let deviceId: String
    let devicePin: String
    let pairingEpoch: String
    let dashboardId: String
    let revision: String
    let endpoint: String
    let networkPermission: String
    let transport: String
    let authenticationPlacement: String
    let authenticationField: String
    let redirectPolicy: String
    let maximumResponseBytes: Int
    let timeoutSeconds: Int
    let credentialGeneration: Int
    let grantGeneration: Int
    let declarationHash: String
    let authorizationContextHash: String
    let intentId: String
    let intentExpiresAt: String
    let reviewExpiresAt: String
    let operations: [Operation]
}

enum BrokerConnectionReviewPresentation {
    static func facts(_ review: WorkbenchConnectionReview) -> BrokerConnectionReviewFacts {
        let iso = ISO8601DateFormatter()
        return BrokerConnectionReviewFacts(alias: review.summary.alias,
            ownerPin: review.ownerPin, ownerEpoch: review.ownerEpoch,
            deviceId: review.summary.deviceId, devicePin: review.devicePin,
            pairingEpoch: review.pairingEpoch, dashboardId: review.summary.dashboardId,
            revision: review.summary.revision, endpoint: review.endpoint,
            networkPermission: review.summary.origin, transport: review.summary.transport,
            authenticationPlacement: review.summary.authenticationPlacement,
            authenticationField: review.summary.authenticationField ?? "",
            redirectPolicy: review.summary.redirectPolicy,
            maximumResponseBytes: review.summary.maximumResponseBytes,
            timeoutSeconds: review.summary.timeoutSeconds,
            credentialGeneration: review.credentialGeneration,
            grantGeneration: review.grantGeneration,
            declarationHash: review.declarationHash,
            authorizationContextHash: review.authorizationContextHash,
            intentId: review.intentId, intentExpiresAt: iso.string(from: review.intentExpiresAt),
            reviewExpiresAt: iso.string(from: review.reviewExpiresAt),
            operations: review.summary.operations.map {
                .init(name: $0.name, method: $0.method, address: $0.address, writes: $0.writes)
            })
    }

    static func render(_ facts: BrokerConnectionReviewFacts) throws -> String {
        let safe = escapeComplete
        var lines = [
            "Screenpunk local connection review — new grant; no removals",
            "Untrusted label: [\(safe(facts.alias))]",
            "Controller owner pin: \(safe(facts.ownerPin))",
            "Owner epoch: \(safe(facts.ownerEpoch))",
            "Device: \(safe(facts.deviceId))",
            "Device peer pin: \(safe(facts.devicePin))",
            "Pairing epoch: \(safe(facts.pairingEpoch))",
            "Dashboard: \(safe(facts.dashboardId))  Revision: \(safe(facts.revision))",
            "Physical endpoint: \(safe(facts.endpoint))",
            "Network permission: \(safe(facts.networkPermission))",
            "Transport: \(safe(facts.transport))",
            "Authentication: \(safe(facts.authenticationPlacement)) \(safe(facts.authenticationField))",
            "Redirect policy: \(safe(facts.redirectPolicy))",
            "Limits: \(facts.maximumResponseBytes) bytes, \(facts.timeoutSeconds) seconds",
            "Credential generation: \(facts.credentialGeneration)  Grant generation: \(facts.grantGeneration)",
            "Declaration hash: \(safe(facts.declarationHash))",
            "Authorization context hash: \(safe(facts.authorizationContextHash))",
            "Intent: \(safe(facts.intentId))  Intent expires: \(safe(facts.intentExpiresAt))",
            "Review expires: \(safe(facts.reviewExpiresAt))",
            "Operations (\(facts.operations.count)):",
        ]
        for (index, item) in facts.operations.enumerated() {
            lines.append("\(index + 1). \(safe(item.name))  \(safe(item.method))  \(safe(item.address))  writes=\(item.writes)")
        }
        guard facts.operations.count <= 32,
              lines.reduce(0, { $0 + $1.utf8.count }) <= 256 * 1024 else {
            throw BrokerConnectionReviewPresentationError.unrenderable
        }
        return lines.joined(separator: "\n")
    }

    static func escapeComplete(_ value: String) -> String {
        var output = ""
        for scalar in value.unicodeScalars {
            let code = scalar.value
            let unsafe = code < 0x20 || (0x7f...0x9f).contains(code) ||
                (0x202a...0x202e).contains(code) || (0x2066...0x2069).contains(code) ||
                code == 0x061c || code == 0x200e || code == 0x200f ||
                code == 0x2028 || code == 0x2029
            output += unsafe ? String(format: "\\u{%04X}", code) : String(scalar)
        }
        return output
    }
}

enum BrokerConnectionReviewPresentationError: Error { case unrenderable }
