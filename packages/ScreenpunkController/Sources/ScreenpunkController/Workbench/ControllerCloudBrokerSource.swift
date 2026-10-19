import Foundation
#if os(macOS)
/// All reads and mutations go through the existing broker and its source CAS journal.
public actor ControllerCloudBrokerSource: ControllerCloudProjectLocal {
    private let client: WorkbenchBrokerClient
    private let scratchRoot: URL
    public init(client: WorkbenchBrokerClient, scratchRoot: URL) throws {
        self.client = client; self.scratchRoot = scratchRoot
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    public func read(projectId: String) async throws -> ControllerCloudSourceSnapshot {
        let selection = try client.workspaceStatus()
        guard let workspaceId = selection.workspaceId, let generation = selection.selectionGeneration else { throw ControllerCloudError.invalidSource }
        let bound: [String:Any] = ["schemaVersion":1,"expectedWorkspaceId":workspaceId,"expectedSelectionGeneration":generation]
        let inspect = try client.performAuthoring(method: .projectInspect, params: bound.merging(["projectId":projectId]) { _, value in value })
        guard let project = inspect.project else { throw ControllerCloudError.invalidResponse }
        // Export uses a stable owned root, with one exact disposable directory per capture.
        let destination = scratchRoot.appendingPathComponent("capture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let result = try client.performAuthoring(method: .projectSourceExport, params: bound.merging(["projectId":projectId, "sourceVersion":project.sourceVersion, "path":destination.path]) { _, value in value })
        guard let receipt = result.sourceArchive, receipt.sourceVersion == project.sourceVersion,
              receipt.archivePath == destination.path else { throw ControllerCloudError.invalidResponse }
        let manifest = try JSONDecoder().decode(WorkbenchPortableSourceArchiveManifest.self, from: Data(contentsOf: destination.appendingPathComponent("source-archive.json")))
        guard manifest.sourceVersion == project.sourceVersion else { throw ControllerCloudError.invalidResponse }
        var files: [String:Data] = [:]
        for member in manifest.files {
            guard WorkspaceValidation.member(member.path) else { throw ControllerCloudError.invalidSource }
            let data = try Data(contentsOf: destination.appendingPathComponent("source").appendingPathComponent(member.path))
            guard data.count == member.bytes, WorkbenchTransactionDigest.hex(data) == member.sha256 else { throw ControllerCloudError.invalidSource }
            files[member.path] = data
        }
        guard try WorkbenchSourceHasher.hash(files) == project.sourceVersion else { throw ControllerCloudError.invalidSource }
        files = files.filter { !ControllerCloudSourcePolicy.excludes($0.key) }
        // Normalize only identity fields; retain entry/config/toolchain/build metadata in cloud.
        if let descriptor = files["screenpunk.project.json"], var shape = try JSONSerialization.jsonObject(with: descriptor) as? [String:Any] {
            shape.removeValue(forKey: "projectId"); shape.removeValue(forKey: "dashboardId")
            files["screenpunk.project.json"] = try JSONSerialization.data(withJSONObject: shape, options: [.sortedKeys])
        }
        let snapshot = ControllerCloudSourceSnapshot(revision: project.sourceVersion, files: files)
        try snapshot.validate()
        return snapshot
    }
    public func replace(projectId: String, expectedRevision: String, snapshot: ControllerCloudSourceSnapshot) async throws {
        try snapshot.validate()
        let current = try await read(projectId: projectId)
        guard current.revision == expectedRevision else { throw ControllerCloudError.conflict }
        let staging = scratchRoot.appendingPathComponent("apply-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        try JSONEncoder().encode(snapshot).write(to: staging.appendingPathComponent("snapshot.json"), options:.atomic)
        let selection = try client.workspaceStatus()
        guard let workspaceId = selection.workspaceId, let generation = selection.selectionGeneration else { throw ControllerCloudError.invalidSource }
        _ = try client.performAuthoring(method:.projectSyncSource, params:["schemaVersion":1,"expectedWorkspaceId":workspaceId,"expectedSelectionGeneration":generation,"projectId":projectId,"expectedSourceVersion":expectedRevision,"path":staging.path])
    }
}
#endif
