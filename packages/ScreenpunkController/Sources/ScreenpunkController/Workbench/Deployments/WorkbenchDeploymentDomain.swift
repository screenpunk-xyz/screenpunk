import Foundation
import ScreenpunkCore
#if os(macOS)

struct WorkbenchFrozenScreen: Codable, Equatable {
    let sourceRevision: String
    let dataDescription: String
    let item: LANScreenSetItem
}

struct WorkbenchDeploymentMaterial: Codable, Equatable {
    let screens: [WorkbenchFrozenScreen]
    let selectedDashboardId: String
    let bindingIds: [String]
}

struct WorkbenchDeploymentObservation {
    let deviceId: String
    let name: String
    let profile: DeviceProfile
    let screens: [LANScreenSetEntry]
    let selectedDashboardId: String?
    let observedAt: Date
}

/// The eventual native adapter must use the current paired owner channel and
/// must not replay deployScreenSet after an ambiguous cached-link error.
protocol WorkbenchDeploymentPeer {
    func observe(deviceId: String) throws -> WorkbenchDeploymentObservation
    func send(_ body: LANScreenSetDeployBody) throws -> LANScreenSetReceipt
    func send(_ body: LANScreenSetDeployBody, preSend: () throws -> Void) throws -> LANScreenSetReceipt
}
extension WorkbenchDeploymentPeer {
    func send(_ body: LANScreenSetDeployBody, preSend: () throws -> Void) throws -> LANScreenSetReceipt {
        try preSend()
        return try send(body)
    }
}

struct WorkbenchDeploymentPreSendFailure: Error {}

/// Constructed only inside this module by a trusted terminal/GUI host or by
/// the additive MCP route's explicit agent assertion. A caller JSON field is
/// never accepted as consent source or local role.
struct WorkbenchDeploymentConsent {
    let source: String
    private init(_ source: String) { self.source = source }
    static func terminal() -> Self { .init("terminal_interactive") }
    static func terminalAssertion() -> Self { .init("terminal_asserted") }
    static func gui() -> Self { .init("gui_interactive") }
    static func agentAssertion() -> Self { .init("agent_asserted") }
}

/// Exact-package core with a deliberately internal construction surface. The
/// broker must wire its single native peer, prepared-package source and shared
/// M3 mutation boundary before any CLI/MCP/GUI route may expose dispatch.
final class WorkbenchDeploymentDomain {
    private let ledger: WorkbenchDeploymentLedger
    private let peer: any WorkbenchDeploymentPeer
    private let boundary: WorkbenchAuthorityBoundary
    private let currentContext: (String, [String]) throws -> String
    private let clock: () -> WorkbenchDeploymentClock
    private let dispatchEnabled: Bool
    private let grantAssessor: (String, [WorkbenchDeploymentGrantRequirement], [String]) throws -> WorkbenchDeploymentGrantAssessment
    private let grantInstaller: (String, WorkbenchDeploymentGrantRequirement, [String]) throws -> Void
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(ledgerPath: String, peer: any WorkbenchDeploymentPeer, boundary: WorkbenchAuthorityBoundary,
         currentContext: @escaping (String, [String]) throws -> String,
         clock: @escaping () -> WorkbenchDeploymentClock, dispatchEnabled: Bool = false,
         grantAssessor: @escaping (String, [WorkbenchDeploymentGrantRequirement], [String]) throws -> WorkbenchDeploymentGrantAssessment = { _, requirements, _ in
             .init(scopes: [], missing: requirements.flatMap { item in
                 item.manifest.connections.map { item.dashboardId + "/" + $0.alias }
             })
         },
         grantInstaller: @escaping (String, WorkbenchDeploymentGrantRequirement, [String]) throws -> Void = { _, _, _ in
             throw WorkbenchDeploymentError.unsupportedIntegration
         }) throws {
        ledger = try WorkbenchDeploymentLedger(path: ledgerPath)
        self.peer = peer; self.boundary = boundary; self.currentContext = currentContext
        self.clock = clock; self.dispatchEnabled = dispatchEnabled
        self.grantAssessor = grantAssessor; self.grantInstaller = grantInstaller
    }

    convenience init(ledgerPath: String, peer: any WorkbenchDeploymentPeer,
                     connections: WorkbenchConnectionDomain,
                     clock: @escaping () -> WorkbenchDeploymentClock,
                     dispatchEnabled: Bool = false) throws {
        try self.init(ledgerPath: ledgerPath, peer: peer, boundary: connections.authorityBoundary,
            currentContext: { deviceId, bindingIds in
                try connections.authorizationContextHash(deviceId: deviceId, bindingIds: bindingIds)
            }, clock: clock, dispatchEnabled: dispatchEnabled,
            grantAssessor: { deviceId, requirements, bindingIds in
                try connections.deploymentGrants(deviceId: deviceId,
                    requirements: requirements, bindingIds: bindingIds)
            }, grantInstaller: { deviceId, selected, bindingIds in
                try connections.installDeploymentGrants(deviceId: deviceId,
                    selected: selected, bindingIds: bindingIds)
            })
    }

    func observe(deviceId: String) throws -> WorkbenchDeploymentObservation {
        try peer.observe(deviceId: deviceId)
    }

    func prepareFromHistory(workspaceId: String, deviceId: String,
                            preparedStore: WorkbenchPreparedPackages,
                            packages: [WorkbenchPreparedSelection], selectedDashboardId: String,
                            removedDashboardIds: [String], bindingIds: [String],
                            lifetimeSeconds: Int64 = 3600,
                            readBudget suppliedBudget: WorkspaceReadBudget? = nil) throws -> WorkbenchDeploymentReview {
        let budget = suppliedBudget ?? WorkspaceReadBudget(
            deadline: ProcessInfo.processInfo.systemUptime + 15, cancelled: { false })
        return try boundary.withDevice(deviceId) {
            try budget.check()
            guard (1...12).contains(packages.count) else { throw WorkbenchDeploymentError.invalidPlan }
            let observation = try peer.observe(deviceId: deviceId)
            try budget.check()
            guard observation.deviceId == deviceId else { throw WorkbenchDeploymentError.staleContext }
            let profileHash = try WorkbenchDeploymentHash.profile(observation.profile)
            var retainedBytes = 0
            let frozen = try packages.map { selected in
                let package = try preparedStore.get(dashboardId: selected.dashboardId,
                    revision: selected.revision, sourceRevision: selected.sourceRevision,
                    targetProfileHash: profileHash, readBudget: budget,
                    maximumBytes: PackageLimits.expandedBytes - retainedBytes)
                retainedBytes += package.files.values.reduce(0) { $0 + $1.count }
                try budget.check()
                let frozen = try preparedStore.freeze(package, deviceId: deviceId,
                    dataDescription: selected.dataDescription)
                try budget.check()
                return frozen
            }
            try budget.check()
            return try prepare(workspaceId: workspaceId, deviceId: deviceId,
                material: .init(screens: frozen.sorted {
                    ToolchainCanonical.utf8Less($0.item.deployment.revision.dashboardId,
                                                $1.item.deployment.revision.dashboardId)
                }, selectedDashboardId: selectedDashboardId,
                    bindingIds: bindingIds.sorted(by: ToolchainCanonical.utf8Less)),
                removedDashboardIds: removedDashboardIds, lifetimeSeconds: lifetimeSeconds)
        }
    }

    func prepare(workspaceId: String, deviceId: String, material: WorkbenchDeploymentMaterial,
                 removedDashboardIds: [String], lifetimeSeconds: Int64 = 3600) throws -> WorkbenchDeploymentReview {
        try boundary.withDevice(deviceId) {
            guard WorkspaceValidation.id(workspaceId), WorkspaceValidation.id(deviceId),
                  (1...86_400).contains(lifetimeSeconds),
                  material.bindingIds == material.bindingIds.sorted(by: ToolchainCanonical.utf8Less),
                  Set(material.bindingIds).count == material.bindingIds.count else {
                throw WorkbenchDeploymentError.invalidPlan
            }
            let observation = try peer.observe(deviceId: deviceId)
            guard observation.deviceId == deviceId else { throw WorkbenchDeploymentError.staleContext }
            let manifestDetails = try verify(material: material, deviceId: deviceId)
            let requirements = manifestDetails.map { detail in
                WorkbenchDeploymentGrantRequirement(dashboardId: detail.manifest.dashboardId,
                    revision: detail.manifest.revision, sourceRevision: detail.screen.sourceRevision,
                    manifest: detail.manifest)
            }
            let grants = try grantAssessor(deviceId, requirements, material.bindingIds)
            for detail in manifestDetails {
                guard let orientation = DeviceOrientation(rawValue: detail.manifest.target.orientation) else {
                    throw WorkbenchDeploymentError.invalidPlan
                }
                var expected = observation.profile
                expected.apply(orientation: orientation)
                guard detail.manifest.target.width == expected.width,
                      detail.manifest.target.height == expected.height else {
                    throw WorkbenchDeploymentError.staleContext
                }
            }
            let oldIDs = Set(observation.screens.map(\.dashboardId))
            let newIDs = Set(material.screens.map { $0.item.deployment.revision.dashboardId })
            let removals = oldIDs.subtracting(newIDs).sorted(by: ToolchainCanonical.utf8Less)
            guard removals == removedDashboardIds else { throw WorkbenchDeploymentError.invalidPlan }
            let context = try currentContext(deviceId, material.bindingIds)
            guard WorkspaceValidation.sha256(context) else { throw WorkbenchDeploymentError.staleContext }
            let sample = clock()
            try ledger.observeClock(sample)
            guard sample.wallSeconds <= Int64.max - lifetimeSeconds,
                  sample.monotonicMilliseconds <= Int64.max - lifetimeSeconds * 1000 else {
                throw WorkbenchDeploymentError.clockUncertain
            }
            let expiry = sample.wallSeconds + lifetimeSeconds
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            let packages = manifestDetails.map { detail in
                WorkbenchDeploymentPackage(dashboardId: detail.manifest.dashboardId,
                    sourceRevision: detail.screen.sourceRevision,
                    revision: detail.manifest.revision, digest: detail.manifest.digest ?? "",
                    declaredCapabilities: declaredCapabilities(detail.manifest),
                    dataDescription: detail.screen.dataDescription)
            }
            guard packages.allSatisfy({ $0.dataDescription.unicodeScalars.count <= 4096 }) else {
                throw WorkbenchDeploymentError.invalidPlan
            }
            let body = WorkbenchDeploymentPlanBody(planVersion: 1, planId: UUID().uuidString.lowercased(),
                workspaceId: workspaceId, deviceId: deviceId,
                deviceProfileHash: try WorkbenchDeploymentHash.profile(observation.profile),
                expectedInstalledSetHash: try WorkbenchDeploymentHash.installedSet(observation.screens,
                    selected: observation.selectedDashboardId),
                packages: packages, selectedDashboardId: material.selectedDashboardId,
                removedDashboardIds: removals,
                requiredDeclarationsHash: try declarationsHash(requirements),
                approvalPolicy: "exact-package-installation-v1",
                expiresAt: formatter.string(from: Date(timeIntervalSince1970: TimeInterval(expiry))))
            let planHash = try WorkbenchDeploymentHash.plan(body)
            let resulting = material.screens.map { screen in
                LANScreenSetEntry(dashboardId: screen.item.deployment.revision.dashboardId,
                    revision: screen.item.deployment.revision.revision, name: screen.item.name)
            }
            var review = WorkbenchDeploymentReview(plan: body, planHash: planHash,
                authorizationContextHash: grants.ready ? context : nil,
                deviceName: WorkbenchDeploymentPresentation.escape(observation.name, limit: 128),
                observedAt: observation.observedAt,
                previouslyInstalled: observation.screens,
                previouslySelectedDashboardId: observation.selectedDashboardId,
                result: resulting,
                packageBytes: manifestDetails.reduce(0) { $0 + $1.bytes },
                note: "Package validated; native render/runtime behavior not verified",
                nativeRenderVerification: "not_performed")
            review.grantScopes = grants.scopes
            review.missingGrants = grants.missing
            let materialJSON = try encoder.encode(material)
            let record = WorkbenchDeploymentPlanRecord(planId: body.planId, planHash: planHash,
                workspaceId: workspaceId, deviceId: deviceId, authorizationContextHash: context,
                immutableBodyHash: try materialHash(materialJSON), materialJSON: materialJSON,
                reviewJSON: try encoder.encode(review), expiresWallSeconds: expiry,
                deadlineMonotonicMilliseconds: sample.monotonicMilliseconds + lifetimeSeconds * 1000,
                bootId: sample.bootId)
            try ledger.createPlan(record, clock: sample)
            return review
        }
    }

    func approve(_ review: WorkbenchDeploymentReview, consent: WorkbenchDeploymentConsent) throws -> WorkbenchDeploymentApprovalRecord {
        try boundary.withDevice(review.plan.deviceId) {
            guard let context = review.authorizationContextHash,
                  try WorkbenchDeploymentHash.plan(review.plan) == review.planHash else {
                throw WorkbenchDeploymentError.invalidPlan
            }
            let sample = clock()
            let frozenPlan = try ledger.observePlanClock(planId: review.plan.planId,
                planHash: review.planHash, clock: sample)
            let expiry = Int64(ISO8601DateFormatter().date(from: review.plan.expiresAt)?.timeIntervalSince1970 ?? 0)
            guard expiry == frozenPlan.expiresWallSeconds else { throw WorkbenchDeploymentError.invalidPlan }
            guard expiry > sample.wallSeconds else { throw WorkbenchDeploymentError.expired }
            let remainingSeconds = expiry - sample.wallSeconds
            guard frozenPlan.planHash == review.planHash,
                  (1...86_400).contains(remainingSeconds),
                  sample.monotonicMilliseconds <= Int64.max - remainingSeconds * 1000 else {
                throw WorkbenchDeploymentError.invalidPlan
            }
            let deadline = min(frozenPlan.deadlineMonotonicMilliseconds,
                               sample.monotonicMilliseconds + remainingSeconds * 1000)
            let approval = WorkbenchDeploymentApprovalRecord(approvalId: UUID().uuidString.lowercased(),
                planId: review.plan.planId, planHash: review.planHash, authorizationContextHash: context,
                consentSource: consent.source, expiresWallSeconds: expiry,
                deadlineMonotonicMilliseconds: deadline,
                bootId: sample.bootId)
            try ledger.approve(approval, clockProvider: clock) {
                try self.validateCurrent(review: review)
            }
            return approval
        }
    }

    func admit(_ review: WorkbenchDeploymentReview, approvalId: String, idempotencyKey: String,
               approved: Bool) throws -> WorkbenchDeploymentOperationRecord {
        try boundary.withDevice(review.plan.deviceId) {
            guard let context = review.authorizationContextHash,
                  try WorkbenchDeploymentHash.plan(review.plan) == review.planHash else {
                throw WorkbenchDeploymentError.invalidPlan
            }
            return try ledger.admit(planId: review.plan.planId, planHash: review.planHash,
                contextHash: context, approvalId: approvalId, idempotencyKey: idempotencyKey,
                approved: approved, clockProvider: clock) { try self.validateCurrent(review: review) }
        }
    }

    func dispatch(operationId: String, review: WorkbenchDeploymentReview) throws -> WorkbenchDeploymentOperationRecord {
        guard dispatchEnabled else { throw WorkbenchDeploymentError.unsupportedIntegration }
        return try boundary.withDevice(review.plan.deviceId) {
            let operation = try ledger.status(operationId)
            guard operation.planId == review.plan.planId, operation.planHash == review.planHash,
                  operation.authorizationContextHash == review.authorizationContextHash else {
                throw WorkbenchDeploymentError.conflict
            }
            let material = try material(for: review)
            let items = material.screens.enumerated().map { index, screen -> LANScreenSetItem in
                var item = screen.item
                item.deployment.deployment.deploymentId = material.screens.count == 1
                    ? operationId : "\(operationId)-\(index)"
                return item
            }
            let body = LANScreenSetDeployBody(deploymentId: operationId, deviceId: review.plan.deviceId,
                screens: items, selectedDashboardId: material.selectedDashboardId)
            try body.validate()
            let sending = try ledger.markSending(operationId: operationId, clockProvider: clock) {
                try self.validateCurrent(review: review)
            }
            guard sending.state == .sending else { return sending }
            let receipt: LANScreenSetReceipt
            do {
                receipt = try peer.send(body, preSend: {
                    guard try self.ledger.validateFirstSend(operationId: operationId,
                        clockProvider: self.clock,
                        validateCurrent: { try self.validateCurrent(review: review) }) else {
                        throw WorkbenchDeploymentPreSendFailure()
                    }
                })
            } catch is WorkbenchDeploymentPreSendFailure {
                return try ledger.status(operationId)
            }
            catch {
                _ = try ledger.updateOutcome(operationId: operationId, state: .unknown)
                throw WorkbenchDeploymentError.unknownRemoteOutcome
            }
            let expected = body.screens.map { LANScreenSetEntry(dashboardId: $0.deployment.revision.dashboardId,
                revision: $0.deployment.revision.revision, name: $0.name) }
            guard receipt.schemaVersion == 1, receipt.deploymentId == operationId,
                  receipt.deviceId == body.deviceId, receipt.screens == expected,
                  receipt.selectedDashboardId == body.selectedDashboardId else {
                _ = try ledger.updateOutcome(operationId: operationId, state: .unknown)
                throw WorkbenchDeploymentError.unknownRemoteOutcome
            }
            let requirements = try verify(material: material, deviceId: review.plan.deviceId).map {
                WorkbenchDeploymentGrantRequirement(dashboardId: $0.manifest.dashboardId,
                    revision: $0.manifest.revision, sourceRevision: $0.screen.sourceRevision,
                    manifest: $0.manifest)
            }
            if let selected = requirements.first(where: { $0.dashboardId == material.selectedDashboardId }),
               !selected.manifest.connections.isEmpty {
                // Persist the accepted screen receipt as uncertain before a
                // second potentially accepted native provisioning call. A
                // crash or lost provisioning reply must not become "active".
                _ = try ledger.updateOutcome(operationId: operationId, state: .unknown,
                    receiptJSON: encoder.encode(receipt))
                do { try grantInstaller(review.plan.deviceId, selected, material.bindingIds) }
                catch { throw WorkbenchDeploymentError.unknownRemoteOutcome }
            }
            let received = try ledger.updateOutcome(operationId: operationId, state: .received,
                receiptJSON: encoder.encode(receipt))
            // The receipt proves acceptance; only authenticated observation
            // of the exact set and selection can establish active state.
            return (try? reconcile(received, review: review)) ?? received
        }
    }

    func status(_ operationId: String) throws -> WorkbenchDeploymentOperationRecord { try ledger.status(operationId) }
    func lookup(planId: String, workspaceId: String) throws -> WorkbenchDeploymentOperationRecord? {
        guard try ledger.plan(planId).workspaceId == workspaceId else {
            throw WorkbenchDeploymentError.conflict
        }
        return try ledger.lookupOperationForPlan(planId)
    }
    func review(planId: String) throws -> WorkbenchDeploymentReview {
        let plan = try ledger.plan(planId)
        let review = try decoder.decode(WorkbenchDeploymentReview.self, from: plan.reviewJSON)
        guard review.plan.planId == planId, review.planHash == plan.planHash,
              review.plan.workspaceId == plan.workspaceId,
              review.plan.deviceId == plan.deviceId,
              (review.authorizationContextHash == nil ||
                  review.authorizationContextHash == plan.authorizationContextHash),
              (review.previouslyInstalled.isEmpty && review.previouslySelectedDashboardId == nil) ||
                review.previouslyInstalled.contains(where: {
                    $0.dashboardId == review.previouslySelectedDashboardId
                }),
              try WorkbenchDeploymentHash.installedSet(review.previouslyInstalled,
                  selected: review.previouslySelectedDashboardId) == review.plan.expectedInstalledSetHash,
              try WorkbenchDeploymentHash.plan(review.plan) == plan.planHash else {
            throw WorkbenchDeploymentError.conflict
        }
        return review
    }
    func cancel(planId: String, deviceId: String) throws -> WorkbenchDeploymentOperationRecord? {
        try boundary.withDevice(deviceId) { try ledger.cancelPlan(planId) }
    }
    func reconcile(operationId: String, review: WorkbenchDeploymentReview) throws -> WorkbenchDeploymentOperationRecord {
        try boundary.withDevice(review.plan.deviceId) {
            let operation = try ledger.status(operationId)
            return try reconcile(operation, review: review)
        }
    }
    private func reconcile(_ operation: WorkbenchDeploymentOperationRecord,
                           review: WorkbenchDeploymentReview) throws -> WorkbenchDeploymentOperationRecord {
        guard operation.sendAttempted, operation.planId == review.plan.planId,
              operation.planHash == review.planHash,
              operation.authorizationContextHash == review.authorizationContextHash else {
            throw WorkbenchDeploymentError.conflict
        }
        let material = try material(for: review)
        let expected = material.screens.map { screen in
            LANScreenSetEntry(dashboardId: screen.item.deployment.revision.dashboardId,
                              revision: screen.item.deployment.revision.revision,
                              name: screen.item.name)
        }
        guard review.result == expected,
              review.plan.selectedDashboardId == material.selectedDashboardId else {
            throw WorkbenchDeploymentError.conflict
        }
        // The current query reports set/revision/selection but no operation
        // identity. Without a correlated receipt, an identical pre-existing
        // set cannot establish that this unknown operation activated.
        guard operation.state == .received, let receiptJSON = operation.receiptJSON else { return operation }
        guard let receipt = try? decoder.decode(LANScreenSetReceipt.self, from: receiptJSON),
              receipt.schemaVersion == 1, receipt.deploymentId == operation.operationId,
              receipt.deviceId == review.plan.deviceId, receipt.screens == expected,
              receipt.selectedDashboardId == material.selectedDashboardId else {
            throw WorkbenchDeploymentError.conflict
        }
        let observation = try peer.observe(deviceId: review.plan.deviceId)
        guard observation.deviceId == review.plan.deviceId,
              observation.screens == expected,
              observation.selectedDashboardId == material.selectedDashboardId else { return operation }
        return try ledger.updateOutcome(operationId: operation.operationId, state: .active)
    }

    private func validateCurrent(review: WorkbenchDeploymentReview) throws {
        let material = try material(for: review)
        let requirements = try verify(material: material, deviceId: review.plan.deviceId).map {
            WorkbenchDeploymentGrantRequirement(dashboardId: $0.manifest.dashboardId,
                revision: $0.manifest.revision, sourceRevision: $0.screen.sourceRevision,
                manifest: $0.manifest)
        }
        let grants = try grantAssessor(review.plan.deviceId, requirements, material.bindingIds)
        guard grants.ready, grants.scopes == (review.grantScopes ?? []),
              review.missingGrants?.isEmpty != false,
              try declarationsHash(requirements) == review.plan.requiredDeclarationsHash else {
            throw WorkbenchDeploymentError.staleContext
        }
        guard try currentContext(review.plan.deviceId, material.bindingIds) == review.authorizationContextHash else {
            throw WorkbenchDeploymentError.staleContext
        }
        let observation = try peer.observe(deviceId: review.plan.deviceId)
        guard observation.deviceId == review.plan.deviceId,
              try WorkbenchDeploymentHash.profile(observation.profile) == review.plan.deviceProfileHash,
              try WorkbenchDeploymentHash.installedSet(observation.screens,
                  selected: observation.selectedDashboardId) == review.plan.expectedInstalledSetHash else {
            throw WorkbenchDeploymentError.staleContext
        }
        _ = try verify(material: material, deviceId: review.plan.deviceId)
    }
    private func material(for review: WorkbenchDeploymentReview) throws -> WorkbenchDeploymentMaterial {
        let plan = try ledger.plan(review.plan.planId)
        guard plan.planHash == review.planHash, plan.authorizationContextHash == review.authorizationContextHash,
              plan.immutableBodyHash == (try materialHash(plan.materialJSON)),
              try decoder.decode(WorkbenchDeploymentReview.self, from: plan.reviewJSON) == review else {
            throw WorkbenchDeploymentError.conflict
        }
        return try decoder.decode(WorkbenchDeploymentMaterial.self, from: plan.materialJSON)
    }
    private func materialHash(_ data: Data) throws -> String {
        try ToolchainCanonical.hash(domain: "frozen-deployment-material", value:
            JSONSerialization.jsonObject(with: data))
    }
    private func declarationsHash(_ requirements: [WorkbenchDeploymentGrantRequirement]) throws -> String {
        let values: [[String: Any]] = try requirements.filter { !$0.manifest.connections.isEmpty }
            .map { requirement in
                ["dashboardId": requirement.dashboardId, "revision": requirement.revision,
                 "connections": try JSONSerialization.jsonObject(with:
                    JSONEncoder().encode(requirement.manifest.connections))]
            }
        if values.isEmpty {
            return try ToolchainCanonical.hash(domain: "required-declarations", value: [] as [String])
        }
        return try ToolchainCanonical.hash(domain: "required-declarations", value: values)
    }
    private func declaredCapabilities(_ manifest: DashboardManifest) -> [String] {
        var result = ["web-runtime"]
        result += manifest.connections.map { "connection:" + $0.alias }
        if manifest.pages?.isEmpty == false { result.append("navigation.pages") }
        if manifest.eventRules?.isEmpty == false { result.append("device.event-rules") }
        if let audio = manifest.deviceBehavior?.audio {
            result.append(audio.autoplay ? "audio.autoplay.allowed" : "audio.autoplay.denied")
        }
        if manifest.deviceBehavior?.temporaryActivation != nil {
            result.append("temporary-activation.home-assistant")
        }
        return result.sorted(by: ToolchainCanonical.utf8Less)
    }
    private func verify(material: WorkbenchDeploymentMaterial, deviceId: String)
        throws -> [(screen: WorkbenchFrozenScreen, manifest: DashboardManifest, bytes: Int)] {
        guard (1...12).contains(material.screens.count),
              material.screens.map({ $0.item.deployment.revision.dashboardId }) ==
                material.screens.map({ $0.item.deployment.revision.dashboardId }).sorted(by: ToolchainCanonical.utf8Less),
              Set(material.screens.map({ $0.item.deployment.revision.dashboardId })).count == material.screens.count,
              material.screens.contains(where: { $0.item.deployment.revision.dashboardId == material.selectedDashboardId }) else {
            throw WorkbenchDeploymentError.invalidPlan
        }
        return try material.screens.map { screen in
            let item = screen.item
            guard item.homeAssistant == nil, item.publicReads == nil,
                  item.deployment.deployment.deviceId == deviceId,
                  item.deployment.deployment.dashboardId == item.deployment.revision.dashboardId,
                  item.deployment.deployment.revision == item.deployment.revision.revision,
                  (1...2_000).contains(item.deployment.files.count),
                  item.deployment.files.map(\.path) == item.deployment.files.map(\.path).sorted(by: ToolchainCanonical.utf8Less),
                  Set(item.deployment.files.map(\.path)).count == item.deployment.files.count else {
                throw WorkbenchDeploymentError.invalidPlan
            }
            var bytes = 0
            var payloads: [String: Data] = [:]
            for file in item.deployment.files {
                guard WorkspaceValidation.member(file.path), let data = Data(base64Encoded: file.dataBase64),
                      data.count <= 50 * 1024 * 1024 - bytes,
                      DeploymentDigest.sha256Hex(data) == file.sha256 else {
                    throw WorkbenchDeploymentError.invalidPlan
                }
                bytes += data.count; payloads[file.path] = data
            }
            guard let manifestData = payloads["manifest.json"],
                  let manifest = try? decoder.decode(DashboardManifest.self, from: manifestData),
                  manifest.dashboardId == item.deployment.revision.dashboardId,
                  manifest.revision == item.deployment.revision.revision,
                  manifest.name == item.name,
                  manifest.digest == item.deployment.revision.digest,
                  manifest.target.profileId == deviceId,
                  manifest.target.width == item.deployment.revision.width,
                  manifest.target.height == item.deployment.revision.height,
                  manifest.target.orientation == item.deployment.revision.orientation.rawValue,
                  Set(manifest.files.map(\.path)).count == manifest.files.count,
                  manifest.files.count + 1 == payloads.count else { throw WorkbenchDeploymentError.invalidPlan }
            try PackageValidator.validate(manifest)
            guard try DeploymentDigest.digest(for: manifest) == manifest.digest else {
                throw WorkbenchDeploymentError.invalidPlan
            }
            for entry in manifest.files {
                guard let data = payloads[entry.path], data.count == entry.bytes,
                      DeploymentDigest.sha256Hex(data) == entry.sha256 else {
                    throw WorkbenchDeploymentError.invalidPlan
                }
            }
            return (screen, manifest, bytes)
        }
    }
}
#endif
