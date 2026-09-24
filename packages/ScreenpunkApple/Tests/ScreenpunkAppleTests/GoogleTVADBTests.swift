import XCTest
import CryptoKit
import Security
@testable import ScreenpunkApple

final class GoogleTVADBTests: XCTestCase {
    func testTLSRejectionIsNotReportedAsUserCancellation() {
        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        let rejected = ADBTransportSTLS.diagnosticError(cancelled, authenticationFailure: "TV key changed", cancelledByOwner: false)
        XCTAssertFalse(rejected is CancellationError)
        XCTAssertTrue(rejected.localizedDescription.contains("TV key changed"))
        let unexplained = ADBTransportSTLS.diagnosticError(cancelled, authenticationFailure: nil, cancelledByOwner: false)
        XCTAssertFalse(unexplained is CancellationError)
        XCTAssertTrue(unexplained.localizedDescription.contains("TLS negotiation"))
        XCTAssertTrue(ADBTransportSTLS.diagnosticError(cancelled, authenticationFailure: nil, cancelledByOwner: true) is CancellationError)
    }

    func testRegeneratedCertificateKeepsPublicKeyPinAndDifferentKeyIsRejected() throws {
        func key() throws -> SecKey {
            try XCTUnwrap(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil))
        }
        func certificate(_ key: SecKey, serial: UInt8) throws -> SecCertificate {
            let der = GoogleTVIdentity.der
            let pub = try XCTUnwrap(SecKeyCopyPublicKey(key))
            let bytes = try XCTUnwrap(SecKeyCopyExternalRepresentation(pub, nil) as Data?)
            let signatureAlgorithm = der(0x30, Data([0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x0b,0x05,0x00]))
            let rsaAlgorithm = der(0x30, Data([0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01,0x05,0x00]))
            let name = der(0x30, der(0x31, der(0x30, Data([0x06,0x03,0x55,0x04,0x03]) + der(0x0c, Data("adb-test".utf8)))))
            let validity = der(0x30, der(0x17, Data("260101000000Z".utf8)) + der(0x17, Data("360101000000Z".utf8)))
            let tbs = der(0x30, der(0xa0, der(0x02, Data([2]))) + der(0x02, Data([serial])) + signatureAlgorithm + name + validity + name + der(0x30, rsaAlgorithm + der(0x03, Data([0]) + bytes)))
            let signature = try XCTUnwrap(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, tbs as CFData, nil) as Data?)
            return try XCTUnwrap(SecCertificateCreateWithData(nil, der(0x30, tbs + signatureAlgorithm + der(0x03, Data([0]) + signature)) as CFData))
        }
        let sameKey = try key()
        let first = try certificate(sameKey, serial: 1)
        let renewed = try certificate(sameKey, serial: 2)
        XCTAssertNotEqual(SecCertificateCopyData(first) as Data, SecCertificateCopyData(renewed) as Data)
        XCTAssertEqual(try GoogleTVADBTrust.pin(certificate: first), try GoogleTVADBTrust.pin(certificate: renewed))
        XCTAssertNotEqual(try GoogleTVADBTrust.pin(certificate: first), try GoogleTVADBTrust.pin(certificate: certificate(key(), serial: 1)))
    }

    func testLegacyPinRequiresExplicitTrustRefreshWithoutLosingApprovals() throws {
        let legacy = GoogleTVADBConfiguration(host: "tv", port: 123, serverPin: Data(repeating: 7, count: 32), deviceGUID: "same-tv", dashboardIDs: ["test"], channelIDs: ["LXfrE81qMGA"])
        var decoded = try JSONDecoder().decode(GoogleTVADBConfiguration.self, from: JSONEncoder().encode(legacy))
        XCTAssertEqual(decoded, legacy)
        XCTAssertNoThrow(try decoded.validate())
        XCTAssertThrowsError(try decoded.trustedKeyPin())
        decoded.pinFormat = GoogleTVADBTrust.format
        XCTAssertEqual(try decoded.trustedKeyPin(), legacy.serverPin)
        XCTAssertEqual(decoded.deviceGUID, legacy.deviceGUID)
        XCTAssertEqual(decoded.dashboardIDs, legacy.dashboardIDs)
        XCTAssertEqual(decoded.channelIDs, legacy.channelIDs)
    }

    func testLegacyConfigurationDoesNotGrantPowerAndShellRequiresCleanExit() throws {
        let old = GoogleTVADBConfiguration(host: "tv", port: 123, serverPin: Data(repeating: 7, count: 32), deviceGUID: "tv")
        let decoded = try JSONDecoder().decode(GoogleTVADBConfiguration.self, from: JSONEncoder().encode(old))
        XCTAssertNil(decoded.powerToggleAllowed)
        var success = GoogleTVADBShellResult(power: true)
        XCTAssertTrue(try success.append(frame(3, Data([0]))))
        var failure = GoogleTVADBShellResult(power: true)
        XCTAssertThrowsError(try failure.append(frame(3, Data([1]))))
        var stderr = GoogleTVADBShellResult(power: true)
        XCTAssertThrowsError(try stderr.append(frame(2, Data("Error".utf8)) + frame(3, Data([0]))))
    }

    func testPowerUsesExactlyOneFixedADBShellCommand() async throws {
        let transport = MockADBTransport([.stlsMessage(), .connectMessage(), .readyMessage(localId: 9, remoteId: 1), ADBMessage(command: .write, arg0: 9, arg1: 1, data: frame(3, Data([0])))])
        let client = GoogleTVADBClient(transport: transport)
        defer { client.close() }
        try await client.connect(host: "test", port: 123)
        try await client.togglePower()
        XCTAssertTrue(transport.upgraded)
        let opens = transport.sent.filter { $0.commandType == .open }
        XCTAssertEqual(opens.count, 1)
        XCTAssertEqual(opens.first?.data, Data("shell,v2,raw:input keyevent 177\0".utf8))
    }

    func testAutomaticScreenAccessStillRequiresPairingAndValidChannelIDs() {
        var configuration = GoogleTVADBConfiguration(host: "tv", port: 5555, serverPin: Data(repeating: 1, count: 32), deviceGUID: "paired-tv")
        XCTAssertFalse(configuration.permits(dashboard: "installed-screen", channel: "LXfrE81qMGA"))
        configuration.automaticScreenAccess = true
        XCTAssertTrue(configuration.permits(dashboard: "installed-screen", channel: "LXfrE81qMGA"))
        XCTAssertFalse(configuration.permits(dashboard: "installed-screen", channel: "shell:reboot"))
        configuration.serverPin = Data()
        XCTAssertFalse(configuration.permits(dashboard: "installed-screen", channel: "LXfrE81qMGA"))
    }

    @MainActor
    func testAutomaticPowerAccessRechecksPairingChangesBeforeSending() async throws {
        var configuration = GoogleTVADBConfiguration(host: "tv", port: 5555, serverPin: Data(repeating: 1, count: 32), deviceGUID: "paired-tv", pinFormat: GoogleTVADBTrust.format)
        configuration.automaticScreenAccess = true
        let mock = MockADBSession()
        let bridge = GoogleTVADBScreenConnection(load: { configuration }, makeClient: { _ in mock })
        _ = try await bridge.togglePower(dashboard: "installed-screen", parameters: [:])
        XCTAssertEqual(mock.toggles, 1)
        mock.connected = { configuration.automaticScreenAccess = false }
        do { _ = try await bridge.togglePower(dashboard: "installed-screen", parameters: [:]); XCTFail("Revoked access must not send") } catch {}
        XCTAssertEqual(mock.toggles, 1)
    }

    @MainActor
    func testPowerRequiresSeparatePermissionRechecksRevocationAndNeverRetries() async throws {
        var config = GoogleTVADBConfiguration(host: "test", port: 123, serverPin: Data(repeating: 1, count: 32), deviceGUID: "tv", dashboardIDs: ["screen"], channelIDs: ["LXfrE81qMGA"], pinFormat: GoogleTVADBTrust.format)
        let mock = MockADBSession()
        let bridge = GoogleTVADBScreenConnection(load: { config }, makeClient: { _ in mock })
        do { _ = try await bridge.togglePower(dashboard: "screen", parameters: [:]); XCTFail() } catch {}
        XCTAssertEqual(mock.connects, 0)
        config.powerToggleAllowed = true
        for (screen, parameters) in [("other", [:]), ("screen", ["command": "input keyevent 26"])] {
            do { _ = try await bridge.togglePower(dashboard: screen, parameters: parameters); XCTFail() } catch {}
        }
        XCTAssertEqual(mock.connects, 0)
        mock.connected = { config.powerToggleAllowed = false }
        do { _ = try await bridge.togglePower(dashboard: "screen", parameters: [:]); XCTFail() } catch {}
        XCTAssertEqual(mock.toggles, 0)
        config.powerToggleAllowed = true; mock.connected = nil; mock.failToggle = true
        do { _ = try await bridge.togglePower(dashboard: "screen", parameters: [:]); XCTFail() } catch {}
        XCTAssertEqual(mock.toggles, 1)
        mock.failToggle = false
        let result = try await bridge.togglePower(dashboard: "screen", parameters: [:])
        XCTAssertEqual(result["effectVerified"] as? Bool, false)
        XCTAssertEqual(result["transport"] as? String, "wireless-adb")
        XCTAssertEqual(mock.toggles, 2)
        XCTAssertEqual(mock.launches, 0)
    }

    private func hex(_ value: String) -> Data {
        var result = Data(); var index = value.startIndex
        while index < value.endIndex { let end = value.index(index, offsetBy: 2); result.append(UInt8(value[index..<end], radix: 16)!); index = end }
        return result
    }

    func testPairingTranscriptAgainstIndependentAffineEdwardsVector() throws {
        // Computed independently using Python integer affine Edwards arithmetic,
        // BoringSSL's documented M/N coordinates, client entropy 0...63 and
        // server entropy 63...0, password = six digits + 64-byte TLS exporter.
        let password = Data("123456".utf8) + Data(0..<64)
        let client = try SPAKE2Client(password: password, randomBytes: Array(0..<64))
        XCTAssertEqual(client.outgoingMessage, hex("001c2afa55b8c2de1d12a38958367cb5c27e95411595e7bbeb37ca5f6a2375df"))
        XCTAssertEqual(try client.processServerMessage(hex("834ba073a54d51cdeabaf6a9faae5ed24cb65de1df3f8bfaaa96ea9d9006076f")), hex("4c6f8b76a43ffd2a657d65e6b34c7fa4d8c518ba581060c7c9c39f2f8063ff22ae149085b11cf3e05b8015eea8729c0644034b651806ca253a3e1205a26c9d0a"))
        XCTAssertEqual(Data(SPAKE2Client.passwordScalar(Array(SHA512.hash(data: password)))), hex("40e3bb4106b6a25ec87e8074a33a7fb281309709fd3f747ad06f85dca92c1358"))
        XCTAssertThrowsError(try client.processServerMessage(Data(repeating: 0, count: 31)))
        XCTAssertNil(EdPoint.decode(Array(repeating: 255, count: 32)))
    }

    func testPairingRejectsTamperedPeerInfoAndInvalidCode() throws {
        let sender = PairingAuthEncryptor(keyMaterial: Data(repeating: 9, count: 64))
        let receiver = PairingAuthEncryptor(keyMaterial: Data(repeating: 9, count: 64))
        var ciphertext = try sender.encrypt(Data(repeating: 0, count: 8192)); ciphertext[0] ^= 1
        XCTAssertThrowsError(try receiver.decrypt(ciphertext))
        XCTAssertThrowsError(try ADBPairing.normalizedPairingCode("12345"))
        XCTAssertThrowsError(try ADBPairing.normalizedPairingCode("12a456"))
        var info = Data(repeating: 0, count: 8192); info[0] = 1
        info.replaceSubrange(1..<5, with: Data("test".utf8))
        XCTAssertEqual(try ADBPairing.parsePeerInfo(info).guid, "test")
        info[0] = 0; XCTAssertThrowsError(try ADBPairing.parsePeerInfo(info))
    }

    private func frame(_ id: UInt8, _ data: Data) -> Data {
        var count = UInt32(data.count).littleEndian
        return Data([id]) + withUnsafeBytes(of: &count) { Data($0) } + data
    }
    func testShellFragmentationAndFailure() throws {
        let wire = frame(1, Data("Status: ok\n".utf8)) + frame(3, Data([0]))
        var result = GoogleTVADBShellResult()
        for byte in wire.dropLast() { XCTAssertFalse(try result.append(Data([byte]))) }
        XCTAssertTrue(try result.append(Data([wire.last!])))
        var failure = GoogleTVADBShellResult()
        XCTAssertThrowsError(try failure.append(frame(1, Data("Status: ok\n".utf8)) + frame(3, Data([1]))))
        var overflow = GoogleTVADBShellResult()
        XCTAssertThrowsError(try overflow.append(Data([1,255,255,255,127])))
    }

    func testRejectsPlaintextAndRequiresTLSBeforeCommands() async throws {
        let plaintext = MockADBTransport([.connectMessage()])
        let client = GoogleTVADBClient(transport: plaintext)
        do { try await client.connect(host: "test", port: 123); XCTFail("Accepted plaintext") } catch {}
        XCTAssertFalse(plaintext.upgraded)
        XCTAssertEqual(plaintext.sent.map(\.commandType), [.connect])
        let transport = MockADBTransport([.stlsMessage(), .connectMessage(), .readyMessage(localId: 9, remoteId: 1), ADBMessage(command: .write, arg0: 9, arg1: 1, data: frame(1, Data("Status: ok\n".utf8)) + frame(3, Data([0])))])
        let secure = GoogleTVADBClient(transport: transport)
        try await secure.connect(host: "test", port: 123)
        try await secure.launch(channelID: "LXfrE81qMGA")
        XCTAssertTrue(transport.upgraded)
        XCTAssertEqual(transport.sent.filter { $0.commandType == .open }.count, 1)
    }

    @MainActor
    func testPermissionsAreRecheckedAfterConnectAndNoAutomaticRetry() async throws {
        var config = GoogleTVADBConfiguration(host: "test", port: 123, serverPin: Data(repeating: 1, count: 32), deviceGUID: "tv", dashboardIDs: ["test-screen"], channelIDs: ["LXfrE81qMGA"], pinFormat: GoogleTVADBTrust.format)
        let mock = MockADBSession()
        let bridge = GoogleTVADBScreenConnection(load: { config }, makeClient: { _ in mock })
        do { _ = try await bridge.launch(dashboard: "other", parameters: ["channelID": "LXfrE81qMGA"]); XCTFail() } catch {}
        XCTAssertEqual(mock.connects, 0)
        mock.connected = { config.channelIDs = [] }
        do { _ = try await bridge.launch(dashboard: "test-screen", parameters: ["channelID": "LXfrE81qMGA"]); XCTFail() } catch {}
        XCTAssertEqual(mock.connects, 1); XCTAssertEqual(mock.launches, 0)
        config.channelIDs = ["LXfrE81qMGA"]; mock.connected = { bridge.close() }
        do { _ = try await bridge.launch(dashboard: "test-screen", parameters: ["channelID": "LXfrE81qMGA"]); XCTFail() } catch {}
        XCTAssertEqual(mock.launches, 0)
    }
}

private final class MockADBTransport: ADBClientTransport, @unchecked Sendable {
    var messages: [ADBMessage]; var sent: [ADBMessage] = []; var upgraded = false
    init(_ messages: [ADBMessage]) { self.messages = messages }
    func connect(host: String, port: UInt16, timeout: TimeInterval) async throws {}
    func sendMessage(_ message: ADBMessage) async throws { sent.append(message) }
    func receiveMessage(timeout: TimeInterval?) async throws -> ADBMessage { guard !messages.isEmpty else { throw ADBError.connectionClosed }; return messages.removeFirst() }
    func upgradeToTLS() async throws { upgraded = true }
    func disconnect() {}
}
private final class MockADBSession: GoogleTVADBSession, @unchecked Sendable {
    var connects = 0; var launches = 0; var toggles = 0; var failToggle = false
    var connected: (@MainActor () -> Void)?
    func connect(host: String, port: UInt16) async throws { connects += 1; await connected?() }
    func launch(channelID: String) async throws { launches += 1 }
    func togglePower() async throws { toggles += 1; if failToggle { throw ADBError.connectionClosed } }
    func close() {}
}
