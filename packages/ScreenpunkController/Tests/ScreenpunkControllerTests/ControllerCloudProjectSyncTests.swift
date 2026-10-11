import XCTest
@testable import ScreenpunkController
#if os(macOS)
private actor CloudLocalFixture: ControllerCloudProjectLocal {
    var snapshot: ControllerCloudSourceSnapshot
    var writes = 0
    init(_ snapshot: ControllerCloudSourceSnapshot) { self.snapshot = snapshot }
    func read(projectId: String) -> ControllerCloudSourceSnapshot { snapshot }
    func change(_ value: ControllerCloudSourceSnapshot) { snapshot = value }
    func replace(projectId: String, expectedRevision: String, snapshot: ControllerCloudSourceSnapshot) throws {
        guard self.snapshot.revision == expectedRevision else { throw ControllerCloudError.conflict }
        self.snapshot = snapshot; writes += 1
    }
}
private actor CloudRemoteFixture: ControllerCloudProjectRemote {
    var snapshot: ControllerCloudSourceSnapshot?
    var keys = [String:ControllerCloudSourceSnapshot]()
    var loseReply = false
    var writes = 0
    init(_ snapshot: ControllerCloudSourceSnapshot?) { self.snapshot = snapshot }
    func read(workspaceId: String, projectId: String) -> ControllerCloudSourceSnapshot? { snapshot }
    func change(_ value: ControllerCloudSourceSnapshot?) { snapshot = value }
    func loseNextReply() { loseReply = true }
    func write(workspaceId: String, projectId: String, baseRevision: String?, files: [String:Data], idempotencyKey: String) throws -> ControllerCloudSourceSnapshot {
        guard snapshot != nil else { throw ControllerCloudError.http(404) }
        if let result = keys[idempotencyKey] { return result }
        guard (snapshot?.revision.isEmpty == true ? nil : snapshot?.revision) == baseRevision else { throw ControllerCloudError.conflict }
        writes += 1; let result = ControllerCloudSourceSnapshot(revision: "remote-\(writes)", files: files)
        snapshot = result; keys[idempotencyKey] = result
        if loseReply { loseReply = false; throw ControllerCloudError.http(503) }
        return result
    }
}
final class ControllerCloudProjectSyncTests: XCTestCase {
    private func source(_ revision: String, _ text: String) -> ControllerCloudSourceSnapshot { .init(revision: revision, files: ["index.html":Data(text.utf8)]) }
    private func setup() throws -> (URL,CloudLocalFixture,CloudRemoteFixture,ControllerCloudProjectSync) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("controller-cloud-test-" + UUID().uuidString)
        let local = CloudLocalFixture(source("local0","zero")), remote = CloudRemoteFixture(source("remote0","zero"))
        return (root,local,remote,try ControllerCloudProjectSync(root:root,remote:remote,local:local))
    }
    private func linked(_ sync:ControllerCloudProjectSync) async throws {
        try await sync.link(accountId:"account",workspaceId:"workspace",localProjectId:"project",cloudProjectId:"remote")
        _ = try await sync.sync(accountId:"account",localProjectId:"project")
    }
    func testNewProjectLookupDoesNotTreatCorruptExistingBindingAsUnbound() async throws {
        let (root, _, _, sync) = try setup(); defer { try? FileManager.default.removeItem(at: root) }
        let absent = try await sync.statusIfPresent(localProjectId: "project")
        XCTAssertNil(absent)
        try await sync.link(accountId: "account", workspaceId: "workspace", localProjectId: "project", cloudProjectId: "remote")
        let existing = try await sync.statusIfPresent(localProjectId: "project")
        XCTAssertEqual(existing?.cloudProjectId, "remote")
        try Data("broken journal".utf8).write(to: root.appendingPathComponent("project.json"), options: .atomic)
        do { _ = try await sync.statusIfPresent(localProjectId: "project"); XCTFail("Corrupt binding must stop automatic creation") }
        catch is DecodingError { }
        catch { XCTFail("Expected corrupt binding diagnostic, got \(error)") }
    }
    func testCleanDownloadAndLocalUploadAreIndependent() async throws {
        let (root,local,remote,sync) = try setup(); defer { try? FileManager.default.removeItem(at:root) }
        try await linked(sync)
        await remote.change(source("remote1","incoming"))
        let downloaded = try await sync.sync(accountId:"account",localProjectId:"project")
        XCTAssertEqual(downloaded.status,.synced)
        let localValue = await local.read(projectId:"project"); XCTAssertEqual(localValue.files,source("x","incoming").files)
        await local.change(source("local2","outgoing"))
        _ = try await sync.sync(accountId:"account",localProjectId:"project")
        let remoteValue = await remote.read(workspaceId:"workspace",projectId:"remote"); XCTAssertEqual(remoteValue?.files,source("x","outgoing").files)
    }
    func testConflictPreservesLocalUntilExplicitResolution() async throws {
        let (root,local,remote,sync) = try setup(); defer { try? FileManager.default.removeItem(at:root) }
        try await linked(sync); await local.change(source("local1","mine")); await remote.change(source("remote1","theirs"))
        let conflicted = try await sync.sync(accountId:"account",localProjectId:"project"); XCTAssertEqual(conflicted.status,.conflict)
        let before = await local.read(projectId:"project"); XCTAssertEqual(before.files,source("x","mine").files)
        _ = try await sync.resolve(accountId:"account",localProjectId:"project",choice:.remote)
        let after = await local.read(projectId:"project"); XCTAssertEqual(after.files,source("x","theirs").files)
    }
    func testReviewedConflictRejectsNewRemoteHead() async throws {
        let (root,local,remote,sync) = try setup(); defer { try? FileManager.default.removeItem(at:root) }
        try await linked(sync); await local.change(source("local1","mine")); await remote.change(source("remote1","theirs"))
        _ = try await sync.sync(accountId:"account",localProjectId:"project"); await remote.change(source("remote2","newer"))
        do { _ = try await sync.resolve(accountId:"account",localProjectId:"project",choice:.local); XCTFail("stale review accepted") } catch { XCTAssertEqual(error as? ControllerCloudError,.conflict) }
    }
    func testLostUploadReplyRestartsWithSameIdempotencyIdentity() async throws {
        let (root,local,remote,sync) = try setup(); defer { try? FileManager.default.removeItem(at:root) }
        try await linked(sync); await local.change(source("local1","mine")); await remote.loseNextReply()
        do { _ = try await sync.sync(accountId:"account",localProjectId:"project"); XCTFail("lost reply") } catch {}
        let resumed = try ControllerCloudProjectSync(root:root,remote:remote,local:local)
        let result = try await resumed.sync(accountId:"account",localProjectId:"project"); XCTAssertEqual(result.status,.synced)
        let writes = await remote.writes; XCTAssertEqual(writes,1)
    }
    func testPendingUploadDeletionPreservesBothDraftsAndNeverRecreates() async throws {
        let (root, local, remote, sync) = try setup(); defer { try? FileManager.default.removeItem(at: root) }
        try await linked(sync)
        await local.change(source("local1", "pending")); await remote.loseNextReply()
        do { _ = try await sync.sync(accountId: "account", localProjectId: "project"); XCTFail("lost reply") } catch {}
        await local.change(source("local2", "latest")); await remote.change(nil)
        let restarted = try ControllerCloudProjectSync(root: root, remote: remote, local: local)
        let result = try await restarted.sync(accountId: "account", localProjectId: "project")
        XCTAssertEqual(result.status, .deleted)
        do { _ = try await restarted.sync(accountId: "account", localProjectId: "project"); XCTFail("recreated") }
        catch { XCTAssertEqual(error as? ControllerCloudError, .deletedProject) }
        try await restarted.unlink(localProjectId: "project")
        let draftPath = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.pathExtension == "draft" })
        struct Draft: Decodable { let pendingUpload: ControllerCloudSourceSnapshot?; let conflictLocal: ControllerCloudSourceSnapshot? }
        let draft = try JSONDecoder().decode(Draft.self, from: Data(contentsOf: draftPath))
        XCTAssertEqual(draft.pendingUpload?.files, source("x", "pending").files)
        XCTAssertEqual(draft.conflictLocal?.files, source("x", "latest").files)
        let writes = await remote.writes; XCTAssertEqual(writes, 1)
        let localCurrent = await local.read(projectId: "project"); XCTAssertEqual(localCurrent.revision, "local2")
    }
    func testDeletionNeverRecreatesAndAccountSwitchNeverRetargets() async throws {
        let (root,local,remote,sync) = try setup(); defer { try? FileManager.default.removeItem(at:root) }
        try await linked(sync); await local.change(source("local1","mine"))
        do { _ = try await sync.sync(accountId:"other",localProjectId:"project"); XCTFail("account retarget") } catch { XCTAssertEqual(error as? ControllerCloudError,.accountMismatch) }
        await remote.change(nil); let deleted = try await sync.sync(accountId:"account",localProjectId:"project"); XCTAssertEqual(deleted.status,.deleted)
        let writes = await remote.writes; XCTAssertEqual(writes,0)
        try await sync.unlink(localProjectId:"project")
        let retained = try FileManager.default.contentsOfDirectory(atPath:root.path); XCTAssertEqual(retained.filter {$0.hasSuffix(".draft")}.count,1)
    }
    func testNewEmptyCloudProjectUploadsWithoutConflict() async throws {
        let (root,_,remote,sync) = try setup(); defer { try? FileManager.default.removeItem(at:root) }
        await remote.change(.init(revision:"",files:[:]))
        try await sync.link(accountId:"account",workspaceId:"workspace",localProjectId:"project",cloudProjectId:"remote")
        let result = try await sync.sync(accountId:"account",localProjectId:"project")
        XCTAssertEqual(result.status,.synced)
        let writes = await remote.writes; XCTAssertEqual(writes,1)
    }
    func testEditsDuringPendingUploadRemainUnsynced() async throws {
        let (root,local,remote,sync) = try setup(); defer { try? FileManager.default.removeItem(at:root) }
        try await linked(sync); await local.change(source("local1","first")); await remote.loseNextReply()
        do { _ = try await sync.sync(accountId:"account",localProjectId:"project"); XCTFail("lost reply") } catch {}
        await local.change(source("local2","second"))
        let restarted = try ControllerCloudProjectSync(root:root,remote:remote,local:local)
        let pending = try await restarted.sync(accountId:"account",localProjectId:"project"); XCTAssertEqual(pending.status,.linked)
        let synced = try await restarted.sync(accountId:"account",localProjectId:"project"); XCTAssertEqual(synced.status,.synced)
        let head = await remote.read(workspaceId:"workspace",projectId:"remote"); XCTAssertEqual(head?.files,source("x","second").files)
    }
    func testLargeSourceFailsExplicitlyWithoutTruncation() throws {
        let files = Dictionary(uniqueKeysWithValues:(0..<2_001).map { ("assets/\($0).txt",Data()) })
        do { try ControllerCloudSourceSnapshot(revision:"v",files:files).validate(); XCTFail("source silently truncated") }
        catch { XCTAssertEqual(error as? ControllerCloudError,.sourceLimitExceeded) }
        let large = ControllerCloudSourceSnapshot(revision:"v",files:["asset.bin":Data(repeating:0,count:5*1024*1024+1)])
        XCTAssertThrowsError(try large.validate()) { XCTAssertEqual($0 as? ControllerCloudError,.sourceLimitExceeded) }
    }
    func testSourceRejectsCredentialAndTraversalPaths() throws {
        for path in ["../secret",".env","credentials.json","key.pem","node_modules/key"] {
            XCTAssertThrowsError(try ControllerCloudSourceSnapshot(revision:"v",files:[path:Data()]).validate())
        }
    }
}
#endif
