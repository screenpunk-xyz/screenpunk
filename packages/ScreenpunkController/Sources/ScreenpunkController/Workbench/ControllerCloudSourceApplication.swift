import Foundation
#if os(macOS)

extension WorkbenchContainedAuthoring {
    /// Applies a bounded cloud journal in one existing source transaction, retaining local identity.
    func applyCloudSource(projectId: String, expectedSourceVersion: String, stagedPath: String) throws -> WorkbenchSourceProject {
        guard WorkspaceValidation.absolute(stagedPath), WorkspaceValidation.sha256(expectedSourceVersion) else { throw WorkspaceError.invalidPath }
        let staged = try WorkspaceFiles(path: stagedPath, requiredPrivateRoot: true)
        let snapshot = try JSONDecoder().decode(ControllerCloudSourceSnapshot.self, from: staged.read(staged.fd, "snapshot.json", maxBytes: 36 * 1024 * 1024))
        try snapshot.validate()
        let (overview, project, before) = try capture(projectId)
        guard try WorkbenchSourceHasher.hash(before) == expectedSourceVersion else { throw WorkspaceError.conflict }
        var after = snapshot.files
        // Source sync does not delete or upload locally held secrets, caches, or build outputs.
        for (path,bytes) in before where ControllerCloudSourcePolicy.excludes(path) { after[path] = bytes }
        guard let remoteDescriptor = after["screenpunk.project.json"],
              var shape = try JSONSerialization.jsonObject(with: remoteDescriptor) as? [String:Any] else { throw WorkspaceError.invalidSchema }
        shape["projectId"] = project.projectId; shape["dashboardId"] = project.dashboardId
        after["screenpunk.project.json"] = try JSONSerialization.data(withJSONObject: shape, options: [.sortedKeys])
        let descriptor = try WorkspaceJSON.decode(WorkspaceProjectDocument.self, from: after["screenpunk.project.json"]!, shape: .project)
        try descriptor.validate(matching: project)
        guard after[descriptor.entry] != nil, let config = after[descriptor.screenConfig],
              (try? JSONSerialization.jsonObject(with: config)) is [String:Any] else { throw WorkspaceError.invalidSchema }
        _ = try WorkbenchSourceHasher.hash(after)
        try staged.verifyRoot()
        try commitSource(project:project,before:before,after:after,expected:overview,register:false,root:WorkspaceFiles(path:overview.path))
        return try get(projectId)
    }
}
#endif
