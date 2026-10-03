import Foundation
import ScreenpunkCore
#if os(macOS)

public struct WorkbenchDeploymentPackage: Codable, Equatable {
    public let dashboardId: String
    public let sourceRevision: String
    public let revision: String
    public let digest: String
    public let declaredCapabilities: [String]
    public let dataDescription: String
}

struct WorkbenchPreparedSelection {
    let dashboardId: String
    let sourceRevision: String
    let revision: String
    let dataDescription: String
}

public struct WorkbenchDeploymentPlanBody: Codable, Equatable {
    public let planVersion: Int
    public let planId: String
    public let workspaceId: String
    public let deviceId: String
    public let deviceProfileHash: String
    public let expectedInstalledSetHash: String
    public let packages: [WorkbenchDeploymentPackage]
    public let selectedDashboardId: String
    public let removedDashboardIds: [String]
    public let requiredDeclarationsHash: String
    public let approvalPolicy: String
    public let expiresAt: String
}

public struct WorkbenchDeploymentReview: Codable, Equatable {
    public let plan: WorkbenchDeploymentPlanBody
    public let planHash: String
    public let authorizationContextHash: String?
    public let deviceName: String
    public let observedAt: Date
    public let previouslyInstalled: [LANScreenSetEntry]
    public let previouslySelectedDashboardId: String?
    public let result: [LANScreenSetEntry]
    public let packageBytes: Int
    public let note: String
    public let nativeRenderVerification: String
    public var grantScopes: [WorkbenchConnectionSummary]? = nil
    public var missingGrants: [String]? = nil
}

public enum WorkbenchDeploymentPresentation {
    /// Terminal/GUI display only. The plan hash always covers the original
    /// descriptive bytes, never this escaped rendering.
    static func escape(_ value: String, limit: Int = 4096) -> String {
        var output = ""
        var count = 0
        for scalar in value.unicodeScalars {
            if count >= limit { output += "… [truncated]"; break }
            count += 1
            let code = scalar.value
            if CharacterSet.controlCharacters.contains(scalar) ||
               (0x202A...0x202E).contains(code) || (0x2066...0x2069).contains(code) ||
               code == 0x200E || code == 0x200F {
                output += "\\u{" + String(code, radix: 16, uppercase: true) + "}"
            } else { output.unicodeScalars.append(scalar) }
        }
        return output
    }

    public static func render(_ review: WorkbenchDeploymentReview) -> String {
        var lines = [
            "Workspace: \(escape(review.plan.workspaceId))",
            "Target: \(escape(review.deviceName)) [\(escape(review.plan.deviceId))]",
            "Observed at: \(ISO8601DateFormatter().string(from: review.observedAt))",
            "Plan: \(review.plan.planId) hash \(review.planHash)",
            "Device profile hash: \(review.plan.deviceProfileHash)",
            "Observed installed-set hash: \(review.plan.expectedInstalledSetHash)",
            "Previously selected screen: \(escape(review.previouslySelectedDashboardId ?? "none"))",
            "Authorization context: \(review.authorizationContextHash ?? "awaiting grants")",
            "Selected screen: \(escape(review.plan.selectedDashboardId))",
            "Removals: \(review.plan.removedDashboardIds.isEmpty ? "none" : review.plan.removedDashboardIds.map { escape($0) }.joined(separator: ", "))"
        ]
        lines.append("Previously installed:")
        for screen in review.previouslyInstalled {
            lines.append("  \(escape(screen.dashboardId)) revision \(escape(screen.revision)) name \(escape(screen.name))")
        }
        if review.previouslyInstalled.isEmpty { lines.append("  none") }
        lines.append("Resulting full set:")
        for screen in review.result {
            lines.append("  \(escape(screen.dashboardId)) revision \(escape(screen.revision)) name \(escape(screen.name))")
        }
        for package in review.plan.packages {
            lines.append("Package: \(escape(package.dashboardId)) source \(escape(package.sourceRevision)) prepared \(escape(package.revision)) digest \(package.digest)")
            lines.append("Declared capabilities: \(package.declaredCapabilities.isEmpty ? "none" : package.declaredCapabilities.map { escape($0) }.joined(separator: ", "))")
            lines.append("Untrusted informational text: \(escape(package.dataDescription))")
        }
        if let missing = review.missingGrants, !missing.isEmpty {
            lines.append("Awaiting current grants:")
            for value in missing { lines.append("  \(escape(value))") }
            lines.append("Configure the required grants, then create and review a fresh plan.")
        }
        if let scopes = review.grantScopes, !scopes.isEmpty {
            lines.append("Current physical grant scope:")
            for scope in scopes {
                lines.append("  \(escape(scope.alias)) [\(escape(scope.bindingId))] \(escape(scope.origin)) \(escape(scope.authenticationPlacement))")
                for operation in scope.operations {
                    lines.append("    \(escape(operation.name)) \(escape(operation.method)) \(escape(operation.address)) write=\(operation.writes)")
                }
            }
        }
        lines.append("Transferred package bytes: \(review.packageBytes); per-file installed delta: unknown")
        lines.append(escape(review.note))
        return lines.joined(separator: "\n")
    }
}

enum WorkbenchDeploymentHash {
    static func plan(_ value: WorkbenchDeploymentPlanBody) throws -> String {
        guard value.planVersion == 1, value.approvalPolicy == "exact-package-installation-v1",
              !value.packages.isEmpty, value.packages.count <= 12,
              value.packages.map(\.dashboardId) == value.packages.map(\.dashboardId).sorted(by: ToolchainCanonical.utf8Less),
              Set(value.packages.map(\.dashboardId)).count == value.packages.count,
              value.removedDashboardIds == value.removedDashboardIds.sorted(by: ToolchainCanonical.utf8Less),
              Set(value.removedDashboardIds).count == value.removedDashboardIds.count,
              value.packages.contains(where: { $0.dashboardId == value.selectedDashboardId }),
              value.packages.allSatisfy({ $0.declaredCapabilities == $0.declaredCapabilities.sorted(by: ToolchainCanonical.utf8Less) &&
                  Set($0.declaredCapabilities).count == $0.declaredCapabilities.count }) else {
            throw WorkbenchDeploymentError.invalidPlan
        }
        let encoded = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: encoded)
        return try ToolchainCanonical.hash(domain: "plan", value: object)
    }
    static func operationBody(planHash: String, contextHash: String) throws -> String {
        guard WorkspaceValidation.sha256(planHash), WorkspaceValidation.sha256(contextHash) else {
            throw WorkbenchDeploymentError.invalidPlan
        }
        return try ToolchainCanonical.hash(domain: "operation-body", value: [
            "bodyVersion": 1, "planHash": planHash, "authorizationContextHash": contextHash
        ])
    }
    static func installedSet(_ entries: [LANScreenSetEntry], selected: String?) throws -> String {
        let records: [[String: String]] = entries.sorted { ToolchainCanonical.utf8Less($0.dashboardId, $1.dashboardId) }
            .map { ["dashboardId": $0.dashboardId, "revision": $0.revision, "name": $0.name] }
        return try ToolchainCanonical.hash(domain: "installed-screen-set", value: [
            "screens": records, "selectedDashboardId": selected ?? ""
        ])
    }
    static func profile(_ profile: DeviceProfile) throws -> String {
        try ToolchainCanonical.hash(domain: "device-profile", value:
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)))
    }
}
#endif
