import Foundation
import ScreenpunkCore

extension ControllerService {
    private func publicApprovalURL(_ manifest: DashboardManifest) throws -> URL {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let content = try encoder.encode(PublicReadProvisioning(manifest: manifest))
        return store.root.appendingPathComponent("public-read-approvals").appendingPathComponent(PeerPin.hex(PeerPin.sha256(content)) + ".json")
    }
    public func approvePublicConnections(dashboardId: String, revision: String, approved: Bool, aliases: [String]? = nil) throws -> PublicReadProvisioning {
        guard approved else { throw ControllerError.permissionRequired("Review the exact revision's HTTPS origins, paths and parameter bounds with the owner before approved=true.") }
        let manifest = try getDashboard(dashboardId: dashboardId, revision: revision).manifest
        try PackageValidator.validate(manifest)
        var provisioning = try PublicReadProvisioning(manifest: manifest)
        if let aliases {
            guard !aliases.isEmpty, Set(aliases).isSubset(of: Set(provisioning.connections.map(\.alias))) else { throw ConnectionFailure.validationFailed }
            let previous = (try? approvedPublicConnections(manifest))?.connections.map(\.alias) ?? []
            let selected = Set(aliases + previous)
            provisioning.connections = provisioning.connections.filter { selected.contains($0.alias) }
        }
        let url = try publicApprovalURL(manifest)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(provisioning).write(to: url, options: .atomic)
        return provisioning
    }
    /// Carries approval only across the controller's device-sizing transformation.
    /// Callers cannot supply an arbitrary prepared package or substitute source bytes.
    public func prepareDashboardForDevice(dashboardId: String, revision: String,
                                          device: DeviceProfile, orientation: DeviceOrientation) throws -> DashboardRevisionRecord {
        let source = try getDashboard(dashboardId: dashboardId, revision: revision)
        guard source.manifest.dashboardId == dashboardId, source.manifest.revision == revision else {
            throw ControllerError.permissionRequired("Saved screen identity does not match the requested revision.")
        }
        let approval = try approvedPublicConnections(source.manifest)
        let prepared = try ScreenPackagePreparation.prepare(source, for: device, orientation: orientation, root: store.root)
        // Only target geometry, generated revision and its digest may change.
        var normalized = prepared.manifest
        normalized.target = source.manifest.target
        normalized.revision = source.manifest.revision
        normalized.digest = source.manifest.digest
        guard normalized == source.manifest, prepared.files == source.files else {
            throw ControllerError.permissionRequired("Prepared screen content or declarations changed. Review and approve the new source revision before applying.")
        }
        if var approval {
            approval.revision = prepared.manifest.revision
            try approval.validate()
            let url = try publicApprovalURL(prepared.manifest)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(approval).write(to: url, options: .atomic)
        }
        return prepared
    }
    public func approvedPublicConnections(_ manifest: DashboardManifest) throws -> PublicReadProvisioning? {
        let expected = try PublicReadProvisioning(manifest: manifest)
        guard !expected.connections.isEmpty else { return nil }
        let url = try publicApprovalURL(manifest)
        guard let data = try? Data(contentsOf: url), let approved = try? JSONDecoder().decode(PublicReadProvisioning.self, from: data), approved.dashboardId == expected.dashboardId, approved.revision == expected.revision,
              approved.connections.allSatisfy({ expected.connections.contains($0) }) else {
            throw ControllerError.permissionRequired("Approve public HTTPS declarations for revision \(manifest.revision) using approve_public_connections or the Mac preview approval control.")
        }
        return approved
    }
    public func inspectPublicConnections(dashboardId: String, revision: String?) throws -> Data {
        let manifest = try getDashboard(dashboardId: dashboardId, revision: revision).manifest
        let declaration = try PublicReadProvisioning(manifest: manifest)
        return try JSONSerialization.data(withJSONObject: ["dashboardId": manifest.dashboardId, "revision": manifest.revision,
            "approved": (try? approvedPublicConnections(manifest)) == declaration,
            "approvedAliases": (try? approvedPublicConnections(manifest))?.connections.map(\.alias) ?? [],
            "provisioning": JSONSerialization.jsonObject(with: JSONEncoder().encode(declaration))])
    }
}
