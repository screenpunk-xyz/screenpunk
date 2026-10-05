import Foundation
import ScreenpunkCore
#if os(macOS)
import Darwin

public enum WorkbenchBrokerCredentialScope: Sendable, Equatable { case ordinary, localReview }

public final class WorkbenchBrokerClient: @unchecked Sendable {
    private let environment: WorkbenchBrokerEnvironment
    private let credentialScope: WorkbenchBrokerCredentialScope
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var instanceId: String?
    public init(environment: WorkbenchBrokerEnvironment,
                credentialScope: WorkbenchBrokerCredentialScope = .ordinary) {
        self.environment = environment; self.credentialScope = credentialScope
    }
    public func connect() throws { try connect(timeout: environment.limits.timeout) }
    /// A caller may shorten the transport budget without changing authentication.
    public func connect(timeout: TimeInterval) throws {
        lock.lock(); defer { lock.unlock() }
        guard fd < 0 else { throw WorkbenchIPCError(.invalidConfiguration) }
        let deadline = try readDeadline(timeout: timeout)
        do {
            let directory = try WorkbenchRuntimeDirectory(environment: environment, create: false)
            let locator = try directory.locator()
            let socketIdentity = try directory.identity(of: "broker.sock", socket: true)
            // Validate token metadata now, but do not read its bytes until server UID validation.
            let tokenName = credentialScope == .localReview ? "broker.local-token" : "broker.token"
            let tokenIdentity = try directory.identity(of: tokenName)
            try directory.revalidatePath()
            fd = try WorkbenchSocket.make()
            let path = environment.runtimeDirectory.appendingPathComponent("broker.sock").path
            let result = try WorkbenchSocket.address(path) { Darwin.connect(fd, $0, $1) }
            if result != 0 {
                guard errno == EINPROGRESS || errno == EAGAIN else { throw WorkbenchIPCError(.unavailable) }
                try WorkbenchSocket.wait(fd, events: Int16(POLLOUT), deadline: deadline, clock: environment.clock)
                var socketError: Int32 = 0; var size = socklen_t(MemoryLayout.size(ofValue: socketError))
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0, socketError == 0 else { throw WorkbenchIPCError(.unavailable) }
            }
            guard try environment.peerCredentials.effectiveUID(socket: fd) == environment.ownerUID else { throw WorkbenchIPCError(.unauthorizedPeer) }
            try directory.revalidatePath()
            guard try directory.locator() == locator,
                  try directory.identity(of: "broker.sock", socket: true) == socketIdentity,
                  try directory.identity(of: tokenName) == tokenIdentity else { throw WorkbenchIPCError(.instanceMismatch) }
            let token = try directory.read(tokenName, maxBytes: 32)
            guard token.count == 32 else { throw WorkbenchIPCError(.insecureRuntime) }
            instanceId = locator.instanceId
            let auth = ["apiVersion": "1.0", "instanceId": locator.instanceId, "token": token.base64EncodedString()]
            try WorkbenchSocket.writeFrame(fd, bytes: WorkbenchSocket.encode(auth), environment: environment, deadline: deadline)
            _ = try receive(requestId: "authentication", method: "authentication", deadline: deadline)
            _ = try call("system.hello", params: [:], deadline: deadline)
        } catch { closeLocked(); throw error }
    }
    /// Refresh only a transport already known to be closed before the next
    /// request. A failure while sending or awaiting a request is never retried:
    /// its mutation outcome may be unknown to the caller.
    @discardableResult public func reconnectIfPeerClosed() throws -> Bool {
        lock.lock()
        var needsConnection = fd < 0
        if !needsConnection {
            var byte: UInt8 = 0
            let count = Darwin.recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            if count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                closeLocked()
                needsConnection = true
            }
        }
        lock.unlock()
        if needsConnection { try connect() }
        return needsConnection
    }
    public func hello() throws -> WorkbenchBrokerSnapshot { try requestSnapshot("system.hello") }
    public func capabilities() throws -> WorkbenchBrokerSnapshot { try requestSnapshot("system.capabilities") }
    public func health() throws -> WorkbenchBrokerSnapshot { try requestSnapshot("system.health") }
    public func health(timeout: TimeInterval) throws -> WorkbenchBrokerSnapshot {
        try requestSnapshot("system.health", timeout: timeout)
    }
    public func stopService() throws -> WorkbenchBrokerSnapshot { try requestSnapshot("service.stop") }
    public func serviceLifecycle() throws -> WorkbenchServiceLifecycleResult { try requestLifecycle("service.lifecycle") }
    public func serviceLifecycle(timeout: TimeInterval) throws -> WorkbenchServiceLifecycleResult {
        try requestLifecycle("service.lifecycle", timeout: timeout)
    }
    public func drainService() throws -> WorkbenchServiceLifecycleResult { try requestLifecycle("service.drain") }
    /// Private package lifecycle RPC, like service.stop. It is intentionally
    /// absent from the public capability list that older API 1.0 clients pin.
    public func prepareServiceRemoval() throws -> WorkbenchServiceLifecycleResult {
        try requestLifecycle("service.prepareRemoval")
    }
    public func performAuthoring(method: WorkbenchAuthoringRecoveryMethod,
                                 params: [String: Any],
                                 operationId: String? = nil) throws -> WorkbenchAuthoringRecoveryResult {
        _ = try WorkbenchAuthoringRecoveryRequest.parse(method: method, params: params)
        if let operationId {
            guard [WorkbenchAuthoringRecoveryMethod.snapshotCreate,
                   WorkbenchAuthoringRecoveryMethod.workspaceRelocate].contains(method),
                  UUID(uuidString: operationId) != nil else {
                throw WorkbenchIPCError(.invalidRequest)
            }
        }
        lock.lock(); defer { lock.unlock() }
        do {
            let deadline = method == .snapshotCreate || method == .workspaceRelocate
                ? environment.clock.now() + 305 :
                ([.projectClone, .packageExport, .projectUpgradeKit].contains(method)
                    ? environment.clock.now() + 125 : nil)
            guard case .authoringAction(let value) = try call(method.rawValue,
                params: params, deadline: deadline, requestId: operationId) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            try value.validate(for: method)
            return value
        } catch { closeLocked(); throw error }
    }
    public func workspaceOperationStatus(operationId: String) throws -> WorkbenchWorkspaceOperationStatus {
        try workspaceOperation(operationId: operationId,
            method: WorkbenchWorkspaceOperationStatus.method)
    }
    public func requestWorkspaceOperationCancel(operationId: String) throws -> WorkbenchWorkspaceOperationStatus {
        try workspaceOperation(operationId: operationId,
            method: WorkbenchWorkspaceOperationStatus.cancelMethod)
    }
    public func workspaceOperationList() throws -> WorkbenchWorkspaceOperationList {
        lock.lock(); defer { lock.unlock() }
        do {
            guard case .workspaceOperationList(let value) = try call(
                WorkbenchWorkspaceOperationList.method,
                params: ["schemaVersion": 1]) else { throw WorkbenchIPCError(.invalidRequest) }
            try value.validate()
            return value
        } catch { closeLocked(); throw error }
    }
    public func operationInventory() throws -> WorkbenchOperationInventory {
        lock.lock(); defer { lock.unlock() }
        do {
            guard case .operationInventory(let value) = try call(
                WorkbenchOperationInventory.listMethod,
                params: ["schemaVersion": 1]) else { throw WorkbenchIPCError(.invalidRequest) }
            try value.validate()
            guard value.instanceId == instanceId else { throw WorkbenchIPCError(.instanceMismatch) }
            return value
        } catch { closeLocked(); throw error }
    }
    public func operationEntry(operationId: String, requestCancel: Bool = false) throws
        -> WorkbenchOperationEntry {
        guard UUID(uuidString: operationId) != nil else { throw WorkbenchIPCError(.invalidRequest) }
        lock.lock(); defer { lock.unlock() }
        do {
            guard case .operationEntry(let value) = try call(
                requestCancel ? WorkbenchOperationInventory.cancelMethod : WorkbenchOperationInventory.showMethod,
                params: ["schemaVersion": 1, "operationId": operationId]) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            try value.validate()
            guard value.operationId == operationId else { throw WorkbenchIPCError(.invalidRequest) }
            return value
        } catch { closeLocked(); throw error }
    }
    public func retainedDeploymentEvidence(workspaceId: String,
                                           selectionGeneration: Int,
                                           deviceId: String) throws
        -> WorkbenchRetainedDeploymentEvidenceRead {
        guard WorkspaceValidation.id(workspaceId), selectionGeneration > 0,
              WorkspaceValidation.id(deviceId) else { throw WorkbenchIPCError(.invalidRequest) }
        lock.lock(); defer { lock.unlock() }
        do {
            guard case .retainedDeploymentEvidence(let value) = try call(
                WorkbenchRetainedDeploymentEvidenceRead.method,
                params: ["schemaVersion": 1, "expectedWorkspaceId": workspaceId,
                         "expectedSelectionGeneration": selectionGeneration,
                         "deviceId": deviceId]) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            try value.validate()
            guard value.workspaceId == workspaceId,
                  value.selectionGeneration == selectionGeneration,
                  value.deviceId == deviceId else { throw WorkbenchIPCError(.workspaceConflict) }
            return value
        } catch { closeLocked(); throw error }
    }
    public func deviceLogs(deviceId: String) throws -> WorkbenchDeviceLogRead {
        guard WorkspaceValidation.id(deviceId) else { throw WorkbenchIPCError(.invalidRequest) }
        lock.lock(); defer { lock.unlock() }
        do {
            guard case .deviceLog(let value) = try call(WorkbenchDeviceLogRead.method,
                params: ["schemaVersion": 1, "deviceId": deviceId]) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            try value.validate()
            guard value.deviceId == deviceId else { throw WorkbenchIPCError(.invalidRequest) }
            return value
        } catch { closeLocked(); throw error }
    }
    public func nativeDoctor() throws -> WorkbenchNativeDoctorRead {
        lock.lock(); defer { lock.unlock() }
        do {
            guard case .nativeDoctor(let value) = try call(WorkbenchNativeDoctorRead.method,
                params: ["schemaVersion": 1]) else { throw WorkbenchIPCError(.invalidRequest) }
            try value.validate()
            return value
        } catch { closeLocked(); throw error }
    }
    public func renameScreenSource(params: [String: Any]) throws -> WorkbenchScreenRenameResult {
        let request = try WorkbenchScreenMutationRequest.parse(.sourceRename, params)
        guard case .sourceRename(let value) = try screenMutation(request, params: params) else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        return value
    }
    public func renameScreenSource(_ request: WorkbenchScreenRenameRequest) throws -> WorkbenchScreenRenameResult {
        try renameScreenSource(params: ["schemaVersion": 1,
            "expectedWorkspaceId": request.expectedWorkspaceId,
            "expectedSelectionGeneration": request.expectedSelectionGeneration,
            "expectedCatalogGeneration": request.expectedCatalogGeneration,
            "projectId": request.projectId, "expectedSourceVersion": request.expectedSourceVersion,
            "name": request.name])
    }
    public func renameScreenPackage(params: [String: Any]) throws -> WorkbenchScreenPackageRenameResult {
        let request = try WorkbenchScreenMutationRequest.parse(.packageRename, params)
        guard case .packageRename(let value) = try screenMutation(request, params: params) else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        return value
    }
    public func renameScreenPackage(_ request: WorkbenchScreenPackageRenameRequest) throws
        -> WorkbenchScreenPackageRenameResult {
        try renameScreenPackage(params: ["schemaVersion": 1,
            "expectedWorkspaceId": request.expectedWorkspaceId,
            "expectedSelectionGeneration": request.expectedSelectionGeneration,
            "expectedCatalogGeneration": request.expectedCatalogGeneration,
            "dashboardId": request.dashboardId, "expectedRevision": request.expectedRevision,
            "expectedDigest": request.expectedDigest, "name": request.name])
    }
    public func duplicateScreenPackage(params: [String: Any]) throws -> WorkbenchScreenPackageDuplicateResult {
        let request = try WorkbenchScreenMutationRequest.parse(.packageDuplicate, params)
        guard case .packageDuplicate(let value) = try screenMutation(request, params: params) else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        return value
    }
    public func duplicateScreenPackage(_ request: WorkbenchScreenPackageDuplicateRequest) throws
        -> WorkbenchScreenPackageDuplicateResult {
        try duplicateScreenPackage(params: ["schemaVersion": 1,
            "expectedWorkspaceId": request.source.expectedWorkspaceId,
            "expectedSelectionGeneration": request.source.expectedSelectionGeneration,
            "expectedCatalogGeneration": request.source.expectedCatalogGeneration,
            "dashboardId": request.source.dashboardId, "expectedRevision": request.source.expectedRevision,
            "expectedDigest": request.source.expectedDigest, "name": request.source.name])
    }
    public func setScreenPackageOrientation(params: [String: Any]) throws -> WorkbenchScreenPackageOrientationResult {
        let request = try WorkbenchScreenMutationRequest.parse(.packageOrientation, params)
        guard case .packageOrientation(let value) = try screenMutation(request, params: params) else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        return value
    }
    public func setScreenPackageOrientation(_ request: WorkbenchScreenPackageOrientationRequest) throws
        -> WorkbenchScreenPackageOrientationResult {
        try setScreenPackageOrientation(params: ["schemaVersion": 1,
            "expectedWorkspaceId": request.expectedWorkspaceId,
            "expectedSelectionGeneration": request.expectedSelectionGeneration,
            "expectedCatalogGeneration": request.expectedCatalogGeneration,
            "dashboardId": request.dashboardId, "expectedRevision": request.expectedRevision,
            "expectedDigest": request.expectedDigest, "support": request.support.rawValue])
    }
    public func setScreenIcon(params: [String: Any]) throws -> WorkbenchScreenIconResult {
        let request = try WorkbenchScreenMutationRequest.parse(.iconSet, params)
        guard case .iconSet(let value) = try screenMutation(request, params: params) else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        return value
    }
    public func setScreenIcon(_ request: WorkbenchScreenIconRequest) throws -> WorkbenchScreenIconResult {
        try setScreenIcon(params: ["schemaVersion": 1,
            "expectedWorkspaceId": request.expectedWorkspaceId,
            "expectedSelectionGeneration": request.expectedSelectionGeneration,
            "expectedCatalogGeneration": request.expectedCatalogGeneration,
            "dashboardId": request.dashboardId, "symbol": request.symbol])
    }
    public func archiveScreen(params: [String: Any]) throws -> WorkbenchScreenArchiveResult {
        let request = try WorkbenchScreenMutationRequest.parse(.archive, params)
        guard case .archive(let value) = try screenMutation(request, params: params) else {
            throw WorkbenchIPCError(.publicationOutcomeUnknown)
        }
        return value
    }
    public func archiveScreen(_ request: WorkbenchScreenArchiveRequest) throws -> WorkbenchScreenArchiveResult {
        var params: [String: Any] = ["schemaVersion": 1,
            "expectedWorkspaceId": request.expectedWorkspaceId,
            "expectedSelectionGeneration": request.expectedSelectionGeneration,
            "expectedCatalogGeneration": request.expectedCatalogGeneration,
            "dashboardId": request.dashboardId]
        if let revision = request.expectedRevision, let digest = request.expectedDigest {
            params["expectedRevision"] = revision; params["expectedDigest"] = digest
        } else if let projectId = request.projectId,
                  let sourceVersion = request.expectedSourceVersion {
            params["projectId"] = projectId; params["expectedSourceVersion"] = sourceVersion
        } else { throw WorkbenchIPCError(.invalidRequest) }
        return try archiveScreen(params: params)
    }
    public func associateReactSource(params: [String: Any]) throws
        -> WorkbenchReactSourceAssociationResult {
        let request = try WorkbenchScreenMutationRequest.parse(.reactSourceAssociate, params)
        guard case .reactSourceAssociate(let value) = try screenMutation(request, params: params) else {
            throw WorkbenchIPCError(.publicationOutcomeUnknown)
        }
        return value
    }
    public func associateReactSource(_ request: WorkbenchReactSourceAssociationRequest) throws
        -> WorkbenchReactSourceAssociationResult {
        try associateReactSource(params: ["schemaVersion": 1,
            "expectedWorkspaceId": request.expectedWorkspaceId,
            "expectedSelectionGeneration": request.expectedSelectionGeneration,
            "expectedCatalogGeneration": request.expectedCatalogGeneration,
            "projectId": request.projectId, "expectedSourceVersion": request.expectedSourceVersion,
            "dashboardId": request.dashboardId, "expectedRevision": request.expectedRevision,
            "expectedDigest": request.expectedDigest])
    }
    private func screenMutation(_ request: WorkbenchScreenMutationRequest,
                                params: [String: Any]) throws -> WorkbenchScreenMutationResult {
        lock.lock(); defer { lock.unlock() }
        do {
            guard case .screenMutation(let result) = try call(request.method.rawValue, params: params) else {
                throw WorkbenchIPCError(.publicationOutcomeUnknown)
            }
            do { try result.validate(for: request) }
            catch { throw WorkbenchIPCError(.publicationOutcomeUnknown) }
            return result
        } catch let error as WorkbenchIPCError where error.code == .invalidRequest {
            closeLocked()
            throw WorkbenchIPCError(.publicationOutcomeUnknown)
        } catch { closeLocked(); throw error }
    }
    public func toolchainRequirements() throws -> WorkbenchToolchainRequirementsRead {
        lock.lock(); defer { lock.unlock() }
        do {
            guard case .toolchainRequirements(let value) = try call(
                WorkbenchToolchainRequirementsRead.method,
                params: ["schemaVersion": 1]) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            try value.validate()
            return value
        } catch { closeLocked(); throw error }
    }
    public func installRequiredToolchains(expectedWorkspaceId: String,
                                          expectedSelectionGeneration: Int) throws
        -> WorkbenchToolchainInstallResult {
        lock.lock(); defer { lock.unlock() }
        do {
            guard case .toolchainInstall(let value) = try call(
                WorkbenchToolchainInstallResult.method,
                params: ["schemaVersion": 1,
                         "expectedWorkspaceId": expectedWorkspaceId,
                         "expectedSelectionGeneration": expectedSelectionGeneration],
                deadline: environment.clock.now() + 620) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            try value.validate()
            guard value.workspaceId == expectedWorkspaceId,
                  value.selectionGeneration == expectedSelectionGeneration else {
                throw WorkbenchIPCError(.workspaceConflict)
            }
            return value
        } catch { closeLocked(); throw error }
    }
    private func workspaceOperation(operationId: String, method: String) throws -> WorkbenchWorkspaceOperationStatus {
        guard UUID(uuidString: operationId) != nil else { throw WorkbenchIPCError(.invalidRequest) }
        lock.lock(); defer { lock.unlock() }
        do {
            guard case .workspaceOperation(let value) = try call(
                method,
                params: ["schemaVersion": 1, "operationId": operationId]) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            try value.validate()
            guard value.operationId == operationId else { throw WorkbenchIPCError(.invalidRequest) }
            return value
        } catch { closeLocked(); throw error }
    }
    public func performDeployment(method: WorkbenchDeploymentMethod,
                                  params: [String: Any]) throws -> WorkbenchDeploymentActionResult {
        let request = try WorkbenchDeploymentRequest.parse(method, params)
        lock.lock(); defer { lock.unlock() }
        do {
            let deadline = environment.clock.now() + 120
            guard case .deploymentAction(let result) = try call(method.rawValue,
                params: params, deadline: deadline) else { throw WorkbenchIPCError(.invalidRequest) }
            try result.validate(for: request)
            return result
        } catch { closeLocked(); throw error }
    }
    public func sourceText(projectId: String, path: String, expectedWorkspaceId: String,
                           expectedSelectionGeneration: Int) throws -> WorkbenchSourceTextRead {
        let request = try WorkbenchSourceTextRequest(expectedWorkspaceId: expectedWorkspaceId,
            expectedSelectionGeneration: expectedSelectionGeneration, projectId: projectId, path: path)
        lock.lock(); defer { lock.unlock() }
        do {
            guard case .sourceText(let result) = try call(WorkbenchSourceTextRequest.method, params: [
                "schemaVersion": 1, "expectedWorkspaceId": request.expectedWorkspaceId,
                "expectedSelectionGeneration": request.expectedSelectionGeneration,
                "projectId": request.projectId, "path": request.path
            ]), result.workspaceId == request.expectedWorkspaceId,
                result.selectionGeneration == request.expectedSelectionGeneration,
                result.projectId == request.projectId, result.path == request.path,
                WorkspaceValidation.sha256(result.sourceVersion), result.text.utf8.count <= 2_048 else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            return result
        } catch { closeLocked(); throw error }
    }
    public func sourceChunk(projectId: String, path: String, expectedSourceVersion: String,
                            offset: Int, expectedWorkspaceId: String,
                            expectedSelectionGeneration: Int) throws -> WorkbenchSourceChunkRead {
        let request = try WorkbenchSourceChunkRequest(expectedWorkspaceId: expectedWorkspaceId,
            expectedSelectionGeneration: expectedSelectionGeneration, projectId: projectId,
            path: path, expectedSourceVersion: expectedSourceVersion, offset: offset)
        lock.lock(); defer { lock.unlock() }
        do {
            guard case .sourceChunk(let result) = try call(WorkbenchSourceChunkRequest.method, params: [
                "schemaVersion": 1, "expectedWorkspaceId": request.expectedWorkspaceId,
                "expectedSelectionGeneration": request.expectedSelectionGeneration,
                "projectId": request.projectId, "path": request.path,
                "expectedSourceVersion": request.expectedSourceVersion, "offset": request.offset
            ]) else { throw WorkbenchIPCError(.invalidRequest) }
            try result.validate(for: request)
            return result
        } catch { closeLocked(); throw error }
    }
    public func beginPackageImport(manifest: DashboardManifest, expectedDigest: String,
                                   expectedWorkspaceId: String,
                                   expectedSelectionGeneration: Int) throws -> WorkbenchPackageImportResult {
        try requestPackageImport(.begin, workspaceId: expectedWorkspaceId,
            generation: expectedSelectionGeneration, fields: [
                "expectedDigest": expectedDigest,
                "manifestBase64": try JSONEncoder().encode(manifest).base64EncodedString()])
    }
    public func sendPackageImportChunk(uploadId: String, fileIndex: Int, offset: Int,
                                       bytes: Data, expectedWorkspaceId: String,
                                       expectedSelectionGeneration: Int) throws -> WorkbenchPackageImportResult {
        try requestPackageImport(.chunk, workspaceId: expectedWorkspaceId,
            generation: expectedSelectionGeneration, fields: [
                "uploadId": uploadId, "fileIndex": fileIndex, "offset": offset,
                "chunkSHA256": DeploymentDigest.sha256Hex(bytes),
                "bytesBase64": bytes.base64EncodedString()])
    }
    public func packageImportStatus(uploadId: String, expectedWorkspaceId: String,
                                    expectedSelectionGeneration: Int) throws -> WorkbenchPackageImportResult {
        try requestPackageImport(.status, workspaceId: expectedWorkspaceId,
            generation: expectedSelectionGeneration, fields: ["uploadId": uploadId])
    }
    public func commitPackageImport(uploadId: String, expectedDigest: String,
                                    expectedWorkspaceId: String,
                                    expectedSelectionGeneration: Int) throws -> WorkbenchBoundedPackageImportReceipt {
        let result = try requestPackageImport(.commit, workspaceId: expectedWorkspaceId,
            generation: expectedSelectionGeneration, fields: [
                "uploadId": uploadId, "expectedDigest": expectedDigest])
        guard let receipt = result.receipt, receipt.digest == expectedDigest,
              receipt.workspaceId == expectedWorkspaceId,
              receipt.selectionGeneration == expectedSelectionGeneration else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        return receipt
    }
    public func abortPackageImport(uploadId: String, expectedWorkspaceId: String,
                                   expectedSelectionGeneration: Int) throws {
        let result = try requestPackageImport(.abort, workspaceId: expectedWorkspaceId,
            generation: expectedSelectionGeneration, fields: ["uploadId": uploadId])
        guard result.aborted == true else { throw WorkbenchIPCError(.invalidRequest) }
    }
    private func requestPackageImport(_ method: WorkbenchPackageImportMethod,
                                      workspaceId: String, generation: Int,
                                      fields: [String: Any]) throws -> WorkbenchPackageImportResult {
        var params = fields
        params["schemaVersion"] = 1
        params["expectedWorkspaceId"] = workspaceId
        params["expectedSelectionGeneration"] = generation
        _ = try WorkbenchPackageImportRequest.parse(method, params)
        lock.lock(); defer { lock.unlock() }
        do {
            guard case .packageImport(let result) = try call(method.rawValue, params: params,
                deadline: environment.clock.now() + 120) else { throw WorkbenchIPCError(.invalidRequest) }
            try result.validate(for: method)
            return result
        } catch { closeLocked(); throw error }
    }
    public func registerGUIConsumer() throws -> WorkbenchGUIConsumerResult {
        try requestGUIConsumer(.register)
    }
    public func renewGUIConsumer() throws -> WorkbenchGUIConsumerResult {
        try requestGUIConsumer(.renew)
    }
    public func releaseGUIConsumer() throws -> WorkbenchGUIConsumerResult {
        try requestGUIConsumer(.release)
    }
    private func requestGUIConsumer(_ method: WorkbenchGUIConsumerMethod) throws -> WorkbenchGUIConsumerResult {
        lock.lock(); defer { lock.unlock() }
        do {
            guard case .guiConsumer(let result) = try call(method.rawValue,
                params: ["schemaVersion": 1]) else { throw WorkbenchIPCError(.invalidRequest) }
            try result.validate(for: method)
            return result
        } catch { closeLocked(); throw error }
    }
    public func listWorkspacePackages(in selected: WorkbenchWorkspaceStatus) throws -> [WorkbenchWorkspacePackageSummary] {
        var collected: [WorkbenchWorkspacePackageSummary] = []
        var cursor: String?
        repeat {
            let page = try workspacePackagePage(in: selected, cursor: cursor)
            guard let packages = page.packages, collected.count + packages.count <= 4_096 else {
                throw WorkbenchIPCError(.resourceLimit)
            }
            collected += packages
            cursor = page.nextCursor
        } while cursor != nil
        return collected.filter(\.visibleInLibrary)
    }
    public func workspacePackagePage(in selected: WorkbenchWorkspaceStatus,
                                     cursor: String? = nil) throws -> WorkbenchWorkspacePackageResult {
        let selection = try selectedWorkspaceSelection(selected)
        let result = try requestWorkspacePackage(.list(selection.0, selection.1, cursor))
        guard result.packages != nil else { throw WorkbenchIPCError(.invalidRequest) }
        return result
    }
    public func workspacePackage(dashboardId: String, revision: String,
                                 in selected: WorkbenchWorkspaceStatus) throws -> WorkbenchWorkspacePackageSummary {
        let selection = try selectedWorkspaceSelection(selected)
        let result = try requestWorkspacePackage(.get(selection.0, selection.1, dashboardId, revision))
        guard let package = result.package else { throw WorkbenchIPCError(.invalidRequest) }
        return package
    }
    public func workspacePackageFile(dashboardId: String, revision: String, path: String,
                                     offset: Int, in selected: WorkbenchWorkspaceStatus) throws -> WorkbenchWorkspacePackageChunk {
        let selection = try selectedWorkspaceSelection(selected)
        let result = try requestWorkspacePackage(.file(selection.0, selection.1,
            dashboardId, revision, path, offset))
        guard let chunk = result.chunk else { throw WorkbenchIPCError(.invalidRequest) }
        return chunk
    }
    private func selectedWorkspaceSelection(_ selected: WorkbenchWorkspaceStatus) throws -> (String, Int) {
        guard selected.state == "selected", let id = selected.workspaceId,
              let generation = selected.selectionGeneration else { throw WorkbenchIPCError(.workspaceConflict) }
        return (id, generation)
    }
    private func requestWorkspacePackage(_ request: WorkbenchWorkspacePackageRequest) throws -> WorkbenchWorkspacePackageResult {
        var params: [String: Any] = ["schemaVersion": 1,
            "expectedWorkspaceId": request.selection.workspaceId,
            "expectedSelectionGeneration": request.selection.generation]
        switch request {
        case .list(_, _, let cursor):
            if let cursor { params["cursor"] = cursor }
        case .get(_, _, let id, let revision):
            params["dashboardId"] = id; params["revision"] = revision
        case .file(_, _, let id, let revision, let path, let offset):
            params["dashboardId"] = id; params["revision"] = revision
            params["path"] = path; params["offset"] = offset
        }
        _ = try WorkbenchWorkspacePackageRequest.parse(request.method, params)
        lock.lock(); defer { lock.unlock() }
        do {
            guard case .workspacePackage(let result) = try call(request.method.rawValue, params: params) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            try result.validate(for: request)
            return result
        } catch { closeLocked(); throw error }
    }
    public func initializeWorkspace(path: String? = nil) throws -> WorkbenchWorkspaceStatus {
        var params: [String: Any] = ["schemaVersion": 1]
        if let path { params["path"] = path }
        return try requestWorkspaceControl("workspace.init", params: params)
    }
    public func openWorkspace(path: String) throws -> WorkbenchWorkspaceStatus {
        try requestWorkspaceControl("workspace.open", params: ["schemaVersion": 1, "path": path])
    }
    public func workspaceStatus() throws -> WorkbenchWorkspaceStatus {
        guard let value = try requestRead(.workspaceStatus, params: ["schemaVersion": 1]).workspace else { throw WorkbenchIPCError(.invalidRequest) }
        return value
    }
    public func workspaceStatus(timeout: TimeInterval) throws -> WorkbenchWorkspaceStatus {
        guard let value = try requestRead(.workspaceStatus, params: ["schemaVersion": 1],
                                         timeout: timeout).workspace else { throw WorkbenchIPCError(.invalidRequest) }
        return value
    }
    public func workspaceCoverage(validate: Bool = false) throws -> WorkbenchCoverageRead {
        guard let value = try requestRead(validate ? .workspaceValidate : .workspaceCoverage,
                                          params: ["schemaVersion": 1]).coverage else { throw WorkbenchIPCError(.invalidRequest) }
        return value
    }
    public func listProjects() throws -> [WorkspaceProject] {
        guard let value = try requestRead(.projectList, params: ["schemaVersion": 1]).projects else { throw WorkbenchIPCError(.invalidRequest) }
        return value
    }
    public func getProject(_ id: String) throws -> WorkspaceProject {
        guard let value = try requestRead(.projectGet, params: ["schemaVersion": 1, "projectId": id]).project else { throw WorkbenchIPCError(.invalidRequest) }
        return value
    }
    public func projectPath(_ id: String) throws -> String {
        guard let value = try requestRead(.projectPath, params: ["schemaVersion": 1, "projectId": id]).projectPath else { throw WorkbenchIPCError(.invalidRequest) }
        return value
    }
    public func projectVersions(_ id: String) throws -> [WorkbenchSourceHistoryEntry] {
        guard let value = try requestRead(.projectVersions, params: ["schemaVersion": 1, "projectId": id]).sourceVersions else { throw WorkbenchIPCError(.invalidRequest) }
        return value
    }
    public func listPackages() throws -> [WorkbenchPackageSummary] {
        guard let value = try requestRead(.packageList, params: ["schemaVersion": 1]).packages else { throw WorkbenchIPCError(.invalidRequest) }
        return value
    }
    public func getPackage(dashboardId: String, revision: String? = nil) throws -> WorkbenchPackageRead {
        var params: [String: Any] = ["schemaVersion": 1, "dashboardId": dashboardId]
        if let revision { params["revision"] = revision }
        guard let value = try requestRead(.packageGet, params: params).package else { throw WorkbenchIPCError(.invalidRequest) }
        return value
    }
    public func validatePackage(dashboardId: String, revision: String? = nil) throws -> WorkbenchPackageRead {
        var params: [String: Any] = ["schemaVersion": 1, "dashboardId": dashboardId]
        if let revision { params["revision"] = revision }
        guard let value = try requestRead(.packageValidate, params: params).package else { throw WorkbenchIPCError(.invalidRequest) }
        return value
    }
    public func listDevices() throws -> [WorkbenchDeviceRead] {
        guard let value = try requestRead(.deviceList, params: ["schemaVersion": 1]).devices else { throw WorkbenchIPCError(.invalidRequest) }
        return value
    }
    public func listDevices(timeout: TimeInterval) throws -> [WorkbenchDeviceRead] {
        guard let value = try requestRead(.deviceList, params: ["schemaVersion": 1],
                                         timeout: timeout).devices else { throw WorkbenchIPCError(.invalidRequest) }
        return value
    }
    public func getDevice(deviceId: String) throws -> WorkbenchDeviceRead {
        guard let value = try requestRead(.deviceGet, params: ["schemaVersion": 1, "deviceId": deviceId]).device else { throw WorkbenchIPCError(.invalidRequest) }
        return value
    }
    public func freshDeviceScreenSet(deviceId: String) throws -> WorkbenchDeviceScreenSetRead {
        guard let value = try requestDevice(.screenSet, fields: ["deviceId": deviceId]).screenSet else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        return value
    }
    public func discoverDevices() throws -> [AdvertisedDevice] {
        guard let value = try requestDevice(.discover).discovered else { throw WorkbenchIPCError(.invalidRequest) }
        return value
    }
    public func addDevice(host: String, port: Int) throws -> AdvertisedDevice {
        guard let value = try requestDevice(.add, fields: ["host": host, "port": port]).endpoint else { throw WorkbenchIPCError(.invalidRequest) }
        return value
    }
    public func beginPairing(deviceId: String) throws -> WorkbenchPairingRead {
        guard let value = try requestDevice(.pairBegin, fields: ["deviceId": deviceId]).pairing else { throw WorkbenchIPCError(.invalidRequest) }
        return value
    }
    public func beginPairing(host: String, port: Int) throws -> WorkbenchPairingRead {
        guard let value = try requestDevice(.pairBegin, fields: ["host": host, "port": port]).pairing else { throw WorkbenchIPCError(.invalidRequest) }
        return value
    }
    public func pendingPairings() throws -> [WorkbenchPairingRead] {
        guard let value = try requestDevice(.pairPending).pending else { throw WorkbenchIPCError(.invalidRequest) }
        return value
    }
    public func confirmPairing(pendingId: String, matchingCode: String) throws -> WorkbenchDeviceRead {
        guard let value = try requestDevice(.pairConfirm, fields: ["pendingId": pendingId, "matchingCode": matchingCode]).device else { throw WorkbenchIPCError(.invalidRequest) }
        return value
    }
    public func cancelPairing(pendingId: String) throws {
        guard try requestDevice(.pairCancel, fields: ["pendingId": pendingId]).removed == true else { throw WorkbenchIPCError(.invalidRequest) }
    }
    public func forgetDevice(_ deviceId: String) throws -> Bool {
        guard let value = try requestDevice(.forget, fields: ["deviceId": deviceId]).removed else { throw WorkbenchIPCError(.invalidRequest) }
        return value
    }
    public func deviceStatus(_ deviceId: String, refresh: Bool) throws -> WorkbenchDeviceRead {
        guard let value = try requestDevice(.status, fields: ["deviceId": deviceId, "refresh": refresh]).device else { throw WorkbenchIPCError(.invalidRequest) }
        return value
    }
    public func deviceSettings(_ deviceId: String) throws -> DeviceSettingsSnapshot {
        guard let value = try requestDevice(.settingsGet, fields: ["deviceId": deviceId]).settings else { throw WorkbenchIPCError(.invalidRequest) }
        return value
    }
    public func updateDeviceSettings(_ deviceId: String, expectedRevision: String, value: DeviceSettings) throws -> DeviceSettingsSnapshot {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        guard let value = try requestDevice(.settingsSet, fields: ["deviceId": deviceId, "expectedRevision": expectedRevision, "value": object]).settings else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        return value
    }
    public func deviceConnections(_ deviceId: String) throws -> DeviceConnectionInventory {
        guard let value = try requestDevice(.connections, fields: ["deviceId": deviceId]).connections else { throw WorkbenchIPCError(.invalidRequest) }
        return value
    }
    public func configureConnection(deviceId: String, dashboardId: String, revision: String,
                                    grant: ConnectionGrant, auth: ConnectionAuthBinding,
                                    secret: Data?) throws -> WorkbenchConnectionIntentView {
        var fields: [String: Any] = ["deviceId": deviceId, "dashboardId": dashboardId, "revision": revision,
            "grant": try JSONSerialization.jsonObject(with: JSONEncoder().encode(grant)),
            "auth": try JSONSerialization.jsonObject(with: JSONEncoder().encode(auth))]
        if let secret { fields["secretBase64"] = secret.base64EncodedString() }
        guard let value = try requestConnection(.configure, fields: fields).intent else { throw WorkbenchIPCError(.invalidRequest) }
        return value
    }
    public func updateConnection(bindingId: String, expectedGrantGeneration: Int,
                                 grant: ConnectionGrant, auth: ConnectionAuthBinding) throws
        -> WorkbenchConnectionIntentView {
        let fields: [String: Any] = ["bindingId": bindingId,
            "expectedGrantGeneration": expectedGrantGeneration,
            "grant": try JSONSerialization.jsonObject(with: JSONEncoder().encode(grant)),
            "auth": try JSONSerialization.jsonObject(with: JSONEncoder().encode(auth))]
        guard let value = try requestConnection(.update, fields: fields).intent else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        return value
    }
    public func requestConnectionIntent(deviceId: String, dashboardId: String, revision: String,
                                        grant: ConnectionGrant, auth: ConnectionAuthBinding) throws -> WorkbenchConnectionIntentView {
        let fields: [String: Any] = ["deviceId": deviceId, "dashboardId": dashboardId,
            "revision": revision,
            "grant": try JSONSerialization.jsonObject(with: JSONEncoder().encode(grant)),
            "auth": try JSONSerialization.jsonObject(with: JSONEncoder().encode(auth))]
        guard let value = try requestConnection(.intentRequest, fields: fields).intent else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        return value
    }
    public func connectionIntent(_ id: String) throws -> WorkbenchConnectionIntentView {
        guard let value = try requestConnection(.intentInspect, fields: ["intentId": id]).intent else { throw WorkbenchIPCError(.invalidRequest) }
        return value
    }
    public func resolveConnectionIntent(_ id: String, approve: Bool) throws -> WorkbenchConnectionActionResult {
        try requestConnection(.intentResolve, fields: ["intentId": id, "approve": approve])
    }
    public func beginConnectionReview(intentId: String) throws -> WorkbenchConnectionReview {
        lock.lock(); defer { lock.unlock() }
        do {
            guard case .connectionReview(let review) = try call("connection.reviewBegin",
                params: ["schemaVersion": 1, "intentId": intentId]), review.intentId == intentId else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            try review.validate()
            return review
        } catch { closeLocked(); throw error }
    }
    public func confirmConnectionReview(_ review: WorkbenchConnectionReview) throws -> WorkbenchConnectionApplyResult {
        lock.lock(); defer { lock.unlock() }
        do {
            try review.validate()
            guard case .connectionAction(let result) = try call("connection.reviewConfirm", params: [
                "schemaVersion": 1, "reviewHandle": review.reviewHandle,
                "expectedDeclarationHash": review.declarationHash,
                "expectedAuthorizationContextHash": review.authorizationContextHash,
                "confirm": true
            ]), let applied = result.applied else { throw WorkbenchIPCError(.invalidRequest) }
            try result.validate(for: .intentResolve)
            return applied
        } catch { closeLocked(); throw error }
    }
    public func beginHomeAssistantReview(deviceId: String, dashboardId: String,
                                         revision: String, origin: String) throws
        -> WorkbenchHomeAssistantReview {
        lock.lock(); defer { lock.unlock() }
        do {
            guard case .homeAssistantReview(let review) = try call(
                WorkbenchHomeAssistantMethod.reviewBegin.rawValue, params: [
                    "schemaVersion": 1, "deviceId": deviceId,
                    "dashboardId": dashboardId, "revision": revision, "origin": origin
                ]), review.deviceId == deviceId, review.dashboardId == dashboardId,
                review.revision == revision, review.origin == origin else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            try review.validate()
            return review
        } catch { closeLocked(); throw error }
    }
    public func confirmHomeAssistantReview(_ review: WorkbenchHomeAssistantReview,
                                           secret: Data) throws -> WorkbenchHomeAssistantAttemptView {
        lock.lock(); defer { lock.unlock() }
        do {
            try review.validate()
            guard (1...8192).contains(secret.count),
                  case .homeAssistantAttempt(let attempt) = try call(
                    WorkbenchHomeAssistantMethod.reviewConfirm.rawValue, params: [
                        "schemaVersion": 1, "reviewHandle": review.reviewHandle,
                        "declarationHash": review.declarationHash,
                        "authorizationContextHash": review.authorizationContextHash,
                        "secretBase64": secret.base64EncodedString()
                    ], deadline: environment.clock.now() + 120),
                  attempt.intentId == review.intentId,
                  attempt.workspaceId == review.workspaceId,
                  attempt.selectionGeneration == review.selectionGeneration,
                  attempt.deviceId == review.deviceId,
                  attempt.dashboardId == review.dashboardId,
                  attempt.revision == review.revision,
                  attempt.packageDigest == review.packageDigest,
                  attempt.origin == review.origin,
                  attempt.connectionId == review.connectionId else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            try attempt.validate()
            return attempt
        } catch { closeLocked(); throw error }
    }
    public func homeAssistantStatus(intentId: String) throws -> WorkbenchHomeAssistantAttemptView {
        try homeAssistantAttempt(.status, intentId: intentId)
    }
    public func cancelHomeAssistantPrepared(intentId: String) throws -> WorkbenchHomeAssistantAttemptView {
        try homeAssistantAttempt(.cancelPrepared, intentId: intentId)
    }
    private func homeAssistantAttempt(_ method: WorkbenchHomeAssistantMethod,
                                      intentId: String) throws -> WorkbenchHomeAssistantAttemptView {
        lock.lock(); defer { lock.unlock() }
        do {
            guard UUID(uuidString: intentId) != nil,
                  case .homeAssistantAttempt(let attempt) = try call(method.rawValue,
                    params: ["schemaVersion": 1, "intentId": intentId]),
                  attempt.intentId == intentId else { throw WorkbenchIPCError(.invalidRequest) }
            try attempt.validate()
            return attempt
        } catch { closeLocked(); throw error }
    }
    public func listConnections(deviceId: String) throws -> [WorkbenchConnectionSummary] {
        guard let value = try requestConnection(.list, fields: ["deviceId": deviceId]).summaries else { throw WorkbenchIPCError(.invalidRequest) }
        return value
    }
    public func inspectConnection(_ id: String) throws -> WorkbenchConnectionSummary {
        guard let value = try requestConnection(.inspect, fields: ["bindingId": id]).summary else { throw WorkbenchIPCError(.invalidRequest) }
        return value
    }
    public func connectionScopeDraft(bindingId: String, workspaceId: String,
                                     selectionGeneration: Int) throws -> WorkbenchConnectionScopeDraft {
        guard let value = try requestConnection(.scopeDraft, fields: [
            "bindingId": bindingId, "workspaceId": workspaceId,
            "selectionGeneration": selectionGeneration]).scopeDraft,
              value.bindingId == bindingId, value.workspaceId == workspaceId,
              value.selectionGeneration == selectionGeneration else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        return value
    }
    public func testConnection(_ id: String) throws -> WorkbenchConnectionSummary {
        guard let value = try requestConnection(.test, fields: ["bindingId": id]).summary else { throw WorkbenchIPCError(.invalidRequest) }
        return value
    }
    public func removeConnection(_ id: String) throws -> WorkbenchConnectionSummary {
        guard let value = try requestConnection(.remove, fields: ["bindingId": id]).summary else { throw WorkbenchIPCError(.invalidRequest) }
        return value
    }
    public func revokeConnection(_ id: String) throws -> WorkbenchConnectionSummary {
        guard let value = try requestConnection(.revoke, fields: ["bindingId": id]).summary else { throw WorkbenchIPCError(.invalidRequest) }
        return value
    }
    /// Both MCP adapters must enter through this closed tool/field boundary.
    /// No caller-supplied RPC method, role or approval claim is forwarded.
    public func requestMCPRead(tool: String, arguments: [String: Any]) throws -> WorkbenchReadResult {
        let route = try WorkbenchMCPReadPolicy.route(tool: tool, arguments: arguments)
        guard let method = WorkbenchReadMethod(rawValue: route.method) else { throw WorkbenchIPCError(.methodNotFound) }
        return try requestRead(method, params: route.params)
    }
    private func requestSnapshot(_ method: String, timeout: TimeInterval? = nil) throws -> WorkbenchBrokerSnapshot {
        lock.lock(); defer { lock.unlock() }
        do {
            guard case .snapshot(let value) = try call(method, params: [:], deadline: timeout.map(readDeadline)) else { throw WorkbenchIPCError(.invalidRequest) }
            return value
        } catch { closeLocked(); throw error }
    }
    private func requestLifecycle(_ method: String, timeout: TimeInterval? = nil) throws -> WorkbenchServiceLifecycleResult {
        lock.lock(); defer { lock.unlock() }
        do {
            guard case .lifecycle(let value) = try call(method, params: ["schemaVersion": 1], deadline: timeout.map(readDeadline)) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            try value.validate(for: method)
            return value
        } catch { closeLocked(); throw error }
    }
    private func requestRead(_ method: WorkbenchReadMethod, params: [String: Any],
                             timeout: TimeInterval? = nil) throws -> WorkbenchReadResult {
        lock.lock(); defer { lock.unlock() }
        do {
            guard case .read(let value) = try call(method.rawValue, params: params, deadline: timeout.map(readDeadline)) else { throw WorkbenchIPCError(.invalidRequest) }
            return value
        } catch { closeLocked(); throw error }
    }
    private func requestDevice(_ method: WorkbenchDeviceControlMethod, fields: [String: Any] = [:]) throws -> WorkbenchDeviceActionResult {
        lock.lock(); defer { lock.unlock() }
        do {
            var params = fields; params["schemaVersion"] = 1
            guard case .deviceAction(let value) = try call(method.rawValue, params: params) else { throw WorkbenchIPCError(.invalidRequest) }
            try value.validate(for: method)
            return value
        } catch { closeLocked(); throw error }
    }
    private func requestConnection(_ method: WorkbenchConnectionControlMethod,
                                   fields: [String: Any] = [:]) throws -> WorkbenchConnectionActionResult {
        lock.lock(); defer { lock.unlock() }
        do {
            var params = fields; params["schemaVersion"] = 1
            guard case .connectionAction(let value) = try call(method.rawValue, params: params) else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            try value.validate(for: method)
            return value
        } catch { closeLocked(); throw error }
    }
    private func requestWorkspaceControl(_ method: String, params: [String: Any]) throws -> WorkbenchWorkspaceStatus {
        lock.lock(); defer { lock.unlock() }
        do {
            guard case .read(let value) = try call(method, params: params), value.kind == .workspace,
                  value.schemaVersion == 1, let workspace = value.workspace,
                  value.packages == nil, value.package == nil, value.devices == nil, value.device == nil else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            return workspace
        } catch { closeLocked(); throw error }
    }
    private func readDeadline(timeout: TimeInterval) throws -> TimeInterval {
        guard timeout.isFinite, timeout > 0 else { throw WorkbenchIPCError(.invalidConfiguration) }
        return environment.clock.now() + min(timeout, environment.limits.timeout)
    }
    private func call(_ method: String, params: [String: Any], deadline: TimeInterval? = nil,
                      requestId: String? = nil) throws -> WorkbenchRPCResult {
        guard fd >= 0, instanceId != nil else { throw WorkbenchIPCError(.disconnected) }
        let id = requestId ?? UUID().uuidString.lowercased()
        let data = try JSONSerialization.data(withJSONObject: ["apiVersion": "1.0", "requestId": id, "method": method, "params": params], options: [.sortedKeys])
        try WorkbenchSocket.writeFrame(fd, bytes: data, environment: environment, deadline: deadline)
        return try receive(requestId: id, method: method, deadline: deadline)
    }
    private func receive(requestId: String, method: String, deadline: TimeInterval? = nil) throws -> WorkbenchRPCResult {
        let data = try WorkbenchSocket.readFrame(fd, environment: environment, deadline: deadline)
        let object = try WorkbenchWireJSON.object(data,
            allowSourceChunk: method == WorkbenchSourceChunkRequest.method)
        guard object["apiVersion"] as? String == "1.0", object["requestId"] as? String == requestId else { throw WorkbenchIPCError(.invalidRequest) }
        let response: WorkbenchWireResponse
        do {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            decoder.userInfo[WorkbenchRPCResult.responseMethodKey] = method
            response = try decoder.decode(WorkbenchWireResponse.self, from: data)
        }
        catch { throw WorkbenchIPCError(.invalidRequest) }
        if response.ok {
            guard Set(object.keys) == ["apiVersion", "requestId", "ok", "result"],
                  let fields = object["result"] as? [String: Any],
                  let result = response.result, let instanceId else { throw WorkbenchIPCError(.invalidRequest) }
            switch result {
            case .snapshot(let snapshot):
                guard method == "authentication" || method == "service.stop" || WorkbenchMethodRegistry.supportedMethods.contains(method),
                      (Set(fields.keys) == ["apiVersion", "instanceId", "status", "supportedMethods", "workspaceState", "build", "devices", "screenshots"] ||
                       Set(fields.keys) == ["apiVersion", "instanceId", "status", "supportedMethods", "workspaceState", "build", "devices", "screenshots", "controllerHomePath"]),
                      snapshot.apiVersion == "1.0", snapshot.instanceId == instanceId, snapshot.status == "ready",
                      snapshot.supportedMethods == WorkbenchMethodRegistry.supportedMethods ||
                      snapshot.supportedMethods == WorkbenchMethodRegistry.supportedMethods + WorkbenchDomainMethodRegistry.availableReadMethods
                        + WorkbenchDomainMethodRegistry.availableWorkspaceMethods
                        + WorkbenchDeviceControlMethod.allCases.map(\.rawValue)
                        + WorkbenchConnectionControlMethod.allCases.map(\.rawValue)
                        + WorkbenchAuthoringRecoveryMethod.allCases.map(\.rawValue)
                        + [WorkbenchSourceTextRequest.method, WorkbenchSourceChunkRequest.method]
                        + WorkbenchPackageImportMethod.allCases.map(\.rawValue)
                        + WorkbenchLocalReviewMethod.allCases.map(\.rawValue)
                        + WorkbenchHomeAssistantMethod.allCases.map(\.rawValue)
                        + [WorkbenchWorkspaceOperationStatus.method]
                        + [WorkbenchWorkspaceOperationStatus.cancelMethod,
                           WorkbenchWorkspaceOperationList.method,
                           WorkbenchOperationInventory.listMethod,
                           WorkbenchOperationInventory.showMethod,
                           WorkbenchOperationInventory.cancelMethod,
                           WorkbenchRetainedDeploymentEvidenceRead.method,
                           WorkbenchDeviceLogRead.method,
                           WorkbenchNativeDoctorRead.method]
                        + [WorkbenchToolchainRequirementsRead.method,
                           WorkbenchToolchainInstallResult.method]
                        + WorkbenchWorkspacePackageMethod.allCases.map(\.rawValue)
                        + WorkbenchScreenMutationMethod.allCases.map(\.rawValue)
                        + WorkbenchDeploymentMethod.allCases.map(\.rawValue)
                        + WorkbenchGUIConsumerMethod.allCases.map(\.rawValue),
                      ["unconfigured", "selected", "unavailable"].contains(snapshot.workspaceState),
                      ["unavailable", "read-only"].contains(snapshot.devices),
                      snapshot.build == "unavailable", snapshot.screenshots == "unavailable"
                else { throw WorkbenchIPCError(.instanceMismatch) }
                guard snapshot.controllerHomePath == nil ||
                      (snapshot.controllerHomePath!.hasPrefix("/") && !snapshot.controllerHomePath!.contains("\0")) else {
                    throw WorkbenchIPCError(.invalidRequest)
                }
            case .read(let read):
                if let expected = WorkbenchReadMethod(rawValue: method) { try read.validate(for: expected) }
                else if method == "workspace.init" || method == "workspace.open" {
                    guard read.kind == .workspace, read.workspace != nil, read.schemaVersion == 1,
                          read.packages == nil, read.package == nil, read.devices == nil, read.device == nil,
                          read.coverage == nil, read.projects == nil, read.project == nil,
                          read.projectPath == nil, read.sourceVersions == nil else {
                        throw WorkbenchIPCError(.invalidRequest)
                    }
                } else { throw WorkbenchIPCError(.invalidRequest) }
            case .deviceAction(let action):
                guard let selected = WorkbenchDeviceControlMethod(rawValue: method) else { throw WorkbenchIPCError(.invalidRequest) }
                try action.validate(for: selected)
            case .connectionAction(let action):
                if method == "connection.reviewConfirm" { try action.validate(for: .intentResolve) }
                else {
                    guard let selected = WorkbenchConnectionControlMethod(rawValue: method) else {
                        throw WorkbenchIPCError(.invalidRequest)
                    }
                    try action.validate(for: selected)
                }
            case .lifecycle(let lifecycle):
                guard ["service.lifecycle", "service.drain", "service.prepareRemoval"].contains(method),
                      Set(fields.keys) == ["schemaVersion", "kind", "state", "activeJobIDs",
                                           "interruptedJobIDs", "authenticatedConnections",
                                           "guiConsumersKnown", "guiConsumers"] else {
                    throw WorkbenchIPCError(.invalidRequest)
                }
                try lifecycle.validate(for: method)
            case .authoringAction(let authoring):
                guard let selected = WorkbenchAuthoringRecoveryMethod(rawValue: method) else {
                    throw WorkbenchIPCError(.invalidRequest)
                }
                try authoring.validate(for: selected)
            case .sourceText(let source):
                guard method == WorkbenchSourceTextRequest.method,
                      WorkspaceValidation.id(source.workspaceId), source.selectionGeneration > 0,
                      WorkspaceValidation.id(source.projectId), WorkspaceValidation.member(source.path),
                      WorkspaceValidation.sha256(source.sourceVersion), source.text.utf8.count <= 2_048 else {
                    throw WorkbenchIPCError(.invalidRequest)
                }
            case .sourceChunk(let chunk):
                guard method == WorkbenchSourceChunkRequest.method,
                      Set(fields.keys) == ["schemaVersion", "workspaceId", "selectionGeneration",
                                           "projectId", "path", "sourceVersion", "fileSHA256",
                                           "fileBytes", "offset", "bytesBase64", "nextOffset", "complete"] else {
                    throw WorkbenchIPCError(.invalidRequest)
                }
                let request = try WorkbenchSourceChunkRequest(expectedWorkspaceId: chunk.workspaceId,
                    expectedSelectionGeneration: chunk.selectionGeneration,
                    projectId: chunk.projectId, path: chunk.path,
                    expectedSourceVersion: chunk.sourceVersion, offset: chunk.offset)
                try chunk.validate(for: request)
            case .packageImport(let imported):
                guard let selected = WorkbenchPackageImportMethod(rawValue: method),
                      (selected == .begin || selected == .chunk || selected == .status
                        ? Set(fields.keys) == ["schemaVersion", "kind", "uploadId", "nextFileIndex", "nextOffset"]
                        : selected == .commit
                            ? Set(fields.keys) == ["schemaVersion", "kind", "receipt"]
                            : Set(fields.keys) == ["schemaVersion", "kind", "aborted"]) else {
                    throw WorkbenchIPCError(.invalidRequest)
                }
                try imported.validate(for: selected)
            case .deploymentAction(let action):
                guard let selected = WorkbenchDeploymentMethod(rawValue: method),
                      action.schemaVersion == 1, action.kind == selected.rawValue,
                      WorkspaceValidation.id(action.workspaceId),
                      action.selectionGeneration > 0 else {
                    throw WorkbenchIPCError(.invalidRequest)
                }
            case .connectionReview(let review):
                guard method == "connection.reviewBegin" else { throw WorkbenchIPCError(.invalidRequest) }
                try review.validate()
            case .homeAssistantReview(let review):
                guard method == WorkbenchHomeAssistantMethod.reviewBegin.rawValue else {
                    throw WorkbenchIPCError(.invalidRequest)
                }
                try review.validate()
            case .homeAssistantAttempt(let attempt):
                guard [WorkbenchHomeAssistantMethod.reviewConfirm.rawValue,
                       WorkbenchHomeAssistantMethod.status.rawValue,
                       WorkbenchHomeAssistantMethod.cancelPrepared.rawValue].contains(method) else {
                    throw WorkbenchIPCError(.invalidRequest)
                }
                try attempt.validate()
            case .workspaceOperation(let operation):
                guard [WorkbenchWorkspaceOperationStatus.method,
                       WorkbenchWorkspaceOperationStatus.cancelMethod].contains(method),
                      Set(["schemaVersion", "operationId", "instanceId", "method",
                           "destination", "state", "phase", "cancellationRequested",
                           "copiedFiles", "totalFiles", "copiedBytes", "totalBytes"])
                          .isSubset(of: Set(fields.keys)),
                      Set(fields.keys).isSubset(of: Set(["schemaVersion", "operationId",
                          "instanceId", "workspaceId", "selectionGeneration", "method",
                          "destination", "state", "phase", "cancellationRequested",
                          "copiedFiles", "totalFiles", "copiedBytes", "totalBytes"])),
                      operation.instanceId == instanceId else {
                    throw WorkbenchIPCError(.invalidRequest)
                }
                try operation.validate()
            case .workspaceOperationList(let operations):
                guard method == WorkbenchWorkspaceOperationList.method,
                      Set(fields.keys) == ["schemaVersion", "instanceId", "scope", "complete", "operations"],
                      operations.instanceId == instanceId else {
                    throw WorkbenchIPCError(.invalidRequest)
                }
                try operations.validate()
            case .operationInventory(let inventory):
                guard method == WorkbenchOperationInventory.listMethod,
                      Set(fields.keys) == ["schemaVersion", "instanceId", "scope", "complete",
                                           "workspaceHistoryTruncated",
                                           "deploymentHistoryTruncated", "entries"],
                      inventory.instanceId == instanceId else {
                    throw WorkbenchIPCError(.invalidRequest)
                }
                try inventory.validate()
            case .operationEntry(let entry):
                guard [WorkbenchOperationInventory.showMethod,
                       WorkbenchOperationInventory.cancelMethod].contains(method),
                      Set(["schemaVersion", "operationId", "kind", "durability", "state",
                           "cancellationRequested"]).isSubset(of: Set(fields.keys)),
                      Set(fields.keys).isSubset(of: Set(["schemaVersion", "operationId", "kind",
                          "durability", "state", "cancellationRequested", "workspaceId",
                          "deviceId", "planId", "sendAttempted", "workspaceCopy"])) else {
                    throw WorkbenchIPCError(.invalidRequest)
                }
                try entry.validate()
            case .retainedDeploymentEvidence(let retained):
                guard method == WorkbenchRetainedDeploymentEvidenceRead.method,
                      Set(fields.keys) == ["schemaVersion", "kind", "workspaceId",
                                           "selectionGeneration", "deviceId", "provenance",
                                           "complete", "packages"] else {
                    throw WorkbenchIPCError(.invalidRequest)
                }
                try retained.validate()
            case .deviceLog(let log):
                guard method == WorkbenchDeviceLogRead.method,
                      Set(fields.keys) == ["schemaVersion", "deviceId", "scope",
                                           "complete", "truncated", "events"] else {
                    throw WorkbenchIPCError(.invalidRequest)
                }
                try log.validate()
            case .screenMutation(let screen):
                guard screen.method.rawValue == method else {
                    throw WorkbenchIPCError(.publicationOutcomeUnknown)
                }
                do { try screen.validateWireShape(fields) }
                catch { throw WorkbenchIPCError(.publicationOutcomeUnknown) }
            case .nativeDoctor(let doctor):
                guard method == WorkbenchNativeDoctorRead.method,
                      Set(fields.keys) == ["schemaVersion", "kind", "scope", "identityState",
                                           "identityPersistence", "networkTransport",
                                           "networkAuthorization", "complete"] else {
                    throw WorkbenchIPCError(.invalidRequest)
                }
                try doctor.validate()
            case .toolchainRequirements(let requirements):
                guard method == WorkbenchToolchainRequirementsRead.method,
                      Set(fields.keys) == ["schemaVersion", "kind", "workspaceId",
                                           "selectionGeneration", "required", "trust",
                                           "installation"] ||
                      (method == WorkbenchToolchainRequirementsRead.method &&
                       Set(fields.keys) == ["schemaVersion", "kind", "workspaceId",
                                            "selectionGeneration", "required", "trust",
                                            "installation", "installed"]) else {
                    throw WorkbenchIPCError(.invalidRequest)
                }
                try requirements.validate()
            case .toolchainInstall(let installation):
                guard method == WorkbenchToolchainInstallResult.method,
                      Set(fields.keys) == ["schemaVersion", "kind", "workspaceId",
                                           "selectionGeneration", "requiredCount",
                                           "installed", "complete"] else {
                    throw WorkbenchIPCError(.invalidRequest)
                }
                try installation.validate()
            case .workspacePackage(let result):
                guard WorkbenchWorkspacePackageMethod(rawValue: method) != nil,
                      result.kind == method else { throw WorkbenchIPCError(.invalidRequest) }
            case .guiConsumer(let result):
                guard let selected = WorkbenchGUIConsumerMethod(rawValue: method) else {
                    throw WorkbenchIPCError(.invalidRequest)
                }
                try result.validate(for: selected)
            }
            let canonical = try WorkbenchWireJSON.object(WorkbenchSocket.encode(result),
                allowSourceChunk: method == WorkbenchSourceChunkRequest.method)
            guard try JSONValue.from(fields) == JSONValue.from(canonical) else { throw WorkbenchIPCError(.invalidRequest) }
            return result
        }
        guard Set(object.keys) == ["apiVersion", "requestId", "ok", "error"],
              let fields = object["error"] as? [String: Any], Set(fields.keys) == ["code", "message"],
              let error = response.error else { throw WorkbenchIPCError(.invalidRequest) }
        throw error
    }
    public func close() { lock.lock(); closeLocked(); lock.unlock() }
    private func closeLocked() {
        if fd >= 0 { _ = Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
        fd = -1; instanceId = nil
    }
    deinit { close() }
}
#endif
