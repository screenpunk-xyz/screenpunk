import Foundation
import ScreenpunkCore
import ScreenpunkController

/// Prepared on a verified GUI local-review socket and held open through the
/// person's review. A lost Apply response is not retried by this workflow.
final class MacBrokerApplyWorkflow: @unchecked Sendable {
    struct Request {
        let selected: WorkbenchWorkspaceStatus
        let deviceId: String
        let packages: [WorkbenchWorkspacePackageSummary]
        let selectedDashboardId: String
        let orientation: DeviceOrientation
        let bindingIds: [String]
    }
    enum Failure: LocalizedError {
        case staleSelection, noPackages, connectionReviewUnavailable
        var errorDescription: String? {
            switch self {
            case .staleSelection: "Workspace or device selection changed; refresh before Apply."
            case .noPackages: "Choose one to twelve distinct selected-workspace packages."
            case .connectionReviewUnavailable: "This package needs live connection review that the current Mac Apply provider cannot present."
            }
        }
    }

    let review: WorkbenchDeploymentReview
    let observed: WorkbenchDeviceScreenSetRead
    let idempotencyKey = UUID().uuidString.lowercased()
    private let session: MacBrokerApplySession

    private init(session: MacBrokerApplySession, review: WorkbenchDeploymentReview,
                 observed: WorkbenchDeviceScreenSetRead) {
        self.session = session; self.review = review; self.observed = observed
    }

    static func prepare(environment: WorkbenchBrokerEnvironment,
                        expectedControllerHome: String, request: Request) async throws
        -> MacBrokerApplyWorkflow {
        let session = try MacBrokerApplySession.open(environment: environment,
            expectedControllerHome: expectedControllerHome)
        do {
            guard session.selected.state == "selected",
                  session.selected.workspaceId == request.selected.workspaceId,
                  session.selected.selectionGeneration == request.selected.selectionGeneration else {
                throw Failure.staleSelection
            }
            guard (1...12).contains(request.packages.count),
                  Set(request.packages.map(\.dashboardId)).count == request.packages.count,
                  request.packages.contains(where: { $0.dashboardId == request.selectedDashboardId }) else {
                throw Failure.noPackages
            }
            // The current review DTO has a declarations hash but no complete
            // grant/binding scope for the native GUI to display. Keep this
            // adapter on packages without live connection grants until that
            // typed review contract exists.
            guard request.bindingIds.isEmpty else { throw Failure.connectionReviewUnavailable }
            // A fresh, owner-checked observation is the GUI's layout/removal
            // baseline. The plan route re-observes and the adapter compares it.
            let firstObservation = try session.adapter.freshDeviceScreenSet(
                deviceId: request.deviceId)
            let selectedPackages = try request.packages.map { package in
                let prepared = try session.adapter.prepareProvenPackage(package,
                    deviceId: request.deviceId, orientation: request.orientation)
                return MacBrokerDeploymentAdapter.PackageSelection(prepared: prepared,
                    dataDescription: "Selected workspace package: \(package.name)")
            }
            let (review, observed) = try session.adapter.planAgainstFreshDevice(
                deviceId: request.deviceId, packages: selectedPackages,
                selectedDashboardId: request.selectedDashboardId,
                bindingIds: request.bindingIds)
            guard review.plan.packages.allSatisfy({
                $0.declaredCapabilities.isEmpty ||
                    $0.declaredCapabilities == ["web-runtime"]
            }) else {
                throw Failure.connectionReviewUnavailable
            }
            guard observed.deviceId == firstObservation.deviceId,
                  observed.name == firstObservation.name,
                  observed.profile == firstObservation.profile,
                  observed.screens == firstObservation.screens,
                  observed.selectedDashboardId == firstObservation.selectedDashboardId,
                  observed.deviceProfileHash == firstObservation.deviceProfileHash,
                  observed.installedSetHash == firstObservation.installedSetHash,
                  observed.stateGenerationId == firstObservation.stateGenerationId,
                  observed.authority == firstObservation.authority else {
                throw Failure.staleSelection
            }
            try session.adapter.revalidateForReview()
            return MacBrokerApplyWorkflow(session: session, review: review, observed: observed)
        } catch {
            await session.close()
            throw error
        }
    }

    /// Previous-set rollback starts from one active receipted operation and
    /// the broker's machine-local retained evidence. Neither the local GUI
    /// journal nor portable workspace history supplies package authority.
    static func prepareRollback(environment: WorkbenchBrokerEnvironment,
        expectedControllerHome: String, selected: WorkbenchWorkspaceStatus,
        deviceId: String, prior: MacBrokerApplyJournal.Record) async throws
        -> MacBrokerApplyWorkflow {
        let session = try MacBrokerApplySession.open(environment: environment,
            expectedControllerHome: expectedControllerHome)
        do {
            guard session.selected.state == "selected",
                  session.selected.workspaceId == selected.workspaceId,
                  session.selected.selectionGeneration == selected.selectionGeneration,
                  prior.workspaceId == selected.workspaceId,
                  prior.selectionGeneration == selected.selectionGeneration,
                  prior.deviceId == deviceId, prior.phase == .active,
                  let operationId = prior.operationId else {
                throw Failure.staleSelection
            }
            let operation = try session.adapter.status(operationId: operationId)
            guard operation.state == .active, operation.receiptJSON != nil,
                  operation.planId == prior.planId,
                  operation.planHash == prior.planHash,
                  operation.idempotencyKey == prior.idempotencyKey else {
                throw Failure.staleSelection
            }
            let oldReview = try session.adapter.review(planId: prior.planId)
            guard oldReview.planHash == prior.planHash,
                  oldReview.plan.workspaceId == prior.workspaceId,
                  oldReview.plan.deviceId == deviceId,
                  oldReview.plan.packages.allSatisfy({
                      $0.declaredCapabilities.isEmpty ||
                          $0.declaredCapabilities == ["web-runtime"]
                  }) else {
                throw Failure.connectionReviewUnavailable
            }
            let observed = try session.adapter.freshDeviceScreenSet(deviceId: deviceId)
            guard observed.screens == oldReview.result,
                  observed.selectedDashboardId == oldReview.plan.selectedDashboardId,
                  observed.deviceProfileHash == oldReview.plan.deviceProfileHash else {
                throw Failure.staleSelection
            }
            let retained = try session.client.retainedDeploymentEvidence(
                workspaceId: prior.workspaceId,
                selectionGeneration: prior.selectionGeneration,
                deviceId: deviceId)
            let proposal = try WorkbenchRetainedRollbackSelection.resolve(read: retained,
                deviceProfileHash: observed.deviceProfileHash,
                previous: oldReview.previouslyInstalled,
                previouslySelectedDashboardId: oldReview.previouslySelectedDashboardId,
                current: observed.screens)
            let review = try session.adapter.rollbackPlan(deviceId: deviceId,
                proposal: proposal, expectedObserved: observed)
            try session.adapter.revalidateForReview()
            return MacBrokerApplyWorkflow(session: session, review: review,
                observed: observed)
        } catch {
            await session.close()
            throw error
        }
    }

    func reviewText() throws -> String {
        try MacBrokerDeploymentReviewPresentation.render(review)
    }

    func revalidateForReview() throws {
        try session.adapter.revalidateForReview()
        let current = try session.adapter.freshDeviceScreenSet(deviceId: observed.deviceId)
        guard current.deviceId == observed.deviceId, current.name == observed.name,
              current.profile == observed.profile, current.screens == observed.screens,
              current.selectedDashboardId == observed.selectedDashboardId,
              current.deviceProfileHash == observed.deviceProfileHash,
              current.installedSetHash == observed.installedSetHash,
              current.authority == observed.authority else { throw Failure.staleSelection }
        try session.adapter.revalidateForReview()
    }

    func applyAfterExplicitReview(willSubmit: () -> Void) throws -> WorkbenchDeploymentOperationRecord {
        try session.adapter.apply(review, idempotencyKey: idempotencyKey,
                                  explicitlyConfirmed: true, willSubmit: willSubmit)
    }

    func status(operationId: String) throws -> WorkbenchDeploymentOperationRecord {
        try session.adapter.status(operationId: operationId)
    }

    func close() async { await session.close() }
}
