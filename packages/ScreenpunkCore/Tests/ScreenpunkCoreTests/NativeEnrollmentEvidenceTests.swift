import XCTest
@testable import ScreenpunkCore
final class NativeEnrollmentEvidenceTests: XCTestCase {
    func fixture(format: CloudInstallationCredentialFormat = .nativeInstallationV1) throws -> (DeviceManagementFormatHistory, DeviceManagementFormatHistory.Binding, NativeClaimInput, UUID) {
        let transition = UUID(), binding = try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: transition, credentialReference: "opaque-ref", format: format)
        let history = try DeviceManagementFormatHistory(transitions: [.init(transitionID: transition, phase: .intent)], credentials: [binding])
        return (history, binding, try .init(requestId: UUID(), transitionId: transition, accountId: UUID(), locationId: UUID(), name: "Cafe\u{301}", profile: "iPad"), UUID())
    }
    func claim(_ input: NativeClaimInput, outcome: NativeClaimReceipt.Outcome = .pending, installation: UUID = UUID(), challenge: UUID = UUID()) throws -> NativeClaimReceipt {
        try .init(installationId: installation, requestId: input.requestId, transitionId: input.transitionId, challengeId: challenge, accountId: input.accountId, locationId: input.locationId, createdAt: "2026-10-01T00:00:00Z", expiresAt: "2026-10-01T00:10:00Z", outcome: outcome)
    }
    func testExactEncodingAndLegacyRejection() throws {
        let (h,b,i,id) = try fixture()
        let equivalent = try NativeClaimInput(requestId: i.requestId, transitionId: i.transitionId, accountId: i.accountId, locationId: i.locationId, name: "Café", profile: i.profile)
        XCTAssertNotEqual(i, equivalent)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: nativeEnrollmentBytes(i)) as? [String: Any])
        XCTAssertTrue(try XCTUnwrap(object["name"] as? String).utf8.elementsEqual(i.name.utf8))
        XCTAssertNoThrow(try NativeEnrollmentRecovery.proposingClaim(in: .init(), history: h, enrollmentId: id, binding: b, input: i))
        let (old,ob,oi,oid) = try fixture(format: .legacyLocal32)
        XCTAssertThrowsError(try NativeEnrollmentRecovery.proposingClaim(in: .init(), history: old, enrollmentId: oid, binding: ob, input: oi))
    }
    func testBoundedPathHistoricalOnlyAndFencing() throws {
        let (h,b,i,id) = try fixture()
        let first = try NativeEnrollmentRecovery.proposingClaim(in: .init(), history: h, enrollmentId: id, binding: b, input: i)
        XCTAssertThrowsError(try NativeEnrollmentRecovery.proposingClaim(in: first, history: h, enrollmentId: UUID(), binding: b, input: i))
        let c = try claim(i)
        let pending = try NativeEnrollmentRecovery.proposingClaimObservation(in: first, history: h, enrollmentId: id, result: .claim(c))
        let duplicate = try NativeEnrollmentRecovery.proposingClaimObservation(in: pending, history: h, enrollmentId: id, result: .claim(c))
        XCTAssertEqual(try nativeEnrollmentBytes(pending), try nativeEnrollmentBytes(duplicate))
        XCTAssertThrowsError(try NativeEnrollmentRecovery.proposingActivation(in: pending, history: h, enrollmentId: id, requestId: i.requestId))
        let request = UUID()
        let proposed = try NativeEnrollmentRecovery.proposingActivation(in: pending, history: h, enrollmentId: id, requestId: request)
        let generation = try NativeGenerationReceipt(generationId: UUID(), createdAt: "2026-10-01T00:01:00Z", renewAfter: "2026-10-31T00:01:00Z", expiresAt: "2026-12-30T00:01:00Z")
        let activation = try NativeActivationReceipt(installationId: c.installationId, deviceId: c.installationId, requestId: request, accountId: i.accountId, locationId: i.locationId, transitionId: i.transitionId, activatedAt: generation.createdAt, initialGeneration: generation)
        XCTAssertThrowsError(try NativeEnrollmentRecovery.proposingClaimObservation(in: first, history: h, enrollmentId: id, result: .activated(activation)))
        let done = try NativeEnrollmentRecovery.proposingActivationObservation(in: proposed, history: h, enrollmentId: id, receipt: activation)
        XCTAssertEqual(done.enrollments[0].events.count, 4)
        guard case .historicalActivationOnly = NativeEnrollmentRecovery.recoveryPlan(evidence: done, history: h, enrollmentId: id, availableCredentialReferences: []) else { return XCTFail() }
        let fenced = try DeviceManagementFormatHistory(transitions: [.init(transitionID: b.transitionID, phase: .locallyFenced)], credentials: [b])
        XCTAssertThrowsError(try NativeEnrollmentRecovery.proposingActivation(in: pending, history: fenced, enrollmentId: id, requestId: UUID()))
        guard case .blocked = NativeEnrollmentRecovery.recoveryPlan(evidence: proposed, history: fenced, enrollmentId: id, availableCredentialReferences: [b.credentialReference]) else { return XCTFail() }
        XCTAssertLessThan(try nativeEnrollmentBytes(done.enrollments[0]).count, NativeEnrollmentEvidence.reservedBytesPerRecord)
    }
    func testFullLedgerReservesCompletionAndRejectsAdmission() throws {
        var records: [NativeEnrollmentEvidence.Enrollment] = []
        for _ in 0..<64 {
            let (_, b, i, id) = try fixture()
            let maximum = try NativeClaimInput(requestId: i.requestId, transitionId: i.transitionId, accountId: i.accountId, locationId: i.locationId, name: String(repeating: "\\", count: 128), profile: String(repeating: "😀", count: 128))
            let c = try claim(maximum)
            let input = NativeActivationInput(installationId: c.installationId, requestId: UUID(), challengeId: c.challengeId, transitionId: c.transitionId)
            let generation = try NativeGenerationReceipt(generationId: UUID(), createdAt: "2026-10-01T00:01:00Z", renewAfter: "2026-10-31T00:01:00Z", expiresAt: "2026-12-30T00:01:00Z")
            let a = try NativeActivationReceipt(installationId: c.installationId, deviceId: c.installationId, requestId: input.requestId, accountId: i.accountId, locationId: i.locationId, transitionId: i.transitionId, activatedAt: generation.createdAt, initialGeneration: generation)
            records.append(.init(localEnrollmentId: id, binding: b, claimInput: maximum, events: [.claimProposed, .pendingClaimObserved(c), .activationProposed(input), .historicalActivationObserved(a)]))
        }
        let full = try NativeEnrollmentEvidence(records)
        XCTAssertLessThan(try nativeEnrollmentBytes(full).count, NativeEnrollmentEvidence.maximumEncodedBytes)
        XCTAssertThrowsError(try NativeEnrollmentEvidence(records + [records[0]]))
    }
    func testTerminalPathsAndConflicts() throws {
        for terminal in [NativeClaimReceipt.Outcome.expired, .cancelled] {
            for activate in [false, true] {
                let (h,b,i,id) = try fixture()
                var e = try NativeEnrollmentRecovery.proposingClaim(in: .init(), history: h, enrollmentId: id, binding: b, input: i)
                let c = try claim(i)
                e = try NativeEnrollmentRecovery.proposingClaimObservation(in: e, history: h, enrollmentId: id, result: .claim(c))
                if activate { e = try NativeEnrollmentRecovery.proposingActivation(in: e, history: h, enrollmentId: id, requestId: UUID()) }
                let t = try claim(i, outcome: terminal, installation: c.installationId, challenge: c.challengeId)
                e = try NativeEnrollmentRecovery.proposingClaimObservation(in: e, history: h, enrollmentId: id, result: .claim(t))
                guard case .terminalClaimEvidence = NativeEnrollmentRecovery.recoveryPlan(evidence: e, history: h, enrollmentId: id, availableCredentialReferences: []) else { return XCTFail() }
                XCTAssertThrowsError(try NativeEnrollmentRecovery.proposingClaimObservation(in: e, history: h, enrollmentId: id, result: .claim(c)))
                XCTAssertNoThrow(try NativeEnrollmentRecovery.proposingClaimObservation(in: e, history: h, enrollmentId: id, result: .claim(t)))
            }
            let (h,b,i,id) = try fixture()
            let first = try NativeEnrollmentRecovery.proposingClaim(in: .init(), history: h, enrollmentId: id, binding: b, input: i)
            XCTAssertNoThrow(try NativeEnrollmentRecovery.proposingClaimObservation(in: first, history: h, enrollmentId: id, result: .claim(claim(i, outcome: terminal))))
        }
    }
    func testReceiptMismatchProofAndHistoryGuards() throws {
        let (h,b,i,id) = try fixture()
        let first = try NativeEnrollmentRecovery.proposingClaim(in: .init(), history: h, enrollmentId: id, binding: b, input: i)
        for field in 0..<4 {
            let bad = try NativeClaimReceipt(installationId: UUID(), requestId: field == 0 ? UUID() : i.requestId, transitionId: field == 1 ? UUID() : i.transitionId, challengeId: UUID(), accountId: field == 2 ? UUID() : i.accountId, locationId: field == 3 ? UUID() : i.locationId, createdAt: "2026-10-01T00:00:00Z", expiresAt: "2026-10-01T00:10:00Z", outcome: .pending)
            XCTAssertThrowsError(try NativeEnrollmentRecovery.proposingClaimObservation(in: first, history: h, enrollmentId: id, result: .claim(bad)))
        }
        XCTAssertThrowsError(try NativeEnrollmentRecovery.proposingClaimObservation(in: first, history: h, enrollmentId: id, result: .claim(claim(i, installation: id))))
        let c = try claim(i)
        let pending = try NativeEnrollmentRecovery.proposingClaimObservation(in: first, history: h, enrollmentId: id, result: .claim(c))
        XCTAssertThrowsError(try NativeEnrollmentRecovery.proposingClaimObservation(in: pending, history: h, enrollmentId: id, result: .claim(claim(i))))
        guard case .blocked = NativeEnrollmentRecovery.recoveryPlan(evidence: first, history: h, enrollmentId: id, availableCredentialReferences: []) else { return XCTFail() }
        let changed = try DeviceManagementFormatHistory.Binding(credentialGenerationID: b.credentialGenerationID, transitionID: b.transitionID, credentialReference: "different-ref", format: b.format)
        let tampered = try DeviceManagementFormatHistory(transitions: h.transitions, credentials: [changed])
        guard case .blocked = NativeEnrollmentRecovery.recoveryPlan(evidence: first, history: tampered, enrollmentId: id, availableCredentialReferences: [b.credentialReference]) else { return XCTFail() }
        let request = UUID()
        let proposed = try NativeEnrollmentRecovery.proposingActivation(in: pending, history: h, enrollmentId: id, requestId: request)
        let g = try NativeGenerationReceipt(generationId: UUID(), createdAt: "2026-10-01T00:01:00Z", renewAfter: "2026-10-31T00:01:00Z", expiresAt: "2026-12-30T00:01:00Z")
        for field in 0..<5 {
            let installation = field == 4 ? UUID() : c.installationId
            let bad = try NativeActivationReceipt(installationId: installation, deviceId: installation, requestId: field == 0 ? UUID() : request, accountId: field == 1 ? UUID() : i.accountId, locationId: field == 2 ? UUID() : i.locationId, transitionId: field == 3 ? UUID() : i.transitionId, activatedAt: g.createdAt, initialGeneration: g)
            XCTAssertThrowsError(try NativeEnrollmentRecovery.proposingActivationObservation(in: proposed, history: h, enrollmentId: id, receipt: bad))
        }
        let good = try NativeActivationReceipt(installationId: c.installationId, deviceId: c.installationId, requestId: request, accountId: i.accountId, locationId: i.locationId, transitionId: i.transitionId, activatedAt: g.createdAt, initialGeneration: g)
        let done = try NativeEnrollmentRecovery.proposingActivationObservation(in: proposed, history: h, enrollmentId: id, receipt: good)
        XCTAssertNoThrow(try NativeEnrollmentRecovery.proposingActivationObservation(in: done, history: h, enrollmentId: id, receipt: good))
        let other = try NativeGenerationReceipt(generationId: UUID(), createdAt: g.createdAt, renewAfter: g.renewAfter, expiresAt: g.expiresAt)
        let conflict = try NativeActivationReceipt(installationId: c.installationId, deviceId: c.installationId, requestId: request, accountId: i.accountId, locationId: i.locationId, transitionId: i.transitionId, activatedAt: g.createdAt, initialGeneration: other)
        XCTAssertThrowsError(try NativeEnrollmentRecovery.proposingActivationObservation(in: done, history: h, enrollmentId: id, receipt: conflict))
    }
    func testPublicFullCapacityCompletionAndServerOwnership() throws {
        var transitions: [DeviceManagementTransitionEntry] = [], bindings: [DeviceManagementFormatHistory.Binding] = []
        var evidence = NativeEnrollmentEvidence()
        var last: (NativeClaimInput, UUID, NativeClaimReceipt)?
        var firstInstallation: UUID?
        for index in 0..<64 {
            if let previous = transitions.popLast() { transitions.append(.init(transitionID: previous.transitionID, phase: .locallyFenced)) }
            let (_, original, i, id) = try fixture()
            let b = try DeviceManagementFormatHistory.Binding(credentialGenerationID: original.credentialGenerationID, transitionID: original.transitionID, credentialReference: "opaque-ref-\(index)", format: original.format)
            transitions.append(.init(transitionID: b.transitionID, phase: .intent)); bindings.append(b)
            let history = try DeviceManagementFormatHistory(transitions: transitions, credentials: bindings)
            evidence = try NativeEnrollmentRecovery.proposingClaim(in: evidence, history: history, enrollmentId: id, binding: b, input: i)
            if index == 1 {
                XCTAssertThrowsError(try NativeEnrollmentRecovery.proposingClaimObservation(in: evidence, history: history, enrollmentId: id, result: .claim(claim(i, installation: firstInstallation!))))
            }
            let c = try claim(i); firstInstallation = firstInstallation ?? c.installationId
            if index < 63 {
                evidence = try NativeEnrollmentRecovery.proposingClaimObservation(in: evidence, history: history, enrollmentId: id, result: .claim(c))
            }
            last = (i,id,c)
        }
        let history = try DeviceManagementFormatHistory(transitions: transitions, credentials: bindings)
        let (i,id,c) = try XCTUnwrap(last)
        evidence = try NativeEnrollmentRecovery.proposingClaimObservation(in: evidence, history: history, enrollmentId: id, result: .claim(c))
        evidence = try NativeEnrollmentRecovery.proposingActivation(in: evidence, history: history, enrollmentId: id, requestId: UUID())
        let terminal = try claim(i, outcome: .expired, installation: c.installationId, challenge: c.challengeId)
        evidence = try NativeEnrollmentRecovery.proposingClaimObservation(in: evidence, history: history, enrollmentId: id, result: .claim(terminal))
        XCTAssertEqual(evidence.enrollments.count, 64)
        XCTAssertEqual(evidence.enrollments.last?.events.count, 4)
        let old = evidence.enrollments[0], oldClaim = try XCTUnwrap({ () -> NativeClaimReceipt? in if case .pendingClaimObserved(let c) = old.events.last { return c }; return nil }())
        let oldTerminal = try claim(old.claimInput, outcome: .cancelled, installation: oldClaim.installationId, challenge: oldClaim.challengeId)
        XCTAssertNoThrow(try NativeEnrollmentRecovery.proposingClaimObservation(in: evidence, history: history, enrollmentId: old.localEnrollmentId, result: .claim(oldTerminal)))
        XCTAssertThrowsError(try NativeEnrollmentRecovery.proposingActivation(in: evidence, history: history, enrollmentId: old.localEnrollmentId, requestId: UUID()))
    }
    func testChallengeAndGenerationOwnershipAcrossEnrollments() throws {
        let (h,b,i,id) = try fixture()
        var evidence = try NativeEnrollmentRecovery.proposingClaim(in: .init(), history: h, enrollmentId: id, binding: b, input: i)
        let c = try claim(i)
        evidence = try NativeEnrollmentRecovery.proposingClaimObservation(in: evidence, history: h, enrollmentId: id, result: .claim(c))
        let request = UUID()
        evidence = try NativeEnrollmentRecovery.proposingActivation(in: evidence, history: h, enrollmentId: id, requestId: request)
        let g = try NativeGenerationReceipt(generationId: UUID(), createdAt: "2026-10-01T00:01:00Z", renewAfter: "2026-10-31T00:01:00Z", expiresAt: "2026-12-30T00:01:00Z")
        evidence = try NativeEnrollmentRecovery.proposingActivationObservation(in: evidence, history: h, enrollmentId: id, receipt: .init(installationId: c.installationId, deviceId: c.installationId, requestId: request, accountId: i.accountId, locationId: i.locationId, transitionId: i.transitionId, activatedAt: g.createdAt, initialGeneration: g))
        let (_, original, ni, nid) = try fixture()
        let nb = try DeviceManagementFormatHistory.Binding(credentialGenerationID: original.credentialGenerationID, transitionID: original.transitionID, credentialReference: "other-ref", format: original.format)
        let nh = try DeviceManagementFormatHistory(transitions: [.init(transitionID: b.transitionID, phase: .locallyFenced), .init(transitionID: nb.transitionID, phase: .intent)], credentials: [b,nb])
        evidence = try NativeEnrollmentRecovery.proposingClaim(in: evidence, history: nh, enrollmentId: nid, binding: nb, input: ni)
        XCTAssertThrowsError(try NativeEnrollmentRecovery.proposingClaimObservation(in: evidence, history: nh, enrollmentId: nid, result: .claim(claim(ni, challenge: c.challengeId))))
        let nc = try claim(ni)
        evidence = try NativeEnrollmentRecovery.proposingClaimObservation(in: evidence, history: nh, enrollmentId: nid, result: .claim(nc))
        let nr = UUID()
        evidence = try NativeEnrollmentRecovery.proposingActivation(in: evidence, history: nh, enrollmentId: nid, requestId: nr)
        let collision = try NativeActivationReceipt(installationId: nc.installationId, deviceId: nc.installationId, requestId: nr, accountId: ni.accountId, locationId: ni.locationId, transitionId: ni.transitionId, activatedAt: g.createdAt, initialGeneration: g)
        XCTAssertThrowsError(try NativeEnrollmentRecovery.proposingActivationObservation(in: evidence, history: nh, enrollmentId: nid, receipt: collision))
    }
    func testCalendarValidationAndOffsets() throws {
        for value in ["2026-02-30T00:00:00Z", "2026-10-01T24:00:00Z", "2026-10-01T00:00:00+24:00", "2026-10-01T00:00:00+00:60", "2026-13-01T00:00:00Z"] {
            XCTAssertThrowsError(try nativeEnrollmentTime(value))
        }
        XCTAssertEqual(try nativeEnrollmentTime("2026-10-01T01:00:00.125+01:00"), try nativeEnrollmentTime("2026-10-01T00:00:00.125Z"))
        let fraction = String(repeating: "0", count: 220)
        let g = try NativeGenerationReceipt(generationId: UUID(), createdAt: "2026-10-01T00:00:00." + fraction + "Z", renewAfter: "2026-10-31T00:00:00." + fraction + "Z", expiresAt: "2026-12-30T00:00:00." + fraction + "Z")
        XCTAssertLessThan(try nativeEnrollmentBytes(g).count, NativeEnrollmentEvidence.reservedBytesPerRecord)
    }
    func testBoundedExactTimestampParsingWithoutFormatter() throws {
        XCTAssertThrowsError(try nativeEnrollmentTime(String(repeating: "0", count: 4096)))
        XCTAssertEqual(try nativeEnrollmentTime("1970-01-01T00:00:00Z").seconds, 0)
        XCTAssertEqual(try nativeEnrollmentTime("1969-12-31T23:59:59Z").seconds, -1)
        XCTAssertEqual(try nativeEnrollmentTime("2000-03-01T00:00:00Z").seconds - (try nativeEnrollmentTime("2000-02-28T00:00:00Z").seconds), 172800)
        XCTAssertEqual(try nativeEnrollmentTime("1900-03-01T00:00:00Z").seconds - (try nativeEnrollmentTime("1900-02-28T00:00:00Z").seconds), 86400)
        for invalid in ["2026-10-01T00:00:00.Z", "2026-10-01T00:00:00.1", "2026-10-01T00:00:00Zextra", "2026-10-01T00:00:00+01", "2026-10-01T00:00:00.１Z", "2026-10-01T00:00:00Z\n", "0000-01-01T00:00:00Z", "2026-10-01T00:00:60Z"] {
            XCTAssertThrowsError(try nativeEnrollmentTime(invalid))
        }
        let fraction = String(repeating: "0", count: 234) + "1"
        let exact = "2026-10-01T00:00:00." + fraction + "Z"
        XCTAssertEqual(exact.utf8.count, 256)
        XCTAssertEqual(try nativeEnrollmentTime(exact).fraction.utf8.count, 235)
        XCTAssertThrowsError(try nativeEnrollmentTime("2026-10-01T00:00:00." + fraction + "0Z"))
        XCTAssertFalse(try nativeEnrollmentInterval("2026-10-01T00:10:00Z", exact, seconds: 600))
        XCTAssertTrue(try nativeEnrollmentInterval("2026-10-01T00:10:00." + fraction + "Z", exact, seconds: 600))
        XCTAssertEqual(try nativeEnrollmentTime("2026-10-01T00:00:00.125000Z"), try nativeEnrollmentTime("2026-10-01T01:00:00.125+01:00"))
        XCTAssertEqual(try nativeEnrollmentTime("2026-09-30T23:00:00.125-01:00"), try nativeEnrollmentTime("2026-10-01T00:00:00.125Z"))
        XCTAssertThrowsError(try NativeClaimReceipt(installationId: UUID(), requestId: UUID(), transitionId: UUID(), challengeId: UUID(), accountId: UUID(), locationId: UUID(), createdAt: exact, expiresAt: "2026-10-01T00:10:00Z", outcome: .pending))
    }
    func testInvalidNamesAndTiming() throws {
        let (_,_,i,_) = try fixture()
        for name in ["\u{FEFF} ", "\n", String(repeating: "a", count: 129)] {
            XCTAssertThrowsError(try NativeClaimInput(requestId: i.requestId, transitionId: i.transitionId, accountId: i.accountId, locationId: i.locationId, name: name, profile: "valid"))
        }
        XCTAssertThrowsError(try NativeGenerationReceipt(generationId: UUID(), createdAt: "2026-10-01T00:00:00Z", renewAfter: "2026-10-02T00:00:00Z", expiresAt: "2026-12-30T00:00:00Z"))
    }
}
