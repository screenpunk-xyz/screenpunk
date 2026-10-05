import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum DeviceLocalResourceGateFailure: Error, Equatable {
    case invalidRoots, reentrant, invalidScope
}
/// Nonsecret acquisition metadata only. Store descriptors and held locks are not qualification.
struct DeviceLocalResourceDescriptor {
    let instance: ObjectIdentifier
    let path: String
    let rootID: UUID
    static func pathsOverlap(_ a: String, _ b: String) -> Bool {
        a.utf8.elementsEqual(b.utf8) || a == "/" || b == "/"
            || a.utf8.starts(with:(b+"/").utf8) || b.utf8.starts(with:(a+"/").utf8)
    }
    /// Physical acquisition key only. Does not rewrite store paths, bindings or protected scope rules.
    static func existing(instance: ObjectIdentifier, path: String, rootID: UUID) throws -> Self {
        guard path.hasPrefix("/"), path.utf8.count <= 4096 else { throw DeviceLocalResourceGateFailure.invalidRoots }
        guard let physical = realpath(path,nil) else { throw DeviceLocalResourceGateFailure.invalidRoots }
        defer { free(physical) }
        let count = strnlen(physical,4097)
        guard count <= 4096 else { throw DeviceLocalResourceGateFailure.invalidRoots }
        return .init(instance:instance,path:String(cString:physical),rootID:rootID)
    }
}
/// Gate-private construction; no FD/context access and no mutation/initialization permission.
final class DeviceLocalResourcePermit {
    fileprivate let owner = ObjectIdentifier(Thread.current)
    fileprivate let participants: [DeviceLocalResourceDescriptor]
    fileprivate init(_ participants: [DeviceLocalResourceDescriptor]) { self.participants = participants }
    func beginAcquisition(_ descriptor: DeviceLocalResourceDescriptor) throws { try DeviceLocalResourceRegistry.acquire(self,descriptor) }
    func beginRead(_ instance: ObjectIdentifier) throws { try DeviceLocalResourceRegistry.read(self,instance) }
    func endRead() { DeviceLocalResourceRegistry.endRead(self) }
    func requireReadable() throws { try DeviceLocalResourceRegistry.readable(self) }
    func invalidate() { DeviceLocalResourceRegistry.invalidate(self) }
}
/// Gate-private construction and fixed dispatch only. Not available from a read scope.
/// Beginning the command uses the same active-operation registry as reads, blocking nested callbacks.
final class DeviceLocalStructuralCommandPermit {
    private let readPermit: DeviceLocalResourcePermit
    fileprivate init(_ permit: DeviceLocalResourcePermit) { readPermit = permit }
    func begin(_ instance: ObjectIdentifier) throws { try readPermit.beginRead(instance) }
    func end() { readPermit.endRead() }
}
/// Fixed completion dispatch/publication only. Neither token is constructible outside this file;
/// publication is issued only after the entire four-root scope successfully exits.
final class DeviceProvisioningCompletionCommandPermit {
    private let permit:DeviceLocalResourcePermit
    fileprivate init(_ permit:DeviceLocalResourcePermit){self.permit=permit}
    func begin(_ instance:ObjectIdentifier)throws{try permit.beginRead(instance)}
    func end(){permit.endRead()}
}
final class DeviceProvisioningCompletionPublicationPermit {
    fileprivate init(){}
    func requireIdle()throws{try DeviceLocalResourceRegistry.requireIdle()}
}
/// Short registry critical sections only. Never holds its mutex during waits, I/O or callbacks.
/// All ordinary store entries are marked BEFORE their mutex acquisition, rejecting nested cross-store
/// or gate entry. Thread markers are removed on exit; they are not persistent state or authority.
enum DeviceLocalResourceRegistry {
    private enum State { case ordinary; case gate(DeviceLocalResourcePermit, acquired: Int, phase: Phase, reading: Bool) }
    private enum Phase { case acquiring, executing, closing }
    private static let mutex = NSLock()
    private static var states: [ObjectIdentifier:State] = [:]
    private static var thread: ObjectIdentifier { ObjectIdentifier(Thread.current) }
    static func requireIdle()throws {
        mutex.lock();defer{mutex.unlock()}
        guard states[thread] == nil else { throw DeviceLocalResourceGateFailure.reentrant }
    }
    static func beginOrdinary() throws {
        mutex.lock(); defer { mutex.unlock() }
        guard states[thread] == nil else { throw DeviceLocalResourceGateFailure.reentrant }; states[thread] = .ordinary
    }
    static func endOrdinary() { mutex.lock(); defer { mutex.unlock() }; states.removeValue(forKey:thread) }
    fileprivate static func begin(_ permit: DeviceLocalResourcePermit) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard permit.owner == thread, states[thread] == nil else { throw DeviceLocalResourceGateFailure.reentrant }
        states[thread] = .gate(permit,acquired:0,phase:.acquiring,reading:false)
    }
    fileprivate static func acquire(_ permit: DeviceLocalResourcePermit, _ descriptor: DeviceLocalResourceDescriptor) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard permit.owner == thread, case .gate(let current,let count,.acquiring,false) = states[thread], current === permit,
              count < permit.participants.count else { throw DeviceLocalResourceGateFailure.invalidScope }
        let expected = permit.participants[count]
        guard expected.instance == descriptor.instance, expected.path.utf8.elementsEqual(descriptor.path.utf8), expected.rootID == descriptor.rootID else { throw DeviceLocalResourceGateFailure.invalidScope }
        states[thread] = .gate(permit,acquired:count+1,phase:.acquiring,reading:false)
    }
    fileprivate static func execute(_ permit: DeviceLocalResourcePermit) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard permit.owner == thread, case .gate(let current,let count,.acquiring,false) = states[thread], current === permit,
              count == permit.participants.count else { throw DeviceLocalResourceGateFailure.invalidScope }
        states[thread] = .gate(permit,acquired:count,phase:.executing,reading:false)
    }
    fileprivate static func readable(_ permit: DeviceLocalResourcePermit) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard permit.owner == thread, case .gate(let current,_,.executing,false) = states[thread], current === permit else { throw DeviceLocalResourceGateFailure.invalidScope }
    }
    fileprivate static func read(_ permit: DeviceLocalResourcePermit, _ instance: ObjectIdentifier) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard permit.owner == thread, case .gate(let current,let count,.executing,false) = states[thread], current === permit,
              permit.participants.contains(where:{$0.instance == instance}) else { throw DeviceLocalResourceGateFailure.invalidScope }
        states[thread] = .gate(permit,acquired:count,phase:.executing,reading:true)
    }
    fileprivate static func endRead(_ permit: DeviceLocalResourcePermit) {
        mutex.lock(); defer { mutex.unlock() }
        guard permit.owner == thread, case .gate(let current,let count,.executing,true) = states[thread], current === permit else { return }
        states[thread] = .gate(permit,acquired:count,phase:.executing,reading:false)
    }
    fileprivate static func invalidate(_ permit: DeviceLocalResourcePermit) {
        mutex.lock(); defer { mutex.unlock() }
        guard permit.owner == thread, case .gate(let current,let count,_,_) = states[thread], current === permit else { return }
        states[thread] = .gate(permit,acquired:count,phase:.closing,reading:false)
    }
    fileprivate static func finish(_ permit: DeviceLocalResourcePermit) {
        mutex.lock(); defer { mutex.unlock() }
        guard permit.owner == thread, case .gate(let current,_,_,_) = states[thread], current === permit else { return }
        states.removeValue(forKey:thread)
    }
}
/// Synchronous scope only, inert after escape. No qualification by possession. Existing verifier
/// requirements still apply. Nested/cross-thread reads reject rather than reacquiring held mutexes.
final class DeviceLocalResourceReadScope {
    private let permit: DeviceLocalResourcePermit
    private let packages: DevicePackagePreparationStore
    private let grants: DeviceGrantPreparationStore
    private let structural: DeviceStructuralStore
    fileprivate init(_ permit: DeviceLocalResourcePermit, _ packages: DevicePackagePreparationStore,
                     _ grants: DeviceGrantPreparationStore, _ structural: DeviceStructuralStore) {
        self.permit = permit; self.packages = packages; self.grants = grants; self.structural = structural
    }
    func verifyPackage(_ receipt: DevicePreparedPackageReceipt) throws -> DeviceVerifiedPreparedPackage {
        try permit.requireReadable(); return try packages.verify(receipt,resourcePermit:permit)
    }
    func verifyGrants(_ receipt: DevicePreparedGrantReceipt, exactRequest: DeviceGrantPreparationRequest,
                      expectedEntries: [DeviceGrantEntryExpectation]) throws -> DeviceVerifiedGrantPreparation {
        try permit.requireReadable(); return try grants.verify(receipt,exactRequest:exactRequest,expectedEntries:expectedEntries,resourcePermit:permit)
    }
    /// Read-only ORIGINAL attempt checkpoints. Holding locks/current qualification cannot renew them.
    func verifyResolutionCheckpoints(packages:DevicePackageResolutionCheckpoint,grants:DeviceGrantResolutionCheckpoint) throws {
        try permit.requireReadable()
        try self.packages.verifyResolutionCheckpoint(packages,resourcePermit:permit)
        try self.grants.verifyResolutionCheckpoint(grants,resourcePermit:permit)
    }
    func verifyRecoveredGrants(_ receipt: DevicePreparedGrantReceipt, expectedEntries: [DeviceGrantEntryExpectation],
                               expectedOwner: PairingIdentity) throws -> DeviceVerifiedGrantPreparation {
        try permit.requireReadable()
        return try grants.verifyRecovered(receipt,expectedEntries:expectedEntries,expectedOwner:expectedOwner,resourcePermit:permit)
    }
    func verifyQualifiedStructuralCapture(_ original:DeviceStructuralStore.QualifiedCurrentCapture)throws {
        try permit.requireReadable();try structural.verifyQualifiedCurrentCapture(original,resourcePermit:permit)
    }
    func genericSeed(_ receipt:DevicePreparedGrantReceipt,expectedEntries:[DeviceGrantEntryExpectation],owner:PairingIdentity,entryID:UUID)throws->DeviceImmutableGenericSeed {
        try permit.requireReadable();return try grants.makeGenericSeed(receipt,expectedEntries:expectedEntries,expectedOwner:owner,entryID:entryID,resourcePermit:permit)
    }
    func inspectLatestStructuralTerminalExact()throws->DeviceStructuralStore.TerminalDiscovery {
        try permit.requireReadable();return try structural.inspectLatestTerminalExact(resourcePermit:permit)
    }
    func verifyStructuralTerminalDiscovery(_ original:DeviceStructuralStore.TerminalDiscovery)throws {
        try permit.requireReadable();try structural.verifyTerminalDiscovery(original,resourcePermit:permit)
    }
    func diagnoseStructural(operationID: UUID) throws -> DeviceStructuralStore.Recovery {
        try permit.requireReadable(); return try structural.recover(operationID:operationID,resourcePermit:permit)
    }
}
/// Unmounted lock-set exclusion ONLY. No resource checkpoints, recovery acknowledgment, admission,
/// atomic production all-writer authority, creation, sync, migration or callbacks moved outside locks.
/// Body is internal synchronous orchestration, never UI/notification/async work. Existing backend/fault
/// calls execute under locks. Same-thread reentry fails; callbacks synchronously joining another thread
/// doing resource work are unsupported (they can deadlock through application-level waiting).
/// Only the fixed completed-current restore command constructs a dispatch permit. No generic
/// mutation closure or read-scope capability can create it.
final class DeviceBoundCompletedRestorePermit {
    private let permit:DeviceLocalResourcePermit
    fileprivate init(_ permit:DeviceLocalResourcePermit){self.permit=permit}
    func begin(_ instance:ObjectIdentifier)throws{try permit.beginRead(instance)}
    func end(){permit.endRead()}
}
/// Original four-root diagnosis, not ACK/admission/capacity. No secret input is exposed.
final class DeviceBoundCompletedRestoreDiscovery:GrantSecretRedacted {
    fileprivate let journal:DeviceLocalProvisioningIntentStore.CompletedCurrentCheckpoint
    fileprivate let grants:DeviceBoundGrantTerminalRecovery
    fileprivate let structural:DeviceStructuralStore.TerminalDiscovery
    fileprivate let journalIssuer:ObjectIdentifier
    fileprivate init(_ journal:DeviceLocalProvisioningIntentStore.CompletedCurrentCheckpoint,_ grants:DeviceBoundGrantTerminalRecovery,
        _ structural:DeviceStructuralStore.TerminalDiscovery,_ journalIssuer:ObjectIdentifier){self.journal=journal;self.grants=grants;self.structural=structural;self.journalIssuer=journalIssuer}
}
/// Original final-lock captures only, privately constructed AFTER successful scope exit. This is
/// not ongoing validity, production admission, journal capacity or a legacy grant receipt.
final class DeviceBoundRestoredRuntimeBinding:GrantSecretRedacted,@unchecked Sendable {
    let operationID:UUID,generationID:UUID,envelopeBytes:Data
    fileprivate let journal:DeviceLocalProvisioningIntentStore,plan:DeviceValidatedProvisioningPlan
    fileprivate let journalTransition:DeviceLocalProvisioningIntentStore.CompletedRestoreTransition
    fileprivate let grants:DeviceBoundGrantTerminalTransition,packages:[DeviceLocalCompleteSetPackageBinding]
    fileprivate let packageCheckpoint:DevicePackageResolutionCheckpoint,capture:DeviceStructuralStore.QualifiedCurrentCapture
    fileprivate init(journal:DeviceLocalProvisioningIntentStore,plan:DeviceValidatedProvisioningPlan,
        journalTransition:DeviceLocalProvisioningIntentStore.CompletedRestoreTransition,grants:DeviceBoundGrantTerminalTransition,
        packages:[DeviceLocalCompleteSetPackageBinding],packageCheckpoint:DevicePackageResolutionCheckpoint,
        capture:DeviceStructuralStore.QualifiedCurrentCapture,generationID:UUID){self.journal=journal;self.plan=plan;self.journalTransition=journalTransition;self.grants=grants;self.packages=packages;self.packageCheckpoint=packageCheckpoint;self.capture=capture;operationID=capture.operationID;self.generationID=generationID;envelopeBytes=capture.envelopeBytes}
}
final class DeviceLocalResourceGate {
    private let packages: DevicePackagePreparationStore
    private let grants: DeviceGrantPreparationStore
    private let structural: DeviceStructuralStore
    init(packageStore: DevicePackagePreparationStore, grantStore: DeviceGrantPreparationStore, structuralStore: DeviceStructuralStore) {
        packages = packageStore; grants = grantStore; structural = structuralStore
    }
    func withReadScope<T>(_ body: (DeviceLocalResourceReadScope) throws -> T) throws -> T {
        try withScope { scope,_ in try body(scope) }
    }
    /// Fixed complete-set orchestration: no generic mutation closure, command factory, or scope API.
    func commitPreparedExact(_ request: DeviceLocalCompleteSetRequest) throws -> DeviceStructuralStore.QualifiedCurrentCapture {
        try withScope { scope,permit in
            let join = DeviceLocalCompleteSetCoordinator(packageStore:self.packages,grantStore:self.grants)
            let candidate = try join.observeUnderGate(request,scope:scope)
            let record = DeviceStructuralOperationRecord(rootID:request.structuralRootID,operationID:request.operationID,
                expectedOld:candidate.expectedOldEnvelopeBytes,candidate:candidate.candidateEnvelopeBytes,resourceAssertions:Data())
            return try self.structural.performExactAttempt(record,commandPermit:.init(permit))
        }
    }
    /// Fixed recovered dispatch retains the resolver's original checkpoints. Read scopes cannot
    /// dispatch mutation or recapture proof. Staleness fails before structural epoch/effects.
    func commitRecoveredExact(_ request:DeviceLocalCompleteSetRecoveredRequest,resources:DeviceResolvedRetainedResources) throws -> DeviceStructuralStore.QualifiedCurrentCapture {
        try commitRecovered(request,resources:resources,discovery:nil)
    }
    /// Fixed terminal-restoration command only. Original structural discovery cannot be refreshed by
    /// holding locks. The ordinary recovered commit path retains its existing exact-retry semantics.
    func commitRecoveredExact(_ request:DeviceLocalCompleteSetRecoveredRequest,resources:DeviceResolvedRetainedResources,
                              discovery:DeviceStructuralStore.TerminalDiscovery)throws->DeviceStructuralStore.QualifiedCurrentCapture {
        try commitRecovered(request,resources:resources,discovery:discovery)
    }
    private func commitRecovered(_ request:DeviceLocalCompleteSetRecoveredRequest,resources:DeviceResolvedRetainedResources,
                                 discovery:DeviceStructuralStore.TerminalDiscovery?)throws->DeviceStructuralStore.QualifiedCurrentCapture {
        try withScope { scope,permit in
            if let discovery { try scope.verifyStructuralTerminalDiscovery(discovery) }
            try scope.verifyResolutionCheckpoints(packages:resources.packageCheckpoint,grants:resources.grantCheckpoint)
            let join=DeviceLocalCompleteSetCoordinator(packageStore:self.packages,grantStore:self.grants)
            let candidate=try join.observeRecoveredUnderGate(request,resources:resources,scope:scope)
            let record=DeviceStructuralOperationRecord(rootID:request.structuralRootID,operationID:request.operationID,
                expectedOld:candidate.expectedOldEnvelopeBytes,candidate:candidate.candidateEnvelopeBytes,resourceAssertions:Data())
            if let discovery { guard record.sameIntent(as:discovery.record) else { throw DeviceStructuralStoreError.conflict } }
            try scope.verifyResolutionCheckpoints(packages:resources.packageCheckpoint,grants:resources.grantCheckpoint)
            if let discovery { try scope.verifyStructuralTerminalDiscovery(discovery) }
            let capture=try self.structural.performExactAttempt(record,commandPermit:.init(permit))
            if discovery != nil {
                // Capture originates in performExactAttempt's original final lock. Do not recapture.
                try scope.verifyResolutionCheckpoints(packages:resources.packageCheckpoint,grants:resources.grantCheckpoint)
                try scope.verifyQualifiedStructuralCapture(capture)
            }
            return capture
        }
    }
    /// Fixed v2 dispatch only. The original journal/package/grant evidence survives structural
    /// progress; no v1 receipt conversion, resource repair, runtime admission or journal release.
    func commitBoundTerminalExact(_ receipt:DeviceBoundTerminalGrantReceipt,
        journal:DeviceLocalProvisioningIntentStore)throws->(DeviceStructuralStore.QualifiedCurrentCapture,UUID) {
        guard receipt.packages.count <= 12,receipt.plan.canonicalBytes.count <= ProvisioningIntentCodec.limit else { throw DeviceLocalCompleteSetFailure.sizeLimit }
        let body=try ProvisioningIntentCodec.decode(receipt.plan.canonicalBytes)
        guard body.operationID == receipt.plan.operationID,body.roots == receipt.plan.roots,
              body.candidate.count <= 128*1024,(body.expectedOld?.count ?? 0) <= 128*1024 else { throw DeviceLocalCompleteSetFailure.invalidInput }
        let candidate=try StructuralStoreCodec.envelope(body.candidate)
        guard candidate.operationID == body.operationID else { throw DeviceLocalCompleteSetFailure.invalidInput }
        let record=DeviceStructuralOperationRecord(rootID:body.roots.structuralID,operationID:body.operationID,
            expectedOld:body.expectedOld,candidate:body.candidate,resourceAssertions:Data())
        return try withScope(journal:journal) { scope,permit in
            let rootIDs=try [journal.resourceGateDescriptor.rootID,self.packages.resourceGateDescriptor.rootID,
                self.grants.resourceGateDescriptor.rootID,self.structural.resourceGateDescriptor.rootID]
            guard rootIDs == [body.roots.journalID,body.roots.packageID,body.roots.grantID,body.roots.structuralID] else { throw DeviceLocalResourceGateFailure.invalidRoots }
            try self.verifyBoundTerminalResources(receipt,journal:journal,permit:permit)
            let capture=try self.structural.performExactAttempt(record,commandPermit:.init(permit))
            try self.verifyBoundTerminalResources(receipt,journal:journal,permit:permit)
            try scope.verifyQualifiedStructuralCapture(capture)
            guard capture.envelopeBytes == body.candidate,capture.operationID == body.operationID else { throw DeviceStructuralStoreError.conflict }
            return (capture,candidate.snapshot.generationID)
        }
    }
    private func verifyBoundTerminalResources(_ receipt:DeviceBoundTerminalGrantReceipt,
        journal:DeviceLocalProvisioningIntentStore,permit:DeviceLocalResourcePermit)throws {
        try journal.verifyExact(receipt.journalReceipt,plan:receipt.plan,resourcePermit:permit)
        try packages.verifyResolutionCheckpoint(receipt.checkpoint,resourcePermit:permit)
        var fresh:[DeviceProvisioningPackageInput]=[]
        for binding in receipt.packages {
            let verified=try packages.verify(binding.receipt,resourcePermit:permit)
            fresh.append(.retained(entryID:binding.entryID,reference:verified.reference,verified:verified))
        }
        try grants.verifyBoundTerminal(receipt.transition,plan:receipt.plan,packages:fresh,resourcePermit:permit)
        try packages.verifyResolutionCheckpoint(receipt.checkpoint,resourcePermit:permit)
        try journal.verifyExact(receipt.journalReceipt,plan:receipt.plan,resourcePermit:permit)
    }
    /// Fixed completion consumes the ORIGINAL structural capture; persisted diagnostics never recreate
    /// acknowledgment. Journal capacity remains unqualified until every scope exit has succeeded.
    func completeProvisioningExact(_ terminal:DeviceBoundTerminalGrantReceipt,
        acknowledgment:DeviceLocalCompleteSetCommitAcknowledgment,journal:DeviceLocalProvisioningIntentStore)throws->DeviceLocalProvisioningIntentStore.CompletionReceipt {
        guard terminal.packages.count <= 12,terminal.plan.canonicalBytes.count <= ProvisioningIntentCodec.limit,
              acknowledgment.envelopeBytes.count <= 128*1024 else{throw DeviceLocalCompleteSetFailure.sizeLimit}
        let body=try ProvisioningIntentCodec.decode(terminal.plan.canonicalBytes),candidate=try StructuralStoreCodec.envelope(body.candidate)
        guard body.roots == terminal.plan.roots,body.operationID == terminal.plan.operationID,
              acknowledgment.operationID == body.operationID,acknowledgment.generationID == candidate.snapshot.generationID,
              acknowledgment.envelopeBytes == body.candidate else{throw DeviceStructuralStoreError.conflict}
        let transition=try withScope(journal:journal){scope,permit in
            let actual=try [journal.resourceGateDescriptor.rootID,self.packages.resourceGateDescriptor.rootID,self.grants.resourceGateDescriptor.rootID,self.structural.resourceGateDescriptor.rootID]
            guard actual == [body.roots.journalID,body.roots.packageID,body.roots.grantID,body.roots.structuralID] else{throw DeviceLocalResourceGateFailure.invalidRoots}
            try journal.verifyCompletionAntecedent(terminal.journalReceipt,plan:terminal.plan,resourcePermit:permit)
            try self.verifyBoundTerminalExternalResources(terminal,permit:permit)
            try acknowledgment.verifyOriginalUnderScope(scope)
            let transition=try journal.performCompletionExact(terminal.journalReceipt,plan:terminal.plan,envelope:acknowledgment.envelopeBytes,commandPermit:.init(permit))
            try journal.verifyCompletionTransition(transition,resourcePermit:permit)
            try self.verifyBoundTerminalExternalResources(terminal,permit:permit)
            try acknowledgment.verifyOriginalUnderScope(scope)
            try journal.verifyCompletionTransition(transition,resourcePermit:permit)
            return transition
        }
        // No qualification was published inside the scope. Exit checks throwing, or another instance
        // invalidating the journal before this mutex-protected publication, cannot release capacity.
        return try journal.publishCompletionExact(transition,permit:.init())
    }
    private func verifyBoundTerminalExternalResources(_ receipt:DeviceBoundTerminalGrantReceipt,permit:DeviceLocalResourcePermit)throws {
        try packages.verifyResolutionCheckpoint(receipt.checkpoint,resourcePermit:permit)
        var fresh:[DeviceProvisioningPackageInput]=[]
        for binding in receipt.packages {
            let value=try packages.verify(binding.receipt,resourcePermit:permit)
            fresh.append(.retained(entryID:binding.entryID,reference:value.reference,verified:value))
        }
        try grants.verifyBoundTerminal(receipt.transition,plan:receipt.plan,packages:fresh,resourcePermit:permit)
        try packages.verifyResolutionCheckpoint(receipt.checkpoint,resourcePermit:permit)
    }
    func inspectBoundCompletedCurrentExact(journal:DeviceLocalProvisioningIntentStore)throws->DeviceBoundCompletedRestoreDiscovery {
        try withScope(journal:journal){scope,permit in
            let current=try journal.inspectCompletedCurrentExact(resourcePermit:permit)
            let body=try ProvisioningIntentCodec.decode(current.exactIntentBytes)
            let discovery=try scope.inspectLatestStructuralTerminalExact()
            guard discovery.record.rootID == body.roots.structuralID,discovery.record.operationID == body.operationID,
                  discovery.record.candidate == current.envelopeBytes,discovery.record.expectedOld == body.expectedOld else{throw DeviceStructuralStoreError.conflict}
            let recovery=try self.grants.inspectBoundCompletedTerminalRecovery(current,resourcePermit:permit)
            try journal.verifyCompletedCurrentExact(current,resourcePermit:permit)
            try scope.verifyStructuralTerminalDiscovery(discovery)
            return .init(current,recovery,discovery,ObjectIdentifier(journal))
        }
    }
    func restoreBoundCompletedCurrentExact(_ original:DeviceBoundCompletedRestoreDiscovery,journal:DeviceLocalProvisioningIntentStore)throws->DeviceBoundRestoredRuntimeBinding {
        guard original.journalIssuer == ObjectIdentifier(journal),original.grants.packages.count <= 12 else{throw DeviceLocalResourceGateFailure.invalidScope}
        let references=original.grants.packages.map(\.reference)
        let inspected=try packages.inspectRetainedTerminalExact(references)
        guard inspected.count == references.count else{throw DeviceGrantPreparationError.conflict}
        let observations=zip(original.grants.packages,inspected).map{DeviceProvisioningPackageInput.retained(entryID:$0.0.entryID,reference:$0.0.reference,verified:$0.1)}
        let plan=try grants.qualifyBoundTerminalRecovery(original.grants,packages:observations)
        guard plan.canonicalBytes == original.journal.exactIntentBytes else{throw DeviceGrantPreparationError.conflict}
        // Original journal/structural captures are checked BEFORE package sync, never renewed.
        try withScope(journal:journal){scope,permit in
            try journal.verifyCompletedCurrentExact(original.journal,resourcePermit:permit)
            try scope.verifyStructuralTerminalDiscovery(original.structural)
        }
        let resolution=try packages.resolveRetainedTerminalExact(references)
        guard resolution.receipts.count == references.count else{throw DeviceGrantPreparationError.conflict}
        let bindings=zip(original.grants.packages,resolution.receipts).map{DeviceLocalCompleteSetPackageBinding(entryID:$0.0.entryID,receipt:$0.1)}
        let body=try ProvisioningIntentCodec.decode(plan.canonicalBytes),candidate=try StructuralStoreCodec.envelope(body.candidate)
        let final=try withScope(journal:journal){scope,permit -> (DeviceLocalProvisioningIntentStore.CompletedRestoreTransition,DeviceBoundGrantTerminalTransition,DeviceStructuralStore.QualifiedCurrentCapture) in
            let ids=try [journal.resourceGateDescriptor.rootID,self.packages.resourceGateDescriptor.rootID,self.grants.resourceGateDescriptor.rootID,self.structural.resourceGateDescriptor.rootID]
            guard ids == [body.roots.journalID,body.roots.packageID,body.roots.grantID,body.roots.structuralID],body.operationID == original.structural.record.operationID,
                  body.candidate == original.structural.record.candidate,body.expectedOld == original.structural.record.expectedOld else{throw DeviceLocalResourceGateFailure.invalidRoots}
            try journal.verifyCompletedCurrentExact(original.journal,resourcePermit:permit)
            try scope.verifyStructuralTerminalDiscovery(original.structural)
            let fresh=try self.boundRestoredPackages(bindings,checkpoint:resolution.checkpoint,permit:permit)
            // Original grant epoch/node/private-reference evidence must still hold BEFORE journal effects.
            // This verifier does not sync or recapture the recovery object.
            try self.grants.verifyBoundCompletedRecovery(original.grants,plan:plan,packages:fresh,resourcePermit:permit)
            try journal.verifyCompletedCurrentExact(original.journal,resourcePermit:permit)
            let j=try journal.repairCompletedCurrentExact(original.journal,commandPermit:.init(permit))
            let g=try self.grants.performBoundTerminal(original.grants,plan:plan,packages:fresh,commandPermit:.init(permit))
            try journal.verifyCompletedRestoreTransition(j,resourcePermit:permit)
            try self.grants.verifyBoundTerminal(g,plan:plan,packages:fresh,resourcePermit:permit)
            try self.packages.verifyResolutionCheckpoint(resolution.checkpoint,resourcePermit:permit)
            try scope.verifyStructuralTerminalDiscovery(original.structural)
            // Dispatch exact intent, not persisted terminal phase/inode evidence. The original
            // discovery still proves the installed record; the store requires an unresolved command.
            let retained=original.structural.record
            let command=DeviceStructuralOperationRecord(rootID:retained.rootID,operationID:retained.operationID,
                expectedOld:retained.expectedOld,candidate:retained.candidate,resourceAssertions:retained.resourceAssertions)
            guard command.sameIntent(as:retained) else{throw DeviceStructuralStoreError.conflict}
            let capture=try self.structural.performExactAttempt(command,commandPermit:.init(permit))
            try journal.verifyCompletedRestoreTransition(j,resourcePermit:permit)
            let finalPackages=try self.boundRestoredPackages(bindings,checkpoint:resolution.checkpoint,permit:permit)
            try self.grants.verifyBoundTerminal(g,plan:plan,packages:finalPackages,resourcePermit:permit)
            try scope.verifyQualifiedStructuralCapture(capture)
            guard capture.envelopeBytes == original.journal.envelopeBytes,capture.operationID == body.operationID else{throw DeviceStructuralStoreError.conflict}
            try journal.verifyCompletedRestoreTransition(j,resourcePermit:permit)
            return (j,g,capture)
        }
        // All store/scope-exit identity checks succeeded; only now may an opaque binding escape.
        return .init(journal:journal,plan:plan,journalTransition:final.0,grants:final.1,packages:bindings,packageCheckpoint:resolution.checkpoint,capture:final.2,generationID:candidate.snapshot.generationID)
    }
    private func boundRestoredPackages(_ bindings:[DeviceLocalCompleteSetPackageBinding],checkpoint:DevicePackageResolutionCheckpoint,
        permit:DeviceLocalResourcePermit)throws->[DeviceProvisioningPackageInput] {
        guard bindings.count <= 12 else{throw DeviceGrantPreparationError.sizeLimit}
        try packages.verifyResolutionCheckpoint(checkpoint,resourcePermit:permit)
        var fresh:[DeviceProvisioningPackageInput]=[]
        for binding in bindings {let value=try packages.verify(binding.receipt,resourcePermit:permit);fresh.append(.retained(entryID:binding.entryID,reference:value.reference,verified:value))}
        try packages.verifyResolutionCheckpoint(checkpoint,resourcePermit:permit);return fresh
    }
    private func verifyBoundRestoredBinding(_ binding:DeviceBoundRestoredRuntimeBinding,scope:DeviceLocalResourceReadScope,
        permit:DeviceLocalResourcePermit)throws->[DeviceProvisioningPackageInput] {
        try binding.journal.verifyCompletedRestoreTransition(binding.journalTransition,resourcePermit:permit)
        try scope.verifyQualifiedStructuralCapture(binding.capture)
        let fresh=try boundRestoredPackages(binding.packages,checkpoint:binding.packageCheckpoint,permit:permit)
        try grants.verifyBoundTerminal(binding.grants,plan:binding.plan,packages:fresh,resourcePermit:permit)
        try scope.verifyQualifiedStructuralCapture(binding.capture)
        try binding.journal.verifyCompletedRestoreTransition(binding.journalTransition,resourcePermit:permit)
        return fresh
    }
    /// Unmounted static projection of the EXPLICIT configured entry only. No authority or display
    /// selection is inferred; empty sets have no content. All assets come from fresh exact package
    /// verification under the original restored four-store evidence, never directory enumeration.
    func makeManagedStaticContentExact(binding:DeviceBoundRestoredRuntimeBinding)throws->DeviceManagedStaticContent {
        let body=try ProvisioningIntentCodec.decode(binding.plan.canonicalBytes)
        let candidate=try StructuralStoreCodec.envelope(body.candidate)
        guard candidate.snapshot.entries.count <= 12 else{throw DeviceManagedRenderFailure.sizeLimit}
        guard let selected=candidate.snapshot.configuredEntryID,
              let entry=candidate.snapshot.entries.first(where:{$0.entryID == selected}) else{throw DeviceManagedRenderFailure.emptySelection}
        let package=try withScope(journal:binding.journal){scope,permit -> QualifiedDevicePackage in
            let fresh=try self.verifyBoundRestoredBinding(binding,scope:scope,permit:permit)
            guard let supplied=fresh.first(where:{value in
                switch value{case .retained(let id,_,_):return id == selected;case .supplied:return false}
            }),case .retained(_,_,let verified)=supplied,
                try StructuralStoreCodec.encode(verified.package.revision) == StructuralStoreCodec.encode(entry.revision) else{throw DeviceManagedRenderFailure.invalidContent}
            try self.verifyBoundRestoredBinding(binding,scope:scope,permit:permit)
            return verified.package
        }
        // Private projection construction and caller-visible checks occur after all scope exits.
        let content=try DeviceManagedRenderProjection.make(package:package,operationID:binding.operationID,
            generationID:binding.generationID,entryID:selected,displayName:entry.displayName,
            validate:{try self.verifyBoundRestoredRuntimeBinding(binding)})
        try content.verifyResources();return content
    }
    func verifyBoundRestoredRuntimeBinding(_ binding:DeviceBoundRestoredRuntimeBinding)throws {
        try withScope(journal:binding.journal){scope,permit in _ = try self.verifyBoundRestoredBinding(binding,scope:scope,permit:permit)}
    }
    func makeGenericRuntimeExact(binding:DeviceBoundRestoredRuntimeBinding,entryID:UUID,
        admission:any DeviceImmutableGenericAdmissionDriver,http:any HTTPTransport,webSocket:any WebSocketTransport,
        resolver:any DestinationResolver,clock:any PairingClock)async throws->any DeviceImmutableGenericOperations {
        try Task.checkCancellation()
        let body=try ProvisioningIntentCodec.decode(binding.plan.canonicalBytes),candidate=try StructuralStoreCodec.envelope(body.candidate)
        guard candidate.snapshot.entries.contains(where:{$0.entryID == entryID}),let owner=candidate.snapshot.contentOwner,owner.isWellFormed,owner.role == .controller else{throw ConnectionFailure.permissionRequired}
        let operation=DeviceImmutableGenericScope(structuralRootID:body.roots.structuralID,operationID:body.operationID,generationID:candidate.snapshot.generationID,entryID:entryID,owner:owner,grants:body.grantIdentity)
        let authorization=DeviceImmutableGenericAuthorization(scope:operation,driver:admission,validate:{try self.verifyBoundRestoredRuntimeBinding(binding)})
        try authorization.validate()
        let seed=try withScope(journal:binding.journal){scope,permit -> DeviceImmutableGenericSeed in
            try Task.checkCancellation();let fresh=try self.verifyBoundRestoredBinding(binding,scope:scope,permit:permit)
            let seed=try self.grants.makeBoundGenericSeed(binding.grants,plan:binding.plan,packages:fresh,owner:owner,entryID:entryID,resourcePermit:permit)
            _ = try self.verifyBoundRestoredBinding(binding,scope:scope,permit:permit);try Task.checkCancellation();return seed
        }
        let runtime=try await seed.instantiate(authorization:authorization,http:http,webSocket:webSocket,resolver:resolver,clock:clock)
        do {try Task.checkCancellation();try authorization.validate();return runtime}catch{await runtime.cancel();throw error}
    }
    /// Unmounted fixed entry factory. Mandatory native-driver seam is NOT a production admission
    /// implementation. Driver/resolver/actor installation/transport work occur outside resource locks.
    func makeGenericRuntimeExact(binding:DeviceRestoredRuntimeBinding,entryID:UUID,
        admission:any DeviceImmutableGenericAdmissionDriver,http:any HTTPTransport,webSocket:any WebSocketTransport,
        resolver:any DestinationResolver,clock:any PairingClock) async throws -> any DeviceImmutableGenericOperations {
        try Task.checkCancellation()
        let request=binding.request
        try DeviceLocalCompleteSetBounds.preflight(request,resources:binding.resources)
        guard request.snapshot.entries.contains(where:{$0.entryID == entryID}) else { throw ConnectionFailure.permissionRequired }
        let scope=DeviceImmutableGenericScope(structuralRootID:request.structuralRootID,operationID:request.operationID,
            generationID:request.snapshot.generationID,entryID:entryID,owner:request.owner,grants:binding.resources.selected.identity)
        let authorization=DeviceImmutableGenericAuthorization(scope:scope,driver:admission,validate:{try self.withReadScope { try self.verifyRuntimeBinding(binding,scope:$0) }})
        try authorization.validate()
        let seed=try withReadScope { scope -> DeviceImmutableGenericSeed in
            try Task.checkCancellation();try self.verifyRuntimeBinding(binding,scope:scope)
            let expectations=try request.packages.map { entryBinding -> DeviceGrantEntryExpectation in
                guard let receipt=self.bindingReference(entryBinding.reference,in:binding.resources) else { throw DeviceLocalCompleteSetFailure.packageMismatch }
                return .init(entryID:entryBinding.entryID,package:try scope.verifyPackage(receipt).package)
            }
            guard let receipt=binding.resources.grantReceipts.first(where:{$0.identity == binding.resources.selected.identity && $0.operationID == binding.resources.selected.operationID}) else { throw DeviceLocalCompleteSetFailure.invalidInput }
            let seed=try scope.genericSeed(receipt,expectedEntries:expectations,owner:request.owner,entryID:entryID)
            try self.verifyRuntimeBinding(binding,scope:scope);try Task.checkCancellation();return seed
        }
        let runtime=try await seed.instantiate(authorization:authorization,http:http,webSocket:webSocket,resolver:resolver,clock:clock)
        do{try Task.checkCancellation();return runtime}catch{await runtime.cancel();throw error}
    }
    private func verifyRuntimeBinding(_ binding:DeviceRestoredRuntimeBinding,scope:DeviceLocalResourceReadScope)throws {
        try scope.verifyQualifiedStructuralCapture(binding.capture)
        try scope.verifyResolutionCheckpoints(packages:binding.resources.packageCheckpoint,grants:binding.resources.grantCheckpoint)
        let observed=try DeviceLocalCompleteSetCoordinator(packageStore:packages,grantStore:grants).observeRecoveredUnderGate(binding.request,resources:binding.resources,scope:scope)
        guard observed.candidateEnvelopeBytes == binding.capture.envelopeBytes,binding.request.operationID == binding.capture.operationID else { throw DeviceStructuralStoreError.conflict }
        try scope.verifyResolutionCheckpoints(packages:binding.resources.packageCheckpoint,grants:binding.resources.grantCheckpoint)
        try scope.verifyQualifiedStructuralCapture(binding.capture)
    }
    private func bindingReference(_ reference:DevicePreparedPackageReference,in resources:DeviceResolvedRetainedResources)->DevicePreparedPackageReceipt? {
        resources.packageReceipts.first {$0.reference.rootID == reference.rootID && $0.reference.preparationOperationID == reference.preparationOperationID && $0.reference.contentID.utf8.elementsEqual(reference.contentID.utf8) && $0.reference.directory.utf8.elementsEqual(reference.directory.utf8)}
    }
    private func withScope<T>(journal:DeviceLocalProvisioningIntentStore? = nil,_ body: (DeviceLocalResourceReadScope,DeviceLocalResourcePermit) throws -> T) throws -> T {
        try DeviceLocalResourceRegistry.requireIdle()
        var participants = try [packages.resourceGateDescriptor,grants.resourceGateDescriptor,structural.resourceGateDescriptor]
        if let journal { participants.append(try journal.resourceGateDescriptor) }
        let descriptors = participants
            .sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        for item in descriptors {
            guard item.path.hasPrefix("/"), item.path.utf8.count <= 4096 else { throw DeviceLocalResourceGateFailure.invalidRoots }
        }
        for first in 0..<descriptors.count {
            for second in (first+1)..<descriptors.count {
                let a = descriptors[first].path, b = descriptors[second].path
                guard !DeviceLocalResourceDescriptor.pathsOverlap(a,b) else { throw DeviceLocalResourceGateFailure.invalidRoots }
            }
        }
        let permit = DeviceLocalResourcePermit(descriptors)
        try DeviceLocalResourceRegistry.begin(permit)
        defer { permit.invalidate(); DeviceLocalResourceRegistry.finish(permit) }
        var result: T?
        func acquire(_ index: Int) throws {
            if index == descriptors.count {
                try DeviceLocalResourceRegistry.execute(permit)
                defer { permit.invalidate() } // BEFORE any participant starts releasing locks.
                result = try body(.init(permit,packages,grants,structural),permit); return
            }
            let descriptor = descriptors[index]
            if descriptor.instance == ObjectIdentifier(packages) { try packages.withResourceGateScope(permit) { try acquire(index+1) } }
            else if descriptor.instance == ObjectIdentifier(grants) { try grants.withResourceGateScope(permit) { try acquire(index+1) } }
            else if let journal,descriptor.instance == ObjectIdentifier(journal) { try journal.withResourceGateScope(permit) { try acquire(index+1) } }
            else { try structural.withResourceGateScope(permit) { try acquire(index+1) } }
        }
        try acquire(0)
        guard let result else { throw DeviceLocalResourceGateFailure.invalidScope }; return result
    }
}

/// Only the fixed gate factory constructs this authorization. Driver callbacks run with no resource
/// locks held. Validation is mandatory exactly once, including drivers that swallow validator errors.
final class DeviceImmutableGenericAuthorization: @unchecked Sendable {
    let scope:DeviceImmutableGenericScope
    private let driver:any DeviceImmutableGenericAdmissionDriver
    private let validator:()throws->Void
    fileprivate init(scope:DeviceImmutableGenericScope,driver:any DeviceImmutableGenericAdmissionDriver,validate:@escaping ()throws->Void) {
        self.scope=scope;self.driver=driver;validator=validate
    }
    func reserve(onCancel:@escaping @Sendable ()->Void)throws->any DeviceImmutableGenericReservation {
        try Task.checkCancellation();try DeviceLocalResourceRegistry.requireIdle()
        var count=0;var succeeded=false
        let reservation=try driver.reserve(scope:scope,validateResources:{
            count += 1
            guard count == 1 else { throw ConnectionFailure.permissionRequired }
            try self.validator();succeeded=true
        },onCancel:onCancel)
        guard count == 1,succeeded else { reservation.finish();throw ConnectionFailure.permissionRequired }
        do {try Task.checkCancellation();try reservation.check();try Task.checkCancellation();return reservation} catch {reservation.finish();throw error}
    }
    func validate()throws {
        let reservation=try reserve(onCancel:{})
        defer {reservation.finish()};try Task.checkCancellation();try reservation.check();try Task.checkCancellation()
    }
}

/// Fixed private-attempt command only. No arbitrary mutation closure, secret getter or resource
/// completion authority. Backend/fault seams retain the synchronous nonreentrant store contract.
final class DeviceBoundGrantCommandPermit {
    private let permit:DeviceLocalResourcePermit
    fileprivate init(_ permit:DeviceLocalResourcePermit){self.permit=permit}
    func begin(_ instance:ObjectIdentifier)throws{try permit.beginRead(instance)}
    func end(){permit.endRead()}
}
final class DeviceBoundGrantAttemptCoordinator {
    private let journal:DeviceLocalProvisioningIntentStore,grants:DeviceGrantPreparationStore
    init(journal:DeviceLocalProvisioningIntentStore,grants:DeviceGrantPreparationStore){self.journal=journal;self.grants=grants}
    func stageExact(_ original:DeviceProvisioningPlanRequest,plan:DeviceValidatedProvisioningPlan,
                    journalReceipt:DeviceLocalProvisioningIntentStore.Receipt)throws->DeviceBoundGrantPrivateAttempt {
        let fresh=try DeviceProvisioningPlanner.qualify(original)
        guard fresh.canonicalBytes == plan.canonicalBytes else{throw DeviceGrantPreparationError.conflict}
        let expected=try DeviceGrantPreparationStore.boundExpectations(original.packages)
        let request=DeviceGrantPreparationRequest(operationID:original.grantOperationID,input:original.grantInput,
            qualified:original.qualifiedGrant,expectedEntries:expected)
        var result:DeviceBoundGrantPrivateAttempt?
        try scope{permit in
            try journal.verifyExact(journalReceipt,plan:plan,resourcePermit:permit)
            let receipt=try grants.performBoundPrivateAttempt(request,plan:plan,recovery:nil,commandPermit:.init(permit))
            try journal.verifyExact(journalReceipt,plan:plan,resourcePermit:permit)
            try grants.verifyBoundPrivateAttempt(receipt,resourcePermit:permit)
            result=receipt
        }
        guard let result else{throw DeviceLocalResourceGateFailure.invalidScope};return result
    }
    func recommitRecoveredExact(_ recovery:DeviceBoundGrantRecoveryPlan,
                                journalReceipt:DeviceLocalProvisioningIntentStore.Receipt)throws->DeviceBoundGrantPrivateAttempt {
        var result:DeviceBoundGrantPrivateAttempt?
        try scope{permit in
            try journal.verifyExact(journalReceipt,plan:recovery.plan,resourcePermit:permit)
            let receipt=try grants.performRecoveredBoundPrivateAttempt(recovery,commandPermit:.init(permit))
            try journal.verifyExact(journalReceipt,plan:recovery.plan,resourcePermit:permit)
            try grants.verifyBoundPrivateAttempt(receipt,resourcePermit:permit)
            result=receipt
        }
        guard let result else{throw DeviceLocalResourceGateFailure.invalidScope};return result
    }
    private func scope(_ body:(DeviceLocalResourcePermit)throws->Void)throws {
        try DeviceLocalResourceRegistry.requireIdle()
        let descriptors=try [journal.resourceGateDescriptor,grants.resourceGateDescriptor].sorted {
            if $0.path.utf8.elementsEqual($1.path.utf8){return $0.rootID.uuidString < $1.rootID.uuidString}
            return $0.path.utf8.lexicographicallyPrecedes($1.path.utf8)
        }
        guard descriptors[0].instance != descriptors[1].instance,
              !DeviceLocalResourceDescriptor.pathsOverlap(descriptors[0].path,descriptors[1].path) else{throw DeviceLocalResourceGateFailure.invalidRoots}
        let permit=DeviceLocalResourcePermit(descriptors)
        try DeviceLocalResourceRegistry.begin(permit);defer{permit.invalidate();DeviceLocalResourceRegistry.finish(permit)}
        func acquire(_ index:Int)throws {
            if index == descriptors.count{try DeviceLocalResourceRegistry.execute(permit);try body(permit);return}
            if descriptors[index].instance == ObjectIdentifier(journal){try journal.withResourceGateScope(permit){try acquire(index+1)}}
            else{try grants.withResourceGateScope(permit){try acquire(index+1)}}
        }
        try acquire(0)
    }
}

/// Fixed package-batch dispatch only; no read scope can construct a mutation permit.
final class DeviceBoundPackageCommandPermit {
    private let permit:DeviceLocalResourcePermit
    fileprivate init(_ permit:DeviceLocalResourcePermit){self.permit=permit}
    func begin(_ instance:ObjectIdentifier)throws{try permit.beginRead(instance)}
    func end(){permit.endRead()}
}
/// Only the fixed credential command can construct this dispatch permit.
final class DeviceBoundCredentialCommandPermit {
    private let permit:DeviceLocalResourcePermit
    fileprivate init(_ permit:DeviceLocalResourcePermit){self.permit=permit}
    func begin(_ instance:ObjectIdentifier)throws{try permit.beginRead(instance)}
    func end(){permit.endRead()}
}
/// Credential additions and recorded references only, never a terminal grant/runtime receipt.
final class DeviceBoundCompletedCredentials:GrantSecretRedacted {
    fileprivate let batch:DeviceBoundPreparedPackageSet,transition:DeviceBoundGrantCredentialTransition
    fileprivate init(batch:DeviceBoundPreparedPackageSet,transition:DeviceBoundGrantCredentialTransition){self.batch=batch;self.transition=transition}
}
/// Fixed v2 terminal dispatch only; legacy/read scopes cannot manufacture it.
final class DeviceBoundTerminalCommandPermit {
    private let permit:DeviceLocalResourcePermit
    fileprivate init(_ permit:DeviceLocalResourcePermit){self.permit=permit}
    func begin(_ instance:ObjectIdentifier)throws{try permit.beginRead(instance)}
    func end(){permit.endRead()}
}
/// V2 terminal/head mechanics only. Not a legacy grant receipt, journal completion or admission.
final class DeviceBoundTerminalGrantReceipt:GrantSecretRedacted {
    fileprivate let plan:DeviceValidatedProvisioningPlan,journalReceipt:DeviceLocalProvisioningIntentStore.Receipt
    fileprivate let packages:[DeviceLocalCompleteSetPackageBinding],checkpoint:DevicePackageResolutionCheckpoint
    fileprivate let transition:DeviceBoundGrantTerminalTransition
    fileprivate init(plan:DeviceValidatedProvisioningPlan,journalReceipt:DeviceLocalProvisioningIntentStore.Receipt,
                     packages:[DeviceLocalCompleteSetPackageBinding],checkpoint:DevicePackageResolutionCheckpoint,transition:DeviceBoundGrantTerminalTransition) {
        self.plan=plan;self.journalReceipt=journalReceipt;self.packages=packages;self.checkpoint=checkpoint;self.transition=transition
    }
}
/// One complete package batch's ORIGINAL final checkpoint. Not structural/grant completion,
/// membership, activation or admission authority. No payload/secret getter or serialization.
final class DeviceBoundPreparedPackageSet {
    let packages:[DeviceLocalCompleteSetPackageBinding]
    fileprivate let checkpoint:DevicePackageResolutionCheckpoint,plan:DeviceValidatedProvisioningPlan
    fileprivate let journalReceipt:DeviceLocalProvisioningIntentStore.Receipt,privateAnchor:DeviceBoundGrantPrivateAttempt
    fileprivate let journalIssuer:ObjectIdentifier,grantIssuer:ObjectIdentifier,packageIssuer:ObjectIdentifier
    fileprivate init(packages:[DeviceLocalCompleteSetPackageBinding],checkpoint:DevicePackageResolutionCheckpoint,
                     plan:DeviceValidatedProvisioningPlan,journalReceipt:DeviceLocalProvisioningIntentStore.Receipt,
                     privateAnchor:DeviceBoundGrantPrivateAttempt,journal:DeviceLocalProvisioningIntentStore,
                     grants:DeviceGrantPreparationStore,store:DevicePackagePreparationStore) {
        self.packages=packages;self.checkpoint=checkpoint;self.plan=plan;self.journalReceipt=journalReceipt;self.privateAnchor=privateAnchor
        journalIssuer=ObjectIdentifier(journal);grantIssuer=ObjectIdentifier(grants);packageIssuer=ObjectIdentifier(store)
    }
}
/// Unmounted fixed three-root batch. Existing backend/fault seams retain their synchronous
/// nonreentrant-under-lock contract; no UI/driver/async/notification callback is introduced.
/// Successor private stage only. Returned current journal receipt includes the intentional repair
/// epoch; no old receipt is refreshed and no terminal/structural/runtime authority is issued.
final class DeviceBoundSuccessorPrivateStage {
    let journalReceipt:DeviceLocalProvisioningIntentStore.Receipt
    let privateAnchor:DeviceBoundGrantPrivateAttempt
    fileprivate init(_ receipt:DeviceLocalProvisioningIntentStore.Receipt,_ anchor:DeviceBoundGrantPrivateAttempt){journalReceipt=receipt;privateAnchor=anchor}
}
final class DeviceBoundPackagePreparationCoordinator {
    private let journal:DeviceLocalProvisioningIntentStore,grants:DeviceGrantPreparationStore,packages:DevicePackagePreparationStore
    init(journal:DeviceLocalProvisioningIntentStore,grants:DeviceGrantPreparationStore,packages:DevicePackagePreparationStore) {
        self.journal=journal;self.grants=grants;self.packages=packages
    }
    private func checkedSuccessorRequest(_ original:DeviceProvisioningPlanRequest,plan:DeviceValidatedProvisioningPlan,
        permit:DeviceLocalResourcePermit)throws->(DeviceGrantPreparationRequest,[DeviceProvisioningPackageInput]) {
        let packages=try self.packages.inspectBoundPackages(original.packages,plan:plan,resourcePermit:permit)
        let expected=try DeviceGrantPreparationStore.boundExpectations(packages)
        let qualified=try DeviceGrantRevisionQualifier.qualify(original.grantInput,expectedEntries:expected)
        let current=DeviceProvisioningPlanRequest(roots:original.roots,operationID:original.operationID,grantOperationID:original.grantOperationID,
            expectedGenerationID:original.expectedGenerationID,baseline:original.baseline,snapshot:original.snapshot,owner:original.owner,
            packages:packages,grantInput:original.grantInput,qualifiedGrant:qualified)
        guard try DeviceProvisioningPlanner.qualify(current).canonicalBytes == plan.canonicalBytes else{throw DeviceGrantPreparationError.conflict}
        return (.init(operationID:original.grantOperationID,input:original.grantInput,qualified:qualified,expectedEntries:expected),packages)
    }
    func prepareSuccessorPrivateAttemptExact(_ original:DeviceProvisioningPlanRequest,plan:DeviceValidatedProvisioningPlan,
        journalReceipt:DeviceLocalProvisioningIntentStore.Receipt)throws->DeviceBoundSuccessorPrivateStage {
        guard original.packages.count <= 12 else{throw DeviceGrantPreparationError.sizeLimit}
        let fresh=try DeviceProvisioningPlanner.qualify(original)
        guard fresh.canonicalBytes == plan.canonicalBytes else{throw DeviceGrantPreparationError.conflict}
        let expected=try DeviceGrantPreparationStore.boundExpectations(original.packages)
        let request=DeviceGrantPreparationRequest(operationID:original.grantOperationID,input:original.grantInput,qualified:original.qualifiedGrant,expectedEntries:expected)
        _ = try DeviceProvisioningPrivateAttemptV2.encoded(request,intent:plan.canonicalBytes)
        var journalOriginal:DeviceLocalProvisioningIntentStore.SuccessorPredecessorCheckpoint?
        var grantOriginal:DeviceGrantPreparationStore.SuccessorPredecessor?
        try scope{permit in
            let j=try journal.captureSuccessorPredecessorExact(journalReceipt,plan:plan,resourcePermit:permit)
            let g=try grants.captureSuccessorPredecessorExact(j,resourcePermit:permit)
            try journal.verifySuccessorPredecessorExact(j,resourcePermit:permit)
            journalOriginal=j;grantOriginal=g
        }
        guard let j=journalOriginal,let g=grantOriginal,g.packages.count <= 12 else{throw DeviceLocalResourceGateFailure.invalidScope}
        let references=g.packages.map(\.reference)
        let inspected=try packages.inspectRetainedTerminalExact(references)
        guard inspected.count == g.packages.count else{throw DeviceGrantPreparationError.conflict}
        let prior=zip(g.packages,inspected).map{DeviceProvisioningPackageInput.retained(entryID:$0.0.entryID,reference:$0.0.reference,verified:$0.1)}
        _ = try grants.qualifySuccessorPredecessorExact(g,packages:prior)
        // ALL new private capacity/input checks precede outside-gate package durability repair.
        try scope{permit in
            try journal.verifySuccessorPredecessorExact(j,resourcePermit:permit)
            let (checkedRequest,_)=try checkedSuccessorRequest(original,plan:plan,permit:permit)
            try grants.preflightSuccessorExact(g,request:checkedRequest,plan:plan,previousPackages:prior,resourcePermit:permit)
            try journal.verifySuccessorPredecessorExact(j,resourcePermit:permit)
        }
        let resolution=try packages.resolveRetainedTerminalExact(references)
        guard resolution.receipts.count == g.packages.count else{throw DeviceGrantPreparationError.conflict}
        var result:DeviceBoundSuccessorPrivateStage?
        try scope{permit in
            try journal.verifySuccessorPredecessorExact(j,resourcePermit:permit)
            try packages.verifyResolutionCheckpoint(resolution.checkpoint,resourcePermit:permit)
            var checked:[DeviceProvisioningPackageInput]=[]
            for (binding,receipt) in zip(g.packages,resolution.receipts) {
                let value=try packages.verify(receipt,resourcePermit:permit)
                guard value.reference == binding.reference else{throw DeviceGrantPreparationError.conflict}
                checked.append(.retained(entryID:binding.entryID,reference:binding.reference,verified:value))
            }
            let (checkedRequest,currentPackages)=try checkedSuccessorRequest(original,plan:plan,permit:permit)
            try grants.preflightSuccessorExact(g,request:checkedRequest,plan:plan,previousPackages:checked,resourcePermit:permit)
            try packages.verifyResolutionCheckpoint(resolution.checkpoint,resourcePermit:permit)
            try journal.verifySuccessorPredecessorExact(j,resourcePermit:permit)
            let transition=try journal.repairSuccessorPredecessorExact(j,commandPermit:.init(permit))
            let anchor=try grants.performSuccessorPrivateAttemptExact(g,request:checkedRequest,plan:plan,previousPackages:checked,commandPermit:.init(permit))
            try journal.verifySuccessorTransitionExact(transition,resourcePermit:permit)
            try grants.verifyBoundPrivateAttempt(anchor,plan:plan,packages:currentPackages,resourcePermit:permit)
            try packages.verifyResolutionCheckpoint(resolution.checkpoint,resourcePermit:permit)
            try journal.verifySuccessorTransitionExact(transition,resourcePermit:permit)
            result = .init(transition.receipt,anchor)
        }
        guard let result else{throw DeviceLocalResourceGateFailure.invalidScope};return result
    }
    func preparePackagesExact(plan:DeviceValidatedProvisioningPlan,journalReceipt:DeviceLocalProvisioningIntentStore.Receipt,
                              privateAnchor:DeviceBoundGrantPrivateAttempt,packages inputs:[DeviceProvisioningPackageInput])throws->DeviceBoundPreparedPackageSet {
        guard inputs.count <= 12 else{throw DevicePackagePreparationError.sizeLimit}
        var result:DeviceBoundPreparedPackageSet?
        try scope{permit in
            try journal.verifyExact(journalReceipt,plan:plan,resourcePermit:permit)
            try grants.verifyBoundPrivateAttempt(privateAnchor,resourcePermit:permit)
            let fresh=try packages.inspectBoundPackages(inputs,plan:plan,resourcePermit:permit)
            try grants.verifyBoundPrivateAttempt(privateAnchor,plan:plan,packages:fresh,resourcePermit:permit)
            try journal.verifyExact(journalReceipt,plan:plan,resourcePermit:permit)
            let terminal=try packages.performBoundPackagesExact(fresh,plan:plan,commandPermit:.init(permit))
            let body=try ProvisioningIntentCodec.decode(plan.canonicalBytes),envelope=try StructuralStoreCodec.envelope(body.candidate)
            let refs=try DeviceLocalCompleteSetRestoreCodec.references(envelope.intent)
            guard terminal.receipts.count == refs.packages.count else{throw DevicePackagePreparationError.conflict}
            let bindings=zip(refs.packages,terminal.receipts).map{DeviceLocalCompleteSetPackageBinding(entryID:$0.0.entryID,receipt:$0.1)}
            let prepared=DeviceBoundPreparedPackageSet(packages:bindings,checkpoint:terminal.checkpoint,plan:plan,
                journalReceipt:journalReceipt,privateAnchor:privateAnchor,journal:journal,grants:grants,store:packages)
            try verifyPreparedSet(prepared,permit:permit)
            result=prepared
        }
        guard let result else{throw DeviceLocalResourceGateFailure.invalidScope};return result
    }
    /// Validate only the ORIGINAL batch checkpoint; no implicit resolution/renewal. This is a future
    /// fixed credential-command prerequisite, not admission or a substitute for executing that command.
    func verifyPreparedSet(_ prepared:DeviceBoundPreparedPackageSet)throws {
        try scope{permit in try verifyPreparedSet(prepared,permit:permit)}
    }
    private func verifyPreparedSet(_ prepared:DeviceBoundPreparedPackageSet,permit:DeviceLocalResourcePermit)throws {
        guard prepared.packages.count <= 12,prepared.journalIssuer == ObjectIdentifier(journal),
              prepared.grantIssuer == ObjectIdentifier(grants),prepared.packageIssuer == ObjectIdentifier(packages) else{throw DeviceLocalResourceGateFailure.invalidScope}
        try journal.verifyExact(prepared.journalReceipt,plan:prepared.plan,resourcePermit:permit)
        try grants.verifyBoundPrivateAttempt(prepared.privateAnchor,resourcePermit:permit)
        try packages.verifyResolutionCheckpoint(prepared.checkpoint,resourcePermit:permit)
        var fresh:[DeviceProvisioningPackageInput]=[]
        for binding in prepared.packages {
            let verified=try packages.verify(binding.receipt,resourcePermit:permit)
            fresh.append(.retained(entryID:binding.entryID,reference:verified.reference,verified:verified))
        }
        try grants.verifyBoundPrivateAttempt(prepared.privateAnchor,plan:prepared.plan,packages:fresh,resourcePermit:permit)
        try packages.verifyResolutionCheckpoint(prepared.checkpoint,resourcePermit:permit)
        try journal.verifyExact(prepared.journalReceipt,plan:prepared.plan,resourcePermit:permit)
        try grants.verifyBoundPrivateAttempt(prepared.privateAnchor,resourcePermit:permit)
    }
    func completeCredentialsExact(_ batch:DeviceBoundPreparedPackageSet)throws->DeviceBoundCompletedCredentials {
        var result:DeviceBoundCompletedCredentials?
        try scope{permit in
            try verifyPreparedSet(batch,permit:permit)
            let fresh=try credentialPackages(batch,permit:permit)
            let transition=try grants.performBoundCredentialCompletion(batch.privateAnchor,plan:batch.plan,packages:fresh,commandPermit:.init(permit))
            let receipt=DeviceBoundCompletedCredentials(batch:batch,transition:transition)
            try verifyCompletedCredentials(receipt,permit:permit);result=receipt
        }
        guard let result else{throw DeviceLocalResourceGateFailure.invalidScope};return result
    }
    func verifyCompletedCredentials(_ receipt:DeviceBoundCompletedCredentials)throws {
        try scope{permit in try verifyCompletedCredentials(receipt,permit:permit)}
    }
    private func credentialPackages(_ batch:DeviceBoundPreparedPackageSet,permit:DeviceLocalResourcePermit)throws->[DeviceProvisioningPackageInput] {
        guard batch.packages.count <= 12,batch.journalIssuer == ObjectIdentifier(journal),batch.grantIssuer == ObjectIdentifier(grants),batch.packageIssuer == ObjectIdentifier(packages) else{throw DeviceLocalResourceGateFailure.invalidScope}
        try journal.verifyExact(batch.journalReceipt,plan:batch.plan,resourcePermit:permit)
        try packages.verifyResolutionCheckpoint(batch.checkpoint,resourcePermit:permit)
        var fresh:[DeviceProvisioningPackageInput]=[]
        for binding in batch.packages {
            let value=try packages.verify(binding.receipt,resourcePermit:permit)
            fresh.append(.retained(entryID:binding.entryID,reference:value.reference,verified:value))
        }
        try packages.verifyResolutionCheckpoint(batch.checkpoint,resourcePermit:permit)
        try journal.verifyExact(batch.journalReceipt,plan:batch.plan,resourcePermit:permit)
        return fresh
    }
    private func verifyCompletedCredentials(_ receipt:DeviceBoundCompletedCredentials,permit:DeviceLocalResourcePermit)throws {
        // The old anchor's epoch/record intentionally cannot be revalidated after progress. Check the
        // privately bound transition instead, retaining ORIGINAL package/journal evidence throughout.
        let fresh=try credentialPackages(receipt.batch,permit:permit)
        try grants.verifyBoundCredentialTransition(receipt.transition,plan:receipt.batch.plan,packages:fresh,resourcePermit:permit)
        try packages.verifyResolutionCheckpoint(receipt.batch.checkpoint,resourcePermit:permit)
        try journal.verifyExact(receipt.batch.journalReceipt,plan:receipt.batch.plan,resourcePermit:permit)
    }
    func closeGrantTerminalExact(_ completed:DeviceBoundCompletedCredentials)throws->DeviceBoundTerminalGrantReceipt {
        var result:DeviceBoundTerminalGrantReceipt?
        try scope{permit in
            try verifyCompletedCredentials(completed,permit:permit)
            let batch=completed.batch,fresh=try credentialPackages(batch,permit:permit)
            let original=try grants.captureBoundTerminal(completed.transition,plan:batch.plan,resourcePermit:permit)
            let transition=try grants.performBoundTerminal(original,plan:batch.plan,packages:fresh,commandPermit:.init(permit))
            let receipt=DeviceBoundTerminalGrantReceipt(plan:batch.plan,journalReceipt:batch.journalReceipt,packages:batch.packages,checkpoint:batch.checkpoint,transition:transition)
            try verifyGrantTerminalExact(receipt,permit:permit);result=receipt
        }
        guard let result else{throw DeviceLocalResourceGateFailure.invalidScope};return result
    }
    func inspectGrantTerminalRecoveryExact()throws->DeviceBoundGrantTerminalRecovery {
        // Retained current completion can be explicitly requalified for an exact restart retry. This
        // diagnostic still cannot mint a structural acknowledgment or release journal capacity.
        guard let diagnostic=try journal.inspectPendingExact() ?? journal.inspectLatestRetainedIntentExact() else{throw DeviceGrantPreparationError.repairRequired}
        return try grants.inspectBoundTerminalRecovery(diagnostic)
    }
    func recommitGrantTerminalExact(_ recovery:DeviceBoundGrantTerminalRecovery)throws->DeviceBoundTerminalGrantReceipt {
        guard recovery.packages.count <= 12 else{throw DeviceGrantPreparationError.sizeLimit}
        let refs=recovery.packages.map(\.reference)
        let inspected=try packages.inspectRetainedTerminalExact(refs)
        guard inspected.count == recovery.packages.count else{throw DeviceGrantPreparationError.conflict}
        let observations=zip(recovery.packages,inspected).map{DeviceProvisioningPackageInput.retained(entryID:$0.0.entryID,reference:$0.0.reference,verified:$0.1)}
        // Validate every mapping/private byte BEFORE either journal or package synchronization. Grant
        // checkpoint stays original: neither of these other-root repairs changes its epoch.
        let plan=try grants.qualifyBoundTerminalRecovery(recovery,packages:observations)
        let journalReceipt=try journal.recommitExact(plan)
        let resolution=try packages.resolveRetainedTerminalExact(refs)
        guard resolution.receipts.count == recovery.packages.count else{throw DeviceGrantPreparationError.conflict}
        let bindings=zip(recovery.packages,resolution.receipts).map{DeviceLocalCompleteSetPackageBinding(entryID:$0.0.entryID,receipt:$0.1)}
        var result:DeviceBoundTerminalGrantReceipt?
        try scope{permit in
            let fresh=try terminalPackages(plan:plan,journalReceipt:journalReceipt,bindings:bindings,checkpoint:resolution.checkpoint,permit:permit)
            let transition=try grants.performBoundTerminal(recovery,plan:plan,packages:fresh,commandPermit:.init(permit))
            let receipt=DeviceBoundTerminalGrantReceipt(plan:plan,journalReceipt:journalReceipt,packages:bindings,checkpoint:resolution.checkpoint,transition:transition)
            try verifyGrantTerminalExact(receipt,permit:permit);result=receipt
        }
        guard let result else{throw DeviceLocalResourceGateFailure.invalidScope};return result
    }
    func verifyGrantTerminalExact(_ receipt:DeviceBoundTerminalGrantReceipt)throws {
        try scope{permit in try verifyGrantTerminalExact(receipt,permit:permit)}
    }
    private func terminalPackages(plan:DeviceValidatedProvisioningPlan,journalReceipt:DeviceLocalProvisioningIntentStore.Receipt,
        bindings:[DeviceLocalCompleteSetPackageBinding],checkpoint:DevicePackageResolutionCheckpoint,permit:DeviceLocalResourcePermit)throws->[DeviceProvisioningPackageInput] {
        guard bindings.count <= 12 else{throw DeviceGrantPreparationError.sizeLimit}
        try journal.verifyExact(journalReceipt,plan:plan,resourcePermit:permit)
        try packages.verifyResolutionCheckpoint(checkpoint,resourcePermit:permit)
        var fresh:[DeviceProvisioningPackageInput]=[]
        for binding in bindings {
            let value=try packages.verify(binding.receipt,resourcePermit:permit)
            fresh.append(.retained(entryID:binding.entryID,reference:value.reference,verified:value))
        }
        try packages.verifyResolutionCheckpoint(checkpoint,resourcePermit:permit)
        try journal.verifyExact(journalReceipt,plan:plan,resourcePermit:permit)
        return fresh
    }
    private func verifyGrantTerminalExact(_ receipt:DeviceBoundTerminalGrantReceipt,permit:DeviceLocalResourcePermit)throws {
        let fresh=try terminalPackages(plan:receipt.plan,journalReceipt:receipt.journalReceipt,bindings:receipt.packages,checkpoint:receipt.checkpoint,permit:permit)
        try grants.verifyBoundTerminal(receipt.transition,plan:receipt.plan,packages:fresh,resourcePermit:permit)
        try packages.verifyResolutionCheckpoint(receipt.checkpoint,resourcePermit:permit)
        try journal.verifyExact(receipt.journalReceipt,plan:receipt.plan,resourcePermit:permit)
    }
    private func scope(_ body:(DeviceLocalResourcePermit)throws->Void)throws {
        try DeviceLocalResourceRegistry.requireIdle()
        let descriptors=try [journal.resourceGateDescriptor,grants.resourceGateDescriptor,packages.resourceGateDescriptor].sorted {
            if $0.path.utf8.elementsEqual($1.path.utf8){return $0.rootID.uuidString < $1.rootID.uuidString}
            return $0.path.utf8.lexicographicallyPrecedes($1.path.utf8)
        }
        for a in descriptors.indices{for b in descriptors.indices where a < b {
            guard descriptors[a].instance != descriptors[b].instance,
                  !DeviceLocalResourceDescriptor.pathsOverlap(descriptors[a].path,descriptors[b].path) else{throw DeviceLocalResourceGateFailure.invalidRoots}
        }}
        let permit=DeviceLocalResourcePermit(descriptors)
        try DeviceLocalResourceRegistry.begin(permit);defer{permit.invalidate();DeviceLocalResourceRegistry.finish(permit)}
        func acquire(_ index:Int)throws {
            if index == descriptors.count{try DeviceLocalResourceRegistry.execute(permit);try body(permit);return}
            let instance=descriptors[index].instance
            if instance == ObjectIdentifier(journal){try journal.withResourceGateScope(permit){try acquire(index+1)}}
            else if instance == ObjectIdentifier(grants){try grants.withResourceGateScope(permit){try acquire(index+1)}}
            else{try packages.withResourceGateScope(permit){try acquire(index+1)}}
        }
        try acquire(0)
    }
}

/// Fixed native intent join only. Read scopes cannot construct this permit or dispatch mutation.
final class DeviceNativeProvisioningCommandPermit {
    private let read:DeviceLocalResourcePermit
    fileprivate init(_ read:DeviceLocalResourcePermit){self.read=read}
    func begin(_ instance:ObjectIdentifier)throws{try read.beginRead(instance)}
    func end(){read.endRead()}
}
/// Native-specific publication token issued only by the fixed coordinator AFTER all scope exits.
/// A legacy completion token cannot publish a native pending object, nor can read scopes mint it.
final class DeviceNativeProvisioningPublicationPermit {
    private let transition:DeviceLocalProvisioningIntentStore.NativeJoinTransition
    fileprivate init(_ transition:DeviceLocalProvisioningIntentStore.NativeJoinTransition){self.transition=transition}
    func validate(_ original:DeviceLocalProvisioningIntentStore.NativeJoinTransition)throws {
        try DeviceLocalResourceRegistry.requireIdle()
        guard transition === original else{throw DeviceLocalResourceGateFailure.invalidScope}
    }
}
/// The two-root command reserves intent only; it admits no resource/structural/runtime execution.
final class DeviceNativeProvisioningCoordinator {
    private let journal:DeviceLocalProvisioningIntentStore,structural:DeviceStructuralStore
    init(journal:DeviceLocalProvisioningIntentStore,structural:DeviceStructuralStore){self.journal=journal;self.structural=structural}
    func joinExact(_ request:DeviceNativeProvisioningRequest,plan:DeviceValidatedNativeProvisioningPlan,
                   attachment:DeviceLocalProvisioningIntentStore.DeliveryAttachmentReceipt?)throws->DeviceLocalProvisioningIntentStore.NativeJoinReceipt {
        guard request.roots.journalID == journal.rootID,request.roots.structuralID == structural.rootID,
              request.roots == plan.roots else{throw DeviceStructuralStoreError.conflict}
        let fresh=try DeviceNativeProvisioningPlanner.qualify(request)
        guard fresh.intentBytes == plan.intentBytes,fresh.candidateBytes == plan.candidateBytes,
              fresh.delivery.commandBytes == plan.delivery.commandBytes,fresh.delivery.planBytes == plan.delivery.planBytes else{throw DeviceStructuralStoreError.conflict}
        var pending:DeviceLocalProvisioningIntentStore.NativeJoinTransition?
        do {
            try scope {permit in
                try structural.verifyNativeGenesisExact(request.baseline,resourcePermit:permit)
                let original=try journal.captureNativeJoinOriginal(plan,attachment:attachment,resourcePermit:permit)
                try structural.verifyNativeGenesisExact(request.baseline,resourcePermit:permit)
                let transition=try journal.performNativeJoinExact(plan,original:original,commandPermit:.init(permit))
                pending=transition // Retained only for failure cleanup; no publication token yet.
                try structural.verifyNativeGenesisExact(request.baseline,resourcePermit:permit)
                try journal.verifyNativeJoinTransition(transition,plan:plan,resourcePermit:permit)
            }
        } catch {
            if let transition=pending {try journal.discardNativeJoinPublication(transition)}
            throw error
        }
        guard let transition=pending else{throw DeviceLocalResourceGateFailure.invalidScope}
        do {return try journal.publishNativeJoinExact(transition,publicationPermit:.init(transition))}
        catch {try journal.discardNativeJoinPublication(transition);throw error}
    }
    func verifyExact(_ receipt:DeviceLocalProvisioningIntentStore.NativeJoinReceipt,plan:DeviceValidatedNativeProvisioningPlan,
                     baseline:DeviceStructuralStore.NativeGenesisCheckpoint)throws {
        try scope {permit in
            try structural.verifyNativeGenesisExact(baseline,resourcePermit:permit)
            try journal.verifyNativeJoinExact(receipt,plan:plan,resourcePermit:permit)
            try structural.verifyNativeGenesisExact(baseline,resourcePermit:permit)
        }
    }
    private func scope(_ body:(DeviceLocalResourcePermit)throws->Void)throws {
        try DeviceLocalResourceRegistry.requireIdle()
        let descriptors=try [journal.resourceGateDescriptor,structural.resourceGateDescriptor].sorted {
            if $0.path.utf8.elementsEqual($1.path.utf8){return $0.rootID.uuidString < $1.rootID.uuidString}
            return $0.path.utf8.lexicographicallyPrecedes($1.path.utf8)
        }
        guard descriptors[0].instance != descriptors[1].instance,
              !DeviceLocalResourceDescriptor.pathsOverlap(descriptors[0].path,descriptors[1].path) else{throw DeviceLocalResourceGateFailure.invalidRoots}
        let permit=DeviceLocalResourcePermit(descriptors)
        try DeviceLocalResourceRegistry.begin(permit);defer{permit.invalidate();DeviceLocalResourceRegistry.finish(permit)}
        func acquire(_ index:Int)throws {
            if index == descriptors.count {try DeviceLocalResourceRegistry.execute(permit);try body(permit);return}
            if descriptors[index].instance == ObjectIdentifier(journal){try journal.withNativeResourceGateScope(permit){try acquire(index+1)}}
            else{try structural.withResourceGateScope(permit){try acquire(index+1)}}
        }
        try acquire(0)
    }
}
