import Foundation
import FirebaseCore
import FirebaseAuth
import FirebaseDatabase
@_spi(NativeInstallation) import ScreenpunkCore

/// Events are hints. Neither a cursor nor presence authorizes a delivery or a mount.
enum NativeCloudRealtimeEvent { case connected, disconnected, cursor(String), sessionRefreshRequired }

@MainActor protocol NativeCloudRealtimeDriver: AnyObject {
    func start(_ session: NativeInstallationRealtimeSession,
        event: @escaping @MainActor (NativeCloudRealtimeEvent) -> Void) async throws
    func stop()
}

/// Coalesces installation-scoped hints and discards callbacks from retired sessions.
/// The native owner remains authoritative when the realtime connection is unavailable.
@MainActor final class NativeCloudRealtimeConsumer {
    private let driver: any NativeCloudRealtimeDriver
    private var generation = UUID()
    private var healthChanged: (@MainActor (Bool) -> Void)?
    private var observedCursor: String?
    private var acknowledgedCursor: String?
    private(set) var isStarted = false
    init(driver: (any NativeCloudRealtimeDriver)? = nil) { self.driver = driver ?? FirebaseInstallationRealtimeDriver() }
    func start(_ session: NativeInstallationRealtimeSession, healthChanged: @escaping @MainActor (Bool) -> Void = { _ in },
        reconcile: @escaping @MainActor () -> Void) async throws {
        stop()
        self.healthChanged = healthChanged
        healthChanged(false)
        let expected = generation
        observedCursor = session.cursor
        try await driver.start(session) { [weak self] event in
            guard let self, self.generation == expected else { return }
            switch event {
            case .sessionRefreshRequired:
                // Reconnect is not a keepalive. A fresh device-authorized token
                // gives the replacement connection a different deletion scope.
                self.stop(); reconcile()
            case .disconnected:
                self.healthChanged?(false)
            case .connected:
                self.healthChanged?(true)
                // Always reconcile on reconnect, including when its cursor is unchanged.
                reconcile()
            case .cursor(let cursor):
                guard Self.validCursor(cursor), cursor != self.observedCursor else { return }
                self.observedCursor = cursor
                if cursor != self.acknowledgedCursor { reconcile() }
            }
        }
        guard generation == expected, !Task.isCancelled else { throw CancellationError() }
        isStarted = true
    }
    func acknowledgeReconciliation() { acknowledgedCursor = observedCursor }
    func stop() {
        generation = UUID(); isStarted = false
        healthChanged?(false); healthChanged = nil
        observedCursor = nil; acknowledgedCursor = nil; driver.stop()
    }
    static func validCursor(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 20 && value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
            && (value == "0" || !value.hasPrefix("0"))
    }
}

/// Uses the already pinned Firebase SDK, with a separate named app/auth instance
/// from human Google sign-in. Firebase owns token refresh and network reconnect.
@MainActor final class FirebaseInstallationRealtimeDriver: NativeCloudRealtimeDriver {
    private var generation = UUID()
    private var database: Database?
    private var wake: DatabaseReference?
    private var connection: DatabaseReference?
    private var presence: DatabaseReference?
    private var transportConnected = false
    private var hasConnected = false
    func start(_ session: NativeInstallationRealtimeSession,
        event: @escaping @MainActor (NativeCloudRealtimeEvent) -> Void) async throws {
        stop()
        let expected = generation
        let configuration = try CloudNativeConfiguration.load()
        guard session.apiKey == configuration.apiKey, session.projectID == configuration.projectID,
            session.appID == configuration.appID, session.senderID == configuration.senderID else { throw CloudNativeIdentityError.notConfigured }
        let name = "ScreenpunkInstallationRealtime"
        if FirebaseApp.app(name: name) == nil {
            let options = FirebaseOptions(googleAppID: configuration.appID, gcmSenderID: configuration.senderID)
            options.apiKey = configuration.apiKey; options.projectID = configuration.projectID
            options.bundleID = configuration.bundleID
            FirebaseApp.configure(name: name, options: options)
        }
        guard let app = FirebaseApp.app(name: name), app.options.googleAppID == configuration.appID,
            app.options.apiKey == configuration.apiKey, app.options.projectID == configuration.projectID,
            app.options.bundleID == configuration.bundleID else { throw CloudNativeIdentityError.notConfigured }
        let auth = Auth.auth(app: app)
        let waiter = NativeRealtimeSignInWaiter()
        let uid: String = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.continuation = continuation
                if Task.isCancelled { waiter.finish(.failure(CancellationError())); return }
                auth.signIn(withCustomToken: session.customToken) { result, error in
                    let outcome: Result<String, Error> = result.map { .success($0.user.uid) }
                        ?? .failure(error ?? CloudNativeIdentityError.invalidCredential)
                    Task { @MainActor in waiter.finish(outcome) }
                }
            }
        } onCancel: { Task { @MainActor in waiter.finish(.failure(CancellationError())) } }
        try Task.checkCancellation()
        guard expected == generation, uid == session.firebaseUID else { throw CloudNativeIdentityError.invalidCredential }
        let database = Database.database(app: app, url: session.databaseURL.absoluteString)
        self.database = database
        let wake = database.reference(withPath: session.wakePath)
        self.wake = wake
        wake.observe(.value) { [weak self] snapshot in
            guard let value = snapshot.value as? [String: Any], let cursor = value["cursor"] as? String else { return }
            Task { @MainActor in
                guard let self, self.generation == expected else { return }
                event(.cursor(cursor))
            }
        }
        let connection = database.reference(withPath: ".info/connected")
        self.connection = connection
        connection.observe(.value) { [weak self] snapshot in
            guard let connected = snapshot.value as? Bool else { return }
            Task { @MainActor in
                guard let self, self.generation == expected, self.transportConnected != connected else { return }
                self.transportConnected = connected
                guard connected else { event(.disconnected); return }
                if self.hasConnected { event(.sessionRefreshRequired); return }
                self.hasConnected = true
                // Each actual network connection needs a new server-minted
                // presenceConnectionId; a normal SDK ID-token refresh does not.
                if await self.claimPresence(session, database: database, expected: expected) {
                    guard self.generation == expected else { return }
                    event(.connected)
                }
            }
        }
        database.goOnline()
    }
    private func claimPresence(_ session: NativeInstallationRealtimeSession, database: Database, expected: UUID) async -> Bool {
        for slot in session.presenceSlots {
            guard generation == expected, transportConnected else { return false }
            let candidate = database.reference(withPath: session.presencePath).child(slot)
            let registered: Bool = await withCheckedContinuation { continuation in
                candidate.onDisconnectRemoveValue { error, _ in continuation.resume(returning: error == nil) }
            }
            guard generation == expected, transportConnected else { return false }
            guard registered else { continue }
            let claimed: Bool = await withCheckedContinuation { continuation in
                candidate.runTransactionBlock({ data in
                    guard data.value == nil || data.value is NSNull else { return TransactionResult.abort() }
                    data.value = ["connectionId": session.presenceConnectionID.uuidString.lowercased(), "connectedAt": ServerValue.timestamp()]
                    return TransactionResult.success(withValue: data)
                }, andCompletionBlock: { error, committed, _ in continuation.resume(returning: error == nil && committed) }, withLocalEvents: false)
            }
            guard generation == expected, transportConnected else { return false }
            if claimed { presence = candidate; return true }
            try? await candidate.cancelDisconnectOperations()
        }
        return false
    }
    func stop() {
        generation = UUID()
        wake?.removeAllObservers(); connection?.removeAllObservers()
        presence?.removeValue()
        database?.goOffline()
        wake = nil; connection = nil; presence = nil; database = nil
        transportConnected = false; hasConnected = false
    }
}

/// Explicit rollout switch. Disabled builds retain their already qualified transport.
enum NativeCloudRealtimeConfiguration {
    static var enabled: Bool { enabled(info: Bundle.main.infoDictionary ?? [:]) }
    static func enabled(info: [String: Any]) -> Bool { info["ScreenpunkCloudRealtimeEnabled"] as? Bool == true }
    static func reconciliationSeconds(realtimeEnabled: Bool, concurrentControl: Bool, realtimeHealthy: Bool = false) -> Int {
        realtimeEnabled ? (realtimeHealthy ? 21600 : 900) : (concurrentControl ? 5 : 60)
    }
}

@MainActor private final class NativeRealtimeSignInWaiter {
    var continuation: CheckedContinuation<String, Error>?
    func finish(_ result: Result<String, Error>) {
        let pending = continuation; continuation = nil; pending?.resume(with: result)
    }
}
