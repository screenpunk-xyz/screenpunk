import Foundation
import XCTest
@testable import ScreenpunkController

final class ToolchainCatalogCapacityTests: XCTestCase {
    private func envelope(paddingTo bytes: Int) throws -> Data {
        let value: [String: Any] = [
            "signatureVersion": 1, "algorithm": "Ed25519", "signerKeyId": "synthetic-signer",
            "signatureBase64": Data(repeating: 0, count: 64).base64EncodedString(),
            "payload": ["catalogVersion": 1, "catalogId": "synthetic-catalog",
                        "channel": "beta", "sequence": 2, "entries": []]
        ]
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        data.append(Data(repeating: 32, count: bytes - data.count))
        return data
    }

    func testBoundedEnvelopeAbovePreviousLimitAndAtCurrentLimitParses() throws {
        for bytes in [8 * 1024 * 1024 + 1, ToolchainCatalogJSON.maximumEnvelopeBytes] {
            let (parsed, _) = try ToolchainCatalogJSON.decode(envelope(paddingTo: bytes))
            XCTAssertEqual(parsed.payload.sequence, 2)
        }
        // Parsing alone does not authenticate this intentionally synthetic signature.
    }

    func testOversizeAndMalformedEnvelopesRemainRejected() throws {
        XCTAssertThrowsError(try ToolchainCatalogJSON.decode(envelope(
            paddingTo: ToolchainCatalogJSON.maximumEnvelopeBytes + 1))) {
            XCTAssertEqual($0 as? ToolchainTrustError, .limitExceeded)
        }
        var duplicate = try envelope(paddingTo: 8 * 1024 * 1024 + 1)
        let prefix = Data("{\"algorithm\":\"Ed25519\",\"algorithm\":\"Ed25519\",\"payload\":{}}".utf8)
        duplicate.replaceSubrange(0..<prefix.count, with: prefix)
        XCTAssertThrowsError(try ToolchainCatalogJSON.decode(duplicate)) {
            XCTAssertEqual($0 as? ToolchainTrustError, .invalidCatalog)
        }
    }
}
