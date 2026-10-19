import Foundation
import ScreenpunkController

enum MacBrokerDeploymentReviewPresentation {
    enum Failure: Error { case unrenderable }

    static func render(_ review: WorkbenchDeploymentReview) throws -> String {
        let safe = BrokerConnectionReviewPresentation.escapeComplete
        let plan = review.plan
        var lines = [
            "Screenpunk exact-package Apply review",
            "Workspace: \(safe(plan.workspaceId))",
            "Device: \(safe(review.deviceName)) [\(safe(plan.deviceId))]",
            "Observed at: \(ISO8601DateFormatter().string(from: review.observedAt))",
            "Plan: \(safe(plan.planId))",
            "Plan hash: \(safe(review.planHash))",
            "Authorization context: \(safe(review.authorizationContextHash ?? "unavailable"))",
            "Device profile hash: \(safe(plan.deviceProfileHash))",
            "Expected installed-set hash: \(safe(plan.expectedInstalledSetHash))",
            "Required declarations hash: \(safe(plan.requiredDeclarationsHash))",
            "Approval policy: \(safe(plan.approvalPolicy))",
            "Expires: \(safe(plan.expiresAt))",
            "Selected screen: \(safe(plan.selectedDashboardId))",
            "Native render verification: \(safe(review.nativeRenderVerification))",
            "Previously installed (\(review.previouslyInstalled.count)):"
        ]
        for screen in review.previouslyInstalled {
            lines.append("  \(safe(screen.dashboardId)) · \(safe(screen.revision)) · \(safe(screen.name))")
        }
        lines.append("Removals (\(plan.removedDashboardIds.count)):")
        for id in plan.removedDashboardIds { lines.append("  \(safe(id))") }
        lines.append("Resulting full set (\(review.result.count)):")
        for screen in review.result {
            lines.append("  \(safe(screen.dashboardId)) · \(safe(screen.revision)) · \(safe(screen.name))")
        }
        lines.append("Exact packages (\(plan.packages.count)):")
        for item in plan.packages {
            lines.append("  Dashboard: \(safe(item.dashboardId))")
            lines.append("    Source: \(safe(item.sourceRevision))")
            lines.append("    Prepared revision: \(safe(item.revision))")
            lines.append("    Digest: \(safe(item.digest))")
            lines.append("    Declared capabilities: \(item.declaredCapabilities.map(safe).joined(separator: ", "))")
            lines.append("    Untrusted description: [\(safe(item.dataDescription))]")
        }
        lines.append("Transferred package bytes: \(review.packageBytes)")
        lines.append("Note: [\(safe(review.note))]")
        guard plan.packages.count <= 12, review.previouslyInstalled.count <= 12,
              review.result.count <= 12,
              lines.reduce(0, { $0 + $1.utf8.count }) <= 512 * 1024 else {
            throw Failure.unrenderable
        }
        return lines.joined(separator: "\n")
    }
}
