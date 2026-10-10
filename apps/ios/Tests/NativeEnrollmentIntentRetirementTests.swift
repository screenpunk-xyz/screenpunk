import XCTest
import Darwin
@testable import Screenpunk

final class NativeEnrollmentIntentRetirementTests: XCTestCase {
    private func fixture() throws -> (URL, NativeEnrollmentIntentJournal, NativeEnrollmentIntentRecord) {
        let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(physical) }
        let parent = URL(fileURLWithPath: String(cString: physical), isDirectory: true).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let journal = NativeEnrollmentIntentJournal(directory: parent.appendingPathComponent("intent"))
        let record = try NativeEnrollmentIntentRecord(accountID: UUID(), locationID: nil, name: "Display", profile: "ios",
            origin: URL(string: "https://fixture.screenpunk.test")!, viewport: CGSize(width: 390, height: 844))
        try journal.saveOriginal(record)
        return (parent, journal, record)
    }
    func testInterruptedRetirementRecoversAndNeverExaminesLaterIntent() throws {
        let (parent, journal, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let retirement = NativeEnrollmentIntentRetirement(original: journal.directory), resetID = UUID()
        let digest = String(repeating: "a", count: 64)
        try journal.freezeWritesForReset {
            try retirement.capture(resetID: resetID, scopeDigest: digest, installationID: UUID(), expected: original, journal: journal)
        }
        var validations = 0
        XCTAssertThrowsError(try retirement.retire(resetID: resetID, scopeDigest: digest) {
            validations += 1
            if validations == 3 { throw CancellationError() } // Durable deleting marker and quarantine already exist.
        })
        XCTAssertEqual(try retirement.load()?.phase, .deleting)
        try retirement.retire(resetID: resetID, scopeDigest: digest, validateCompletion: {})
        XCTAssertEqual(try retirement.load()?.phase, .retired)
        let later = NativeEnrollmentIntentJournal(directory: journal.directory)
        try later.saveOriginal(original)
        let before = try Data(contentsOf: journal.directory.appendingPathComponent("original.json"))
        try retirement.retire(resetID: resetID, scopeDigest: digest) { XCTFail("Retired operation must never revalidate later state") }
        XCTAssertEqual(try Data(contentsOf: journal.directory.appendingPathComponent("original.json")), before)
        XCTAssertThrowsError(try journal.markRecordedInstallation(original)) // Captured old callback remains fenced.
        XCTAssertFalse(try XCTUnwrap(later.load()).restoreRecordedInstallation)
    }
    func testReplacementAndMissingSidecarFailClosed() throws {
        let (parent, journal, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let retirement = NativeEnrollmentIntentRetirement(original: journal.directory), resetID = UUID()
        let digest = String(repeating: "b", count: 64)
        try journal.freezeWritesForReset {
            try retirement.capture(resetID: resetID, scopeDigest: digest, installationID: UUID(), expected: original, journal: journal)
        }
        let old = parent.appendingPathComponent("preserved-original")
        try FileManager.default.moveItem(at: journal.directory, to: old)
        let replacement = NativeEnrollmentIntentJournal(directory: journal.directory)
        try replacement.saveOriginal(original)
        XCTAssertThrowsError(try retirement.retire(resetID: resetID, scopeDigest: digest, validateCompletion: {}))
        XCTAssertEqual(try replacement.load(), original)
        try FileManager.default.removeItem(at: retirement.file)
        XCTAssertThrowsError(try retirement.retire(resetID: resetID, scopeDigest: digest, validateCompletion: {}))
        XCTAssertEqual(try replacement.load(), original)
    }
    func testLateCapturedWriterCannotPublishAfterSnapshot() throws {
        let (parent, journal, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let captured = journal
        try journal.freezeWritesForReset {}
        XCTAssertThrowsError(try captured.markRecordedInstallation(original))
        XCTAssertFalse(try XCTUnwrap(journal.load()).restoreRecordedInstallation)
    }
}
