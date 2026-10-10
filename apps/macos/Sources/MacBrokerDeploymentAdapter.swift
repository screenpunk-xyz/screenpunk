import Foundation
import ScreenpunkCore
import ScreenpunkController

/// The native Apply workflow's typed broker boundary. The caller must present
/// `WorkbenchDeploymentPresentation.render(review)` and obtain an explicit
/// human decision before calling `apply`. It must keep the idempotency key and
/// reconcile an uncertain outcome instead of creating a new Apply request.
struct MacBrokerDeploymentAdapter {
    struct PackageSelection {
        let dashboardId: String
        let sourceRevision: String
        let revision: String
        let dataDescription: String

        init(prepared: WorkbenchPreparedPackageSummary, dataDescription: String) {
            dashboardId = prepared.dashboardId
            sourceRevision = prepared.sourceRevision
            revision = prepared.revision
            self.dataDescription = dataDescription
        }

        var fields: [String: String] {
            ["dashboardId": dashboardId, "sourceRevision": sourceRevision,
             "revision": revision, "dataDescription": dataDescription]
        }
    }

    enum Error: Swift.Error { case noSelection, staleSelection, changedPlan, confirmationRequired }

    private let client: WorkbenchBrokerClient
    private let selected: WorkbenchWorkspaceStatus
    private let workspaceId: String
    private let selectionGeneration: Int

    init(client: WorkbenchBrokerClient, selected: WorkbenchWorkspaceStatus) throws {
        guard selected.state == "selected", let workspaceId = selected.workspaceId,
              let selectionGeneration = selected.selectionGeneration else { throw Error.noSelection }
        self.client = client
        self.selected = selected
        self.workspaceId = workspaceId
        self.selectionGeneration = selectionGeneration
    }

    private var common: [String: Any] {
        ["schemaVersion": 1, "expectedWorkspaceId": workspaceId,
         "expectedSelectionGeneration": selectionGeneration]
    }

    private func request(_ method: WorkbenchDeploymentMethod, _ fields: [String: Any],
                         willSubmit: () -> Void = {}) throws
        -> WorkbenchDeploymentActionResult {
        var params = common
        for (key, value) in fields { params[key] = value }
        willSubmit()
        return try client.performDeployment(method: method, params: params)
    }

    private func assertSelection() throws {
        let current = try client.workspaceStatus()
        guard MacBrokerReviewSelectionGate.matches(expectedId: workspaceId,
            expectedGeneration: selectionGeneration, state: current.state,
            currentId: current.workspaceId,
            currentGeneration: current.selectionGeneration) else { throw Error.staleSelection }
    }

    func revalidateForReview() throws { try assertSelection() }

    /// Only a current build head can prove source provenance with the existing
    /// broker routes. Imported or older history remains explicitly unavailable.
    func provenSourceRevision(for package: WorkbenchWorkspacePackageSummary) throws -> String {
        try assertSelection()
        let exact = try client.workspacePackage(dashboardId: package.dashboardId,
            revision: package.revision, in: selected)
        guard exact == package else { throw Error.changedPlan }
        let matching = try client.listProjects().filter { $0.dashboardId == package.dashboardId }
        guard matching.count == 1, let project = matching.first else {
            throw MacBrokerSourceProvenance.Failure.unproven
        }
        var params = common
        params["projectId"] = project.projectId
        let head = try client.performAuthoring(method: .buildHead, params: params).build
        try assertSelection()
        return try MacBrokerSourceProvenance.sourceRevision(
            for: .init(dashboardId: package.dashboardId, revision: package.revision,
                       digest: package.digest),
            project: .init(projectId: project.projectId, dashboardId: project.dashboardId),
            head: head.map { .init(projectId: $0.projectId, dashboardId: $0.dashboardId,
                                  sourceVersion: $0.sourceVersion, revision: $0.revision,
                                  digest: $0.digest) })
    }

    func prepareProvenPackage(_ package: WorkbenchWorkspacePackageSummary,
                              deviceId: String, orientation: DeviceOrientation)
        throws -> WorkbenchPreparedPackageSummary {
        let sourceRevision = try provenSourceRevision(for: package)
        return try prepare(deviceId: deviceId, dashboardId: package.dashboardId,
            sourceRevision: sourceRevision, orientation: orientation)
    }

    func prepare(deviceId: String, dashboardId: String, sourceRevision: String,
                 orientation: DeviceOrientation) throws -> WorkbenchPreparedPackageSummary {
        try assertSelection()
        guard let prepared = try request(.prepare,
            ["deviceId": deviceId, "dashboardId": dashboardId,
             "sourceRevision": sourceRevision, "orientation": orientation.rawValue]).prepared,
            prepared.dashboardId == dashboardId, prepared.sourceRevision == sourceRevision else {
            throw Error.changedPlan
        }
        return prepared
    }

    func freshDeviceScreenSet(deviceId: String) throws -> WorkbenchDeviceScreenSetRead {
        try assertSelection()
        let observed = try client.freshDeviceScreenSet(deviceId: deviceId)
        guard observed.deviceId == deviceId,
              observed.authority == "fresh-pinned-owned-screen-set-v1" else {
            throw Error.changedPlan
        }
        try assertSelection()
        return observed
    }

    /// The broker re-observes during plan creation. A change between this
    /// pinned read and that review rejects the GUI's displayed baseline.
    func planAgainstFreshDevice(deviceId: String, packages: [PackageSelection],
                                selectedDashboardId: String, bindingIds: [String],
                                lifetimeSeconds: Int64 = 3600)
        throws -> (WorkbenchDeploymentReview, WorkbenchDeviceScreenSetRead) {
        let observed = try freshDeviceScreenSet(deviceId: deviceId)
        let desired = Set(packages.map(\.dashboardId))
        let removals = observed.stateGenerationId == nil ? observed.screens.map(\.dashboardId).filter { !desired.contains($0) } : []
        let review = try plan(deviceId: deviceId, packages: packages,
            selectedDashboardId: selectedDashboardId, removedDashboardIds: removals,
            bindingIds: bindingIds, lifetimeSeconds: lifetimeSeconds)
        let afterPlan = try freshDeviceScreenSet(deviceId: deviceId)
        guard review.plan.expectedStateGenerationId == observed.stateGenerationId,
              afterPlan.stateGenerationId == observed.stateGenerationId,
              review.previouslyInstalled == observed.screens,
              review.previouslySelectedDashboardId == observed.selectedDashboardId,
              review.plan.deviceProfileHash == observed.deviceProfileHash,
              review.plan.expectedInstalledSetHash == observed.installedSetHash,
              Self.context(observed) == Self.context(afterPlan) else { throw Error.changedPlan }
        try assertSelection()
        return (review, observed)
    }

    private static func context(_ read: WorkbenchDeviceScreenSetRead)
        -> MacBrokerObservedContext<DeviceProfile, LANScreenSetEntry> {
        .init(deviceId: read.deviceId, name: read.name, profile: read.profile,
              screens: read.screens, selectedDashboardId: read.selectedDashboardId,
              authority: read.authority)
    }

    func plan(deviceId: String, packages: [PackageSelection], selectedDashboardId: String,
              removedDashboardIds: [String], bindingIds: [String], lifetimeSeconds: Int64 = 3600)
        throws -> WorkbenchDeploymentReview {
        try assertSelection()
        let orderedPackages = packages.sorted {
            $0.dashboardId.utf8.lexicographicallyPrecedes($1.dashboardId.utf8)
        }
        let orderedRemovals = removedDashboardIds.sorted {
            $0.utf8.lexicographicallyPrecedes($1.utf8)
        }
        let orderedBindings = bindingIds.sorted {
            $0.utf8.lexicographicallyPrecedes($1.utf8)
        }
        let review = try request(.plan,
            ["deviceId": deviceId, "packages": orderedPackages.map(\.fields),
             "selectedDashboardId": selectedDashboardId,
             "removedDashboardIds": orderedRemovals, "bindingIds": orderedBindings,
             "lifetimeSeconds": lifetimeSeconds]).review
        guard let review, review.plan.workspaceId == workspaceId,
              review.plan.deviceId == deviceId,
              review.plan.selectedDashboardId == selectedDashboardId,
              review.plan.removedDashboardIds == orderedRemovals,
              review.plan.packages.count == orderedPackages.count,
              zip(review.plan.packages, orderedPackages).allSatisfy({ actual, expected in
                  actual.dashboardId == expected.dashboardId &&
                  actual.sourceRevision == expected.sourceRevision &&
                  actual.revision == expected.revision &&
                  actual.dataDescription == expected.dataDescription
              }) else { throw Error.changedPlan }
        return review
    }

    /// A rollback always creates a fresh broker plan against a fresh installed
    /// set. The retained evidence supplies exact historical package identity;
    /// the broker must validate retained bytes and return the same digest.
    func rollbackPlan(deviceId: String,
        proposal: WorkbenchRetainedRollbackSelection,
        expectedObserved: WorkbenchDeviceScreenSetRead) throws -> WorkbenchDeploymentReview {
        let before = try freshDeviceScreenSet(deviceId: deviceId)
        guard Self.context(before) == Self.context(expectedObserved),
              before.deviceProfileHash == expectedObserved.deviceProfileHash,
              before.installedSetHash == expectedObserved.installedSetHash else {
            throw Error.changedPlan
        }
        let ordered = proposal.packages.sorted {
            $0.dashboardId.utf8.lexicographicallyPrecedes($1.dashboardId.utf8)
        }
        let packageFields: [[String: String]] = ordered.map { item in
            ["dashboardId": item.dashboardId,
             "sourceRevision": item.sourceRevision,
             "revision": item.revision,
             "dataDescription": item.dataDescription]
        }
        let fields: [String: Any] = [
            "deviceId": deviceId, "packages": packageFields,
            "selectedDashboardId": proposal.selectedDashboardId,
            "removedDashboardIds": proposal.removedDashboardIds,
            "bindingIds": [String](), "lifetimeSeconds": Int64(3600)]
        let review = try request(.rollbackPlan, fields).review
        let after = try freshDeviceScreenSet(deviceId: deviceId)
        let packagesMatch = review.map { value in
            value.plan.packages.count == ordered.count &&
                zip(value.plan.packages, ordered).allSatisfy { actual, expected in
                    actual.dashboardId == expected.dashboardId &&
                    actual.sourceRevision == expected.sourceRevision &&
                    actual.revision == expected.revision &&
                    actual.digest == expected.digest &&
                    actual.dataDescription == expected.dataDescription &&
                    (actual.declaredCapabilities.isEmpty ||
                     actual.declaredCapabilities == ["web-runtime"])
                }
        } ?? false
        guard let review, review.plan.workspaceId == workspaceId,
              review.plan.deviceId == deviceId,
              review.plan.deviceProfileHash == before.deviceProfileHash,
              review.plan.expectedInstalledSetHash == before.installedSetHash,
              review.previouslyInstalled == before.screens,
              review.previouslySelectedDashboardId == before.selectedDashboardId,
              review.plan.selectedDashboardId == proposal.selectedDashboardId,
              review.plan.removedDashboardIds == proposal.removedDashboardIds,
              packagesMatch,
              Self.context(after) == Self.context(before),
              after.deviceProfileHash == before.deviceProfileHash,
              after.installedSetHash == before.installedSetHash else {
            throw Error.changedPlan
        }
        try assertSelection()
        return review
    }

    func review(planId: String) throws -> WorkbenchDeploymentReview {
        try assertSelection()
        guard let review = try request(.review, ["planId": planId]).review,
              review.plan.workspaceId == workspaceId,
              review.plan.planId == planId else { throw Error.changedPlan }
        return review
    }

    /// GUI consent is valid only on the same socket holding a verified GUI
    /// lease. Renewal fails before Apply if that provenance is unavailable.
    func apply(_ displayed: WorkbenchDeploymentReview, idempotencyKey: String,
               explicitlyConfirmed: Bool, willSubmit: () -> Void) throws -> WorkbenchDeploymentOperationRecord {
        guard explicitlyConfirmed else { throw Error.confirmationRequired }
        try assertSelection()
        _ = try client.renewGUIConsumer()
        let current = try review(planId: displayed.plan.planId)
        guard current == displayed else { throw Error.changedPlan }
        guard let contextHash = displayed.authorizationContextHash else { throw Error.confirmationRequired }
        guard let operation = try request(.apply,
            ["planId": displayed.plan.planId, "expectedPlanHash": displayed.planHash,
             "expectedAuthorizationContextHash": contextHash,
             "idempotencyKey": idempotencyKey, "approved": true], willSubmit: willSubmit).operation,
            operation.planId == displayed.plan.planId,
            operation.planHash == displayed.planHash else { throw Error.changedPlan }
        return operation
    }

    func status(operationId: String) throws -> WorkbenchDeploymentOperationRecord {
        try assertSelection()
        guard let operation = try request(.status, ["operationId": operationId]).operation,
              operation.operationId == operationId else { throw Error.changedPlan }
        return operation
    }
}
