import Foundation
import ScreenpunkCore
#if os(macOS)

/// Durable machine-local storage supplied by the broker host. Implementations
/// must make begin/transition atomic and persist before returning.
public protocol WorkbenchHomeAssistantAttemptStore {
    func load(intentId: String) throws -> WorkbenchHomeAssistantAttempt?
    func begin(_ attempt: WorkbenchHomeAssistantAttempt) throws
    func transition(from: WorkbenchHomeAssistantAttempt,
                    to: WorkbenchHomeAssistantAttempt) throws
}

public struct WorkbenchHomeAssistantContext: Sendable, Equatable {
    public let workspaceId: String
    public let selectionGeneration: Int
    public let deviceId: String
    public let dashboardId: String
    public let revision: String
    public let packageDigest: String
    public let authorizationContextHash: String

    public init(workspaceId: String, selectionGeneration: Int, deviceId: String,
                dashboardId: String, revision: String, packageDigest: String,
                authorizationContextHash: String) {
        self.workspaceId = workspaceId; self.selectionGeneration = selectionGeneration
        self.deviceId = deviceId; self.dashboardId = dashboardId; self.revision = revision
        self.packageDigest = packageDigest
        self.authorizationContextHash = authorizationContextHash
    }
}

/// Created only inside the controller module after trusted local review.
/// No MCP field or ordinary-client role can construct this approval.
public struct WorkbenchHomeAssistantReviewedSetup: Sendable {
    public let intentId: String
    public let context: WorkbenchHomeAssistantContext
    public let origin: String
    public let connectionId: String
    public let expiresAt: Date

    init(intentId: String, context: WorkbenchHomeAssistantContext,
         origin: String, connectionId: String, expiresAt: Date) {
        self.intentId = intentId; self.context = context; self.origin = origin
        self.connectionId = connectionId; self.expiresAt = expiresAt
    }
}

public struct WorkbenchHomeAssistantAttempt: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        case preparing, prepared, cleanupPending, unknown, installed, cancelled
    }
    public let intentId: String
    public let workspaceId: String
    public let selectionGeneration: Int
    public let deviceId: String
    public let dashboardId: String
    public let revision: String
    public let packageDigest: String
    public let authorizationContextHash: String
    public let origin: String
    public let connectionId: String
    public let authRef: String
    public let provisioningId: String
    public let expiresAt: Date
    public var phase: Phase

    init(review: WorkbenchHomeAssistantReviewedSetup, authRef: String,
         provisioningId: String) {
        intentId = review.intentId
        workspaceId = review.context.workspaceId
        selectionGeneration = review.context.selectionGeneration
        deviceId = review.context.deviceId
        dashboardId = review.context.dashboardId
        revision = review.context.revision
        packageDigest = review.context.packageDigest
        authorizationContextHash = review.context.authorizationContextHash
        origin = review.origin; connectionId = review.connectionId
        self.authRef = authRef; self.provisioningId = provisioningId
        expiresAt = review.expiresAt; phase = .preparing
    }
    var context: WorkbenchHomeAssistantContext {
        .init(workspaceId: workspaceId, selectionGeneration: selectionGeneration,
            deviceId: deviceId, dashboardId: dashboardId, revision: revision,
            packageDigest: packageDigest,
            authorizationContextHash: authorizationContextHash)
    }
}

public enum WorkbenchHomeAssistantSetupFailure: Error, Equatable {
    case invalidReview, staleContext, expired, conflict, invalidAPI,
         unknownRemoteOutcome, invalidReceipt, cleanupPending
}

/// Verifies and stages a dedicated Home Assistant configuration. The host
/// injects its Keychain-backed secret store, durable machine-local attempt
/// store, current broker context, redirect-denying HTTP transport and existing
/// DeviceCoordinator.provisionHomeAssistant call. This helper never accesses
/// UserDefaults, Keychain or the network on its own.
public final class WorkbenchHomeAssistantSetupAdapter {
    public typealias ContextReader = () throws -> WorkbenchHomeAssistantContext
    public typealias Provisioner = (String, HomeAssistantProvisioning) async throws -> HomeAssistantProvisioningReceipt

    private let secrets: any WorkbenchSecretProvider
    private let attempts: any WorkbenchHomeAssistantAttemptStore
    private let transport: any HTTPTransport
    private let resolver: any DestinationResolver
    private let context: ContextReader
    private let provision: Provisioner
    private let now: () -> Date
    // Confirm and cancel construct separate adapters for the same journal.
    // Hold a process-wide lock across install and cleanup so cancellation
    // cannot publish "cancelled" before an in-flight install finishes.
    private static let preparationLock = NSLock()

    private static func withPreparationLock<T>(_ body: () throws -> T) rethrows -> T {
        preparationLock.lock()
        defer { preparationLock.unlock() }
        return try body()
    }

    public init(secrets: any WorkbenchSecretProvider,
                attempts: any WorkbenchHomeAssistantAttemptStore,
                transport: any HTTPTransport, resolver: any DestinationResolver,
                context: @escaping ContextReader, provision: @escaping Provisioner,
                now: @escaping () -> Date = Date.init) {
        self.secrets = secrets; self.attempts = attempts; self.transport = transport
        self.resolver = resolver; self.context = context; self.provision = provision
        self.now = now
    }

    public func prepare(review: WorkbenchHomeAssistantReviewedSetup,
                        manifest: DashboardManifest, secret: Data,
                        capability: WorkbenchTrustedLocalCapability) async throws -> WorkbenchHomeAssistantAttempt {
        _ = capability
        try check(review: review, manifest: manifest)
        guard let token = String(data: secret, encoding: .utf8),
              !token.isEmpty else { throw ConnectionFailure.validationFailed }
        var configuration = HomeAssistantProvisioning(dashboardId: review.context.dashboardId,
            connectionId: review.connectionId, provisioningId: UUID().uuidString.lowercased(),
            revision: review.context.revision, origin: review.origin,
            allowInsecureHTTP: review.origin.hasPrefix("http://"), token: token)
        configuration = try configuration.scoped(to: manifest)
        try await verifyAPI(configuration)
        try Task.checkCancellation()
        try check(review: review, manifest: manifest)
        let authRef = "ha-" + UUID().uuidString.lowercased()
        let attempt = WorkbenchHomeAssistantAttempt(review: review, authRef: authRef,
            provisioningId: configuration.provisioningId)
        return try Self.withPreparationLock {
            // Persist the cleanup handle before touching Keychain. A failed or
            // partially successful install can then be cleaned up after restart.
            try attempts.begin(attempt)
            do {
                try secrets.install(secret, for: authRef)
                var prepared = attempt; prepared.phase = .prepared
                try attempts.transition(from: attempt, to: prepared)
                return prepared
            } catch {
                do { try cleanup(intentId: attempt.intentId) }
                catch { throw WorkbenchHomeAssistantSetupFailure.cleanupPending }
                throw error
            }
        }
    }

    public func submit(intentId: String, manifest: DashboardManifest,
                       capability: WorkbenchTrustedLocalCapability) async throws -> WorkbenchHomeAssistantAttempt {
        _ = capability
        guard let attempt = try attempts.load(intentId: intentId) else {
            throw WorkbenchHomeAssistantSetupFailure.conflict
        }
        guard attempt.phase == .prepared else { throw WorkbenchHomeAssistantSetupFailure.conflict }
        try check(attempt: attempt, manifest: manifest)
        try Task.checkCancellation()
        let secret = try secrets.load(authRef: attempt.authRef)
        guard let token = String(data: secret, encoding: .utf8) else {
            throw ConnectionFailure.validationFailed
        }
        var configuration = HomeAssistantProvisioning(dashboardId: attempt.dashboardId,
            connectionId: attempt.connectionId, provisioningId: attempt.provisioningId,
            revision: attempt.revision, origin: attempt.origin,
            allowInsecureHTTP: attempt.origin.hasPrefix("http://"), token: token)
        configuration = try configuration.scoped(to: manifest)
        // Loading a credential can block while the selected workspace or
        // pairing authority changes. Recheck after that work and immediately
        // before the durable one-shot send boundary.
        try Task.checkCancellation()
        try check(attempt: attempt, manifest: manifest)
        // Persist unknown before crossing the device mutation boundary. A lost
        // response or crash cannot make this attempt eligible for blind resend.
        var uncertain = attempt; uncertain.phase = .unknown
        try attempts.transition(from: attempt, to: uncertain)
        do {
            let receipt = try await provision(attempt.deviceId, configuration)
            guard receipt.installed, receipt.deviceId == attempt.deviceId,
                  receipt.dashboardId == attempt.dashboardId,
                  receipt.revision == attempt.revision,
                  receipt.connectionId == attempt.connectionId,
                  receipt.provisioningId == attempt.provisioningId else {
                throw WorkbenchHomeAssistantSetupFailure.invalidReceipt
            }
            var installed = uncertain; installed.phase = .installed
            try attempts.transition(from: uncertain, to: installed)
            return installed
        } catch { throw WorkbenchHomeAssistantSetupFailure.unknownRemoteOutcome }
    }

    public func cancelPrepared(intentId: String,
                               capability: WorkbenchTrustedLocalCapability) throws {
        _ = capability
        try Self.withPreparationLock { try cleanup(intentId: intentId) }
    }

    private func cleanup(intentId: String) throws {
        guard let attempt = try attempts.load(intentId: intentId),
              [.preparing, .prepared, .cleanupPending].contains(attempt.phase) else {
            throw WorkbenchHomeAssistantSetupFailure.conflict
        }
        var pending = attempt
        if attempt.phase != .cleanupPending {
            pending.phase = .cleanupPending
            try attempts.transition(from: attempt, to: pending)
        }
        // The injected provider must treat an already absent ref as removed;
        // a crash may occur after deletion but before this terminal CAS.
        try secrets.remove(authRef: pending.authRef)
        var cancelled = pending; cancelled.phase = .cancelled
        try attempts.transition(from: pending, to: cancelled)
    }

    private func check(review: WorkbenchHomeAssistantReviewedSetup,
                       manifest: DashboardManifest) throws {
        guard WorkspaceValidation.id(review.intentId),
              WorkspaceValidation.id(review.context.workspaceId),
              review.context.selectionGeneration > 0,
              WorkspaceValidation.id(review.context.deviceId),
              WorkspaceValidation.id(review.context.dashboardId),
              WorkspaceValidation.id(review.context.revision),
              WorkspaceValidation.sha256(review.context.packageDigest),
              WorkspaceValidation.sha256(review.context.authorizationContextHash),
              !review.connectionId.isEmpty, review.connectionId.utf8.count <= 128,
              now() < review.expiresAt,
              manifest.dashboardId == review.context.dashboardId,
              manifest.revision == review.context.revision,
              manifest.digest == review.context.packageDigest,
              try DeploymentDigest.digest(for: manifest) == review.context.packageDigest,
              manifest.connections.contains(where: { $0.alias == "home" }) else {
            throw WorkbenchHomeAssistantSetupFailure.invalidReview
        }
        try PackageValidator.validate(manifest)
        guard try context() == review.context else {
            throw WorkbenchHomeAssistantSetupFailure.staleContext
        }
    }

    private func check(attempt: WorkbenchHomeAssistantAttempt,
                       manifest: DashboardManifest) throws {
        guard now() < attempt.expiresAt else { throw WorkbenchHomeAssistantSetupFailure.expired }
        let review = WorkbenchHomeAssistantReviewedSetup(intentId: attempt.intentId,
            context: attempt.context, origin: attempt.origin,
            connectionId: attempt.connectionId, expiresAt: attempt.expiresAt)
        try check(review: review, manifest: manifest)
    }

    private func verifyAPI(_ configuration: HomeAssistantProvisioning) async throws {
        let grant = configuration.connectionGrant(path: "/api/", write: false)
        let destination = try ConnectionPolicy.authorize(grant: grant, operationName: "request",
            parameters: [:],
            resolvedAddresses: resolver.addresses(for: try ConnectionPolicy.originHost(configuration.origin)),
            binding: .init(authRef: grant.authRef, placement: .bearer))
        let response = try await transport.send(.init(url: destination.url, method: "GET",
            headers: ["Authorization": "Bearer " + configuration.token, "Accept": "application/json"],
            body: nil, timeout: 10, maxBytes: 16_384))
        guard response.body.count <= 16_384 else { throw ConnectionFailure.sizeLimit }
        guard response.status != 401 && response.status != 403 else {
            throw ConnectionFailure.permissionRequired
        }
        guard response.status == 200,
              let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: String],
              object["message"] == "API running." else {
            throw WorkbenchHomeAssistantSetupFailure.invalidAPI
        }
    }
}
#endif
