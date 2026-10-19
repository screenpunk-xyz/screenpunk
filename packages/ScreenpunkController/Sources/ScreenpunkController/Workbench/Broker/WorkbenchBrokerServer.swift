import Foundation
import CoreFoundation
#if os(macOS)
import Darwin

private enum WorkbenchSessionPrincipal: Equatable { case ordinary, localReview }

public final class WorkbenchBrokerServer: @unchecked Sendable {
    private let environment: WorkbenchBrokerEnvironment
    private let lifecycle = NSLock()
    private var state: WorkbenchServerState?
    private let afterSocketBound: (() throws -> Void)?
    private let domain: WorkbenchBrokerDomain?
    private let onShutdown: (() -> Void)?
    private let lifecycleCoordinator: WorkbenchServiceLifecycle
    private let guiVerifier: WorkbenchGUIConsumerVerifier?
    public init(environment: WorkbenchBrokerEnvironment, domain: WorkbenchBrokerDomain? = nil,
                onShutdown: (() -> Void)? = nil,
                guiVerifier: WorkbenchGUIConsumerVerifier? = nil) {
        self.environment = environment; self.domain = domain; self.onShutdown = onShutdown; afterSocketBound = nil
        self.guiVerifier = guiVerifier
        lifecycleCoordinator = WorkbenchServiceLifecycle()
    }
    // Test-only service-owned lifecycle seam; no peer can inject it.
    init(environment: WorkbenchBrokerEnvironment, lifecycleCoordinator: WorkbenchServiceLifecycle) {
        self.environment = environment; domain = nil; onShutdown = nil; afterSocketBound = nil
        guiVerifier = nil
        self.lifecycleCoordinator = lifecycleCoordinator
    }
    // Internal deterministic failure seam; no production caller or RPC can supply this hook.
    init(environment: WorkbenchBrokerEnvironment, afterSocketBound: @escaping () throws -> Void) {
        self.environment = environment; self.afterSocketBound = afterSocketBound; domain = nil; onShutdown = nil
        guiVerifier = nil
        lifecycleCoordinator = WorkbenchServiceLifecycle()
    }
    @discardableResult public func start() throws -> WorkbenchBrokerSnapshot {
        lifecycle.lock(); defer { lifecycle.unlock() }
        guard state == nil else { throw WorkbenchIPCError(.alreadyRunning) }
        let created = try WorkbenchServerState(environment: environment, domain: domain, afterSocketBound: afterSocketBound,
                                               onShutdown: onShutdown, lifecycleCoordinator: lifecycleCoordinator,
                                               guiVerifier: guiVerifier)
        state = created; created.start(); return created.snapshot
    }
    public func stop() {
        lifecycle.lock(); defer { lifecycle.unlock() }
        state?.stop(); state = nil
    }
    var stagedFrameBytes: Int { lifecycle.lock(); defer { lifecycle.unlock() }; return state?.stagedFrameBytes ?? 0 }
    var activeConnectionCount: Int { lifecycle.lock(); defer { lifecycle.unlock() }; return state?.activeConnectionCount ?? 0 }
    deinit { stop() }
}

private final class WorkbenchServerState: @unchecked Sendable {
    let environment: WorkbenchBrokerEnvironment
    let snapshot: WorkbenchBrokerSnapshot
    private let domain: WorkbenchBrokerDomain?
    private let onShutdown: (() -> Void)?
    private let directory: WorkbenchRuntimeDirectory
    private let lockFD: Int32
    private let listener: Int32
    private let token: Data
    private let localToken: Data
    private let ownedFiles: [(String, WorkbenchFileIdentity, Bool)]
    private let budget: WorkbenchFrameBudget
    private let serviceLifecycle: WorkbenchServiceLifecycle
    private let workspaceOperations: WorkbenchWorkspaceOperationRegistry
    private let deviceEvents: WorkbenchDeviceEventJournal?
    private let guiVerifier: WorkbenchGUIConsumerVerifier?
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var stopped = false
    private var connections = Set<Int32>()

    init(environment: WorkbenchBrokerEnvironment, domain: WorkbenchBrokerDomain?, afterSocketBound: (() throws -> Void)?,
         onShutdown: (() -> Void)?, lifecycleCoordinator: WorkbenchServiceLifecycle,
         guiVerifier: WorkbenchGUIConsumerVerifier?) throws {
        self.environment = environment
        self.domain = domain
        self.onShutdown = onShutdown
        serviceLifecycle = lifecycleCoordinator
        self.guiVerifier = guiVerifier
        directory = try WorkbenchRuntimeDirectory(environment: environment, create: true)
        let held = try directory.lock()
        var socket: Int32 = -1
        var owned: [(String, WorkbenchFileIdentity, Bool)] = []
        var domainStarted = false
        do {
            // Only the process holding the runtime owner lock may reconcile
            // interrupted journal rows. A rejected second start must not
            // relabel the first owner's still-running workspace copy.
            workspaceOperations = try WorkbenchWorkspaceOperationRegistry(
                journalPath: domain?.workspaceOperationJournalPath())
            if domain != nil {
                let path = domain?.deviceEventJournalPath() ?? environment.runtimeDirectory
                    .appendingPathComponent("device-events.sqlite").path
                deviceEvents = try WorkbenchDeviceEventJournal(path: path)
            } else { deviceEvents = nil }
            try directory.removeStaleInstance(); try directory.revalidatePath()
            socket = try WorkbenchSocket.make()
            let path = environment.runtimeDirectory.appendingPathComponent("broker.sock").path
            guard try WorkbenchSocket.address(path, { Darwin.bind(socket, $0, $1) }) == 0 else { throw WorkbenchIPCError(.unavailable) }
            // Record the bound inode before chmod or any injected/fallible publication step.
            let socketID = try directory.unpublishedSocketIdentity()
            owned.append(("broker.sock", socketID, true))
            try afterSocketBound?()
            guard fchmodat(directory.fd, "broker.sock", 0o600, 0) == 0,
                  try directory.identity(of: "broker.sock", socket: true) == socketID else { throw WorkbenchIPCError(.insecureRuntime) }
            guard Darwin.listen(socket, Int32(environment.limits.maxConnections)) == 0 else { throw WorkbenchIPCError(.unavailable) }
            let instance = UUID().uuidString.lowercased()
            var random = SystemRandomNumberGenerator()
            let secret = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) })
            let localSecret = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) })
            owned.append(("broker.token", try directory.create("broker.token", bytes: secret), false))
            owned.append(("broker.local-token", try directory.create("broker.local-token", bytes: localSecret), false))
            let locator = WorkbenchRuntimeLocator(instanceId: instance)
            owned.append(("broker.locator.json", try directory.create("broker.locator.json", bytes: WorkbenchSocket.encode(locator)), false))
            try directory.revalidatePath()
            lockFD = held; listener = socket; token = secret; localToken = localSecret; ownedFiles = owned
            try domain?.start(); domainStarted = domain != nil
            snapshot = try domain?.snapshot(instanceId: instance) ?? WorkbenchBrokerSnapshot(instanceId: instance)
            budget = WorkbenchFrameBudget(maximum: environment.limits.maxStagingBytes)
        } catch {
            if domainStarted { domain?.stop() }
            if socket >= 0 { close(socket) }
            for (name, id, isSocket) in owned.reversed() {
                if isSocket { try? directory.removeUnpublishedSocket(matching: id) }
                else { try? directory.remove(name, matching: id) }
            }
            _ = flock(held, LOCK_UN); close(held); throw error
        }
    }
    func start() {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in defer { group.leave() }; acceptLoop() }
    }
    var stagedFrameBytes: Int { budget.currentUsage }
    var activeConnectionCount: Int { lock.lock(); defer { lock.unlock() }; return connections.count }
    private func isStopped() -> Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func stop() {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        _ = Darwin.shutdown(listener, SHUT_RDWR)
        // Shutdown and worker close share this lock, preventing reuse of a captured fd.
        for fd in connections { _ = Darwin.shutdown(fd, SHUT_RDWR) }
        lock.unlock()
        group.wait(); domain?.stop(); close(listener)
        for (name, id, isSocket) in ownedFiles.reversed() { try? directory.remove(name, matching: id, socket: isSocket) }
        _ = flock(lockFD, LOCK_UN); close(lockFD)
    }
    private func acceptLoop() {
        while !isStopped() {
            do { try WorkbenchSocket.wait(listener, events: Int16(POLLIN), deadline: environment.clock.now() + 0.1, clock: environment.clock) }
            catch { continue }
            let fd = Darwin.accept(listener, nil, nil)
            if fd < 0 { continue }
            lock.lock()
            if stopped || connections.count >= environment.limits.maxConnections { close(fd); lock.unlock(); continue }
            connections.insert(fd); group.enter(); lock.unlock()
            DispatchQueue.global(qos: .utility).async { [self] in
                defer {
                    lock.lock(); connections.remove(fd); close(fd); lock.unlock(); group.leave()
                }
                serve(fd)
            }
        }
    }
    private func send(_ fd: Int32, response: WorkbenchWireResponse, deadline: TimeInterval? = nil) throws {
        try WorkbenchSocket.writeFrame(fd, bytes: WorkbenchSocket.encode(response), environment: environment, deadline: deadline)
    }
    private func serve(_ fd: Int32) {
        let handshakeDeadline = environment.clock.now() + environment.limits.timeout
        let principal: WorkbenchSessionPrincipal
        do {
            try WorkbenchSocket.configureAccepted(fd)
            guard try environment.peerCredentials.effectiveUID(socket: fd) == environment.ownerUID else {
                // Reject before receiving any authentication payload from an unauthorized UID.
                return
            }
            let auth = try WorkbenchWireJSON.object(WorkbenchSocket.readFrame(fd, environment: environment, budget: budget, deadline: handshakeDeadline))
            guard Set(auth.keys) == ["apiVersion", "instanceId", "token"] else { throw WorkbenchIPCError(.invalidRequest) }
            guard auth["apiVersion"] as? String == "1.0" else { throw WorkbenchIPCError(.unsupportedVersion) }
            guard auth["instanceId"] as? String == snapshot.instanceId else { throw WorkbenchIPCError(.instanceMismatch) }
            guard let text = auth["token"] as? String, let supplied = Data(base64Encoded: text), supplied.count == 32 else { throw WorkbenchIPCError(.authenticationFailed) }
            let ordinaryMismatch = zip(supplied, token).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) }
            let localMismatch = zip(supplied, localToken).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) }
            guard ordinaryMismatch == 0 || localMismatch == 0 else { throw WorkbenchIPCError(.authenticationFailed) }
            principal = localMismatch == 0 ? .localReview : .ordinary
            try send(fd, response: WorkbenchWireResponse(requestId: "authentication", result: snapshot), deadline: handshakeDeadline)
        } catch {
            if let error = error as? WorkbenchIPCError, ![.timedOut, .disconnected].contains(error.code) {
                try? send(fd, response: WorkbenchWireResponse(requestId: "authentication", error: error), deadline: handshakeDeadline)
            }
            return
        }
        serviceLifecycle.authenticatedConnectionOpened()
        // A request ID is caller-chosen and can repeat on another socket.
        // Keep it visible in lifecycle reports, with a broker-minted suffix
        // that distinguishes concurrent sessions without trusting a wire role.
        let sessionJobSuffix = UUID().uuidString.lowercased()
        let guiConsumerID = UUID().uuidString.lowercased()
        let removalOwner = UUID()
        var removalPrepared = false
        var shutdownRequested = false
        var registeredGUI = false
        defer {
            if !shutdownRequested { serviceLifecycle.cancelPreparedRemoval(owner: removalOwner) }
            if registeredGUI { serviceLifecycle.releaseVerifiedGUIConsumer(guiConsumerID) }
            serviceLifecycle.authenticatedConnectionClosed()
        }
        var saidHello = false
        var localReviewTicket: WorkbenchLocalReviewTicket?
        var homeAssistantTicket: WorkbenchHomeAssistantReviewTicket?
        while !isStopped() {
            var requestId = "invalid-request"
            do {
                let ticketUptime = localReviewTicket?.deadlineUptime ?? homeAssistantTicket?.deadlineUptime
                let reviewIdleDeadline = ticketUptime.map {
                    environment.clock.now() + max(0, $0 - ProcessInfo.processInfo.systemUptime)
                }
                let data = try WorkbenchSocket.readFrame(fd, environment: environment, budget: budget,
                    deadline: saidHello ? nil : handshakeDeadline, idleDeadline: reviewIdleDeadline)
                let object = try WorkbenchWireJSON.object(data, allowImportPayload: true, allowDeviceSettings: true)
                guard Set(object.keys) == ["apiVersion", "requestId", "method", "params"],
                      let id = object["requestId"] as? String, Self.validID(id),
                      let method = object["method"] as? String, method.utf8.count <= 100,
                      let params = object["params"] as? [String: Any] else { throw WorkbenchIPCError(.invalidRequest) }
                requestId = id
                guard object["apiVersion"] as? String == "1.0" else { throw WorkbenchIPCError(.unsupportedVersion) }
                let lifecycleOnly = ["system.hello", "system.capabilities", "system.health",
                                     "service.lifecycle", "service.drain", "service.stop", "service.prepareRemoval",
                                     "gui.release", WorkbenchWorkspaceOperationStatus.method,
                                     WorkbenchWorkspaceOperationStatus.cancelMethod].contains(method)
                let jobID = id + "." + sessionJobSuffix
                let jobToken: UUID?
                if lifecycleOnly { jobToken = nil }
                else {
                    do { jobToken = try serviceLifecycle.beginJob(id: jobID, cancel: {}) }
                    catch { throw WorkbenchIPCError(.serviceBusy) }
                }
                var requestCompleted = false
                defer {
                    if let jobToken {
                        serviceLifecycle.finishJob(id: jobID, token: jobToken,
                            completion: !requestCompleted && serviceLifecycle.cancelRequested
                                ? .interrupted : .completed)
                    }
                }
                let requestCancelled: () -> Bool = { [weak self] in
                    guard let self else { return true }
                    return self.isStopped() || self.serviceLifecycle.cancelRequested ||
                        self.workspaceOperations.isCancelRequested(id: id) || Self.peerDisconnected(fd)
                }
                if method == "service.stop" {
                    guard saidHello, params.isEmpty, let onShutdown else { throw WorkbenchIPCError(.methodNotFound) }
                    do {
                        if removalPrepared { try serviceLifecycle.commitRemoval(owner: removalOwner) }
                        else { _ = try serviceLifecycle.drain(timeout: 8) }
                    }
                    catch { throw WorkbenchIPCError(.serviceBusy) }
                    let current = try domain?.snapshot(instanceId: snapshot.instanceId) ?? snapshot
                    try send(fd, response: WorkbenchWireResponse(requestId: id, result: current))
                    shutdownRequested = true
                    onShutdown()
                    return
                } else if ["service.lifecycle", "service.drain", "service.prepareRemoval"].contains(method) {
                    guard saidHello, let version = params["schemaVersion"] as? NSNumber,
                          CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
                          Set(params.keys) == ["schemaVersion"] else { throw WorkbenchIPCError(.invalidRequest) }
                    let result: WorkbenchServiceLifecycleResult
                    if method == "service.prepareRemoval" {
                        do { try serviceLifecycle.prepareRemoval(owner: removalOwner) }
                        catch { throw WorkbenchIPCError(.serviceBusy) }
                        removalPrepared = true
                        result = WorkbenchServiceLifecycleResult(snapshot: serviceLifecycle.snapshot(), drained: true)
                    } else if method == "service.drain" {
                        let interrupted: [String]
                        do { interrupted = try serviceLifecycle.drain(timeout: 8) }
                        catch { throw WorkbenchIPCError(.serviceBusy) }
                        result = WorkbenchServiceLifecycleResult(snapshot: serviceLifecycle.snapshot(),
                            interruptedJobIDs: interrupted, drained: true)
                    } else {
                        result = WorkbenchServiceLifecycleResult(snapshot: serviceLifecycle.snapshot())
                    }
                    try result.validate(for: method)
                    try send(fd, response: WorkbenchWireResponse(requestId: id, lifecycle: result))
                } else if method == WorkbenchOperationInventory.listMethod {
                    guard saidHello, let domain,
                          Set(params.keys) == ["schemaVersion"],
                          let version = params["schemaVersion"] as? NSNumber,
                          CFGetTypeID(version) != CFBooleanGetTypeID(),
                          version.doubleValue == 1 else {
                        throw WorkbenchIPCError(.invalidRequest)
                    }
                    let deployments = try domain.deploymentOperationInventory()
                    let copies = try workspaceOperations.history()
                    let inventory = WorkbenchOperationInventory(instanceId: snapshot.instanceId,
                        copies: copies.operations.map { WorkbenchOperationEntry(copy: $0,
                            durable: workspaceOperations.durable) },
                        deployments: deployments.entries,
                        workspaceHistoryTruncated: copies.truncated,
                        deploymentHistoryTruncated: deployments.truncated)
                    try inventory.validate()
                    try send(fd, response: WorkbenchWireResponse(requestId: id,
                        operationInventory: inventory))
                    requestCompleted = true
                } else if method == WorkbenchOperationInventory.showMethod ||
                            method == WorkbenchOperationInventory.cancelMethod {
                    guard saidHello, let domain,
                          Set(params.keys) == ["schemaVersion", "operationId"],
                          let version = params["schemaVersion"] as? NSNumber,
                          CFGetTypeID(version) != CFBooleanGetTypeID(),
                          version.doubleValue == 1,
                          let operationId = params["operationId"] as? String,
                          UUID(uuidString: operationId) != nil else {
                        throw WorkbenchIPCError(.invalidRequest)
                    }
                    let entry: WorkbenchOperationEntry?
                    if let copy = method == WorkbenchOperationInventory.cancelMethod
                        ? try (workspaceOperations.requestCancel(id: operationId) ??
                               workspaceOperations.historical(operationId))
                        : try workspaceOperations.historical(operationId) {
                        entry = WorkbenchOperationEntry(copy: copy,
                            durable: workspaceOperations.durable)
                    } else {
                        entry = try method == WorkbenchOperationInventory.cancelMethod
                            ? domain.cancelDeploymentOperation(operationId)
                            : domain.deploymentOperation(operationId)
                    }
                    guard let entry else { throw WorkbenchIPCError(.unavailable) }
                    try entry.validate()
                    try send(fd, response: WorkbenchWireResponse(requestId: id,
                        operationEntry: entry))
                    requestCompleted = true
                } else if method == WorkbenchRetainedDeploymentEvidenceRead.method {
                    guard saidHello, let domain,
                          Set(params.keys) == ["schemaVersion", "expectedWorkspaceId",
                                               "expectedSelectionGeneration", "deviceId"],
                          let version = params["schemaVersion"] as? NSNumber,
                          CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
                          let workspaceId = params["expectedWorkspaceId"] as? String,
                          WorkspaceValidation.id(workspaceId),
                          let generation = params["expectedSelectionGeneration"] as? NSNumber,
                          CFGetTypeID(generation) != CFBooleanGetTypeID(),
                          generation.doubleValue == Double(generation.intValue),
                          generation.intValue > 0,
                          let deviceId = params["deviceId"] as? String,
                          WorkspaceValidation.id(deviceId) else {
                        throw WorkbenchIPCError(.invalidRequest)
                    }
                    let evidence = try domain.retainedDeploymentEvidence(
                        workspaceId: workspaceId, generation: generation.intValue,
                        deviceId: deviceId)
                    try send(fd, response: WorkbenchWireResponse(requestId: id,
                        retainedDeploymentEvidence: evidence))
                    requestCompleted = true
                } else if let selected = WorkbenchScreenMutationMethod(rawValue: method) {
                    guard saidHello, let domain else { throw WorkbenchIPCError(.methodNotFound) }
                    let request = try WorkbenchScreenMutationRequest.parse(selected, params)
                    let result = try domain.performScreenMutation(request)
                    try send(fd, response: WorkbenchWireResponse(requestId: id,
                        screenMutation: result))
                    requestCompleted = true
                } else if method == WorkbenchWorkspaceOperationList.method {
                    guard saidHello, Set(params.keys) == ["schemaVersion"],
                          let version = params["schemaVersion"] as? NSNumber,
                          CFGetTypeID(version) != CFBooleanGetTypeID(),
                          version.doubleValue == 1 else { throw WorkbenchIPCError(.invalidRequest) }
                    let operations = workspaceOperations.list(instanceId: snapshot.instanceId)
                    try operations.validate()
                    try send(fd, response: WorkbenchWireResponse(requestId: id,
                        workspaceOperationList: operations))
                    requestCompleted = true
                } else if method == WorkbenchWorkspaceOperationStatus.method ||
                    method == WorkbenchWorkspaceOperationStatus.cancelMethod {
                    guard saidHello, Set(params.keys) == ["schemaVersion", "operationId"],
                          let version = params["schemaVersion"] as? NSNumber,
                          CFGetTypeID(version) != CFBooleanGetTypeID(), version.intValue == 1,
                          version.doubleValue == 1,
                          let operationId = params["operationId"] as? String,
                          UUID(uuidString: operationId) != nil else {
                        throw WorkbenchIPCError(.invalidRequest)
                    }
                    let status = method == WorkbenchWorkspaceOperationStatus.cancelMethod
                        ? try workspaceOperations.requestCancel(id: operationId)
                        : workspaceOperations.get(id: operationId)
                    guard let status else {
                        throw WorkbenchIPCError(.unavailable)
                    }
                    try status.validate()
                    try send(fd, response: WorkbenchWireResponse(requestId: id,
                        workspaceOperation: status))
                    requestCompleted = true
                } else if method == WorkbenchToolchainRequirementsRead.method {
                    guard saidHello, let domain, Set(params.keys) == ["schemaVersion"],
                          let version = params["schemaVersion"] as? NSNumber,
                          CFGetTypeID(version) != CFBooleanGetTypeID(),
                          version.doubleValue == 1 else {
                        throw WorkbenchIPCError(.invalidRequest)
                    }
                    let requirements = try domain.toolchainRequirements()
                    try send(fd, response: WorkbenchWireResponse(requestId: id,
                        toolchainRequirements: requirements))
                    requestCompleted = true
                } else if method == WorkbenchToolchainInstallResult.method {
                    guard saidHello, let domain,
                          Set(params.keys) == ["schemaVersion", "expectedWorkspaceId",
                                               "expectedSelectionGeneration"],
                          let version = params["schemaVersion"] as? NSNumber,
                          CFGetTypeID(version) != CFBooleanGetTypeID(),
                          version.doubleValue == 1,
                          let workspaceId = params["expectedWorkspaceId"] as? String,
                          WorkspaceValidation.id(workspaceId),
                          let generation = params["expectedSelectionGeneration"] as? NSNumber,
                          CFGetTypeID(generation) != CFBooleanGetTypeID(),
                          generation.doubleValue == Double(generation.intValue),
                          generation.intValue > 0,
                          generation.intValue <= WorkspaceValidation.maxUInt else {
                        throw WorkbenchIPCError(.invalidRequest)
                    }
                    let installed = try domain.installRequiredToolchains(
                        workspaceId: workspaceId, selectionGeneration: generation.intValue)
                    try installed.validate()
                    try send(fd, response: WorkbenchWireResponse(requestId: id,
                        toolchainInstall: installed))
                    requestCompleted = true
                } else if method == "workspace.init" || method == "workspace.open" {
                    guard saidHello, let domain else { throw WorkbenchIPCError(.methodNotFound) }
                    guard let version = params["schemaVersion"] as? NSNumber,
                          CFGetTypeID(version) != CFBooleanGetTypeID(), version.intValue == 1,
                          version.doubleValue == 1 else { throw WorkbenchIPCError(.invalidRequest) }
                    let keys = Set(params.keys)
                    guard (method == "workspace.init" && (keys == ["schemaVersion"] || keys == ["schemaVersion", "path"])) ||
                          (method == "workspace.open" && keys == ["schemaVersion", "path"]) else { throw WorkbenchIPCError(.invalidRequest) }
                    let path = params["path"] as? String
                    guard params["path"] == nil || (path.map(WorkspaceValidation.absolute) == true),
                          method != "workspace.open" || path != nil else { throw WorkbenchIPCError(.invalidRequest) }
                    let result = try domain.selectWorkspace(path: path, create: method == "workspace.init",
                        cancelled: requestCancelled)
                    try send(fd, response: WorkbenchWireResponse(requestId: id, read: result))
                    requestCompleted = true
                } else if WorkbenchMethodRegistry.supportedMethods.contains(method) {
                    try WorkbenchMethodRegistry.validate(method: method, params: params)
                    guard saidHello || method == "system.hello" else { throw WorkbenchIPCError(.invalidRequest) }
                    saidHello = true
                    let current = try domain?.snapshot(instanceId: snapshot.instanceId,
                        cancelled: requestCancelled) ?? snapshot
                    try send(fd, response: WorkbenchWireResponse(requestId: id, result: current))
                    requestCompleted = true
                } else if let selected = WorkbenchDeviceControlMethod(rawValue: method) {
                    guard saidHello, let domain else { throw WorkbenchIPCError(.methodNotFound) }
                    let request = try WorkbenchDeviceControlRequest.parse(method: selected, params: params)
                    let result = try domain.performDevice(request, cancelled: requestCancelled)
                    do { try recordDeviceEvent(request: request, result: result) }
                    catch { throw WorkbenchIPCError(.publicationOutcomeUnknown) }
                    try send(fd, response: WorkbenchWireResponse(requestId: id, deviceAction: result))
                    requestCompleted = true
                } else if method == WorkbenchDeviceLogRead.method {
                    guard saidHello, domain != nil, let deviceEvents,
                          Set(params.keys) == ["schemaVersion", "deviceId"],
                          let version = params["schemaVersion"] as? NSNumber,
                          CFGetTypeID(version) != CFBooleanGetTypeID(),
                          version.doubleValue == 1,
                          let deviceId = params["deviceId"] as? String,
                          WorkspaceValidation.id(deviceId) else {
                        throw WorkbenchIPCError(.invalidRequest)
                    }
                    let read = try deviceEvents.read(deviceId: deviceId)
                    try send(fd, response: WorkbenchWireResponse(requestId: id, deviceLog: read))
                    requestCompleted = true
                } else if method == WorkbenchNativeDoctorRead.method {
                    guard saidHello, let domain,
                          Set(params.keys) == ["schemaVersion"],
                          let version = params["schemaVersion"] as? NSNumber,
                          CFGetTypeID(version) != CFBooleanGetTypeID(),
                          version.doubleValue == 1 else { throw WorkbenchIPCError(.invalidRequest) }
                    let read = try domain.nativeDoctor()
                    try send(fd, response: WorkbenchWireResponse(requestId: id, nativeDoctor: read))
                    requestCompleted = true
                } else if method == WorkbenchLocalReviewMethod.begin.rawValue {
                    guard saidHello, principal == .localReview, let domain else {
                        throw WorkbenchIPCError(.methodNotFound)
                    }
                    guard Set(params.keys) == ["schemaVersion", "intentId"],
                          let version = params["schemaVersion"] as? NSNumber,
                          CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
                          let intentId = params["intentId"] as? String,
                          WorkspaceValidation.id(intentId) else { throw WorkbenchIPCError(.invalidRequest) }
                    guard UUID(uuidString: intentId) != nil else {
                        throw WorkbenchIPCError(.confirmationRequired)
                    }
                    localReviewTicket = nil
                    homeAssistantTicket = nil
                    let ticket = try domain.beginConnectionReview(intentId: intentId, cancelled: requestCancelled)
                    localReviewTicket = ticket
                    try send(fd, response: WorkbenchWireResponse(requestId: id, connectionReview: ticket.review))
                    requestCompleted = true
                } else if method == WorkbenchLocalReviewMethod.confirm.rawValue {
                    guard saidHello, principal == .localReview, let domain else {
                        throw WorkbenchIPCError(.methodNotFound)
                    }
                    guard Set(params.keys) == ["schemaVersion", "reviewHandle", "expectedDeclarationHash",
                                               "expectedAuthorizationContextHash", "confirm"],
                          let version = params["schemaVersion"] as? NSNumber,
                          CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
                          let confirmed = params["confirm"] as? NSNumber,
                          CFGetTypeID(confirmed) == CFBooleanGetTypeID(), confirmed.boolValue,
                          let handle = params["reviewHandle"] as? String,
                          let declaration = params["expectedDeclarationHash"] as? String,
                          let context = params["expectedAuthorizationContextHash"] as? String else {
                        throw WorkbenchIPCError(.invalidRequest)
                    }
                    let ticket = localReviewTicket
                    localReviewTicket = nil // one attempt, even when scope or context fails
                    guard let ticket, handle == ticket.review.reviewHandle,
                          declaration == ticket.review.declarationHash,
                          context == ticket.review.authorizationContextHash else {
                        throw WorkbenchIPCError(.confirmationRequired)
                    }
                    let result = try domain.confirmConnectionReview(ticket, cancelled: requestCancelled)
                    try send(fd, response: WorkbenchWireResponse(requestId: id, connectionAction: result))
                    requestCompleted = true
                } else if method == WorkbenchHomeAssistantMethod.reviewBegin.rawValue {
                    guard saidHello, principal == .localReview, let domain else {
                        throw WorkbenchIPCError(.methodNotFound)
                    }
                    guard Set(params.keys) == ["schemaVersion", "deviceId", "dashboardId", "revision", "origin"],
                          let version = params["schemaVersion"] as? NSNumber,
                          CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
                          let deviceId = params["deviceId"] as? String,
                          let dashboardId = params["dashboardId"] as? String,
                          let revision = params["revision"] as? String,
                          let origin = params["origin"] as? String,
                          WorkspaceValidation.id(deviceId), WorkspaceValidation.id(dashboardId),
                          WorkspaceValidation.id(revision) else {
                        throw WorkbenchIPCError(.invalidRequest)
                    }
                    localReviewTicket = nil; homeAssistantTicket = nil
                    let ticket = try domain.beginHomeAssistantReview(deviceId: deviceId,
                        dashboardId: dashboardId, revision: revision, origin: origin,
                        cancelled: requestCancelled)
                    homeAssistantTicket = ticket
                    try send(fd, response: WorkbenchWireResponse(requestId: id,
                        homeAssistantReview: ticket.review))
                    requestCompleted = true
                } else if method == WorkbenchHomeAssistantMethod.reviewConfirm.rawValue {
                    guard saidHello, principal == .localReview, let domain else {
                        throw WorkbenchIPCError(.methodNotFound)
                    }
                    let ticket = homeAssistantTicket
                    homeAssistantTicket = nil // one use, including failed scope or transport
                    guard let ticket,
                          Set(params.keys) == ["schemaVersion", "reviewHandle", "declarationHash",
                                               "authorizationContextHash", "secretBase64"],
                          let version = params["schemaVersion"] as? NSNumber,
                          CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
                          params["reviewHandle"] as? String == ticket.review.reviewHandle,
                          params["declarationHash"] as? String == ticket.review.declarationHash,
                          params["authorizationContextHash"] as? String == ticket.review.authorizationContextHash,
                          let encoded = params["secretBase64"] as? String,
                          encoded.utf8.count <= 10_924,
                          let secret = Data(base64Encoded: encoded),
                          (1...8192).contains(secret.count),
                          secret.base64EncodedString() == encoded else {
                        throw WorkbenchIPCError(.confirmationRequired)
                    }
                    let result = try domain.confirmHomeAssistantReview(ticket,
                        secret: secret, cancelled: requestCancelled)
                    try send(fd, response: WorkbenchWireResponse(requestId: id,
                        homeAssistantAttempt: result))
                    requestCompleted = true
                } else if method == WorkbenchHomeAssistantMethod.status.rawValue ||
                            method == WorkbenchHomeAssistantMethod.cancelPrepared.rawValue {
                    guard saidHello, principal == .localReview, let domain else {
                        throw WorkbenchIPCError(.methodNotFound)
                    }
                    guard Set(params.keys) == ["schemaVersion", "intentId"],
                          let version = params["schemaVersion"] as? NSNumber,
                          CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
                          let intentId = params["intentId"] as? String,
                          UUID(uuidString: intentId) != nil else {
                        throw WorkbenchIPCError(.invalidRequest)
                    }
                    let result = method == WorkbenchHomeAssistantMethod.status.rawValue
                        ? try domain.homeAssistantStatus(intentId: intentId)
                        : try domain.cancelHomeAssistantPrepared(intentId: intentId)
                    try send(fd, response: WorkbenchWireResponse(requestId: id,
                        homeAssistantAttempt: result))
                    requestCompleted = true
                } else if let selected = WorkbenchConnectionControlMethod(rawValue: method) {
                    guard saidHello, let domain else { throw WorkbenchIPCError(.methodNotFound) }
                    guard principal == .localReview ||
                          selected == .intentRequest || selected == .intentInspect ||
                          selected == .update else {
                        throw WorkbenchIPCError(.methodNotFound)
                    }
                    let request = try WorkbenchConnectionControlRequest.parse(method: selected, params: params)
                    let result = try domain.performConnection(request,
                        ordinaryProposal: principal == .ordinary,
                        cancelled: requestCancelled)
                    try send(fd, response: WorkbenchWireResponse(requestId: id, connectionAction: result))
                    requestCompleted = true
                } else if method == WorkbenchSourceTextRequest.method {
                    guard saidHello, let domain else { throw WorkbenchIPCError(.methodNotFound) }
                    let request = try WorkbenchSourceTextRequest.parse(params)
                    let result = try domain.readSourceText(request, cancelled: requestCancelled)
                    try send(fd, response: WorkbenchWireResponse(requestId: id, sourceText: result))
                    requestCompleted = true
                } else if method == WorkbenchSourceChunkRequest.method {
                    guard saidHello, let domain else { throw WorkbenchIPCError(.methodNotFound) }
                    let request = try WorkbenchSourceChunkRequest.parse(params)
                    let result = try domain.readSourceChunk(request, cancelled: requestCancelled)
                    try send(fd, response: WorkbenchWireResponse(requestId: id, sourceChunk: result))
                    requestCompleted = true
                } else if let selected = WorkbenchPackageImportMethod(rawValue: method) {
                    guard saidHello, let domain else { throw WorkbenchIPCError(.methodNotFound) }
                    let request = try WorkbenchPackageImportRequest.parse(selected, params)
                    let result = try domain.performPackageImport(request, cancelled: requestCancelled)
                    try send(fd, response: WorkbenchWireResponse(requestId: id, packageImport: result))
                    requestCompleted = true
                } else if let selected = WorkbenchDeploymentMethod(rawValue: method) {
                    guard saidHello, let domain else { throw WorkbenchIPCError(.methodNotFound) }
                    let request = try WorkbenchDeploymentRequest.parse(selected, params)
                    let consent: WorkbenchDeploymentConsent = registeredGUI ? .gui() :
                        principal == .localReview
                            ? (params["approvalMode"] as? String == "scripted"
                                ? .terminalAssertion() : .terminal())
                            : .agentAssertion()
                    let result = try domain.performDeployment(request, consent: consent,
                        cancelled: requestCancelled)
                    try send(fd, response: WorkbenchWireResponse(requestId: id,
                        deploymentAction: result))
                    requestCompleted = true
                } else if let selected = WorkbenchAuthoringRecoveryMethod(rawValue: method) {
                    guard saidHello, let domain else { throw WorkbenchIPCError(.methodNotFound) }
                    if selected == .migrationApply && principal != .localReview {
                        throw WorkbenchIPCError(.methodNotFound)
                    }
                    let request = try WorkbenchAuthoringRecoveryRequest.parse(method: selected, params: params)
                    let exclusive = selected == .snapshotCreate || selected == .workspaceRelocate
                    let operationDeadlineUptime = exclusive
                        ? ProcessInfo.processInfo.systemUptime + 300 : nil
                    if exclusive {
                        guard let selected = request.expectedSelection else {
                            throw WorkbenchIPCError(.invalidRequest)
                        }
                        try workspaceOperations.begin(id: id, instanceId: snapshot.instanceId,
                            method: method, destination: params["path"] as? String ?? "",
                            workspaceId: selected.workspaceId,
                            selectionGeneration: selected.generation)
                        guard let jobToken else {
                            try? workspaceOperations.finish(id: id, state: "notStarted")
                            throw WorkbenchIPCError(.serviceBusy)
                        }
                        do { try serviceLifecycle.beginExclusiveWorkspaceJob(id: jobID,
                            token: jobToken) }
                        catch {
                            try? workspaceOperations.finish(id: id, state: "notStarted")
                            throw WorkbenchIPCError(.serviceBusy)
                        }
                    }
                    defer {
                        if exclusive, let jobToken {
                            serviceLifecycle.endExclusiveWorkspaceJob(id: jobID,
                                token: jobToken)
                        }
                    }
                    do {
                        let result = try domain.performAuthoring(request,
                            cancelled: requestCancelled,
                            operationDeadlineUptime: operationDeadlineUptime,
                            progress: { [workspaceOperations] value in
                                workspaceOperations.progress(id: id, value: value)
                            })
                        if exclusive {
                            do { try workspaceOperations.finish(id: id, state: "applied") }
                            catch { throw WorkbenchIPCError(.publicationOutcomeUnknown) }
                        }
                        try send(fd, response: WorkbenchWireResponse(requestId: id, authoringAction: result))
                        requestCompleted = true
                    } catch {
                        if exclusive { try? workspaceOperations.finish(id: id, state: "outcomeUnknown") }
                        throw error
                    }
                } else if let selected = WorkbenchGUIConsumerMethod(rawValue: method) {
                    guard saidHello, domain != nil else { throw WorkbenchIPCError(.methodNotFound) }
                    try WorkbenchGUIConsumerMethod.parse(selected, params: params)
                    switch selected {
                    case .register:
                        guard !registeredGUI, guiVerifier?.verifyConnectedPeer(socket: fd) == true else {
                            throw WorkbenchIPCError(.incompatibleOwner)
                        }
                        try serviceLifecycle.registerVerifiedGUIConsumer(guiConsumerID)
                        registeredGUI = true
                    case .renew:
                        guard registeredGUI else { throw WorkbenchIPCError(.incompatibleOwner) }
                        try serviceLifecycle.renewVerifiedGUIConsumer(guiConsumerID)
                    case .release:
                        guard registeredGUI else { throw WorkbenchIPCError(.incompatibleOwner) }
                        serviceLifecycle.releaseVerifiedGUIConsumer(guiConsumerID)
                        registeredGUI = false
                    }
                    let result = WorkbenchGUIConsumerResult(method: selected, consumerId: guiConsumerID)
                    try send(fd, response: WorkbenchWireResponse(requestId: id, guiConsumer: result))
                    requestCompleted = true
                } else if let selected = WorkbenchWorkspacePackageMethod(rawValue: method) {
                    guard saidHello, let domain else { throw WorkbenchIPCError(.methodNotFound) }
                    let request = try WorkbenchWorkspacePackageRequest.parse(selected, params)
                    let result = try domain.performWorkspacePackage(request, cancelled: requestCancelled)
                    try send(fd, response: WorkbenchWireResponse(requestId: id, workspacePackage: result))
                    requestCompleted = true
                } else {
                    guard saidHello else { throw WorkbenchIPCError(.invalidRequest) }
                    let request = try WorkbenchDomainMethodRegistry.parse(method: method, params: params, domainAvailable: domain != nil)
                    guard let domain else { throw WorkbenchIPCError(.methodNotFound) }
                    let result = try domain.perform(request, cancelled: requestCancelled)
                    try result.validate(for: request.method)
                    try send(fd, response: WorkbenchWireResponse(requestId: id, read: result))
                    requestCompleted = true
                }
            } catch {
                guard let error = error as? WorkbenchIPCError else { return }
                if [.disconnected, .timedOut].contains(error.code) { return }
                try? send(fd, response: WorkbenchWireResponse(requestId: requestId, error: error))
                // Invalid framing/JSON/dispatch closes the connection; no recovery from an
                // uncertain byte boundary or continued access after protocol rejection.
                return
            }
        }
    }
    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 100 && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }
    }
    private func recordDeviceEvent(request: WorkbenchDeviceControlRequest,
                                   result: WorkbenchDeviceActionResult) throws {
        let event: (String, String, String)?
        switch request {
        case .pairBegin: event = result.pairing.map { ($0.deviceId, "pairingBegan", "acknowledged") }
        case .pairConfirm: event = result.device.map { ($0.deviceId, "pairingConfirmed", "acknowledged") }
        case .forget(let deviceId):
            event = result.removed == true ? (deviceId, "deviceForgotten", "acknowledged") : nil
        case .settingsSet(let deviceId, _, _):
            event = (deviceId, "settingsUpdated", "acknowledged")
        case .screenSet(let deviceId):
            event = (deviceId, "screenSetObserved", "observed")
        default: event = nil
        }
        if let event {
            guard let deviceEvents else { throw WorkbenchIPCError(.unavailable) }
            try deviceEvents.append(deviceId: event.0, kind: event.1, outcome: event.2)
        }
    }
    private static func peerDisconnected(_ fd: Int32) -> Bool {
        var byte: UInt8 = 0
        let result = Darwin.recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        return result == 0 || (result < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
    }
}
#endif
