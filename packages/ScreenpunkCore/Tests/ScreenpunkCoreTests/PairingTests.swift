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

    /// Runs the same scenarios as sdk/test/pairing.test.ts against the Swift state machine.
    func testSharedScenariosMatchTypeScript() throws {
        let fixture = try PairingFixture.load()
        XCTAssertEqual(fixture.info, PairingLimits.sasInfo)
        XCTAssertEqual(fixture.expirySeconds, PairingLimits.expirySeconds)
        XCTAssertEqual(fixture.maxFailedAttempts, PairingLimits.maxFailedAttempts)
        XCTAssertGreaterThanOrEqual(fixture.scenarios.count, 10)
        XCTAssertEqual(Set(fixture.scenarios.map(\.id)).count, fixture.scenarios.count)

        var exercised = Set<String>()
        for scenario in fixture.scenarios {
            var state = DevicePairingState()
            for (index, step) in scenario.steps.enumerated() {
                let label = "\(scenario.id) step \(index + 1) (\(step.op))"
                let clock = FixedClock(start.addingTimeInterval(step.atSeconds))
                exercised.insert(step.expect)
                let outcome = run(step: step, on: &state, fixture: fixture, clock: clock)
                XCTAssertEqual(outcome, step.expect, label)
            }
            let owner = state.owner.map { hex($0.publicKey) }
            let expected = scenario.finalOwner.flatMap { fixture.identities[$0]?.publicKey }
            XCTAssertEqual(owner, expected, "\(scenario.id) final owner")
        }
        for required in ["ok", "expired", "rateLimited", "codeMismatch", "identityChanged", "secondOwner", "invalidIdentity"] {
            XCTAssertTrue(exercised.contains(required), "scenarios must exercise \(required)")
        }
    }

    private func run(
        step: PairingFixture.Step,
        on state: inout DevicePairingState,
        fixture: PairingFixture,
        clock: FixedClock
    ) -> String {
        do {
            switch step.op {
            case "begin":
                guard let vector = fixture.cases.first(where: { $0.id == step.case }) else {
                    return "unknown case \(step.case ?? "nil")"
                }
                let candidate = step.candidate.flatMap { fixture.identity(named: $0) }
                    ?? PairingIdentity(role: .controller, publicKey: bytes(vector.controllerPublicKey))
                try state.begin(
                    transcript: PairingTranscript(
                        devicePublicKey: bytes(fixture.devicePublicKey),
                        controllerPublicKey: bytes(vector.controllerPublicKey),
                        sessionNonce: bytes(fixture.sessionNonce)
                    ),
                    expectedCode: vector.code,
                    candidateOwner: candidate,
                    clock: clock
                )
            case "confirm":
                guard let presented = step.presented.flatMap({ fixture.identity(named: $0) }) else {
                    return "unknown identity \(step.presented ?? "nil")"
                }
                try state.confirm(code: fixture.resolveCode(step.code ?? ""), presentedOwner: presented, clock: clock)
            default:
                return "unknown op \(step.op)"
            }
            return "ok"
        } catch let failure as PairingFailure {
            return failure.rawValue
        } catch {
            return "unexpected \(error)"
        }
    }

    private func bytes(_ hexString: String) -> [UInt8] {
        var out: [UInt8] = []
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2, limitedBy: hexString.endIndex) ?? hexString.endIndex
            out.append(UInt8(hexString[index..<next], radix: 16) ?? 0)
            index = next
        }
        return out
    }

    private func hex(_ value: [UInt8]) -> String {
        value.map { String(format: "%02x", $0) }.joined()
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

    func testEveryPublishedVectorCodeMatchesCryptoKit() throws {
        let fixture = try PairingFixture.load()
        for vector in fixture.cases {
            let code = PairingSAS.matchingCode(for: PairingTranscript(
                devicePublicKey: bytes(fixture.devicePublicKey),
                controllerPublicKey: bytes(vector.controllerPublicKey),
                sessionNonce: bytes(fixture.sessionNonce)
            ))
            XCTAssertEqual(code, vector.code, vector.id)
        }
    }
    #endif
}

struct PairingFixture: Decodable {
    struct Vector: Decodable {
        var id: String
        var controllerPublicKey: String
        var macHex: String
        var code: String
    }

    struct Identity: Decodable {
        var role: String
        var publicKey: String
    }

    struct Step: Decodable {
        var op: String
        var `case`: String?
        var candidate: String?
        var code: String?
        var presented: String?
        var atSeconds: TimeInterval
        var expect: String
    }

    struct Scenario: Decodable {
        var id: String
        var steps: [Step]
        var finalOwner: String?
    }

    var info: String
    var expirySeconds: TimeInterval
    var maxFailedAttempts: Int
    var devicePublicKey: String
    var sessionNonce: String
    var cases: [Vector]
    var identities: [String: Identity]
    var scenarios: [Scenario]

    static func load() throws -> PairingFixture {
        try RepoFixtures.decode(PairingFixture.self, from: "tests/feasibility/pairing/vectors.json")
    }

    func identity(named name: String) -> PairingIdentity? {
        guard let entry = identities[name] else { return nil }
        var out: [UInt8] = []
        var index = entry.publicKey.startIndex
        while index < entry.publicKey.endIndex {
            let next = entry.publicKey.index(index, offsetBy: 2, limitedBy: entry.publicKey.endIndex)
                ?? entry.publicKey.endIndex
            out.append(UInt8(entry.publicKey[index..<next], radix: 16) ?? 0)
            index = next
        }
        return PairingIdentity(role: PairingRole(rawValue: entry.role) ?? .device, publicKey: out)
    }

    func resolveCode(_ spec: String) -> String {
        guard spec.hasPrefix("case:") else { return spec }
        let id = String(spec.dropFirst("case:".count))
        return cases.first(where: { $0.id == id })?.code ?? spec
    }
}
