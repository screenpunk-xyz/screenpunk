import Foundation
import ScreenpunkCore
#if os(macOS)

struct WorkbenchDeploymentGrantRequirement {
    let dashboardId: String
    let revision: String
    let sourceRevision: String
    let manifest: DashboardManifest
}

struct WorkbenchDeploymentGrantAssessment {
    let scopes: [WorkbenchConnectionSummary]
    let missing: [String]
    var ready: Bool { missing.isEmpty }
    static let noDeclarations = Self(scopes: [], missing: [])
}

#endif
