import Foundation
import ScreenpunkCore

#if os(macOS)
private final class WorkbenchHAAsyncOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<WorkbenchHomeAssistantAttemptView, Error>?
    func set(_ value: Result<WorkbenchHomeAssistantAttemptView, Error>) {
        lock.lock(); stored = value; lock.unlock()
    }
    func get() -> Result<WorkbenchHomeAssistantAttemptView, Error>? {
        lock.lock(); defer { lock.unlock() }; return stored
    }
}

private struct WorkbenchPackageImportSession {
    let uploadId: String
    let workspaceId: String
    let selectionGeneration: Int
    let digest: String
    let manifest: DashboardManifest
    var files: [String: Data] = [:]
    var fileIndex = 0
    var offset = 0
    var partial = Data()
    let deadlineAt: TimeInterval
    var expiresAt: TimeInterval
    init(workspaceId: String, selectionGeneration: Int, digest: String,
         manifest: DashboardManifest, now: TimeInterval) {
        uploadId = UUID().uuidString.lowercased()
        self.workspaceId = workspaceId; self.selectionGeneration = selectionGeneration
        self.digest = digest; self.manifest = manifest
        deadlineAt = now + 600
        expiresAt = now + 120
    }
}
#endif

/// The host supplies an already-selected domain and an explicit native adapter.
/// No constructor loads Keychain identity, starts LAN discovery or resolves a helper.
public struct WorkbenchNativeComposition {
    public let activate: (ControllerService) throws -> Void
    public let deactivate: () -> Void
    public let activateOnStart: Bool
    public init(activateOnStart: Bool = true, activate: @escaping (ControllerService) throws -> Void,
                deactivate: @escaping () -> Void) {
        self.activate = activate; self.deactivate = deactivate; self.activateOnStart = activateOnStart
    }
}

/// A single serial owner for read dispatch and later admitted domain operations.
/// The broker never exposes mutable ControllerService or DeviceCoordinator handles
/// to clients. A future runner must drain its own jobs before stopping this owner.
public final class WorkbenchBrokerDomain: @unchecked Sendable {
    private let controller: ControllerService
    private let workspace: WorkspaceStore?
    private let native: WorkbenchNativeComposition?
    private let initialAuthorityBoundary: WorkbenchAuthorityBoundary
    private let machineAuthorityPath: String?
    private let mutationGate: (() throws -> Void)?
    private let nativeDiagnostics: WorkbenchNativeDiagnosticProvider?
    #if os(macOS)
    private let secretProvider: any WorkbenchSecretProvider
    private let trustedCatalog: DurableToolchainCatalogStore?
    private let toolchainInstaller: ToolchainKitInstaller?
    private let connectionNow: () -> Date
    private var connectionDomain: WorkbenchConnectionDomain?
    private var deploymentDomain: WorkbenchDeploymentDomain?
    private var packageImportSession: WorkbenchPackageImportSession?
    private let deploymentPeerFactory: ((DeviceCoordinator) -> any WorkbenchDeploymentPeer)?
    private let deploymentClock: () -> WorkbenchDeploymentClock
    private let homeAssistantAttempts: (any WorkbenchHomeAssistantAttemptStore)?
    private let homeAssistantTransport: (any HTTPTransport)?
    private let homeAssistantResolver: any DestinationResolver
    private let homeAssistantProvisioner: ((String, HomeAssistantProvisioning) throws -> HomeAssistantProvisioningReceipt)?
    private var credentialCleanupTimer: DispatchSourceTimer?
    #endif
    private var deviceDomain: WorkbenchDeviceDomain?
    private var authoringRecoveryDomain: WorkbenchAuthoringRecoveryDomain?
    private var nativeActivated = false
    private var authorityBoundary: WorkbenchAuthorityBoundary {
        #if os(macOS)
        return connectionDomain?.authorityBoundary ?? initialAuthorityBoundary
        #else
        return initialAuthorityBoundary
        #endif
    }
    private let dispatchObserver: ((WorkbenchReadMethod) -> Void)?
    private let localReadTimeout: TimeInterval
    private let queue = DispatchQueue(label: "xyz.screenpunk.workbench.domain")
    private let activeLock = NSLock()
    private var active = false

    public convenience init(controller: ControllerService, workspace: WorkspaceStore? = nil,
                            native: WorkbenchNativeComposition? = nil,
                            machineAuthorityPath: String? = nil,
                            secrets: any WorkbenchSecretProvider = WorkbenchUnavailableSecretProvider(),
                            mutationGate: (() throws -> Void)? = nil,
                            connectionNow: @escaping () -> Date = { Date() },
                            homeAssistantAttempts: (any WorkbenchHomeAssistantAttemptStore)? = nil,
                            homeAssistantTransport: (any HTTPTransport)? = nil,
                            homeAssistantResolver: any DestinationResolver = LiteralOrResolvedDestinationResolver(),
                            homeAssistantProvisioner: ((String, HomeAssistantProvisioning) throws -> HomeAssistantProvisioningReceipt)? = nil,
                            installedReleaseTrust: WorkbenchInstalledReleaseTrust? = nil,
                            nativeDiagnostics: WorkbenchNativeDiagnosticProvider? = nil) {
        self.init(controller: controller, workspace: workspace, native: native, dispatchObserver: nil,
                  machineAuthorityPath: machineAuthorityPath, secrets: secrets,
                  mutationGate: mutationGate, connectionNow: connectionNow,
                  homeAssistantAttempts: homeAssistantAttempts,
                  homeAssistantTransport: homeAssistantTransport,
                  homeAssistantResolver: homeAssistantResolver,
                  homeAssistantProvisioner: homeAssistantProvisioner,
                  nativeDiagnostics: nativeDiagnostics,
                  trustedCatalog: installedReleaseTrust?.catalog,
                  toolchainInstaller: installedReleaseTrust?.installer)
    }
    // Deterministic serialization seam for tests; no peer can install it.
    init(controller: ControllerService, workspace: WorkspaceStore?, native: WorkbenchNativeComposition?,
         dispatchObserver: ((WorkbenchReadMethod) -> Void)?, localReadTimeout: TimeInterval = 15,
         authorityBoundary: WorkbenchAuthorityBoundary = WorkbenchAuthorityBoundary(),
         machineAuthorityPath: String? = nil,
         secrets: any WorkbenchSecretProvider = WorkbenchUnavailableSecretProvider(),
         mutationGate: (() throws -> Void)? = nil,
         deploymentPeerFactory: ((DeviceCoordinator) -> any WorkbenchDeploymentPeer)? = nil,
         deploymentClock: @escaping () -> WorkbenchDeploymentClock = { WorkbenchTrustedClock().sample() },
         connectionNow: @escaping () -> Date = { Date() },
         homeAssistantAttempts: (any WorkbenchHomeAssistantAttemptStore)? = nil,
         homeAssistantTransport: (any HTTPTransport)? = nil,
         homeAssistantResolver: any DestinationResolver = LiteralOrResolvedDestinationResolver(),
         homeAssistantProvisioner: ((String, HomeAssistantProvisioning) throws -> HomeAssistantProvisioningReceipt)? = nil,
         nativeDiagnostics: WorkbenchNativeDiagnosticProvider? = nil,
         trustedCatalog: DurableToolchainCatalogStore? = nil,
         toolchainInstaller: ToolchainKitInstaller? = nil) {
        self.controller = controller; self.workspace = workspace; self.native = native
        self.dispatchObserver = dispatchObserver; self.localReadTimeout = localReadTimeout
        self.initialAuthorityBoundary = authorityBoundary
        self.machineAuthorityPath = machineAuthorityPath
        self.secretProvider = secrets
        self.trustedCatalog = trustedCatalog ?? toolchainInstaller?.catalog
        self.toolchainInstaller = toolchainInstaller
        self.connectionNow = connectionNow
        self.deploymentPeerFactory = deploymentPeerFactory
        self.deploymentClock = deploymentClock
        self.homeAssistantAttempts = homeAssistantAttempts
        self.homeAssistantTransport = homeAssistantTransport
        self.homeAssistantResolver = homeAssistantResolver
        self.homeAssistantProvisioner = homeAssistantProvisioner
        self.mutationGate = mutationGate
        self.nativeDiagnostics = nativeDiagnostics
    }

    func start() throws {
        try queue.sync {
            guard !active else { throw WorkbenchIPCError(.alreadyRunning) }
            do {
                if native?.activateOnStart == true { try native?.activate(controller); nativeActivated = true }
            }
            catch {
                // Activation may have attached resources before failing. Composition
                // cleanup must therefore also be safe after partial activation.
                native?.deactivate(); nativeActivated = false
                throw WorkbenchIPCError(.unavailable)
            }
            activeLock.lock(); active = true; activeLock.unlock()
        }
    }

    func stop() {
        queue.sync {
            activeLock.lock(); let wasActive = active; active = false; activeLock.unlock()
            guard wasActive else { return }
            if nativeActivated { native?.deactivate(); nativeActivated = false }
            deviceDomain = nil
            #if os(macOS)
            credentialCleanupTimer?.cancel(); credentialCleanupTimer = nil
            connectionDomain = nil
            deploymentDomain = nil
            packageImportSession = nil
            #endif
        }
    }

    func snapshot(instanceId: String, cancelled: @escaping () -> Bool = { false }) throws -> WorkbenchBrokerSnapshot {
        activeLock.lock(); let isActive = active; activeLock.unlock()
        guard isActive else { throw WorkbenchIPCError(.unavailable) }
        // Health/hello never wait behind a long domain read. An incomplete workspace
        // inspection reports unavailable instead of claiming a selected workspace.
        let budget = WorkspaceReadBudget(deadline: ProcessInfo.processInfo.systemUptime + min(localReadTimeout, 0.2),
                                         cancelled: cancelled)
        let state: String
        do { state = try workspace?.current(readBudget: budget) == nil ? "unconfigured" : "selected" }
        catch { state = "unavailable" }
        return WorkbenchBrokerSnapshot(
            instanceId: instanceId,
            supportedMethods: WorkbenchMethodRegistry.supportedMethods + WorkbenchDomainMethodRegistry.availableReadMethods
                + WorkbenchDomainMethodRegistry.availableWorkspaceMethods
                + WorkbenchDeviceControlMethod.allCases.map(\.rawValue)
                + WorkbenchConnectionControlMethod.allCases.map(\.rawValue)
                + WorkbenchAuthoringRecoveryMethod.allCases.map(\.rawValue)
                + [WorkbenchSourceTextRequest.method, WorkbenchSourceChunkRequest.method]
                + WorkbenchPackageImportMethod.allCases.map(\.rawValue)
                + WorkbenchLocalReviewMethod.allCases.map(\.rawValue)
                + WorkbenchHomeAssistantMethod.allCases.map(\.rawValue)
                + [WorkbenchWorkspaceOperationStatus.method,
                   WorkbenchWorkspaceOperationStatus.cancelMethod,
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
            workspaceState: state,
            devices: "read-only",
            controllerHomePath: controller.store.root.resolvingSymlinksInPath().path
        )
    }

    func nativeDoctor() throws -> WorkbenchNativeDoctorRead {
        try queue.sync {
            activeLock.lock(); let isActive = active; activeLock.unlock()
            guard isActive else { throw WorkbenchIPCError(.unavailable) }
            // These are only observations already held by this owner. Neither
            // property loads Keychain state, attaches a link, nor starts LAN.
            let attached = controller.devices.transportAvailable
            let loaded = controller.devices.controllerIdentity != nil
            let authorization = nativeDiagnostics?.networkAuthorization() ?? .notAssessed
            let result = WorkbenchNativeDoctorRead(identityLoaded: loaded,
                transportAttached: attached, authorization: authorization)
            try result.validate()
            return result
        }
    }

    func performDevice(_ request: WorkbenchDeviceControlRequest,
                       cancelled: @escaping () -> Bool = { false }) throws -> WorkbenchDeviceActionResult {
        let budget = DashboardReadBudget(deadline: ProcessInfo.processInfo.systemUptime + localReadTimeout,
                                         cancelled: cancelled)
        return try queue.sync {
            activeLock.lock(); let isActive = active; activeLock.unlock()
            guard isActive else { throw WorkbenchIPCError(.unavailable) }
            try budget.check()
            do {
                try mutationGate?()
                let domain = try ensureDeviceDomain()
                try budget.check()
                let result: WorkbenchDeviceActionResult
                switch request {
                case .discover: result = .init(kind: "discovered", discovered: domain.discover())
                case .add(let host, let port): result = .init(kind: "endpoint", endpoint: try domain.registerEndpoint(host: host, port: port))
                case .pairBegin(let id, let host, let port):
                    result = .init(kind: "pairing", pairing: WorkbenchPairingRead(try domain.beginPairing(deviceId: id, host: host, port: port)))
                case .pairPending: result = .init(kind: "pending", pending: domain.pendingPairings().map(WorkbenchPairingRead.init))
                case .pairConfirm(let pendingId, let code):
                    let record = try domain.confirmPairing(pendingId: pendingId, matchingCode: code)
                    result = .init(kind: "device", device: WorkbenchDeviceRead(record, currentIdentity: controller.devices.controllerIdentity))
                case .pairCancel(let pendingId):
                    try domain.cancelPairing(pendingId: pendingId)
                    result = .init(kind: "removed", removed: true)
                case .forget(let id): result = .init(kind: "removed", removed: try domain.forget(deviceId: id))
                case .status(let id, let refresh):
                    let record = try domain.status(deviceId: id, refresh: refresh)
                    result = .init(kind: "device", device: WorkbenchDeviceRead(record, currentIdentity: controller.devices.controllerIdentity))
                case .settingsGet(let id): result = .init(kind: "settings", settings: try domain.settingsGet(deviceId: id))
                case .settingsSet(let id, let revision, let value):
                    result = .init(kind: "settings", settings: try domain.settingsUpdate(deviceId: id, expectedRevision: revision, value: value))
                case .connections(let id): result = .init(kind: "connections", connections: try domain.connectionInventory(deviceId: id))
                case .screenSet(let id):
                    let (profile, screens, selected, observedAt, name) = try controller.devices.observeScreenSet(id)
                    result = .init(kind: "screenSet", screenSet: try .init(deviceId: id,
                        name: name, profile: profile, screens: screens,
                        selectedDashboardId: selected, observedAt: observedAt))
                }
                try budget.check()
                try result.validate(for: request.method)
                _ = try WorkbenchWireJSON.object(WorkbenchSocket.encode(result))
                return result
            } catch let error as WorkbenchIPCError { throw error }
            catch { throw WorkbenchIPCError(.unavailable) }
        }
    }

    private func ensureDeviceDomain() throws -> WorkbenchDeviceDomain {
        if nativeActivated && !controller.devices.transportAvailable {
            resetNativeOwner()
        }
        if let deviceDomain { return deviceDomain }
        if !nativeActivated {
            do { try native?.activate(controller); nativeActivated = native != nil }
            catch { resetNativeOwner(); throw WorkbenchIPCError(.unavailable) }
        }
        #if os(macOS)
        if let machineAuthorityPath, let workspace {
            let connection = try WorkbenchConnectionDomain(machineAuthorityPath: machineAuthorityPath,
                devices: controller.devices, workspace: workspace, secrets: secretProvider,
                now: connectionNow)
            connectionDomain = connection
            try? connection.reapExpiredManagedIntents()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 60, repeating: 60)
            timer.setEventHandler { [weak self] in
                try? self?.connectionDomain?.reapExpiredManagedIntents()
            }
            credentialCleanupTimer = timer
            timer.resume()
            let device = connection.deviceDomain()
            deviceDomain = device
            return device
        }
        #endif
        let device = WorkbenchDeviceDomain(devices: controller.devices)
        deviceDomain = device
        return device
    }

    private func resetNativeOwner() {
        native?.deactivate()
        nativeActivated = false
        deviceDomain = nil
        #if os(macOS)
        credentialCleanupTimer?.cancel(); credentialCleanupTimer = nil
        connectionDomain = nil
        deploymentDomain = nil
        #endif
    }

    func performConnection(_ request: WorkbenchConnectionControlRequest,
                           ordinaryProposal: Bool = false,
                           cancelled: @escaping () -> Bool = { false }) throws -> WorkbenchConnectionActionResult {
        // A same-UID authenticated socket is not a trusted human-approval
        // channel. No wire Boolean may mint a local approval capability.
        if case .intentResolve(_, true) = request { throw WorkbenchIPCError(.confirmationRequired) }
        let budget = DashboardReadBudget(deadline: ProcessInfo.processInfo.systemUptime + localReadTimeout,
                                         cancelled: cancelled)
        return try queue.sync {
            activeLock.lock(); let isActive = active; activeLock.unlock()
            guard isActive else { throw WorkbenchIPCError(.unavailable) }
            try budget.check()
            do {
                try mutationGate?()
                _ = try ensureDeviceDomain()
                guard let domain = connectionDomain else { throw WorkbenchIPCError(.unavailable) }
                try budget.check()
                let result: WorkbenchConnectionActionResult
                switch request {
                case .intentRequest(let deviceId, let dashboardId, let revision, var grant, var auth):
                    let originalGrant = grant
                    let originalAuth = auth
                    guard let owner = controller.devices.controllerIdentity else { throw WorkbenchIPCError(.unavailable) }
                    let ref = WorkbenchSecretReference.make(ownerPin: PeerPin.hex(owner.publicKey),
                        deviceId: deviceId, credentialId: UUID())
                    grant.authRef = ref; auth.authRef = ref
                    try budget.check()
                    result = .init(kind: "intent", intent: try domain.hostRequestGenericIntent(
                        deviceId: deviceId, dashboardId: dashboardId, revision: revision,
                        grant: grant, auth: auth,
                        originalGrant: originalGrant, originalAuth: originalAuth))
                case .configure(let deviceId, let dashboardId, let revision, var grant, var auth, let secret):
                    guard let owner = controller.devices.controllerIdentity else { throw WorkbenchIPCError(.unavailable) }
                    let ref = WorkbenchSecretReference.make(ownerPin: PeerPin.hex(owner.publicKey),
                        deviceId: deviceId, credentialId: UUID())
                    grant.authRef = ref; auth.authRef = ref
                    try budget.check()
                    result = .init(kind: "intent", intent: try domain.hostConfigureGenericIntent(
                        deviceId: deviceId, dashboardId: dashboardId, revision: revision,
                        grant: grant, auth: auth, secret: secret))
                case .update(let bindingId, let expectedGeneration, let grant, let auth):
                    try budget.check()
                    result = .init(kind: "intent", intent: try domain.hostUpdateGenericIntent(
                        bindingId: bindingId, expectedGrantGeneration: expectedGeneration,
                        grant: grant, auth: auth,
                        ordinaryProposal: ordinaryProposal))
                case .intentInspect(let id): result = .init(kind: "intent", intent: try domain.inspectIntent(id))
                case .intentResolve(let id, let approve):
                    guard !approve else { throw WorkbenchIPCError(.confirmationRequired) }
                    let applied = try domain.resolveGenericIntent(id, approve: approve,
                        capability: .hostTerminalOrGUI())
                    result = applied.map { .init(kind: "resolution", applied: $0) } ?? .init(kind: "resolution", denied: true)
                case .list(let id): result = .init(kind: "summaries", summaries: try domain.list(deviceId: id))
                case .inspect(let id): result = .init(kind: "summary", summary: try domain.inspect(bindingId: id))
                case .scopeDraft(let id, let workspaceId, let selectionGeneration):
                    result = .init(kind: "scope_draft", scopeDraft: try domain.scopeDraft(
                        bindingId: id, workspaceId: workspaceId,
                        selectionGeneration: selectionGeneration))
                case .test(let id): result = .init(kind: "summary", summary: try domain.test(bindingId: id))
                case .remove(let id):
                    result = .init(kind: "summary", summary: try domain.removeLocal(
                        bindingId: id, capability: .hostTerminalOrGUI()))
                case .revoke(let id):
                    result = .init(kind: "summary", summary: try domain.revoke(
                        bindingId: id, capability: .hostTerminalOrGUI()))
                }
                do {
                    try budget.check()
                    try result.validate(for: request.method)
                    _ = try WorkbenchWireJSON.object(WorkbenchSocket.encode(result))
                } catch {
                    // A configure result that cannot be returned must not leave
                    // an unobservable pending credential behind. Denial is local
                    // and removes only this intent's fresh secret reference.
                    if let intentId = result.intent?.intentId {
                        switch request {
                        case .configure, .update, .intentRequest:
                            _ = try domain.resolveGenericIntent(intentId, approve: false,
                                capability: .hostTerminalOrGUI())
                        default: break
                        }
                    }
                    throw error
                }
                return result
            } catch let error as WorkbenchIPCError { throw error }
            catch let error as WorkbenchAuthorityError where error == .staleContext {
                throw WorkbenchIPCError(.workspaceConflict)
            }
            catch let error as WorkbenchAuthorityError where error == .intentCapacity {
                throw WorkbenchIPCError(.resourceLimit)
            }
            catch let error as WorkbenchAuthorityError where error == .credentialCleanupRequired {
                throw WorkbenchIPCError(.credentialCleanupRequired)
            }
            catch { throw WorkbenchIPCError(.unavailable) }
        }
    }

    func beginConnectionReview(intentId: String, cancelled: @escaping () -> Bool = { false }) throws -> WorkbenchLocalReviewTicket {
        try queue.sync {
            do {
            activeLock.lock(); let isActive = active; activeLock.unlock()
            guard isActive, !cancelled() else { throw WorkbenchIPCError(.disconnected) }
            _ = try ensureDeviceDomain()
            guard let domain = connectionDomain else { throw WorkbenchIPCError(.unavailable) }
            var random = SystemRandomNumberGenerator()
            let handle = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) })
                .base64EncodedString()
            let review = try domain.makeLocalReview(intentId: intentId, handle: handle)
            let lifetime = min(300, max(0, review.reviewExpiresAt.timeIntervalSinceNow))
            guard lifetime > 0 else { throw WorkbenchIPCError(.confirmationRequired) }
            return WorkbenchLocalReviewTicket(review: review,
                deadlineUptime: ProcessInfo.processInfo.systemUptime + lifetime)
            } catch let error as WorkbenchIPCError { throw error }
            catch { throw WorkbenchIPCError(.confirmationRequired) }
        }
    }

    func confirmConnectionReview(_ ticket: WorkbenchLocalReviewTicket,
                                 cancelled: @escaping () -> Bool = { false }) throws -> WorkbenchConnectionActionResult {
        try queue.sync {
            do {
            activeLock.lock(); let isActive = active; activeLock.unlock()
            guard isActive, !cancelled() else { throw WorkbenchIPCError(.disconnected) }
            guard ProcessInfo.processInfo.systemUptime < ticket.deadlineUptime else {
                throw WorkbenchIPCError(.confirmationRequired)
            }
            try mutationGate?()
            _ = try ensureDeviceDomain()
            guard let domain = connectionDomain else { throw WorkbenchIPCError(.unavailable) }
            let applied = try domain.confirmLocalReview(ticket.review)
            return .init(kind: "resolution", applied: applied)
            } catch let error as WorkbenchIPCError { throw error }
            catch let error as WorkbenchAuthorityError where error == .remoteOutcomeUnknown {
                throw WorkbenchIPCError(.remoteOutcomeUnknown)
            }
            catch let error as WorkbenchAuthorityError where error == .credentialCleanupRequired {
                throw WorkbenchIPCError(.credentialCleanupRequired)
            }
            catch { throw WorkbenchIPCError(.confirmationRequired) }
        }
    }

    private func homeAssistantContext(deviceId: String, dashboardId: String,
                                      revision: String, connection: WorkbenchConnectionDomain)
        throws -> (WorkbenchHomeAssistantContext, DashboardManifest,
                   (contextHash: String, ownerPin: String, devicePin: String, pairingEpoch: String)) {
        activeLock.lock(); let isActive = active; activeLock.unlock()
        guard isActive, let workspace, let selected = try workspace.current(),
              let generation = selected.selectionGeneration else {
            throw WorkbenchIPCError(.workspaceConflict)
        }
        let package = try WorkbenchPortablePackages(workspace: workspace).get(
            dashboardId: dashboardId, revision: revision)
        let manifest = package.manifest
        guard let digest = manifest.digest, WorkspaceValidation.sha256(digest),
              try DeploymentDigest.digest(for: manifest) == digest,
              manifest.connections.filter({ $0.alias == "home" }).count == 1 else {
            throw WorkbenchIPCError(.invalidRequest)
        }
        let authority = try connection.homeAssistantAuthority(deviceId: deviceId)
        let context = WorkbenchHomeAssistantContext(workspaceId: selected.descriptor.workspaceId,
            selectionGeneration: generation, deviceId: deviceId,
            dashboardId: dashboardId, revision: revision, packageDigest: digest,
            authorizationContextHash: authority.contextHash)
        return (context, manifest, authority)
    }

    func beginHomeAssistantReview(deviceId: String, dashboardId: String,
                                  revision: String, origin: String,
                                  cancelled: @escaping () -> Bool = { false }) throws
        -> WorkbenchHomeAssistantReviewTicket {
        try queue.sync {
            do {
            guard !cancelled(), let homeAssistantAttempts,
                  homeAssistantTransport != nil, homeAssistantProvisioner != nil else {
                throw WorkbenchIPCError(.methodNotFound)
            }
            _ = homeAssistantAttempts
            try mutationGate?()
            _ = try ensureDeviceDomain()
            guard let connectionDomain else { throw WorkbenchIPCError(.unavailable) }
            guard let components = URLComponents(string: origin),
                  ["http", "https"].contains(components.scheme ?? ""),
                  components.host != nil, components.user == nil,
                  components.password == nil, components.query == nil,
                  components.fragment == nil,
                  components.path.isEmpty || components.path == "/",
                  origin.utf8.count <= 2048 else {
                throw WorkbenchIPCError(.invalidRequest)
            }
            let (context, manifest, authority) = try homeAssistantContext(
                deviceId: deviceId, dashboardId: dashboardId,
                revision: revision, connection: connectionDomain)
            var random = SystemRandomNumberGenerator()
            let handle = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) })
                .base64EncodedString()
            let review = try WorkbenchHomeAssistantReview(handle: handle,
                intentId: UUID().uuidString.lowercased(), context: context,
                ownerPin: authority.ownerPin, devicePin: authority.devicePin,
                pairingEpoch: authority.pairingEpoch, origin: origin,
                connectionId: UUID().uuidString.lowercased(),
                declaration: manifest.connections.first(where: { $0.alias == "home" })!,
                reviewExpiresAt: connectionNow().addingTimeInterval(300))
            return .init(review: review, manifest: manifest,
                deadlineUptime: ProcessInfo.processInfo.systemUptime + 300)
            } catch let error as WorkbenchIPCError { throw error }
            catch let error as WorkbenchAuthorityError where error == .staleContext {
                throw WorkbenchIPCError(.workspaceConflict)
            }
            catch { throw WorkbenchIPCError(.unavailable) }
        }
    }

    func confirmHomeAssistantReview(_ ticket: WorkbenchHomeAssistantReviewTicket,
                                    secret: Data,
                                    cancelled: @escaping () -> Bool = { false }) throws
        -> WorkbenchHomeAssistantAttemptView {
        let prepared: (WorkbenchHomeAssistantSetupAdapter,
                       WorkbenchHomeAssistantReviewedSetup) = try queue.sync {
            do {
            guard !cancelled(), ProcessInfo.processInfo.systemUptime < ticket.deadlineUptime,
                  connectionNow() < ticket.review.reviewExpiresAt,
                  (1...8192).contains(secret.count),
                  let attempts = homeAssistantAttempts,
                  let transport = homeAssistantTransport,
                  let provisioner = homeAssistantProvisioner else {
                throw WorkbenchIPCError(.confirmationRequired)
            }
            try mutationGate?()
            _ = try ensureDeviceDomain()
            guard let connectionDomain else { throw WorkbenchIPCError(.unavailable) }
            let current = try homeAssistantContext(deviceId: ticket.review.deviceId,
                dashboardId: ticket.review.dashboardId,
                revision: ticket.review.revision, connection: connectionDomain)
            guard current.0 == ticket.review.context,
                  current.1 == ticket.manifest,
                  current.2.ownerPin == ticket.review.ownerPin,
                  current.2.devicePin == ticket.review.devicePin,
                  current.2.pairingEpoch == ticket.review.pairingEpoch,
                  current.1.connections.first(where: { $0.alias == "home" }) == ticket.review.declaration else {
                throw WorkbenchIPCError(.workspaceConflict)
            }
            let review = WorkbenchHomeAssistantReviewedSetup(intentId: ticket.review.intentId,
                context: ticket.review.context, origin: ticket.review.origin,
                connectionId: ticket.review.connectionId,
                expiresAt: ticket.review.reviewExpiresAt)
            let adapter = WorkbenchHomeAssistantSetupAdapter(secrets: secretProvider,
                attempts: attempts, transport: transport, resolver: homeAssistantResolver,
                context: { [weak self] in
                    guard let self else { throw WorkbenchHomeAssistantSetupFailure.staleContext }
                    do {
                        return try self.homeAssistantContext(deviceId: ticket.review.deviceId,
                            dashboardId: ticket.review.dashboardId,
                            revision: ticket.review.revision,
                            connection: connectionDomain).0
                    } catch { throw WorkbenchHomeAssistantSetupFailure.staleContext }
                }, provision: { [weak self] deviceId, configuration in
                    guard let self else { throw WorkbenchHomeAssistantSetupFailure.staleContext }
                    // The asynchronous credential load and task scheduling can
                    // outlive the selected workspace or pairing. Check the full
                    // review again at the last local boundary before the device
                    // call, including fields omitted from the context digest.
                    // The native provider is synchronous, so the first send
                    // remains inside the same authority/selection boundary.
                    return try self.queue.sync {
                        try self.authorityBoundary.withDevice(deviceId) {
                            try self.mutationGate?()
                            let current = try self.homeAssistantContext(
                                deviceId: ticket.review.deviceId,
                                dashboardId: ticket.review.dashboardId,
                                revision: ticket.review.revision,
                                connection: connectionDomain)
                            guard current.0 == ticket.review.context,
                                  current.1 == ticket.manifest,
                                  current.2.ownerPin == ticket.review.ownerPin,
                                  current.2.devicePin == ticket.review.devicePin,
                                  current.2.pairingEpoch == ticket.review.pairingEpoch,
                                  current.1.connections.first(where: { $0.alias == "home" }) == ticket.review.declaration,
                                  deviceId == ticket.review.deviceId,
                                  configuration.provisioningId.isEmpty == false else {
                                throw WorkbenchHomeAssistantSetupFailure.staleContext
                            }
                            return try provisioner(deviceId, configuration)
                        }
                    }
                }, now: connectionNow)
            return (adapter, review)
            } catch let error as WorkbenchIPCError { throw error }
            catch let error as WorkbenchAuthorityError where error == .staleContext {
                throw WorkbenchIPCError(.workspaceConflict)
            }
            catch { throw WorkbenchIPCError(.unavailable) }
        }
        let outcome = WorkbenchHAAsyncOutcome()
        let completed = DispatchSemaphore(value: 0)
        let task = Task {
            do {
                _ = try await prepared.0.prepare(review: prepared.1,
                    manifest: ticket.manifest, secret: secret,
                    capability: .hostTerminalOrGUI())
                try mutationGate?()
                let installed = try await prepared.0.submit(intentId: ticket.review.intentId,
                    manifest: ticket.manifest, capability: .hostTerminalOrGUI())
                outcome.set(.success(.init(installed)))
            } catch { outcome.set(.failure(error)) }
            completed.signal()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 120
        while completed.wait(timeout: .now() + 0.1) == .timedOut {
            if cancelled() || ProcessInfo.processInfo.systemUptime >= deadline {
                task.cancel()
                throw WorkbenchIPCError(.remoteOutcomeUnknown)
            }
        }
        guard let result = outcome.get() else { throw WorkbenchIPCError(.remoteOutcomeUnknown) }
        do { return try result.get() }
        catch let failure as WorkbenchHomeAssistantSetupFailure {
            switch failure {
            case .unknownRemoteOutcome, .invalidReceipt: throw WorkbenchIPCError(.remoteOutcomeUnknown)
            case .cleanupPending: throw WorkbenchIPCError(.credentialCleanupRequired)
            case .staleContext, .conflict: throw WorkbenchIPCError(.workspaceConflict)
            case .expired, .invalidReview: throw WorkbenchIPCError(.confirmationRequired)
            case .invalidAPI: throw WorkbenchIPCError(.connectionValidationFailed)
            }
        } catch { throw WorkbenchIPCError(.connectionValidationFailed) }
    }

    func homeAssistantStatus(intentId: String) throws -> WorkbenchHomeAssistantAttemptView {
        do {
            guard let attempts = homeAssistantAttempts,
                  let attempt = try attempts.load(intentId: intentId) else {
                throw WorkbenchIPCError(.unavailable)
            }
            return .init(attempt)
        } catch let error as WorkbenchIPCError { throw error }
        catch { throw WorkbenchIPCError(.unavailable) }
    }

    func cancelHomeAssistantPrepared(intentId: String) throws -> WorkbenchHomeAssistantAttemptView {
        try queue.sync {
            do {
            try mutationGate?()
            guard let attempts = homeAssistantAttempts,
                  let transport = homeAssistantTransport,
                  let provisioner = homeAssistantProvisioner else {
                throw WorkbenchIPCError(.methodNotFound)
            }
            let adapter = WorkbenchHomeAssistantSetupAdapter(secrets: secretProvider,
                attempts: attempts, transport: transport, resolver: homeAssistantResolver,
                context: { throw WorkbenchHomeAssistantSetupFailure.staleContext },
                provision: provisioner, now: connectionNow)
            do { try adapter.cancelPrepared(intentId: intentId,
                capability: .hostTerminalOrGUI()) }
            catch WorkbenchHomeAssistantSetupFailure.cleanupPending {
                throw WorkbenchIPCError(.credentialCleanupRequired)
            }
            guard let attempt = try attempts.load(intentId: intentId) else {
                throw WorkbenchIPCError(.unavailable)
            }
            return .init(attempt)
            } catch let error as WorkbenchIPCError { throw error }
            catch WorkbenchHomeAssistantSetupFailure.conflict {
                throw WorkbenchIPCError(.workspaceConflict)
            }
            catch {
                if let pending = try? homeAssistantAttempts?.load(intentId: intentId),
                   pending.phase == .cleanupPending {
                    throw WorkbenchIPCError(.credentialCleanupRequired)
                }
                throw WorkbenchIPCError(.unavailable)
            }
        }
    }

    func performScreenMutation(_ request: WorkbenchScreenMutationRequest) throws
        -> WorkbenchScreenMutationResult {
        try queue.sync {
            activeLock.lock(); let isActive = active; activeLock.unlock()
            guard isActive, let workspace else { throw WorkbenchIPCError(.unavailable) }
            guard let mutationGate else { throw WorkbenchIPCError(.incompatibleOwner) }
            do {
                return try authorityBoundary.withWorkspaceSelection {
                    try mutationGate()
                    let result: WorkbenchScreenMutationResult
                    switch request {
                    case .sourceRename(let input):
                        result = .sourceRename(try WorkbenchScreenRenameDomain(workspace: workspace).rename(input))
                    case .packageRename(let input):
                        result = .packageRename(try WorkbenchScreenPackageRenameDomain(workspace: workspace).rename(input))
                    case .packageDuplicate(let input):
                        result = .packageDuplicate(try WorkbenchScreenPackageDuplicateDomain(workspace: workspace).duplicate(input))
                    case .packageOrientation(let input):
                        result = .packageOrientation(try WorkbenchScreenPackageOrientationDomain(workspace: workspace).set(input))
                    case .iconSet(let input):
                        result = .iconSet(try WorkbenchScreenIconDomain(workspace: workspace).set(input))
                    case .archive(let input):
                        result = .archive(try WorkbenchScreenArchiveDomain(workspace: workspace).archive(input))
                    case .reactSourceAssociate(let input):
                        result = .reactSourceAssociate(try WorkbenchReactSourceAssociationDomain(
                            workspace: workspace).attach(input))
                    }
                    do {
                        try result.validate(for: request)
                        _ = try WorkbenchWireJSON.object(WorkbenchSocket.encode(result))
                    } catch { throw WorkbenchIPCError(.publicationOutcomeUnknown) }
                    return result
                }
            } catch is WorkspaceAppliedMutationReadUnavailable {
                throw WorkbenchIPCError(.publicationOutcomeUnknown)
            } catch let error as WorkspaceError {
                switch error {
                case .conflict: throw WorkbenchIPCError(.workspaceConflict)
                case .invalidSchema: throw WorkbenchIPCError(.invalidRequest)
                case .invalidPath, .unsafeFile: throw WorkbenchIPCError(.invalidWorkspacePath)
                case .limitExceeded: throw WorkbenchIPCError(.resourceLimit)
                case .newerSchema: throw WorkbenchIPCError(.unsupportedVersion)
                case .incomplete: throw WorkbenchIPCError(.workspaceIncomplete)
                case .alreadyExists: throw WorkbenchIPCError(.workspaceExists)
                case .unavailable: throw WorkbenchIPCError(.unavailable)
                }
            }
        }
    }

    func performWorkspacePackage(_ request: WorkbenchWorkspacePackageRequest,
                                 cancelled: @escaping () -> Bool = { false }) throws -> WorkbenchWorkspacePackageResult {
        let deadline = ProcessInfo.processInfo.systemUptime + localReadTimeout
        return try queue.sync {
            do {
                guard let workspace else { throw WorkbenchIPCError(.methodNotFound) }
                guard !cancelled(), ProcessInfo.processInfo.systemUptime < deadline else {
                    throw WorkbenchIPCError(.timedOut)
                }
                let budget = WorkspaceReadBudget(deadline: deadline, cancelled: cancelled)
                guard let selected = try workspace.current(readBudget: budget),
                      selected.descriptor.workspaceId == request.selection.workspaceId,
                      selected.selectionGeneration == request.selection.generation else {
                    throw WorkbenchIPCError(.workspaceConflict)
                }
                let packages = WorkbenchPortablePackages(workspace: workspace,
                    localReadTimeout: localReadTimeout)
                let result: WorkbenchWorkspacePackageResult
                switch request {
                case .list(_, _, let cursorValue):
                    let cursor = try cursorValue.map(WorkbenchWorkspacePackageCursor.parse)
                    if let cursor {
                        guard cursor.workspaceId == selected.descriptor.workspaceId,
                              cursor.selectionGeneration == request.selection.generation,
                              cursor.historyGeneration == selected.descriptor.generation else {
                            throw WorkbenchIPCError(.workspaceConflict)
                        }
                    }
                    let page = try packages.listPage(afterObjectId: cursor?.lastObjectId,
                        expectedInventoryHash: cursor?.inventoryHash,
                        deadline: deadline, cancelled: cancelled)
                    let nextCursor = page.hasMore ? WorkbenchWorkspacePackageCursor(
                        workspaceId: selected.descriptor.workspaceId,
                        selectionGeneration: request.selection.generation,
                        historyGeneration: selected.descriptor.generation,
                        inventoryHash: page.inventoryHash,
                        lastObjectId: page.lastObjectId!).value : nil
                    result = try .init(.list, selected.descriptor.workspaceId,
                        request.selection.generation,
                        packages: try page.manifests.map {
                            try WorkbenchWorkspacePackageSummary($0,
                                visibleInLibrary: !selected.catalog.archivedDashboardIds.contains($0.dashboardId))
                        },
                        hasMore: page.hasMore, nextCursor: nextCursor)
                case .get(_, _, let dashboardId, let revision):
                    let package = try packages.get(dashboardId: dashboardId, revision: revision,
                        deadline: deadline, cancelled: cancelled)
                    result = try .init(.get, selected.descriptor.workspaceId,
                        request.selection.generation,
                        package: WorkbenchWorkspacePackageSummary(package.manifest,
                            visibleInLibrary: !selected.catalog.archivedDashboardIds.contains(dashboardId)))
                case .file(_, _, let dashboardId, let revision, let path, let offset):
                    let package = try packages.get(dashboardId: dashboardId, revision: revision,
                        deadline: deadline, cancelled: cancelled)
                    let bytes: Data
                    let digest: String
                    if path.isEmpty {
                        bytes = try JSONEncoder().encode(package.manifest)
                        digest = WorkbenchTransactionDigest.hex(bytes)
                    } else {
                        guard let member = package.manifest.files.first(where: { $0.path == path }),
                              let content = package.files[path] else { throw WorkbenchIPCError(.invalidRequest) }
                        bytes = content; digest = member.sha256
                    }
                    guard offset <= bytes.count else { throw WorkbenchIPCError(.invalidRequest) }
                    let end = min(bytes.count, offset + 64 * 1024)
                    let chunk = WorkbenchWorkspacePackageChunk(path: path, offset: offset,
                        totalBytes: bytes.count, sha256: digest,
                        bytes: bytes.subdata(in: offset..<end))
                    result = .init(.file, selected.descriptor.workspaceId,
                        request.selection.generation, chunk: chunk)
                }
                guard !cancelled(), ProcessInfo.processInfo.systemUptime < deadline else {
                    throw WorkbenchIPCError(.timedOut)
                }
                try result.validate(for: request)
                return result
            } catch let error as WorkbenchIPCError { throw error }
            catch let error as WorkspaceError {
                switch error {
                case .conflict: throw WorkbenchIPCError(.workspaceConflict)
                case .invalidPath, .unsafeFile: throw WorkbenchIPCError(.invalidWorkspacePath)
                case .limitExceeded: throw WorkbenchIPCError(.resourceLimit)
                case .newerSchema: throw WorkbenchIPCError(.unsupportedVersion)
                case .invalidSchema: throw WorkbenchIPCError(.invalidRequest)
                case .incomplete: throw WorkbenchIPCError(.workspaceIncomplete)
                case .alreadyExists: throw WorkbenchIPCError(.workspaceExists)
                case .unavailable: throw WorkbenchIPCError(cancelled() ? .disconnected : .unavailable)
                }
            }
        }
    }

    #if os(macOS)
    private func ensureDeploymentDomain() throws -> WorkbenchDeploymentDomain {
        if let deploymentDomain { return deploymentDomain }
        _ = try ensureDeviceDomain()
        guard let connectionDomain, let machineAuthorityPath else {
            throw WorkbenchIPCError(.methodNotFound)
        }
        let directory = URL(fileURLWithPath: machineAuthorityPath).deletingLastPathComponent()
        let peer = deploymentPeerFactory?(controller.devices) ??
            WorkbenchNativeDeploymentPeer(devices: controller.devices)
        let domain = try WorkbenchDeploymentDomain(
            ledgerPath: directory.appendingPathComponent("deployment-ledger.sqlite").path,
            peer: peer, connections: connectionDomain, clock: deploymentClock,
            dispatchEnabled: true)
        deploymentDomain = domain
        return domain
    }

    private func deploymentLedgerPath() -> String? {
        machineAuthorityPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent()
            .appendingPathComponent("deployment-ledger.sqlite").path }
    }

    func workspaceOperationJournalPath() -> String? {
        machineAuthorityPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent()
            .appendingPathComponent("workspace-operation-journal.sqlite").path }
    }
    func deviceEventJournalPath() -> String? {
        machineAuthorityPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent()
            .appendingPathComponent("device-events.sqlite").path }
    }

    func deploymentOperationInventory() throws
        -> (entries: [WorkbenchOperationEntry], truncated: Bool) {
        activeLock.lock(); let isActive = active; activeLock.unlock()
        guard isActive else { throw WorkbenchIPCError(.unavailable) }
        guard let path = deploymentLedgerPath() else { return ([], false) }
        do {
            let ledger = try WorkbenchDeploymentLedger(readOnlyPath: path)
            let records = try ledger.recentOperations(limit: 129)
            let entries = try records.prefix(128).map { record in
                WorkbenchOperationEntry(deployment: record,
                    plan: try ledger.plan(record.planId))
            }
            return (entries, records.count > 128)
        } catch WorkbenchDeploymentError.missing { return ([], false) }
        catch { throw WorkbenchIPCError(.unavailable) }
    }

    func retainedDeploymentEvidence(workspaceId: String, generation: Int,
                                    deviceId: String) throws -> WorkbenchRetainedDeploymentEvidenceRead {
        try queue.sync {
            activeLock.lock(); let isActive = active; activeLock.unlock()
            guard isActive, let workspace, let path = deploymentLedgerPath(),
                  let selected = try workspace.current(),
                  selected.descriptor.workspaceId == workspaceId,
                  selected.selectionGeneration == generation else {
                throw WorkbenchIPCError(.workspaceConflict)
            }
            var packages: [WorkbenchRetainedDeploymentPackage] = []
            let ledger: WorkbenchDeploymentLedger?
            do { ledger = try WorkbenchDeploymentLedger(readOnlyPath: path) }
            catch WorkbenchDeploymentError.missing { ledger = nil }
            catch { throw WorkbenchIPCError(.unavailable) }
            if let ledger {
                do {
                    let records = try ledger.recentOperations(limit: 129)
                    guard records.count <= 128 else { throw WorkbenchIPCError(.resourceLimit) }
                    for record in records where record.state == .active {
                        let plan = try ledger.plan(record.planId)
                        guard plan.workspaceId == workspaceId, plan.deviceId == deviceId else { continue }
                        let review = try JSONDecoder().decode(WorkbenchDeploymentReview.self,
                            from: plan.reviewJSON)
                        packages += try WorkbenchRollbackProvenance.evidence(
                            from: review, operation: record).map(WorkbenchRetainedDeploymentPackage.init)
                        guard packages.count <= 128 else { throw WorkbenchIPCError(.resourceLimit) }
                    }
                } catch let error as WorkbenchIPCError { throw error }
                catch { throw WorkbenchIPCError(.unavailable) }
            }
            guard let current = try workspace.current(),
                  current.descriptor.workspaceId == workspaceId,
                  current.selectionGeneration == generation else {
                throw WorkbenchIPCError(.workspaceConflict)
            }
            let result = WorkbenchRetainedDeploymentEvidenceRead(workspaceId: workspaceId,
                selectionGeneration: generation, deviceId: deviceId, packages: packages)
            try result.validate()
            return result
        }
    }

    func deploymentOperation(_ id: String) throws -> WorkbenchOperationEntry? {
        activeLock.lock(); let isActive = active; activeLock.unlock()
        guard isActive else { throw WorkbenchIPCError(.unavailable) }
        guard let path = deploymentLedgerPath() else { return nil }
        do {
            let ledger = try WorkbenchDeploymentLedger(readOnlyPath: path)
            let record = try ledger.status(id)
            return WorkbenchOperationEntry(deployment: record,
                plan: try ledger.plan(record.planId))
        } catch WorkbenchDeploymentError.missing { return nil }
        catch { throw WorkbenchIPCError(.unavailable) }
    }

    func cancelDeploymentOperation(_ id: String) throws -> WorkbenchOperationEntry? {
        guard let entry = try deploymentOperation(id),
              let planId = entry.planId, let path = deploymentLedgerPath() else { return nil }
        return try queue.sync {
            activeLock.lock(); let isActive = active; activeLock.unlock()
            guard isActive else { throw WorkbenchIPCError(.unavailable) }
            do {
                let ledger = try WorkbenchDeploymentLedger(path: path)
                _ = try ledger.cancelPlan(planId)
                let record = try ledger.status(id)
                return WorkbenchOperationEntry(deployment: record,
                    plan: try ledger.plan(record.planId))
            } catch { throw WorkbenchIPCError(.unavailable) }
        }
    }

    func performDeployment(_ request: WorkbenchDeploymentRequest,
                           consent: WorkbenchDeploymentConsent,
                           cancelled: @escaping () -> Bool = { false }) throws -> WorkbenchDeploymentActionResult {
        try queue.sync {
            activeLock.lock(); let isActive = active; activeLock.unlock()
            guard isActive, let workspace else { throw WorkbenchIPCError(.unavailable) }
            guard !cancelled() else { throw WorkbenchIPCError(.disconnected) }
            do {
                let budget = WorkspaceReadBudget(
                    deadline: ProcessInfo.processInfo.systemUptime + localReadTimeout,
                    cancelled: cancelled)
                let selected = try workspace.current(readBudget: budget)
                guard selected?.descriptor.workspaceId == request.selection.workspaceId,
                      selected?.selectionGeneration == request.selection.generation else {
                    throw WorkbenchIPCError(.workspaceConflict)
                }
                // The old-writer gate precedes ledger creation and every
                // authority transition; the selection assertion and action
                // share the workspace switch boundary.
                try mutationGate?()
                let domain = try ensureDeploymentDomain()
                let result = try authorityBoundary.withWorkspaceSelection {
                    let current = try workspace.current(readBudget: budget)
                    guard current?.descriptor.workspaceId == request.selection.workspaceId,
                          current?.selectionGeneration == request.selection.generation else {
                        throw WorkbenchIPCError(.workspaceConflict)
                    }
                    let id = request.selection.workspaceId
                    let generation = request.selection.generation
                    switch request {
                    case .prepare(_, _, let deviceId, let dashboardId, let revision, let orientation):
                        let observed = try domain.observe(deviceId: deviceId)
                        let source = try WorkbenchPortablePackages(workspace: workspace,
                            localReadTimeout: localReadTimeout).get(dashboardId: dashboardId,
                            revision: revision, deadline: budget.deadline, cancelled: cancelled)
                        let prepared = try WorkbenchPreparedPackages(workspace: workspace).prepare(
                            source: source, profile: observed.profile, orientation: orientation)
                        return try WorkbenchDeploymentActionResult(.prepare, workspaceId: id,
                            generation: generation, prepared: WorkbenchPreparedPackageSummary(prepared))
                    case .plan(_, _, let deviceId, let packages, let selectedDashboardId,
                               let removed, let bindings, let lifetime, let rollback):
                        let review = try domain.prepareFromHistory(workspaceId: id, deviceId: deviceId,
                            preparedStore: WorkbenchPreparedPackages(workspace: workspace),
                            packages: packages, selectedDashboardId: selectedDashboardId,
                            removedDashboardIds: removed, bindingIds: bindings,
                            lifetimeSeconds: lifetime, readBudget: budget)
                        return WorkbenchDeploymentActionResult(rollback ? .rollbackPlan : .plan,
                            workspaceId: id, generation: generation, review: review)
                    case .review(_, _, let planId):
                        let review = try domain.review(planId: planId)
                        guard review.plan.workspaceId == id else { throw WorkbenchIPCError(.workspaceConflict) }
                        return .init(.review, workspaceId: id, generation: generation, review: review)
                    case .apply(_, _, let planId, let expectedHash, let expectedContext,
                                let key, let approved):
                        guard approved else { throw WorkbenchIPCError(.confirmationRequired) }
                        let review = try domain.review(planId: planId)
                        guard review.plan.workspaceId == id, review.planHash == expectedHash,
                              review.authorizationContextHash == expectedContext else {
                            throw WorkbenchIPCError(.workspaceConflict)
                        }
                        // Existing admission is returned without another send,
                        // including after timeout, expiry or a lost response.
                        var previous: WorkbenchDeploymentOperationRecord?
                        do {
                            previous = try domain.admit(review, approvalId: "",
                                idempotencyKey: key, approved: true)
                        } catch let error as WorkbenchDeploymentError {
                            guard error == .invalidApproval else { throw error }
                        }
                        if let existing = previous {
                            return .init(.apply, workspaceId: id, generation: generation,
                                operation: existing)
                        }
                        let approval = try domain.approve(review, consent: consent)
                        let admitted = try domain.admit(review, approvalId: approval.approvalId,
                            idempotencyKey: key, approved: true)
                        let operation: WorkbenchDeploymentOperationRecord
                        do { operation = try domain.dispatch(operationId: admitted.operationId, review: review) }
                        catch { operation = try domain.status(admitted.operationId) }
                        return .init(.apply, workspaceId: id, generation: generation,
                            operation: operation)
                    case .status(_, _, let operationId):
                        let operation = try domain.status(operationId)
                        guard try domain.review(planId: operation.planId).plan.workspaceId == id else {
                            throw WorkbenchIPCError(.workspaceConflict)
                        }
                        return .init(.status, workspaceId: id, generation: generation,
                            operation: operation)
                    case .lookup(_, _, let planId):
                        let operation = try domain.lookup(planId: planId, workspaceId: id)
                        return .init(.lookup, workspaceId: id, generation: generation,
                            operation: operation)
                    case .reconcile(_, _, let operationId):
                        let operation = try domain.status(operationId)
                        let review = try domain.review(planId: operation.planId)
                        guard review.plan.workspaceId == id else { throw WorkbenchIPCError(.workspaceConflict) }
                        let updated = try domain.reconcile(operationId: operationId, review: review)
                        return .init(.reconcile, workspaceId: id, generation: generation,
                            operation: updated)
                    case .cancel(_, _, let planId, let deviceId):
                        let review = try domain.review(planId: planId)
                        guard review.plan.workspaceId == id, review.plan.deviceId == deviceId else {
                            throw WorkbenchIPCError(.workspaceConflict)
                        }
                        let operation = try domain.cancel(planId: planId, deviceId: deviceId)
                        return .init(.cancel, workspaceId: id, generation: generation,
                            operation: operation, cancelled: operation == nil ? true : nil)
                    }
                }
                try result.validate(for: request)
                _ = try WorkbenchWireJSON.object(WorkbenchSocket.encode(result))
                return result
            } catch let error as WorkbenchIPCError { throw error }
            catch let error as WorkbenchDeploymentError {
                switch error {
                case .invalidPlan: throw WorkbenchIPCError(.invalidRequest)
                case .invalidApproval, .expired: throw WorkbenchIPCError(.confirmationRequired)
                case .staleContext, .conflict, .cancelled, .alreadySent: throw WorkbenchIPCError(.workspaceConflict)
                case .clockUncertain, .storage, .missing: throw WorkbenchIPCError(.unavailable)
                case .unsupportedIntegration: throw WorkbenchIPCError(.methodNotFound)
                case .unknownRemoteOutcome: throw WorkbenchIPCError(.remoteOutcomeUnknown)
                }
            }
            catch let error as WorkspaceError where error == .conflict {
                throw WorkbenchIPCError(.workspaceConflict)
            }
            catch { throw WorkbenchIPCError(.unavailable) }
        }
    }
    #endif

    func perform(_ request: WorkbenchDomainRequest, cancelled: @escaping () -> Bool = { false }) throws -> WorkbenchReadResult {
        let budget = DashboardReadBudget(deadline: ProcessInfo.processInfo.systemUptime + localReadTimeout,
                                         cancelled: cancelled)
        return try queue.sync {
            activeLock.lock(); let isActive = active; activeLock.unlock()
            guard isActive else { throw WorkbenchIPCError(.unavailable) }
            dispatchObserver?(request.method)
            do {
                try budget.check()
                let result = try execute(request, budget: budget)
                try budget.check()
                // Never emit a DTO the bounded wire decoder cannot consume.
                do { _ = try WorkbenchWireJSON.object(WorkbenchSocket.encode(result)) }
                catch { throw WorkbenchIPCError(.resourceLimit) }
                return result
            }
            catch let error as WorkbenchIPCError { throw error }
            catch { throw WorkbenchIPCError(.unavailable) }
        }
    }

    func performAuthoring(_ request: WorkbenchAuthoringRecoveryRequest,
                          cancelled: @escaping () -> Bool = { false },
                          operationDeadlineUptime: TimeInterval? = nil,
                          progress: @escaping (WorkspaceCopyProgress) -> Void = { _ in })
        throws -> WorkbenchAuthoringRecoveryResult {
        try queue.sync {
            activeLock.lock(); let isActive = active; activeLock.unlock()
            guard isActive, let workspace else { throw WorkbenchIPCError(.unavailable) }
            guard !cancelled() else { throw WorkbenchIPCError(.disconnected) }
            let longOperation = request.method == .snapshotCreate ||
                request.method == .workspaceRelocate
            let handler: WorkbenchAuthoringRecoveryDomain
            if longOperation, let operationDeadlineUptime {
                let remaining = operationDeadlineUptime - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw WorkbenchIPCError(.timedOut) }
                handler = WorkbenchAuthoringRecoveryDomain(workspace: workspace,
                    timeout: min(300, remaining),
                    mutationGate: mutationGate ?? { throw WorkbenchIPCError(.incompatibleOwner) },
                    trustedCatalog: trustedCatalog)
            } else {
                if authoringRecoveryDomain == nil {
                authoringRecoveryDomain = WorkbenchAuthoringRecoveryDomain(workspace: workspace,
                    timeout: 300,
                    mutationGate: mutationGate ?? { throw WorkbenchIPCError(.incompatibleOwner) },
                    trustedCatalog: trustedCatalog)
                }
                guard let cached = authoringRecoveryDomain else {
                    throw WorkbenchIPCError(.unavailable)
                }
                handler = cached
            }
            // The request's selection assertion and its first write share the
            // same broker-owned boundary as workspace.open/init. Another
            // client cannot switch selection between check and mutation.
            let result = try authorityBoundary.withWorkspaceSelection {
                try handler.perform(request, cancelled: cancelled, progress: progress)
            }
            try result.validate(for: request.method)
            _ = try WorkbenchWireJSON.object(WorkbenchSocket.encode(result))
            return result
        }
    }

    func toolchainRequirements() throws -> WorkbenchToolchainRequirementsRead {
        let requirements = try queue.sync {
            activeLock.lock(); let isActive = active; activeLock.unlock()
            guard isActive, let workspace else { throw WorkbenchIPCError(.unavailable) }
            return try authorityBoundary.withWorkspaceSelection {
                try WorkbenchToolchainRequirementsReader.read(workspace: workspace)
            }
        }
        guard let installer = toolchainInstaller else { return requirements }
        var installed: [WorkspaceToolchainRequirements.Requirement] = []
        for requirement in requirements.required {
            do { _ = try installer.installed(requirement); installed.append(requirement) }
            catch ToolchainTrustError.kitMissing { continue }
            catch { throw WorkbenchIPCError(.toolchainTrustUnavailable) }
        }
        let measured = WorkbenchToolchainRequirementsRead(workspaceId: requirements.workspaceId,
            selectionGeneration: requirements.selectionGeneration,
            required: requirements.required, installed: installed)
        try measured.validate()
        return measured
    }

    func installRequiredToolchains(workspaceId: String, selectionGeneration: Int) throws
        -> WorkbenchToolchainInstallResult {
        let requirements = try queue.sync { () -> WorkbenchToolchainRequirementsRead in
            activeLock.lock(); let isActive = active; activeLock.unlock()
            guard isActive, let workspace else { throw WorkbenchIPCError(.unavailable) }
            let value = try WorkbenchToolchainRequirementsReader.read(workspace: workspace)
            guard value.workspaceId == workspaceId,
                  value.selectionGeneration == selectionGeneration else {
                throw WorkbenchIPCError(.workspaceConflict)
            }
            return value
        }
        guard !requirements.required.isEmpty else {
            return WorkbenchToolchainInstallResult(requirements: requirements, installed: [])
        }
        guard let installer = toolchainInstaller else {
            throw WorkbenchIPCError(.toolchainTrustUnavailable)
        }
        for requirement in requirements.required {
            do {
                _ = try installer.install(requirement)
                _ = try installer.installed(requirement)
            } catch ToolchainTrustError.limitExceeded {
                throw WorkbenchIPCError(.resourceLimit)
            } catch {
                throw WorkbenchIPCError(.toolchainTrustUnavailable)
            }
        }
        let current = try queue.sync { () -> WorkbenchToolchainRequirementsRead in
            activeLock.lock(); let isActive = active; activeLock.unlock()
            guard isActive, let workspace else { throw WorkbenchIPCError(.unavailable) }
            return try WorkbenchToolchainRequirementsReader.read(workspace: workspace)
        }
        guard current.workspaceId == requirements.workspaceId,
              current.selectionGeneration == requirements.selectionGeneration,
              current.required == requirements.required else {
            throw WorkbenchIPCError(.workspaceConflict)
        }
        let result = WorkbenchToolchainInstallResult(requirements: requirements,
            installed: requirements.required)
        try result.validate()
        return result
    }

    func readSourceText(_ request: WorkbenchSourceTextRequest,
                        cancelled: @escaping () -> Bool = { false }) throws -> WorkbenchSourceTextRead {
        try queue.sync {
            activeLock.lock(); let isActive = active; activeLock.unlock()
            guard isActive, let workspace else { throw WorkbenchIPCError(.unavailable) }
            guard !cancelled() else { throw WorkbenchIPCError(.disconnected) }
            do {
                let result = try WorkbenchContainedAuthoring(workspace: workspace,
                    localReadTimeout: localReadTimeout).readText(request.projectId,
                    path: request.path, expectedWorkspaceId: request.expectedWorkspaceId,
                    expectedSelectionGeneration: request.expectedSelectionGeneration,
                    deadline: ProcessInfo.processInfo.systemUptime + localReadTimeout,
                    cancelled: cancelled)
                _ = try WorkbenchWireJSON.object(WorkbenchSocket.encode(result))
                return result
            } catch let error as WorkbenchIPCError { throw error }
            catch let error as WorkspaceError {
                switch error {
                case .conflict: throw WorkbenchIPCError(.workspaceConflict)
                case .invalidPath, .unsafeFile: throw WorkbenchIPCError(.invalidWorkspacePath)
                case .invalidSchema: throw WorkbenchIPCError(.invalidRequest)
                case .limitExceeded: throw WorkbenchIPCError(.resourceLimit)
                case .newerSchema: throw WorkbenchIPCError(.unsupportedVersion)
                default: throw WorkbenchIPCError(.unavailable)
                }
            }
        }
    }

    func readSourceChunk(_ request: WorkbenchSourceChunkRequest,
                         cancelled: @escaping () -> Bool = { false }) throws -> WorkbenchSourceChunkRead {
        try queue.sync {
            activeLock.lock(); let isActive = active; activeLock.unlock()
            guard isActive, let workspace else { throw WorkbenchIPCError(.unavailable) }
            guard !cancelled() else { throw WorkbenchIPCError(.disconnected) }
            do {
                let result = try WorkbenchContainedAuthoring(workspace: workspace,
                    localReadTimeout: localReadTimeout).readChunk(request,
                    deadline: ProcessInfo.processInfo.systemUptime + localReadTimeout,
                    cancelled: cancelled)
                try result.validate(for: request)
                _ = try WorkbenchWireJSON.object(WorkbenchSocket.encode(result), allowSourceChunk: true)
                return result
            } catch let error as WorkbenchIPCError { throw error }
            catch let error as WorkspaceError {
                switch error {
                case .conflict: throw WorkbenchIPCError(.workspaceConflict)
                case .invalidPath, .unsafeFile: throw WorkbenchIPCError(.invalidWorkspacePath)
                case .invalidSchema: throw WorkbenchIPCError(.invalidRequest)
                case .limitExceeded: throw WorkbenchIPCError(.resourceLimit)
                case .newerSchema: throw WorkbenchIPCError(.unsupportedVersion)
                default: throw WorkbenchIPCError(.unavailable)
                }
            }
        }
    }

    func performPackageImport(_ request: WorkbenchPackageImportRequest,
                              cancelled: @escaping () -> Bool = { false }) throws -> WorkbenchPackageImportResult {
        try queue.sync {
            activeLock.lock(); let isActive = active; activeLock.unlock()
            guard isActive, let workspace, !cancelled() else { throw WorkbenchIPCError(.unavailable) }
            do {
                let now = ProcessInfo.processInfo.systemUptime
                if let session = packageImportSession, session.expiresAt <= now {
                    packageImportSession = nil
                }
                let workspaceId: String, generation: Int
                switch request {
                case .begin(let id, let gen, _, _, _), .chunk(let id, let gen, _, _, _, _),
                     .status(let id, let gen, _), .commit(let id, let gen, _, _),
                     .abort(let id, let gen, _):
                    workspaceId = id; generation = gen
                }
                guard let selected = try workspace.current(),
                      selected.descriptor.workspaceId == workspaceId,
                      selected.selectionGeneration == generation else {
                    if packageImportSession?.workspaceId == workspaceId &&
                       packageImportSession?.selectionGeneration == generation {
                        packageImportSession = nil
                    }
                    throw WorkbenchIPCError(.workspaceConflict)
                }
                let result: WorkbenchPackageImportResult
                switch request {
                case .begin(_, _, let digest, let manifest, _):
                    try mutationGate?()
                    guard packageImportSession == nil else { throw WorkbenchIPCError(.workspaceConflict) }
                    let session = WorkbenchPackageImportSession(workspaceId: workspaceId,
                        selectionGeneration: generation, digest: digest, manifest: manifest, now: now)
                    packageImportSession = session
                    result = .init(kind: request.method.rawValue, uploadId: session.uploadId,
                        nextFileIndex: 0, nextOffset: 0)
                case .chunk(_, _, let uploadId, let fileIndex, let offset, let bytes):
                    try mutationGate?()
                    guard var session = packageImportSession, session.uploadId == uploadId,
                          session.workspaceId == workspaceId,
                          session.selectionGeneration == generation,
                          fileIndex == session.fileIndex, offset == session.offset,
                          fileIndex < session.manifest.files.count else {
                        throw WorkbenchIPCError(.workspaceConflict)
                    }
                    let file = session.manifest.files[fileIndex]
                    guard bytes.count <= file.bytes - session.offset,
                          !bytes.isEmpty || file.bytes == 0 else {
                        throw WorkbenchIPCError(.invalidRequest)
                    }
                    session.partial.append(bytes)
                    session.offset += bytes.count
                    if session.offset == file.bytes {
                        guard DeploymentDigest.sha256Hex(session.partial) == file.sha256 else {
                            packageImportSession = nil
                            throw WorkbenchIPCError(.invalidRequest)
                        }
                        session.files[file.path] = session.partial
                        session.partial = Data()
                        session.fileIndex += 1; session.offset = 0
                    }
                    session.expiresAt = min(now + 120, session.deadlineAt)
                    packageImportSession = session
                    result = .init(kind: request.method.rawValue, uploadId: uploadId,
                        nextFileIndex: session.fileIndex, nextOffset: session.offset)
                case .status(_, _, let uploadId):
                    guard let session = packageImportSession, session.uploadId == uploadId,
                          session.workspaceId == workspaceId,
                          session.selectionGeneration == generation else {
                        throw WorkbenchIPCError(.workspaceConflict)
                    }
                    result = .init(kind: request.method.rawValue, uploadId: uploadId,
                        nextFileIndex: session.fileIndex, nextOffset: session.offset)
                case .commit(_, _, let uploadId, let digest):
                    try mutationGate?()
                    guard let session = packageImportSession, session.uploadId == uploadId,
                          session.workspaceId == workspaceId,
                          session.selectionGeneration == generation,
                          session.digest == digest,
                          session.fileIndex == session.manifest.files.count,
                          session.offset == 0,
                          session.files.count == session.manifest.files.count else {
                        throw WorkbenchIPCError(.workspaceConflict)
                    }
                    packageImportSession = nil // one commit attempt; retry begins a new measured upload
                    let submitted = try WorkbenchBoundedPackageImportRequest(
                        expectedWorkspaceId: workspaceId,
                        expectedSelectionGeneration: generation,
                        expectedDigest: digest,
                        package: WorkbenchPortablePackage(manifest: session.manifest,
                            files: session.files))
                    let receipt = try WorkbenchBoundedPackageImport(workspace: workspace).perform(submitted)
                    result = .init(kind: request.method.rawValue, receipt: receipt)
                case .abort(_, _, let uploadId):
                    guard packageImportSession?.uploadId == uploadId else {
                        throw WorkbenchIPCError(.workspaceConflict)
                    }
                    packageImportSession = nil
                    result = .init(kind: request.method.rawValue, aborted: true)
                }
                try result.validate(for: request.method)
                _ = try WorkbenchWireJSON.object(WorkbenchSocket.encode(result))
                return result
            } catch let error as WorkbenchIPCError { throw error }
            catch let error as WorkspaceError {
                switch error {
                case .conflict: throw WorkbenchIPCError(.workspaceConflict)
                case .invalidPath, .unsafeFile: throw WorkbenchIPCError(.invalidWorkspacePath)
                case .invalidSchema: throw WorkbenchIPCError(.invalidRequest)
                case .limitExceeded: throw WorkbenchIPCError(.resourceLimit)
                case .newerSchema: throw WorkbenchIPCError(.unsupportedVersion)
                default: throw WorkbenchIPCError(.unavailable)
                }
            }
        }
    }

    func selectWorkspace(path: String?, create: Bool, cancelled: @escaping () -> Bool = { false }) throws -> WorkbenchReadResult {
        let budget = WorkspaceReadBudget(deadline: ProcessInfo.processInfo.systemUptime + localReadTimeout,
                                         cancelled: cancelled)
        return try queue.sync {
            activeLock.lock(); let isActive = active; activeLock.unlock()
            guard isActive, let workspace else { throw WorkbenchIPCError(.unavailable) }
            guard !cancelled() else { throw WorkbenchIPCError(.disconnected) }
            let checkSelection: () throws -> Void = {
                try budget.check()
                self.activeLock.lock(); let stillActive = self.active; self.activeLock.unlock()
                guard stillActive && !cancelled() else { throw WorkbenchIPCError(.disconnected) }
            }
            do {
                let overview: WorkspaceOverview
                overview = try authorityBoundary.withWorkspaceSelection {
                    try checkSelection()
                    try mutationGate?()
                    if create {
                        if try legacyDataPresent() { throw WorkbenchIPCError(.migrationRequired) }
                        return try workspace.create(at: path, readBudget: budget, beforeSelection: checkSelection)
                    }
                    guard let path else { throw WorkbenchIPCError(.invalidRequest) }
                    _ = try WorkbenchContainedAuthoring(workspace: workspace)
                        .recoverContainedBeforeOpen(at: path)
                    try checkSelection()
                    return try workspace.open(at: path, readBudget: budget, beforeSelection: checkSelection)
                }
                return WorkbenchReadResult(kind: .workspace, workspace: WorkbenchWorkspaceStatus(overview: overview))
            } catch let error as WorkbenchIPCError { throw error }
            catch WorkspaceError.unavailable { throw WorkbenchIPCError(cancelled() ? .disconnected : .timedOut) }
            catch WorkspaceError.alreadyExists { throw WorkbenchIPCError(.workspaceExists) }
            catch WorkspaceError.conflict { throw WorkbenchIPCError(.workspaceConflict) }
            catch WorkspaceError.incomplete { throw WorkbenchIPCError(.workspaceIncomplete) }
            catch WorkspaceError.invalidPath { throw WorkbenchIPCError(.invalidWorkspacePath) }
            catch WorkspaceError.unsafeFile { throw WorkbenchIPCError(.invalidWorkspacePath) }
            catch { throw WorkbenchIPCError(.unavailable) }
        }
    }

    private func legacyDataPresent() throws -> Bool {
        for member in ["dashboards", "authoring/projects"] {
            let path = controller.store.root.appendingPathComponent(member)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) else { continue }
            guard isDirectory.boolValue else { return true }
            if try !FileManager.default.contentsOfDirectory(atPath: path.path).isEmpty { return true }
        }
        return false
    }

    private func execute(_ request: WorkbenchDomainRequest, budget: DashboardReadBudget) throws -> WorkbenchReadResult {
        switch request {
        case .workspaceStatus:
            let workspaceBudget = WorkspaceReadBudget(deadline: budget.deadline, cancelled: budget.cancelled)
            return WorkbenchReadResult(kind: .workspace,
                workspace: WorkbenchWorkspaceStatus(overview: try workspace?.current(readBudget: workspaceBudget)))
        case .workspaceCoverage, .workspaceValidate:
            guard let workspace else { throw WorkbenchIPCError(.unavailable) }
            let readBudget = WorkspaceReadBudget(deadline: budget.deadline, cancelled: budget.cancelled)
            guard let overview = try workspace.current(readBudget: readBudget) else { throw WorkbenchIPCError(.unavailable) }
            return WorkbenchReadResult(kind: .coverage,
                coverage: WorkbenchCoverageRead(overview, validate: request.method == .workspaceValidate))
        case .projectList:
            guard let workspace else { throw WorkbenchIPCError(.unavailable) }
            let readBudget = WorkspaceReadBudget(deadline: budget.deadline, cancelled: budget.cancelled)
            guard let overview = try workspace.current(readBudget: readBudget) else { throw WorkbenchIPCError(.unavailable) }
            guard overview.catalog.projects.count <= 128 else { throw WorkbenchIPCError(.resourceLimit) }
            let hidden = Set(overview.catalog.archivedDashboardIds)
            return WorkbenchReadResult(kind: .projects,
                projects: overview.catalog.projects.filter { !hidden.contains($0.dashboardId) })
        case .projectGet(let id):
            guard let workspace else { throw WorkbenchIPCError(.unavailable) }
            let readBudget = WorkspaceReadBudget(deadline: budget.deadline, cancelled: budget.cancelled)
            guard let overview = try workspace.current(readBudget: readBudget),
                  let project = overview.catalog.projects.first(where: { $0.projectId == id }) else { throw WorkbenchIPCError(.unavailable) }
            return WorkbenchReadResult(kind: .project, project: project)
        case .projectPath(let id):
            guard let workspace else { throw WorkbenchIPCError(.unavailable) }
            let readBudget = WorkspaceReadBudget(deadline: budget.deadline, cancelled: budget.cancelled)
            guard let path = try workspace.resolveProject(id, readBudget: readBudget) else { throw WorkbenchIPCError(.unavailable) }
            return WorkbenchReadResult(kind: .projectPath, projectPath: path)
        case .projectVersions(let id):
            guard let workspace else { throw WorkbenchIPCError(.unavailable) }
            let authoring = WorkbenchContainedAuthoring(workspace: workspace, localReadTimeout: localReadTimeout)
            let versions = try authoring.versions(id, deadline: budget.deadline, cancelled: {
                (try? budget.check()) == nil
            })
            guard versions.count <= 128 else { throw WorkbenchIPCError(.resourceLimit) }
            return WorkbenchReadResult(kind: .sourceVersions, sourceVersions: versions)
        case .packageList:
            let packages = try controller.store.listDashboards(readBudget: budget)
            guard packages.count <= 128 else { throw WorkbenchIPCError(.resourceLimit) }
            return WorkbenchReadResult(kind: .packages, packages: packages.map(WorkbenchPackageSummary.init))
        case .packageGet(let id, let revision), .packageValidate(let id, let revision):
            let record = try controller.store.getRevision(dashboardId: id, revision: revision, readBudget: budget)
            try PackageValidator.validate(record.manifest)
            let manifest = record.manifest
            guard manifest.dashboardId == id,
                  revision == nil || manifest.revision == revision,
                  let digest = manifest.digest,
                  digest == (try DeploymentDigest.digest(for: manifest)),
                  manifest.files.count == record.files.count else { throw WorkbenchIPCError(.unavailable) }
            var total = 0
            for file in manifest.files {
                try budget.check()
                guard let bytes = record.files[file.path], bytes.count == file.bytes,
                      DeploymentDigest.sha256Hex(bytes) == file.sha256 else { throw WorkbenchIPCError(.unavailable) }
                guard bytes.count <= PackageLimits.expandedBytes - total else { throw WorkbenchIPCError(.resourceLimit) }
                total += bytes.count
            }
            let detail = WorkbenchPackageRead(dashboardId: manifest.dashboardId,
                revision: manifest.revision, name: manifest.name, digest: digest,
                fileCount: manifest.files.count, bytes: total,
                integrity: "verified-local-bytes-no-provenance", storage: "legacy-controller")
            return WorkbenchReadResult(kind: .package, package: detail)
        case .deviceList:
            let identity = controller.devices.controllerIdentity
            let devices = controller.devices.listDevices()
            guard devices.count <= 128 else { throw WorkbenchIPCError(.resourceLimit) }
            return WorkbenchReadResult(kind: .devices,
                devices: devices.map { WorkbenchDeviceRead($0, currentIdentity: identity) })
        case .deviceGet(let id):
            let record = try controller.devices.device(id, probe: false)
            return WorkbenchReadResult(kind: .device,
                device: WorkbenchDeviceRead(record, currentIdentity: controller.devices.controllerIdentity))
        }
    }
}
