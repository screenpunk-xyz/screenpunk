import Foundation
#if os(macOS)

/// An authoring projection, never a compiler proof or a change to the remote source.
/// The record precedes local creation so retries retain the same per-client identity.
struct ControllerCloudCanonicalSourceStore {
    struct Record: Codable, Equatable {
        let schemaVersion: Int
        let localWorkspaceId: String
        let cloudWorkspaceId: String
        let cloudProjectId: String
        let localProjectId: String
        let dashboardId: String
        let name: String
        let sourceKind: String

        func validate() throws {
            guard schemaVersion == 1, sourceKind == "react",
                  [localWorkspaceId, cloudWorkspaceId, cloudProjectId, localProjectId, dashboardId].allSatisfy({ UUID(uuidString: $0) != nil }),
                  WorkspaceValidation.text(name), !name.isEmpty else { throw ControllerCloudError.invalidSource }
        }
        private func descriptor() throws -> Data {
            try validate()
            return try WorkspaceJSON.encode(WorkspaceProjectDocument(schemaVersion: 1,
                projectId: localProjectId, dashboardId: dashboardId, name: name, kind: "react",
                kitVersion: "builtin-react-1", entry: "src/main.tsx", screenConfig: "screen.json"))
        }
        private func validateCanonical(_ snapshot: ControllerCloudSourceSnapshot) throws {
            try validate(); try snapshot.validate()
            guard snapshot.files["screenpunk.project.json"] == nil,
                  snapshot.files["src/main.tsx"] != nil,
                  let config = snapshot.files["screen.json"],
                  (try? JSONSerialization.jsonObject(with: config)) is [String: Any] else {
                throw ControllerCloudError.invalidSource
            }
        }
        func localView(_ snapshot: ControllerCloudSourceSnapshot) throws -> ControllerCloudSourceSnapshot {
            try validateCanonical(snapshot)
            var files = snapshot.files; files["screenpunk.project.json"] = try descriptor()
            let local = ControllerCloudSourceSnapshot(revision: snapshot.revision, files: files)
            try local.validate(); return local
        }
        func canonicalView(_ snapshot: ControllerCloudSourceSnapshot) throws -> ControllerCloudSourceSnapshot {
            try validate(); try snapshot.validate()
            guard let bytes = snapshot.files["screenpunk.project.json"] else { throw ControllerCloudError.invalidSource }
            let descriptor = try WorkspaceJSON.decode(WorkspaceProjectDocument.self, from: bytes, shape: .project)
            // Display-name changes remain local. All source/build semantics must still match
            // the recorded projection; silently dropping descriptor edits would lose work.
            guard descriptor.schemaVersion == 1, descriptor.projectId == localProjectId,
                  descriptor.dashboardId == dashboardId, descriptor.kind == "react",
                  descriptor.kitVersion == "builtin-react-1", descriptor.entry == "src/main.tsx",
                  descriptor.screenConfig == "screen.json", WorkspaceValidation.text(descriptor.name) else {
                throw ControllerCloudError.conflict
            }
            var files = snapshot.files; files.removeValue(forKey: "screenpunk.project.json")
            let canonical = ControllerCloudSourceSnapshot(revision: snapshot.revision, files: files)
            try validateCanonical(canonical); return canonical
        }
    }
    let root: URL
    private func file(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw ControllerCloudError.invalidSource }
        return root.appendingPathComponent(id + ".json")
    }
    func read(_ id: String) throws -> Record? {
        let path = try file(id)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let bytes = try Data(contentsOf: path)
        guard bytes.count <= 8192 else { throw ControllerCloudError.invalidSource }
        let record = try JSONDecoder().decode(Record.self, from: bytes)
        try record.validate()
        guard record.localProjectId == id else { throw ControllerCloudError.conflict }
        return record
    }
    func prepare(_ record: Record, snapshot: ControllerCloudSourceSnapshot) throws -> ControllerCloudSourceSnapshot {
        let local = try record.localView(snapshot)
        if let old = try read(record.localProjectId) {
            guard old == record else { throw ControllerCloudError.conflict }
        } else {
            try ControllerCloudAutomaticSyncAuthorization.requireConsent()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try ControllerCloudPersistence.write(JSONEncoder().encode(record), to: file(record.localProjectId))
        }
        return local
    }
}
#endif
