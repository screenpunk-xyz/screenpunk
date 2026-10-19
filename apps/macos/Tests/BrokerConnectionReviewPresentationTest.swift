import Foundation

@main
struct BrokerConnectionReviewPresentationTest {
    static func main() throws {
        func facts(_ address: String) -> BrokerConnectionReviewFacts {
            .init(alias: "Kitchen\u{001B}\u{202E}", ownerPin: "owner", ownerEpoch: "epoch-1",
                  deviceId: "device-1", devicePin: "peer", pairingEpoch: "pair-1",
                  dashboardId: "screen-1", revision: "revision-1",
                  endpoint: "service.example:443", networkPermission: "lan:service.example",
                  transport: "https", authenticationPlacement: "header",
                  authenticationField: "Authorization", redirectPolicy: "deny",
                  maximumResponseBytes: 1024, timeoutSeconds: 5,
                  credentialGeneration: 2, grantGeneration: 3,
                  declarationHash: String(repeating: "a", count: 64),
                  authorizationContextHash: String(repeating: "b", count: 64),
                  intentId: "intent-1", intentExpiresAt: "2026-09-29T20:00:00Z",
                  reviewExpiresAt: "2026-09-29T19:59:00Z",
                  operations: [.init(name: "Read", method: "GET", address: address,
                                     writes: false)])
        }
        let tail = "target=kitchen&view=" + String(repeating: "x", count: 4500) + "FINAL"
        let output = try BrokerConnectionReviewPresentation.render(facts("https://service.example/path?" + tail))
        precondition(output.contains("FINAL") && output.contains("lan:service.example") &&
                     output.contains("target=kitchen") && !output.contains("\u{001B}") &&
                     !output.contains("\u{202E}") && output.contains("\\u{001B}"))
        do {
            _ = try BrokerConnectionReviewPresentation.render(
                facts(String(repeating: "x", count: 256 * 1024)))
            preconditionFailure("Oversized review rendered")
        } catch BrokerConnectionReviewPresentationError.unrenderable {}
        print("BrokerConnectionReviewPresentationTest passed")
    }
}
