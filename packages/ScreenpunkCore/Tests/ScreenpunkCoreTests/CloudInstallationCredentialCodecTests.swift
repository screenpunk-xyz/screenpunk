import XCTest
@testable import ScreenpunkCore

final class CloudInstallationCredentialCodecTests: XCTestCase {
    func testCanonicalEncodingRoundTripsAllByteValuesAndURLAlphabet() throws {
        for offset in 0..<256 {
            let bytes = Data((0..<48).map { UInt8(($0 + offset) % 256) })
            let wire = try CloudInstallationCredentialCodec.encode(randomBytes: bytes)
            XCTAssertEqual(wire.utf8.count, 70)
            XCTAssertTrue(wire.hasPrefix("spni1_"))
            XCTAssertFalse(wire.contains("="))
            XCTAssertFalse(wire.contains("+"))
            XCTAssertFalse(wire.contains("/"))
            XCTAssertEqual(try CloudInstallationCredentialCodec.decode(wire), bytes)
        }
        XCTAssertEqual(try CloudInstallationCredentialCodec.encode(randomBytes: Data(repeating: 0, count: 48)), "spni1_" + String(repeating: "A", count: 64))
    }

    func testRejectsLegacyAndWrongByteCounts() {
        for count in [0, 32, 47, 49, 64] {
            XCTAssertThrowsError(try CloudInstallationCredentialCodec.encode(randomBytes: Data(repeating: 0, count: count))) {
                XCTAssertEqual($0 as? CloudInstallationCredentialCodec.Failure, .invalidByteCount)
            }
        }
    }

    func testRejectsNoncanonicalWireFormsWithoutIncludingInputInErrors() throws {
        let valid = try CloudInstallationCredentialCodec.encode(randomBytes: Data(repeating: 255, count: 48))
        let malformed = ["", valid + "=", " " + valid, valid + "\n", valid.uppercased(),
                         "spni2_" + String(valid.dropFirst(6)), String(valid.dropLast()), valid + "A",
                         "spni1_" + String(repeating: "/", count: 64),
                         "spni1_" + String(repeating: "+", count: 64),
                         "spni1_" + String(repeating: "=", count: 64),
                         "spni1_" + String(repeating: " ", count: 64),
                         "spni1_" + String(repeating: "é", count: 32),
                         "spni1_" + Data(repeating: 0, count: 32).base64EncodedString()]
        for wire in malformed {
            XCTAssertThrowsError(try CloudInstallationCredentialCodec.decode(wire)) {
                XCTAssertEqual($0 as? CloudInstallationCredentialCodec.Failure, .invalidEncoding)
            }
        }
    }
}
