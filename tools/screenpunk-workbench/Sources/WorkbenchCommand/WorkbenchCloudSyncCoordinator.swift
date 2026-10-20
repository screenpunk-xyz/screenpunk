import Foundation
import CryptoKit
import ScreenpunkController

/// Internal constructor seam. Shipping defaults use the unchanged controller consumer.
protocol WorkbenchCloudRealtimeListener: Sendable {
    func start(_ session: ControllerCloudRealtimeSession,
               onCursor: @escaping @Sendable (String) async throws -> Void,
               onReconnect: @escaping @Sendable () async throws -> Void,
               onSessionRefreshRequired: @escaping @Sendable () async -> Void,
               onTerminal: @escaping @Sendable () async -> Void) async throws
    func stop() async
}
extension ControllerCloudRealtimeConsumer: WorkbenchCloudRealtimeListener {}

/// One owner profile and one push listener for the shared origin namespace.
actor WorkbenchCloudSyncCoordinator {
    private let baseURL: URL
    private let environment: [String: String]
    private let broker: WorkbenchBrokerEnvironment
    private let home: URL
    private let machine: URL
    private let source: WorkbenchCloudSyncEventSource
    private let makeConsumer: @Sendable () -> any WorkbenchCloudRealtimeListener
    private var localClient: WorkbenchBrokerClient?
    private var facade: ControllerCloudWorkbench?
    private var clientId: String?
    private var consumer: (any WorkbenchCloudRealtimeListener)?
    private var refreshRequired = true
    private var startupRequested = false
    private var listenerID: UUID?
    private var listenerGeneration: String?
    private var listenerAuthorityExpiresAtMs: Int64?
    private var terminalParked = false
    private var listenerRequest: ControllerCloudScreenSyncRequest?
    init(baseURL: URL, environment: [String: String], broker: WorkbenchBrokerEnvironment, home: URL,
         source: WorkbenchCloudSyncEventSource,
         preparedConnection: (WorkbenchBrokerClient, ControllerCloudWorkbench, String)? = nil,
         makeConsumer: @escaping @Sendable () -> any WorkbenchCloudRealtimeListener = { ControllerCloudRealtimeConsumer() }) {
        // Internal synthetic-fixture injection only. Production constructs its normal broker,
        // trusted deployment, Keychain session and realtime consumer through the defaults.
        self.makeConsumer = makeConsumer
        self.localClient = preparedConnection?.0; self.facade = preparedConnection?.1; self.clientId = preparedConnection?.2
        self.baseURL = baseURL; self.environment = environment; self.broker = broker; self.home = home; self.source = source
        machine = broker.runtimeDirectory.appendingPathComponent("machine")
    }
    private func client() throws -> WorkbenchBrokerClient {
        if let localClient { _ = try localClient.reconnectIfPeerClosed(); return localClient }
        let client = WorkbenchBrokerClient(environment: broker, reconnectClosedConnections: true)
        try client.connect()
        guard try client.hello().controllerHomePath == home.path else { client.close(); throw ControllerCloudError.invalidConfiguration }
        localClient = client; return client
    }
    func idle() async {
        do {
            guard let owner = try ControllerCloudWorkbench.screenSyncOwner(baseURL: baseURL, machineRoot: machine) else {
                listenerID = nil; listenerGeneration = nil; await consumer?.stop(); consumer = nil; facade = nil; clientId = nil; refreshRequired = true
                source.watchWorkspace(nil); startupRequested = false; return
            }
            let client = try client()
            let selected = try client.workspaceStatus(); source.watchWorkspace(selected.path)
            if !startupRequested {
                startupRequested = true
                try await ControllerCloudWorkbench.requestScreenSync(baseURL: baseURL, client: client, machineRoot: machine, trigger: .appOpened)
            }
            if clientId != nil && clientId != owner { listenerID = nil; listenerGeneration = nil; await consumer?.stop(); consumer = nil; facade = nil; clientId = nil; refreshRequired = true }
        } catch { failed() }
    }
    func policyChanged() async {
        guard let token = listenerID else { return }
        // Independently observed local consent can invalidate a suspended network operation.
        if (try? ControllerCloudWorkbench.screenSyncOwner(baseURL: baseURL, machineRoot: machine)) != clientId ||
            listenerRequest.map({ request in (try? facade?.validateScreenSyncRequest(request)) == nil }) == true {
            listenerID = nil; listenerGeneration = nil
            await consumer?.stop()
            if listenerID == nil { consumer = nil; refreshRequired = true }
        }
        _ = token
    }
    func localChange() async throws {
        guard source.takeLocalChange(), try ControllerCloudWorkbench.screenSyncOwner(baseURL: baseURL, machineRoot: machine) != nil else { return }
        // Debounce only a real filesystem event. This timer never schedules a remote check itself.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let client = try client()
        let status = try await ControllerCloudWorkbench.localScreenSyncStatus(baseURL: baseURL, client: client, machineRoot: machine)
        guard status.screenSyncEnabled else { return }
        for (dashboard, row) in status.screenSyncScreens where row.state == "pending" {
            try await ControllerCloudWorkbench.requestScreenSync(baseURL: baseURL, client: client, machineRoot: machine,
                trigger: .localChanged, dashboardId: dashboard)
        }
    }
    private func sameListenerScope(_ request: ControllerCloudScreenSyncRequest) -> Bool {
        guard let previous = listenerRequest else { return false }
        return previous.epoch == request.epoch && previous.accountId == request.accountId &&
            previous.workspaceId == request.workspaceId && previous.localWorkspaceId == request.localWorkspaceId && previous.clientId == request.clientId
    }
    private func hasCurrentListener(_ request: ControllerCloudScreenSyncRequest) -> Bool {
        listenerID != nil && consumer != nil && sameListenerScope(request) &&
            (listenerAuthorityExpiresAtMs ?? 0) > Int64(Date().timeIntervalSince1970 * 1000)
    }
    func process(_ request: ControllerCloudScreenSyncRequest) async throws -> Bool {
        guard try ControllerCloudWorkbench.screenSyncOwner(baseURL: baseURL, machineRoot: machine) == request.clientId else { return false }
        if terminalParked && sameListenerScope(request) && [.remoteInvalidation, .reconnected].contains(request.trigger) { return false }
        terminalParked = false
        let client = try client()
        source.watchWorkspace(try client.workspaceStatus().path)
        if clientId != request.clientId {
            listenerID = nil; listenerGeneration = nil; await consumer?.stop(); consumer = nil; facade = nil; refreshRequired = true
            guard try ControllerCloudKeychain(server: baseURL, clientID: request.clientId).load() != nil else { return false }
            let config = try await ControllerCloudConfiguration.deployment(clientID: request.clientId, environment: environment, machineRoot: machine)
            facade = try ControllerCloudWorkbench(configuration: config, client: client, machineRoot: machine)
            clientId = request.clientId
        }
        guard let facade else { return false }
        if refreshRequired || !hasCurrentListener(request) {
            let renew = refreshRequired && listenerID != nil
            // Rotation may revoke the old remote generation while the POST is suspended.
            // Fence its callbacks before any await so an old terminal cannot park its successor.
            listenerID = nil; listenerGeneration = nil
            await consumer?.stop(); consumer = nil
            try facade.validateScreenSyncRequest(request)
            let session = try await facade.prepareScreenSyncSession(request, renew: renew)
            try facade.validateScreenSyncRequest(request)
            let consumer = makeConsumer(); self.consumer = consumer
            let token = UUID(); listenerID = token; listenerGeneration = session.generationId
            listenerAuthorityExpiresAtMs = session.authorityExpiresAtMs; listenerRequest = request
            refreshRequired = false
            do {
                try await consumer.start(session,
                    onCursor: { [weak self] _ in try await self?.enqueue(.remoteInvalidation, token: token, request: request) },
                    onReconnect: { [weak self] in try await self?.enqueue(.reconnected, token: token, request: request) },
                    onSessionRefreshRequired: { [weak self] in await self?.renew(token: token, request: request) },
                    onTerminal: { [weak self] in await self?.terminal(token: token, request: request) })
                try facade.validateScreenSyncRequest(request)
                guard listenerID == token else { return false }
            } catch {
                if listenerID == token { listenerID = nil; listenerGeneration = nil }
                await consumer.stop()
                refreshRequired = true
                if (try? facade.validateScreenSyncRequest(request)) != nil { failed() }
                return false // Never acknowledge the sole wake when no listener was established.
            }
        }
        let outcome = try await facade.processScreenSyncRequest(request)
        try facade.validateScreenSyncRequest(request)
        if !hasCurrentListener(request) && !refreshRequired && !terminalParked {
            // The authority timer normally queues this during catch-up. Close the scheduling
            // race without acknowledging the only durable event if it has just expired.
            refreshRequired = true
            try facade.requestScreenSync(.reconnected, authorizedBy: request)
        }
        return outcome.completed && !refreshRequired && !terminalParked && hasCurrentListener(request)
    }
    private func enqueue(_ trigger: ControllerCloudScreenSyncTrigger, token: UUID, request: ControllerCloudScreenSyncRequest) throws {
        guard listenerID == token, let facade else { throw CancellationError() }
        // No suspension between session fence, scoped policy admission and the durable queue write.
        try facade.requestScreenSync(trigger, authorizedBy: request)
    }
    private func renew(token: UUID, request: ControllerCloudScreenSyncRequest) {
        guard listenerID == token else { return }
        do { try enqueue(.reconnected, token: token, request: request); refreshRequired = true } catch { }
    }
    private func terminal(token: UUID, request: ControllerCloudScreenSyncRequest) {
        guard listenerID == token, let facade else { return }
        // A terminal callback may describe only its still-current policy scope.
        guard (try? ControllerCloudWorkbench.screenSyncOwner(baseURL: baseURL, machineRoot: machine)) == request.clientId,
              (try? facade.validateScreenSyncRequest(request)) != nil else { return }
        terminalParked = true; refreshRequired = true; failed()
    }
    func stop() async { listenerID = nil; listenerGeneration = nil; await consumer?.stop(); consumer = nil; localClient?.close(); localClient = nil }
    nonisolated func failed() {
        let value = ["state": "paused", "reason": "Screen sync could not finish. Local copies are preserved.",
            "checkedAt": ISO8601DateFormatter().string(from: Date())]
        if let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            try? bytes.write(to: machine.appendingPathComponent("cloud-sync-status.json"), options: .atomic)
        }
    }
}
