import Foundation
import ScreenpunkCore
#if os(macOS)
import Darwin

struct WorkbenchPreparedPackage {
    let sourceRevision: String
    let manifest: DashboardManifest
    let files: [String: Data]
}

/// Publishes target-specific bytes to visible immutable Prepared history
/// before a plan can name them. No portable history entry restores consent.
final class WorkbenchPreparedPackages {
    private struct Origin: Codable {
        let sourceRevision: String
        let dashboardId: String
        let preparedRevision: String
        let targetProfileHash: String
    }
    private let workspace: WorkspaceStore
    init(workspace: WorkspaceStore) { self.workspace = workspace }

    func prepare(source: WorkbenchPortablePackage, profile: DeviceProfile,
                 orientation: DeviceOrientation) throws -> WorkbenchPreparedPackage {
        try verify(manifest: source.manifest, files: source.files)
        guard let selected = try workspace.current() else { throw WorkbenchDeploymentError.staleContext }
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sp-m4-prep-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let sourceRecord = DashboardRevisionRecord(manifest: source.manifest, files: source.files,
            createdAt: Date(), packageDirectory: scratch)
        let prepared = try ScreenPackagePreparation.prepare(sourceRecord, for: profile,
            orientation: orientation, root: scratch)
        try verify(manifest: prepared.manifest, files: prepared.files)
        guard prepared.manifest.dashboardId == source.manifest.dashboardId,
              prepared.manifest.target.profileId == profile.deviceId,
              prepared.manifest.revision != source.manifest.revision else {
            throw WorkbenchDeploymentError.invalidPlan
        }
        let profileHash = try WorkbenchDeploymentHash.profile(profile)
        let origin = Origin(sourceRevision: source.manifest.revision,
            dashboardId: source.manifest.dashboardId,
            preparedRevision: prepared.manifest.revision, targetProfileHash: profileHash)
        let id = try objectId(dashboardId: prepared.manifest.dashboardId,
                              revision: prepared.manifest.revision)
        var payloads: [String: Data] = [
            "manifest.json": try JSONEncoder().encode(prepared.manifest),
            "origin.json": try JSONEncoder().encode(origin)
        ]
        for (path, bytes) in prepared.files { payloads["files/" + path] = bytes }
        guard payloads.count <= 2_002 else { throw WorkbenchDeploymentError.invalidPlan }
        var operations = payloads.keys.sorted(by: ToolchainCanonical.utf8Less).map { path -> WorkbenchTransactionOperation in
            let bytes = payloads[path]!
            return .init(target: .history("preparedPackage", id, path), before: .absent,
                         after: .present(bytes), recoveryBlobHash: WorkbenchTransactionDigest.hex(bytes))
        }
        var blobs: [String: Data] = [:]
        for bytes in payloads.values { blobs[WorkbenchTransactionDigest.hex(bytes)] = bytes }
        let root = try WorkspaceFiles(path: selected.path)
        try WorkbenchHistoryPublicationMetadata.append(to: &operations, blobs: &blobs,
            overview: selected, root: root)
        let journal = WorkbenchTransactionJournal(schemaVersion: 2,
            transactionId: UUID().uuidString.lowercased(), workspaceId: selected.descriptor.workspaceId,
            kind: .historyPublish, expectedGeneration: selected.descriptor.generation,
            operations: operations)
        let engine = WorkbenchTransactionEngine(selection: workspace.selection)
        try engine.prepare(journal, blobs: blobs)
        try engine.commit(journal.transactionId)
        return try get(dashboardId: prepared.manifest.dashboardId, revision: prepared.manifest.revision,
                       sourceRevision: source.manifest.revision, targetProfileHash: profileHash)
    }

    func get(dashboardId: String, revision: String, sourceRevision: String,
             targetProfileHash: String, readBudget suppliedBudget: WorkspaceReadBudget? = nil,
             maximumBytes: Int = PackageLimits.expandedBytes) throws -> WorkbenchPreparedPackage {
        let budget = suppliedBudget ?? WorkspaceReadBudget(
            deadline: ProcessInfo.processInfo.systemUptime + 15, cancelled: { false })
        try budget.check()
        guard WorkspaceValidation.id(dashboardId), WorkspaceValidation.id(revision),
              WorkspaceValidation.id(sourceRevision), WorkspaceValidation.sha256(targetProfileHash),
              let selected = try workspace.current(readBudget: budget) else { throw WorkbenchDeploymentError.invalidPlan }
        let root = try WorkspaceFiles(path: selected.path)
        let folder = try root.directory(["Workbench", "History", "Prepared",
            objectId(dashboardId: dashboardId, revision: revision)])
        defer { close(folder) }
        let manifestData = try root.read(folder, "manifest.json", maxBytes: 8 * 1024 * 1024, readBudget: budget)
        let originData = try root.read(folder, "origin.json", maxBytes: 16 * 1024, readBudget: budget)
        let manifest = try JSONDecoder().decode(DashboardManifest.self, from: manifestData)
        let origin = try JSONDecoder().decode(Origin.self, from: originData)
        try PackageValidator.validateInventoryBounds(manifest.files)
        try PackageValidator.validate(manifest)
        var declaredBytes = 0
        for item in manifest.files {
            guard item.bytes <= maximumBytes - declaredBytes else { throw WorkbenchDeploymentError.invalidPlan }
            declaredBytes += item.bytes
        }
        guard manifest.dashboardId == dashboardId, manifest.revision == revision,
              origin.dashboardId == dashboardId, origin.preparedRevision == revision,
              origin.sourceRevision == sourceRevision,
              origin.targetProfileHash == targetProfileHash else {
            throw WorkbenchDeploymentError.invalidPlan
        }
        var files: [String: Data] = [:]
        for item in manifest.files {
            try budget.check()
            guard WorkspaceValidation.member(item.path) else { throw WorkbenchDeploymentError.invalidPlan }
            let components = item.path.split(separator: "/").map(String.init)
            files[item.path] = try readFile(root: root,
                directory: ["Workbench", "History", "Prepared",
                    objectId(dashboardId: dashboardId, revision: revision), "files"] +
                    Array(components.dropLast()),
                name: components.last!, maxBytes: item.bytes, readBudget: budget)
            try budget.check()
        }
        try budget.check()
        try verify(manifest: manifest, files: files)
        return .init(sourceRevision: sourceRevision, manifest: manifest, files: files)
    }

    func freeze(_ prepared: WorkbenchPreparedPackage, deviceId: String,
                dataDescription: String) throws -> WorkbenchFrozenScreen {
        try verify(manifest: prepared.manifest, files: prepared.files)
        guard prepared.manifest.target.profileId == deviceId,
              let orientation = DeviceOrientation(rawValue: prepared.manifest.target.orientation),
              let digest = prepared.manifest.digest else { throw WorkbenchDeploymentError.invalidPlan }
        let revision = StoredRevision(revision: prepared.manifest.revision,
            dashboardId: prepared.manifest.dashboardId, name: prepared.manifest.name,
            digest: digest, orientation: orientation, width: prepared.manifest.target.width,
            height: prepared.manifest.target.height)
        var files = prepared.files.map { path, bytes in
            LANFileBlob(path: path, sha256: DeploymentDigest.sha256Hex(bytes),
                        dataBase64: bytes.base64EncodedString())
        }
        let manifestBytes = try JSONEncoder().encode(prepared.manifest)
        files.append(.init(path: "manifest.json", sha256: DeploymentDigest.sha256Hex(manifestBytes),
                           dataBase64: manifestBytes.base64EncodedString()))
        files.sort { ToolchainCanonical.utf8Less($0.path, $1.path) }
        let body = LANDeployBody(deployment: DeploymentRecord(deploymentId: "planned",
            revision: revision.revision, dashboardId: revision.dashboardId,
            deviceId: deviceId, phase: .queued), revision: revision, files: files)
        return .init(sourceRevision: prepared.sourceRevision, dataDescription: dataDescription,
                     item: .init(name: prepared.manifest.name, deployment: body))
    }

    private func objectId(dashboardId: String, revision: String) throws -> String {
        try ToolchainCanonical.hash(domain: "prepared-package-object", value: [
            "dashboardId": dashboardId, "revision": revision
        ])
    }
    private func readFile(root: WorkspaceFiles, directory: [String], name: String,
                          maxBytes: Int, readBudget: WorkspaceReadBudget) throws -> Data {
        try readBudget.check()
        let parent = try root.directory(directory)
        defer { close(parent) }
        return try root.read(parent, name, maxBytes: maxBytes, readBudget: readBudget)
    }
    private func verify(manifest: DashboardManifest, files: [String: Data]) throws {
        try PackageValidator.validate(manifest)
        guard manifest.files.count == files.count,
              manifest.digest == (try DeploymentDigest.digest(for: manifest)) else {
            throw WorkbenchDeploymentError.invalidPlan
        }
        for item in manifest.files {
            guard let bytes = files[item.path], bytes.count == item.bytes,
                  DeploymentDigest.sha256Hex(bytes) == item.sha256 else {
                throw WorkbenchDeploymentError.invalidPlan
            }
        }
    }
}
#endif
