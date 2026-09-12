import XCTest
@testable import ScreenpunkCore

final class PairingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let deviceKey = [UInt8](repeating: 0x01, count: 32)
    private let controllerKey = [UInt8](repeating: 0x02, count: 32)
    private let attackerKey = [UInt8](repeating: 0x99, count: 32)
    private let sessionNonce = [UInt8](repeating: 0x03, count: 16)
    /// Keep in sync with tests/feasibility/pairing/vectors.json
    private let honestCode = "833492"
    private let mitmCode = "287900"

    private func transcript(controller: [UInt8]? = nil) -> PairingTranscript {
        PairingTranscript(
            devicePublicKey: deviceKey,
            controllerPublicKey: controller ?? controllerKey,
            sessionNonce: sessionNonce
        )
    }

    private func controller(_ key: [UInt8]) -> PairingIdentity {
        PairingIdentity(role: .controller, publicKey: key)
    }

    func testExpiryAndRateLimit() throws {
        var state = DevicePairingState()
        let owner = controller(controllerKey)
        try state.begin(
            transcript: transcript(),
            expectedCode: honestCode,
            candidateOwner: owner,
            clock: FixedClock(start)
        )
        XCTAssertThrowsError(
            try state.confirm(code: honestCode, presentedOwner: owner, clock: FixedClock(start.addingTimeInterval(121)))
        ) { error in
            XCTAssertEqual(error as? PairingFailure, .expired)
        }

        var limited = DevicePairingState()
        try limited.begin(
            transcript: transcript(),
            expectedCode: honestCode,
            candidateOwner: owner,
            clock: FixedClock(start)
        )
        for _ in 0..<4 {
            XCTAssertThrowsError(
                try limited.confirm(code: "000000", presentedOwner: owner, clock: FixedClock(start))
            ) { error in
                XCTAssertEqual(error as? PairingFailure, .codeMismatch)
            }
        }
        XCTAssertThrowsError(
            try limited.confirm(code: "000000", presentedOwner: owner, clock: FixedClock(start))
        ) { error in
            XCTAssertEqual(error as? PairingFailure, .rateLimited)
        }
        XCTAssertNil(limited.owner)
    }

    func testSecondOwnerAndIdentityChange() throws {
        var state = DevicePairingState()
        let owner = controller(controllerKey)
        try state.begin(
            transcript: transcript(),
            expectedCode: honestCode,
            candidateOwner: owner,
            clock: FixedClock(start)
        )
        try state.confirm(code: honestCode, presentedOwner: owner, clock: FixedClock(start))
        XCTAssertEqual(state.owner, owner)

        XCTAssertThrowsError(
            try state.begin(
                transcript: transcript(controller: attackerKey),
                expectedCode: mitmCode,
                candidateOwner: controller(attackerKey),
                clock: FixedClock(start)
            )
        ) { error in
            XCTAssertEqual(error as? PairingFailure, .secondOwner)
        }

        var midSession = DevicePairingState()
        try midSession.begin(
            transcript: transcript(),
            expectedCode: honestCode,
            candidateOwner: owner,
            clock: FixedClock(start)
        )
        XCTAssertThrowsError(
            try midSession.confirm(
                code: honestCode,
                presentedOwner: controller(attackerKey),
                clock: FixedClock(start)
            )
        ) { error in
            XCTAssertEqual(error as? PairingFailure, .identityChanged)
        }
    }

    func testNoCredentialsInPublishedVectors() {
        XCTAssertFalse(honestCode.contains("sk-"))
        XCTAssertEqual(PairingLimits.expirySeconds, 120)
        XCTAssertEqual(PairingLimits.maxFailedAttempts, 5)
    }

    #if canImport(CryptoKit)
    func testPublishedSASVectors() {
        let honest = transcript()
        XCTAssertEqual(PairingSAS.matchingCode(for: honest), honestCode)
        let mitm = transcript(controller: attackerKey)
        XCTAssertEqual(PairingSAS.matchingCode(for: mitm), mitmCode)
        XCTAssertNotEqual(
            PairingSAS.matchingCode(for: honest),
            PairingSAS.matchingCode(for: mitm)
        )
        let changed = transcript(controller: [UInt8](repeating: 0x04, count: 32))
        XCTAssertEqual(PairingSAS.matchingCode(for: changed), "756361")
    }
    #endif
}
