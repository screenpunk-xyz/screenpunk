import Foundation
import XCTest
@testable import ScreenpunkCore
#if canImport(CryptoKit)
import CryptoKit
#endif

final class DevicePublicDigestHexTests: XCTestCase {
    func testPublicSHAHexFormattingMatchesFrozenPercent02xForAll256Bytes() {
        let bytes = (0...255).map { UInt8($0) }
        for byte in bytes {
            XCTAssertEqual(DevicePublicDigestHex.encode([byte]), String(format: "%02x", byte))
        }
        let output = DevicePublicDigestHex.encode(bytes)
        XCTAssertEqual(output, bytes.map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(output.utf8.count, 512)
        XCTAssertTrue(output.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
        XCTAssertTrue(output.hasPrefix("000102030405060708090a0b0c0d0e0f"))
        XCTAssertTrue(output.hasSuffix("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff"))
        XCTAssertEqual(DevicePublicDigestHex.encode([0, 15, 16, 255, 0]), "000f10ff00")
        XCTAssertEqual(DevicePublicDigestHex.encode([]), "")
    }

    #if canImport(CryptoKit)
    func testPublicPackageSHAHexMatchesKnownDigestWithoutChangingFraming() throws {
        let abc = Data("abc".utf8)
        let abcDigest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        XCTAssertEqual(DevicePublicDigestHex.encode(Array(SHA256.hash(data: abc))), abcDigest)
        XCTAssertEqual(try PackagePreparationCodec.hash(abc), abcDigest)
        let files = [
            PreparationFile(path: "index.html", bytes: 3, sha256: abcDigest),
            PreparationFile(path: "empty.txt", bytes: 0, sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        ]
        // Frozen public vector: original NUL-terminated prefix, UInt64 big-endian
        // UTF-8 byte lengths, then digest/path/decimal-size/file-hash in input order.
        XCTAssertEqual(try PackagePreparationCodec.contentID(files, digest: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"),
            "c0d02c6469f679b976216312597b087e3fdbfccd11aa1513b9d9850338be2e5e")
    }
    #endif
}
