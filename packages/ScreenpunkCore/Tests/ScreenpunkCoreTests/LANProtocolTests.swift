import XCTest
@testable import ScreenpunkCore

final class LANProtocolTests: XCTestCase {
    func testFrameRejectsOversizedAndRoundTrips() throws {
        let envelope = LANEnvelope(requestId: "r1", method: LANMethod.hello.rawValue, ok: true)
        let body = try LANCodec.encode(envelope)
        let framed = try LANCodec.frame(body)
        XCTAssertEqual(framed.count, body.count + 4)
        let length = try LANCodec.messageLength(fromHeader: framed.prefix(4))
        XCTAssertEqual(length, body.count)
        let decoded = try LANCodec.decode(Data(framed.dropFirst(4)))
        XCTAssertEqual(decoded.requestId, "r1")
        XCTAssertEqual(decoded.protocolVersion, 1)

        let huge = Data(repeating: 1, count: LANProtocolLimits.maxMessageBytes + 1)
        XCTAssertThrowsError(try LANCodec.frame(huge))
        XCTAssertThrowsError(try LANCodec.messageLength(fromHeader: Data([0x7F, 0xFF, 0xFF, 0xFF])))
    }

    func testTransferLimitNegotiationAndHeaderBounds() throws {
        XCTAssertEqual(LANProtocolLimits.transferLimit(advertised: nil), 2 * 1024 * 1024)
        XCTAssertEqual(LANProtocolLimits.transferLimit(advertised: -1), 2 * 1024 * 1024)
        XCTAssertEqual(LANProtocolLimits.transferLimit(advertised: 32 * 1024 * 1024), 32 * 1024 * 1024)
        XCTAssertEqual(LANProtocolLimits.transferLimit(advertised: Int.max), 32 * 1024 * 1024)
        XCTAssertEqual(try LANCodec.messageLength(fromHeader: Data([2, 0, 0, 0])), 32 * 1024 * 1024)
        XCTAssertThrowsError(try LANCodec.messageLength(fromHeader: Data([2, 0, 0, 1])))
        XCTAssertThrowsError(try LANCodec.messageLength(fromHeader: Data([0, 32, 0, 1]), maximumBytes: LANProtocolLimits.legacyMessageBytes))
        let legacy = "{\"role\":\"device\",\"deviceId\":\"old\",\"pinHex\":\"00\",\"protocolMajor\":1}"
        let hello = try LANCodec.decodePayload(LANHello.self, json: legacy)
        XCTAssertNil(hello.maxTransferBytes)
    }

    func testPinMismatchIsIdentityChanged() {
        let pinned = PairingIdentityFactory.make(role: .device, bytes: [UInt8](repeating: 0x11, count: 32))
        let other = PairingIdentityFactory.make(role: .device, bytes: [UInt8](repeating: 0x22, count: 32))
        XCTAssertThrowsError(try PinnedPeer.rejectIfChanged(pinned: pinned, presented: other)) { error in
            XCTAssertEqual(error as? PairingFailure, .identityChanged)
        }
        XCTAssertNoThrow(try PinnedPeer.rejectIfChanged(pinned: pinned, presented: pinned))
        let pin = [UInt8](repeating: 0xAB, count: 32)
        XCTAssertEqual(PeerPin.bytes(PeerPin.hex(pin)), pin)
        XCTAssertNil(PeerPin.parseHex("abc"))
        XCTAssertNil(PeerPin.parseHex("zz"))
        XCTAssertEqual(PeerPin.parseHex(""), [])
    }

    func testHelloPayloadContainsNoSecrets() throws {
        let hello = LANHello(role: .device, deviceId: "phone-1", pinHex: PeerPin.hex([UInt8](repeating: 1, count: 32)))
        let json = try LANCodec.encodePayload(hello)
        XCTAssertFalse(json.contains("sk-"))
        XCTAssertFalse(json.contains("password"))
        XCTAssertTrue(json.contains("phone-1"))
    }
}
