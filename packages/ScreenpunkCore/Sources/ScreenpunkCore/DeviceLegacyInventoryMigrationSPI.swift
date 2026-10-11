import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Supplied legacy bytes and approvals are requalified, never converted from screen metadata.
/// This input must remain within the trusted device process; descriptions omit all credentials.
@_spi(NativeInstallation) public struct DeviceLegacyMigrationScreen: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let entryID: UUID
    let packageOperationID: UUID
    let displayName: String
    let revision: StoredRevision
    let manifest: Data
    let files: [String: Data]
    let homeAssistant: HomeAssistantProvisioning?
    let generic: ConnectionProvisioning?
    let publicReads: PublicReadProvisioning?
    public init(entryID: UUID, packageOperationID: UUID, displayName: String, revision: StoredRevision,
        manifest: Data, files: [String: Data], homeAssistant: HomeAssistantProvisioning?,
        generic: ConnectionProvisioning?, publicReads: PublicReadProvisioning?) {
        self.entryID = entryID; self.packageOperationID = packageOperationID; self.displayName = displayName
        self.revision = revision; self.manifest = manifest; self.files = files
        self.homeAssistant = homeAssistant; self.generic = generic; self.publicReads = publicReads
    }
    public var entryIdentity: UUID { entryID }
    public var packagePreparationIdentity: UUID { packageOperationID }
    public func retainingPackagePreparationIdentity(_ operationID: UUID) -> Self {
        .init(entryID: entryID, packageOperationID: operationID, displayName: displayName, revision: revision,
            manifest: manifest, files: files, homeAssistant: homeAssistant, generic: generic, publicReads: publicReads)
    }
    public var description: String { "Legacy migration input (redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// Exact transaction using the existing durable local provisioning machinery. No activation,
/// authority switch, vault deletion, or runtime admission occurs here. Callers retain the legacy
/// data until the mixed inventory transaction has separately completed and been qualified.
enum DeviceLegacyInventoryMigration {
    static func prepareAndCommit(screens: [DeviceLegacyMigrationScreen], selected: UUID?,
        owner: PairingIdentity, profile: DeviceProfile, profileID: String,
        roots: DeviceProvisioningRoots, operationID: UUID, grantOperationID: UUID,
        generationID: UUID, grantRevisionID: UUID, legacyGrantSet: String?,
        journal: DeviceLocalProvisioningIntentStore, packages: DevicePackagePreparationStore,
        grants: DeviceGrantPreparationStore, structural: DeviceStructuralStore,
        validateOriginal: () throws -> Void) throws -> DeviceBoundRestoredRuntimeBinding {
        guard screens.count <= 12, Set(screens.map(\.entryID)).count == screens.count,
            Set(screens.map(\.packageOperationID)).count == screens.count else { throw DeviceLocalCompleteSetFailure.invalidInput }
        try validateOriginal()
        let qualified = try screens.map { screen in
            try DevicePackageQualifier.qualify(.init(manifest: screen.manifest,
                files: screen.files.map { .init(path: $0.key, bytes: $0.value) }),
                expected: .init(revision: screen.revision, target: profile, profileID: profileID))
        }
        var credentials: [DeviceGrantCredentialInput] = []
        let entries = zip(screens, qualified).map { screen, _ in
            var references: [DeviceGrantCredentialReference] = []
            func append(_ kind: DeviceGrantCredentialKind, _ key: String, _ bytes: Data) {
                #if canImport(CryptoKit)
                var uuidBytes = Array(SHA256.hash(data: Data((grantRevisionID.uuidString + "\0" + screen.entryID.uuidString + "\0" + kind.rawValue + "\0" + key).utf8)).prefix(16))
                uuidBytes[6] = (uuidBytes[6] & 0x0f) | 0x50; uuidBytes[8] = (uuidBytes[8] & 0x3f) | 0x80
                let id = UUID(uuid: (uuidBytes[0],uuidBytes[1],uuidBytes[2],uuidBytes[3],uuidBytes[4],uuidBytes[5],uuidBytes[6],uuidBytes[7],uuidBytes[8],uuidBytes[9],uuidBytes[10],uuidBytes[11],uuidBytes[12],uuidBytes[13],uuidBytes[14],uuidBytes[15]))
                #else
                let id = grantRevisionID // The qualifier rejects duplicate IDs on unsupported targets.
                #endif
                credentials.append(.init(revisionID: id, bytes: bytes))
                references.append(.init(credentialRevisionID: id, kind: kind, key: key))
            }
            for connection in screen.generic?.entries ?? [] {
                if let secret = connection.secret { append(.generic, connection.grant.authRef, secret) }
            }
            if let home = screen.homeAssistant { append(.homeAssistant, home.connectionId, Data(home.token.utf8)) }
            return DeviceGrantEntryInput(entryID: screen.entryID, revision: screen.revision,
                generic: screen.generic, homeAssistant: screen.homeAssistant, publicReads: screen.publicReads,
                credentialReferences: references)
        }
        let expectations = zip(screens, qualified).map { DeviceGrantEntryExpectation(entryID: $0.entryID, package: $1) }
        let input = DeviceGrantRevisionInput(schemaVersion: 1, identity: .init(rootID: roots.grantID, revisionID: grantRevisionID),
            owner: owner, entries: entries, credentials: credentials, retainedRevisions: [])
        let grant = try DeviceGrantRevisionQualifier.qualify(input, expectedEntries: expectations)
        let packageInputs = zip(screens, qualified).map { DeviceProvisioningPackageInput.supplied(entryID: $0.entryID, operationID: $0.packageOperationID, package: $1) }
        let structuralEntries = try zip(screens, qualified).map { screen, package in
            let reference = try PackagePreparationCodec.expectedReference(.init(operationID: screen.packageOperationID, package: package), rootID: roots.packageID)
            return DeviceStructuralEntry(entryID: screen.entryID, displayName: screen.displayName,
                revision: screen.revision, packageDirectory: reference.directory)
        }
        let request = DeviceProvisioningPlanRequest(roots: roots, operationID: operationID, grantOperationID: grantOperationID,
            expectedGenerationID: nil, baseline: .initialExplicit(legacyGrantSet: legacyGrantSet),
            snapshot: .init(generationID: generationID, entries: structuralEntries, configuredEntryID: selected, contentOwner: owner, grantSet: legacyGrantSet),
            owner: owner, packages: packageInputs, grantInput: input, qualifiedGrant: grant)
        let plan = try DeviceProvisioningPlanner.qualify(request)
        try validateOriginal()
        try journal.initializeExplicit(); try packages.initializeExplicit(); try grants.initializeExplicit(); try structural.initializeExplicit()
        let intent = try journal.stageExact(plan)
        let anchor = try DeviceBoundGrantAttemptCoordinator(journal: journal, grants: grants).stageExact(request, plan: plan, journalReceipt: intent)
        let preparation = DeviceBoundPackagePreparationCoordinator(journal: journal, grants: grants, packages: packages)
        let batch = try preparation.preparePackagesExact(plan: plan, journalReceipt: intent, privateAnchor: anchor, packages: packageInputs)
        let completed = try preparation.completeCredentialsExact(batch)
        try validateOriginal()
        let terminal = try preparation.closeGrantTerminalExact(completed)
        let commit = DeviceLocalCompleteSetCommitCoordinator(packageStore: packages, grantStore: grants, structuralStore: structural)
        let acknowledgment = try commit.commitBoundTerminalExact(terminal, journal: journal)
        let completion = try commit.completeProvisioningExact(terminal, acknowledgment: acknowledgment, journal: journal)
        try journal.verifyCompletion(completion)
        try validateOriginal()
        return try DeviceLocalCompleteSetRestoreCoordinator(packageStore: packages, grantStore: grants, structuralStore: structural).restoreLatestBoundCompletedExact(journal: journal)
    }
}

/// Device-only durable migration session. Root identities must originate in the device's persisted
/// original migration intent. The authority layer separately approves these exact physical roots.
@_spi(NativeInstallation) public final class DeviceLegacyMigrationSession {
    let roots: DeviceProvisioningRoots
    let packages: DevicePackagePreparationStore
    let grants: DeviceGrantPreparationStore
    let structural: DeviceStructuralStore
    let journal: DeviceLocalProvisioningIntentStore
    private(set) var binding: DeviceBoundRestoredRuntimeBinding?
    private let validateRoots: () throws -> Void
    public init(packageRoot: URL, packageRootID: UUID, grantRoot: URL, grantRootID: UUID,
        structuralRoot: URL, structuralRootID: UUID, provisioningRoot: URL, provisioningRootID: UUID,
        legacyStateRoot: URL, legacyArchiveRoot: URL, resetRoot: URL, cloudRoot: URL,
        managementRoot: URL, preferencesRoot: URL, otherProtectedRoots: [URL],
        credentialTransport: any DeviceGrantCredentialTransport, validateRoots: @escaping () throws -> Void) throws {
        self.validateRoots = validateRoots
        try validateRoots()
        roots = .init(journalID: provisioningRootID, structuralID: structuralRootID, packageID: packageRootID, grantID: grantRootID)
        let scope = DevicePackageProtectedScope(legacyStateRoot: legacyStateRoot, legacyArchiveRoot: legacyArchiveRoot,
            resetRoot: resetRoot, cloudRoot: cloudRoot, managementRoot: managementRoot,
            preferencesRoot: preferencesRoot, otherProtectedRoots: otherProtectedRoots)
        packages = .init(root: packageRoot, rootID: packageRootID, protectedScope: scope)
        grants = .init(root: grantRoot, rootID: grantRootID, protectedScope: scope,
            backend: try DeviceGrantCredentialTransportBackend(rootID: grantRootID, transport: credentialTransport))
        structural = .init(root: structuralRoot, rootID: structuralRootID)
        journal = .init(root: provisioningRoot, rootID: provisioningRootID, protectedRoots: scope.roots)
    }
    public func prepareAndCommit(screens: [DeviceLegacyMigrationScreen], selected: UUID?, owner: PairingIdentity,
        profile: DeviceProfile, profileID: String, operationID: UUID, grantOperationID: UUID,
        generationID: UUID, grantRevisionID: UUID, legacyGrantSet: String?,
        validateOriginal: () throws -> Void) throws {
        guard binding == nil else { throw DeviceStructuralStoreError.conflict }
        try validateRoots()
        binding = try DeviceLegacyInventoryMigration.prepareAndCommit(screens: screens, selected: selected, owner: owner,
            profile: profile, profileID: profileID, roots: roots, operationID: operationID, grantOperationID: grantOperationID,
            generationID: generationID, grantRevisionID: grantRevisionID, legacyGrantSet: legacyGrantSet,
            journal: journal, packages: packages, grants: grants, structural: structural, validateOriginal: { try self.validateRoots(); try validateOriginal() })
        try validateRoots()
    }
    /// Restart uses original durable transaction qualification; no legacy metadata adoption.
    public func restoreCompleted() throws {
        guard binding == nil else { throw DeviceStructuralStoreError.conflict }
        try validateRoots()
        binding = try DeviceLocalCompleteSetRestoreCoordinator(packageStore: packages, grantStore: grants,
            structuralStore: structural).restoreLatestBoundCompletedExact(journal: journal)
        try validateRoots()
    }
}

@_spi(NativeInstallation) public struct DeviceUnifiedInventoryAssociation {
    public struct Entry {
        public let entryID: UUID
        public let dashboardID: String
        public let displayName: String
        public let revision: String
        public let manifestDigest: String
        public let provenance: String
    }
    public let commonRootID: UUID, installationID: UUID, generationID: UUID
    public let entries: [Entry]
    public let configuredEntryID: UUID?
}

@_spi(NativeInstallation) public struct DeviceUnifiedMountStateAssociation {
    public let generationID: UUID
    public let entryID: UUID?
    public let state: String
    public let failureCode: String?
}
@_spi(NativeInstallation) public struct DeviceUnifiedMountedContentAssociation {
    public let generationID: UUID
    public let entryID: UUID?
    public let manifestDigest: String?
    public let currentlyConfigured: Bool
}
@_spi(NativeInstallation) public struct DeviceUnifiedLocalSourceAssociation {
    public struct Root { public let rootID: UUID; public let path: String }
    public let operationID: UUID
    public let roots: [Root]
}
/// Issued only after the fixed owner durably accepted this original Cloud command.
@_spi(NativeInstallation) public final class NativeUnifiedAcceptedCloudCommand: CustomReflectable {
    fileprivate let session: ObjectIdentifier
    fileprivate let binding: DeviceNativeDeliveryCommandBinding
    fileprivate init(session: DeviceUnifiedInventorySession, binding: DeviceNativeDeliveryCommandBinding) {
        self.session = ObjectIdentifier(session); self.binding = binding
    }
    public var customMirror: Mirror { Mirror(self, children: [] as [(String, Any)]) }
}
@_spi(NativeInstallation) public final class DeviceUnifiedInventorySession {
    /// Authority-owned staging must be promoted by exact inode before any session opens.
    public static func prepareOwnedRootForPromotion(stagingRoot: URL, finalRoot: URL, rootID: UUID) throws {
        try DeviceMixedInventoryStore(root: stagingRoot, rootID: rootID).initializeExplicit(recordedFinalRoot: finalRoot)
    }
    private struct CloudWork {
        let incoming: DeviceMixedIncomingResources
        var body: NativeDeliveryDurableBody?
        var requestID: UUID?
        var authorization: NativeDeliveryActivationHTTPObservation?
        var authorizationBytes: Data?
        var outcome: NativeDeliveryDurableBody?
    }
    private var reportingRejections: [UUID: (DeviceNativeDeliveryCommandBinding, NativeDeliveryDurableBody)] = [:]
    private var acceptedCloud: DeviceNativeDeliveryCommandBinding?
    private var cloudWork: CloudWork?
    private let operationMutex = NSLock()
    private func beginOperation() throws {
        guard operationMutex.try() else { throw DeviceLocalResourceGateFailure.reentrant }
    }
    private let migration: DeviceLegacyMigrationSession?
    private let retainedLocalPreparations: [DeviceIncomingLocalPreparation]
    private let automaticOwnerFactory: ((UUID) throws -> any NativeUnifiedAutomationOwner)?
    private let native: NativeDeliveryExecutionSession
    private let store: DeviceMixedInventoryStore
    private var resolver: DeviceMixedResourceResolver?
    private var original: DeviceMixedResolvedResources?
    private var capture: DeviceMixedInventoryStore.Capture?
    private var mountedPresentation: DeviceManagedStaticContent?
    private var restoredPresentation: DeviceManagedStaticContent?
    private var confirmedPresentation: DeviceManagedStaticContent?
    private let validateOriginal: () throws -> Void
    private let validateMutation: () throws -> Void
    /// The caller owns the physical common root and persists its UUID before directory creation.
    /// Construction alone grants neither command permission nor resource validity.
    public init(local: DeviceLegacyMigrationSession? = nil, incomingLocal: [DeviceIncomingLocalPreparation] = [], native: NativeDeliveryExecutionSession,
        commonRoot: URL, commonRootID: UUID, validateOriginal: @escaping () throws -> Void,
        validateMutation: @escaping () throws -> Void = { throw NativeDeliveryExecutionError.unavailableDispatchCapability },
        automationOwner: ((UUID) throws -> any NativeUnifiedAutomationOwner)? = nil) {
        automaticOwnerFactory = automationOwner
        migration = local; retainedLocalPreparations = incomingLocal; self.native = native; self.validateOriginal = validateOriginal; self.validateMutation = validateMutation
        store = .init(root: commonRoot, rootID: commonRootID)
    }
    public func qualifiedResetResourcesExact() throws -> DeviceOwnedInstallationResetResources {
        try validateOriginal()
        try beginOperation(); defer { operationMutex.unlock() }
        guard let original, let resolver, let capture else { throw NativeDeliveryExecutionError.phase }
        let result = try resolver.qualifiedResetResourcesExact(original, store: store, current: capture)
        try validateOriginal()
        return result
    }
    public func migrate(current: NativeCurrentInstallationDispatch, operationID: UUID, generationID: UUID,
        admissionEnabled: Bool) throws {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        guard capture == nil else { throw DeviceStructuralStoreError.conflict }
        let binding = migration?.binding
        guard migration == nil || binding != nil else { throw DeviceStructuralStoreError.conflict }
        let (coordinator, source) = try native.mixedInventorySourceExact(current: current)
        let localGate = migration.map { DeviceLocalResourceGate(packageStore: $0.packages, grantStore: $0.grants, structuralStore: $0.structural) }
        let resolver = DeviceMixedResourceResolver(local: localGate, native: coordinator)
        let original = try resolver.resolveInitialMigrationExact(local: binding, native: source, generationID: generationID)
        try store.initializeExplicit()
        let result = try resolver.commitInitialMigrationExact(original, store: store, operationID: operationID, admissionEnabled: admissionEnabled)
        try validateOriginal()
        self.resolver = resolver; self.original = original; capture = result.0
    }
    /// Reopens original generation/history without creating another migration intent.
    /// False means a genuinely bound empty common root, never a corrupt/orphan state.
    public func restoreCompleted(current: NativeCurrentInstallationDispatch) throws -> Bool {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        guard capture == nil else { throw DeviceStructuralStoreError.conflict }
        let binding = migration?.binding
        guard migration == nil || binding != nil else { throw DeviceStructuralStoreError.conflict }
        guard let restored = try store.readCurrent() else { return false }
        let (coordinator, source) = try native.mixedInventorySourceExact(current: current)
        let localGate = migration.map { DeviceLocalResourceGate(packageStore: $0.packages, grantStore: $0.grants, structuralStore: $0.structural) }
        let resolver = DeviceMixedResourceResolver(local: localGate, native: coordinator)
        let original = try resolver.resolveInitialMigrationExact(local: binding, native: source, generationID: restored.snapshot.generationID)
        try resolver.restoreIncomingLocalResourcesExact(store: store, sources: retainedLocalPreparations.map(\.resources))
        try resolver.restoreIncomingCloudResourcesExact(store: store)
        try resolver.verifyCurrentInventoryResourcesExact(original, store: store, current: restored)
        try validateOriginal()
        self.resolver = resolver; self.original = original; capture = restored
        return true
    }
    public func restoreCompleted() throws -> Bool {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        guard capture == nil else { throw DeviceStructuralStoreError.conflict }
        let binding = migration?.binding
        guard migration == nil || binding != nil else { throw DeviceStructuralStoreError.conflict }
        guard let restored = try store.readCurrent() else { return false }
        let (coordinator, source) = try native.mixedInventorySourceExact()
        let localGate = migration.map { DeviceLocalResourceGate(packageStore: $0.packages, grantStore: $0.grants, structuralStore: $0.structural) }
        let resolver = DeviceMixedResourceResolver(local: localGate, native: coordinator)
        let original = try resolver.resolveInitialMigrationExact(local: binding, native: source, generationID: restored.snapshot.generationID)
        try resolver.restoreIncomingLocalResourcesExact(store: store, sources: retainedLocalPreparations.map(\.resources))
        try resolver.restoreIncomingCloudResourcesExact(store: store)
        try resolver.verifyCurrentInventoryResourcesExact(original, store: store, current: restored)
        try validateOriginal()
        self.resolver = resolver; self.original = original; capture = restored
        return true
    }
    public func retainedLocalSourceAssociations() throws -> [DeviceUnifiedLocalSourceAssociation] {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        let frames = try store.retainedLocalSourcesExact()
        try validateOriginal()
        return frames.map { frame in .init(operationID: frame.operationID,
            roots: frame.roots.map { .init(rootID: $0.rootID, path: $0.path) }) }
    }
    public func validatedAssociation() throws -> DeviceUnifiedInventoryAssociation {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        guard let resolver, let original, let capture else { throw DeviceStructuralStoreError.conflict }
        try resolver.verifyCurrentInventoryResourcesExact(original, store: store, current: capture)
        let entries = capture.snapshot.entries.map { entry -> DeviceUnifiedInventoryAssociation.Entry in
            switch entry {
            case .retainedLocal(let local): return .init(entryID: entry.entryID, dashboardID: entry.dashboardID,
                displayName: local.entry.displayName, revision: local.entry.revision.revision,
                manifestDigest: local.entry.revision.digest, provenance: "retainedLocal")
            case .cloud(let cloud, _): return .init(entryID: entry.entryID, dashboardID: entry.dashboardID,
                displayName: cloud.displayName, revision: cloud.package.revision.uuidString.lowercased(),
                manifestDigest: cloud.package.manifestDigest.text, provenance: "cloud")
            }
        }
        try validateOriginal()
        return .init(commonRootID: store.rootID, installationID: capture.snapshot.installationOwner.installationID,
            generationID: capture.snapshot.generationID, entries: entries, configuredEntryID: capture.snapshot.configuredEntryID)
    }
    func automationOwnerExact(baseGenerationID: UUID) throws -> any NativeUnifiedAutomationOwner {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        guard let factory = automaticOwnerFactory else { throw NativeDeliveryExecutionError.unavailableDispatchCapability }
        return try factory(baseGenerationID)
    }
    func automationCheckpointExact() throws -> (navigation: TemporaryActivationNavigation, ownedGenerationID: UUID?, previousEntryID: UUID?, targetEntryID: UUID, explicitBaseGenerationID: UUID, generationID: UUID)? {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        guard let capture, let frame = try store.automationExact() else { return nil }
        var navigation = frame.navigation
        let owned: UUID?
        if frame.ownedGenerationID == capture.snapshot.generationID, !navigation.dismissed { owned = frame.ownedGenerationID }
        else { navigation.manualSelection(); owned = nil }
        return (navigation, owned, frame.previousEntryID, frame.targetEntryID, frame.explicitBaseGenerationID, frame.ownedGenerationID)
    }
    func commitAutomaticSelectionExact(_ permit: DeviceUnifiedAutomaticSelectionPermit) throws -> Bool {
        try permit.validateEvent()
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        guard let resolver, let original, capture === permit.baseCapture else { throw DeviceStructuralStoreError.conflict }
        let command = try NativeInstallationAutomaticSelectionCommand(owner: permit.owner, permit: permit,
            resolver: resolver, original: original, store: store)
        let result = try command.dispatch()
        try validateOriginal(); capture = result.capture; mountedPresentation = nil
        return true
    }
    func automationSourceExact() throws -> (resolver: DeviceMixedResourceResolver, original: DeviceMixedResolvedResources,
        store: DeviceMixedInventoryStore, capture: DeviceMixedInventoryStore.Capture, validate: () throws -> Void) {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        guard let resolver, let original, let capture else { throw DeviceStructuralStoreError.conflict }
        try resolver.verifyCurrentInventoryResourcesExact(original, store: store, current: capture)
        return (resolver, original, store, capture, {
            try resolver.verifyCurrentInventoryResourcesExact(original, store: self.store, current: capture)
        })
    }
    func runtimeSourceExact() throws -> (resolver: DeviceMixedResourceResolver, original: DeviceMixedResolvedResources,
        store: DeviceMixedInventoryStore, capture: DeviceMixedInventoryStore.Capture, validate: () throws -> Void) {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        guard let resolver, let original, let capture else { throw DeviceStructuralStoreError.conflict }
        try resolver.verifyCurrentInventoryResourcesExact(original, store: store, current: capture)
        return (resolver, original, store, capture, { [self] in
            // This callback also runs while presentation confirmation holds operationMutex.
            // Resource stores serialize and requalify the captured current/mounted graph.
            try validateOriginal()
            try resolver.verifyCurrentOrMountedResourcesExact(original, store: store, presentation: capture)
            try validateOriginal()
        })
    }
    func retainRestoredRuntimePresentationExact(_ content: DeviceManagedStaticContent, historical: DeviceMixedInventoryStore.Capture) throws {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        guard let mounted = try store.mountedExact(), mounted.generationID == historical.snapshot.generationID,
            mounted.entryID == content.entryID, content.generationID == historical.snapshot.generationID else { throw DeviceStructuralStoreError.conflict }
        try content.verifyResources(); restoredPresentation = content
    }
    func retainRuntimePresentationExact(_ content: DeviceManagedStaticContent, current: DeviceMixedInventoryStore.Capture) throws {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        guard capture === current, content.generationID == current.snapshot.generationID,
            content.entryID == current.snapshot.configuredEntryID else { throw DeviceStructuralStoreError.conflict }
        mountedPresentation = content
    }
    /// Reconstructs only the actually mounted, historically completed source after
    /// a failed newer candidate. Issuance does not activate data before its new mount callback.
    public func lastSuccessfulContent(operationID: UUID) throws -> DeviceManagedStaticContent? {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        guard let resolver, let original, let current = capture, let mounted = try store.mountedCaptureExact(),
            mounted.snapshot.configuredEntryID != nil, mounted.snapshot.generationID != current.snapshot.generationID else { return nil }
        try resolver.verifyCurrentOrMountedResourcesExact(original, store: store, presentation: mounted)
        let content = try resolver.selectedStaticContentExact(original, store: store, current: mounted,
            operationID: operationID, historicalMounted: true)
        restoredPresentation = content; return content
    }
    func lastSuccessfulRuntimeSourceExact() throws -> (resolver: DeviceMixedResourceResolver, original: DeviceMixedResolvedResources,
        store: DeviceMixedInventoryStore, capture: DeviceMixedInventoryStore.Capture, validate: () throws -> Void)? {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        guard let resolver, let original, let current = capture, let mounted = try store.mountedCaptureExact(),
            mounted.snapshot.configuredEntryID != nil, mounted.snapshot.generationID != current.snapshot.generationID else { return nil }
        try resolver.verifyCurrentOrMountedResourcesExact(original, store: store, presentation: mounted)
        return (resolver, original, store, mounted, { [self] in
            try validateOriginal()
            try resolver.verifyCurrentOrMountedResourcesExact(original, store: self.store, presentation: mounted)
            try validateOriginal()
        })
    }
    public func selectedContent(operationID: UUID) throws -> DeviceManagedStaticContent {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        guard let resolver, let original, let capture else { throw DeviceManagedRenderFailure.invalidContent }
        let content = try resolver.selectedStaticContentExact(original, store: store, current: capture, operationID: operationID)
        try validateOriginal()
        mountedPresentation = content
        return content
    }
    func retainCloudObservation(authenticatedGenerationID: UUID) throws -> DeviceMixedInventoryStore.CloudObservation {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        guard let resolver, let original, let capture else { throw DeviceStructuralStoreError.conflict }
        let observation = try resolver.retainCloudObservationExact(original, store: store,
            current: capture, authenticatedCloudGenerationID: authenticatedGenerationID)
        try validateOriginal(); return observation
    }
    func nextCloudObservation() throws -> DeviceMixedInventoryStore.CloudObservation? {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        guard let observation = try store.nextCloudObservationExact() else { return nil }
        try validateCloudObservationUnderReservation(observation); return observation
    }
    func validateCloudObservation(_ observation: DeviceMixedInventoryStore.CloudObservation) throws {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateCloudObservationUnderReservation(observation)
    }
    private func validateCloudObservationUnderReservation(_ observation: DeviceMixedInventoryStore.CloudObservation) throws {
        try validateOriginal()
        guard let resolver, let original else { throw DeviceStructuralStoreError.conflict }
        try resolver.verifyCloudObservationResourcesExact(original, store: store, observation: observation)
        try validateOriginal()
    }
    func acknowledgeCloudObservation(_ observation: DeviceMixedInventoryStore.CloudObservation) throws {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateCloudObservationUnderReservation(observation)
        try store.acknowledgeCloudObservationExact(observation)
        try validateOriginal()
    }
    /// The host calls only after the exact mounted WK content finishes loading.
    /// Called only after the host has actually retired its previous content and
    /// displayed the explicit empty selection, without waiting for a WebView event.
    public func confirmMountedEmptyDisplay() throws {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        guard let resolver, let original, let capture, capture.snapshot.configuredEntryID == nil else { throw DeviceStructuralStoreError.conflict }
        try resolver.retainMountedEmptyExact(original, store: store, current: capture)
        try validateOriginal(); mountedPresentation = nil; confirmedPresentation = nil
    }
    public func confirmMountedLocalContent(_ content: DeviceManagedStaticContent) throws {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        guard let resolver, let original, let capture else { throw DeviceStructuralStoreError.conflict }
        if content === restoredPresentation {
            try resolver.verifyCurrentInventoryResourcesExact(original, store: store, current: capture)
            guard let mounted = try store.mountedExact(), mounted.generationID == content.generationID,
                mounted.entryID == content.entryID else { throw DeviceStructuralStoreError.conflict }
            try content.verifyResources(); try validateOriginal(); confirmedPresentation = content
            return
        }
        guard content === mountedPresentation else { throw DeviceStructuralStoreError.conflict }
        try resolver.retainMountedContentExact(original, store: store, current: capture, content: content)
        try validateOriginal()
        confirmedPresentation = content
    }
    func verifyRuntimePresentationMountedExact(_ content: DeviceManagedStaticContent) throws {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        guard confirmedPresentation === content, let resolver, let original, let capture else { throw DeviceStructuralStoreError.conflict }
        try resolver.verifyCurrentInventoryResourcesExact(original, store: store, current: capture)
        try content.verifyResources()
    }
    public func confirmMountFailure(_ content: DeviceManagedStaticContent, code: String) throws {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        guard let resolver, let original, let capture, content === mountedPresentation else { throw DeviceStructuralStoreError.conflict }
        try resolver.retainMountedContentExact(original, store: store, current: capture, content: content, failureCode: code)
        try validateOriginal()
    }
    public func mountStateAssociation() throws -> DeviceUnifiedMountStateAssociation {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        guard let resolver, let original, let capture else { throw DeviceStructuralStoreError.conflict }
        try resolver.verifyCurrentInventoryResourcesExact(original, store: store, current: capture)
        let failure = try store.mountFailureExact(), mounted = try store.mountedExact()
        let ready = mounted?.generationID == capture.snapshot.generationID && mounted?.entryID == capture.snapshot.configuredEntryID
        try validateOriginal()
        return .init(generationID: capture.snapshot.generationID, entryID: capture.snapshot.configuredEntryID,
            state: failure != nil ? "failed" : (ready ? "ready" : "preparing"), failureCode: failure?.code)
    }
    public func mountedAssociation() throws -> DeviceUnifiedMountedContentAssociation? {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        guard let resolver, let original, let capture else { throw DeviceStructuralStoreError.conflict }
        try resolver.verifyCurrentInventoryResourcesExact(original, store: store, current: capture)
        guard let mounted = try store.mountedExact() else { return nil }
        try validateOriginal()
        return .init(generationID: mounted.generationID, entryID: mounted.entryID, manifestDigest: mounted.manifestDigest,
            currentlyConfigured: mounted.generationID == capture.snapshot.generationID && mounted.entryID == capture.snapshot.configuredEntryID)
    }
    public func confirmMountedContent(_ content: DeviceManagedStaticContent,
        current: NativeCurrentInstallationDispatch) throws -> NativeMountedContentObservation {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        guard let capture, content === mountedPresentation else { throw DeviceStructuralStoreError.conflict }
        let observation = try native.confirmUnifiedMountedContentExact(content, inventory: capture, current: current)
        try validateOriginal(); return observation
    }
    // Only the fixed authenticated opaque plan collector calls this internal seam.
    func acceptCloudCommandExact(current: NativeCurrentInstallationDispatch, command: Data, associationHeader: String,
        rawPlan: Data, nativeOperationID: UUID) throws -> NativeUnifiedAcceptedCloudCommand {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal(); try native.validateUnifiedInventoryAssociation(current: current)
        guard let resolver, let original, let capture else { throw NativeDeliveryExecutionError.phase }
        let priorAccepted = acceptedCloud
        let binding = try DeviceNativeDeliveryCommandBinding.bindMixed(command: command, associationHeader: associationHeader,
            rawPlan: rawPlan, nativeOperationID: nativeOperationID, journalRootID: original.nativeSource.journalRootID, capture: capture)
        let containsLocal = capture.snapshot.entries.contains { if case .retainedLocal = $0 { return true }; return false }
        let acceptance = try native.makeUnifiedAcceptanceExact(current: current, binding: binding,
            commonRootID: store.rootID, containsLocal: containsLocal) {
                try resolver.retainCloudAcceptedExact(original, store: self.store, previous: capture, binding: binding)
            }
        let result = try current.performFixedUnifiedCloudAcceptance(acceptance)
        try acceptance.validateResult(result); try validateOriginal()
        acceptedCloud = binding
        if let priorAccepted, priorAccepted.association.operationID != binding.association.operationID {
            cloudWork = nil
            let rejected = try DeviceNativeDeliveryHTTPCodec.notActivatedRequest(binding: priorAccepted)
            _ = try resolver.retainCloudRejectionExact(original, store: store, binding: priorAccepted, bytes: rejected)
        }
        return NativeUnifiedAcceptedCloudCommand(session: self, binding: binding)
    }
    /// Caller persists every operation/root/grant ID before invoking this method.
    /// Preparation changes no selected inventory and owns a separate package root.
    public func prepareCloud(current: NativeCurrentInstallationDispatch, command: Data, associationHeader: String,
        rawPlan: Data, nativeOperationID: UUID, packageRootID: UUID, grantOperationID: UUID,
        grantRevisionID: UUID, archives: [NativeDeliveryArchiveInput]) throws {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal(); try native.validateUnifiedInventoryAssociation(current: current)
        guard cloudWork == nil, let acceptedCloud,
            !(try store.isCloudRejectedExact(operationID: acceptedCloud.association.operationID)), acceptedCloud.commandBytes == command,
            acceptedCloud.planBytes == rawPlan, acceptedCloud.nativeOperationID == nativeOperationID,
            let resolver, let original, let capture else { throw DeviceStructuralStoreError.conflict }
        let incomingRoot = try store.incomingPackageRootExact(operationID: nativeOperationID)
        let prepared = try DeviceMixedPreparedCloudCommand.prepare(capture: capture, command: command,
            associationHeader: associationHeader, rawPlan: rawPlan, nativeOperationID: nativeOperationID,
            journalRootID: original.nativeSource.journalRootID, packageRootID: packageRootID,
            grantRootID: store.rootID, grantOperationID: grantOperationID, grantRevisionID: grantRevisionID, archives: archives)
        if !FileManager.default.fileExists(atPath: incomingRoot.path) {
            try FileManager.default.createDirectory(at: incomingRoot, withIntermediateDirectories: false)
        }
        let packages = resolver.makeIncomingPackageStore(root: incomingRoot, rootID: packageRootID)
        try packages.initializeExplicit()
        let incoming = try resolver.prepareIncomingCloudResourcesExact(original, store: store, command: prepared, packages: packages)
        try native.validateUnifiedInventoryAssociation(current: current); try validateOriginal()
        cloudWork = .init(incoming: incoming)
    }
    func retainedCloudMountFailureAssociation() throws -> (operationID: UUID, expectedGenerationID: UUID, committedGenerationID: UUID, validate: () throws -> Void, acknowledge: (Data) throws -> Void) {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        guard let resolver, let original, let capture, let incoming = cloudWork?.incoming,
            capture.snapshot.generationID == incoming.command.candidate.generationID,
            capture.snapshot.configuredEntryID == incoming.command.candidate.configuredEntryID,
            try store.mountFailureExact()?.generationID == capture.snapshot.generationID else { throw NativeDeliveryExecutionError.phase }
        try resolver.verifyCurrentInventoryResourcesExact(original, store: store, current: capture)
        return (incoming.command.delivery.association.operationID, incoming.command.delivery.expectedGenerationID,
            capture.snapshot.generationID, { [self] in
                try beginOperation(); defer { operationMutex.unlock() }
                try validateOriginal()
                guard self.capture === capture, try store.mountFailureExact()?.generationID == capture.snapshot.generationID else { throw NativeDeliveryExecutionError.phase }
                try resolver.verifyCurrentInventoryResourcesExact(original, store: store, current: capture)
                try validateOriginal()
            }, { [self] bytes in
                try beginOperation(); defer { operationMutex.unlock() }
                try validateOriginal()
                guard cloudWork?.incoming === incoming, self.capture === capture,
                    let failed = try store.mountFailureExact(), failed.generationID == capture.snapshot.generationID else { throw NativeDeliveryExecutionError.phase }
                try resolver.verifyCurrentInventoryResourcesExact(original, store: store, current: capture)
                try resolver.retainIncomingHTTPExact(original, store: store, incoming: incoming,
                    kind: .failedAcknowledgment, bytes: bytes)
                try validateOriginal(); cloudWork = nil; acceptedCloud = nil
            })
    }
    func retainedCloudProgressAssociation() throws -> (operationID: UUID, expectedGenerationID: UUID, validate: () throws -> Void) {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        guard let resolver, let original, let incoming = cloudWork?.incoming else { throw NativeDeliveryExecutionError.phase }
        try resolver.verifyPreparedIncomingCloudExact(original, store: store, incoming: incoming)
        return (incoming.command.delivery.association.operationID, incoming.command.delivery.expectedGenerationID, { [self] in
            try beginOperation(); defer { operationMutex.unlock() }
            try validateOriginal()
            try resolver.verifyPreparedIncomingCloudExact(original, store: store, incoming: incoming)
            try validateOriginal()
        })
    }
    public func retainCloudActivationRequest(requestID: UUID, current: NativeCurrentInstallationDispatch) throws -> NativeDeliveryDurableBody {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        guard let resolver, let original, var work = cloudWork else { throw NativeDeliveryExecutionError.phase }
        if let existing = work.body {
            guard work.requestID == requestID else { throw NativeDeliveryExecutionError.association }; return existing
        }
        let bytes = try DeviceNativeDeliveryHTTPCodec.activationRequest(binding: work.incoming.command.delivery, requestID: requestID)
        try resolver.retainIncomingHTTPExact(original, store: store, incoming: work.incoming, kind: .request, bytes: bytes)
        let body = try native.makeUnifiedActivationBodyExact(bytes: bytes, requestID: requestID, current: current, session: ObjectIdentifier(self))
        try validateOriginal(); work.body = body; work.requestID = requestID; cloudWork = work; return body
    }
    public func retainCloudAuthorization(requestBody: NativeDeliveryDurableBody,
        observation: NativeDeliveryActivationHTTPObservation) throws {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        guard let resolver, let original, var work = cloudWork, let body = work.body,
            body.matchesOriginalBody(requestBody) else { throw NativeDeliveryExecutionError.association }
        let bytes = try native.validateUnifiedAuthorizationExact(body: body, observation: observation, binding: work.incoming.command.delivery)
        try resolver.retainIncomingHTTPExact(original, store: store, incoming: work.incoming, kind: .authorization, bytes: bytes)
        try validateOriginal(); work.authorization = observation; work.authorizationBytes = bytes; cloudWork = work
    }
    public func dispatchCloudAndRetainActivatedOutcome(current: NativeCurrentInstallationDispatch) throws -> NativeDeliveryDurableBody {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        guard let resolver, let original, var work = cloudWork, let body = work.body,
            let observation = work.authorization, let authorizationBytes = work.authorizationBytes,
            let requestID = work.requestID else { throw NativeDeliveryExecutionError.phase }
        if let outcome = work.outcome { return outcome }
        let command = try native.makeUnifiedStructuralCommandExact(resolver: resolver, original: original, store: store,
            incoming: work.incoming, body: body, observation: observation, current: current)
        let result = try current.performFixedUnifiedStructuralDispatch(command)
        let captured = try command.unwrap(result).0
        self.capture = captured; mountedPresentation = nil
        let authorization = try DeviceNativeDeliveryHTTPCodec.observe(authorizationBytes, kind: .activationResponse,
            binding: work.incoming.command.delivery, requestID: requestID)
        let request = try DeviceNativeDeliveryHTTPCodec.activationRequest(binding: work.incoming.command.delivery, requestID: requestID)
        var object = try JSONSerialization.jsonObject(with: request) as! [String: Any]
        object["authorizationDigest"] = authorization.authorizationDigest
        object["outcome"] = "activated"
        object["previousGenerationId"] = work.incoming.command.delivery.expectedGenerationID.uuidString.lowercased()
        object["resultingGenerationId"] = captured.snapshot.generationID.uuidString.lowercased()
        object["renderState"] = "not-observed"
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        _ = try DeviceNativeDeliveryHTTPCodec.observe(bytes, kind: .terminalRequest, binding: work.incoming.command.delivery,
            requestID: requestID, authorizationDigest: authorization.authorizationDigest, expectedOutcome: "activated")
        try resolver.retainIncomingHTTPExact(original, store: store, incoming: work.incoming, kind: .outcome, bytes: bytes)
        let outcome = try native.makeUnifiedOutcomeBodyExact(bytes: bytes, requestID: requestID, current: current, session: ObjectIdentifier(self))
        try validateOriginal(); work.outcome = outcome; cloudWork = work; return outcome
    }
    /// Completed outcomes can be retried after restart; their original authorization
    /// is reportable evidence and never becomes a new dispatch lease.
    /// Reports only a durably accepted original command for which no common CAS
    /// intent/receipt exists. Download or validation failure cannot claim activation.
    public func retainCloudNotActivatedOutcome(current: NativeCurrentInstallationDispatch, command: NativeUnifiedAcceptedCloudCommand) throws -> NativeDeliveryDurableBody {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        guard command.session == ObjectIdentifier(self), let resolver, let original else { throw NativeDeliveryExecutionError.phase }
        let binding = command.binding
        let bytes = try DeviceNativeDeliveryHTTPCodec.notActivatedRequest(binding: binding)
        let body = try native.makeUnifiedOutcomeBodyExact(bytes: bytes, requestID: nil, current: current, session: ObjectIdentifier(self))
        guard try resolver.retainCloudRejectionExact(original, store: store, binding: binding, bytes: bytes) else { throw DeviceMixedInventoryStore.Failure.needsReview }
        reportingRejections[binding.association.operationID] = (binding, body)
        try validateOriginal(); return body
    }
    public func restorePendingCloudNotActivatedOutcome(current: NativeCurrentInstallationDispatch) throws -> NativeDeliveryDurableBody? {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        guard let resolver, let original, let pending = try store.pendingCloudRejectionsExact().first else { return nil }
        guard try resolver.retainCloudRejectionExact(original, store: store, binding: pending.binding, bytes: pending.outcome) else { throw DeviceMixedInventoryStore.Failure.needsReview }
        let body = try native.makeUnifiedOutcomeBodyExact(bytes: pending.outcome, requestID: nil, current: current, session: ObjectIdentifier(self))
        reportingRejections[pending.binding.association.operationID] = (pending.binding, body)
        try validateOriginal(); return body
    }
    public func retainCloudNotActivatedAcknowledgment(body: NativeDeliveryDurableBody,
        observation: NativeDeliveryReceiptHTTPObservation) throws -> UUID {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        guard let resolver, let original, let pair = reportingRejections.values.first(where: { $0.1.matchesOriginalBody(body) }) else { throw NativeDeliveryExecutionError.association }
        let (bytes, receiptID) = try native.validateUnifiedReceiptExact(body: pair.1, observation: observation,
            binding: pair.0, expectedOutcome: "not_activated")
        guard try resolver.retainCloudRejectionExact(original, store: store, binding: pair.0, bytes: bytes,
            acknowledgment: true) else { throw DeviceMixedInventoryStore.Failure.needsReview }
        let operationID = pair.0.association.operationID
        reportingRejections.removeValue(forKey: operationID)
        if acceptedCloud?.association.operationID == operationID { acceptedCloud = nil }
        if cloudWork?.incoming.command.delivery.association.operationID == operationID { cloudWork = nil }
        try validateOriginal(); return receiptID
    }
    public func restorePendingCloudMountFailure(current: NativeCurrentInstallationDispatch) throws -> Bool {
        guard try store.mountFailureExact() != nil else { return false }
        try beginOperation()
        do {
            try validateOriginal()
            if let capture, let work = cloudWork, work.incoming.command.candidate.generationID == capture.snapshot.generationID {
                operationMutex.unlock(); return true
            }
            operationMutex.unlock()
        } catch { operationMutex.unlock(); throw error }
        _ = try restorePendingCloudOutcome(current: current)
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        guard let capture, let work = cloudWork else { return false }
        return try store.mountFailureExact()?.generationID == capture.snapshot.generationID &&
            work.incoming.command.candidate.generationID == capture.snapshot.generationID
    }
    public func restorePendingCloudOutcome(current: NativeCurrentInstallationDispatch) throws -> NativeDeliveryDurableBody? {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        guard cloudWork == nil, let resolver, let original, let capture else { throw NativeDeliveryExecutionError.phase }
        try resolver.verifyCurrentInventoryResourcesExact(original, store: store, current: capture)
        guard let record = try store.pendingIncomingOutcomesExact().first else { return nil }
        let incoming = try resolver.restoredIncomingCloudExact(operationID: record.operationID)
        var object = try JSONSerialization.jsonObject(with: record.request) as! [String: Any]
        let requestID = try DeviceNativeDeliveryAttachmentCodec.uuid(object["activationRequestId"])
        _ = try DeviceNativeDeliveryHTTPCodec.observe(record.request, kind: .activationRequest,
            binding: incoming.command.delivery, requestID: requestID)
        let authorization = try DeviceNativeDeliveryHTTPCodec.observe(record.authorization, kind: .activationResponse,
            binding: incoming.command.delivery, requestID: requestID)
        object["authorizationDigest"] = authorization.authorizationDigest
        object["outcome"] = "activated"
        object["previousGenerationId"] = incoming.command.delivery.expectedGenerationID.uuidString.lowercased()
        object["resultingGenerationId"] = incoming.command.candidate.generationID.uuidString.lowercased()
        object["renderState"] = "not-observed"
        let expected = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard record.outcome == nil || record.outcome == expected else { throw DeviceStructuralStoreError.conflict }
        try resolver.retainIncomingHTTPExact(original, store: store, incoming: incoming, kind: .outcome, bytes: expected)
        _ = try DeviceNativeDeliveryHTTPCodec.observe(expected, kind: .terminalRequest, binding: incoming.command.delivery,
            requestID: requestID, authorizationDigest: authorization.authorizationDigest, expectedOutcome: "activated")
        let body = try native.makeUnifiedOutcomeBodyExact(bytes: expected, requestID: requestID, current: current, session: ObjectIdentifier(self))
        try validateOriginal()
        cloudWork = .init(incoming: incoming, requestID: requestID, outcome: body)
        if try store.mountFailureExact()?.generationID == incoming.command.candidate.generationID { return nil }
        return body
    }
    public func retainCloudOutcomeAcknowledgment(body: NativeDeliveryDurableBody,
        observation: NativeDeliveryReceiptHTTPObservation) throws -> UUID {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        guard let resolver, let original, let work = cloudWork, let outgoing = work.outcome,
            outgoing.matchesOriginalBody(body) else { throw NativeDeliveryExecutionError.association }
        let (bytes, receiptID) = try native.validateUnifiedReceiptExact(body: outgoing, observation: observation, binding: work.incoming.command.delivery)
        try resolver.retainIncomingHTTPExact(original, store: store, incoming: work.incoming, kind: .acknowledgment, bytes: bytes)
        try validateOriginal(); cloudWork = nil; acceptedCloud = nil
        return receiptID
    }
    public func installLocal(_ preparation: DeviceIncomingLocalPreparation, operationID: UUID, generationID: UUID,
        retainedEntryIDs: [UUID], selected: UUID?, owner: any NativeUnifiedLocalInventoryOwner) throws {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        guard let resolver, let original, let capture else { throw DeviceStructuralStoreError.conflict }
        let command = try NativeInstallationUnifiedLocalDispatchCommand(resolver: resolver, original: original,
            store: store, previous: capture, operationID: operationID, generationID: generationID,
            retained: retainedEntryIDs, selected: selected, owner: owner, incoming: preparation.resources)
        let result = try command.dispatch()
        try validateOriginal()
        self.capture = try command.unwrap(result); mountedPresentation = nil
    }
    public func selectOrRemove(operationID: UUID, generationID: UUID, retainedEntryIDs: [UUID], selected: UUID?,
        owner: any NativeUnifiedLocalInventoryOwner) throws {
        try beginOperation(); defer { operationMutex.unlock() }
        try validateOriginal()
        guard let resolver, let original, let capture else { throw DeviceStructuralStoreError.conflict }
        let command = try NativeInstallationUnifiedLocalDispatchCommand(resolver: resolver, original: original,
            store: store, previous: capture, operationID: operationID, generationID: generationID,
            retained: retainedEntryIDs, selected: selected, owner: owner)
        let result = try command.dispatch()
        try validateOriginal()
        self.capture = try command.unwrap(result); mountedPresentation = nil
    }

}
