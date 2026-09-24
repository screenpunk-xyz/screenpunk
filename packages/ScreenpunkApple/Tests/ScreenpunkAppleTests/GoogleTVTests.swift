import XCTest
import CryptoKit
import Security
@testable import ScreenpunkApple

final class GoogleTVTests: XCTestCase {
    func testIndependentIdentitiesHaveDistinctCertificatePrimaryKeys() throws {
        func certificate() throws -> (SecCertificate, Data) {
            let key = try XCTUnwrap(SecKeyCreateRandomKey([
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeySizeInBits as String: 2048
            ] as CFDictionary, nil))
            let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
            let data = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
            return (try GoogleTVIdentity.makeCertificate(key: key, publicData: data), data)
        }
        let (adb, adbKey) = try certificate()
        let (remote, remoteKey) = try certificate()
        let adbSerial = try XCTUnwrap(SecCertificateCopySerialNumberData(adb, nil) as Data?)
        let remoteSerial = try XCTUnwrap(SecCertificateCopySerialNumberData(remote, nil) as Data?)
        XCTAssertNotEqual(adbSerial, remoteSerial, "Keychain must not reject the second identity as a duplicate")
        for (cert, expectedKey, serial) in [(adb, adbKey, adbSerial), (remote, remoteKey, remoteSerial)] {
            XCTAssertEqual(serial.count, 16)
            XCTAssertLessThan(try XCTUnwrap(serial.first), 128)
            XCTAssertGreaterThan(try XCTUnwrap(serial.first), 0)
            let key = try XCTUnwrap(SecCertificateCopyKey(cert))
            XCTAssertEqual(SecKeyCopyExternalRepresentation(key, nil) as Data?, expectedKey)
        }
    }
    @MainActor
    func testTVPowerToggleSendsOneExplicitRemoteKeyWithoutReplay() async throws {
        var keys: [W.Message] = []
        let session = GoogleTVSession { data, completion in
            do {
                var framer = W.Framer()
                let message = try W.parse(try framer.append(data)[0])
                if message.payloads[10] != nil { keys.append(try message.nested(10)) }
                completion(nil)
            } catch { completion(error) }
        }
        defer { session.close() }
        try session.handle(W.parse(W.bytes(1, W.number(1, 615))))
        try session.handle(W.parse(W.bytes(40, W.number(1, 1))))
        try await session.command(key: "tvPowerToggle", link: nil)
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys.first?.numbers[1], 177)
        XCTAssertEqual(keys.first?.numbers[2], 3) // One short press.
        session.close()
        do { try await session.command(key: "tvPowerToggle", link: nil); XCTFail("Disconnected command must fail") }
        catch { }
        XCTAssertEqual(keys.count, 1)
    }
    typealias W = GoogleTVWire
    func testFragmentedAndCoalescedTCPFrames() throws {
        let messages = [W.bytes(1, W.number(1, 615)), W.bytes(8, W.number(1, 89)), W.bytes(40, W.number(1, 1))]
        let stream = messages.reduce(Data()) { $0 + W.varint(UInt64($1.count)) + $1 }
        for split in 0...stream.count {
            var framer = W.Framer()
            let first = try framer.append(Data(stream.prefix(split)))
            let second = try framer.append(Data(stream.dropFirst(split)))
            XCTAssertEqual(first + second, messages)
        }
        var framer = W.Framer(); var actual: [Data] = []
        for byte in stream { actual += try framer.append(Data([byte])) }; XCTAssertEqual(actual, messages)
    }
    func testMalformedAndOversizedFramesFailClosed() throws {
        var framer = W.Framer()
        XCTAssertThrowsError(try framer.append(W.varint(UInt64(W.limit + 1))))
        XCTAssertThrowsError(try W.parse(Data([0])))
        XCTAssertThrowsError(try W.parse(Data([10, 6, 1])))
        XCTAssertThrowsError(try W.parse(Data([8] + Array(repeating: 255, count: 10))))
        var index = 0; XCTAssertNil(try W.read([128], &index)); XCTAssertEqual(index, 0)
    }
    func testPairingSecretUsesBothKeysAndValidatesCode() throws {
        // Different modulus/exponent widths exercise DER length decoding rather
        // than assuming one specific RSA certificate layout.
        let der = GoogleTVIdentity.der
        let client = der(0x30, der(2, Data([0, 0x81, 0x02])) + der(2, Data([1, 0, 1])))
        let server = der(0x30, der(2, Data([0, 0x91, 0x03])) + der(2, Data([3])))
        let expected = Data(SHA256.hash(data: Data([0x81, 2, 1, 0, 1, 0x91, 3, 3, 0xab, 0xcd])))
        let code = String(format: "%02XABCD", expected.first!)
        XCTAssertEqual(try GoogleTVIdentity.secret(client: client, server: server, code: code), expected)
        XCTAssertThrowsError(try GoogleTVIdentity.secret(client: server, server: client, code: code))
        XCTAssertThrowsError(try GoogleTVIdentity.secret(client: client, server: server, code: "GG0000"))
        XCTAssertThrowsError(try GoogleTVIdentity.secret(client: client, server: server, code: "00"))
        XCTAssertThrowsError(try GoogleTVIdentity.secret(client: client, server: server, code: "ééé"))
        XCTAssertThrowsError(try GoogleTVIdentity.rsaComponents(Data([0x30, 0x82, 0xff, 0xff])))
    }
    func testAppLinkAllowlistRejectsLookalikesAndCredentials() {
        XCTAssertTrue(GoogleTVConfiguration.validLink("https://tv.youtube.com/watch/example"))
        for url in ["http://tv.youtube.com/", "https://tv.youtube.com.evil.test/", "https://tv.youtube.com@evil.test/", "https://user@tv.youtube.com/", "intent://launch", "https://tv.youtube.com:443/", "https://tv.youtube.com/#anything"] {
            XCTAssertFalse(GoogleTVConfiguration.validLink(url), url)
        }
        XCTAssertFalse(GoogleTVConfiguration.validHost("192.168.1.1:6466/path"))
        XCTAssertFalse(GoogleTVConfiguration.validHost("https://tv.local"))
    }
    @MainActor
    func testUnapprovedScreenCannotTriggerNativeConnection() async {
        let connection = GoogleTVScreenConnection()
        do { _ = try await connection.request(dashboardID: UUID().uuidString, operation: "key", parameters: ["key": "wake"]); XCTFail("Unapproved screen must not reach the network") }
        catch { XCTAssertTrue(error.localizedDescription.contains("permission required")) }
        connection.close()
    }
    @MainActor
    func testCommandsAreExplicitAndBounded() {
        XCTAssertEqual(GoogleTVSession.keys["wake"], 224)
        XCTAssertEqual(GoogleTVSession.keys["sleep"], 223)
        XCTAssertEqual(GoogleTVSession.keys["muteToggle"], 164)
        XCTAssertNil(GoogleTVSession.keys["power"])
        XCTAssertNil(GoogleTVSession.keys["shell"])
    }
}
